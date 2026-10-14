#!/usr/bin/env bash
# The fixture's setup script, run by rust.yml's lint and test jobs. It leaves
# a marker, with its arguments, for the post-test script to check.
set -euo pipefail
printf '%s\n' "$*" >"${RUNNER_TEMP:?}/rust-ci-setup-ran"
