# test-ci-runner

This repo runs [test-ci](https://github.com/i-aye-eye/test-ci)'s GitHub Actions jobs on Isambard-AI. 
This includes the launcher inside each Slurm job, its pre-job hook, the custom shell for steps in a container image, and a dispatcher for starting runners by hand. A demo, not a BriCS product.

Users never need to touch this repo. 
A user should call test-ci's reusable workflow.

## How it fits

| Repo | Who uses it | What's in it |
|---|---|---|
| [test-ci](https://github.com/i-aye-eye/test-ci) | Anyone whose repo runs jobs on Isambard-AI | The reusable workflow, the request job's action, examples |
| test-ci-runner (this) | Whoever runs the service | Everything that starts and runs a runner |
| ci-service | Phase A on: the job API, release page and submitter | Unchanged; its dev stack copies this repo into its Slurm container |

- A job in a calling repo waits in GitHub for a runner labelled `test-ci-<profile>` and `test-ci-run-<run id>`.
- Something starts a Slurm job that runs `launcher/launch-runner.sh` with a one-job runner config for those labels.
- The launcher starts GitHub's runner, which takes that job, runs it, reports to GitHub and exits.

What starts the Slurm job depends on the workflow's `dispatch` input:

| `dispatch` | What starts it | Runs as |
|---|---|---|
| `manual` | `tools/dispatch-runner.sh` on your laptop, over ssh | You |
| `mvp` | ci-service's submitter, after a release, through ssh -> sudo -> `slurmspawner_sbatch` | The releaser's `user.project` |

## Layout

```
launcher/launch-runner.sh   runs inside every Slurm job: config, private copy, hook,
                            SIGTERM, idle stop, clean-up
launcher/hook.sh            pre-job hook: marks the job's start, refuses another repo or run
launcher/submit.sh          on a login node: config on stdin -> 0600 file -> sbatch the launcher
bin/test-ci-apptainer       custom shell: runs a step's script in TEST_CI_IMAGE with Apptainer
tools/dispatch-runner.sh    on your laptop: one runner per queued test-ci job (manual dispatch)
tests/                      shellcheck, actionlint, the contract with test-ci, simulate.sh
```

## The contract with `i-aye-eye/test-ci`

The profiles live only in test-ci, in `request-runner/profiles.json`: each one's
Slurm options and time limits. This repo keeps no copy. Its scripts take the
values as arguments:

- `launch-runner.sh --profile P --runner-minutes N`;
- `submit.sh --profile P --runner-minutes N [--repo R --run ID] -- SLURM_OPTION...`,
  which accepts only `--nodes=N`, `--gpus=N` and `--time=HH:MM:SS`, needs `--time`,
  and needs the runner minutes under Slurm's limit.

With `dispatch: mvp`, test-ci's `request-runner` writes both into the job script.
With `dispatch: manual`, the dispatcher reads `profiles.json` at the commit of
`gh200.yml` each run uses, so a run tagged `v0` gets `v0`'s profiles.

The two repos meet at four points. `tests/check-contract.sh` checks them against a
checkout of test-ci (CI checks out test-ci's `main`; locally, set `TEST_CI_DIR`):

- `gh200.yml` labels jobs `test-ci-<profile>` and `test-ci-run-<run id>`, which the
  dispatcher reads;
- `gh200.yml` runs image steps with `shell: test-ci-apptainer {0}`, which the
  launcher puts on `PATH` from `bin/`;
- the job script `request-runner` writes runs this launcher with arguments it accepts;
- every profile in `profiles.json` is one `submit.sh` accepts.

A profile is changed in test-ci only. A new kind of Slurm option needs `submit.sh`
changed here first.

## Set up on Isambard-AI

Set up once, on a UAN.
The runner install sits beside this checkout, so the launcher finds `~/actions-runner/current` for `~/test-ci-runner`.

```bash
git clone https://github.com/i-aye-eye/test-ci-runner ~/test-ci-runner

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

Assuming `gh` is installed, `clifton auth` ran, and this repo cloned, on your laptop:

```bash
tools/dispatch-runner.sh --watch OWNER/REPO     # leave running: every queued job gets a runner
tools/dispatch-runner.sh OWNER/REPO RUN_ID      # or one run
```

For each queued job labelled `test-ci-<profile>`, it reads the profile from
test-ci's `profiles.json` at the run's version of `gh200.yml` (`v0` if GitHub
doesn't say), makes a one-job runner config with your `gh` login, and pipes it over
ssh to `launcher/submit.sh` with the profile's settings. `submit.sh` keeps the
config in a `0600` file and runs `sbatch`. It runs `git pull` in `~/test-ci-runner`
first, so the cluster's launcher matches this repo. Options: `--host` (default
`brics.aip2.isambard`), `--dir` (default `test-ci-runner`), `--test-ci` (default
`i-aye-eye/test-ci`), `--no-pull`, `--interval`.

Logs of each Slurm job are in `~/.test-ci/logs/` on Isambard-AI.

**Manual dispatch runs every job as you, with no release step and no checks
beyond the pre-job hook. Use it on your own test repos only.**

## In `isambard-sc/ci-service`'s dev stack (`dispatch: mvp`)

ci-service's `submitter/dev/add_runner.sh /path/to/test-ci-runner` copies `launcher/` and `bin/` into the dev Slurm container at `/opt/test-ci-runner`, and installs the runner beside it at `/opt/actions-runner/current`. 
`test-ci`'s `request-runner` writes job scripts that `exec /opt/test-ci-runner/launcher/launch-runner.sh --profile P --runner-minutes N --config-env …`.

## What the launcher does

- reads the runner config from a `0600` file it then deletes (`--config-file`, from `submit.sh`) or from the environment (`--config-env`, Phase A), and passes it to the runner in `ACTIONS_RUNNER_INPUT_JITCONFIG`, never on a command line;
- copies the runner into a private folder in node-local `TMPDIR` (falling back to `/local/user/<uid>`, then `/tmp`), from `current.tar` if it exists; sets the
  folder to `0700` and runs with `umask 077`, as the runner writes its key `0644`;
- sets the pre-job hook, which refuses a job from another repo or run;
- puts `bin/` on `PATH` for `test-ci-apptainer`;
- runs the runner under `timeout` for `--runner-minutes`, passes Slurm's SIGTERM on to it and waits, so GitHub shows a cancelled job as cancelled;
- stops a runner that hasn't been given a job within `IDLE_MINUTES` (10), so a runner whose job has gone doesn't hold its node;
- deletes the private folder at the end.

Settings reach it as arguments: `submit.sh` uses `sbatch --wrap`, never `--export`, which lost `TMPDIR` in Phase 0.

## Paul's Testing

On Isambard-AI, 13 Nov 2026, with `dispatch: manual`:

- a push runs the GH200 jobs with nobody touching Isambard-AI: about 25 s from push to the job starting with the tar copy, most of it the watcher's polling;
- a plain job, and one in `ubuntu:24.04` through `test-ci-apptainer`, both see the GH200 and pass;
- each runner takes one job, deletes its credentials and exits; the launcher cleans up, and no config files are left in `~/.test-ci`;
- `scancel` mid-job: GitHub shows "The operation was canceled" 19 s later, inside Slurm's 30 s before SIGKILL;
- the tar copy unpacks the runner in 0-1 s, against 45-54 s copying file by file;
- two queued runs, one dispatched: the other run's jobs stay queued (run label);
- a runner started for run A that takes a job from run B is refused by the pre-job hook before checkout;
- a matrix gives one queued job per profile; `gh200-1gpu` gets one GPU and `gh200-4gpu` a whole node with four (after 40 min in the Slurm queue);
- runner configs left unused for 41 min and for 2 h 34 min still work.

Later on Isambard-AI:

- after the profiles moved to test-ci's `profiles.json` (15 Nov), a manual run passed with the profile's limits, and `scancel` on a waiting runner stopped it and cleaned up within a second;
- the idle stop (17 Nov): a runner given no job stopped itself 600 s after starting and cleaned up, and Slurm recorded COMPLETED after 10 min instead of holding the GPU for the job's hour.

On ci-service's dev stack, 15 Nov, with `dispatch: mvp` (Phase A): a pushed job, released as `testuser.project1`, ran through the ssh → sudo chain and passed. Unlike Isambard-AI, the dev Slurm signals every process on `scancel`, so a cancelled job shows as failed there.

## Known gaps

- A Slurm job cancelled before it starts leaves its config file in `~/.test-ci` and its runner registration in GitHub.
- A runner that never takes a job (cancelled, or stopped by the idle stop) leaves its registration in GitHub, offline. GitHub removes it after a day.
- When a GitHub job is cancelled or fails before its runner starts, the dispatcher doesn't cancel the Slurm job. The runner stops itself after 10 minutes without a job.

## Checks

```bash
tests/lint.sh                          # shellcheck, actionlint, the contract (with TEST_CI_DIR)
tests/simulate.sh                      # stand-ins for the runner, sbatch, ssh and gh; Linux only
TEST_CI_DIR=../test-ci tests/lint.sh   # with test-ci cloned beside this repo
```
