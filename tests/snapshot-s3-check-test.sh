#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-s3-check-test: $*" >&2
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

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
call="${DOCKER_LOG:?}.$$"
: > "${call}"
operation=
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${call}"
    case "${argument}" in init|snapshots|check) operation=${argument} ;; esac
done
printf '%s\n' '---' >> "${DOCKER_LOG}"
cat "${call}" >> "${DOCKER_LOG}"
if [ "${operation}" = check ]; then cat "${call}" >> "${CHECK_LOG:?}"; fi
rm -f "${call}"
case "${operation}" in
    init) : > "${REMOTE_MARKER:?}" ;;
    snapshots)
        [ -e "${REMOTE_MARKER:?}" ] || exit 1
        printf '[]\n'
        ;;
    check)
        [ "${FAIL_CHECK:-0}" = 0 ] || exit 1
        printf '%s\n' "${CHECK_RESPONSE:-}"
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

HOME_DIR="${TMP}/Pi Run"
export DOCKER_LOG="${TMP}/docker.log" CHECK_LOG="${TMP}/check.log" REMOTE_MARKER="${TMP}/remote"
: > "${DOCKER_LOG}"
: > "${CHECK_LOG}"
printf '2\nhttps://ceph.example.test\npi-run-backups\nusers/alice\neu-west-1\n1\nyes\nACCESS_123\nSECRET/456+=\n' | env \
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" CHECK_LOG="${CHECK_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null 2>&1

HEALTHY='{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}'
export CHECK_RESPONSE="${HEALTHY}"
: > "${DOCKER_LOG}"
: > "${CHECK_LOG}"
output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" CHECK_LOG="${CHECK_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    CHECK_RESPONSE="${CHECK_RESPONSE}" "${ROOT}/bin/pi-run" snapshot check)"
[[ "${output}" == *'Snapshot check: OK'* && "${output}" == *'Data verification: complete'* ]] \
    || fail "healthy S3 check output is incomplete"
for argument in '--network' bridge '--no-lock' check '--read-data' '--json' \
    'AWS_SHARED_CREDENTIALS_FILE=/s3-credentials' 's3.region=eu-west-1' 's3.bucket-lookup=path'; do
    grep -Fx -- "${argument}" "${CHECK_LOG}" >/dev/null || fail "missing check argument: ${argument}"
done
grep -F "src=${HOME_DIR}/snapshots/secrets,dst=/secret,readonly" "${CHECK_LOG}" >/dev/null \
    || fail "snapshot secret was not mounted read-only"
grep -F "src=${HOME_DIR}/snapshots/s3-credentials,dst=/s3-credentials,readonly" "${CHECK_LOG}" >/dev/null \
    || fail "S3 credentials were not mounted read-only"
if grep -F 'dst=/repository' "${CHECK_LOG}" >/dev/null; then fail "S3 check mounted a local repository"; fi
if grep -E 'ACCESS_123|SECRET/456' "${DOCKER_LOG}" >/dev/null; then fail "credentials leaked into Docker arguments"; fi

PRUNE_ADVISORY='{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":true}'
advisory_output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" CHECK_LOG="${CHECK_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    CHECK_RESPONSE="${PRUNE_ADVISORY}" "${ROOT}/bin/pi-run" snapshot check)"
[[ "${advisory_output}" == *'Snapshot check: OK'* &&
   "${advisory_output}" == *'Restic found unused repository data'* &&
   "${advisory_output}" == *'Snapshot check does not delete or prune repository data.'* ]] \
    || fail "S3 prune recommendation was not reported as a non-fatal advisory"

for response in \
    'not-json' \
    '{"message_type":"summary","num_errors":1,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}' \
    '{"message_type":"summary","num_errors":0,"broken_packs":["pack"],"suggest_repair_index":false,"suggest_prune":false}' \
    '{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":true,"suggest_prune":false}' \
    $'{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}\n{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}'; do
    expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        DOCKER_LOG="${DOCKER_LOG}" CHECK_LOG="${CHECK_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
        CHECK_RESPONSE="${response}" "${ROOT}/bin/pi-run" snapshot check
done
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" CHECK_LOG="${CHECK_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    CHECK_RESPONSE="${HEALTHY}" FAIL_CHECK=1 "${ROOT}/bin/pi-run" snapshot check

echo "S3 snapshot check tests passed"
