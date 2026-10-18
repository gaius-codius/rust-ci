#!/usr/bin/env bash
# Tests actions/env-guard/env-guard.sh: records a snapshot with a fake rustup
# toolchain (fake cargo, rustc and friends in a temporary CARGO_HOME), then runs
# the check the way action.yml does (/bin/bash --posix, the startup variables
# blanked) with the environment a project script could leave behind through
# $GITHUB_ENV and $GITHUB_PATH. Needs bash, git and Linux (/proc).
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="${src_root}/actions/env-guard/env-guard.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

home="${work}/home"
cargo_home="${home}/.cargo"
rustup_home="${home}/.rustup"
mkdir -p "${cargo_home}/bin" "${rustup_home}/toolchains/stable/bin" "${work}/fake" "${work}/elsewhere"
# rustc prints the sysroot named in sysroot.txt.
printf '%s\n' "${rustup_home}/toolchains/stable" >"${work}/sysroot.txt"
for tool in cargo cargo-clippy cargo-fmt rustdoc; do
  printf '#!/bin/sh\nexit 0\n' >"${cargo_home}/bin/${tool}"
done
printf '#!/bin/sh\ncat %q\n' "${work}/sysroot.txt" >"${cargo_home}/bin/rustc"
printf '#!/bin/sh\nexit 0\n' >"${work}/fake/cargo"
printf '#!/bin/sh\nexit 0\n' >"${work}/elsewhere/cargo-nextest"
chmod +x "${cargo_home}/bin/"* "${work}/fake/cargo" "${work}/elsewhere/cargo-nextest"

path="${cargo_home}/bin:/usr/local/bin:/usr/bin:/bin"
base_env=(HOME="${home}" PATH="${path}" CARGO_BUILD_WARNINGS=deny CARGO_TERM_COLOR=always)

# Record, as action.yml's first step does.
out="${work}/output"
: >"${out}"
env -i "${base_env[@]}" GITHUB_OUTPUT="${out}" GUARD_MODE=record \
  bash --noprofile --norc -e -c '. "$1"' guard "${script}" >/dev/null
snapshot="$(sed -n '/^snapshot<</,/^RUST_CI_SNAPSHOT_END$/{/^snapshot<</d;/^RUST_CI_SNAPSHOT_END$/d;p}' "${out}")"
if [[ ${snapshot} != *"command cargo=${cargo_home}/bin/cargo"* ]]; then
  echo "FAIL record: the snapshot doesn't hold cargo's place:"
  printf '%s\n' "${snapshot}" | sed 's/^/    /'
  exit 1
fi
echo "ok   record writes the snapshot"

printf '. "%s"\n' "${script}" >"${work}/run.sh"

failures=0

# run_case <name> <want: pass or fail> <want output substring or ""> [VAR=value]...
# Runs the check with the base environment plus the given variables (later
# ones win, so PATH= and HOME= replace the base's).
run_case() {
  local name="$1" want="$2" want_out="$3" o code
  shift 3
  o="$(env -i "${base_env[@]}" GUARD_MODE=check GUARD_SNAPSHOT="${snapshot}" \
    GUARD_WARNINGS=deny GUARD_TOOLS= BASH_ENV= ENV= SHELLOPTS= BASHOPTS= LD_PRELOAD= LD_AUDIT= \
    GUARD_SEEN_BASH_ENV= GUARD_SEEN_ENV= GUARD_SEEN_SHELLOPTS= GUARD_SEEN_BASHOPTS= \
    GUARD_SEEN_LD_PRELOAD= GUARD_SEEN_LD_AUDIT= "$@" \
    /bin/bash --posix --noprofile --norc -e "${work}/run.sh" 2>&1)"
  code=$?
  if [[ ${want} == pass && ${code} -ne 0 ]] || [[ ${want} == fail && ${code} -eq 0 ]] ||
    [[ -n ${want_out} && ${o} != *"${want_out}"* ]]; then
    echo "FAIL ${name}: exit ${code}, want ${want}${want_out:+ with [${want_out}]}; output:"
    printf '%s\n' "${o}" | sed 's/^/    /'
    failures=$((failures + 1))
  else
    echo "ok   ${name}"
  fi
}

run_case "untouched environment passes" pass "as rust-ci left it"
run_case "an empty RUSTFLAGS passes" pass "" RUSTFLAGS=
run_case "CARGO_TARGET_DIR and other settings pass" pass "" \
  CARGO_TARGET_DIR=/tmp/t CARGO_INCREMENTAL=0 CARGO_PROFILE_DEV_DEBUG=0 RUST_BACKTRACE=1

for var in RUSTFLAGS=--cap-lints=allow RUSTDOCFLAGS=--cap-lints=allow CARGO_ENCODED_RUSTFLAGS=x \
  CARGO_BUILD_RUSTFLAGS=x RUSTC_WRAPPER=/bin/true RUSTC_WORKSPACE_WRAPPER=/bin/true \
  CARGO_BUILD_RUSTC_WRAPPER=/bin/true RUSTC=/bin/true CARGO=/bin/true CLIPPY_ARGS=-Aclippy::all \
  CLIPPY_CONF_DIR=/tmp RUSTUP_TOOLCHAIN=evil RUSTC_BOOTSTRAP=1 NEXTEST_RETRIES=5 \
  NEXTEST_NO_TESTS=pass NEXTEST_PROFILE=default CARGO_ALIAS_CLIPPY=check CARGO_MUTANTS_JOBS=1 \
  CARGO_PROFILE_TEST_OVERFLOW_CHECKS=false CARGO_PROFILE_DEV_DEBUG_ASSERTIONS=false \
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUNNER=/bin/true CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=/x; do
  run_case "${var%%=*} fails" fail "${var%%=*} is set" "${var}"
done

run_case "CARGO_BUILD_WARNINGS=warn fails" fail "CARGO_BUILD_WARNINGS is 'warn'" CARGO_BUILD_WARNINGS=warn
run_case "CARGO_BUILD_WARNINGS unset fails" fail "CARGO_BUILD_WARNINGS is ''" CARGO_BUILD_WARNINGS=
run_case "CARGO_BUILD_WARNINGS=warn passes where warn is wanted" pass "" \
  CARGO_BUILD_WARNINGS=warn GUARD_WARNINGS=warn

run_case "BASH_ENV from \$GITHUB_ENV fails" fail "BASH_ENV is set" GUARD_SEEN_BASH_ENV=/tmp/x.sh
run_case "LD_PRELOAD from \$GITHUB_ENV fails" fail "LD_PRELOAD is set" GUARD_SEEN_LD_PRELOAD=/tmp/x.so
run_case "SHELLOPTS from \$GITHUB_ENV fails" fail "SHELLOPTS is set" GUARD_SEEN_SHELLOPTS=noexec

run_case "an exported function fails" fail "exported shell function, cargo," 'BASH_FUNC_cargo%%=() {  :
}'
run_case "an exported function named after a builtin the guard uses fails" fail \
  "exported shell function, printf," 'BASH_FUNC_printf%%=() {  :
}'

run_case "another cargo first on PATH fails" fail "cargo is now '${work}/fake/cargo'" \
  PATH="${work}/fake:${path}"
run_case "a changed CARGO_HOME fails" fail "CARGO_HOME is" CARGO_HOME="${work}/fake"
run_case "a changed RUSTUP_HOME fails" fail "RUSTUP_HOME is" RUSTUP_HOME="${work}/fake"
run_case "a changed HOME fails" fail "HOME is" HOME="${work}/elsewhere"

cp "${work}/elsewhere/cargo-nextest" "${cargo_home}/bin/"
run_case "a tool in CARGO_HOME/bin passes" pass "" GUARD_TOOLS="cargo-nextest"
run_case "a tool elsewhere on PATH fails" fail "cargo-nextest is '${work}/elsewhere/cargo-nextest'" \
  GUARD_TOOLS="cargo-nextest" PATH="${work}/elsewhere:${path}"
run_case "a missing tool fails" fail "cargo-mutants is 'not found'" GUARD_TOOLS="cargo-mutants"

printf '%s\n' "/opt/other-rust" >"${work}/sysroot.txt"
run_case "rustc outside the rustup toolchains fails" fail "rustc's sysroot is '/opt/other-rust'"

run_case "an empty snapshot fails" fail "snapshot is empty" GUARD_SNAPSHOT=

# In a PID namespace that keeps the host's /proc (as a runner under pasta or
# unshare does), the shell's $$ isn't its PID in /proc. Skipped where
# unprivileged user namespaces aren't allowed.
if unshare --user --pid --fork true 2>/dev/null; then
  base_run=(env -i "${base_env[@]}" GUARD_MODE=check GUARD_SNAPSHOT="${snapshot}"
    GUARD_WARNINGS=deny GUARD_TOOLS= BASH_ENV= ENV= SHELLOPTS= BASHOPTS= LD_PRELOAD= LD_AUDIT=
    GUARD_SEEN_BASH_ENV= GUARD_SEEN_ENV= GUARD_SEEN_SHELLOPTS= GUARD_SEEN_BASHOPTS=
    GUARD_SEEN_LD_PRELOAD= GUARD_SEEN_LD_AUDIT=)
  printf '%s\n' "${rustup_home}/toolchains/stable" >"${work}/sysroot.txt"
  for want in pass fail; do
    extra=()
    [[ ${want} == fail ]] && extra=(RUSTFLAGS=--cap-lints=allow)
    o="$(unshare --user --pid --fork "${base_run[@]}" "${extra[@]}" \
      /bin/bash --posix --noprofile --norc -e "${work}/run.sh" 2>&1)"
    code=$?
    if [[ ${want} == pass && ${code} -ne 0 ]] || [[ ${want} == fail && ( ${code} -eq 0 || ${o} != *RUSTFLAGS* ) ]]; then
      echo "FAIL in a PID namespace, want ${want}: exit ${code}; output:"
      printf '%s\n' "${o}" | sed 's/^/    /'
      failures=$((failures + 1))
    else
      echo "ok   in a PID namespace with the host's /proc, the check gives ${want}"
    fi
  done
else
  echo "skip in a PID namespace (unshare --user --pid not allowed here)"
fi

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} case(s) failed"
  exit 1
fi
echo "all env-guard cases passed"
