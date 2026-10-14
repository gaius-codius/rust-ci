#!/usr/bin/env bash
# Claude Code PostToolUse hook: after an agent edits a .rs file in a Cargo package,
# format the file with rustfmt, using the edition from the package's Cargo.toml.
#
# rustfmt.toml in the baseline sets only style_edition, so a bare `rustfmt` would
# parse the file as edition 2015 and reject modern syntax; the edition is read from
# `edition` in [package], or from [workspace.package] when the package inherits it.
#
# Install: symlink it into ~/.claude/hooks/ and register it for Edit|Write|MultiEdit
# (rust-ci README, "Claude Code hooks").
#
# Outcomes:
#   exit 2, findings on stderr: rustfmt ran and the file doesn't parse. Claude Code
#     feeds them back to the agent.
#   exit 0, nothing: not a .rs edit, or no Cargo.toml above the file, or the file
#     was formatted.
#   exit 0 with JSON additionalContext on stdout: the check could not run (rustfmt
#     missing, no edition found, a rustfmt or config failure). Never silent.
set -uo pipefail

# say <message>: tell the agent something without blocking, then exit 0.
say() {
  local m=$1
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg m "rust fmt hook: $m" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  else
    m=${m//\\/\\\\}; m=${m//\"/\\\"}; m=${m//$'\n'/\\n}
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"rust fmt hook: %s"}}\n' "$m"
  fi
  exit 0
}

# toml_edition <Cargo.toml> <section>: the literal edition set in [<section>], or
# nothing. Handles `edition = "2024"` with comments and single quotes.
toml_edition() {
  awk -v want="[$2]" '
    /^[[:space:]]*\[/ { s = $0; sub(/[[:space:]]*(#.*)?$/, "", s); sub(/^[[:space:]]*/, "", s); cur = s; next }
    cur == want && /^[[:space:]]*edition[[:space:]]*=[[:space:]]*["\x27]/ {
      v = $0; sub(/^[^"\x27]*["\x27]/, "", v); sub(/["\x27].*$/, "", v); print v; exit
    }' "$1"
}

# find_edition <dir>: the edition for a file in <dir>, found by walking up.
find_edition() {
  local d=$1 first=1 e
  while :; do
    if [[ -f $d/Cargo.toml ]]; then
      if ((first)); then
        e=$(toml_edition "$d/Cargo.toml" package)
        [[ -n $e ]] && { printf '%s\n' "$e"; return 0; }
        first=0
      fi
      e=$(toml_edition "$d/Cargo.toml" workspace.package)
      [[ -n $e ]] && { printf '%s\n' "$e"; return 0; }
    fi
    [[ $d == / ]] && return 1
    d=$(dirname "$d")
  done
}

has_manifest() {
  local d=$1
  while :; do
    [[ -f $d/Cargo.toml ]] && return 0
    [[ $d == / ]] && return 1
    d=$(dirname "$d")
  done
}

input=$(cat)
if command -v jq >/dev/null 2>&1; then
  if ! file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty'); then
    say "could not read the hook input with jq, so this edit was not checked."
  fi
  parsed=1
else
  # Best effort without jq, only to decide whether the edit is ours to report on.
  file=$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  parsed=0
fi
[[ $file == *.rs && -f $file ]] || exit 0
file=$(realpath -- "$file")
dir=$(dirname "$file")

has_manifest "$dir" || exit 0
if ((!parsed)); then
  say "jq is not on PATH, so the edited path can't be read reliably and this edit was not checked."
fi
if ! command -v rustfmt >/dev/null 2>&1; then
  say "rustfmt is not on PATH, so $file was not formatted or parse-checked (rustup component add rustfmt)."
fi
edition=$(find_edition "$dir") || say "no edition found in the Cargo.toml above $file ([package] or [workspace.package]), so it was not formatted: rustfmt would parse it as edition 2015."

# Run from the file's directory so rustup picks the project's rust-toolchain.toml
# and rustfmt finds rustfmt.toml by walking up.
cd "$dir" || say "cannot cd to $dir, so $file was not formatted."
out=$(rustfmt --edition "$edition" "$file" 2>&1)
code=$?
if ((code == 0)); then
  exit 0
fi
# A parse error points at a .rs location (`--> file.rs:3:5`); anything else (a bad
# rustfmt.toml, a missing component, a crash) is a tool failure.
if grep -Eq -- '-->[[:space:]]*[^[:space:]]+\.rs:[0-9]+' <<<"$out"; then
  printf 'rustfmt could not parse %s (edition %s):\n%s\n' "$file" "$edition" "$out" >&2
  exit 2
fi
say "rustfmt failed (exit $code), so $file was not formatted: $out"
