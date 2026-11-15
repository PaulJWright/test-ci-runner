#!/bin/bash
# Checks each profile's limits are in the right order (job < runner < Slurm), and,
# given a checkout of test-ci in TEST_CI_DIR, the contract between the two repos:
#   - launcher/profiles.sh is identical to test-ci's request-runner/profiles.sh
#   - gh200.yml's timeout-minutes map matches the profiles
#   - gh200.yml's labels are test-ci-<profile> and test-ci-run-<run id>
#   - gh200.yml's image steps use bin/test-ci-apptainer
# Without TEST_CI_DIR it checks the limits only, unless CHECK_CONTRACT=1 (CI).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../launcher/profiles.sh
. "$root/launcher/profiles.sh"

want="{"
for p in $PROFILES; do
  profile_settings "$p"
  want+="\"$p\":$JOB_MINUTES,"
  slurm=""
  for a in "${SBATCH_ARGS[@]}"; do case $a in --time=*) slurm=${a#--time=} ;; esac; done
  IFS=: read -r h m s <<<"$slurm"
  slurm_min=$(( 10#$h * 60 + 10#$m + (10#$s > 0) ))
  if [ "$JOB_MINUTES" -ge "$RUNNER_MINUTES" ] || [ "$RUNNER_MINUTES" -ge "$slurm_min" ]; then
    echo "profile $p: need job ($JOB_MINUTES) < runner ($RUNNER_MINUTES) < Slurm ($slurm_min) minutes" >&2
    exit 1
  fi
done
want="${want%,}}"
echo "profile limits OK: $want"

dir=${TEST_CI_DIR:-}
if [ -z "$dir" ] || [ ! -f "$dir/.github/workflows/gh200.yml" ]; then
  if [ "${CHECK_CONTRACT:-0}" = 1 ]; then
    echo "no test-ci checkout at '${dir}': set TEST_CI_DIR" >&2
    exit 1
  fi
  echo "contract with test-ci not checked: set TEST_CI_DIR to a test-ci checkout"
  exit 0
fi
wf=$dir/.github/workflows/gh200.yml

cmp -s "$root/launcher/profiles.sh" "$dir/request-runner/profiles.sh" || {
  echo "launcher/profiles.sh differs from test-ci's request-runner/profiles.sh:" >&2
  diff "$dir/request-runner/profiles.sh" "$root/launcher/profiles.sh" >&2 || true
  exit 1
}
have=$(grep -o "fromJSON('{[^']*}')\[inputs.profile\]" "$wf" \
  | sed "s/^fromJSON('//; s/')\[inputs.profile\]$//")
[ "$have" = "$want" ] || { echo "test-ci's gh200.yml timeout map is $have; profiles.sh says $want" >&2; exit 1; }
grep -qF "format('[\"test-ci-{0}\",\"test-ci-run-{1}\"]'" "$wf" \
  || { echo "test-ci's gh200.yml no longer labels jobs test-ci-<profile> + test-ci-run-<run id>" >&2; exit 1; }
grep -qF "shell: test-ci-apptainer {0}" "$wf" && [ -x "$root/bin/test-ci-apptainer" ] \
  || { echo "test-ci's gh200.yml and bin/test-ci-apptainer disagree on the custom shell" >&2; exit 1; }
echo "contract with test-ci OK ($dir)"
