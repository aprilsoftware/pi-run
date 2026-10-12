#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-check-test: $*" >&2
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
        init|snapshots|check) operation=${argument} ;;
    esac
done
case "${operation}" in
    init)
        destination="${SNAPSHOT_TEST_ROOT:?}/${repository#/snapshots/}"
        mkdir "${destination}"
        printf 'restic repository\n' > "${destination}/config"
        ;;
    snapshots)
        printf '[]\n'
        ;;
    check)
        [ "${FAIL_CHECK:-0}" = 0 ] || exit 1
        if [ -n "${CHECK_RESPONSE:-}" ]; then
            printf '%s\n' "${CHECK_RESPONSE}"
        else
            printf '%s\n' '{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}'
        fi
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"
export SNAPSHOT_TEST_ROOT="${HOME_DIR}/snapshots"

printf '1\nyes\n' | env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null
state_before="$(sha256sum "${HOME_DIR}/snapshots/config.json" \
    "${HOME_DIR}/snapshots/secrets" "${HOME_DIR}/snapshots/repository/config")"

check_output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot check)"
[[ "${check_output}" == *"Snapshot check: OK"* &&
   "${check_output}" == *"Data verification: complete"* ]] \
    || fail "healthy repository did not report success"
[[ "${state_before}" == "$(sha256sum "${HOME_DIR}/snapshots/config.json" \
    "${HOME_DIR}/snapshots/secrets" "${HOME_DIR}/snapshots/repository/config")" ]] \
    || fail "integrity check modified repository configuration"
for argument in --no-lock check --read-data --json; do
    grep -Fx -- "${argument}" "${DOCKER_LOG}" >/dev/null \
        || fail "missing Restic check argument: ${argument}"
done
grep -F "type=bind,src=${HOME_DIR}/snapshots,dst=/snapshots,readonly" "${DOCKER_LOG}" >/dev/null \
    || fail "integrity check did not use a read-only mount"
grep -Fx -- 'none' "${DOCKER_LOG}" >/dev/null || fail "integrity check did not disable networking"

PRUNE_ADVISORY='{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":true}'
advisory_output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" CHECK_RESPONSE="${PRUNE_ADVISORY}" \
    "${ROOT}/bin/pi-run" snapshot check)"
[[ "${advisory_output}" == *'Snapshot check: OK'* &&
   "${advisory_output}" == *'Restic found unused repository data'* &&
   "${advisory_output}" == *'Snapshot check does not delete or prune repository data.'* ]] \
    || fail "prune recommendation was not reported as a non-fatal advisory"

ERROR_SUMMARY='{"message_type":"summary","num_errors":1,"broken_packs":["pack"],"suggest_repair_index":true,"suggest_prune":false}'
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" CHECK_RESPONSE="${ERROR_SUMMARY}" \
    "${ROOT}/bin/pi-run" snapshot check
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" CHECK_RESPONSE='not-json' \
    "${ROOT}/bin/pi-run" snapshot check
CONTRADICTORY='{"message_type":"error"}
{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}'
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" CHECK_RESPONSE="${CONTRADICTORY}" \
    "${ROOT}/bin/pi-run" snapshot check
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" FAIL_CHECK=1 \
    "${ROOT}/bin/pi-run" snapshot check

echo "snapshot check tests passed"
