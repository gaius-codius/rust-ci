#!/usr/bin/env bash
# Tests actions/check-args/check-args.sh: arguments that would make a check pass
# without checking fail, in --flag value, --flag=value and short-cluster forms;
# the arguments projects use pass. Needs bash only.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="${src_root}/actions/check-args/check-args.sh"

failures=0

# run_case <tool> <want: pass or fail> <arguments> [want output substring]
run_case() {
  local tool="$1" want="$2" arguments="$3" want_out="${4:-}" o code
  o="$(ARGUMENTS="${arguments}" bash "${script}" "${tool}" 2>&1)"
  code=$?
  if [[ ${want} == pass && ${code} -ne 0 ]] || [[ ${want} == fail && ${code} -ne 1 ]] ||
    [[ -n ${want_out} && ${o} != *"${want_out}"* ]]; then
    echo "FAIL ${tool} [${arguments}]: exit ${code}, want ${want}${want_out:+ with [${want_out}]}; output:"
    printf '%s\n' "${o}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${tool} ${want} [${arguments}]"
  fi
}

# gitleaks
run_case gitleaks pass ""
run_case gitleaks pass "--ignore-gitleaks-allow"
run_case gitleaks pass "--ignore-gitleaks-allow --max-target-megabytes 10 -v --redact=50 --timeout 600"
run_case gitleaks fail "--exit-code 0" "gitleaks-arguments: --exit-code is not allowed"
run_case gitleaks fail "--exit-code=0" "--exit-code"
run_case gitleaks fail "--baseline-path old.json" "--baseline-path"
run_case gitleaks fail "-b old.json" "-b is not allowed"
run_case gitleaks fail "-vb old.json" "-b is not allowed"
run_case gitleaks fail "--enable-rule=aws-access-token" "--enable-rule"
run_case gitleaks fail "--gitleaks-ignore-path docs/" "--gitleaks-ignore-path"
run_case gitleaks fail "-i docs/" "-i is not allowed"
run_case gitleaks fail "--config other.toml" "use the gitleaks-config input"
run_case gitleaks fail "--log-opts=HEAD~1..HEAD" "--log-opts"
run_case gitleaks fail "--pre-commit" "--pre-commit"
run_case gitleaks fail "--staged" "--staged"
run_case gitleaks fail "--help" "--help"
run_case gitleaks fail "-h" "-h is not allowed"
run_case gitleaks pass "-l info" # -l takes a value: the letters after it aren't flags
run_case gitleaks pass "-lhb"    # the value of -l is "hb"

# cargo-mutants
run_case mutants pass ""
run_case mutants pass "--test-tool nextest --timeout 120 -j 2 -j2 --test-workspace true -vV --cap-lints true"
run_case mutants pass "--test-tool nextest -- --release"
run_case mutants fail "--list" "mutants-arguments: --list is not allowed: runs no tests"
run_case mutants fail "--list-files" "--list-files"
run_case mutants fail "--check" "--check"
run_case mutants fail "--exclude-re ." "--exclude-re"
run_case mutants fail "--exclude-re=." "--exclude-re"
run_case mutants fail "-E ." "-E is not allowed"
run_case mutants fail "-vE." "-E is not allowed"
run_case mutants fail "--exclude src/lib.rs" "--exclude"
run_case mutants fail "-e src/lib.rs" "-e is not allowed"
run_case mutants fail "--re nothing" "--re"
run_case mutants fail "-F nothing" "-F is not allowed"
run_case mutants fail "--file src/other.rs" "--file"
run_case mutants fail "-f src/other.rs" "-f is not allowed"
run_case mutants fail "--package other" "--package"
run_case mutants fail "--shard 0/100" "--shard"
run_case mutants fail "--iterate" "--iterate"
run_case mutants fail "--baseline skip" "--baseline"
run_case mutants fail "--in-diff empty.diff" "--in-diff"
run_case mutants fail "-D empty.diff" "-D is not allowed"
run_case mutants fail "--config lax.toml" "--config"
run_case mutants fail "--no-config" "--no-config"
run_case mutants fail "--output elsewhere" "--output"
run_case mutants fail "--version" "--version"
run_case mutants pass "-L debug" # "debug" is -L's value, not -d -e -b -u -g

# nextest (test-command, with or without its "cargo nextest run")
run_case nextest pass "cargo nextest run --workspace --locked --profile ci --no-tests=fail"
run_case nextest pass "cargo nextest run --workspace --all-targets --locked --profile ci --no-tests=fail"
run_case nextest pass "--workspace -E test(foo) --run-ignored all --flaky-result fail -j 4 -- --skip slow"
run_case nextest fail "cargo nextest run --workspace --no-tests=pass" "test-command: --no-tests=pass is not allowed"
run_case nextest fail "cargo nextest run --workspace --no-tests pass" "--no-tests=pass"
run_case nextest fail "cargo nextest run --no-tests=warn" "--no-tests=warn"
run_case nextest fail "cargo nextest run --retries 3" "--retries"
run_case nextest fail "cargo nextest run --retries=3" "--retries"
run_case nextest fail "cargo nextest run --flaky-result=pass" "--flaky-result=pass"
run_case nextest fail "cargo nextest run --no-run" "--no-run"
run_case nextest fail "cargo nextest run --partition count:1/9" "--partition"
run_case nextest fail "cargo nextest run --run-ignored only" "--run-ignored=only"
run_case nextest fail "cargo nextest run -- --ignored" "--ignored"
run_case nextest fail "cargo nextest run -R latest" "-R is not allowed"
run_case nextest fail "cargo nextest run --debugger /bin/true" "--debugger"
run_case nextest fail "cargo nextest run --archive-file tests.tar.zst" "--archive-file"
run_case nextest fail "cargo nextest run --binaries-metadata b.json" "--binaries-metadata"
run_case nextest fail "cargo nextest run --config build.rustflags=['--cap-lints=allow']" "--config"
run_case nextest fail "cargo nextest run --config-file lax.toml" "--config-file"
run_case nextest fail "cargo nextest run --manifest-path other/Cargo.toml" "--manifest-path"

# cargo-deny
run_case deny pass "--all-features --locked"
run_case deny pass "--all-features --locked --workspace -t x86_64-unknown-linux-gnu -L info"
run_case deny fail "--config lax.toml" "deny-arguments: --config is not allowed"
run_case deny fail "--manifest-path other/Cargo.toml" "--manifest-path"
run_case deny fail "--metadata-path fake.json" "--metadata-path"
run_case deny fail "--exclude bad-crate" "--exclude"
run_case deny fail "--locked check advisories" "check is not allowed"
run_case deny fail "-V" "-V is not allowed"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all check-args cases passed"
