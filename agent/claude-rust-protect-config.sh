#!/usr/bin/env bash
# Claude Code PreToolUse hook: before an agent changes a file that controls a Rust
# project's checks (lint tables, clippy, rustfmt, the toolchain, dependency policy,
# spelling, nextest profiles, cargo config, build scripts, CI workflows and actions,
# git hooks, gitleaks, CODEOWNERS), adds a lint or test suppression to a .rs file, or
# adds a gitleaks:allow anywhere, ask the human to approve it. An agent stuck on a finding can otherwise make it go away by weakening
# the check.
#
# Install: symlink it into ~/.claude/hooks/ and register it under PreToolUse for
# Edit|Write|MultiEdit|Bash (rust-ci README, "Claude Code hooks").
#
# What asks (paths relative to the git repo root, which must have a Cargo.toml):
#   deny.toml, rust-toolchain(.toml), .config/nextest.toml, typos.toml, _typos.toml,
#   .typos.toml, (.)lefthook(-local).yml/.yaml, .gitleaks.toml, .gitleaksignore,
#   CODEOWNERS (root, .github/, docs/), .github/workflows/*, .github/actions/**,
#   .github/zizmor.yml, .github/actionlint.yaml (.yml or .yaml); clippy.toml,
#   .clippy.toml, rustfmt.toml, .rustfmt.toml, .cargo/config(.toml),
#   .cargo/mutants.toml, .gitattributes and build.rs at any depth.
#   Cargo.toml at any depth, only when the change touches the [lints],
#   [workspace.lints] or [profile] tables. With Python 3.11+ (tomllib) the manifest
#   before and after the change is parsed and those tables compared; an edit whose
#   old text can't be found asks (unsure). Without it, a line heuristic: Edit and
#   MultiEdit ask when the old or new text mentions lints or adds or drops a table
#   header, or the old text sits inside a lints table; Write asks when the lints
#   lines or the table headers differ, or the new content has a dotted lints key.
#   A .rs file when the change adds a suppression attribute: allow, expect, ignore,
#   should_panic, rustfmt::skip, a cfg_attr applying one, or #[cfg(any())] /
#   #[cfg(not(all()))] / #[cfg(false)] / #[cfg(miri)]. The attributes of the file
#   after the change are compared with the file before, so a wider suppression in
#   place of a narrow one asks. Any file when the change adds a gitleaks:allow.
#   Removing one never asks. Removing or narrowing a deny, forbid or warn attribute
#   (or a cfg_attr applying one) asks too: a crate's #![deny(...)] is a check.
#   Bash, best effort: a command that names a protected file (or any Cargo.toml, or a
#   .rs file together with a suppression attribute or the word deny or forbid, or
#   gitleaks:allow) and either
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
      .lefthook.yml | .lefthook.yaml | lefthook-local.yml | lefthook-local.yaml | \
      .lefthook-local.yml | .lefthook-local.yaml | .gitleaks.toml | .gitleaksignore | \
      CODEOWNERS | .github/CODEOWNERS | docs/CODEOWNERS | \
      .github/zizmor.yml | .github/zizmor.yaml | .github/actionlint.yml | .github/actionlint.yaml | \
      .github/workflows/* | .github/actions/*) echo config ;;
    clippy.toml | */clippy.toml | .clippy.toml | */.clippy.toml | \
      rustfmt.toml | */rustfmt.toml | .rustfmt.toml | */.rustfmt.toml | \
      .cargo/config | */.cargo/config | .cargo/config.toml | */.cargo/config.toml | \
      .cargo/mutants.toml | */.cargo/mutants.toml | .gitattributes | */.gitattributes) echo config ;;
    # A build script runs before every build and test, and can set cfgs and env.
    build.rs | */build.rs) echo config ;;
    *.rs) echo rust ;;
  esac
}

# The suppressions a .rs change must not add without a human. attr_re finds every
# attribute (Oniguruma, for jq; a "]" inside a string literal doesn't end it), and
# suppress_re picks the suppressions from them once their whitespace is removed:
# allow, expect, ignore, should_panic, rustfmt::skip, a cfg_attr applying one of
# those, and a cfg that compiles the item out (any(), not(all()), false) or out of
# Miri runs. A #[cfg(windows)] or #[cfg(target_os = ...)] can skip a test too, but
# it is ordinary in non-test code and the hook can't tell the two apart, so it would
# ask far too often. suppress_ere is the same idea as an ERE for Bash commands
# (whitespace tolerant, and a sed script's \[ and \( count).
attr_re='#\s*!?\s*\[(?:[^\]"]|"(?:[^"\\]|\\.)*")*\]'
suppress_re='^#!?\[((allow|expect|ignore|should_panic|rustfmt::skip)\b|cfg\((any\(\)|not\(all\(\)\)|false|miri)\)|cfg_attr\(.*(\b(allow|expect|ignore|should_panic)\b|rustfmt::skip))'
# strict_re picks the attributes that make lints stricter, whose removal asks;
# strict_ere is its Bash counterpart, any deny or forbid in the command.
strict_re='^#!?\[(deny|forbid|warn)\(|^#!?\[cfg_attr\(.*\b(deny|forbid|warn)\('
strict_ere='(^|[^[:alnum:]_])(deny|forbid)([^[:alnum:]_]|$)'
suppress_ere='#[[:space:]]*!?[[:space:]]*\\?\[[[:space:]]*(allow|expect|ignore|should_panic|rustfmt[[:space:]]*::[[:space:]]*skip)([^[:alnum:]_]|$)|cfg_attr[[:space:]]*\\?\(.*([^[:alnum:]_](allow|expect|ignore|should_panic)|rustfmt[[:space:]]*::[[:space:]]*skip)([^[:alnum:]_]|$)|#[[:space:]]*!?[[:space:]]*\\?\[[[:space:]]*cfg[[:space:]]*\\?\([[:space:]]*(any[[:space:]]*\\?\([[:space:]]*\\?\)|not[[:space:]]*\\?\([[:space:]]*all[[:space:]]*\\?\([[:space:]]*\\?\)[[:space:]]*\\?\)|false|miri)[[:space:]]*\\?\)'

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
  files='deny\.toml|\.?clippy\.toml|\.?rustfmt\.toml|rust-toolchain(\.toml)?|nextest\.toml|[._]?typos\.toml|\.?lefthook(-local)?\.ya?ml|\.gitleaks\.toml|\.gitleaksignore|CODEOWNERS|\.cargo/(config(\.toml)?|mutants\.toml)|\.gitattributes|build\.rs|zizmor\.ya?ml|actionlint\.ya?ml'
  names="(^|$b)($files)($b|$)|(^|$b)\.github(/(workflows|actions)|/?($b|$))"
  writers="(^|[;&|({[:space:]])((sed|perl)[[:space:]][^;&|]*-[a-zA-Z]*i|tee|mv|cp|rm|truncate|ln|install|patch|git[[:space:]]+(checkout|restore|rm|mv|apply))([[:space:]]|$)"
  redirect=">[[:space:]]*['\"]?[^[:space:];&|<>]*"
  target=""
  if grep -Eq -- "$names" <<<"$cmd"; then
    if grep -Eq -- "$writers" <<<"$cmd" || grep -Eq -- "${redirect}($files|\.github/)" <<<"$cmd"; then
      target="a file that controls the project's checks (lints, formatting, toolchain, dependency policy, spelling, CI or git hooks)"
    fi
  fi
  # Any write to a Cargo.toml: from a command line there's no telling which table a
  # sed script or a heredoc lands in.
  if [[ -z $target ]] && grep -Eq -- '(^|[^[:alnum:]_.-])Cargo\.toml' <<<"$cmd"; then
    if grep -Eq -- "$writers" <<<"$cmd" || grep -Eq -- "${redirect}Cargo\.toml" <<<"$cmd"; then
      target="a Cargo.toml, whose [lints] and [profile] tables set what clippy, rustc and the tests check"
    fi
  fi
  if [[ -z $target ]] && grep -Eq -- '\.rs([^[:alnum:]_]|$)' <<<"$cmd" && grep -Eq -- "$suppress_ere" <<<"$cmd"; then
    if grep -Eq -- "$writers" <<<"$cmd" || grep -Eq -- "${redirect}\.rs" <<<"$cmd"; then
      target="a .rs file, adding a lint or test suppression (#[allow], #[expect], #[ignore], #[should_panic], #[rustfmt::skip] or a disabling cfg)"
    fi
  fi
  if [[ -z $target ]] && grep -Eq -- '\.rs([^[:alnum:]_]|$)' <<<"$cmd" && grep -Eq -- "$strict_ere" <<<"$cmd"; then
    if grep -Eq -- "$writers" <<<"$cmd" || grep -Eq -- "${redirect}\.rs" <<<"$cmd"; then
      target="a .rs file, with a deny or forbid attribute it may remove or loosen"
    fi
  fi
  if [[ -z $target ]] && grep -q -- 'gitleaks:allow' <<<"$cmd"; then
    if grep -Eq -- "$writers" <<<"$cmd" || grep -Eq -- "$redirect" <<<"$cmd"; then
      target="a file, adding a gitleaks:allow comment that hides a line from secret scanning"
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
# Any other file is only checked for an added gitleaks:allow.
[[ -n $k ]] || grep -q 'gitleaks:allow' <<<"$input" || exit 0

if [[ $k == config ]]; then
  ask "$rel controls the project's checks (lints, formatting, toolchain, dependency policy, spelling, CI or git hooks). Changing it can weaken them, so a human approves this edit."
fi

# The current content ("" for a new file) beside the hook input, as $cur in jq. Read
# by jq from the file: in an argument a large file would overflow the size limit.
cur=(--arg cur "")
[[ -f $abs ]] && cur=(--rawfile cur "$abs")

# jq helpers for both checks. edited(edit): the text with one Edit or MultiEdit edit
# applied as Claude Code applies it, or null when the old text isn't in it.
# shellcheck disable=SC2016 # jq variables, not shell ones
after='
  def edited($e): ($e.old_string // "") as $o | ($e.new_string // "") as $n
    | if $o == "" then (if . == "" then $n else null end)
      else split($o) as $p
        | if ($p | length) < 2 then null
          elif ($e.replace_all // false) then $p | join($n)
          else $p[0] + $n + ($p[1:] | join($o)) end
      end;
  def edits: if .tool_name == "Edit" then [.tool_input] else [.tool_input.edits[]?] end;
'

# toml_py <current file> < <new text>: prints "no" when the [lints], [workspace.lints]
# and [profile] tables parse the same before and after, "lints" when they don't.
# Exit 3 when it can't tell (no tomllib before Python 3.11, or TOML it can't read).
toml_py='
import sys
try:
    import tomllib
except ImportError:
    sys.exit(3)
def tables(text):
    d = tomllib.loads(text)
    w = d.get("workspace")
    return d.get("lints"), w.get("lints") if isinstance(w, dict) else None, d.get("profile")
try:
    try:
        with open(sys.argv[1], encoding="utf-8") as f:
            old = f.read()
    except FileNotFoundError:
        old = ""
    print("no" if tables(old) == tables(sys.stdin.read()) else "lints")
except Exception:
    sys.exit(3)
'

if [[ $k == cargo ]]; then
  # The manifest after the change, parsed, decides. Table context counts: a dotted
  # lints key moved under another header is no longer a lint.
  new=$(printf '%s' "$input" | jq -j "${cur[@]}" "$after"'
    if .tool_name == "Write" then "ok\n" + (.tool_input.content // "")
    else reduce edits[] as $e ($cur; if . == null then null else edited($e) end)
      | if . == null then "unsure" else "ok\n" + . end
    end' 2>/dev/null) || say "could not read the edit with jq, so this change to $rel was not checked for lints changes."
  verdict=""
  if [[ $new == ok$'\n'* ]] && command -v python3 >/dev/null 2>&1; then
    verdict=$(python3 -I -c "$toml_py" "$abs" <<<"${new#ok$'\n'}" 2>/dev/null) || verdict=""
  fi
  # Without tomllib, a line heuristic: the lints lines, the table headers, and any
  # dotted lints key.
  [[ -n $verdict ]] || verdict=$(printf '%s' "$input" | jq -r "${cur[@]}" '
    # The lines that belong to a lints table or set a lints key, whitespace removed,
    # comments and blank lines dropped.
    def lintlines: split("\n") | reduce .[] as $l ({sec: false, out: []};
      if ($l | test("^\\s*\\[")) then
        .sec = ($l | test("lints")) | if .sec then .out += [$l | gsub("\\s+"; "")] else . end
      elif (.sec or ($l | test("lints"))) and ($l | test("^\\s*(#.*)?$") | not) then
        .out += [$l | gsub("\\s+"; "")]
      else . end) | .out;
    # The table headers, whitespace removed.
    def headers: [split("\n")[] | select(test("^\\s*\\[")) | gsub("\\s+"; "")] | unique;
    def dotted: test("(^|\n)\\s*(workspace\\s*\\.\\s*)?lints\\s*\\.");
    # The table header that holds the start of <old> in the current file.
    def section($old): ($cur | split($old)) as $parts
      | if ($parts | length) < 2 then null
        else ($parts[0] | split("\n") | map(select(test("^\\s*\\["))) | last // "") end;
    def edit_touches: (.old_string // "") as $o | (.new_string // "") as $n
      | if ($o + $n | test("lints")) or ($o | headers) != ($n | headers) then "lints"
        elif $o == "" then "no"
        else section($o) as $s
          | if $s == null then "unsure" elif ($s | test("lints")) then "lints" else "no" end
        end;
    if .tool_name == "Write" then (.tool_input.content // "") as $n
      | if ($n | lintlines) != ($cur | lintlines) or ($n | headers) != ($cur | headers) or ($n | dotted)
        then "lints" else "no" end
    elif .tool_name == "Edit" then .tool_input | edit_touches
    else [.tool_input.edits[]? | edit_touches] as $v
      | if any($v[]; . == "lints") then "lints" elif any($v[]; . == "unsure") then "unsure" else "no" end
    end' 2>/dev/null) || say "could not read the edit with jq, so this change to $rel was not checked for lints changes."
  case $verdict in
    lints) ask "this edit changes the [lints], [workspace.lints] or [profile] tables in $rel, which set what clippy, rustc and the tests check. Changing them can weaken the checks, so a human approves this edit." ;;
    unsure) ask "this edit's old text isn't in $rel as it is now, so the hook can't tell whether it touches the [lints] tables. A human approves it." ;;
  esac
fi

# Ask only when the change adds a suppression: a .rs attribute (attr_re, suppress_re)
# or, in any file, a gitleaks:allow. The file after the change is compared with the
# file before, as lists with repeats, so turning one suppression into a wider one or
# adding a lint to an allow list counts as adding. An edit whose old text isn't in
# the file is judged on its own old and new text.
[[ $k == rust ]] && rust=true || rust=false
added=$(printf '%s' "$input" | jq -r "${cur[@]}" --arg attr "$attr_re" --arg re "$suppress_re" --argjson rust "$rust" "$after"'
  def found: (if $rust then [match($attr; "g") | .string | gsub("\\s+"; "") | select(test($re))] else [] end)
    + [match("gitleaks:allow"; "g") | .string];
  # The items of the list that <$old> has fewer of.
  def more($old): ($old | group_by(.) | map({key: .[0], value: length}) | from_entries) as $c
    | group_by(.) | map(select(length > ($c[.[0]] // 0)) | .[0]);
  if .tool_name == "Write" then (.tool_input.content // "") | found | more($cur | found)
  else reduce edits[] as $e ({text: $cur, also: []};
      (.text | edited($e)) as $t
      | if $t == null then .also += (($e.new_string // "") | found | more(($e.old_string // "") | found))
        else .text = $t end)
    | (.text | found | more($cur | found)) + .also
  end | unique | join(", ")' 2>/dev/null) || say "could not read the edit with jq, so this change to $rel was not checked for added suppressions."
if [[ -n $added ]]; then
  ask "this edit adds a suppression to $rel ($added). Silencing a lint, ignoring a test, compiling code out or hiding a line from secret scanning can hide a real problem, so a human approves it."
fi

# The other way round: a deny, forbid or warn attribute the file had and loses, or
# one that loses a lint from its list. Moving or respacing one stays silent.
if [[ $k == rust ]]; then
  removed=$(printf '%s' "$input" | jq -r "${cur[@]}" --arg attr "$attr_re" --arg re "$strict_re" "$after"'
    def found: [match($attr; "g") | .string | gsub("\\s+"; "") | select(test($re))];
    def more($old): ($old | group_by(.) | map({key: .[0], value: length}) | from_entries) as $c
      | group_by(.) | map(select(length > ($c[.[0]] // 0)) | .[0]);
    if .tool_name == "Write" then (.tool_input.content // "") as $n | $cur | found | more($n | found)
    else reduce edits[] as $e ({text: $cur, also: []};
        (.text | edited($e)) as $t
        | if $t == null then .also += (($e.old_string // "") | found | more(($e.new_string // "") | found))
          else .text = $t end)
      | .also as $also | .text as $t | ($cur | found | more($t | found)) + $also
    end | unique | join(", ")' 2>/dev/null) || say "could not read the edit with jq, so this change to $rel was not checked for removed lint attributes."
  if [[ -n $removed ]]; then
    ask "this edit removes or narrows a lint attribute in $rel ($removed). A deny or forbid in the code is a check, so a human approves loosening it."
  fi
fi
exit 0
