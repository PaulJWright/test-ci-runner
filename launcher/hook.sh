#!/bin/bash
# hook.sh: the runner's pre-job hook (ACTIONS_RUNNER_HOOK_JOB_STARTED). It runs
# before the job's first step; a non-zero exit fails the job before any of the
# job's own code runs.
#
# Phase 1: log what the job is, and refuse a job from a repo or run other than
# the one this runner was started for. Phase B: ask Service 1 instead.
set -euo pipefail

# Tell the launcher a job has arrived, so it doesn't stop this runner as idle.
if [ -n "${TEST_CI_JOB_MARKER:-}" ]; then : > "$TEST_CI_JOB_MARKER"; fi

echo "test-ci: ${GITHUB_REPOSITORY:-?} run ${GITHUB_RUN_ID:-?} attempt ${GITHUB_RUN_ATTEMPT:-?}," \
  "job ${GITHUB_JOB:-?}, commit ${GITHUB_SHA:-?}, profile ${TEST_CI_PROFILE:-?}"

if [ -n "${TEST_CI_EXPECT_REPO:-}" ] && [ "${GITHUB_REPOSITORY:-}" != "$TEST_CI_EXPECT_REPO" ]; then
  echo "::error::This runner was started for $TEST_CI_EXPECT_REPO, not ${GITHUB_REPOSITORY:-?}"
  exit 1
fi
if [ -n "${TEST_CI_EXPECT_RUN:-}" ] && [ "${GITHUB_RUN_ID:-}" != "$TEST_CI_EXPECT_RUN" ]; then
  echo "::error::This runner was started for run $TEST_CI_EXPECT_RUN, not ${GITHUB_RUN_ID:-?}"
  exit 1
fi
