#!/bin/bash
# Runs the launcher, hook, submit.sh and dispatch-runner.sh against stand-ins
# for the runner, sbatch, ssh and gh. No network,
# no Slurm. Catches wiring mistakes; it can't stand in for the real cluster.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
pass=0
ok() { echo "ok - $*"; pass=$((pass + 1)); }
fail() { echo "FAIL - $*" >&2; exit 1; }

# A stand-in runner: run.sh starts bin/Runner.Listener by its full path, as the real
# one does. The listener runs the pre-job hook with a fake job's GITHUB_* variables,
# records what it saw, then either finishes or (FAKE_HOLD=1) waits for SIGTERM.
fake=$t/actions-runner/current
mkdir -p "$fake/bin"
cat > "$fake/run.sh" <<'EOF'
#!/bin/bash
DIR="$(cd -P "$(dirname "$0")" && pwd)"
"$DIR/bin/Runner.Listener" run
EOF
cat > "$fake/bin/Runner.Listener" <<'EOF'
#!/bin/bash
[ -n "${ACTIONS_RUNNER_INPUT_JITCONFIG:-}" ] || { echo "listener: no config"; exit 3; }
root=$(cd "$(dirname "$0")/.." && pwd)
{ echo "config=$ACTIONS_RUNNER_INPUT_JITCONFIG"; echo "mode=$(stat -c %a "$root")";
  echo "path=$PATH"; } > "$FAKE_OUT/seen"
if [ "${FAKE_NOJOB:-0}" != 1 ]; then   # FAKE_NOJOB=1: no job ever arrives
  GITHUB_REPOSITORY=${FAKE_REPO:-o/r} GITHUB_RUN_ID=${FAKE_RUN:-1} GITHUB_RUN_ATTEMPT=1 \
    GITHUB_JOB=run GITHUB_SHA=abc "$ACTIONS_RUNNER_HOOK_JOB_STARTED" > "$FAKE_OUT/hook" 2>&1 \
    && echo "hook=0" >> "$FAKE_OUT/seen" || echo "hook=$?" >> "$FAKE_OUT/seen"
  if [ -e "${TEST_CI_JOB_MARKER:-/nonexistent}" ]; then echo "marker=yes"; else echo "marker=no"; fi >> "$FAKE_OUT/seen"
fi
if [ "${FAKE_HOLD:-0}" = 1 ]; then
  trap 'echo "listener: SIGTERM, telling GitHub"; sleep 2; echo "listener: done"; exit 0' TERM
  sleep 300 & wait
fi
if [ -n "${FAKE_SLEEP:-}" ]; then sleep "$FAKE_SLEEP"; fi   # a job that takes a while
echo "listener: job finished"
EOF
chmod +x "$fake/run.sh" "$fake/bin/Runner.Listener"
export RUNNER_HOME=$fake FAKE_OUT=$t TMPDIR=$t/tmp HOME=$t/home
mkdir -p "$TMPDIR" "$HOME"

# 1. Launcher with a config file: reads and deletes it, 700 folder, hook passes, cleans up
echo "CFG1" > "$t/cfg" && chmod 600 "$t/cfg"
"$root/launcher/launch-runner.sh" --profile gh200-1gpu --runner-minutes 55 --config-file "$t/cfg" \
  --expect-repo o/r --expect-run 1 > "$t/log1" 2>&1 || fail "launcher exited non-zero: $(cat "$t/log1")"
[ ! -e "$t/cfg" ] || fail "config file not deleted"
grep -q '^config=CFG1$' "$t/seen" || fail "runner didn't get the config"
grep -q '^mode=700$' "$t/seen" || fail "runner folder not 700: $(grep mode "$t/seen")"
grep -q "^path=$root/bin:" "$t/seen" || fail "the checkout's bin/ not first on PATH"
grep -q '^hook=0$' "$t/seen" || fail "hook refused a matching job: $(cat "$t/hook")"
grep -q '^marker=yes$' "$t/seen" || fail "hook didn't mark the job's start"
grep -q 'cleaned up' "$t/log1" || fail "no clean-up"
grep -q 'profile gh200-1gpu, for up to 55 min' "$t/log1" || fail "runner minutes not used: $(cat "$t/log1")"
[ -z "$(ls -A "$TMPDIR")" ] || fail "runner folder left behind: $(ls -A "$TMPDIR")"
ok "launcher: config file, 700 folder, PATH, hook and its job marker, clean-up"

# 2. The hook refuses another repo or run
echo CFG2 > "$t/cfg"
FAKE_RUN=2 "$root/launcher/launch-runner.sh" --profile gh200-1gpu --runner-minutes 55 --config-file "$t/cfg" \
  --expect-repo o/r --expect-run 1 > "$t/log2" 2>&1 || true
grep -q '^hook=1$' "$t/seen" || fail "hook accepted the wrong run"
grep -q 'started for run 1, not 2' "$t/hook" || fail "hook message: $(cat "$t/hook")"
ok "hook: refuses a job from another run"

# 3. Config from the environment, and a missing config
ACTIONS_RUNNER_INPUT_JITCONFIG=CFG3 "$root/launcher/launch-runner.sh" --profile gh200-4gpu --runner-minutes 115 \
  --config-env > "$t/log3" 2>&1 || fail "launcher --config-env failed"
grep -q '^config=CFG3$' "$t/seen" || fail "runner didn't get the config from the environment"
if "$root/launcher/launch-runner.sh" --profile gh200-1gpu --runner-minutes 55 > "$t/log4" 2>&1; then fail "ran with no config"; fi
if ACTIONS_RUNNER_INPUT_JITCONFIG=X "$root/launcher/launch-runner.sh" --profile gh200-1gpu --config-env > "$t/log5" 2>&1; then
  fail "ran without --runner-minutes"
fi
if ACTIONS_RUNNER_INPUT_JITCONFIG=X "$root/launcher/launch-runner.sh" --profile gh200-1gpu --runner-minutes 5x --config-env > "$t/log5" 2>&1; then
  fail "ran with bad --runner-minutes"
fi
ok "launcher: --config-env; refuses no config and missing or bad runner minutes"

# 4. The tar copy, when <RUNNER_HOME>.tar exists
tar -C "$fake" -cf "$fake.tar" .
echo CFG4 > "$t/cfg"
"$root/launcher/launch-runner.sh" --profile gh200-1gpu --runner-minutes 55 --config-file "$t/cfg" > "$t/log6" 2>&1 \
  || fail "launcher with tar failed: $(cat "$t/log6")"
grep -q '^mode=700$' "$t/seen" || fail "tar copy left the folder at $(grep mode "$t/seen")"
rm -f "$fake.tar"
ok "launcher: tar copy keeps the folder 700"

# 4b. With no RUNNER_HOME, the runner beside this checkout (/opt/actions-runner
#     for /opt/test-ci-runner)
mkdir -p "$t/opt/test-ci-runner" "$t/opt/actions-runner"
cp -r "$root/launcher" "$root/bin" "$t/opt/test-ci-runner/"
cp -a "$fake" "$t/opt/actions-runner/current"
echo CFG4B > "$t/cfg"
env -u RUNNER_HOME "$t/opt/test-ci-runner/launcher/launch-runner.sh" --profile dev-cpu --runner-minutes 25 --config-file "$t/cfg" \
  > "$t/log6b" 2>&1 || fail "launcher from /opt layout failed: $(cat "$t/log6b")"
grep -q '^config=CFG4B$' "$t/seen" || fail "runner beside the checkout not used"
ok "launcher: finds the runner beside its checkout"

# 5. SIGTERM to the launcher only (as Slurm does): the runner gets it and finishes first
echo CFG5 > "$t/cfg"
FAKE_HOLD=1 setsid "$root/launcher/launch-runner.sh" --profile gh200-1gpu --runner-minutes 55 --config-file "$t/cfg" \
  > "$t/log7" 2>&1 &
lpid=$!
for _ in $(seq 50); do grep -q 'runner starting' "$t/log7" 2>/dev/null && break; sleep 0.1; done
sleep 1
kill -TERM "$lpid"
wait "$lpid" || true
grep -q 'listener: done' "$t/log7" || fail "runner didn't finish after SIGTERM: $(cat "$t/log7")"
n_done=$(grep -n 'listener: done' "$t/log7" | cut -d: -f1)
n_clean=$(grep -n 'cleaned up' "$t/log7" | cut -d: -f1)
[ "$n_done" -lt "$n_clean" ] || fail "cleaned up before the runner finished"
ok "launcher: passes SIGTERM on and waits for the runner"

# 5b. A runner that gets no job is stopped after the idle limit, and cleaned up
echo CFG5B > "$t/cfg"
start=$SECONDS
FAKE_NOJOB=1 FAKE_HOLD=1 TEST_CI_IDLE_SECONDS=3 "$root/launcher/launch-runner.sh" --profile gh200-1gpu --runner-minutes 55 \
  --config-file "$t/cfg" > "$t/log7b" 2>&1 || fail "launcher (idle) exited non-zero: $(cat "$t/log7b")"
grep -q 'no job within 3 s of starting: stopping the runner' "$t/log7b" || fail "no idle stop: $(cat "$t/log7b")"
grep -q 'listener: done' "$t/log7b" || fail "idle runner not stopped cleanly: $(cat "$t/log7b")"
grep -q 'cleaned up' "$t/log7b" || fail "no clean-up after idle stop"
[ $(( SECONDS - start )) -lt 20 ] || fail "idle stop took $(( SECONDS - start )) s"
ok "launcher: stops a runner with no job after the idle limit"

# 5c. A runner whose job runs past the idle limit is left alone
echo CFG5C > "$t/cfg"
FAKE_SLEEP=6 TEST_CI_IDLE_SECONDS=2 "$root/launcher/launch-runner.sh" --profile gh200-1gpu --runner-minutes 55 \
  --config-file "$t/cfg" > "$t/log7c" 2>&1 || fail "launcher (busy) exited non-zero: $(cat "$t/log7c")"
! grep -q 'no job within' "$t/log7c" || fail "stopped a runner that had a job: $(cat "$t/log7c")"
grep -q 'listener: job finished' "$t/log7c" || fail "job didn't finish: $(cat "$t/log7c")"
ok "launcher: leaves a runner with a job running past the idle limit"

# 6. submit.sh: 0600 config file, arguments not --export, Slurm options checked
mkdir -p "$t/stub"
cat > "$t/stub/sbatch" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_OUT/sbatch-args"
echo 4242
STUB
chmod +x "$t/stub/sbatch"
submit() { PATH="$t/stub:$PATH" "$root/launcher/submit.sh" "$@"; }
jobid=$(echo CFG6 | submit --profile gh200-4gpu --runner-minutes 115 --repo o/r --run 77 \
  -- --nodes=1 --gpus=4 --time=02:00:00)
[ "$jobid" = 4242 ] || fail "submit.sh printed '$jobid'"
grep -qx -- '--gpus=4' "$t/sbatch-args" || fail "Slurm options missing"
grep -qx -- '--job-name=test-ci-gh200-4gpu-77' "$t/sbatch-args" || fail "job name"
! grep -q -- '--export' "$t/sbatch-args" || fail "submit.sh uses --export"
wrap=$(grep -A1 -x -- '--wrap' "$t/sbatch-args" | tail -1)
case $wrap in "exec $root/launcher/launch-runner.sh --profile gh200-4gpu --runner-minutes 115 --config-file $HOME/.test-ci/config."*" --expect-repo o/r --expect-run 77 ") ;;
  *) fail "wrap command: $wrap" ;; esac
cfg=$(sed -n 's/.*--config-file \([^ ]*\).*/\1/p' <<<"$wrap")
[ "$(stat -c %a "$cfg")" = 600 ] && [ "$(cat "$cfg")" = CFG6 ] || fail "config file mode or content"
[ "$(stat -c %a "$HOME/.test-ci")" = 700 ] || fail "\$HOME/.test-ci not 700"
rm -f "$HOME"/.test-ci/config.*
refuse() {   # refuse WHY ARGS...: submit.sh must refuse, leaving no config file behind
  local why=$1; shift
  if echo CFG | submit "$@" >/dev/null 2>&1; then fail "submit.sh accepted $why"; fi
  [ -z "$(ls "$HOME/.test-ci"/config.* 2>/dev/null)" ] || fail "config left behind after refusing $why"
}
refuse "a bad repo name" --profile gh200-1gpu --runner-minutes 55 --repo 'o/r;rm' --run 1 -- --gpus=1 --time=01:00:00
refuse "an option not on the list" --profile gh200-1gpu --runner-minutes 55 -- --gpus=1 --mem=1 --time=01:00:00
refuse "an option with shell in it" --profile gh200-1gpu --runner-minutes 55 -- '--gpus=1;id' --time=01:00:00
refuse "no --time" --profile gh200-1gpu --runner-minutes 55 -- --gpus=1
refuse "runner minutes over Slurm's limit" --profile gh200-1gpu --runner-minutes 60 -- --gpus=1 --time=01:00:00
refuse "no --runner-minutes" --profile gh200-1gpu -- --gpus=1 --time=01:00:00
ok "submit.sh: 0600 config, arguments not --export, Slurm options and minutes checked"

# 7. dispatch-runner.sh: reads each run's profiles from test-ci at the commit the run
#    used, one runner per queued job, both labels. The gh stand-in answers from canned
#    API responses with real jq, so the dispatcher's own jq filters are tested too.
api=$t/api
mkdir -p "$api"
profiles='{"gh200-1gpu":{"job_minutes":50,"runner_minutes":55,"slurm":["--nodes=1","--gpus=1","--time=01:00:00"]},
 "gh200-4gpu":{"job_minutes":110,"runner_minutes":115,"slurm":["--nodes=1","--gpus=4","--time=02:00:00"]}}'
# GitHub's contents API returns the file in base64, with a line break every 60 characters
jq -n --arg c "$(printf '%s' "$profiles" | base64 -w 60)" '{content: $c, encoding: "base64"}' > "$api/profiles"
cat > "$api/jobs-555" <<'JSON'
{"jobs": [
  {"id": 901, "status": "queued", "labels": ["test-ci-gh200-1gpu", "test-ci-run-555"]},
  {"id": 902, "status": "queued", "labels": ["test-ci-gh200-4gpu", "test-ci-run-555"]},
  {"id": 903, "status": "completed", "labels": ["test-ci-gh200-1gpu", "test-ci-run-555"]},
  {"id": 904, "status": "queued", "labels": ["ubuntu-latest"]}]}
JSON
echo '{"referenced_workflows": [{"path": "PaulJWright/test-ci/.github/workflows/gh200.yml@v0", "sha": "abc123", "ref": "refs/tags/v0"}]}' > "$api/run-555"
echo '{"jobs": [{"id": 911, "status": "queued", "labels": ["test-ci-gh200-1gpu", "test-ci-run-556"]}]}' > "$api/jobs-556"
echo '{"referenced_workflows": []}' > "$api/run-556"
echo '{"jobs": [{"id": 921, "status": "queued", "labels": ["test-ci-nope", "test-ci-run-557"]}]}' > "$api/jobs-557"
echo '{"referenced_workflows": []}' > "$api/run-557"
cat > "$t/stub/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$FAKE_OUT/gh-calls"
shift   # api
path="" filter=""
while [ $# -gt 0 ]; do
  case $1 in
    --paginate) shift ;;
    --jq) filter=$2; shift 2 ;;
    -X|-f|-F|-H) shift 2 ;;
    *) path=$1; shift ;;
  esac
done
case $path in
  *generate-jitconfig) echo "CFG-$RANDOM"; exit 0 ;;
  repos/o/r/actions/runs/*/jobs*) f=jobs-$(sed 's#.*/runs/\([0-9]*\)/jobs.*#\1#' <<<"$path") ;;
  repos/o/r/actions/runs/*) f=run-${path##*/} ;;
  repos/PaulJWright/test-ci/contents/request-runner/profiles.json\?ref=*) f=profiles
    echo "${path##*ref=}" >> "$FAKE_OUT/profile-refs" ;;
  *) echo "gh stand-in: no answer for $path" >&2; exit 1 ;;
esac
jq -r "${filter:-.}" "$FAKE_API/$f"
STUB
cat > "$t/stub/ssh" <<'STUB'
#!/bin/bash
while [ "${1#-}" != "$1" ]; do shift 2; done; shift
echo "ssh $*" >> "$FAKE_OUT/ssh-calls"
case "$*" in *submit.sh*) cat > /dev/null; echo 5000 ;; esac
STUB
chmod +x "$t/stub/gh" "$t/stub/ssh"
dispatch() { PATH="$t/stub:$PATH" FAKE_API=$api "$root/tools/dispatch-runner.sh" "$@"; }
out=$(dispatch o/r 555)
[ "$(grep -c 'runner in Slurm job 5000' <<<"$out")" = 2 ] || fail "dispatch output: $out"
grep -qx abc123 "$t/profile-refs" || fail "profiles not read at the run's commit: $(cat "$t/profile-refs")"
grep -q 'labels\[\]=test-ci-gh200-4gpu -f labels\[\]=test-ci-run-555' "$t/gh-calls" || fail "labels: $(cat "$t/gh-calls")"
grep -q 'test-ci-runner/launcher/submit.sh --profile gh200-4gpu --runner-minutes 115 --repo o/r --run 555 -- --nodes=1 --gpus=4 --time=02:00:00' \
  "$t/ssh-calls" || fail "submit call: $(cat "$t/ssh-calls")"
grep -q 'git -C test-ci-runner pull' "$t/ssh-calls" || fail "no git pull"
out=$(dispatch --no-pull o/r 556)
grep -q 'runner in Slurm job 5000' <<<"$out" && [ "$(tail -1 "$t/profile-refs")" = v0 ] \
  || fail "no fallback to v0: $out / $(cat "$t/profile-refs")"
n_configs=$(grep -c generate-jitconfig "$t/gh-calls")
out=$(dispatch --no-pull o/r 557 2>&1) || true
grep -q "no profile 'nope'" <<<"$out" || fail "unknown profile not reported: $out"
[ "$(grep -c generate-jitconfig "$t/gh-calls")" = "$n_configs" ] || fail "made a runner config for an unknown profile"
ok "dispatch-runner.sh: profiles from test-ci at the run's commit (else v0), one runner per job, both labels"

echo "$pass checks passed"
