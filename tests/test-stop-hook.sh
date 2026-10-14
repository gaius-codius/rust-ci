#!/usr/bin/env bash
# Tests agent/claude-rust-stop.sh with fake hook-input JSON, a throwaway git repo with a
# Cargo workspace, and a fake cargo (FAKE_CARGO_* select its behaviour). No Rust needed.
# Needs bash, git, jq and sha256sum (or shasum).
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${src_root}/agent/claude-rust-stop.sh"
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
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# diag <level> <file> <line> <message> [suggested replacement]: one cargo JSON line.
diag() {
  jq -nc --arg level "$1" --arg file "$2" --argjson line "$3" --arg text "$4" --arg repl "${5:-}" '
    {reason: "compiler-message", message: {
      level: $level, message: $text, code: {code: "clippy::demo"},
      spans: [{file_name: $file, line_start: $line, line_end: $line, column_start: 5, column_end: 9, is_primary: true, label: null, suggested_replacement: null}],
      children: (if $repl == "" then [] else [{level: "help", message: "consider using", spans: [{file_name: $file, line_start: $line, line_end: $line, column_start: 5, column_end: 9, is_primary: true, label: null, suggested_replacement: $repl}]}] end),
      rendered: "rendered"}}'
}

# new_repo: a workspace on main with a commit, then a feature branch with no changes yet.
new_repo() {
  r="${work}/repo"
  rm -rf "${r}" && mkdir -p "${r}/crates/lib/src" "${work}/out"
  git -C "${r}" init -q -b main
  printf '[workspace]\nmembers = ["crates/*"]\n' >"${r}/Cargo.toml"
  printf '[package]\nname = "lib"\nedition = "2024"\n' >"${r}/crates/lib/Cargo.toml"
  printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' >"${r}/crates/lib/src/lib.rs"
  printf 'pub fn old() {}\n' >"${r}/crates/lib/src/old.rs"
  printf 'target/\n' >"${r}/.gitignore"
  git -C "${r}" add -A && git -C "${r}" commit -qm base
  git -C "${r}" checkout -q -b feature
  : >"${FAKE_CARGO_LOG}"
}

# run_case <name> <want exit> <want output substring or ""> <unwanted substring or "">
# Runs the hook in the current repo. EVENT, ACTIVE and HOOK_PATH adjust the input.
run_case() {
  local name="$1" want_code="$2" want="$3" unwanted="$4" out code
  out="$(jq -n --arg c "${r}" --arg e "${EVENT:-Stop}" --argjson a "${ACTIVE:-false}" '{hook_event_name: $e, cwd: $c, stop_hook_active: $a}' |
    PATH="${HOOK_PATH:-${work}/bin:${PATH}}" "${hook}" 2>&1)"
  code=$?
  if [[ ${code} -ne ${want_code} ]] || [[ -n "${want}" && "${out}" != *"${want}"* ]] ||
    [[ -n "${unwanted}" && "${out}" == *"${unwanted}"* ]] ||
    [[ "${EXPECT_SILENT:-}" == 1 && -n "${out}" ]]; then
    echo "FAIL ${name}: exit ${code}, want ${want_code}; output:"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

# silent <name>: expects exit 0 and no output at all.
silent() {
  EXPECT_SILENT=1 run_case "$1" 0 "" ""
  EXPECT_SILENT=
}

# out <lines...>: the fake cargo's stdout for the next calls.
out() {
  : >"${work}/out/cargo.json"
  local l
  for l in "$@"; do printf '%s\n' "${l}" >>"${work}/out/cargo.json"; done
  export FAKE_CARGO_OUT="${work}/out/cargo.json"
}

new_repo
out ""
silent "nothing changed against the merge-base is silent"
if [[ ! -s "${FAKE_CARGO_LOG}" ]]; then echo "ok   cargo is not run when nothing changed"; else
  echo "FAIL cargo was run with nothing changed"; failures=$((failures + 1)); fi

printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\npub fn new() {}\n' >"${r}/crates/lib/src/lib.rs"
out ""
silent "changed Rust files with a clean clippy run are silent"
if grep -qx 'clippy --workspace --all-targets --message-format=json' "${FAKE_CARGO_LOG}"; then echo "ok   cargo runs clippy on the whole workspace, all targets"; else
  echo "FAIL cargo was called with: $(cat "${FAKE_CARGO_LOG}")"; failures=$((failures + 1)); fi

out "$(diag warning crates/lib/src/old.rs 1 'unused thing')"
silent "a warning in an unchanged file is filtered out"

out "$(diag error crates/lib/src/old.rs 1 'cannot find value x')"
FAKE_CARGO_CODE=101 run_case "an error in an unchanged file still blocks (H5)" 2 "crates/lib/src/old.rs:1:5: error: cannot find value x" ""

out "$(diag warning crates/lib/src/lib.rs 2 'this could be better' 'better()')"
run_case "a warning in a changed file blocks and shows the suggested replacement" 2 'replace with `better()`' ""
run_case "the finding names the file and lint" 2 "crates/lib/src/lib.rs:2:5: warning: this could be better [clippy::demo]" ""
if grep -q 'better' "${r}/crates/lib/src/lib.rs"; then echo "FAIL the suggestion was applied"; failures=$((failures + 1)); else echo "ok   the suggestion is not applied"; fi

# Loop protection (H3): same tree and findings.
new_repo
printf 'pub fn new() {}\n' >"${r}/crates/lib/src/lib.rs"
out "$(diag warning crates/lib/src/lib.rs 1 'this could be better')"
run_case "first stop blocks" 2 "this could be better" ""
ACTIVE=true run_case "stop_hook_active with unchanged findings is additionalContext, not a block" 0 '"additionalContext": "rust stop hook: cargo clippy' "systemMessage"
ACTIVE=true run_case "the unchanged findings are not delivered twice (systemMessage only)" 0 '"systemMessage"' "additionalContext"
ACTIVE=true run_case "and stay a systemMessage on every further repeat" 0 '"systemMessage"' "additionalContext"
run_case "a fresh turn (stop_hook_active false) blocks again" 2 "this could be better" ""
printf 'pub fn newer() {}\n' >"${r}/crates/lib/src/lib.rs"
ACTIVE=true run_case "after an edit that leaves the same warning, an active stop blocks again" 2 "this could be better" ""
out "$(diag warning crates/lib/src/lib.rs 1 'a different finding')"
ACTIVE=true run_case "different findings with stop_hook_active block" 2 "a different finding" ""

# SubagentStop has its own state and names its own event.
new_repo
printf 'pub fn new() {}\n' >"${r}/crates/lib/src/lib.rs"
out "$(diag error crates/lib/src/lib.rs 1 'broken')"
FAKE_CARGO_CODE=101 EVENT=SubagentStop run_case "SubagentStop blocks on findings" 2 "broken" ""
FAKE_CARGO_CODE=101 EVENT=SubagentStop ACTIVE=true run_case "SubagentStop repeat reports through SubagentStop additionalContext" 0 '"hookEventName": "SubagentStop"' "systemMessage"
FAKE_CARGO_CODE=101 EVENT=Stop ACTIVE=true run_case "Stop state is separate: an active Stop with no earlier block still blocks" 2 "broken" ""

# H2: committed, staged and untracked changes all count; a Markdown change does not.
new_repo
printf 'docs\n' >"${r}/NOTES.md"
git -C "${r}" add -A && git -C "${r}" commit -qm docs
out "$(diag warning crates/lib/src/lib.rs 1 'x')"
silent "a committed non-Rust change doesn't run clippy"
printf 'pub fn c() {}\n' >"${r}/crates/lib/src/lib.rs"
git -C "${r}" commit -qam "rust"
run_case "a committed Rust change counts" 2 "x" ""
new_repo
printf 'pub fn s() {}\n' >"${r}/crates/lib/src/lib.rs"
git -C "${r}" add -A
run_case "a staged Rust change counts" 2 "x" ""
new_repo
printf 'pub fn u() {}\n' >"${r}/crates/lib/src/extra.rs"
out "$(diag warning crates/lib/src/extra.rs 1 'untracked finding')"
run_case "an untracked Rust file counts" 2 "untracked finding" ""

# Tool failures (H4) never block and are never silent.
new_repo
printf 'pub fn new() {}\n' >"${r}/crates/lib/src/lib.rs"
out ""
FAKE_CARGO_CODE=101 FAKE_CARGO_ERR='error: failed to get `serde` as a dependency: failed to fetch' run_case "a failed dependency fetch is reported, not blocking" 0 "cargo clippy failed (exit 101)" ""
FAKE_CARGO_CODE=101 FAKE_CARGO_ERR='error: failed to get `serde` as a dependency: failed to fetch' run_case "the same failure again goes out as systemMessage only" 0 '"systemMessage"' "additionalContext"
FAKE_CARGO_CODE=101 FAKE_CARGO_ERR='error: no such command: `clippy`' run_case "missing clippy is a tool failure" 0 "no such command" ""
FAKE_CARGO_CODE=134 FAKE_CARGO_ERR='thread panicked: boom' run_case "a cargo crash is a tool failure" 0 "cargo clippy failed (exit 134)" ""
HOOK_PATH="${nocargo}" run_case "missing cargo is reported, not blocking" 0 "cargo not found" ""
start=$SECONDS
FAKE_CARGO_LOCK=1 run_case "a held build lock is reported through additionalContext" 0 "build lock is held" "systemMessage"
if ((SECONDS - start < 15)); then echo "ok   a held build lock is not waited for"; else
  echo "FAIL waited ${SECONDS}s for a held build lock"; failures=$((failures + 1)); fi
FAKE_CARGO_LOCK=1 run_case "the same lock report again is systemMessage only" 0 '"systemMessage"' "additionalContext"

# Not ours to judge.
mkdir -p "${work}/plain" && git -C "${work}/plain" init -q -b main
r="${work}/plain"
silent "a git repo without a Cargo workspace is silent"
r="${work}"
silent "a directory outside git is silent"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"
