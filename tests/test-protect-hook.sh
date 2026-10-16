#!/usr/bin/env bash
# Tests agent/claude-rust-protect-config.sh, which runs weakened-checks' hook and
# rust-ci's own (agent/rust-protect-remainder.sh) and combines them, with fake
# PreToolUse hook-input JSON and a throwaway git repo with a Cargo workspace. Needs
# bash, git and jq, and weakened-checks: WEAKENED_CHECKS_DIR (a clone at the commit
# below), else a clone from GitHub, so an offline run needs WEAKENED_CHECKS_DIR.
set -uo pipefail

# weakened-checks v1.1.0, the release the wrapper was written against.
wc_commit=534b261dbad4e995e1575d7f8f2de0d6abfb0fb7

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
hook="${src_root}/agent/claude-rust-protect-config.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
if [[ -z ${WEAKENED_CHECKS_DIR:-} ]]; then
  WEAKENED_CHECKS_DIR="${work}/weakened-checks"
  git -c advice.detachedHead=false clone -q --depth 1 --branch v1.1.0 https://github.com/gaius-codius/weakened-checks "${WEAKENED_CHECKS_DIR}" ||
    { echo "FAIL could not clone weakened-checks; set WEAKENED_CHECKS_DIR to a clone at ${wc_commit}"; exit 1; }
fi
got="$(git -C "${WEAKENED_CHECKS_DIR}" rev-parse HEAD 2>/dev/null)"
[[ ${got} == "${wc_commit}" ]] || { echo "FAIL ${WEAKENED_CHECKS_DIR} is at ${got:-nothing}, want ${wc_commit}"; exit 1; }
shared="${WEAKENED_CHECKS_DIR}/agent/claude-protect-config.sh"
# The developer's own hooks and settings stay out of it.
export HOME="${work}/home" WEAKENED_CHECKS_HOOK="${shared}"
mkdir -p "${HOME}"
unset WEAKENED_CHECKS_PROTECT_CONFIG
# A PATH with the tools the hook uses but no jq, for the missing-tool case (jq often
# shares /usr/bin with bash, so dropping its directory isn't enough).
mkdir -p "${work}/nojq"
for t in bash env git realpath readlink dirname basename sed head grep cat mktemp rm tr cut sort uniq timeout mkdir wc awk; do
  ln -s "$(command -v "${t}")" "${work}/nojq/${t}"
done
nojq="${work}/nojq"
# A PATH whose python3 has no tomllib (before 3.11), for the Cargo.toml line
# heuristic. A stub in front, since jq may be a shim that can't be linked elsewhere.
mkdir -p "${work}/oldpy"
printf '#!/bin/sh\nexit 3\n' >"${work}/oldpy/python3" && chmod +x "${work}/oldpy/python3"
nopy="${work}/oldpy:${PATH}"

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
  # Whatever it says is one JSON object.
  [[ -z "${out}" ]] || jq -e -s 'length == 1 and (.[0].hookSpecificOutput | type) == "object"' <<<"${out}" >/dev/null 2>&1 || ok=0
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
  .github/actions/a/b/c.sh lefthook.yml .gitleaks.toml .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS \
  lefthook.yaml .lefthook.yml lefthook-local.yml lefthook-local.yaml .gitleaksignore \
  .cargo/config .cargo/config.toml crates/lib/.cargo/config.toml .cargo/mutants.toml \
  .gitattributes crates/lib/.gitattributes build.rs crates/lib/build.rs \
  .github/zizmor.yml .github/zizmor.yaml .github/actionlint.yml .github/actionlint.yaml; do
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
edit "adding a [profile] setting asks" Cargo.toml 'serde = "1"' 'serde = "1"

[profile.release]
overflow-checks = false' ask "[profile]"
# weakened-checks' hook compares the lints lines, not the parsed tables.
write "Write of Cargo.toml with the lints spelled another way asks (weakened-checks' hook)" Cargo.toml '[workspace]
members = ["crates/*"]

[workspace.dependencies]
serde = "1"

[workspace.lints]
clippy.unwrap_used = "deny"
' ask "weakened-checks hook"

# Cargo.toml: dotted lints keys, where the table they sit under decides.
mkdir -p "${r}/crates/dot"
printf '# dot crate\nlints.clippy.unwrap_used = "deny"\n\n[package]\nname = "dot"\n' >"${r}/crates/dot/Cargo.toml"
dot_moved='[package.metadata]
lints.clippy.unwrap_used = "deny"

[package]
name = "dot"
'
write "a Write moving a dotted lints key under another table asks" crates/dot/Cargo.toml "# dot crate
${dot_moved}" ask "[lints]"
edit "an Edit putting a table header above a dotted lints key asks" crates/dot/Cargo.toml '# dot crate' '# dot crate
[package.metadata]' ask "[lints]"
edit "an Edit below the dotted lints key outside lints does not ask" crates/dot/Cargo.toml 'name = "dot"' 'name = "dots"' silent

# Without tomllib (or python3), the line heuristic stands in.
HOOK_PATH="${nopy}" write "no tomllib: moving a dotted lints key asks" crates/dot/Cargo.toml "# dot crate
${dot_moved}" ask "[lints]"
HOOK_PATH="${nopy}" write "no tomllib: a new table header asks" Cargo.toml "$(cat "${r}/Cargo.toml")
[workspace.package]
edition = \"2024\"" ask
HOOK_PATH="${nopy}" write "no tomllib: dropping the lints asks" Cargo.toml '[workspace]
members = ["crates/*"]
' ask
HOOK_PATH="${nopy}" write "no tomllib: the same tables and lints do not ask" Cargo.toml "$(cat "${r}/Cargo.toml")
" silent
HOOK_PATH="${nopy}" edit "no tomllib: an edit adding a table header asks" crates/lib/Cargo.toml 'serde.workspace = true' 'serde.workspace = true
[package.metadata]' ask
HOOK_PATH="${nopy}" edit "no tomllib: a dependency edit does not ask" crates/lib/Cargo.toml 'serde.workspace = true' 'serde = "1"' silent

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

# .rs files: a suppression swapped for a wider one, or a lint list widened, is added.
s_rs='#[expect(clippy::x, reason = "why")]
fn e() {}
#[deny(clippy::unwrap_used)]
fn d() {}
#[allow(dead_code)]
fn a() {}
#[expect(dead_code)]
fn w() {}
'
printf '%s' "${s_rs}" >"${r}/crates/lib/src/s.rs"
edit "an #[expect] swapped for #![allow(warnings)] asks" crates/lib/src/s.rs '#[expect(clippy::x, reason = "why")]' '#![allow(warnings)]' ask "#![allow(warnings)]"
write "a Write swapping an #[expect] for a crate-wide one asks" crates/lib/src/s.rs "${s_rs/'#[expect(dead_code)]'/'#![expect(clippy::pedantic, reason = "x")]'}" ask "clippy::pedantic"
edit "a #[deny] turned into #[allow] asks" crates/lib/src/s.rs '#[deny(clippy::unwrap_used)]' '#[allow(clippy::unwrap_used)]' ask "#[allow(clippy::unwrap_used)]"
edit "a lint added to an #[allow] list asks" crates/lib/src/s.rs '#[allow(dead_code)]' '#[allow(dead_code, clippy::unwrap_used)]' ask
edit "a lint added inside an attribute, without its #[, asks" crates/lib/src/s.rs 'dead_code)]
fn a' 'dead_code, clippy::unwrap_used)]
fn a' ask
# weakened-checks' hook compares the attribute as written, so respacing asks there.
edit "respacing an #[allow] asks (weakened-checks' hook)" crates/lib/src/s.rs '#[allow(dead_code)]' '#[allow( dead_code )]' ask "weakened-checks hook"
write "a Write moving the suppressions around does not ask" crates/lib/src/s.rs "fn z() {}
${s_rs}" silent
run_json "a MultiEdit swapping one #[allow] for another asks" "$(jq -n --arg f "${r}/crates/lib/src/s.rs" \
  '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "#[allow(dead_code)]\n", new_string: ""}, {old_string: "fn w() {}", new_string: "fn w() {}\n#[allow(unused)] fn u() {}"}]}}')" ask "#[allow(unused)]"
run_json "a MultiEdit moving an #[allow] does not ask" "$(jq -n --arg f "${r}/crates/lib/src/s.rs" \
  '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "#[allow(dead_code)]\nfn a() {}\n", new_string: ""}, {old_string: "fn w() {}", new_string: "fn w() {}\n#[allow(dead_code)]\nfn a() {}"}]}}')" silent
for i in $(seq 3000); do printf '#[allow(dead_code)]\nfn f%d() { let _x = [1, 2]; }\n' "${i}"; done >"${r}/crates/lib/src/big.rs"
edit "a large file (over the argument size limit) is still judged" crates/lib/src/big.rs 'fn f10()' '#[allow(warnings)]
fn f10()' ask "#[allow(warnings)]"
edit "a large file's normal edit does not ask" crates/lib/src/big.rs 'fn f10()' 'fn g10()' silent

# Removing or narrowing a deny, forbid or warn attribute asks; moving one doesn't.
d_rs='#![forbid(unsafe_code)]
#![deny(clippy::unwrap_used, clippy::expect_used)]

#[warn(missing_docs)]
pub fn a() {}
'
printf '%s' "${d_rs}" >"${r}/crates/lib/src/d.rs"
edit "removing a #![forbid] asks" crates/lib/src/d.rs '#![forbid(unsafe_code)]
' '' ask "#![forbid(unsafe_code)]"
edit "narrowing a #![deny] list asks" crates/lib/src/d.rs 'clippy::unwrap_used, clippy::expect_used' 'clippy::unwrap_used' ask "#![deny("
edit "turning #[warn] into #[allow] asks" crates/lib/src/d.rs '#[warn(missing_docs)]' '#[allow(missing_docs)]' ask
edit "respacing a #![deny] does not ask" crates/lib/src/d.rs '#![deny(clippy::unwrap_used, clippy::expect_used)]' '#![deny( clippy::unwrap_used,  clippy::expect_used )]' silent
edit "an unrelated edit next to a #![deny] does not ask" crates/lib/src/d.rs 'pub fn a() {}' 'pub fn b() {}' silent
write "a Write dropping a #![deny] asks" crates/lib/src/d.rs '#![forbid(unsafe_code)]

#[warn(missing_docs)]
pub fn a() {}
' ask "#![deny("
write "a Write moving the lint attributes does not ask" crates/lib/src/d.rs "// moved
${d_rs}" silent
edit "an edit whose old text isn't in the file is judged on its own text" crates/lib/src/d.rs '#![deny(clippy::panic)]' '' ask "#![deny(clippy::panic)]"
bash_cmd "sed -i deleting a deny line asks" "sed -i '/deny(/d' crates/lib/src/d.rs" ask "deny or forbid"
bash_cmd "grep for deny in a .rs file does not ask" "grep -n deny crates/lib/src/d.rs" silent

# .rs files: other ways to make a test or a lint go away.
edit "an edit adding #[should_panic] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[test] #[should_panic] fn t() {}' ask "#[should_panic]"
edit "an edit adding #[should_panic(expected)] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[test]
#[should_panic(expected = "boom")]
fn t() {}' ask
edit "an edit adding #[rustfmt::skip] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[rustfmt::skip] pub fn a() {}' ask
edit "an edit adding #[cfg(miri)] asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[cfg(miri)] pub fn a() {}' ask
edit "an edit adding a cfg_attr ignore asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[test] #[cfg_attr(miri, ignore)] fn t() {}' ask
edit "an edit adding #[ ignore ] with spaces asks" crates/lib/src/lib.rs 'pub fn a() {}' '#[test] # [ ignore ] fn t() {}' ask
edit "an edit adding #[cfg(windows)] does not ask (too common outside tests)" crates/lib/src/lib.rs 'pub fn a() {}' '#[cfg(windows)] pub fn a() {}' silent
edit "an edit adding #[cfg(test)] does not ask" crates/lib/src/lib.rs 'pub fn a() {}' '#[cfg(test)] mod tests {}' silent
edit "an edit adding gitleaks:allow to a .rs file asks" crates/lib/src/lib.rs 'pub fn a() {}' 'const K: &str = "k"; // gitleaks:allow' ask "gitleaks:allow"
write "a Markdown file gaining gitleaks:allow asks" NOTES.md 'token: abc <!-- gitleaks:allow -->' ask "gitleaks:allow"
write "a Cargo.toml gaining gitleaks:allow asks" crates/lib/Cargo.toml "$(cat "${r}/crates/lib/Cargo.toml")
# gitleaks:allow" ask "gitleaks:allow"

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
bash_cmd "sed -i on Cargo.toml lints asks" "sed -i '/\\[workspace.lints/,\$d' Cargo.toml" ask "[lints]"
bash_cmd "appending #[allow( to a .rs file asks" "printf '#[allow(dead_code)]\\n' >> crates/lib/src/lib.rs" ask
bash_cmd "reading deny.toml does not ask" "cat deny.toml | grep bans" silent
bash_cmd "cargo test does not ask" "cargo test --workspace 2>&1 | tail" silent
bash_cmd "sed -i on Cargo.toml without the word lints asks" "sed -i '/unsafe_code/a warnings = \"allow\"' Cargo.toml" ask "a Cargo.toml"
bash_cmd "sed -i on Cargo.toml dependencies asks" "sed -i 's/serde = \"1\"/serde = \"2\"/' Cargo.toml" ask
bash_cmd "perl -i on a member Cargo.toml asks" "perl -i -pe 's/workspace = true//' crates/lib/Cargo.toml" ask
bash_cmd "appending to Cargo.toml asks" "printf '[profile.dev]\\nopt-level = 1\\n' >> Cargo.toml" ask
bash_cmd "mv onto Cargo.toml asks" "mv /tmp/x.toml Cargo.toml" ask
bash_cmd "reading Cargo.toml does not ask" "grep -n lints Cargo.toml" silent
bash_cmd "cargo add does not ask" "cargo add serde --features derive" silent
bash_cmd "a .rs write without a suppression does not ask" "printf 'fn x() {}\\n' >> crates/lib/src/lib.rs" silent
bash_cmd "sed -i adding #[ allow(...)] with a space asks" "sed -i 's/^pub fn a/#[ allow(warnings)]\\npub fn a/' crates/lib/src/lib.rs" ask
bash_cmd "sed -i adding an escaped #\\[allow( asks" "sed -i 's/^pub fn a/#\\[allow(warnings)]\\npub fn a/' crates/lib/src/lib.rs" ask
bash_cmd "appending #[should_panic] asks" "printf '#[should_panic]\\n' >> crates/lib/src/lib.rs" ask
bash_cmd "appending #[cfg_attr(miri, ignore)] asks" "printf '#[cfg_attr(miri, ignore)]\\n' >> crates/lib/src/lib.rs" ask
bash_cmd "appending #[cfg(miri)] asks" "printf '#[cfg( miri )]\\n' >> crates/lib/src/lib.rs" ask
bash_cmd "appending #[rustfmt::skip] asks" "printf '#[rustfmt::skip]\\n' >> crates/lib/src/lib.rs" ask
bash_cmd "appending gitleaks:allow to any file asks" "echo 'key = abc # gitleaks:allow' >> config/app.ini" ask "gitleaks:allow"
bash_cmd "appending to .gitleaksignore asks" "echo 'abc:src/x.rs:generic-api-key:3' >> .gitleaksignore" ask
bash_cmd "sed -i on .cargo/config.toml asks" "sed -i 's/-D/-W/' .cargo/config.toml" ask
bash_cmd "writing a .gitattributes asks" "echo '*.rs -diff' > crates/lib/.gitattributes" ask
bash_cmd "cp onto build.rs asks" "cp /tmp/b.rs build.rs" ask
bash_cmd "tee into lefthook-local.yml asks" "echo 'skip_output: true' | tee lefthook-local.yml" ask
bash_cmd "a redirect into .github/zizmor.yml asks" "printf 'rules: {}\\n' > .github/zizmor.yml" ask
bash_cmd "reading build.rs does not ask" "cat build.rs" silent

# The two halves combined.
wrapper="${hook}"
write "both halves asking give one ask with both reasons" deny.toml 'x' ask "rust protect hook: deny.toml controls"
write "both reasons are in it" deny.toml 'x' ask "weakened-checks hook: deny.toml is check config"
out="$(printf '%s' "$(jq -n --arg f "${r}/deny.toml" --arg c "${r}" '{cwd: $c, tool_name: "Write", tool_input: {file_path: $f, content: "x"}}')" | (cd "${r}" && "${hook}"))"
reason="$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"${out}")"
if [[ ${reason} == *"WEAKENED_CHECKS_PROTECT_CONFIG=off turns off only its weakened-checks half)." && $(grep -o 'to turn this hook off' <<<"${reason}" | wc -l) -eq 1 ]]; then
  echo "ok   the joined reason ends with one opt-out naming both halves"
else
  echo "FAIL the joined reason ends with one opt-out naming both halves: ${reason}"
  failures=$((failures + 1))
fi
write "a Go config in a Rust repo asks (weakened-checks' hook only)" .golangci.yml 'x' ask "weakened-checks hook"
write "a TypeScript suppression in a Rust repo asks" web/a.ts '// @ts-ignore
const x = 1;' ask "weakened-checks hook"

WEAKENED_CHECKS_HOOK="${work}/none/protect-config.sh" write "a missing shared hook: rust-ci's rules still ask" deny.toml 'x' ask "rust protect hook: deny.toml controls"
WEAKENED_CHECKS_HOOK="${work}/none/protect-config.sh" write "a missing shared hook is said in additionalContext beside the ask" deny.toml 'x' ask '"additionalContext": "rust protect hook: weakened-checks'"'"' hook was not found'
WEAKENED_CHECKS_HOOK="${work}/none/protect-config.sh" run_json "a missing shared hook is said in additionalContext with rust-ci's own note" '{not json' context "hook was not found"
WEAKENED_CHECKS_HOOK="${work}/none/protect-config.sh" write "a missing shared hook is not said for a change rust-ci's rules pass" NOTES.md '# notes' silent
WEAKENED_CHECKS_HOOK="${work}/none/protect-config.sh" bash_cmd "a missing shared hook is not said for a plain command" "ls" silent

mkdir -p "${work}/stubs"
printf '#!/bin/sh\ncat >/dev/null\nexit 3\n' >"${work}/stubs/fails.sh"
printf '#!/bin/sh\ncat >/dev/null\necho hello\n' >"${work}/stubs/text.sh"
printf '#!/bin/sh\ncat >/dev/null\nprintf "{\\"hookSpecificOutput\\":{\\"additionalContext\\":\\"a\\"}}\\n{\\"hookSpecificOutput\\":{\\"additionalContext\\":\\"b\\"}}\\n"\n' >"${work}/stubs/two.sh"
printf '#!/bin/sh\nexec sleep 30\n' >"${work}/stubs/slow.sh"
chmod +x "${work}"/stubs/*.sh
WEAKENED_CHECKS_HOOK="${work}/stubs/fails.sh" write "a failing shared hook is said" NOTES.md '# notes' context "weakened-checks' hook exited 3"
WEAKENED_CHECKS_HOOK="${work}/stubs/fails.sh" write "a failing shared hook doesn't stop rust-ci's ask" deny.toml 'x' ask "exited 3"
WEAKENED_CHECKS_HOOK="${work}/stubs/text.sh" write "a shared hook printing text is said" NOTES.md '# notes' context "not hook JSON"
WEAKENED_CHECKS_HOOK="${work}/stubs/two.sh" write "a shared hook printing two objects is said" NOTES.md '# notes' context "not hook JSON"
WEAKENED_CHECKS_HOOK="${work}/stubs/slow.sh" write "a slow shared hook is stopped and said" NOTES.md '# notes' context "took longer than"

WEAKENED_CHECKS_PROTECT_CONFIG=off write "WEAKENED_CHECKS_PROTECT_CONFIG=off turns off the shared half" .golangci.yml 'x' silent
out="$(WEAKENED_CHECKS_PROTECT_CONFIG=off bash -c 'printf "%s" "$1" | (cd "$2" && "$3")' _ "$(jq -n --arg f "${r}/deny.toml" --arg c "${r}" '{cwd: $c, tool_name: "Write", tool_input: {file_path: $f, content: "x"}}')" "${r}" "${hook}")"
if [[ ${out} == *"rust protect hook: deny.toml controls"* && ${out} != *"weakened-checks hook:"* ]]; then
  echo "ok   WEAKENED_CHECKS_PROTECT_CONFIG=off leaves rust-ci's half"
else
  echo "FAIL WEAKENED_CHECKS_PROTECT_CONFIG=off leaves rust-ci's half: ${out}"
  failures=$((failures + 1))
fi

# Installed as a symlink, it finds its remainder beside its real path; copied on
# its own, it says the remainder is missing and still runs the shared hook.
mkdir -p "${work}/hooks" "${work}/copy"
ln -s "${wrapper}" "${work}/hooks/rust-protect-config.sh"
hook="${work}/hooks/rust-protect-config.sh"
write "through a symlink, rust-ci's rules still run" build.rs 'x' ask "rust protect hook: build.rs controls"
cp "${wrapper}" "${work}/copy/rust-protect-config.sh"
hook="${work}/copy/rust-protect-config.sh"
write "a copy without its remainder says so, and the shared hook still asks" deny.toml 'x' ask "rust-ci's own check was not found"
hook="${wrapper}"

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
# rust-ci's own rules skip a repo without a root Cargo.toml; weakened-checks' hook
# judges every git repository.
write "a non-Rust repo's workflow asks (weakened-checks' hook only)" .github/workflows/ci.yml 'x' ask "weakened-checks hook"
write "deny.toml in a non-Rust repo asks (weakened-checks' hook only)" deny.toml 'x' ask "weakened-checks hook"
bash_cmd "Bash in a non-Rust repo asks (weakened-checks' hook only)" "sed -i 's/a/b/' deny.toml" ask "weakened-checks hook"
mkdir -p "${p}/sub" && printf '[package]\nname = "sub"\n' >"${p}/sub/Cargo.toml"
write "a crate below a non-Rust repo root asks (weakened-checks' hook only)" sub/clippy.toml 'x' ask "weakened-checks hook"
write "a Go config in a non-Rust repo asks (weakened-checks' hook only)" .golangci.yml 'x' ask "weakened-checks hook"
write "a Markdown file in a non-Rust repo does not ask" NOTES.md 'x' silent

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} failed"
  exit 1
fi
echo "all passed"
