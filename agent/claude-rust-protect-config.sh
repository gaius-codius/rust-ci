#!/usr/bin/env bash
# Claude Code PreToolUse hook: before an agent changes a file that controls a
# project's checks, or adds a lint or test suppression, ask the human to approve
# it. An agent stuck on a finding can otherwise make it go away by weakening the
# check.
#
# It runs two hooks on the same input, side by side, and gives one answer:
#   - weakened-checks' hook (agent/claude-protect-config.sh in that repository),
#     which covers every language and reads the project's
#     .github/weakened-checks.conf. Found at $WEAKENED_CHECKS_HOOK, else
#     ~/.claude/hooks/protect-config.sh, the link weakened-checks' README installs.
#   - agent/rust-protect-remainder.sh beside this file's real path: rust-ci
#     v3.0.0's own hook, for what the shared one doesn't cover yet ([profile]
#     tables, removed deny/forbid/warn attributes, should_panic, cfg(miri),
#     gitleaks:allow, any Bash write to a Cargo.toml, and a few paths).
#
# Install: symlink it into ~/.claude/hooks/ and register it under PreToolUse for
# Edit|Write|MultiEdit|Bash (rust-ci README, "Claude Code hooks"). Don't register
# weakened-checks' hook as well.
#
# Outcomes:
#   exit 0 with JSON permissionDecision "ask": either hook asked. The reasons of
#     both are shown, rust-ci's first, with any note from the other.
#   exit 0 with JSON additionalContext: neither asked, and one had a note, or a
#     half could not run (missing, failed, too slow, output that isn't hook JSON,
#     jq missing). A shared hook missing from the default path is only mentioned
#     when rust-ci's half had something to say, so a machine without it isn't
#     told on every command; one WEAKENED_CHECKS_HOOK names always is. A deny
#     from a half counts as an ask.
#   exit 0, nothing: anything else, or RUST_CI_PROTECT_CONFIG=off, which turns
#     off both halves (WEAKENED_CHECKS_PROTECT_CONFIG=off only the shared one).
# It never blocks.
set -uo pipefail

[[ ${RUST_CI_PROTECT_CONFIG:-} == off ]] && exit 0

# Each half gets this many seconds: Claude Code drops a hook that outlives its
# registered timeout (10s in the README) without a word, so a slow half has to
# end in a note first.
deadline=8
opt_out="Set RUST_CI_PROTECT_CONFIG=off to turn this hook off (WEAKENED_CHECKS_PROTECT_CONFIG=off turns off only its weakened-checks half)."

# context <message>: a note that doesn't block, written by hand (jq may be missing).
context() {
  local m="rust protect hook: $1"
  m=${m//\\/\\\\}; m=${m//\"/\\\"}; m=${m//$'\n'/\\n}; m=${m//$'\t'/\\t}; m=${m//$'\r'/\\r}
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$m"
  exit 0
}

# ask_by_hand <reason>: an ask written without jq, for when combining fails.
ask_by_hand() {
  local m="rust protect hook: $1 $opt_out"
  m=${m//\\/\\\\}; m=${m//\"/\\\"}; m=${m//$'\n'/\\n}; m=${m//$'\t'/\\t}; m=${m//$'\r'/\\r}
  printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask", "permissionDecisionReason": "%s"}}\n' "$m"
  exit 0
}

self=$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null) ||
  self=${BASH_SOURCE[0]}
remainder=$(dirname -- "$self")/rust-protect-remainder.sh
shared=${WEAKENED_CHECKS_HOOK:-${HOME:-}/.claude/hooks/protect-config.sh}

tmp=$(mktemp -d 2>/dev/null) || context "mktemp failed, so this change was not checked for weakened checks."
trap 'rm -rf "$tmp"' EXIT
# The input goes to each half from a file: a half that exits before reading it
# (its own opt-out) would otherwise break a pipe and look like a failure.
cat >"$tmp/in"

# run_half <name> <path>: runs one hook on the input, leaving <name>.out and
# <name>.status: its exit code, "timeout", "relative", "missing" or "noexec".
run_half() {
  local name=$1 path=$2 code pid dog
  if [[ $path != /* ]]; then
    echo relative >"$tmp/$name.status"; return
  elif [[ ! -f $path ]]; then
    echo missing >"$tmp/$name.status"; return
  elif [[ ! -x $path ]]; then
    echo noexec >"$tmp/$name.status"; return
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 "$deadline" "$path" <"$tmp/in" >"$tmp/$name.out" 2>/dev/null
    code=$?
    [[ $code == 124 ]] && code=timeout
  else
    # No timeout(1) (macOS without coreutils): a watchdog of our own.
    "$path" <"$tmp/in" >"$tmp/$name.out" 2>/dev/null &
    pid=$!
    (sleep "$deadline" && : >"$tmp/$name.late" && kill -TERM "$pid" && sleep 1 && kill -KILL "$pid") >/dev/null 2>&1 &
    dog=$!
    wait "$pid"
    code=$?
    kill "$dog" 2>/dev/null
    [[ -e $tmp/$name.late ]] && code=timeout
  fi
  echo "$code" >"$tmp/$name.status"
}
# Their stderr (a "Killed" line from a stopped half) isn't the hook's output.
run_half rust "$remainder" 2>/dev/null &
run_half shared "$shared" 2>/dev/null &
wait

# problem <name> <label> <path>: what went wrong running a half, or nothing.
problem() {
  local status
  status=$(cat "$tmp/$1.status" 2>/dev/null) || status=lost
  case $status in
    0) ;;
    missing | noexec)
      [[ $status == missing ]] && status="was not found at $3" || status="at $3 is not executable"
      if [[ $1 == shared ]]; then
        echo "$2 $status (set WEAKENED_CHECKS_HOOK, or link agent/claude-protect-config.sh from a clone of weakened-checks to ~/.claude/hooks/protect-config.sh), so this change was checked only by rust-ci's own rules."
      else
        echo "$2 $status (keep this hook a symlink into a clone of rust-ci), so this change was checked only by weakened-checks' hook."
      fi ;;
    relative) echo "WEAKENED_CHECKS_HOOK is $3, not an absolute path, so $2 did not run and this change was checked only by rust-ci's own rules." ;;
    timeout) echo "$2 took longer than ${deadline}s and was stopped, so this change was not fully checked." ;;
    *) echo "$2 exited $status, so this change was not fully checked." ;;
  esac
}
rust_problem=$(problem rust "rust-ci's own check" "$remainder")
shared_problem=$(problem shared "weakened-checks' hook" "$shared")
: >>"$tmp/rust.out"; : >>"$tmp/shared.out"

# The default shared hook, missing, is said only when rust-ci's half had
# something to say; one named by WEAKENED_CHECKS_HOOK always is.
if [[ -z ${WEAKENED_CHECKS_HOOK:-} && $(cat "$tmp/shared.status" 2>/dev/null) == missing &&
  ! -s $tmp/rust.out && -z $rust_problem ]]; then
  shared_problem=""
fi

if [[ ! -s $tmp/rust.out && ! -s $tmp/shared.out && -z $rust_problem$shared_problem ]]; then
  exit 0
fi

# asked_raw: whether either half's output looks like an ask, read as text.
asked_raw() {
  grep -Eq '"permissionDecision"[[:space:]]*:[[:space:]]*"(ask|deny)"' "$tmp/rust.out" "$tmp/shared.out" 2>/dev/null
}

if ! command -v jq >/dev/null 2>&1; then
  # Neither half can ask without jq, and their notes can't be read back safely.
  asked_raw && ask_by_hand "a check asked, but jq is not on PATH to show why, so a human approves this change."
  context "jq is not on PATH, so this change was not checked for weakened checks."
fi

# Combine with jq: asks win (a deny counts as an ask), their reasons joined; every
# note, and every problem, goes with them: with an ask, in the reason (which is
# shown) and as additionalContext; without one, as additionalContext. The outputs
# are read from their files, so their size doesn't matter.
jq -n --rawfile rust "$tmp/rust.out" --rawfile shared "$tmp/shared.out" \
  --arg rust_problem "$rust_problem" --arg shared_problem "$shared_problem" --arg opt_out "$opt_out" '
  def bad($label): "rust protect hook: " + $label + " printed something that is not hook JSON, so this change was not fully checked.";
  # parse(<text>; <label>): {asks, notes} from one half output.
  def parse($t; $label):
    if ($t | test("^\\s*$")) then {asks: [], notes: []}
    else ([$t | fromjson?] | if length == 1 then .[0] else null end) as $j
      | if ($j | type) == "object" and ($j.hookSpecificOutput | type) == "object" then
          $j.hookSpecificOutput as $h
          | ($h.permissionDecisionReason | if type == "string" then . else ($label + " asked.") end) as $why
          | {asks: (if $h.permissionDecision == "ask" or $h.permissionDecision == "deny" then [$why] else [] end),
             notes: ((if ($h.additionalContext | type) == "string" and $h.additionalContext != "" then [$h.additionalContext]
                      elif $h.additionalContext == null then [] else [bad($label)] end)
                     + (if ($h.permissionDecision | IN(null, "ask", "deny", "allow")) then [] else [bad($label)] end))}
        else {asks: [], notes: [bad($label)]}
        end
    end;
  # Each reason ends with its own opt-out; one line naming both replaces them.
  def strip: sub(" ?Set (RUST_CI|WEAKENED_CHECKS)_PROTECT_CONFIG=off to turn this hook off\\.$"; "");
  parse($rust; "rust-ci'"'"'s own check") as $r
  | parse($shared; "weakened-checks'"'"' hook") as $s
  | ([$rust_problem, $shared_problem] | map(select(. != "") | "rust protect hook: " + .)) as $p
  | ($r.notes + $s.notes + $p) as $notes
  | ($r.asks + $s.asks | map(strip) | reduce .[] as $a ([]; if index([$a]) then . else . + [$a] end)) as $asks
  | if ($asks | length) > 0 then
      {hookSpecificOutput: ({hookEventName: "PreToolUse", permissionDecision: "ask",
        permissionDecisionReason: (($asks + $notes + [$opt_out]) | join(" "))}
        + if ($notes | length) > 0 then {additionalContext: ($notes | join("\n"))} else {} end)}
    elif ($notes | length) > 0 then
      {hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: ($notes | join("\n"))}}
    else empty
    end' 2>/dev/null && exit 0
# Combining failed: an ask still asks.
asked_raw && ask_by_hand "a check asked, but its answers could not be combined to show why, so a human approves this change."
context "could not combine the two halves' answers with jq, so this change was not fully checked."
