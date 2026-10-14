#!/usr/bin/env bash
# Tests actions/baseline-drift/drift.py: a project made of the baseline's own
# files has no drift, and each kind of change is reported as a warning while
# the exit status stays 0. Needs bash and python3 (3.11 or later).
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# drift.py finds the baseline relative to itself, so run a copy of the layout.
mkdir -p "${work}/rust-ci/actions/baseline-drift"
cp "${src_root}/actions/baseline-drift/drift.py" "${work}/rust-ci/actions/baseline-drift/"
cp -R "${src_root}/baseline" "${work}/rust-ci/baseline"

failures=0

# run_case <name> <expected output substring> <unexpected substring or "">
# Sets up the project from the baseline, applies the commands on stdin, then
# runs drift.py in it.
run_case() {
  local name="$1" want="$2" unwanted="$3" out code
  rm -rf "${work}/project" && mkdir -p "${work}/project/.config"
  local b="${work}/rust-ci/baseline"
  cp "${b}/rustfmt.toml" "${b}/rust-toolchain.toml" "${b}/deny.toml" "${b}/typos.toml" "${work}/project/"
  cp "${b}/.config/nextest.toml" "${work}/project/.config/"
  {
    printf '[workspace]\nmembers = ["crates/*"]\n\n'
    cat "${b}/workspace-lints.toml"
  } >"${work}/project/Cargo.toml"
  (cd "${work}/project" && bash -s)
  out="$(cd "${work}/project" && python3 -I "${work}/rust-ci/actions/baseline-drift/drift.py" 2>&1)"
  code=$?
  if [[ ${code} -ne 0 ]]; then
    echo "FAIL ${name}: exit ${code}, want 0"
    failures=$((failures + 1))
  elif [[ "${out}" != *"${want}"* ]] || [[ -n "${unwanted}" && "${out}" == *"${unwanted}"* ]]; then
    echo "FAIL ${name}: output:"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

run_case "identical copies have no drift" "no drift" "::warning" <<<":"
run_case "comments and order don't count" "no drift" "::warning" \
  <<<"{ echo '# a comment'; tac rustfmt.toml | grep -v '^#'; } >x && mv x rustfmt.toml"
run_case "changed toolchain is drift" 'toolchain.channel is "1.97.0"' "no drift" \
  <<<"sed -i 's/channel = .*/channel = \"1.97.0\"/' rust-toolchain.toml"
run_case "changed rustfmt value is drift" "max_width is 120" "no drift" \
  <<<"sed -i 's/max_width = 100/max_width = 120/' rustfmt.toml"
run_case "extra rustfmt key is drift" "hard_tabs is not in the baseline" "no drift" \
  <<<"echo 'hard_tabs = true' >>rustfmt.toml"
run_case "missing rustfmt key is drift" "use_try_shorthand is missing" "no drift" \
  <<<"sed -i '/use_try_shorthand/d' rustfmt.toml"
run_case "missing file is drift" ".config/nextest.toml is missing" "no drift" \
  <<<"rm .config/nextest.toml"
run_case "extra nextest profile is not drift" "no drift" "::warning" \
  <<<"printf '\n[profile.slow]\nretries = 2\n' >>.config/nextest.toml"
run_case "changed nextest setting is drift" "profile.ci.fail-fast is true" "no drift" \
  <<<"sed -i 's/fail-fast = false/fail-fast = true/' .config/nextest.toml"
run_case "extra lint is not drift" "no drift" "::warning" \
  <<<"sed -i 's/^\[workspace.lints.clippy\]$/[workspace.lints.clippy]\nprint_stdout = \"warn\"/' Cargo.toml"
run_case "weaker lint is drift" 'rust.unsafe_code is "allow"' "no drift" \
  <<<"sed -i 's/unsafe_code = \"forbid\"/unsafe_code = \"allow\"/' Cargo.toml"
run_case "missing lint is drift" "clippy.use_self is missing" "no drift" \
  <<<"sed -i '/^use_self/d' Cargo.toml"
run_case "Cargo.toml without lints is drift" "has no [workspace.lints]" "no drift" \
  <<<"printf '[workspace]\n' >Cargo.toml"
run_case "extra deny entries are not drift" "no drift" "::warning" \
  <<<"sed -i 's/^allow = \[$/allow = [\n  \"MPL-2.0\",/' deny.toml && printf '\n[[licenses.exceptions]]\ncrate = \"x\"\nallow = [\"MPL-2.0\"]\n' >>deny.toml"
run_case "missing licence is drift" 'licenses.allow lacks "ISC"' "no drift" \
  <<<"sed -i '/\"ISC\",/d' deny.toml"
run_case "extra typos words are not drift" "no drift" "::warning" \
  <<<"printf 'nota = \"nota\"\n' >>typos.toml"
run_case "unparsable file is reported, not no drift" "could not read deny.toml" "no drift" \
  <<<"echo 'not = = toml' >>deny.toml"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all drift cases passed"
