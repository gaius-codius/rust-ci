#!/usr/bin/env bash
# Run by action.yml, once per step: TOOL_STEP is prepare, download or
# finish. See action.yml for what the action does; the variables are its inputs
# (TOOL, TOOL_SHA256, TARGET_ROOT, ARCHIVE_URL, ARCHIVE_SHA256, JOB_DIR,
# INSTALL_HOME, ADD_TO_PATH) and prepare's outputs (TOOL_MODE, TOOL_STAGE).
set -euo pipefail

tool_fail() {
  printf '::error title=rust-ci install-tool::%s\n' "$1"
  exit 1
}

# tool_digest_ok <file>: the file's sha256 is the pinned one.
tool_digest_ok() {
  [[ -f $1 ]] || return 1
  local digest
  # From stdin, so the output has no file name (escaped if it has a backslash).
  digest="$(sha256sum <"$1")" || return 1
  [[ ${digest%% *} == "${TOOL_SHA256}" ]]
}

# tool_copy_in <file>: copies the file into the job's own folder, checks the
# copy (not the source, which another job can change), and moves it into
# place. Fails, leaving nothing, if the copy doesn't match.
tool_copy_in() {
  local part="${JOB_DIR}/${name}.part"
  mkdir -p -- "${JOB_DIR}"
  rm -f -- "${part}"
  if cp -- "$1" "${part}" 2>/dev/null && tool_digest_ok "${part}"; then
    chmod 0755 -- "${part}"
    # Whatever a project script left at the copy's place (a folder would take
    # the copy inside it) goes first.
    rm -rf -- "${JOB_DIR:?}/${name}"
    mv -fT -- "${part}" "${JOB_DIR}/${name}"
    return 0
  fi
  rm -f -- "${part}"
  return 1
}

name="${TOOL%%@*}"
version="${TOOL#*@}"
if [[ ! ${name} =~ ^[a-z0-9][a-z0-9-]*$ || ! ${version} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ${TOOL} != "${name}@${version}" ]]; then
  tool_fail "tool must be <name>@<exact version>, for example cargo-nextest@0.9.146, got: ${TOOL}"
fi
# The pinned sha256 values are of the Linux x64 builds.
if [[ ${TOOL_RUNNER:-} != Linux/X64 ]]; then
  tool_fail "rust-ci's tools are pinned for Linux x64 runners; this runner is ${TOOL_RUNNER:-unknown}."
fi
if [[ ! ${TOOL_SHA256} =~ ^[0-9a-f]{64}$ ]]; then
  tool_fail "sha256 must be the binary's sha256 in lowercase hex, got: ${TOOL_SHA256}"
fi
if [[ -n ${TARGET_ROOT} && ( ${TARGET_ROOT} != /* || /${TARGET_ROOT}/ == */../* || /${TARGET_ROOT}/ == */./* ) ]]; then
  tool_fail "target-dir must be an absolute path without . or .. parts, got: ${TARGET_ROOT}"
fi
tools="${TARGET_ROOT}/tools"
kept="${tools}/${TOOL}"
# prepare's stage folder, for the later steps: never anything else, since
# they delete it.
if [[ ${TOOL_STEP} != prepare && ${TOOL_MODE:-} == install &&
  ( -z ${TARGET_ROOT} || ${TOOL_STAGE:-} != "${tools}/.stage-${TOOL}."* || ${TOOL_STAGE} == */../* ) ]]; then
  tool_fail "the stage folder '${TOOL_STAGE:-}' isn't one prepare made in ${tools}."
fi

case "${TOOL_STEP}" in
  prepare)
    if [[ -z ${TARGET_ROOT} ]]; then
      printf 'mode=hosted\n' >>"${GITHUB_OUTPUT}"
      exit 0
    fi
    mkdir -p -- "${tools}"
    # Folders left by jobs that stopped part-way. A day is far longer than any
    # job keeps one.
    find "${tools}" -mindepth 1 -maxdepth 1 \( -name '.stage-*' -o -name '.old-*' \) \
      -mmin +1440 -exec rm -rf -- {} + 2>/dev/null || true
    if [[ -e ${kept}/${name} ]]; then
      if tool_copy_in "${kept}/${name}"; then
        printf 'Using %s kept on the runner (%s).\n' "${TOOL}" "${kept}"
        printf 'mode=kept\n' >>"${GITHUB_OUTPUT}"
        exit 0
      fi
      printf "::warning title=rust-ci install-tool::%s on the runner (%s) doesn't match its pinned sha256; installing it again.\n" "${TOOL}" "${kept}"
    fi
    rm -rf -- "${INSTALL_HOME:?}"
    # In the tools folder, so the rename into place stays on one filesystem.
    stage="$(mktemp -d "${tools}/.stage-${TOOL}.XXXXXXXX")"
    printf 'Installing %s into %s.\n' "${TOOL}" "${stage}"
    {
      printf 'mode=install\n'
      printf 'stage=%s\n' "${stage}"
    } >>"${GITHUB_OUTPUT}"
    ;;

  download)
    # A release archive with the binary at its top level, for tools
    # install-action doesn't carry.
    if [[ ${TOOL_MODE} == install ]]; then
      dest="${TOOL_STAGE}"
    else
      dest="${JOB_DIR}"
    fi
    mkdir -p -- "${dest}"
    archive="${dest}/archive.tar.gz"
    curl --fail --silent --show-error --location --retry 3 --output "${archive}" "${ARCHIVE_URL}"
    printf '%s  %s\n' "${ARCHIVE_SHA256}" "${archive}" | sha256sum --check -
    tar -xzf "${archive}" -C "${dest}" "${name}"
    rm -f -- "${archive}"
    ;;

  finish)
    case "${TOOL_MODE}" in
      hosted)
        if [[ -n ${ARCHIVE_URL} ]]; then
          bin="${JOB_DIR}/${name}"
        else
          bin="$(command -v "${name}" || true)"
        fi
        tool_digest_ok "${bin}" ||
          tool_fail "${TOOL} at '${bin:-not found}' doesn't match its pinned sha256 ${TOOL_SHA256}."
        chmod 0755 -- "${bin}"
        if [[ -n ${ARCHIVE_URL} && ${ADD_TO_PATH} == true ]]; then
          printf '%s\n' "${JOB_DIR}" >>"${GITHUB_PATH}"
        fi
        printf 'path=%s\n' "${bin}" >>"${GITHUB_OUTPUT}"
        printf '%s is %s.\n' "${TOOL}" "${bin}"
        exit 0
        ;;
      install)
        stage="${TOOL_STAGE}"
        if [[ -z ${ARCHIVE_URL} ]]; then
          # install-action ran with HOME in the job's own INSTALL_HOME.
          mv -fT -- "${INSTALL_HOME:?}/.install-action/bin/${name}" "${stage}/${name}" 2>/dev/null || true
          rm -rf -- "${INSTALL_HOME:?}"
        fi
        if ! tool_digest_ok "${stage}/${name}"; then
          rm -rf -- "${stage}"
          tool_fail "the ${TOOL} just installed doesn't match its pinned sha256 ${TOOL_SHA256}."
        fi
        tool_copy_in "${stage}/${name}" || tool_fail "copying ${TOOL} into ${JOB_DIR} failed."
        # Keep it for later jobs: replace a folder that doesn't match, then
        # rename the stage into place. A rename onto a folder another job has
        # put there since fails, and that job's copy is as good as this one.
        if [[ -e ${kept} || -L ${kept} ]] && ! tool_digest_ok "${kept}/${name}"; then
          old="$(mktemp -u "${tools}/.old-${TOOL}.XXXXXXXX")"
          if mv -T -- "${kept}" "${old}" 2>/dev/null; then
            rm -rf -- "${old}"
          fi
        fi
        if mv -T -- "${stage}" "${kept}" 2>/dev/null; then
          printf 'Kept %s on the runner (%s).\n' "${TOOL}" "${kept}"
        else
          rm -rf -- "${stage}"
          printf 'Another job kept %s on the runner first.\n' "${TOOL}"
        fi
        ;;
      kept) ;;
      *) tool_fail "unknown mode: ${TOOL_MODE}" ;;
    esac
    if [[ ${ADD_TO_PATH} == true ]]; then
      printf '%s\n' "${JOB_DIR}" >>"${GITHUB_PATH}"
    fi
    printf 'path=%s\n' "${JOB_DIR}/${name}" >>"${GITHUB_OUTPUT}"
    ;;

  *) tool_fail "unknown step: ${TOOL_STEP}" ;;
esac
