# shellcheck shell=bash
# profiles.sh: sourced by request-runner (test-ci) and by submit.sh and
# launch-runner.sh (test-ci-runner). Two identical copies, test-ci's
# request-runner/profiles.sh and test-ci-runner's launcher/profiles.sh: change
# both at once. test-ci-runner's tests/check-profiles.sh fails if they differ.
#
# A profile names the resources a CI job gets on Isambard-AI. Each one sets:
#   SBATCH_ARGS     Slurm options for the job
#   RUNNER_MINUTES  how long the launcher lets the runner live
#   JOB_MINUTES     the job's timeout-minutes in .github/workflows/gh200.yml
#
# Keep JOB_MINUTES < RUNNER_MINUTES < the Slurm --time, so GitHub stops the job
# first, then the launcher stops the runner, and Slurm never has to kill it.
# tests/check-profiles.sh fails if gh200.yml's timeout map drifts from this file.

# shellcheck disable=SC2034  # the variables are used by the scripts that source this
PROFILES="gh200-1gpu gh200-4gpu dev-cpu"

# Stop a runner that hasn't been given a job this long after it starts: its job
# may have gone while the Slurm job waited (cancelled, or failed after 24 h in
# GitHub's queue), and otherwise it would hold its node until RUNNER_MINUTES.
IDLE_MINUTES=10

profile_settings() {
  case ${1:-} in
    gh200-1gpu)
      SBATCH_ARGS=(--nodes=1 --gpus=1 --time=01:00:00)
      RUNNER_MINUTES=55 JOB_MINUTES=50 ;;
    gh200-4gpu)
      SBATCH_ARGS=(--nodes=1 --gpus=4 --time=02:00:00)
      RUNNER_MINUTES=115 JOB_MINUTES=110 ;;
    dev-cpu)
      # The dev stack's Slurm container (Phase A), which has no GPUs
      SBATCH_ARGS=(--nodes=1 --time=00:30:00)
      RUNNER_MINUTES=25 JOB_MINUTES=20 ;;
    *) return 1 ;;
  esac
}
