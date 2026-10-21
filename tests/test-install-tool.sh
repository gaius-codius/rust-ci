#!/usr/bin/env bash
# Tests actions/install-tool/install-tool.sh: runs its steps the way action.yml
# does, with a fake install-action (a function that writes the binary into
# $HOME/.install-action/bin, as install-action does with HOME in the stage
# folder) and release archives served from file:// URLs through a curl that
# counts its downloads. Needs bash, curl, tar, sha256sum and GNU coreutils.
set -uo pipefail

src_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="${src_root}/actions/install-tool/install-tool.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# Two versions of a fake tool, and a release archive of each.
mkdir -p "${work}/src/1.0.0" "${work}/src/2.0.0" "${work}/bin"
for v in 1.0.0 2.0.0; do
  printf '#!/bin/sh\necho "fake-tool %s"\n' "${v}" >"${work}/src/${v}/fake-tool"
  chmod +x "${work}/src/${v}/fake-tool"
  tar -czf "${work}/src/${v}.tar.gz" -C "${work}/src/${v}" fake-tool
done
sha_of() { sha256sum -- "$1" | cut -d' ' -f1; }
sha1="$(sha_of "${work}/src/1.0.0/fake-tool")"
sha2="$(sha_of "${work}/src/2.0.0/fake-tool")"
downloads="${work}/downloads"
: >"${downloads}"
real_curl="$(command -v curl)"
printf '#!/bin/sh\necho download >>%q\nexec %q "$@"\n' "${downloads}" "${real_curl}" >"${work}/bin/curl"
chmod +x "${work}/bin/curl"
export PATH="${work}/bin:${PATH}"

failures=0
fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}
ok() { echo "ok   $1"; }

# out_of <file> <key>: a key=value line from a GITHUB_OUTPUT file.
out_of() { sed -n "s/^$2=//p" "$1" | tail -1; }

# run_tool <job> <target-dir> <tool> <sha256> [archive]: one job's run of the
# action, in a folder of its own (<work>/jobs/<job>: GITHUB_OUTPUT, GITHUB_PATH,
# runner.temp). archive is a version whose release archive to download;
# without it the fake install-action installs the tool. Prints the step logs;
# returns the first failing step's status.
run_tool() {
  local job="$1" target="$2" tool="$3" sha="$4" archive="${5:-}"
  local jd="${work}/jobs/${job}" url="" asha=""
  mkdir -p "${jd}/temp"
  : >"${jd}/output"
  : >"${jd}/path"
  if [[ -n ${archive} ]]; then
    url="file://${work}/src/${archive}.tar.gz"
    asha="$(sha_of "${work}/src/${archive}.tar.gz")"
  fi
  local -a env=(GITHUB_OUTPUT="${jd}/output" GITHUB_PATH="${jd}/path" TOOL="${tool}"
    TOOL_SHA256="${sha}" TARGET_ROOT="${target}" ARCHIVE_URL="${url}" ARCHIVE_SHA256="${asha}"
    JOB_DIR="${jd}/temp/rust-ci-tools/${tool}" ADD_TO_PATH=true)
  env "${env[@]}" TOOL_STEP=prepare bash "${script}" || return
  local mode stage
  mode="$(out_of "${jd}/output" mode)"
  stage="$(out_of "${jd}/output" stage)"
  if [[ -z ${url} && ${mode} == install ]]; then
    # install-action with HOME in the stage folder.
    echo install >>"${downloads}"
    mkdir -p "${stage}/home/.install-action/bin"
    cp "${work}/src/${tool#*@}/fake-tool" "${stage}/home/.install-action/bin/"
  elif [[ -z ${url} && ${mode} == hosted ]]; then
    # install-action into CARGO_HOME/bin, on PATH.
    echo install >>"${downloads}"
    mkdir -p "${jd}/cargo/bin"
    cp "${work}/src/${tool#*@}/fake-tool" "${jd}/cargo/bin/"
    env=("${env[@]}" PATH="${jd}/cargo/bin:${PATH}")
  elif [[ -n ${url} && ${mode} != kept ]]; then
    env "${env[@]}" TOOL_STEP=download TOOL_MODE="${mode}" TOOL_STAGE="${stage}" bash "${script}" || return
  fi
  env "${env[@]}" TOOL_STEP=finish TOOL_MODE="${mode}" TOOL_STAGE="${stage}" bash "${script}"
}

target="${work}/target"
leftovers() { find "${target}/tools" -mindepth 1 -maxdepth 1 -name '.*' | wc -l; }

# A first run installs and keeps the tool; a second downloads nothing.
o="$(run_tool first "${target}" fake-tool@1.0.0 "${sha1}" 2>&1)" || fail "first run: ${o}"
[[ $(out_of "${work}/jobs/first/output" mode) == install ]] || fail "first run's mode isn't install"
[[ -x ${target}/tools/fake-tool@1.0.0/fake-tool ]] || fail "first run kept nothing"
[[ $("${work}/jobs/first/temp/rust-ci-tools/fake-tool@1.0.0/fake-tool") == "fake-tool 1.0.0" ]] ||
  fail "first run's job copy doesn't run"
[[ $(cat "${work}/jobs/first/path") == "${work}/jobs/first/temp/rust-ci-tools/fake-tool@1.0.0" ]] ||
  fail "first run didn't put the job's folder on PATH"
[[ $(out_of "${work}/jobs/first/output" path) == "${work}/jobs/first/temp/rust-ci-tools/fake-tool@1.0.0/fake-tool" ]] ||
  fail "first run's path output is wrong"
[[ $(leftovers) -eq 0 ]] || fail "first run left a stage folder"
ok "a first run installs and keeps the tool"

: >"${downloads}"
o="$(run_tool second "${target}" fake-tool@1.0.0 "${sha1}" 2>&1)" || fail "second run: ${o}"
[[ $(out_of "${work}/jobs/second/output" mode) == kept ]] || fail "second run's mode isn't kept"
[[ ! -s ${downloads} ]] || fail "second run downloaded: $(tr '\n' ' ' <"${downloads}")"
[[ $("${work}/jobs/second/temp/rust-ci-tools/fake-tool@1.0.0/fake-tool") == "fake-tool 1.0.0" ]] ||
  fail "second run's job copy doesn't run"
ok "a second run downloads no tool"

# A release archive (actionlint, gitleaks): the same, downloaded once.
: >"${downloads}"
for job in archive-1 archive-2; do
  o="$(run_tool "${job}" "${work}/target-archive" fake-tool@1.0.0 "${sha1}" 1.0.0 2>&1)" || fail "${job}: ${o}"
done
[[ $(grep -c download "${downloads}") -eq 1 ]] || fail "archive runs downloaded $(grep -c download "${downloads}") times"
[[ $(out_of "${work}/jobs/archive-2/output" mode) == kept ]] || fail "second archive run's mode isn't kept"
[[ -x ${work}/target-archive/tools/fake-tool@1.0.0/fake-tool ]] || fail "archive run kept nothing"
[[ ! -e ${work}/target-archive/tools/fake-tool@1.0.0/archive.tar.gz ]] || fail "archive run kept the archive"
ok "a release archive is downloaded once"

# Jobs started together that need the same tool, not yet kept, all pass.
race="${work}/target-race"
pids=()
for i in 1 2 3 4 5 6 7 8; do
  run_tool "race-${i}" "${race}" fake-tool@1.0.0 "${sha1}" >"${work}/race-${i}.log" 2>&1 &
  pids+=($!)
done
for i in "${!pids[@]}"; do
  wait "${pids[${i}]}" || fail "race job $((i + 1)) failed: $(cat "${work}/race-$((i + 1)).log")"
done
for i in 1 2 3 4 5 6 7 8; do
  [[ $("${work}/jobs/race-${i}/temp/rust-ci-tools/fake-tool@1.0.0/fake-tool") == "fake-tool 1.0.0" ]] ||
    fail "race job ${i}'s copy doesn't run"
done
[[ $(sha_of "${race}/tools/fake-tool@1.0.0/fake-tool") == "${sha1}" ]] || fail "the raced kept copy is wrong"
[[ $(find "${race}/tools" -mindepth 1 | wc -l) -eq 2 ]] ||
  fail "the race left more than the kept folder: $(find "${race}/tools" -mindepth 1)"
ok "eight jobs installing the same tool at once all pass"

# A kept copy another job changed is installed again, with a warning.
printf '#!/bin/sh\necho tampered\n' >"${target}/tools/fake-tool@1.0.0/fake-tool"
o="$(run_tool tampered "${target}" fake-tool@1.0.0 "${sha1}" 2>&1)" || fail "tampered run: ${o}"
[[ ${o} == *"doesn't match its pinned sha256; installing it again"* ]] || fail "tampered run didn't warn: ${o}"
[[ $(out_of "${work}/jobs/tampered/output" mode) == install ]] || fail "tampered run's mode isn't install"
[[ $("${work}/jobs/tampered/temp/rust-ci-tools/fake-tool@1.0.0/fake-tool") == "fake-tool 1.0.0" ]] ||
  fail "tampered run's job copy is wrong"
[[ $(sha_of "${target}/tools/fake-tool@1.0.0/fake-tool") == "${sha1}" ]] || fail "tampered copy wasn't replaced"
[[ $(leftovers) -eq 0 ]] || fail "tampered run left a folder: $(find "${target}/tools" -mindepth 1 -maxdepth 1 -name '.*')"
ok "a changed kept copy is installed again"

# A version bump installs the new version once and leaves the old folder.
before="$(sha_of "${target}/tools/fake-tool@1.0.0/fake-tool")"
o="$(run_tool bump "${target}" fake-tool@2.0.0 "${sha2}" 2>&1)" || fail "bump run: ${o}"
[[ $(out_of "${work}/jobs/bump/output" mode) == install ]] || fail "bump run's mode isn't install"
[[ $("${work}/jobs/bump/temp/rust-ci-tools/fake-tool@2.0.0/fake-tool") == "fake-tool 2.0.0" ]] ||
  fail "bump run's job copy is wrong"
[[ $(sha_of "${target}/tools/fake-tool@1.0.0/fake-tool") == "${before}" ]] || fail "bump changed the old folder"
[[ $(cat "${work}/jobs/bump/path") != *1.0.0* ]] || fail "bump put the old version on PATH"
: >"${downloads}"
o="$(run_tool bump-again "${target}" fake-tool@2.0.0 "${sha2}" 2>&1)" || fail "bump-again run: ${o}"
[[ ! -s ${downloads} ]] || fail "the bumped version was downloaded again"
ok "a version bump installs once and leaves the old folder"

# An install that doesn't match the pinned sha256 fails and keeps nothing.
o="$(run_tool wrong-sha "${work}/target-wrong" fake-tool@1.0.0 "${sha2}" 2>&1)"
code=$?
[[ ${code} -ne 0 && ${o} == *"just installed doesn't match its pinned sha256"* ]] ||
  fail "a wrong pinned sha256 didn't fail (exit ${code}): ${o}"
[[ $(find "${work}/target-wrong/tools" -mindepth 1 | wc -l) -eq 0 ]] || fail "a wrong sha256 kept something"
[[ ! -e ${work}/jobs/wrong-sha/temp/rust-ci-tools/fake-tool@1.0.0/fake-tool ]] ||
  fail "a wrong sha256 left a job copy"
ok "an install that doesn't match its pinned sha256 fails"

# Without target-dir: install-action's binary is checked where it is.
o="$(run_tool hosted "" fake-tool@1.0.0 "${sha1}" 2>&1)" || fail "hosted run: ${o}"
[[ $(out_of "${work}/jobs/hosted/output" mode) == hosted ]] || fail "hosted run's mode isn't hosted"
[[ $(out_of "${work}/jobs/hosted/output" path) == "${work}/jobs/hosted/cargo/bin/fake-tool" ]] ||
  fail "hosted run's path is $(out_of "${work}/jobs/hosted/output" path)"
[[ ! -s ${work}/jobs/hosted/path ]] || fail "hosted run changed PATH"
o="$(run_tool hosted-wrong "" fake-tool@1.0.0 "${sha2}" 2>&1)" && fail "hosted run with a wrong sha256 passed"
[[ ${o} == *"doesn't match its pinned sha256"* ]] || fail "hosted wrong-sha output: ${o}"
o="$(run_tool hosted-archive "" fake-tool@1.0.0 "${sha1}" 1.0.0 2>&1)" || fail "hosted archive run: ${o}"
[[ $(cat "${work}/jobs/hosted-archive/path") == "${work}/jobs/hosted-archive/temp/rust-ci-tools/fake-tool@1.0.0" ]] ||
  fail "hosted archive run didn't put its folder on PATH"
[[ ! -e ${work}/jobs/hosted-archive/temp/rust-ci-tools/fake-tool@1.0.0/archive.tar.gz ]] ||
  fail "hosted archive run left the archive"
ok "without target-dir, the installed binary is checked"

# Inputs that fail.
for bad in fake-tool fake-tool@latest "fake-tool@1.0" "Fake@1.0.0" "fake-tool@1.0.0@2"; do
  o="$(run_tool bad "${target}" "${bad}" "${sha1}" 2>&1)" && fail "tool '${bad}' passed"
  [[ ${o} == *"<name>@<exact version>"* ]] || fail "tool '${bad}': ${o}"
done
o="$(run_tool bad "${target}" fake-tool@1.0.0 "${sha1^^}" 2>&1)" && fail "an uppercase sha256 passed"
o="$(run_tool bad relative/dir fake-tool@1.0.0 "${sha1}" 2>&1)" && fail "a relative target-dir passed"
[[ ${o} == *"must be an absolute path"* ]] || fail "relative target-dir: ${o}"
ok "a tool without an exact version, a bad sha256 or a relative target-dir fails"

# The later steps only take a stage folder prepare made.
for bad_stage in "" /home "${target}/tools" "${target}/tools/.stage-fake-tool@1.0.0.x/../.."; do
  o="$(env GITHUB_OUTPUT=/dev/null GITHUB_PATH=/dev/null TOOL=fake-tool@1.0.0 TOOL_SHA256="${sha1}" \
    TARGET_ROOT="${target}" ARCHIVE_URL= JOB_DIR="${work}/jobs/stage/temp" ADD_TO_PATH=true \
    TOOL_STEP=finish TOOL_MODE=install TOOL_STAGE="${bad_stage}" bash "${script}" 2>&1)" &&
    fail "stage '${bad_stage}' passed"
  [[ ${o} == *"isn't one prepare made"* ]] || fail "stage '${bad_stage}': ${o}"
done
[[ -d /home && -d ${target}/tools/fake-tool@1.0.0 ]] || fail "a bad stage folder removed something"
ok "the later steps refuse a stage folder prepare didn't make"

# Stage folders from a job that stopped part-way are removed after a day.
mkdir -p "${target}/tools/.stage-fake-tool@1.0.0.old" "${target}/tools/.stage-fake-tool@1.0.0.new"
touch -d '2 days ago' "${target}/tools/.stage-fake-tool@1.0.0.old"
o="$(run_tool prune "${target}" fake-tool@1.0.0 "${sha1}" 2>&1)" || fail "prune run: ${o}"
[[ ! -e ${target}/tools/.stage-fake-tool@1.0.0.old ]] || fail "an old stage folder was kept"
[[ -e ${target}/tools/.stage-fake-tool@1.0.0.new ]] || fail "a recent stage folder was removed"
ok "stage folders older than a day are removed"

if [[ ${failures} -ne 0 ]]; then
  echo "${failures} install-tool case(s) failed"
  exit 1
fi
echo "all install-tool cases passed"
