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
"$root/launcher/launch-runner.sh" --profile gh200-1gpu --config-file "$t/cfg" \
  --expect-repo o/r --expect-run 1 > "$t/log1" 2>&1 || fail "launcher exited non-zero: $(cat "$t/log1")"
[ ! -e "$t/cfg" ] || fail "config file not deleted"
grep -q '^config=CFG1$' "$t/seen" || fail "runner didn't get the config"
grep -q '^mode=700$' "$t/seen" || fail "runner folder not 700: $(grep mode "$t/seen")"
grep -q "^path=$root/bin:" "$t/seen" || fail "the checkout's bin/ not first on PATH"
grep -q '^hook=0$' "$t/seen" || fail "hook refused a matching job: $(cat "$t/hook")"
grep -q '^marker=yes$' "$t/seen" || fail "hook didn't mark the job's start"
grep -q 'cleaned up' "$t/log1" || fail "no clean-up"
[ -z "$(ls -A "$TMPDIR")" ] || fail "runner folder left behind: $(ls -A "$TMPDIR")"
ok "launcher: config file, 700 folder, PATH, hook and its job marker, clean-up"

# 2. The hook refuses another repo or run
echo CFG2 > "$t/cfg"
FAKE_RUN=2 "$root/launcher/launch-runner.sh" --profile gh200-1gpu --config-file "$t/cfg" \
  --expect-repo o/r --expect-run 1 > "$t/log2" 2>&1 || true
grep -q '^hook=1$' "$t/seen" || fail "hook accepted the wrong run"
grep -q 'started for run 1, not 2' "$t/hook" || fail "hook message: $(cat "$t/hook")"
ok "hook: refuses a job from another run"

# 3. Config from the environment, and a missing config
ACTIONS_RUNNER_INPUT_JITCONFIG=CFG3 "$root/launcher/launch-runner.sh" --profile gh200-4gpu \
  --config-env > "$t/log3" 2>&1 || fail "launcher --config-env failed"
grep -q '^config=CFG3$' "$t/seen" || fail "runner didn't get the config from the environment"
if "$root/launcher/launch-runner.sh" --profile gh200-1gpu > "$t/log4" 2>&1; then fail "ran with no config"; fi
if "$root/launcher/launch-runner.sh" --profile nope --config-env > "$t/log5" 2>&1; then fail "ran with a bad profile"; fi
ok "launcher: --config-env; refuses no config and unknown profiles"

# 4. The tar copy, when <RUNNER_HOME>.tar exists
tar -C "$fake" -cf "$fake.tar" .
echo CFG4 > "$t/cfg"
"$root/launcher/launch-runner.sh" --profile gh200-1gpu --config-file "$t/cfg" > "$t/log6" 2>&1 \
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
env -u RUNNER_HOME "$t/opt/test-ci-runner/launcher/launch-runner.sh" --profile dev-cpu --config-file "$t/cfg" \
  > "$t/log6b" 2>&1 || fail "launcher from /opt layout failed: $(cat "$t/log6b")"
grep -q '^config=CFG4B$' "$t/seen" || fail "runner beside the checkout not used"
ok "launcher: finds the runner beside its checkout"

# 5. SIGTERM to the launcher only (as Slurm does): the runner gets it and finishes first
echo CFG5 > "$t/cfg"
FAKE_HOLD=1 setsid "$root/launcher/launch-runner.sh" --profile gh200-1gpu --config-file "$t/cfg" \
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
FAKE_NOJOB=1 FAKE_HOLD=1 TEST_CI_IDLE_SECONDS=3 "$root/launcher/launch-runner.sh" --profile gh200-1gpu \
  --config-file "$t/cfg" > "$t/log7b" 2>&1 || fail "launcher (idle) exited non-zero: $(cat "$t/log7b")"
grep -q 'no job within 3 s of starting: stopping the runner' "$t/log7b" || fail "no idle stop: $(cat "$t/log7b")"
grep -q 'listener: done' "$t/log7b" || fail "idle runner not stopped cleanly: $(cat "$t/log7b")"
grep -q 'cleaned up' "$t/log7b" || fail "no clean-up after idle stop"
[ $(( SECONDS - start )) -lt 20 ] || fail "idle stop took $(( SECONDS - start )) s"
ok "launcher: stops a runner with no job after the idle limit"

# 5c. A runner whose job runs past the idle limit is left alone
echo CFG5C > "$t/cfg"
FAKE_SLEEP=6 TEST_CI_IDLE_SECONDS=2 "$root/launcher/launch-runner.sh" --profile gh200-1gpu \
  --config-file "$t/cfg" > "$t/log7c" 2>&1 || fail "launcher (busy) exited non-zero: $(cat "$t/log7c")"
! grep -q 'no job within' "$t/log7c" || fail "stopped a runner that had a job: $(cat "$t/log7c")"
grep -q 'listener: job finished' "$t/log7c" || fail "job didn't finish: $(cat "$t/log7c")"
ok "launcher: leaves a runner with a job running past the idle limit"

# 6. submit.sh: 0600 config file, arguments not --export, profile settings
mkdir -p "$t/stub"
cat > "$t/stub/sbatch" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_OUT/sbatch-args"
echo 4242
EOF
chmod +x "$t/stub/sbatch"
jobid=$(echo CFG6 | PATH="$t/stub:$PATH" "$root/launcher/submit.sh" gh200-4gpu o/r 77)
[ "$jobid" = 4242 ] || fail "submit.sh printed '$jobid'"
grep -qx -- '--gpus=4' "$t/sbatch-args" || fail "profile settings missing"
grep -qx -- '--job-name=test-ci-gh200-4gpu-77' "$t/sbatch-args" || fail "job name"
! grep -q -- '--export' "$t/sbatch-args" || fail "submit.sh uses --export"
wrap=$(grep -A1 -x -- '--wrap' "$t/sbatch-args" | tail -1)
case $wrap in "exec $root/launcher/launch-runner.sh --profile gh200-4gpu --config-file $HOME/.test-ci/config."*" --expect-repo o/r --expect-run 77 ") ;;
  *) fail "wrap command: $wrap" ;; esac
cfg=$(sed -n 's/.*--config-file \([^ ]*\).*/\1/p' <<<"$wrap")
[ "$(stat -c %a "$cfg")" = 600 ] && [ "$(cat "$cfg")" = CFG6 ] || fail "config file mode or content"
[ "$(stat -c %a "$HOME/.test-ci")" = 700 ] || fail "\$HOME/.test-ci not 700"
if echo CFG | PATH="$t/stub:$PATH" "$root/launcher/submit.sh" gh200-1gpu 'o/r;rm' 1 >/dev/null 2>&1; then
  fail "submit.sh accepted a bad repo name"
fi
jobid=$(echo CFG7 | PATH="$t/stub:$PATH" "$root/launcher/submit.sh" dev-cpu o/r 78)
[ "$jobid" = 4242 ] || fail "submit.sh dev-cpu printed '$jobid'"
! grep -q -- '--gpus' "$t/sbatch-args" || fail "dev-cpu asks for GPUs"
grep -qx -- '--time=00:30:00' "$t/sbatch-args" || fail "dev-cpu time limit"
rm -f "$HOME"/.test-ci/config.*
ok "submit.sh: 0600 config, profile settings, arguments not --export, input checks, dev-cpu"

# 7. dispatch-runner.sh: one runner per queued test-ci job, with both labels
cat > "$t/stub/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "$FAKE_OUT/gh-calls"
case "$*" in
  *"runs/555/jobs"*) printf '901 gh200-1gpu\n902 gh200-4gpu\n' ;;
  *generate-jitconfig*) echo "CFG-$(date +%N)" ;;
esac
EOF
cat > "$t/stub/ssh" <<'EOF'
#!/bin/bash
while [ "${1#-}" != "$1" ]; do shift 2; done; shift
echo "ssh $*" >> "$FAKE_OUT/ssh-calls"
case "$*" in *submit.sh*) cat > /dev/null; echo 5000 ;; esac
EOF
chmod +x "$t/stub/gh" "$t/stub/ssh"
out=$(PATH="$t/stub:$PATH" "$root/tools/dispatch-runner.sh" o/r 555)
[ "$(grep -c 'runner in Slurm job 5000' <<<"$out")" = 2 ] || fail "dispatch output: $out"
grep -q 'labels\[\]=test-ci-gh200-4gpu -f labels\[\]=test-ci-run-555' "$t/gh-calls" || fail "labels: $(cat "$t/gh-calls")"
grep -q 'test-ci-runner/launcher/submit.sh gh200-4gpu o/r 555' "$t/ssh-calls" || fail "submit call: $(cat "$t/ssh-calls")"
grep -q 'git -C test-ci-runner pull' "$t/ssh-calls" || fail "no git pull"
ok "dispatch-runner.sh: one runner per queued job, profile and run labels"

echo "$pass checks passed"
