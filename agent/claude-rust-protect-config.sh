#!/usr/bin/env bash
# Claude Code PreToolUse hook: before an agent changes a file that controls a Rust
# project's checks (lint tables, clippy, rustfmt, the toolchain, dependency policy,
# spelling, nextest profiles, CI workflows and actions, git hooks, gitleaks,
# CODEOWNERS), or adds a lint or test suppression to a .rs file, ask the human to
# approve it. An agent stuck on a finding can otherwise make it go away by weakening
# the check.
#
# Install: symlink it into ~/.claude/hooks/ and register it under PreToolUse for
# Edit|Write|MultiEdit|Bash (rust-ci README, "Claude Code hooks").
#
# What asks (paths relative to the git repo root, which must have a Cargo.toml):
#   deny.toml, rust-toolchain(.toml), .config/nextest.toml, typos.toml, _typos.toml,
#   .typos.toml, lefthook.yml, .gitleaks.toml, CODEOWNERS (root, .github/, docs/),
#   .github/workflows/*, .github/actions/**; clippy.toml, .clippy.toml, rustfmt.toml
#   and .rustfmt.toml at any depth (both tools read them from subdirectories).
#   Cargo.toml at any depth, only when the change touches a [lints] or
#   [workspace.lints] table or a lints key. Edit and MultiEdit: the old or new text
#   mentions lints, or the old text sits inside a lints table, or the old text can't
#   be found (unsure, so ask). Write: the lints lines of the new content differ from
#   the current file's.
#   A .rs file when the change adds #[allow(, #![allow(, #[expect(, a cfg_attr that
#   allows or expects, #[ignore, or #[cfg(any())] / #[cfg(not(all()))] / #[cfg(false)]
#   (more of them in the new text than in the old). Removing one never asks.
#   Bash, best effort: a command that names a protected file (or Cargo.toml together
#   with "lints", or a .rs file together with a suppression attribute) and either
#   writes with sed -i, perl -i, tee, mv, cp, rm, truncate, ln, install, patch,
#   git checkout/restore/rm/mv/apply, or redirects into one. A write through any other
#   program (python, a script, cargo itself) is not seen; a read with cp is asked.
#   NotebookEdit only edits notebooks, so it is not covered.
#
# Outcomes:
#   exit 0 with JSON permissionDecision "ask": a protected change. Claude Code asks
#     the user, showing the reason.
#   exit 0, nothing: anything else, a repo without Cargo.toml at its root, or
#     RUST_CI_PROTECT_CONFIG=off. The normal permission flow carries on.
#   exit 0 with JSON additionalContext: the check could not run (jq missing, input
#     jq can't read). Never blocks, never silent.
set -uo pipefail

opt_out="Set RUST_CI_PROTECT_CONFIG=off to turn this hook off."

# say <message>: tell the agent something without blocking, then exit 0.
say() {
  local m=$1
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg m "rust protect hook: $m" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
  else
    m=${m//\\/\\\\}; m=${m//\"/\\\"}; m=${m//$'\n'/\\n}
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"rust protect hook: %s"}}\n' "$m"
  fi
  exit 0
}

# ask <reason>: hand the decision to the user, then exit 0. Only called with jq.
ask() {
  jq -n --arg r "rust protect hook: $1 $opt_out" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
}

# workspace_root <dir>: the nearest directory at or above <dir> whose Cargo.toml has a
# [workspace] table, else the nearest with a Cargo.toml.
workspace_root() {
  local d=$1 nearest=""
  while :; do
    if [[ -f $d/Cargo.toml ]]; then
      [[ -n $nearest ]] || nearest=$d
      grep -Eq '^[[:space:]]*\[workspace[].]' "$d/Cargo.toml" && { printf '%s\n' "$d"; return 0; }
    fi
    [[ $d == / ]] && break
    d=$(dirname "$d")
  done
  [[ -n $nearest ]] && { printf '%s\n' "$nearest"; return 0; }
  return 1
}

# rust_root <existing dir>: the git repo root of <dir> (else the Cargo workspace root),
# when it has a Cargo.toml.
rust_root() {
  local r
  r=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || r=$(workspace_root "$1") || return 1
  r=$(realpath -- "$r") || return 1
  [[ -f $r/Cargo.toml ]] || return 1
  printf '%s\n' "$r"
}

# abs_path <path> <cwd>: <path> made absolute with its nearest existing directory
# resolved. The file itself is not resolved: a symlinked deny.toml stays deny.toml.
abs_path() {
  local p=$1 d rest
  [[ $p == /* ]] || p="$2/$p"
  d=$(dirname "$p")
  rest=$(basename "$p")
  while [[ ! -d $d ]]; do
    rest="$(basename "$d")/$rest"
    d=$(dirname "$d")
  done
  d=$(realpath -- "$d") || return 1
  printf '%s/%s\n' "${d%/}" "$rest"
}

# kind <path relative to the root>: "config", "cargo", "rust" or nothing.
kind() {
  case $1 in
    Cargo.toml | */Cargo.toml) echo cargo ;;
    deny.toml | rust-toolchain | rust-toolchain.toml | .config/nextest.toml | \
      typos.toml | _typos.toml | .typos.toml | lefthook.yml | lefthook.yaml | \
      .lefthook.yml | .lefthook.yaml | .gitleaks.toml | \
      CODEOWNERS | .github/CODEOWNERS | docs/CODEOWNERS | \
      .github/workflows/* | .github/actions/*) echo config ;;
    clippy.toml | */clippy.toml | .clippy.toml | */.clippy.toml | \
      rustfmt.toml | */rustfmt.toml | .rustfmt.toml | */.rustfmt.toml) echo config ;;
    *.rs) echo rust ;;
  esac
}

# The suppressions a .rs change must not add without a human (an Oniguruma regex for
# jq), and the same idea as an ERE for Bash commands.
suppress_re='#\s*!?\s*\[\s*(allow|expect)\s*\(|#\s*!?\s*\[\s*cfg_attr\s*\([^\]]*\b(allow|expect)\s*\(|#\s*\[\s*ignore\b|#\s*!?\s*\[\s*cfg\s*\(\s*(any\s*\(\s*\)|not\s*\(\s*all\s*\(\s*\)\s*\)|false)\s*\)'
suppress_ere='#!?\[(allow|expect)\(|cfg_attr\(.*(allow|expect)\(|#\[ignore|cfg\((any\(\)|not\(all\(\)\)|false)\)'

[[ ${RUST_CI_PROTECT_CONFIG:-} == off ]] && exit 0

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  # Best effort without jq, only to decide whether the change is ours to report on.
  file=$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  cwd=$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [[ -n $cwd && -d $cwd ]] || cwd=$PWD
  if [[ -n $file ]]; then
    abs=$(abs_path "$file" "$cwd") || exit 0
    root=$(rust_root "$(dirname "$abs")") || exit 0
    [[ $abs == "$root"/* && -n $(kind "${abs#"$root"/}") ]] || exit 0
    say "jq is not on PATH, so this change to ${abs#"$root"/} was not checked for weakened checks."
  fi
  rust_root "$cwd" >/dev/null || exit 0
  grep -Eq '"command"' <<<"$input" || exit 0
  say "jq is not on PATH, so this command was not checked for changes to check-config files."
fi

if ! fields=$(printf '%s' "$input" | jq -c '{tool: (.tool_name // ""), cwd: (.cwd // ""), file: (.tool_input.file_path // ""), command: (.tool_input.command // "")}' 2>/dev/null); then
  say "could not read the hook input with jq, so this change was not checked for weakened checks."
fi
tool=$(jq -r .tool <<<"$fields")
cwd=$(jq -r .cwd <<<"$fields")
[[ -n $cwd && -d $cwd ]] || cwd=$PWD

# Bash, best effort.
if [[ $tool == Bash ]]; then
  cmd=$(jq -r .command <<<"$fields")
  [[ -n $cmd ]] || exit 0
  root=$(rust_root "$cwd") || exit 0
  b='[^[:alnum:]_.-]'
  names="(^|$b)(deny\.toml|\.?clippy\.toml|\.?rustfmt\.toml|rust-toolchain(\.toml)?|nextest\.toml|[._]?typos\.toml|\.?lefthook\.ya?ml|\.gitleaks\.toml|CODEOWNERS)($b|$)|(^|$b)\.github(/(workflows|actions)|/?($b|$))"
  writers="(^|[;&|({[:space:]])((sed|perl)[[:space:]][^;&|]*-[a-zA-Z]*i|tee|mv|cp|rm|truncate|ln|install|patch|git[[:space:]]+(checkout|restore|rm|mv|apply))([[:space:]]|$)"
  redirect=">[[:space:]]*['\"]?[^[:space:];&|<>]*"
  target=""
  if grep -Eq -- "$names" <<<"$cmd"; then
    if grep -Eq -- "$writers" <<<"$cmd" || grep -Eq -- "${redirect}(deny\.toml|clippy\.toml|rustfmt\.toml|rust-toolchain(\.toml)?|nextest\.toml|typos\.toml|lefthook\.ya?ml|\.gitleaks\.toml|CODEOWNERS|\.github/)" <<<"$cmd"; then
      target="a file that controls the project's checks (lints, formatting, toolchain, dependency policy, spelling, CI or git hooks)"
    fi
  fi
  if [[ -z $target ]] && grep -Eq -- '(^|[^[:alnum:]_.-])Cargo\.toml' <<<"$cmd" && grep -q 'lints' <<<"$cmd"; then
    if grep -Eq -- "$writers" <<<"$cmd" || grep -Eq -- "${redirect}Cargo\.toml" <<<"$cmd"; then
      target="the lints tables in a Cargo.toml"
    fi
  fi
  if [[ -z $target ]] && grep -Eq -- '\.rs([^[:alnum:]_]|$)' <<<"$cmd" && grep -Eq -- "$suppress_ere" <<<"$cmd"; then
    if grep -Eq -- "$writers" <<<"$cmd" || grep -Eq -- "${redirect}\.rs" <<<"$cmd"; then
      target="a .rs file, adding a lint or test suppression (#[allow], #[expect], #[ignore] or a disabling cfg)"
    fi
  fi
  [[ -n $target ]] || exit 0
  ask "this command looks like it changes $target. Those can weaken what CI and the hooks check, so a human approves it."
fi

case $tool in
  Edit | Write | MultiEdit) ;;
  *) exit 0 ;;
esac
file=$(jq -r .file <<<"$fields")
[[ -n $file ]] || exit 0
abs=$(abs_path "$file" "$cwd") || exit 0
root=$(rust_root "$(dirname "$abs")") || exit 0
[[ $abs == "$root"/* ]] || exit 0
rel=${abs#"$root"/}
k=$(kind "$rel")
[[ -n $k ]] || exit 0

if [[ $k == config ]]; then
  ask "$rel controls the project's checks (lints, formatting, toolchain, dependency policy, spelling, CI or git hooks). Changing it can weaken them, so a human approves this edit."
fi

# The current content ("" for a new file) beside the hook input.
cur=""
[[ -f $abs ]] && cur=$(cat -- "$abs"; printf x) && cur=${cur%x}

if [[ $k == cargo ]]; then
  verdict=$(printf '%s' "$input" | jq -r --arg cur "$cur" '
    # The lines that belong to a lints table or set a lints key, whitespace removed,
    # comments and blank lines dropped.
    def lintlines: split("\n") | reduce .[] as $l ({sec: false, out: []};
      if ($l | test("^\\s*\\[")) then
        .sec = ($l | test("lints")) | if .sec then .out += [$l | gsub("\\s+"; "")] else . end
      elif (.sec or ($l | test("lints"))) and ($l | test("^\\s*(#.*)?$") | not) then
        .out += [$l | gsub("\\s+"; "")]
      else . end) | .out;
    # The table header that holds the start of <old> in the current file.
    def section($old): ($cur | split($old)) as $parts
      | if ($parts | length) < 2 then null
        else ($parts[0] | split("\n") | map(select(test("^\\s*\\["))) | last // "") end;
    def edit_touches: (.old_string // "") as $o | (.new_string // "") as $n
      | if ($o + $n | test("lints")) then "lints"
        elif $o == "" then "no"
        else section($o) as $s
          | if $s == null then "unsure" elif ($s | test("lints")) then "lints" else "no" end
        end;
    if .tool_name == "Write" then
      if ((.tool_input.content // "") | lintlines) == ($cur | lintlines) then "no" else "lints" end
    elif .tool_name == "Edit" then .tool_input | edit_touches
    else [.tool_input.edits[]? | edit_touches] as $v
      | if any($v[]; . == "lints") then "lints" elif any($v[]; . == "unsure") then "unsure" else "no" end
    end' 2>/dev/null) || say "could not read the edit with jq, so this change to $rel was not checked for lints changes."
  case $verdict in
    lints) ask "this edit changes the [lints] or [workspace.lints] tables in $rel, which set what clippy and rustc deny. Changing them can weaken the checks, so a human approves this edit." ;;
    unsure) ask "this edit's old text isn't in $rel as it is now, so the hook can't tell whether it touches the [lints] tables. A human approves it." ;;
  esac
  exit 0
fi

# A .rs file: ask only when the change adds suppressions.
added=$(printf '%s' "$input" | jq -r --arg cur "$cur" --arg re "$suppress_re" '
  def count: [match($re; "g")] | length;
  def found: [match($re; "g") | .string] | unique | join(", ");
  if .tool_name == "Write" then
    (.tool_input.content // "") as $n
    | if ($n | count) > ($cur | count) then $n | found else "" end
  else (if .tool_name == "Edit" then [.tool_input] else [.tool_input.edits[]?] end) as $e
    | ([$e[] | ((.new_string // "") | count) - ((.old_string // "") | count)] | add // 0) as $d
    | if $d > 0 then [$e[] | (.new_string // "")] | join("\n") | found else "" end
  end' 2>/dev/null) || say "could not read the edit with jq, so this change to $rel was not checked for added suppressions."
if [[ -n $added ]]; then
  ask "this edit adds a lint or test suppression to $rel ($added). Silencing a lint, ignoring a test or compiling code out can hide a real problem, so a human approves it."
fi
exit 0
