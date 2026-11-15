# test-ci-runner

What runs [test-ci](https://github.com/PaulJWright/test-ci)'s GitHub Actions jobs
on Isambard-AI: the launcher inside each Slurm job, its pre-job hook, the
profiles, the custom shell for steps in a container image, and a dispatcher for
starting runners by hand. A demo, not a BriCS product.

Users never touch this repo. They call test-ci's reusable workflow; this is what
answers it.

## How it fits

| Repo | Who uses it | What's in it |
|---|---|---|
| [test-ci](https://github.com/PaulJWright/test-ci) | Anyone whose repo runs jobs on Isambard-AI | The reusable workflow, the request job's action, examples |
| test-ci-runner (this) | Whoever runs the service | Everything that starts and runs a runner |
| ci-service | Phase A on: the job API, release page and submitter | Unchanged; its dev stack copies this repo into its Slurm container |

A job in a calling repo waits in GitHub for a runner labelled `test-ci-<profile>`
and `test-ci-run-<run id>`. Something starts a Slurm job that runs
`launcher/launch-runner.sh` with a one-job runner config for those labels. The
launcher starts GitHub's runner, which takes that job, runs it, reports to GitHub
and exits.

What starts the Slurm job depends on the workflow's `dispatch` input:

| `dispatch` | What starts it | Runs as |
|---|---|---|
| `manual` (Phase 1) | `tools/dispatch-runner.sh` on your laptop, over ssh | You |
| `mvp` (Phase A, dev) | ci-service's submitter, after a release, through ssh → sudo → `slurmspawner_sbatch` | The releaser's `user.project` |

## Layout

```
launcher/launch-runner.sh   runs inside every Slurm job: config, private copy, hook,
                            SIGTERM, idle stop, clean-up
launcher/hook.sh            pre-job hook: marks the job's start, refuses another repo or run
launcher/submit.sh          on a login node: config on stdin -> 0600 file -> sbatch the launcher
launcher/profiles.sh        profile -> Slurm options and time limits
bin/test-ci-apptainer       custom shell: runs a step's script in TEST_CI_IMAGE with Apptainer
tools/dispatch-runner.sh    on your laptop: one runner per queued test-ci job (manual dispatch)
tests/                      shellcheck, actionlint, the contract with test-ci, simulate.sh
```

## The contract with test-ci

The two repos meet at four points. `tests/check-profiles.sh` checks them against a
checkout of test-ci (CI checks out test-ci's `main`; locally, set `TEST_CI_DIR`):

- `launcher/profiles.sh` is identical to test-ci's `request-runner/profiles.sh`,
  which writes the `#SBATCH` lines for `dispatch: mvp`;
- test-ci's `gh200.yml` sets `timeout-minutes` from the same profiles;
- `gh200.yml` labels jobs `test-ci-<profile>` and `test-ci-run-<run id>`, which the
  dispatcher reads;
- `gh200.yml` runs image steps with `shell: test-ci-apptainer {0}`, which the
  launcher puts on `PATH` from `bin/`.

Change a profile in both repos at once.

## Set up on Isambard-AI

Once, on a login node. The runner install sits beside this checkout, so the
launcher finds `~/actions-runner/current` for `~/test-ci-runner`.

```bash
git clone https://github.com/PaulJWright/test-ci-runner ~/test-ci-runner

mkdir -p ~/actions-runner/2.338.2 && cd ~/actions-runner
curl -fsSL https://github.com/actions/runner/releases/download/v2.338.2/actions-runner-linux-arm64-2.338.2.tar.gz \
  | tar -xz -C 2.338.2
ln -sfn 2.338.2 current

# One tar file per runner version: each job then unpacks the runner in about a
# second, instead of copying its files one by one (45-54 s from home)
tar -cf 2.338.2.tar -C 2.338.2 .
ln -sfn 2.338.2.tar current.tar
```

## Start runners by hand (`dispatch: manual`)

On your laptop, with `gh` signed in and `clifton auth` done, and this repo cloned:

```bash
tools/dispatch-runner.sh --watch OWNER/REPO     # leave running: every queued job gets a runner
tools/dispatch-runner.sh OWNER/REPO RUN_ID      # or one run
```

For each queued job labelled `test-ci-<profile>`, it makes a one-job runner config
with your `gh` login and pipes it over ssh to `launcher/submit.sh`, which keeps it
in a `0600` file and runs `sbatch` with the profile's settings. It runs `git pull`
in `~/test-ci-runner` first, so the cluster's launcher matches this repo. Options:
`--host` (default `brics.aip2.isambard`), `--dir` (default `test-ci-runner`),
`--no-pull`, `--interval`.

Logs of each Slurm job are in `~/.test-ci/logs/` on Isambard-AI.

**Manual dispatch runs every job as you, with no release step and no checks
beyond the pre-job hook. Use it on your own test repos only.**

## In ci-service's dev stack (`dispatch: mvp`)

ci-service's `submitter/dev/add_runner.sh /path/to/test-ci-runner` copies
`launcher/` and `bin/` into the dev Slurm container at `/opt/test-ci-runner`, and
installs the runner beside it at `/opt/actions-runner/current`. test-ci's
`request-runner` writes job scripts that `exec
/opt/test-ci-runner/launcher/launch-runner.sh --config-env …`.

## What the launcher does

- reads the runner config from a `0600` file it then deletes (`--config-file`, from
  `submit.sh`) or from the environment (`--config-env`, Phase A), and passes it to
  the runner in `ACTIONS_RUNNER_INPUT_JITCONFIG`, never on a command line;
- copies the runner into a private folder in node-local `TMPDIR` (falling back to
  `/local/user/<uid>`, then `/tmp`), from `current.tar` if it exists; sets the
  folder to `0700` and runs with `umask 077`, as the runner writes its key `0644`;
- sets the pre-job hook, which refuses a job from another repo or run;
- puts `bin/` on `PATH` for `test-ci-apptainer`;
- runs the runner under `timeout` from the profile, passes Slurm's SIGTERM on to it
  and waits, so GitHub shows a cancelled job as cancelled;
- stops a runner that hasn't been given a job within `IDLE_MINUTES` (10), so a
  runner whose job has gone doesn't hold its node;
- deletes the private folder at the end.

Settings reach it as arguments: `submit.sh` uses `sbatch --wrap`, never `--export`,
which lost `TMPDIR` in Phase 0.

## Tested so far

On Isambard-AI, 13 Nov 2026, with `dispatch: manual`:

- a push runs the GH200 jobs with nobody touching Isambard-AI: about 25 s from
  push to the job starting with the tar copy, most of it the watcher's polling;
- a plain job, and one in `ubuntu:24.04` through `test-ci-apptainer`, both see the
  GH200 and pass;
- each runner takes one job, deletes its credentials and exits; the launcher
  cleans up, and no config files are left in `~/.test-ci`;
- `scancel` mid-job: GitHub shows "The operation was canceled" 19 s later, inside
  Slurm's 30 s before SIGKILL;
- the tar copy unpacks the runner in 0-1 s, against 45-54 s copying file by file;
- two queued runs, one dispatched: the other run's jobs stay queued (run label);
- a runner started for run A that takes a job from run B is refused by the
  pre-job hook before checkout;
- a matrix gives one queued job per profile; `gh200-1gpu` gets one GPU and
  `gh200-4gpu` a whole node with four (after 40 min in the Slurm queue);
- runner configs left unused for 41 min and for 2 h 34 min still work.

Not yet tested on the cluster: the idle stop, and `dispatch: mvp` through
ci-service (Phase A).

## Known gaps

- A Slurm job cancelled before it starts leaves its config file in `~/.test-ci`
  and its runner registration in GitHub.
- When a GitHub job is cancelled or fails before its runner starts, the dispatcher
  doesn't cancel the Slurm job. The runner stops itself after 10 minutes without a
  job.

## Checks

```bash
tests/lint.sh                          # shellcheck, actionlint, the contract (with TEST_CI_DIR)
tests/simulate.sh                      # stand-ins for the runner, sbatch, ssh and gh; Linux only
TEST_CI_DIR=../test-ci tests/lint.sh   # with test-ci cloned beside this repo
```
