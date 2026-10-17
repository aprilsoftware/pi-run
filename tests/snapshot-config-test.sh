#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-config-test: $*" >&2
    exit 1
}

expect_failure() {
    local status
    set +e
    "$@" >/dev/null 2>&1
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "command unexpectedly succeeded: $*"
}

assert_pair() {
    local first="$1" second="$2"
    awk -v first="${first}" -v second="${second}" '
        previous == first && $0 == second { found = 1 }
        { previous = $0 }
        END { exit(found ? 0 : 1) }
    ' "${DOCKER_LOG}" || fail "missing Docker argument pair: ${first} ${second}"
}

HOME_DIR="${TMP}/Pi Run"
mkdir -p "${TMP}/fake-bin"

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
: > "${DOCKER_LOG:?}"
repository=
operation=
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG}"
    case "${argument}" in
        RESTIC_REPOSITORY=/snapshots/*) repository=${argument#RESTIC_REPOSITORY=} ;;
        init) operation=init ;;
        snapshots) operation=snapshots ;;
    esac
done
[ "${FAIL_DOCKER:-0}" = 0 ] || exit 1
case "${operation}" in
    init)
        destination="${SNAPSHOT_TEST_ROOT:?}/${repository#/snapshots/}"
        mkdir "${destination}"
        printf 'restic repository\n' > "${destination}/config"
        ;;
    snapshots)
        [ -f "${SNAPSHOT_TEST_ROOT:?}/${repository#/snapshots/}/config" ]
        printf '[]\n'
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"
export SNAPSHOT_TEST_ROOT="${HOME_DIR}/snapshots"

run_local_configure() {
    local home="$1"
    printf '1\nyes\n' | env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
        SNAPSHOT_TEST_ROOT="${home}/snapshots" FAIL_DOCKER="${FAIL_DOCKER:-0}" \
        "${ROOT}/bin/pi-run" snapshot configure
}

CANCEL_HOME="${TMP}/cancelled"
cancel_output="$(printf 'q\n' | env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${CANCEL_HOME}" \
    SNAPSHOT_TEST_ROOT="${CANCEL_HOME}/snapshots" "${ROOT}/bin/pi-run" snapshot configure 2>&1)"
[[ "${cancel_output}" == *'Snapshot configuration cancelled.'* ]] \
    || fail "explicit cancellation was not reported"
[[ ! -e "${CANCEL_HOME}/snapshots/config.json" ]] || fail "cancellation published configuration"

EOF_HOME="${TMP}/end-of-input"
eof_output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${EOF_HOME}" \
    SNAPSHOT_TEST_ROOT="${EOF_HOME}/snapshots" "${ROOT}/bin/pi-run" snapshot configure </dev/null 2>&1)"
[[ "${eof_output}" == *'Snapshot configuration cancelled.'* ]] || fail "EOF was not handled as cancellation"
[[ ! -e "${EOF_HOME}/snapshots/config.json" ]] || fail "EOF published configuration"

INVALID_HOME="${TMP}/invalid-selection"
invalid_output="$(printf 'wrong\n1\nno\n' | env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${INVALID_HOME}" \
    SNAPSHOT_TEST_ROOT="${INVALID_HOME}/snapshots" "${ROOT}/bin/pi-run" snapshot configure 2>&1)"
[[ "${invalid_output}" == *'Enter 1 for local storage'* && "${invalid_output}" == *'cancelled'* ]] \
    || fail "invalid selection was not explained and re-prompted"
[[ ! -e "${INVALID_HOME}/snapshots/config.json" ]] || fail "declined local configuration was published"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${TMP}/removed-command" \
    SNAPSHOT_TEST_ROOT="${TMP}/removed-command/snapshots" "${ROOT}/bin/pi-run" \
    snapshot configure-s3 https://s3.example.test bucket-name valid/prefix us-east-1

status_output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot status)"
[[ "${status_output}" == "Snapshot status: unconfigured" ]] \
    || fail "unexpected unconfigured status"
[[ ! -e "${DOCKER_LOG}" ]] || fail "unconfigured status invoked Docker"

configure_output="$(run_local_configure "${HOME_DIR}" 2>&1)"
[[ "${configure_output}" == *'Choose snapshot storage:'* &&
   "${configure_output}" == *'does not protect against loss of the local disk'* ]] \
    || fail "local configuration guidance is incomplete"
SNAPSHOT_ROOT="${HOME_DIR}/snapshots"
CONFIG="${SNAPSHOT_ROOT}/config.json"
SECRETS="${SNAPSHOT_ROOT}/secrets"
REPOSITORY="${SNAPSHOT_ROOT}/repository"

[[ -f "${CONFIG}" && -f "${SECRETS}" && -f "${REPOSITORY}/config" ]] \
    || fail "configuration did not publish complete state"
[[ "$(stat -c %a "${CONFIG}")" == 600 && "$(stat -c %a "${SECRETS}")" == 600 ]] \
    || fail "configuration files are not mode 600"
[[ -s "${SECRETS}" ]] || fail "generated snapshot secret is empty"
jq -e '.schemaVersion == 1 and .backend == "local" and .repository == "repository"' \
    "${CONFIG}" >/dev/null || fail "snapshot configuration is invalid"
secret_value="$(< "${SECRETS}")"
[[ "${configure_output}" != *"${secret_value}"* ]] || fail "snapshot secret was printed"
[[ -z "$(find "${SNAPSHOT_ROOT}" -maxdepth 1 -name '.*.tmp.*' -print -quit)" ]] \
    || fail "successful configuration left staging files"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_ROOT}" "${ROOT}/bin/pi-run" snapshot configure

status_output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot status)"
[[ "${status_output}" == *"Snapshot backend: local"* &&
   "${status_output}" == *"Snapshot status: ready"* ]] \
    || fail "configured status is incomplete"
[[ "${status_output}" != *"${secret_value}"* ]] || fail "status printed the snapshot secret"
assert_pair --network none
assert_pair --cap-drop=ALL --security-opt=no-new-privileges
assert_pair --entrypoint restic
assert_pair --env RESTIC_REPOSITORY=/snapshots/repository
assert_pair --env RESTIC_PASSWORD_FILE=/snapshots/secrets
grep -F "type=bind,src=${SNAPSHOT_ROOT},dst=/snapshots,readonly" "${DOCKER_LOG}" >/dev/null \
    || fail "status did not use a read-only snapshots mount"
grep -Fx 'ghcr.io/aprilsoftware/pi-run:0.6.3' "${DOCKER_LOG}" >/dev/null \
    || fail "status used the wrong runtime image"

UNSAFE_HOME="${TMP}/unsafe home"
OUTSIDE="${TMP}/outside"
mkdir -p "${UNSAFE_HOME}" "${OUTSIDE}"
ln -s "${OUTSIDE}" "${UNSAFE_HOME}/snapshots"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${UNSAFE_HOME}" \
    SNAPSHOT_TEST_ROOT="${OUTSIDE}" "${ROOT}/bin/pi-run" snapshot status
[[ ! -e "${OUTSIDE}/metadata" && ! -e "${OUTSIDE}/restore-staging" ]] \
    || fail "unsafe snapshot symlink was followed during initialization"

FAILED_HOME="${TMP}/failed home"
FAIL_DOCKER=1 expect_failure run_local_configure "${FAILED_HOME}"
for path in config.json secrets repository; do
    [[ ! -e "${FAILED_HOME}/snapshots/${path}" ]] \
        || fail "failed configuration published ${path}"
done
[[ -z "$(find "${FAILED_HOME}/snapshots" -maxdepth 1 -name '.*.tmp.*' -print -quit)" ]] \
    || fail "failed configuration left staging files"

mv "${CONFIG}" "${CONFIG}.valid"
printf '%s\n' '{"schemaVersion":99}' > "${CONFIG}"
chmod 0600 "${CONFIG}"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_ROOT}" "${ROOT}/bin/pi-run" snapshot status
rm "${CONFIG}"
mv "${CONFIG}.valid" "${CONFIG}"

mv "${SECRETS}" "${SECRETS}.linked"
ln "${SECRETS}.linked" "${SECRETS}"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_ROOT}" "${ROOT}/bin/pi-run" snapshot status
rm "${SECRETS}"
mv "${SECRETS}.linked" "${SECRETS}"

echo "snapshot configuration tests passed"
