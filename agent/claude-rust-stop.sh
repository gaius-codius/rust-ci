#!/usr/bin/env bash
# Claude Code Stop / SubagentStop hook: when Rust files changed against the merge-base,
# run `cargo clippy --workspace --all-targets --message-format=json` and block the stop
# while there are findings.
#
# Install: symlink it into ~/.claude/hooks/ and register it for both Stop and
# SubagentStop (rust-ci README, "Claude Code hooks").
#
# Outcomes:
#   exit 2, findings on stderr: clippy ran and found problems. Every error is reported
#     wherever it is (a change can break files it never touched); warnings only in the
#     files that changed, so the existing backlog doesn't nag. Clippy's suggested
#     replacement text is shown, never applied. Claude keeps working.
#   exit 0, nothing: not in a git repo or Cargo workspace, nothing Rust changed against
#     the merge-base, or no findings.
#   exit 0 with JSON additionalContext (hookSpecificOutput): a non-blocking report not
#     delivered before: the check could not run (cargo or clippy missing, a failed
#     dependency fetch, a crash, the build lock held by the agent's own cargo), or the
#     blocking findings are unchanged since the last block. On Stop this makes Claude
#     continue the turn, so each distinct report is delivered once.
#   exit 0 with JSON systemMessage: the same report again. It shows to the user and
#     doesn't continue the turn, so the hook can't loop.
#
# Loop protection: when stop_hook_active is true and the findings equal the last blocking
# set (same checked tree, same diagnostics), blocking again can't help; the findings are
# reported through the non-blocking path instead. State lives under the git dir. Without
# sha256sum or shasum nothing can be remembered, so every report goes out as systemMessage.
#
# This hook does not run when the user interrupts Claude, so CI stays the gate.
set -uo pipefail

event=Stop
state_name=rust-ci-stop-hook

# emit <message> <fresh>: print the JSON for the hook and exit 0.
emit() {
  local m="rust stop hook: $1" fresh=$2 field=systemMessage
  if [[ $fresh == 1 ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg m "$m" --arg e "$event" '{hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
      exit 0
    fi
    field=additionalContext
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg m "$m" '{systemMessage: $m}'
  else
    m=${m//\\/\\\\}; m=${m//\"/\\\"}; m=${m//$'\n'/\\n}
    if [[ $field == additionalContext ]]; then
      printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$event" "$m"
    else
      printf '{"systemMessage":"%s"}\n' "$m"
    fi
  fi
  exit 0
}

# sha <stdin>: hex sha256 of stdin, or nothing when no tool is available.
sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  fi
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
# a held build lock (the agent may be running cargo itself). Returns cargo's exit code,
# 127 when cargo is missing, 200 when the lock is held.
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
cwd=$PWD
active=false
if command -v jq >/dev/null 2>&1; then
  e=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null) && [[ -n $e ]] && event=$e
  c=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) && [[ -n $c ]] && cwd=$c
  a=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null) && [[ $a == true ]] && active=true
else
  c=$(printf '%s' "$input" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [[ -n $c ]] && cwd=$c
  grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$input" && active=true
fi
[[ $event == Stop || $event == SubagentStop ]] || event=Stop

cd "$cwd" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
root=$(workspace_root "$(pwd -P)") || exit 0
cd "$root" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
gitdir=$(git rev-parse --absolute-git-dir 2>/dev/null) || gitdir=""
state="$gitdir/$state_name"

# notify <message>: the non-blocking report. Each distinct report (same tree, same
# text) goes out once as additionalContext; repeats go as systemMessage.
notify() {
  local key fresh=0
  key=$(printf '%s\n%s' "$tree" "$1" | sha)
  if [[ -n $key && -n $tree && -n $gitdir ]] && mkdir -p "$state" 2>/dev/null; then
    if ! grep -qx "$key" "$state/delivered-$event" 2>/dev/null; then
      printf '%s\n' "$key" >>"$state/delivered-$event" 2>/dev/null && fresh=1
    fi
  fi
  emit "$1" "$fresh"
}

tree=""

# The merge-base with the default branch; the checked tree is the working tree.
base=""
for ref in origin/HEAD origin/main origin/master main master; do
  if base=$(git merge-base HEAD "$ref" 2>/dev/null) && [[ -n $base ]]; then break; fi
  base=""
done
if [[ -z $base ]]; then
  notify "could not find a merge-base with origin/main or main, so clippy was not run."
fi

# H2: Rust files changed against the base, committed or not, relative to the workspace root.
changed=$({ git diff --relative --name-only "$base" -- . 2>/dev/null; git ls-files -o --exclude-standard 2>/dev/null; } |
  grep -E '\.rs$|(^|/)(Cargo\.(toml|lock)|\.?clippy\.toml|rust-toolchain(\.toml)?)$' | sort -u)
[[ -n $changed ]] || exit 0

tree=$({ printf '%s\n' "$base"; git diff --relative "$base" -- . 2>/dev/null
  git ls-files -o --exclude-standard 2>/dev/null | while IFS= read -r f; do printf '%s %s\n' "$f" "$(git hash-object -- "$f" 2>/dev/null)"; done; } | sha)

if ! command -v jq >/dev/null 2>&1; then
  notify "jq is not on PATH, so clippy's JSON output can't be read and clippy was not run."
fi

tmp=$(mktemp -d) || notify "could not create a temporary directory, so clippy was not run."
trap 'rm -rf "$tmp"' EXIT
run_cargo "$tmp/out" "$tmp/err" clippy --workspace --all-targets --message-format=json
code=$?
if ((code == 200)); then
  notify "cargo's build lock is held (another cargo is running, probably yours), so clippy was not run. Run 'cargo clippy --workspace --all-targets' yourself once the other cargo finishes."
fi

# One finding per line (JSON): errors anywhere, warnings only in changed files, with
# clippy's suggested replacements spelled out. Non-JSON lines (cargo's own) are skipped.
findings=$(jq -R -r --rawfile changed <(printf '%s\n' "$changed") '
  fromjson? | select(.reason == "compiler-message") | .message
  | select(.level == "error" or .level == "warning")
  | select((.message | test("^(aborting due to|could not compile|[0-9]+ warnings? emitted|build failed)")) | not)
  | ([.spans[] | select(.is_primary)][0] // .spans[0]) as $p
  | select(.level == "error" or ($p != null and (($changed | split("\n")) | index($p.file_name) != null)))
  | ([.spans[]?, (.children[]?.spans[]?)] | map(select(.suggested_replacement != null))) as $fixes
  | (if $p then "\($p.file_name):\($p.line_start):\($p.column_start): " else "" end)
    + "\(.level): \(.message)" + (if .code then " [\(.code.code)]" else "" end)
    + (if $p.label then "\n  \($p.label)" else "" end)
    + ([.children[]? | select(.message != "" and (.message | test("^(for further information visit|`-[WAD] |to override `-|requested on the command line)") | not)) | "\n  \(.level): \(.message)"] | join(""))
    + ([$fixes[] | "\n  suggestion: at \(.file_name):\(.line_start):\(.column_start)-\(.line_end):\(.column_end) replace with `\(.suggested_replacement | rtrimstr("\n"))`"] | join(""))
  | @json' "$tmp/out" 2>"$tmp/jqerr")
jqcode=$?
if ((jqcode != 0)); then
  notify "could not read clippy's JSON output (jq exit $jqcode), so clippy findings were not checked: $(clip 5 <"$tmp/jqerr")"
fi
diagnostics=""
if [[ -n $findings ]]; then
  diagnostics=$(printf '%s\n' "$findings" | sort -u | jq -r .)
fi

if [[ -z $diagnostics ]]; then
  if ((code != 0)); then
    # No diagnostics but a failed run: the code wasn't judged (a missing tool, a failed
    # fetch, a failing build script, a crash). Never "no findings".
    notify "cargo clippy failed (exit $code), so clippy did not check the code: $(clip 15 <"$tmp/err")"
  fi
  exit 0
fi

# Blocking findings. H3: with the same tree and diagnostics as the last block, and the
# agent already continuing because of this hook, blocking again can't help.
key=$(printf '%s\n%s' "$tree" "$diagnostics" | sha)
body=$(printf '%s\n' "$diagnostics" | clip 60)
msg="cargo clippy --workspace --all-targets found problems (errors anywhere, warnings in files you changed; suggestions are not applied):"$'\n'"$body"
if [[ $active == true && -n $key && -f "$state/block-$event" ]] && grep -qx "$key" "$state/block-$event" 2>/dev/null; then
  notify "$msg"$'\n\n'"These findings were already reported and are unchanged, so the hook is not blocking again. Tell the user they remain unresolved."
fi
if [[ -n $key && -n $gitdir ]] && mkdir -p "$state" 2>/dev/null; then
  printf '%s\n' "$key" >"$state/block-$event" 2>/dev/null
fi
printf '%s\n' "$msg" >&2
exit 2
