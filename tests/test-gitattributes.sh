#!/usr/bin/env bash
# Tests that a pull request's own .gitattributes can't hide its changes from
# the secrets and mutants jobs. In a temporary repository, a pull request marks
# *.rs -diff and *.txt binary, adds a file with a NUL byte, and plants a secret
# in each; after the override rust.yml writes to $GIT_DIR/info/attributes, the
# mutants job's `git diff` shows every change, and gitleaks (git mode, as the
# secrets job runs it, with --ignore-gitleaks-allow passed twice) finds every
# secret, including one on a line marked gitleaks:allow. Needs bash and git;
# the gitleaks cases are skipped when gitleaks isn't on PATH.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${src_root}/.github/workflows/rust.yml"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

failures=0
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}"
    failures=$((failures + 1))
  fi
}

# The override, as rust.yml writes it in the mutants and secrets jobs.
override='printf '"'"'* diff\n'"'"' >>"${attributes}"'
check "rust.yml writes the override in the mutants and secrets jobs" \
  test "$(grep -cF -- "${override}" "${workflow}")" -eq 2

# A GitHub token gitleaks' default rules find, built here so this file holds none.
token() { printf 'ghp_%s' "$(printf '%s' "$1" | sha256sum | cut -c1-36)"; }

repo="${work}/repo"
mkdir -p "${repo}/src"
git -C "${repo}" init --quiet
printf 'pub fn f() {}\n' >"${repo}/src/lib.rs"
git -C "${repo}" add -A
git -C "${repo}" commit --quiet -m base
base="$(git -C "${repo}" rev-parse HEAD)"

printf '*.rs -diff\n*.txt binary\n' >"${repo}/.gitattributes"
printf 'pub fn f() {}\npub const T: &str = "%s";\n' "$(token rs)" >"${repo}/src/lib.rs"
printf 'token = "%s"\n' "$(token txt)" >"${repo}/notes.txt"
printf 'nul\0token = "%s"\n' "$(token nul)" >"${repo}/blob.dat"
printf 'token = "%s" # gitleaks:allow\n' "$(token allow)" >"${repo}/allowed.toml"
git -C "${repo}" add -A
git -C "${repo}" commit --quiet -m "pull request"

# Before the override the changes are hidden: the reason for it.
git -C "${repo}" diff --no-color "${base}...HEAD" >"${work}/before.diff"
check "without the override git diff hides the .rs change" \
  grep -q '^Binary files a/src/lib.rs and b/src/lib.rs differ' "${work}/before.diff"

attributes="$(git -C "${repo}" rev-parse --path-format=absolute --git-path info/attributes)"
mkdir -p "$(dirname "${attributes}")"
eval "${override}"

# The mutants job's command, less --text, which on its own would hide the
# attributes' effect.
git -C "${repo}" diff --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ \
  "${base}...HEAD" >"${work}/after.diff"
check "with the override git diff shows no binary file" \
  bash -c '! grep -q "^Binary files" "$1"' _ "${work}/after.diff"
for f in src/lib.rs notes.txt blob.dat; do
  check "with the override git diff shows the ${f} change" \
    grep -q "^+++ b/${f}\$" "${work}/after.diff"
done

if ! command -v gitleaks >/dev/null; then
  echo "skip gitleaks cases: gitleaks is not on PATH"
else
  report="${work}/report.json"
  (cd "${repo}" && gitleaks git --no-banner --redact --ignore-gitleaks-allow --ignore-gitleaks-allow \
    --report-format json --report-path "${report}" "--log-opts=${base}..HEAD" . >"${work}/gitleaks.log" 2>&1)
  code=$?
  check "gitleaks exits 1 on the planted secrets" test "${code}" -eq 1
  for f in src/lib.rs notes.txt blob.dat allowed.toml; do
    check "gitleaks finds the secret in ${f}" grep -q "\"File\": \"${f}\"" "${report}"
  done
  if [[ ${failures} -ne 0 ]]; then
    sed 's/^/    /' "${work}/gitleaks.log"
  fi
fi

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all gitattributes cases passed"
