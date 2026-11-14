#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "runtime-init-test: $*" >&2
    exit 1
}

expect_failure() {
    local status
    set +e
    "$@" >"${TMP}/failure.out" 2>&1
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "command unexpectedly succeeded: $*"
}

assert_profile_absent() {
    local name="$1"
    [[ ! -e "${HOME_DIR}/profiles/${name}" && ! -L "${HOME_DIR}/profiles/${name}" ]] \
        || fail "failed profile creation left a target: ${name}"
    ! find "${HOME_DIR}/profiles" -maxdepth 1 -name ".${name}.tmp.*" -print -quit | grep -q . \
        || fail "failed profile creation left staging data: ${name}"
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
: > "${DOCKER_CALLED:?}"
exit 99
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export PATH="${TMP}/fake-bin:${PATH}"
export DOCKER_CALLED="${TMP}/docker-called"

HOME_DIR="${TMP}/Pi Run"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
default_runtime="${HOME_DIR}/profiles/default/runtime"
[[ -d "${default_runtime}" && ! -L "${default_runtime}" ]] \
    || fail "fresh default profile has no safe runtime directory"
cmp "${ROOT}/templates/runtime/Dockerfile" "${default_runtime}/Dockerfile" \
    || fail "fresh default runtime differs from its Dockerfile template"
cmp "${ROOT}/templates/runtime/.dockerignore" "${default_runtime}/.dockerignore" \
    || fail "fresh default runtime differs from its ignore template"
[[ "$(stat -c %a "${default_runtime}")" == 700 &&
   "$(stat -c %a "${default_runtime}/Dockerfile")" == 600 &&
   "$(stat -c %a "${default_runtime}/.dockerignore")" == 600 ]] \
    || fail "fresh default runtime permissions are not private"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create legacy-init >/dev/null
legacy_profile="${HOME_DIR}/profiles/legacy-init"
rm -rf "${legacy_profile}/runtime"
output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    --profile legacy-init runtime init)"
runtime_dir="${legacy_profile}/runtime"
[[ "${output}" == "$(printf 'Initialized runtime for legacy-init: %s\nNo runtime image was built.' \
    "${runtime_dir}/Dockerfile")" ]] || fail "runtime init returned unexpected output"
cmp "${ROOT}/templates/runtime/Dockerfile" "${runtime_dir}/Dockerfile" \
    || fail "generated Dockerfile differs from its installed template"
cmp "${ROOT}/templates/runtime/.dockerignore" "${runtime_dir}/.dockerignore" \
    || fail "generated .dockerignore differs from its installed template"
[[ ! -e "${DOCKER_CALLED}" ]] || fail "profile runtime creation invoked Docker"

printf 'user-owned\n' >> "${runtime_dir}/Dockerfile"
cp "${runtime_dir}/Dockerfile" "${TMP}/Dockerfile.before"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    --profile legacy-init runtime init
cmp "${TMP}/Dockerfile.before" "${runtime_dir}/Dockerfile" \
    || fail "repeated runtime init changed existing content"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create operations >/dev/null
rm -rf "${HOME_DIR}/profiles/operations/runtime"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default operations >/dev/null
operations_dir="${HOME_DIR}/profiles/operations/runtime"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" runtime init >/dev/null
[[ -f "${operations_dir}/Dockerfile" ]] \
    || fail "runtime init did not use the configured default profile"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create explicit >/dev/null
explicit_profile="${HOME_DIR}/profiles/explicit"
rm -rf "${explicit_profile}/runtime"
exec {profile_lock_fd}<"${explicit_profile}"
flock -x "${profile_lock_fd}"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" --profile explicit runtime init \
    >"${TMP}/locked-init.out" &
init_pid=$!
sleep 0.1
kill -0 "${init_pid}" 2>/dev/null \
    || fail "runtime init did not wait for the profile lock"
flock -u "${profile_lock_fd}"
wait "${init_pid}"
exec {profile_lock_fd}>&-
[[ -f "${explicit_profile}/runtime/Dockerfile" ]] \
    || fail "explicit-profile runtime init did not complete after locking"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create linked >/dev/null
linked_profile="${HOME_DIR}/profiles/linked"
rm -rf "${linked_profile}/runtime"
mkdir "${TMP}/outside-runtime"
printf 'outside\n' > "${TMP}/outside-runtime/sentinel"
ln -s "${TMP}/outside-runtime" "${linked_profile}/runtime"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    --profile linked runtime init
[[ "$(< "${TMP}/outside-runtime/sentinel")" == outside ]] \
    || fail "runtime symlink refusal changed the external target"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create occupied >/dev/null
occupied_runtime="${HOME_DIR}/profiles/occupied/runtime"
rm -rf "${occupied_runtime}"
printf 'occupied\n' > "${occupied_runtime}"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    --profile occupied runtime init
[[ "$(< "${occupied_runtime}")" == occupied ]] \
    || fail "runtime file refusal changed existing content"
[[ ! -e "${DOCKER_CALLED}" ]] || fail "a refused runtime init invoked Docker"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create failed-stage >/dev/null
mkdir "${TMP}/failing-bin"
cat > "${TMP}/failing-bin/install" <<'EOF'
#!/bin/sh
exit 12
EOF
chmod 0755 "${TMP}/failing-bin/install"
failed_profile="${HOME_DIR}/profiles/failed-stage"
rm -rf "${failed_profile}/runtime"
expect_failure env PATH="${TMP}/failing-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" --profile failed-stage runtime init
[[ ! -e "${failed_profile}/runtime" ]] \
    || fail "failed file installation left a partial runtime"
! find "${failed_profile}" -maxdepth 1 -name '.runtime.tmp.*' -print -quit | grep -q . \
    || fail "failed file installation left runtime staging data"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create custom-source >/dev/null
custom_source="${HOME_DIR}/profiles/custom-source"
mkdir -p "${custom_source}/runtime/assets/nested" "${custom_source}/logs"
printf '#!/bin/sh\nexit 0\n' > "${custom_source}/runtime/assets/nested/tool"
chmod 0755 "${custom_source}/runtime/assets/nested/tool"
printf 'external\n' > "${TMP}/external-runtime-asset"
ln -s "${TMP}/external-runtime-asset" "${custom_source}/runtime/assets/external-link"
printf 'credential\n' > "${custom_source}/credentials/private"
printf 'session\n' > "${custom_source}/sessions/state"
printf 'log\n' > "${custom_source}/logs/private"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    profile create custom-copy --from custom-source >/dev/null
custom_copy="${HOME_DIR}/profiles/custom-copy"
cmp "${custom_source}/runtime/Dockerfile" "${custom_copy}/runtime/Dockerfile" \
    || fail "profile creation did not copy the source Dockerfile"
cmp "${custom_source}/runtime/assets/nested/tool" \
    "${custom_copy}/runtime/assets/nested/tool" \
    || fail "profile creation did not copy nested runtime assets"
[[ "$(stat -c %a "${custom_copy}/runtime")" == 700 &&
   "$(stat -c %a "${custom_copy}/runtime/assets/nested/tool")" == 755 ]] \
    || fail "profile runtime copy did not preserve expected modes"
[[ -L "${custom_copy}/runtime/assets/external-link" &&
   "$(readlink "${custom_copy}/runtime/assets/external-link")" == "${TMP}/external-runtime-asset" ]] \
    || fail "profile runtime copy followed or changed a symlink"
[[ ! -e "${custom_copy}/credentials/private" &&
   ! -e "${custom_copy}/sessions/state" &&
   ! -e "${custom_copy}/logs" ]] \
    || fail "profile creation copied private runtime state"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create legacy-source >/dev/null
rm -rf "${HOME_DIR}/profiles/legacy-source/runtime"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    profile create legacy-copy --from legacy-source >/dev/null
cmp "${ROOT}/templates/runtime/Dockerfile" \
    "${HOME_DIR}/profiles/legacy-copy/runtime/Dockerfile" \
    || fail "legacy source did not receive a base runtime"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create hardlink-source >/dev/null
hardlink_source="${HOME_DIR}/profiles/hardlink-source/runtime"
printf 'linked\n' > "${hardlink_source}/asset"
ln "${hardlink_source}/asset" "${hardlink_source}/asset-link"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    profile create hardlink-copy --from hardlink-source
assert_profile_absent hardlink-copy

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create special-source >/dev/null
mkfifo "${HOME_DIR}/profiles/special-source/runtime/channel"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    profile create special-copy --from special-source
assert_profile_absent special-copy

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create large-source >/dev/null
truncate -s 536870913 "${HOME_DIR}/profiles/large-source/runtime/large-asset"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    profile create large-copy --from large-source
assert_profile_absent large-copy

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create crowded-source >/dev/null
crowded_runtime="${HOME_DIR}/profiles/crowded-source/runtime"
for ((entry = 0; entry < 4095; entry += 1)); do
    : > "${crowded_runtime}/entry-${entry}"
done
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    profile create crowded-copy --from crowded-source
assert_profile_absent crowded-copy
[[ ! -e "${DOCKER_CALLED}" ]] || fail "profile runtime lifecycle invoked Docker"

"${ROOT}/scripts/build-release" "${TMP}/release" >/dev/null
version="$(tr -d '\r\n' < "${ROOT}/VERSION")"
tar -xzf "${TMP}/release/pi-run-${version}.tar.gz" -C "${TMP}"
package="${TMP}/pi-run-${version}"
packaged_home="${TMP}/packaged-home"
PI_RUN_HOME="${packaged_home}" "${package}/bin/pi-run" init >/dev/null
cmp "${package}/templates/runtime/Dockerfile" \
    "${packaged_home}/profiles/default/runtime/Dockerfile" \
    || fail "packaged runtime init did not use the packaged Dockerfile template"
cmp "${package}/templates/runtime/.dockerignore" \
    "${packaged_home}/profiles/default/runtime/.dockerignore" \
    || fail "packaged runtime init did not use the packaged ignore template"

rm "${package}/templates/runtime/.dockerignore"
missing_home="${TMP}/missing-template-home"
expect_failure env PI_RUN_HOME="${missing_home}" "${package}/bin/pi-run" init
[[ ! -e "${missing_home}/profiles/default" ]] \
    || fail "missing template left a partial default profile"
! find "${missing_home}/profiles" -maxdepth 1 -name '.default.*' -print -quit | grep -q . \
    || fail "missing template left default-profile staging data"

install -m 0644 "${ROOT}/templates/runtime/.dockerignore" \
    "${package}/templates/runtime/.dockerignore"
rm "${package}/templates/runtime/Dockerfile"
ln -s /dev/null "${package}/templates/runtime/Dockerfile"
unsafe_home="${TMP}/unsafe-template-home"
expect_failure env PI_RUN_HOME="${unsafe_home}" "${package}/bin/pi-run" init
[[ ! -e "${unsafe_home}/profiles/default" ]] \
    || fail "unsafe template left a partial default profile"
[[ ! -e "${DOCKER_CALLED}" ]] || fail "runtime template failures invoked Docker"

echo "runtime init tests passed"
