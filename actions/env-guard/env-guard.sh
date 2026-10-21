# shellcheck shell=bash
# Sourced by action.yml. GUARD_MODE=record writes a snapshot of where the
# toolchain is to $GITHUB_OUTPUT; GUARD_MODE=check compares the environment
# with GUARD_SNAPSHOT and fails on a variable or a PATH entry a project script
# could use to weaken the checks. See action.yml.

# In check mode this runs under bash --posix, where unset (a special builtin)
# comes before functions: a function exported through $GITHUB_ENV can't stand
# in for the builtins used below. Any other exported function fails the check.
unset -f builtin command declare printf read type 2>/dev/null

# The commands that must still resolve where they did before project code ran.
guard_commands=(cargo cargo-clippy cargo-fmt rustc rustdoc git bash)

if [[ ${GUARD_MODE} == record ]]; then
  {
    printf 'snapshot<<RUST_CI_SNAPSHOT_END\n'
    printf 'home=%s\n' "${HOME}"
    printf 'cargo-home=%s\n' "${CARGO_HOME:-${HOME}/.cargo}"
    printf 'rustup-home=%s\n' "${RUSTUP_HOME:-${HOME}/.rustup}"
    for name in "${guard_commands[@]}"; do
      printf 'command %s=%s\n' "${name}" "$(command -v "${name}" || true)"
    done
    printf 'RUST_CI_SNAPSHOT_END\n'
  } >>"${GITHUB_OUTPUT}"
  printf 'Recorded the toolchain place:\n'
  printf '  %s\n' "HOME=${HOME}" "CARGO_HOME=${CARGO_HOME:-${HOME}/.cargo}" \
    "RUSTUP_HOME=${RUSTUP_HOME:-${HOME}/.rustup}" "cargo: $(command -v cargo || true)"
  return 0
fi

guard_failures=0
guard_fail() {
  printf '::error title=rust-ci env guard::%s\n' "$1"
  guard_failures=$((guard_failures + 1))
}

# The snapshot, as written in record mode.
declare -A guard_was=()
while IFS= read -r line; do
  [[ ${line} == *=* ]] || continue
  guard_was["${line%%=*}"]="${line#*=}"
done <<<"${GUARD_SNAPSHOT}"
if [[ -z ${guard_was[cargo-home]:-} || -z ${guard_was[home]:-} ]]; then
  guard_fail "the snapshot is empty or incomplete; record one before any project script runs."
  exit 1
fi

# Read at startup by bash or the loader; blanked for this step, seen through
# the env context.
for name in BASH_ENV ENV SHELLOPTS BASHOPTS LD_PRELOAD LD_AUDIT; do
  seen="GUARD_SEEN_${name}"
  if [[ -n ${!seen} ]]; then
    guard_fail "${name} is set (${!seen}); a project script must not set it through \$GITHUB_ENV."
  fi
done

# Variables that change how the code is built, linted or tested. An empty
# value changes nothing, so only a value counts.
guard_denied=" RUSTFLAGS RUSTDOCFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_ENCODED_RUSTDOCFLAGS
  CARGO_BUILD_RUSTFLAGS CARGO_BUILD_RUSTDOCFLAGS RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER
  CARGO_BUILD_RUSTC_WRAPPER CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER RUSTC CARGO_BUILD_RUSTC
  RUSTDOC CARGO_BUILD_RUSTDOC CARGO CLIPPY_ARGS CLIPPY_CONF_DIR RUSTUP_TOOLCHAIN
  RUSTC_BOOTSTRAP "
guard_denied="${guard_denied//$'\n'/ }"

# The process's own environment, as the runner started it: what $GITHUB_ENV
# set, including exported functions (BASH_FUNC_<name>%%), which bash doesn't
# list as variables. /proc/self, not /proc/$$: the shell opens the redirect
# itself, so self is this shell, and $$ is a PID in the shell's own namespace,
# which a runner in a PID namespace with the host's /proc (pasta, unshare)
# doesn't have, or has as another process.
while IFS= read -r -d '' entry; do
  name="${entry%%=*}"
  value="${entry#*=}"
  case "${name}" in
    BASH_FUNC_*)
      name="${name#BASH_FUNC_}"
      guard_fail "an exported shell function, ${name%\%\%}, is set; it would stand in for a command in later steps."
      continue
      ;;
    GUARD_* | BASH_ENV | ENV | SHELLOPTS | BASHOPTS | LD_PRELOAD | LD_AUDIT) continue ;;
  esac
  [[ -n ${value} ]] || continue
  case "${name}" in
    NEXTEST_* | CARGO_ALIAS_* | CARGO_MUTANTS_* | CARGO_HOST_* | \
      CARGO_TARGET_*_RUNNER | CARGO_TARGET_*_LINKER | CARGO_TARGET_*_RUSTFLAGS | CARGO_TARGET_*_RUSTDOCFLAGS | \
      CARGO_PROFILE_*_OVERFLOW_CHECKS | CARGO_PROFILE_*_DEBUG_ASSERTIONS | CARGO_PROFILE_*_RUSTFLAGS)
      guard_fail "${name} is set (${value}); a project script must not set it through \$GITHUB_ENV."
      ;;
    *)
      if [[ ${guard_denied} == *" ${name} "* ]]; then
        guard_fail "${name} is set (${value}); a project script must not set it through \$GITHUB_ENV."
      fi
      ;;
  esac
done </proc/self/environ

if [[ ${CARGO_BUILD_WARNINGS:-} != "${GUARD_WARNINGS}" ]]; then
  guard_fail "CARGO_BUILD_WARNINGS is '${CARGO_BUILD_WARNINGS:-}', not '${GUARD_WARNINGS}'."
fi
if [[ ${HOME} != "${guard_was[home]}" ]]; then
  guard_fail "HOME is ${HOME}, not ${guard_was[home]} as when the toolchain was installed."
fi
if [[ ${CARGO_HOME:-${HOME}/.cargo} != "${guard_was[cargo-home]}" ]]; then
  guard_fail "CARGO_HOME is ${CARGO_HOME:-${HOME}/.cargo}, not ${guard_was[cargo-home]} as when the toolchain was installed."
fi
if [[ ${RUSTUP_HOME:-${HOME}/.rustup} != "${guard_was[rustup-home]}" ]]; then
  guard_fail "RUSTUP_HOME is ${RUSTUP_HOME:-${HOME}/.rustup}, not ${guard_was[rustup-home]} as when the toolchain was installed."
fi

# The commands resolve where they did before project code ran.
for name in "${guard_commands[@]}"; do
  was="${guard_was["command ${name}"]:-}"
  now="$(command -v "${name}" || true)"
  if [[ ${now} != "${was}" ]]; then
    guard_fail "${name} is now '${now:-not found}', not '${was:-not found}' as when the toolchain was installed; a project script must not change PATH."
  fi
done

# Tools installed since. A name: install-action puts it in $CARGO_HOME/bin,
# or in ~/.install-action/bin when cargo isn't there. A path (actions/install-
# tool's path output): the tool must resolve to exactly that file.
for tool in ${GUARD_TOOLS}; do
  name="${tool##*/}"
  now="$(command -v "${name}" || true)"
  if [[ ${tool} == /* ]]; then
    if [[ ${now} != "${tool}" || ! -f ${tool} ]]; then
      guard_fail "${name} is '${now:-not found}', not the one rust-ci installed at ${tool}."
    fi
    continue
  fi
  case "${now}" in
    "${guard_was[cargo-home]}/bin/${name}" | "${guard_was[home]}/.install-action/bin/${name}") ;;
    *) guard_fail "${name} is '${now:-not found}', not the one install-action installed in ${guard_was[cargo-home]}/bin." ;;
  esac
done

# rustc runs from a toolchain rustup installed.
if [[ -n ${guard_was["command rustc"]:-} && ${guard_failures} -eq 0 ]]; then
  sysroot="$(rustc --print sysroot)" || sysroot=""
  if [[ ${sysroot} != "${guard_was[rustup-home]}/toolchains/"* ]]; then
    guard_fail "rustc's sysroot is '${sysroot}', not a toolchain in ${guard_was[rustup-home]}/toolchains."
  fi
fi

if [[ ${guard_failures} -ne 0 ]]; then
  exit 1
fi
printf 'The environment is as rust-ci left it.\n'
