#!/usr/bin/env bash
# Tests agent/claude-rust-check-on-edit.sh with fake hook-input JSON, a throwaway Cargo
# workspace and a fake cargo (FAKE_CARGO_* select its behaviour). No Rust needed.
# Needs bash and jq.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${src_root}/agent/claude-rust-check-on-edit.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"
export FAKE_CARGO_LOG="${work}/cargo.log"

cat >"${work}/bin/cargo" <<'FAKE'
#!/usr/bin/env bash
# Prints FAKE_CARGO_OUT (a file of JSON lines) and FAKE_CARGO_ERR (text), exits
# FAKE_CARGO_CODE. FAKE_CARGO_LOCK=1 behaves like a held build lock.
printf '%s\n' "$*" >>"${FAKE_CARGO_LOG}"
if [[ -n "${FAKE_CARGO_LOCK:-}" ]]; then
  echo '    Blocking waiting for file lock on build directory' >&2
  sleep 30
  exit 0
fi
[[ -n "${FAKE_CARGO_OUT:-}" ]] && cat "${FAKE_CARGO_OUT}"
[[ -n "${FAKE_CARGO_ERR:-}" ]] && printf '%s\n' "${FAKE_CARGO_ERR}" >&2
exit "${FAKE_CARGO_CODE:-0}"
FAKE
chmod +x "${work}/bin/cargo"
# The caller's PATH without any directory that has a cargo, for the missing-tool case.
nocargo="$(IFS=:; out=""; for d in ${PATH}; do [[ -x "${d}/cargo" ]] || out+="${out:+:}${d}"; done; printf '%s' "${out}")"

failures=0

# diag <level> <file> <line> <message>: one cargo JSON line.
diag() {
  jq -nc --arg level "$1" --arg file "$2" --argjson line "$3" --arg text "$4" '
    {reason: "compiler-message", message: {
      level: $level, message: $text, code: {code: "E0308"},
      spans: [{file_name: $file, line_start: $line, line_end: $line, column_start: 5, column_end: 9, is_primary: true, label: "expected u32", suggested_replacement: null}],
      children: [], rendered: "rendered"}}'
}

# out <lines...>: the fake cargo's stdout for the next calls.
out() {
  : >"${work}/cargo.json"
  local l
  for l in "$@"; do printf '%s\n' "${l}" >>"${work}/cargo.json"; done
  export FAKE_CARGO_OUT="${work}/cargo.json"
}

w="${work}/ws"
rm -rf "${w}" && mkdir -p "${w}/crates/lib/src" "${w}/crates/app/src"
printf '[workspace]\nmembers = ["crates/*"]\n' >"${w}/Cargo.toml"
printf '[package]\nname = "lib"\n' >"${w}/crates/lib/Cargo.toml"
printf '[package]\nname = "app"\n' >"${w}/crates/app/Cargo.toml"
printf 'pub fn a() {}\n' >"${w}/crates/lib/src/lib.rs"
printf 'fn main() { lib::a(); }\n' >"${w}/crates/app/src/main.rs"
printf '# notes\n' >"${w}/NOTES.md"

# run_case <name> <edited file, relative to the workspace> <want exit> <want output substring or ""> <unwanted substring or "">
run_case() {
  local name="$1" file="$2" want_code="$3" want="$4" unwanted="$5" o code
  o="$(jq -n --arg f "${w}/${file}" '{tool_name: "Edit", tool_input: {file_path: $f}}' |
    PATH="${HOOK_PATH:-${work}/bin:${PATH}}" "${hook}" 2>&1)"
  code=$?
  if [[ ${code} -ne ${want_code} ]] || [[ -n "${want}" && "${o}" != *"${want}"* ]] ||
    [[ -n "${unwanted}" && "${o}" == *"${unwanted}"* ]]; then
    echo "FAIL ${name}: exit ${code}, want ${want_code}; output:"
    printf '%s\n' "${o}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

out ""
: >"${FAKE_CARGO_LOG}"
run_case "clean edit exits 0 quietly" crates/lib/src/lib.rs 0 "" "rust check hook"
if grep -qx 'check --workspace --message-format=json' "${FAKE_CARGO_LOG}"; then echo "ok   cargo checks the whole workspace"; else
  echo "FAIL cargo was called with: $(cat "${FAKE_CARGO_LOG}")"; failures=$((failures + 1)); fi

: >"${FAKE_CARGO_LOG}"
run_case "non-Rust file is ignored" NOTES.md 0 "" "rust check hook"
run_case "missing file is ignored" crates/lib/src/nope.rs 0 "" "rust check hook"
if [[ ! -s "${FAKE_CARGO_LOG}" ]]; then echo "ok   cargo is not run for them"; else
  echo "FAIL cargo was run for a non-Rust edit"; failures=$((failures + 1)); fi

out "$(diag error crates/app/src/main.rs 1 'this function takes 1 argument')"
FAKE_CARGO_CODE=101 run_case "a broken caller in another crate exits 2 and names it" crates/lib/src/lib.rs 2 "crates/app/src/main.rs:1:5: error: this function takes 1 argument [E0308]" ""
FAKE_CARGO_CODE=101 run_case "the span label is shown" crates/lib/src/lib.rs 2 "expected u32" ""

out "$(diag warning crates/lib/src/lib.rs 1 'unused variable')"
run_case "a warning in the edited file exits 2" crates/lib/src/lib.rs 2 "unused variable" ""
out "$(diag warning crates/app/src/main.rs 1 'elsewhere')"
run_case "a warning in another file is filtered out" crates/lib/src/lib.rs 0 "" "elsewhere"

out ""
FAKE_CARGO_CODE=101 FAKE_CARGO_ERR='error: failed to get `serde` as a dependency' run_case "a failed dependency fetch does not block" crates/lib/src/lib.rs 0 "cargo check failed (exit 101)" ""
FAKE_CARGO_CODE=134 FAKE_CARGO_ERR='thread panicked: boom' run_case "a cargo crash does not block" crates/lib/src/lib.rs 0 "cargo check failed (exit 134)" ""
HOOK_PATH="${nocargo}" run_case "missing cargo does not block" crates/lib/src/lib.rs 0 "cargo check failed (exit 127)" ""
start=$SECONDS
FAKE_CARGO_LOCK=1 run_case "a held build lock is reported, not blocking" crates/lib/src/lib.rs 0 "build lock is held" ""
if ((SECONDS - start < 15)); then echo "ok   a held build lock is not waited for"; else
  echo "FAIL waited ${SECONDS}s for a held build lock"; failures=$((failures + 1)); fi

mkdir -p "${work}/loose" && printf 'fn main() {}\n' >"${work}/loose/x.rs"
w="${work}/loose"
run_case "a .rs file outside any Cargo package is ignored" x.rs 0 "" "rust check hook"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"
