#!/bin/bash
# Checks the contract with test-ci, given a checkout of it in TEST_CI_DIR:
#   1. gh200.yml labels jobs test-ci-<profile> and test-ci-run-<run id>, which the
#      dispatcher reads;
#   2. gh200.yml runs image steps with test-ci-apptainer, which bin/ provides;
#   3. the job script test-ci's request-runner writes (dispatch: mvp) runs this
#      repo's launcher with arguments it accepts;
#   4. every profile in test-ci's profiles.json is one submit.sh accepts.
# The profiles themselves live only in test-ci. Without TEST_CI_DIR this skips the
# checks, unless CHECK_CONTRACT=1 (CI). Needs jq.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "contract with test-ci: $*" >&2; exit 1; }

dir=${TEST_CI_DIR:-}
if [ -z "$dir" ] || [ ! -f "$dir/.github/workflows/gh200.yml" ]; then
  [ "${CHECK_CONTRACT:-0}" = 1 ] && die "no test-ci checkout at '$dir': set TEST_CI_DIR"
  echo "contract with test-ci not checked: set TEST_CI_DIR to a test-ci checkout"
  exit 0
fi
dir=$(cd "$dir" && pwd)
wf=$dir/.github/workflows/gh200.yml
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

# 1 and 2
grep -qF "format('[\"test-ci-{0}\",\"test-ci-run-{1}\"]'" "$wf" \
  || die "gh200.yml no longer labels jobs test-ci-<profile> + test-ci-run-<run id>"
grep -qF "shell: test-ci-apptainer {0}" "$wf" && [ -x "$root/bin/test-ci-apptainer" ] \
  || die "gh200.yml and bin/test-ci-apptainer disagree on the custom shell"

# 3. Run test-ci's request.sh against stand-ins for gh and the job API, then run the
#    job script it wrote, with this repo's launcher and a stand-in runner.
mkdir -p "$t/stub" "$t/runner" "$t/home" "$t/tmp"
printf '#!/bin/bash\necho QUJD\n' > "$t/stub/gh"
cat > "$t/stub/curl" <<'STUB'
#!/bin/bash
# The job API's reply, as ci-service gives it: to the file after -o, with the HTTP
# code for -w, or on stdout if request.sh doesn't ask for those
reply='{"id": "dQw4w9WgXcQ", "release_url": "https://ci.example/ci/job?id=dQw4w9WgXcQ"}'
out=""
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    @*) cp "${1#@}" "$T/job.sh"; shift ;;
    *) shift ;;
  esac
done
if [ -n "$out" ]; then printf '%s' "$reply" > "$out"; printf 201; else echo "$reply"; fi
STUB
printf '#!/bin/bash\necho "runner ran"\n' > "$t/runner/run.sh"
chmod +x "$t/stub/gh" "$t/stub/curl" "$t/runner/run.sh"
profile=$(jq -r 'keys_unsorted[0]' "$dir/request-runner/profiles.json")
T=$t PATH="$t/stub:$PATH" DISPATCH=mvp PROFILE=$profile ORIGIN_TOKEN=ot GH_TOKEN=pat \
  URL=https://ci.example LAUNCHER="$root/launcher/launch-runner.sh" REPO=o/r RUN_ID=1 RUN_ATTEMPT=1 \
  GITHUB_STEP_SUMMARY=$t/summary GITHUB_OUTPUT=$t/output \
  "$dir/request-runner/request.sh" > "$t/request.log" 2>&1 || die "request.sh failed: $(cat "$t/request.log")"
RUNNER_HOME=$t/runner TMPDIR=$t/tmp HOME=$t/home bash "$t/job.sh" > "$t/job.log" 2>&1 \
  || die "the launcher refused request-runner's job script: $(cat "$t/job.log")"
grep -q 'runner ran' "$t/job.log" || die "the runner didn't start: $(cat "$t/job.log")"

# 4. Every profile, as the dispatcher passes it to submit.sh
printf '#!/bin/bash\necho 1\n' > "$t/stub/sbatch"
chmod +x "$t/stub/sbatch"
n=0
while IFS=$'\t' read -r name minutes options; do
  # shellcheck disable=SC2086  # the options are split into words on purpose, as the dispatcher does
  echo CFG | HOME=$t/home PATH="$t/stub:$PATH" "$root/launcher/submit.sh" \
    --profile "$name" --runner-minutes "$minutes" -- $options > /dev/null 2> "$t/submit.err" \
    || die "submit.sh refuses profile $name: $(cat "$t/submit.err")"
  n=$((n + 1))
done < <(jq -r 'to_entries[] | [.key, .value.runner_minutes, (.value.slurm | join(" "))] | @tsv' \
  "$dir/request-runner/profiles.json")
[ "$n" -gt 0 ] || die "no profiles in test-ci's profiles.json"
echo "contract with test-ci OK: labels, custom shell, launcher arguments, $n profiles ($dir)"
