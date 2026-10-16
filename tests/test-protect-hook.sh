#!/usr/bin/env bash
# Tests agent/claude-rust-protect-config.sh with fake PreToolUse hook-input JSON and a
# throwaway git repo with a Cargo workspace. Needs bash, git and jq.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${src_root}/agent/claude-rust-protect-config.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
# A PATH with the tools the hook uses but no jq, for the missing-tool case (jq often
# shares /usr/bin with bash, so dropping its directory isn't enough).
mkdir -p "${work}/nojq"
for t in bash env git realpath dirname basename sed head grep cat; do
  ln -s "$(command -v "${t}")" "${work}/nojq/${t}"
done
nojq="${work}/nojq"

failures=0
unset RUST_CI_PROTECT_CONFIG
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# new_repo: a git repo at ${r} with a Cargo workspace, a lints table, a crate and some
# config files.
new_repo() {
  r="${work}/repo"
  rm -rf "${r}" && mkdir -p "${r}/crates/lib/src" "${r}/.github/workflows"
  git -C "${r}" init -q -b main
  printf '[workspace]\nmembers = ["crates/*"]\n\n[workspace.dependencies]\nserde = "1"\n\n[workspace.lints.clippy]\nunwrap_used = "deny"\n' >"${r}/Cargo.toml"
  printf '[package]\nname = "lib"\nedition = "2024"\n\n[dependencies]\nserde.workspace = true\n\n[lints]\nworkspace = true\n' >"${r}/crates/lib/Cargo.toml"
  printf '#[allow(dead_code)]\nfn old() {}\n\npub fn a() {}\n' >"${r}/crates/lib/src/lib.rs"
  printf '[bans]\n' >"${r}/deny.toml"
  printf 'name: ci\n' >"${r}/.github/workflows/ci.yml"
}

# run_json <name> <hook input JSON> <want: ask | silent | context> [want substring]
run_json() {
  local name="$1" json="$2" want="$3" sub="${4:-}" out code ok=1
  out="$(printf '%s' "${json}" | (cd "${r}" && PATH="${HOOK_PATH:-${PATH}}" "${hook}") 2>&1)"
  code=$?
  [[ ${code} -eq 0 ]] || ok=0
  case "${want}" in
    ask) [[ "${out}" == *'"permissionDecision": "ask"'* && "${out}" == *'"hookEventName": "PreToolUse"'* ]] || ok=0 ;;
    silent) [[ -z "${out}" ]] || ok=0 ;;
    context) [[ "${out}" == *'"additionalContext"'* && "${out}" != *permissionDecision* ]] || ok=0 ;;
  esac
  [[ -z "${sub}" || "${out}" == *"${sub}"* ]] || ok=0
  if ((ok)); then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: exit ${code}, want ${want}; output:"
    printf '%s\n' "${out}" | sed 's/^/    /'
    failures=$((failures + 1))
  fi
}

# edit <name> <file, relative to the repo> <old> <new> <want> [substring]
edit() {
  run_json "$1" "$(jq -n --arg f "${r}/$2" --arg o "$3" --arg n "$4" --arg c "${r}" \
    '{hook_event_name: "PreToolUse", cwd: $c, tool_name: "Edit", tool_input: {file_path: $f, old_string: $o, new_string: $n}}')" "$5" "${6:-}"
}

# write <name> <file, relative to the repo> <content> <want> [substring]
write() {
  run_json "$1" "$(jq -n --arg f "${r}/$2" --arg n "$3" --arg c "${r}" \
    '{hook_event_name: "PreToolUse", cwd: $c, tool_name: "Write", tool_input: {file_path: $f, content: $n}}')" "$4" "${5:-}"
}

# bash_cmd <name> <command> <want> [substring]
bash_cmd() {
  run_json "$1" "$(jq -n --arg cmd "$2" --arg c "${r}" \
    '{hook_event_name: "PreToolUse", cwd: $c, tool_name: "Bash", tool_input: {command: $cmd}}')" "$3" "${4:-}"
}

new_repo

# Every protected path asks, for Edit and Write, existing or new.
for p in deny.toml clippy.toml .clippy.toml crates/lib/clippy.toml rustfmt.toml .rustfmt.toml \
  rust-toolchain.toml rust-toolchain .config/nextest.toml typos.toml _typos.toml .typos.toml \
  .github/workflows/ci.yml .github/workflows/new.yml .github/actions/pre-test/action.yml \
  .github/actions/a/b/c.sh lefthook.yml .gitleaks.toml .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
  write "Write to ${p} asks" "${p}" 'x = 1' ask "${p} controls the project's checks"
done
edit "Edit to deny.toml asks" deny.toml '[bans]' '[bans]
multiple-versions = "allow"' ask "deny.toml controls"
edit "the reason names the opt-out" deny.toml '[bans]' '' ask "RUST_CI_PROTECT_CONFIG=off"
ln -s deny.toml "${r}/deny-link.toml"
mkdir -p "${r}/baseline" && printf 'x\n' >"${r}/baseline/clippy.toml.src"
ln -s baseline/clippy.toml.src "${r}/clippy.toml"
edit "a symlinked config file is judged by its own name" clippy.toml 'x' 'y' ask "clippy.toml controls"
edit "a relative file path is resolved against cwd" "crates/../deny.toml" '[bans]' '' ask "deny.toml controls"
rm -f "${r}/clippy.toml" "${r}/deny-link.toml"

# Cargo.toml: only the lints tables.
edit "Cargo.toml edit outside lints does not ask" Cargo.toml 'serde = "1"' 'serde = "1.0.200"' silent
edit "Cargo.toml edit inside [workspace.lints.clippy] asks" Cargo.toml 'unwrap_used = "deny"' 'unwrap_used = "allow"' ask "[workspace.lints]"
edit "a member's [lints] removal asks" crates/lib/Cargo.toml '[lints]
workspace = true
' '' ask "crates/lib/Cargo.toml"
edit "adding a lints key asks" crates/lib/Cargo.toml 'serde.workspace = true' 'serde.workspace = true
[lints.rust]
unsafe_code = "allow"' ask
edit "an old text not in the file asks (unsure)" Cargo.toml 'not = "there"' 'x' ask "can't tell"
edit "a member's dependency edit does not ask" crates/lib/Cargo.toml 'serde.workspace = true' 'serde = "1"' silent
write "Write of Cargo.toml with the same lints does not ask" Cargo.toml "$(cat "${r}/Cargo.toml")
[workspace.package]
edition = \"2024\"" silent
write "Write of Cargo.toml that drops the lints asks" Cargo.toml '[workspace]
members = ["crates/*"]
' ask "[workspace.lints]"
write "Write of a member Cargo.toml without [lints] asks" crates/lib/Cargo.toml '[package]
name = "lib"
' ask
run_json "MultiEdit with one edit in the lints table asks" "$(jq -n --arg f "${r}/Cargo.toml" \
  '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "serde = \"1\"", new_string: "serde = \"2\""}, {old_string: "unwrap_used = \"deny\"", new_string: "unwrap_used = \"warn\""}]}}')" ask
run_json "MultiEdit outside the lints table does not ask" "$(jq -n --arg f "${r}/Cargo.toml" \
  '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "serde = \"1\"", new_string: "serde = \"2\""}]}}')" silent

# .rs files: adding a suppression asks, removing one or a normal edit doesn't.
edit "an edit adding #[allow( asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[allow(clippy::unwrap_used)]
pub fn a() {}' ask "#[allow("
edit "an edit adding #![allow( asks" crates/lib/src/lib.rs 'pub fn a() {}' '#![allow(warnings)]
pub fn a() {}' ask "#![allow("
edit "an edit adding #[expect( asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[expect(dead_code)] pub fn a() {}' ask
edit "an edit adding a cfg_attr allow asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[cfg_attr(test, allow(dead_code))] pub fn a() {}' ask
edit "an edit adding #[ignore] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[test]
#[ignore = "flaky"]
fn t() {}' ask "#[ignore"
edit "an edit adding #[cfg(any())] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[cfg(any())]
pub fn a() {}' ask
edit "an edit adding #[cfg(not(all()))] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[cfg(not(all()))] pub fn a() {}' ask
edit "an edit removing #[allow( does not ask" crates/lib/src/lib.rs '#[allow(dead_code)]
fn old() {}' 'fn old() {}' silent
edit "an edit keeping an existing #[allow( does not ask" crates/lib/src/lib.rs '#[allow(dead_code)]
fn old() {}' '#[allow(dead_code)]
fn older() {}' silent
edit "a normal .rs edit does not ask" crates/lib/src/lib.rs 'pub fn a() {}' 'pub fn a() -> u8 { 1 }' silent
write "a Write keeping the same suppressions does not ask" crates/lib/src/lib.rs '#[allow(dead_code)]
fn old() {}
pub fn b() {}' silent
write "a Write adding a suppression asks" crates/lib/src/lib.rs '#[allow(dead_code)]
fn old() {}
#[allow(unused)]
pub fn b() {}' ask
write "a new .rs file with #[ignore] asks" crates/lib/src/new.rs '#[test] #[ignore] fn t() {}' ask
run_json "a MultiEdit adding a suppression asks" "$(jq -n --arg f "${r}/crates/lib/src/lib.rs" \
  '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "pub fn a() {}", new_string: "#[allow(unused)] pub fn a() {}"}]}}')" ask

# Other files and tools.
write "a Markdown file does not ask" NOTES.md '# notes' silent
write "a file under .github outside workflows and actions does not ask" .github/dependabot.yml 'version: 2' silent
run_json "NotebookEdit is not judged" "$(jq -n --arg f "${r}/n.ipynb" '{tool_name: "NotebookEdit", tool_input: {notebook_path: $f, new_source: "x"}}')" silent

# Bash, best effort.
bash_cmd "sed -i on deny.toml asks" "sed -i 's/deny/allow/' deny.toml" ask "this command looks like it changes"
bash_cmd "a redirect into rustfmt.toml asks" "printf 'x\\n' > rustfmt.toml" ask
bash_cmd "tee into a workflow asks" "echo x | tee .github/workflows/ci.yml" ask
bash_cmd "rm of a workflow directory asks" "rm -rf .github/workflows" ask
bash_cmd "git checkout of clippy.toml asks" "git checkout main -- clippy.toml" ask
bash_cmd "sed -i on Cargo.toml lints asks" "sed -i '/\\[workspace.lints/,\$d' Cargo.toml" ask "lints tables"
bash_cmd "appending #[allow( to a .rs file asks" "printf '#[allow(dead_code)]\\n' >> crates/lib/src/lib.rs" ask
bash_cmd "reading deny.toml does not ask" "cat deny.toml | grep bans" silent
bash_cmd "cargo test does not ask" "cargo test --workspace 2>&1 | tail" silent
bash_cmd "sed -i on Cargo.toml dependencies does not ask" "sed -i 's/serde = \"1\"/serde = \"2\"/' Cargo.toml" silent
bash_cmd "a .rs write without a suppression does not ask" "printf 'fn x() {}\\n' >> crates/lib/src/lib.rs" silent

# Opt-out.
export RUST_CI_PROTECT_CONFIG=off
write "RUST_CI_PROTECT_CONFIG=off turns the hook off" deny.toml 'x' silent
bash_cmd "RUST_CI_PROTECT_CONFIG=off turns Bash checks off" "sed -i 's/a/b/' deny.toml" silent
unset RUST_CI_PROTECT_CONFIG

# A tool failure never asks and is never silent.
HOOK_PATH="${nojq}" write "missing jq is reported through additionalContext" deny.toml 'x' context "jq is not on PATH"
HOOK_PATH="${nojq}" write "missing jq is quiet for a file that isn't ours" NOTES.md 'x' silent
run_json "unreadable input is reported, not asked" '{not json' context "could not read the hook input"

# Not ours to judge.
p="${work}/plain"
mkdir -p "${p}/.github/workflows" && git -C "${p}" init -q -b main
r="${p}"
write "a non-Rust repo is ignored" .github/workflows/ci.yml 'x' silent
write "deny.toml in a non-Rust repo is ignored" deny.toml 'x' silent
bash_cmd "Bash in a non-Rust repo is ignored" "sed -i 's/a/b/' deny.toml" silent
mkdir -p "${p}/sub" && printf '[package]\nname = "sub"\n' >"${p}/sub/Cargo.toml"
write "a crate below a non-Rust repo root is ignored" sub/clippy.toml 'x' silent

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"
