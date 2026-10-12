#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-s3-delete-test: $*" >&2
    exit 1
}

FULL_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHORT_ID=bbbbbbbbbbbb
REQUEST_ID=22222222-2222-4222-8222-222222222222
HOME_DIR="${TMP}/Pi Run"
STATE_FILE="${TMP}/snapshot-present"
REMOTE_MARKER="${TMP}/remote"
DOCKER_LOG="${TMP}/docker.log"
FORGET_LOG="${TMP}/forget.log"
MANIFEST_FILE="${TMP}/manifest.json"
mkdir -p "${TMP}/fake-bin"

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
operation=
call="${DOCKER_LOG:?}.$$"
: > "${call}"
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${call}"
    case "${argument}" in init|snapshots|dump|forget|check) operation=${argument} ;; esac
done
printf '%s\n' '---' >> "${DOCKER_LOG}"
cat "${call}" >> "${DOCKER_LOG}"
case "${operation}" in
    init) : > "${REMOTE_MARKER:?}" ;;
    snapshots)
        [ -e "${REMOTE_MARKER:?}" ] || exit 1
        if [ -e "${STATE_FILE:?}" ]; then printf '%s\n' "${SNAPSHOT_METADATA:?}"; else printf '[]\n'; fi
        ;;
    dump) cat "${MANIFEST_FILE:?}" ;;
    forget)
        printf '%s\n' '---' >> "${FORGET_LOG:?}"
        cat "${call}" >> "${FORGET_LOG}"
        rm -f "${call}"
        [ "${FAIL_FORGET:-0}" = 0 ] || exit 1
        rm -f "${STATE_FILE}"
        exit 0
        ;;
    check)
        printf '%s\n' '{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}'
        ;;
    *) rm -f "${call}"; exit 2 ;;
esac
rm -f "${call}"
EOF
chmod 0755 "${TMP}/fake-bin/docker"

export STATE_FILE REMOTE_MARKER DOCKER_LOG FORGET_LOG MANIFEST_FILE
: > "${DOCKER_LOG}"
: > "${FORGET_LOG}"
printf '2\nhttps://ceph.example.test\npi-run-backups\nusers/alice\neu-west-1\n1\nyes\nACCESS_123\nSECRET/456+=\n' | env \
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null 2>&1

SNAPSHOT_METADATA="$(jq -nc --arg id "${FULL_ID}" --arg request "${REQUEST_ID}" '[{
    id:$id,time:"2026-08-03T12:00:00Z",hostname:"fedcba9876543210",
    tags:["pi-run","scope=complete",("request="+$request)]
}]')"
jq -n --arg request "${REQUEST_ID}" '{
    schemaVersion:1,requestId:$request,createdAt:"2026-08-03T11:59:59Z",scope:"complete",
    piRunVersion:"0.5.13",runtimeImage:"ghcr.io/aprilsoftware/pi-run:0.5.13",piVersion:"1.1.0",
    homeConfigurationSchemaVersion:1,profileSchemaVersion:1,workspaceRegistrySchemaVersion:1,
    snapshotConfigurationSchemaVersion:1,
    includedPaths:["config.json","profiles","skills","shared","workspaces","snapshots/config.json"],
    excludedPaths:["machines","snapshots/secrets","snapshots/repository","snapshots/restore-staging"]
}' > "${MANIFEST_FILE}"
export SNAPSHOT_METADATA

run_delete() {
    script -qec "env PATH='${TMP}/fake-bin:${PATH}' PI_RUN_HOME='${HOME_DIR}' FAIL_FORGET='${FAIL_FORGET:-0}' '${ROOT}/bin/pi-run' snapshot delete '${SHORT_ID}'" /dev/null
}

: > "${FORGET_LOG}"
touch "${STATE_FILE}"
FAIL_FORGET=1
set +e
printf '%s\n' "${FULL_ID}" | run_delete >/dev/null 2>&1
status=$?
set -e
FAIL_FORGET=0
[[ ${status} -ne 0 ]] || fail "failed S3 forget unexpectedly succeeded"
[[ "$(grep -Fxc -- '---' "${FORGET_LOG}")" == 1 ]] || fail "failed S3 forget was retried"
[[ -e "${STATE_FILE}" ]] || fail "failed S3 fixture unexpectedly removed the snapshot"

: > "${DOCKER_LOG}"
: > "${FORGET_LOG}"
output="$(printf '%s\n' "${FULL_ID}" | run_delete)"
[[ "${output}" == *"Snapshot deleted and repository pruned: ${FULL_ID}"* ]] \
    || fail "S3 deletion success was not reported"
[[ ! -e "${STATE_FILE}" ]] || fail "S3 snapshot remained after deletion"
[[ "$(grep -Fxc -- '---' "${FORGET_LOG}")" == 1 ]] || fail "S3 forget was not executed exactly once"
for argument in '--network' bridge forget "${FULL_ID}" --prune --no-cache \
    'AWS_SHARED_CREDENTIALS_FILE=/s3-credentials' 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' \
    's3.region=eu-west-1' 's3.bucket-lookup=path' 's3.connections=2'; do
    grep -Fx -- "${argument}" "${FORGET_LOG}" >/dev/null || fail "missing S3 forget argument: ${argument}"
done
grep -F "src=${HOME_DIR}/snapshots/secrets,dst=/secret,readonly" "${FORGET_LOG}" >/dev/null \
    || fail "snapshot secret was not mounted read-only"
grep -F "src=${HOME_DIR}/snapshots/s3-credentials,dst=/s3-credentials,readonly" "${FORGET_LOG}" >/dev/null \
    || fail "S3 credentials were not mounted read-only"
if grep -Fx -- '--no-lock' "${FORGET_LOG}" >/dev/null; then fail "S3 forget disabled repository locking"; fi
if grep -E 'ACCESS_123|SECRET/456' "${DOCKER_LOG}" >/dev/null; then fail "S3 credentials leaked into Docker arguments"; fi

echo "S3 snapshot delete and prune tests passed"
