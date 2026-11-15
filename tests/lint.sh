#!/bin/bash
# Runs shellcheck on every script, actionlint on the workflows, and the profile and
# contract checks (set TEST_CI_DIR to a test-ci checkout for the contract).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
shellcheck -x -P SCRIPTDIR launcher/*.sh bin/test-ci-apptainer tools/*.sh tests/*.sh
if command -v actionlint >/dev/null; then
  actionlint .github/workflows/*.yml
else
  echo "actionlint not installed: skipped"
fi
tests/check-profiles.sh
