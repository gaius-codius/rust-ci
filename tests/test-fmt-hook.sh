#!/usr/bin/env bash
# Tests agent/claude-rust-fmt-on-edit.sh with fake hook-input JSON, a throwaway Cargo
# workspace and a fake rustfmt (FAKE_FMT_* select its behaviour; it logs its arguments).
# Needs bash and jq.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${src_root}/agent/claude-rust-fmt-on-edit.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"
log="${work}/rustfmt.log"
export FAKE_FMT_LOG="${log}"

cat >"${work}/bin/rustfmt" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_FMT_LOG}"
file="${@: -1}"
case "${FAKE_FMT_MODE:-ok}" in
  parse)
    printf 'error: this file contains an unclosed delimiter\n  --> %s:3:12\n   |\n3  | fn x() {\n   |        ^\n' "${file}" >&2
    exit 1 ;;
  config)
    echo 'Error: Invalid value for `style_edition`' >&2
    exit 1 ;;
  crash)
    echo 'thread panicked: boom' >&2
    exit 101 ;;
esac
exit 0
FAKE
chmod +x "${work}/bin/rustfmt"
# The caller's PATH without any directory that has a rustfmt, for the missing-tool case.
norust="$(IFS=:; out=""; for d in ${PATH}; do [[ -x "${d}/rustfmt" ]] || out+="${out:+:}${d}"; done; printf '%s' "${out}")"

failures=0

# new_ws <member manifest body>: a workspace at ${w} with crates/a (its manifest is the
# argument) and a non-Rust file.
new_ws() {
  w="${work}/ws"
  rm -rf "${w}" && mkdir -p "${w}/crates/a/src"
  printf '[workspace]\nmembers = ["crates/*"]\n\n[workspace.package]\nedition = "2024"\n' >"${w}/Cargo.toml"
  printf '%s\n' "$1" >"${w}/crates/a/Cargo.toml"
  printf 'pub fn a() {}\n' >"${w}/crates/a/src/lib.rs"
  printf '# notes\n' >"${w}/NOTES.md"
  : >"${log}"
}

# run_case <name> <edited file, relative to the workspace> <want exit> <want output substring or ""> <unwanted substring or "">
run_case() {
  local name="$1" file="$2" want_code="$3" want="$4" unwanted="$5" out code
  out="$(jq -n --arg f "${w}/${file}" '{tool_name: "Edit", tool_input: {file_path: $f}}' |
    PATH="${HOOK_PATH:-${work}/bin:${PATH}}" "${hook}" 2>&1)"
  code=$?
  if [[ ${code} -ne ${want_code} ]] || [[ -n "${want}" && "${out}" != *"${want}"* ]] ||
    [[ -n "${unwanted}" && "${out}" == *"${unwanted}"* ]]; then
    echo "FAIL ${name}: exit ${code}, want ${want_code}; output:"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

# logged <name> <want log substring>: the last rustfmt call has it.
logged() {
  if [[ "$(tail -1 "${log}")" == *"$2"* ]]; then echo "ok   $1"; else
    echo "FAIL $1: rustfmt was called with: $(tail -1 "${log}")"; failures=$((failures + 1)); fi
}

new_ws '[package]
name = "a"
edition.workspace = true'
run_case "clean edit exits 0 quietly" crates/a/src/lib.rs 0 "" "rust fmt hook"
logged "inherited workspace edition is passed to rustfmt" "--edition 2024"

new_ws '[package]
name = "a"
version = "0.1.0"
edition = "2021" # older
'
run_case "package edition is used" crates/a/src/lib.rs 0 "" "rust fmt hook"
logged "package edition beats the workspace's" "--edition 2021"

new_ws '[package]
name = "a"
edition = { workspace = true }'
run_case "inline workspace edition inherits" crates/a/src/lib.rs 0 "" "rust fmt hook"
logged "inline workspace = true gives the workspace edition" "--edition 2024"

new_ws '[package]
name = "a"
edition = "2021"'
run_case "non-Rust file is ignored" NOTES.md 0 "" "rust fmt hook"
run_case "missing file is ignored" crates/a/src/nope.rs 0 "" "rust fmt hook"

new_ws '[package]
name = "a"
edition = "2021"'
printf '[package]\nname = "a"\n' >"${w}/crates/a/Cargo.toml"
printf '[workspace]\nmembers = ["crates/*"]\n' >"${w}/Cargo.toml"
run_case "no edition anywhere is reported, not silent" crates/a/src/lib.rs 0 "no edition found" ""

new_ws '[package]
name = "a"
edition = "2021"'
FAKE_FMT_MODE=parse run_case "a file that does not parse exits 2 with rustfmt's message" crates/a/src/lib.rs 2 "unclosed delimiter" ""
FAKE_FMT_MODE=config run_case "a rustfmt config failure does not block" crates/a/src/lib.rs 0 "rustfmt failed (exit 1)" ""
FAKE_FMT_MODE=crash run_case "a rustfmt crash does not block" crates/a/src/lib.rs 0 "rustfmt failed (exit 101)" ""
HOOK_PATH="${norust}" run_case "missing rustfmt does not block" crates/a/src/lib.rs 0 "rustfmt is not on PATH" ""
HOOK_PATH="${norust}" run_case "missing rustfmt is a PostToolUse additionalContext" crates/a/src/lib.rs 0 '"additionalContext"' ""

mkdir -p "${work}/loose" && printf 'fn main() {}\n' >"${work}/loose/x.rs"
w="${work}/loose"
run_case "a .rs file outside any Cargo package is ignored" x.rs 0 "" "rust fmt hook"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"
