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
#     jq missing). A missing shared hook is only mentioned when rust-ci's half
#     had something to say, so a machine without it isn't told on every command.
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
# <name>.status (its exit code, or "missing").
run_half() {
  local name=$1 path=$2 code
  if [[ ! -f $path || ! -x $path ]]; then
    echo missing >"$tmp/$name.status"
    return
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 "$deadline" "$path" <"$tmp/in" >"$tmp/$name.out" 2>/dev/null
  else
    "$path" <"$tmp/in" >"$tmp/$name.out" 2>/dev/null
  fi
  code=$?
  echo "$code" >"$tmp/$name.status"
}
run_half rust "$remainder" &
run_half shared "$shared" &
wait

# problem <name> <label>: what went wrong running a half, or nothing.
problem() {
  local status
  status=$(cat "$tmp/$1.status" 2>/dev/null) || status=lost
  case $status in
    0) ;;
    missing)
      if [[ $1 == shared ]]; then
        echo "weakened-checks' hook was not found at $shared (set WEAKENED_CHECKS_HOOK, or link agent/claude-protect-config.sh from a clone of weakened-checks there), so this change was checked only by rust-ci's own rules."
      else
        echo "$2 was not found at $remainder (keep this hook a symlink into a clone of rust-ci), so this change was checked only by weakened-checks' hook."
      fi ;;
    124 | 137) echo "$2 took longer than ${deadline}s and was stopped, so this change was not fully checked." ;;
    *) echo "$2 exited $status, so this change was not fully checked." ;;
  esac
}
rust_problem=$(problem rust "rust-ci's own check")
shared_problem=$(problem shared "weakened-checks' hook")
rust_out=$(cat "$tmp/rust.out" 2>/dev/null)
shared_out=$(cat "$tmp/shared.out" 2>/dev/null)

# A missing shared hook is said only when rust-ci's half had something to say.
if [[ $(cat "$tmp/shared.status" 2>/dev/null) == missing && -z $rust_out && -z $rust_problem ]]; then
  shared_problem=""
fi

if [[ -z $rust_out$shared_out$rust_problem$shared_problem ]]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  # Neither half can ask without jq, and their notes can't be read back safely.
  context "jq is not on PATH, so this change was not checked for weakened checks."
fi

# Combine with jq: asks win, their reasons joined; every note, and every problem,
# goes with them: with an ask, in the reason (which is shown) and as
# additionalContext; without one, as additionalContext.
jq -n --arg rust "$rust_out" --arg shared "$shared_out" \
  --arg rust_problem "$rust_problem" --arg shared_problem "$shared_problem" --arg opt_out "$opt_out" '
  # parse(<text>; <label>): {asks, notes} from one half output.
  def parse($t; $label):
    if $t == "" then {asks: [], notes: []}
    else (try ([$t | fromjson?] | if length == 1 then .[0] else null end) catch null) as $j
      | if ($j | type) == "object" and ($j.hookSpecificOutput | type) == "object" then
          $j.hookSpecificOutput as $h
          | {asks: (if $h.permissionDecision == "ask" then [$h.permissionDecisionReason // ($label + " asked")] else [] end),
             notes: (if ($h.additionalContext // "") != "" then [$h.additionalContext] else [] end)}
        else {asks: [], notes: ["rust protect hook: " + $label + " printed something that is not hook JSON, so this change was not fully checked."]}
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
    else
      {hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: ($notes | join("\n"))}}
    end' 2>/dev/null || context "could not combine the two halves' answers with jq, so this change was not fully checked."
exit 0
