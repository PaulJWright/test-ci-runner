#!/usr/bin/env bash
# dispatch-runner.sh: on your laptop. Starts one short-lived runner on Isambard-AI
# for each queued test-ci job: a job whose labels are test-ci-<profile> plus
# test-ci-run-<run id>, as gh200.yml sets them.
#
#   dispatch-runner.sh [options] OWNER/REPO RUN_ID   the queued test-ci jobs in one run
#   dispatch-runner.sh [options] --watch OWNER/REPO  keep doing that for every run
#
# For each job it reads the job's profile from test-ci's request-runner/profiles.json,
# at the commit of gh200.yml the run uses (v0 if GitHub doesn't say), creates a
# runner config with your gh login, sends both over ssh to
# test-ci-runner/launcher/submit.sh on Isambard-AI, and prints the Slurm job ID.
# Jobs run as your Isambard-AI account, with no release step: our own test repos
# only. This is Phase 1's stand-in for Service 1 and the submitter (Phase B), and
# --watch for the automatic mode.
#
# Options:
#   --host HOST   ssh host for Isambard-AI (default brics.aip2.isambard; run clifton auth first)
#   --dir DIR     the test-ci-runner checkout on Isambard-AI, relative to home
#                 (default test-ci-runner)
#   --no-pull     don't git pull that checkout first
#   --test-ci R   the repo holding gh200.yml and profiles.json (default PaulJWright/test-ci)
#   --interval N  seconds between checks with --watch (default 15)
set -euo pipefail

host=brics.aip2.isambard dir=test-ci-runner pull=1 watch=0 interval=15 test_ci=PaulJWright/test-ci
while [ $# -gt 0 ]; do
  case $1 in
    --host) host=$2; shift 2 ;;
    --dir) dir=$2; shift 2 ;;
    --no-pull) pull=0; shift ;;
    --watch) watch=1; shift ;;
    --interval) interval=$2; shift 2 ;;
    --test-ci) test_ci=$2; shift 2 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
repo=${1:?usage: dispatch-runner.sh [options] OWNER/REPO RUN_ID | --watch OWNER/REPO}
run=${2:-}
[ "$watch" = 1 ] || [ -n "$run" ] || { echo "give a run ID, or use --watch" >&2; exit 2; }
[[ $test_ci =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "bad --test-ci: $test_ci" >&2; exit 2; }

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# BatchMode: fail at once if the clifton certificate has expired.
# ControlMaster: one ssh connection, reused, so each call is quick.
remote() {
  ssh -o BatchMode=yes -o ConnectTimeout=20 -o ControlMaster=auto \
    -o ControlPath="$HOME/.ssh/test-ci-%C" -o ControlPersist=120 "$host" "$@"
}

# The queued test-ci jobs in one run, as "job-id profile" lines
queued_jobs() {
  gh api --paginate "repos/$repo/actions/runs/$1/jobs?filter=latest" \
    --jq '.jobs[] | select(.status == "queued")
          | [.id, ((.labels // [])[] | select(startswith("test-ci-") and (startswith("test-ci-run-") | not)))]
          | select(length > 1) | "\(.[0]) \(.[1] | ltrimstr("test-ci-"))"'
}

# The commit of test-ci's gh200.yml that a run calls, from GitHub's record of the
# reusable workflows the run used; v0 if it doesn't say.
test_ci_ref() {   # test_ci_ref RUN
  local ref
  ref=$(gh api "repos/$repo/actions/runs/$1" --jq "[.referenced_workflows[]?
          | select(.path | startswith(\"$test_ci/.github/workflows/gh200.yml@\")) | .sha][0] // empty") || true
  echo "${ref:-v0}"
}

# A profile's runner minutes and Slurm options from test-ci's profiles.json at REF,
# as one line, for example "55 --nodes=1 --gpus=1 --time=01:00:00". Empty if the
# profile isn't there.
profile_spec() {   # profile_spec REF PROFILE
  gh api "repos/$test_ci/contents/request-runner/profiles.json?ref=$1" \
    --jq ".content | gsub(\"\\n\"; \"\") | @base64d | fromjson | .[\"$2\"] // empty
          | [.runner_minutes] + .slurm | map(tostring) | join(\" \")"
}

start_runner() {   # start_runner RUN JOB PROFILE
  local r=$1 job=$2 profile=$3 ref spec minutes opts o config jobid
  [[ $profile =~ ^[a-z0-9-]+$ ]] || { echo "job $job: bad profile label '$profile'" >&2; return 1; }
  ref=$(test_ci_ref "$r")
  spec=$(profile_spec "$ref" "$profile") || return 1
  [ -n "$spec" ] || { echo "job $job: no profile '$profile' in $test_ci at $ref" >&2; return 1; }
  read -r minutes opts <<<"$spec"
  # submit.sh checks these again; checked here too, as they go into a remote command
  [[ $minutes =~ ^[0-9]+$ ]] || { echo "job $job: bad runner minutes '$minutes'" >&2; return 1; }
  for o in $opts; do
    [[ $o =~ ^--(nodes|gpus)=[0-9]+$ || $o =~ ^--time=[0-9]+:[0-9]{2}:[0-9]{2}$ ]] \
      || { echo "job $job: Slurm option '$o' not allowed" >&2; return 1; }
  done
  config=$(gh api -X POST "repos/$repo/actions/runners/generate-jitconfig" \
    -f name="test-ci-$r-$job" -F runner_group_id=1 \
    -f "labels[]=test-ci-$profile" -f "labels[]=test-ci-run-$r" \
    --jq .encoded_jit_config) || return 1
  [ -n "$config" ] || return 1
  jobid=$(printf '%s\n' "$config" | remote "$dir/launcher/submit.sh --profile $profile --runner-minutes $minutes --repo $repo --run $r -- $opts") || return 1
  echo "$(now) run $r, job $job: $profile runner in Slurm job $jobid"
}

remote true || { echo "can't reach $host: run 'clifton auth' and try again" >&2; exit 1; }
if [ "$pull" = 1 ]; then
  remote "git -C $dir pull -q --ff-only" || { echo "couldn't update ~/$dir on $host" >&2; exit 1; }
fi

if [ "$watch" = 0 ]; then
  found=0
  while read -r job profile; do
    [ -n "$job" ] || continue
    found=1
    start_runner "$run" "$job" "$profile" || echo "couldn't start a runner for job $job" >&2
  done < <(queued_jobs "$run")
  [ "$found" = 1 ] || echo "no queued test-ci jobs in run $run (yet?)"
  exit 0
fi

echo "$(now) watching $repo for queued test-ci jobs every ${interval}s. Ctrl-C to stop."
seen=" "
while :; do
  for status in queued in_progress; do
    for r in $(gh api "repos/$repo/actions/runs?status=$status&per_page=30" \
        --jq '.workflow_runs[].id' 2>/dev/null || true); do
      while read -r job profile; do
        [ -n "$job" ] || continue
        case $seen in *" $job "*) continue ;; esac
        seen="$seen$job "
        start_runner "$r" "$job" "$profile" || echo "couldn't start a runner for job $job" >&2
      done < <(queued_jobs "$r" 2>/dev/null || true)
    done
  done
  sleep "$interval"
done
