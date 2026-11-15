#!/bin/bash
# launch-runner.sh: runs inside every test-ci Slurm job. Starts GitHub's own
# runner for exactly one job, in a private copy, and cleans up after it.
#
#   launch-runner.sh --profile P --config-file F [--expect-repo OWNER/REPO] [--expect-run ID]
#   launch-runner.sh --profile P --config-env    [--expect-repo OWNER/REPO] [--expect-run ID]
#
# --config-file: a 0600 file holding the runner config; read, then deleted (submit.sh)
# --config-env:  the config is already in ACTIONS_RUNNER_INPUT_JITCONFIG (MVP job script)
#
# From Phase 0 (see the plan's "Phase 0 results"):
# - Slurm sends SIGTERM to this script only, and SIGKILL to everything 30 s later.
#   Pass SIGTERM on to the runner and wait for it, or GitHub waits ~10 minutes.
# - The runner writes its private key into its folder as 644: keep the folder 700.
# - Settings come as arguments, never through sbatch --export (that lost TMPDIR).
# - The job's result lives in GitHub. This script exits 0 whatever the job did.
# From Phase 1:
# - A runner whose job has gone before Slurm starts it sits idle. Stop it after
#   IDLE_MINUTES without a job (the hook marks a job's start).
set -euo pipefail
umask 077

here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
TEST_CI_RUNNER_HOME=$(cd "$here/.." && pwd)
# The runner install sits beside this checkout: ~/actions-runner/current for
# ~/test-ci-runner, /opt/actions-runner/current for /opt/test-ci-runner (the dev stack, and later a shared
# install). <it>.tar beside it, if present, is copied instead (much faster).
RUNNER_HOME=${RUNNER_HOME:-$(dirname "$TEST_CI_RUNNER_HOME")/actions-runner/current}
# shellcheck source=profiles.sh
. "$here/profiles.sh"

log() { echo "test-ci: $* ($(date -Is))"; }

profile="" config_file="" config_env=0 expect_repo="" expect_run=""
while [ $# -gt 0 ]; do
  case $1 in
    --profile) profile=$2; shift 2 ;;
    --config-file) config_file=$2; shift 2 ;;
    --config-env) config_env=1; shift ;;
    --expect-repo) expect_repo=$2; shift 2 ;;
    --expect-run) expect_run=$2; shift 2 ;;
    *) echo "test-ci: unknown argument: $1" >&2; exit 2 ;;
  esac
done
profile_settings "$profile" || { echo "test-ci: unknown profile '$profile'" >&2; exit 2; }

# 1. The runner config
if [ -n "$config_file" ]; then
  ACTIONS_RUNNER_INPUT_JITCONFIG=$(cat "$config_file")
  rm -f "$config_file"
elif [ "$config_env" != 1 ]; then
  echo "test-ci: no runner config: use --config-file or --config-env" >&2
  exit 2
fi
if [ -z "${ACTIONS_RUNNER_INPUT_JITCONFIG:-}" ]; then
  echo "test-ci: the runner config is empty" >&2
  exit 2
fi
export ACTIONS_RUNNER_INPUT_JITCONFIG

# 2. A private copy of the runner, in node-local TMPDIR. Jobs submitted through
#    sudo (the submitter) may not have TMPDIR set, so fall back to the per-user
#    folder the nodes provide, then /tmp.
base=${TMPDIR:-}
if [ -z "$base" ] || [ ! -d "$base" ]; then
  base=/local/user/$(id -u)
  [ -d "$base" ] || base=/tmp
fi
dir=$(mktemp -d "$base/test-ci-runner.XXXXXX")
trap 'rm -rf "$dir"; log "cleaned up"' EXIT
start=$(date +%s)
if [ -f "$RUNNER_HOME.tar" ]; then
  # one tar file (made once per runner version) instead of 431 MB of small files
  tar --no-overwrite-dir -xf "$RUNNER_HOME.tar" -C "$dir"
else
  cp -a "$RUNNER_HOME/." "$dir"/
fi
chmod 700 "$dir"   # cp -a and tar can copy the install's 755 onto the folder
if [ ! -x "$dir/run.sh" ]; then
  log "the runner copy in $dir is missing or incomplete"
  exit 1
fi
log "runner copied in $(( $(date +%s) - start ))s"

# 3. The pre-job hook, and what the job's steps can use
export ACTIONS_RUNNER_HOOK_JOB_STARTED="$here/hook.sh"
export TEST_CI_PROFILE=$profile TEST_CI_EXPECT_REPO=$expect_repo TEST_CI_EXPECT_RUN=$expect_run
export TEST_CI_JOB_MARKER="$dir/.test-ci-job-started"   # hook.sh creates it when a job arrives
export PATH="$TEST_CI_RUNNER_HOME/bin:$PATH"   # test-ci-apptainer, for steps that run in an image

# 4. Run the runner. On scancel or the time limit, pass SIGTERM on to it: it then
#    cancels the job, tells GitHub and exits, well inside Slurm's 30 s KillWait.
cd "$dir"
log "runner starting on $(hostname), profile $profile, for up to $RUNNER_MINUTES min"
listener="${dir##*/}/bin/Runner\.Listener"
trap 'log "SIGTERM: stopping the runner"; pkill -TERM -u "$(id -u)" -f "$listener" || true' TERM
timeout "${RUNNER_MINUTES}m" ./run.sh &
pid=$!

# 5. Stop the runner if no job arrives within IDLE_MINUTES. Its job may have gone
#    while the Slurm job waited; otherwise it would hold the node until the timeout.
#    TEST_CI_IDLE_SECONDS overrides the limit, for tests only.
idle=${TEST_CI_IDLE_SECONDS:-$(( IDLE_MINUTES * 60 ))}
(
  end=$(( SECONDS + idle ))
  while [ "$SECONDS" -lt "$end" ]; do
    [ -e "$TEST_CI_JOB_MARKER" ] && exit 0      # a job arrived
    kill -0 "$pid" 2>/dev/null || exit 0      # the runner has already gone
    sleep 2
  done
  [ -e "$TEST_CI_JOB_MARKER" ] && exit 0
  log "no job within $idle s of starting: stopping the runner"
  pkill -TERM -u "$(id -u)" -f "$listener" || true
) &
watchdog=$!

rc=0
while :; do
  wait "$pid" && rc=0 || rc=$?
  kill -0 "$pid" 2>/dev/null || break   # wait returns early when the trap runs
done
wait "$watchdog" 2>/dev/null || true    # it exits within 2 s of the runner
for _ in $(seq 25); do                    # the runner can outlive run.sh briefly
  pgrep -u "$(id -u)" -f "${dir##*/}/bin/Runner\." >/dev/null || break
  sleep 1
done
log "runner exited with $rc"
