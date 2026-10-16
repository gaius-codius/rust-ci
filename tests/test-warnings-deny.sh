#!/usr/bin/env bash
# Tests that CARGO_BUILD_WARNINGS=deny, which every rust.yml job sets, turns the
# baseline's "warn" lints into a failed build. Runs clippy on a copy of the
# fixture workspace with code planted that a baseline lint flags. Needs the
# toolchain from rust-toolchain.toml; no network.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

w="${work}/ws"
mkdir -p "${w}"
# -L copies the baseline files the fixture symlinks to.
cp -RL "${src_root}/Cargo.toml" "${src_root}/Cargo.lock" "${src_root}/rust-toolchain.toml" "${src_root}/crates" "${w}/"
for f in clippy.toml .clippy.toml; do
  [[ -e "${src_root}/${f}" ]] && cp -L "${src_root}/${f}" "${w}/"
done
lib="${w}/crates/fixture/src/lib.rs"
cp "${lib}" "${work}/lib.rs.orig"
export CARGO_TARGET_DIR="${work}/target" CARGO_NET_OFFLINE=true CARGO_TERM_COLOR=never

failures=0

# run_case <name> <code planted in lib.rs, before the test module, or ""> <CARGO_BUILD_WARNINGS> <want exit: 0 or nonzero> <want output substring or "">
run_case() {
  local name="$1" planted="$2" warnings="$3" want="$4" want_out="$5" o code ok=1
  {
    sed '/^#\[cfg(test)\]/,$d' "${work}/lib.rs.orig"
    [[ -n "${planted}" ]] && printf '%s\n\n' "${planted}"
    sed -n '/^#\[cfg(test)\]/,$p' "${work}/lib.rs.orig"
  } >"${lib}"
  o="$(cd "${w}" && CARGO_BUILD_WARNINGS="${warnings}" cargo clippy --workspace --all-targets --locked 2>&1)"
  code=$?
  if [[ "${want}" == 0 ]]; then [[ ${code} -eq 0 ]] || ok=0; else [[ ${code} -ne 0 ]] || ok=0; fi
  [[ -z "${want_out}" || "${o}" == *"${want_out}"* ]] || ok=0
  if [[ ${ok} -eq 1 ]]; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: exit ${code}, want ${want}; output:"
    printf '%s\n' "${o}" | sed 's/^/    /'
    failures=$((failures + 1))
  fi
}

unwrap='/// Parses `s`.
///
/// # Panics
///
/// If `s` is not a number.
#[must_use]
pub fn parse(s: &str) -> u32 {
    s.parse().unwrap()
}'
ignored='/// Parses `s`, dropping the error.
pub fn parse_or_nothing(s: &str) {
    let _ = s.parse::<u32>();
}'

run_case "the clean fixture passes with warnings denied" "" deny 0 ""
run_case "an unwrap fails with warnings denied" "${unwrap}" deny nonzero "warnings are denied"
run_case "the unwrap is reported as clippy::unwrap_used" "${unwrap}" deny nonzero "#unwrap_used"
run_case "a dropped Result fails with warnings denied" "${ignored}" deny nonzero "#let_underscore_must_use"
run_case "the same unwrap only warns without deny" "${unwrap}" warn 0 "#unwrap_used"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"
