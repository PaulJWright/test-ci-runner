#!/bin/bash
# submit.sh: on an Isambard-AI login node. Reads one runner config on stdin,
# keeps it in a 0600 file, and submits the launcher with the profile's Slurm
# settings. Prints the Slurm job ID.
#
#   submit.sh <profile> [<owner/repo> <run-id>]
#
# The repo and run, when given, are checked again by the pre-job hook.
set -euo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
# shellcheck source=profiles.sh
. "$here/profiles.sh"

profile=${1:?usage: submit.sh <profile> [<owner/repo> <run-id>]}
repo=${2:-} run=${3:-}
profile_settings "$profile" || { echo "unknown profile: $profile (known: $PROFILES)" >&2; exit 2; }
[[ -z $repo || $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "bad repo: $repo" >&2; exit 2; }
[[ -z $run || $run =~ ^[0-9]+$ ]] || { echo "bad run ID: $run" >&2; exit 2; }

state="$HOME/.test-ci"
mkdir -p "$state/logs"
chmod 700 "$state"
config=$(umask 077; mktemp "$state/config.XXXXXX")
cat > "$config"
if [ ! -s "$config" ]; then
  rm -f "$config"
  echo "no runner config on stdin" >&2
  exit 2
fi

args=(--profile "$profile" --config-file "$config")
[ -n "$repo" ] && args+=(--expect-repo "$repo")
[ -n "$run" ] && args+=(--expect-run "$run")

# Settings reach the launcher as arguments, not through sbatch --export, which lost
# TMPDIR in Phase 0. --wrap runs the launcher from its real path, so it finds hook.sh
# (a submitted script would run from Slurm's spool folder instead).
sbatch --parsable --job-name="test-ci-$profile${run:+-$run}" "${SBATCH_ARGS[@]}" \
  --output="$state/logs/%x-%j.out" --chdir="$state" \
  --wrap "exec $here/launch-runner.sh $(printf '%q ' "${args[@]}")"
