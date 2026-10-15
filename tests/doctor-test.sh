#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_RUN="${ROOT}/bin/pi-run"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "doctor-test: $*" >&2
    exit 1
}

assert_contains() {
    local text="$1" expected="$2"
    [[ "${text}" == *"${expected}"* ]] || fail "expected output to contain: ${expected}"
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
case "$1" in
    info)
        [ "${DOCKER_INFO_FAIL:-0}" = 0 ]
        ;;
    image)
        [ "$2" = inspect ] || exit 2
        printf '%s\n' "$3" > "${DOCKER_IMAGE_CAPTURE:?}"
        [ "${DOCKER_IMAGE_FAIL:-0}" = 0 ]
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

# Version reporting has no Docker, jq, or initialized-home dependency.
mkdir -p "${TMP}/minimal-bin"
for command_name in bash dirname readlink realpath tr; do
    command_path="$(command -v "${command_name}")"
    ln -s "${command_path}" "${TMP}/minimal-bin/${command_name}"
done
version_output="$(PATH="${TMP}/minimal-bin" PI_RUN_HOME="${TMP}/never-created" "${PI_RUN}" version)"
assert_contains "${version_output}" "pi-run v0.6.0"
assert_contains "${version_output}" "runtime ghcr.io/aprilsoftware/pi-run:0.6.0"
[[ ! -e "${TMP}/never-created" ]] || fail "version created Pi-Run home"

if [[ -s /etc/machine-id ]]; then
    machine_source="$(< /etc/machine-id)"
else
    machine_source="$(hostname)"
fi
expected_machine_id="$(printf '%s:%s' "${machine_source}" "$(id -u)" | sha256sum | cut -c1-16)"
machine_output="$(PI_RUN_HOME="${TMP}/machine-id-home" "${PI_RUN}" machine-id)"
[[ "${machine_output}" == "${expected_machine_id}" &&
   "${machine_output}" =~ ^[0-9a-f]{16}$ ]] || fail "machine-id output is invalid or unstable"
[[ ! -e "${TMP}/machine-id-home" ]] || fail "machine-id created Pi-Run home"

# A healthy host with no initialized home passes with a warning and no mutation.
export DOCKER_IMAGE_CAPTURE="${TMP}/image"
output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${TMP}/uninitialized" "${PI_RUN}" doctor)"
assert_contains "${output}" "WARN  Pi-Run home is not initialized"
assert_contains "${output}" "Doctor: PASS"
[[ ! -e "${TMP}/uninitialized" ]] || fail "doctor initialized Pi-Run home"
[[ "$(cat "${TMP}/image")" == "ghcr.io/aprilsoftware/pi-run:0.6.0" ]] \
    || fail "doctor inspected the wrong default image"

# An initialized home and an image override pass validation.
PI_RUN_HOME="${TMP}/healthy home" "${PI_RUN}" init >/dev/null
output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${TMP}/healthy home" \
    PI_RUN_IMAGE="example.invalid/pi-run:test" "${PI_RUN}" doctor)"
assert_contains "${output}" "home configuration is valid"
assert_contains "${output}" "selected profile configuration is valid: default"
assert_contains "${output}" "Doctor: PASS"
[[ "$(cat "${TMP}/image")" == "example.invalid/pi-run:test" ]] \
    || fail "doctor ignored PI_RUN_IMAGE"

# Malformed state and unsafe permissions are failures, not repairs.
printf '%s\n' '{"schemaVersion":99}' > "${TMP}/healthy home/config.json"
chmod 0755 "${TMP}/healthy home"
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${TMP}/healthy home" "${PI_RUN}" doctor 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "doctor accepted malformed state"
assert_contains "${output}" "Pi-Run home permissions must be 700"
assert_contains "${output}" "home configuration is missing or invalid"

# Docker daemon and image failures produce a nonzero result.
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${TMP}/absent-a" \
    DOCKER_INFO_FAIL=1 "${PI_RUN}" doctor 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "doctor accepted an unavailable Docker daemon"
assert_contains "${output}" "Docker daemon is unavailable"

set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${TMP}/absent-b" \
    DOCKER_IMAGE_FAIL=1 "${PI_RUN}" doctor 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "doctor accepted a missing runtime image"
assert_contains "${output}" "runtime image unavailable locally"

# Remove Docker from PATH while retaining every other required diagnostic tool.
mkdir -p "${TMP}/no-docker-bin"
for command_name in bash dirname flock jq readlink realpath sha256sum stat sync timeout tr uname; do
    command_path="$(command -v "${command_name}")"
    ln -s "${command_path}" "${TMP}/no-docker-bin/${command_name}"
done
set +e
output="$(PATH="${TMP}/no-docker-bin" PI_RUN_HOME="${TMP}/absent-c" "${PI_RUN}" doctor 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "doctor accepted a missing Docker command"
assert_contains "${output}" "required command unavailable: docker"

# Lifecycle locking is a required host capability.
mkdir -p "${TMP}/no-flock-bin"
for command_name in bash dirname jq readlink realpath sha256sum stat sync timeout tr uname; do
    command_path="$(command -v "${command_name}")"
    ln -s "${command_path}" "${TMP}/no-flock-bin/${command_name}"
done
ln -s "${TMP}/fake-bin/docker" "${TMP}/no-flock-bin/docker"
set +e
output="$(PATH="${TMP}/no-flock-bin" PI_RUN_HOME="${TMP}/absent-d" "${PI_RUN}" doctor 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "doctor accepted a missing flock command"
assert_contains "${output}" "required command unavailable: flock"

# Bounded S3 configuration requires GNU timeout.
mkdir -p "${TMP}/no-timeout-bin"
for command_name in bash dirname flock jq readlink realpath sha256sum stat sync tr uname; do
    command_path="$(command -v "${command_name}")"
    ln -s "${command_path}" "${TMP}/no-timeout-bin/${command_name}"
done
ln -s "${TMP}/fake-bin/docker" "${TMP}/no-timeout-bin/docker"
set +e
output="$(PATH="${TMP}/no-timeout-bin" PI_RUN_HOME="${TMP}/absent-e" "${PI_RUN}" doctor 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "doctor accepted a missing timeout command"
assert_contains "${output}" "required command unavailable: timeout"

# Simulate WSL kernels and backing filesystems without Docker or Windows access.
REAL_UNAME="$(command -v uname)"
REAL_STAT="$(command -v stat)"
export REAL_UNAME REAL_STAT
cat > "${TMP}/fake-bin/uname" <<'EOF'
#!/bin/sh
case "$1" in
    -s) printf '%s\n' Linux ;;
    -m) printf '%s\n' "${TEST_ARCH:-x86_64}" ;;
    -r) printf '%s\n' "${TEST_KERNEL:-6.6.87.2-microsoft-standard-WSL2}" ;;
    *) exec "$REAL_UNAME" "$@" ;;
esac
EOF
cat > "${TMP}/fake-bin/stat" <<'EOF'
#!/bin/sh
if [ "$1" = -f ]; then
    printf '%s\n' "$5" > "${TEST_FS_CAPTURE:?}"
    [ "${TEST_FS_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "${TEST_FS:-ext2/ext3}"
else
    exec "$REAL_STAT" "$@"
fi
EOF
chmod 0755 "${TMP}/fake-bin/uname" "${TMP}/fake-bin/stat"
export TEST_FS_CAPTURE="${TMP}/filesystem-path"
wsl_home="${TMP}/wsl-home/nested/Pi-Run"
output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${wsl_home}" "${PI_RUN}" doctor)"
assert_contains "${output}" "platform: WSL2 Linux/amd64"
assert_contains "${output}" "without Docker Desktop"
assert_contains "${output}" "not automatically Windows"
assert_contains "${output}" "WSL data-home filesystem: ext2/ext3"
assert_contains "${output}" "Doctor: PASS"
[[ "$(cat "${TEST_FS_CAPTURE}")" == "${TMP}" && ! -e "${TMP}/wsl-home" ]] \
    || fail "WSL diagnostics did not check an existing ancestor without mutation"

for kernel in 4.19.104-microsoft-standard 4.4.0-19041-Microsoft custom-linux; do
    set +e
    output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${wsl_home}" \
        TEST_KERNEL="${kernel}" WSL_DISTRO_NAME=Debian "${PI_RUN}" doctor 2>&1)"
    status=$?
    set -e
    case "${kernel}" in
        4.19*) assert_contains "${output}" "platform: WSL2 Linux/amd64" ;;
        4.4*)
            [[ ${status} -ne 0 ]] || fail "doctor accepted WSL1"
            assert_contains "${output}" "WSL1 is unsupported"
            ;;
        *) assert_contains "${output}" "unrecognized WSL kernel" ;;
    esac
    [[ "${kernel}" == 4.4* || ${status} -eq 0 ]] || fail "doctor rejected a non-WSL1 kernel"
done

for filesystem in 9p drvfs ntfs ntfs3; do
    set +e
    output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${wsl_home}" \
        TEST_FS="${filesystem}" "${PI_RUN}" doctor 2>&1)"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "doctor accepted Windows-backed storage: ${filesystem}"
    assert_contains "${output}" "WSL data home is Windows-backed (${filesystem})"
    assert_contains "${output}" "accessible through Windows Explorer"
    [[ ! -e "${TMP}/wsl-home" ]] || fail "filesystem diagnostic created data"
done

output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${wsl_home}" \
    TEST_FS_FAIL=1 "${PI_RUN}" doctor)"
assert_contains "${output}" "could not determine WSL data-home filesystem"
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${wsl_home}" \
    DOCKER_INFO_FAIL=1 "${PI_RUN}" doctor 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "WSL diagnostics accepted an unavailable daemon"
assert_contains "${output}" "systemctl status docker and docker info"

output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${wsl_home}" \
    TEST_KERNEL=6.8.0-generic WSL_INTEROP='' WSL_DISTRO_NAME='' "${PI_RUN}" doctor)"
assert_contains "${output}" "platform: Linux/amd64"
[[ "${output}" != *"WSL"* ]] || fail "native Linux received WSL diagnostics"
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${wsl_home}" \
    TEST_ARCH=aarch64 "${PI_RUN}" doctor 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "WSL diagnostics accepted ARM64"
assert_contains "${output}" "unsupported platform: Linux/aarch64"

echo "version and doctor tests passed"
