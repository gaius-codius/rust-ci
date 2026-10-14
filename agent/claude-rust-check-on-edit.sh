#!/usr/bin/env bash
# Claude Code PostToolUse hook: after an agent edits a .rs file in a Cargo workspace,
# run `cargo check --workspace --message-format=json` and report what broke. An edit
# can break callers in crates it never touched, so errors are reported wherever they
# are; warnings only for the edited file.
#
# Install: symlink it into ~/.claude/hooks/ and register it for Edit|Write|MultiEdit,
# beside claude-rust-fmt-on-edit.sh (rust-ci README, "Claude Code hooks").
#
# Outcomes:
#   exit 2, findings on stderr: cargo ran and found problems. Claude Code feeds them
#     back to the agent.
#   exit 0, nothing: not a .rs edit, no Cargo.toml above the file, or no findings.
#   exit 0 with JSON additionalContext on stdout: the check could not run (cargo
#     missing, a failed dependency fetch, a crash, the build lock held by the agent's
#     own cargo, which the hook doesn't wait for). Never silent.
set -uo pipefail

# say <message>: tell the agent something without blocking, then exit 0.
say() {
  local m=$1
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg m "rust check hook: $m" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
  else
    m=${m//\\/\\\\}; m=${m//\"/\\\"}; m=${m//$'\n'/\\n}
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"rust check hook: %s"}}\n' "$m"
  fi
  exit 0
}

# clip <max lines>: first lines of stdin, with a count of the rest.
clip() {
  awk -v max="$1" 'NR <= max { print } NR > max { n++ } END { if (n) printf "... and %d more lines\n", n }'
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

# run_cargo <stdout file> <stderr file> <cargo args>...: runs cargo, but doesn't wait for
# a held build lock. Returns cargo's exit code, 127 when cargo is missing, 200 when the
# lock is held.
run_cargo() {
  local out=$1 err=$2 pid
  shift 2
  : >"$out"
  command -v cargo >/dev/null 2>&1 || { echo "cargo not found (install a Rust toolchain)" >"$err"; return 127; }
  cargo "$@" >"$out" 2>"$err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if grep -q 'Blocking waiting for file lock' "$err" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 200
    fi
    sleep 0.1
  done
  wait "$pid"
}

input=$(cat)
if command -v jq >/dev/null 2>&1; then
  if ! file=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty'); then
    say "could not read the hook input with jq, so this edit was not checked."
  fi
  parsed=1
else
  file=$(printf '%s' "$input" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  parsed=0
fi
[[ $file == *.rs && -f $file ]] || exit 0
file=$(realpath -- "$file")

root=$(workspace_root "$(dirname "$file")") || exit 0
if ((!parsed)); then
  say "jq is not on PATH, so the edited path can't be read reliably and this edit was not checked."
fi
cd "$root" || say "cannot cd to $root, so this edit was not checked."
rel=$(realpath --relative-to=. "$file")

tmp=$(mktemp -d) || say "could not create a temporary directory, so this edit was not checked."
trap 'rm -rf "$tmp"' EXIT
run_cargo "$tmp/out" "$tmp/err" check --workspace --message-format=json
code=$?
if ((code == 200)); then
  say "cargo's build lock is held (another cargo is running, probably yours), so cargo check was not run for $rel."
fi

findings=$(jq -R -r --arg f "$rel" '
  fromjson? | select(.reason == "compiler-message") | .message
  | select(.level == "error" or .level == "warning")
  | select((.message | test("^(aborting due to|could not compile|[0-9]+ warnings? emitted|build failed)")) | not)
  | ([.spans[] | select(.is_primary)][0] // .spans[0]) as $p
  | select(.level == "error" or ($p != null and $p.file_name == $f))
  | (if $p then "\($p.file_name):\($p.line_start):\($p.column_start): " else "" end)
    + "\(.level): \(.message)" + (if .code then " [\(.code.code)]" else "" end)
    + (if $p.label then "\n  \($p.label)" else "" end)
    + ([.children[]? | select(.message != "" and (.message | test("^(for further information visit|`-[WAD] |to override `-|requested on the command line)") | not)) | "\n  \(.level): \(.message)"] | join(""))
  | @json' "$tmp/out" 2>"$tmp/jqerr")
jqcode=$?
if ((jqcode != 0)); then
  say "could not read cargo's JSON output (jq exit $jqcode), so $rel was not checked: $(clip 5 <"$tmp/jqerr")"
fi
if [[ -n $findings ]]; then
  printf '%s\n' "$findings" | sort -u | jq -r . | clip 60 >&2
  exit 2
fi
if ((code != 0)); then
  say "cargo check failed (exit $code), so the code was not checked: $(clip 15 <"$tmp/err")"
fi
exit 0
