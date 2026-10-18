#!/usr/bin/env bash
# The fixture's post-test script: checks that the setup script (with its
# arguments) and the pre-test action ran before the tests.
set -euo pipefail
marker="${RUNNER_TEMP:?}/rust-ci-setup-ran"
if [[ "$(cat "${marker}" 2>/dev/null)" != "one two" ]]; then
  echo "::error::the setup script didn't run with its arguments"
  exit 1
fi
if [[ "${RUST_CI_PRE_TEST:-}" != ran ]]; then
  echo "::error::the pre-test action didn't run, or its variable didn't reach the tests"
  exit 1
fi
echo "setup script and pre-test action both ran"
