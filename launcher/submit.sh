#!/bin/bash
# submit.sh: on an Isambard-AI login node. Reads one runner config on stdin,
# keeps it in a 0600 file, and submits the launcher with the profile's Slurm
# options. Prints the Slurm job ID.
#
#   submit.sh --profile P --runner-minutes N [--repo OWNER/REPO --run ID] -- SLURM_OPTION...
#
# The runner minutes and Slurm options come from test-ci's profiles.json, which
# the dispatcher reads; this repo keeps no copy. Only --nodes=N, --gpus=N and
# --time=HH:MM:SS are accepted, --time is required, and the runner must stop
# before Slurm's limit. The repo and run, when given, are checked again by the
# pre-job hook.
set -euo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
usage="usage: submit.sh --profile P --runner-minutes N [--repo OWNER/REPO --run ID] -- SLURM_OPTION..."
die() { echo "submit.sh: $*" >&2; exit 2; }

profile="" minutes="" repo="" run=""
while [ $# -gt 0 ]; do
  case $1 in
    --profile) profile=$2; shift 2 ;;
    --runner-minutes) minutes=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --run) run=$2; shift 2 ;;
    --) shift; break ;;
    *) die "unknown argument: $1. $usage" ;;
  esac
done
[[ $profile =~ ^[a-z0-9-]+$ ]] || die "bad or missing --profile. $usage"
[[ $minutes =~ ^[0-9]+$ ]] && [ "$minutes" -ge 1 ] || die "bad or missing --runner-minutes. $usage"
[[ -z $repo || $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "bad repo: $repo"
[[ -z $run || $run =~ ^[0-9]+$ ]] || die "bad run ID: $run"

slurm_minutes=""
for o in "$@"; do
  if [[ $o =~ ^--(nodes|gpus)=[0-9]+$ ]]; then :
  elif [[ $o =~ ^--time=([0-9]+):([0-9]{2}):([0-9]{2})$ ]]; then
    slurm_minutes=$(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} + (10#${BASH_REMATCH[3]} > 0) ))
  else die "Slurm option '$o' isn't one of --nodes=N, --gpus=N, --time=HH:MM:SS"
  fi
done
[ -n "$slurm_minutes" ] || die "no --time among the Slurm options"
[ "$minutes" -lt "$slurm_minutes" ] || die "runner minutes ($minutes) must be under Slurm's limit ($slurm_minutes)"

state="$HOME/.test-ci"
mkdir -p "$state/logs"
chmod 700 "$state"
config=$(umask 077; mktemp "$state/config.XXXXXX")
cat > "$config"
if [ ! -s "$config" ]; then
  rm -f "$config"
  die "no runner config on stdin"
fi

args=(--profile "$profile" --runner-minutes "$minutes" --config-file "$config")
[ -n "$repo" ] && args+=(--expect-repo "$repo")
[ -n "$run" ] && args+=(--expect-run "$run")

# Settings reach the launcher as arguments, not through sbatch --export, which lost
# TMPDIR in Phase 0. --wrap runs the launcher from its real path, so it finds hook.sh
# (a submitted script would run from Slurm's spool folder instead).
sbatch --parsable --job-name="test-ci-$profile${run:+-$run}" "$@" \
  --output="$state/logs/%x-%j.out" --chdir="$state" \
  --wrap "exec $here/launch-runner.sh $(printf '%q ' "${args[@]}")"
