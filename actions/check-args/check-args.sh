#!/usr/bin/env bash
# check-args.sh <gitleaks|mutants|nextest|deny>: fails on an argument in
# $ARGUMENTS (split on spaces, as rust.yml splits it) that would make the check
# pass without checking, or that replaces one rust.yml passes itself. Both
# --flag value and --flag=value are caught, and a short flag inside a cluster
# (-vE x). See action.yml.
set -euo pipefail

tool="${1:?usage: check-args.sh <gitleaks|mutants|nextest|deny>}"
read -r -a args <<<"${ARGUMENTS:-}"

# Per tool: the input the arguments come from; long flags (without --) and
# short letters that are rejected, each with the reason; the short letters that
# take a value (the rest of a cluster after one is its value); and whether the
# scan stops at "--" (what follows goes to another program).
declare -A long=() short=()
stop_at_dashes=0
case "${tool}" in
  gitleaks)
    input=gitleaks-arguments
    takes_value=bcilfr
    for f in exit-code baseline-path enable-rule gitleaks-ignore-path; do
      long[${f}]="makes gitleaks skip or forgive findings"
    done
    long[config]="use the gitleaks-config input"
    long[log-opts]="the job sets the commits to scan"
    long[pre-commit]="scans the working tree's diff, not the pull request's commits"
    long[staged]="scans the index, not the pull request's commits"
    short[b]="${long[baseline-path]}"
    short[i]="${long[gitleaks-ignore-path]}"
    short[c]="${long[config]}"
    ;;
  mutants)
    input=mutants-arguments
    takes_value=LCjtFeEfDpdo
    stop_at_dashes=1
    for f in list list-files check emit-schema completions Zmutate-file; do
      long[${f}]="runs no tests"
    done
    for f in exclude exclude-re re file package dir manifest-path shard iterate; do
      long[${f}]="leaves out mutants the pull request's diff makes"
    done
    long[baseline]="skips the check that the tests pass before mutating"
    for f in in-diff in-place output no-config config; do
      long[${f}]="the job passes its own (--in-diff, --in-place, --output, --no-config)"
    done
    short[F]="${long[re]}"
    short[e]="${long[exclude]}"
    short[E]="${long[exclude-re]}"
    short[f]="${long[file]}"
    short[p]="${long[package]}"
    short[d]="${long[dir]}"
    short[D]="${long[in-diff]}"
    short[o]="${long[output]}"
    ;;
  nextest)
    input=test-command
    takes_value=pFjEPR
    # Drop the "cargo nextest run" the test step checks for.
    if [[ ${args[*]:0:3} == "cargo nextest run" ]]; then
      args=("${args[@]:3}")
    fi
    long[retries]="passes a failing test that passes on a retry"
    long[no-run]="builds the tests without running them"
    long[partition]="runs only part of the tests"
    long[rerun]="${long[partition]}"
    long[ignored]="runs only the ignored tests"
    for f in debugger tracer; do
      long[${f}]="runs the tests under another program"
    done
    for f in archive-file archive-format extract-to binaries-metadata cargo-metadata workspace-remap target-dir-remap build-dir-remap manifest-path; do
      long[${f}]="runs tests other than the workspace's"
    done
    for f in config config-file user-config-file tool-config-file; do
      long[${f}]="replaces the checked cargo or nextest config"
    done
    short[R]="${long[rerun]}"
    ;;
  deny)
    input=deny-arguments
    takes_value=Lfct
    long[config]="replaces the checked deny.toml"
    for f in manifest-path metadata-path exclude; do
      long[${f}]="checks a crate graph other than the workspace's"
    done
    ;;
  *)
    echo "::error::check-args.sh: unknown tool '${tool}'" >&2
    exit 2
    ;;
esac
# Help and version print and exit 0 without checking anything.
long[help]="prints help and runs no check"
long[version]="prints the version and runs no check"
short[h]="${long[help]}"
if [[ ${tool} == deny ]]; then
  short[V]="${long[version]}"
fi

failures=0
reject() {
  echo "::error title=rust-ci arguments::${input}: ${1} is not allowed: ${2}."
  failures=$((failures + 1))
}

n=${#args[@]}
for ((i = 0; i < n; i++)); do
  arg="${args[i]}"
  if [[ ${arg} == -- ]]; then
    [[ ${stop_at_dashes} -eq 1 ]] && break
    continue
  fi
  if [[ ${arg} == --* ]]; then
    name="${arg#--}"
    name="${name%%=*}"
    if [[ ${arg} == *=* ]]; then
      value="${arg#*=}"
    else
      value="${args[i + 1]:-}"
    fi
    if [[ -n ${long[${name}]:-} ]]; then
      reject "--${name}" "${long[${name}]}"
    elif [[ ${tool} == nextest && ${name} == no-tests && ${value} =~ ^(pass|warn)$ ]]; then
      reject "--no-tests=${value}" "passes a run that finds no tests"
    elif [[ ${tool} == nextest && ${name} == flaky-result && ${value} == pass ]]; then
      reject "--flaky-result=${value}" "${long[retries]}"
    elif [[ ${tool} == nextest && ${name} == run-ignored && ${value} =~ ^(only|ignored-only)$ ]]; then
      reject "--run-ignored=${value}" "${long[ignored]}"
    fi
  elif [[ ${arg} == -?* ]]; then
    # A cluster of short flags; the letters after one that takes a value are
    # its value.
    letters="${arg#-}"
    for ((j = 0; j < ${#letters}; j++)); do
      c="${letters:j:1}"
      if [[ -n ${short[${c}]:-} ]]; then
        reject "-${c}" "${short[${c}]}"
        break
      fi
      [[ ${takes_value} == *"${c}"* ]] && break
    done
  elif [[ ${tool} == deny && ${arg} =~ ^(check|fetch|init|list|help)$ ]]; then
    reject "${arg}" "the job runs \`cargo deny ... check\` itself"
  fi
done

if [[ ${failures} -ne 0 ]]; then
  exit 1
fi
echo "${input}: no argument that weakens the check."
