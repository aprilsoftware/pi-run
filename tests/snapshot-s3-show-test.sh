#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-s3-show-test: $*" >&2
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

SNAPSHOT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
REQUEST_ID=11111111-1111-4111-8111-111111111111
mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
call="${DOCKER_LOG:?}.$$"
: > "${call}"
operation=
reference=
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${call}"
    case "${argument}" in init|snapshots|dump) operation=${argument} ;; esac
    case "${argument}" in
        [0-9a-f]*)
            if [ "${#argument}" -eq 12 ] || [ "${#argument}" -eq 64 ]; then reference=${argument}; fi
            ;;
    esac
done
printf '%s\n' '---' >> "${DOCKER_LOG}"
cat "${call}" >> "${DOCKER_LOG}"
if [ "${operation}" = dump ]; then cat "${call}" >> "${DUMP_LOG:?}"; fi
rm -f "${call}"
case "${operation}" in
    init) : > "${REMOTE_MARKER:?}" ;;
    snapshots)
        [ -e "${REMOTE_MARKER:?}" ] || exit 1
        if [ -n "${reference}" ]; then printf '%s\n' "${SNAPSHOT_METADATA:-[]}"; else printf '[]\n'; fi
        ;;
    dump)
        [ "${FAIL_DUMP:-0}" = 0 ] || exit 1
        cat "${MANIFEST_FILE:?}"
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

HOME_DIR="${TMP}/Pi Run"
export DOCKER_LOG="${TMP}/docker.log" DUMP_LOG="${TMP}/dump.log" REMOTE_MARKER="${TMP}/remote"
: > "${DOCKER_LOG}"
: > "${DUMP_LOG}"
printf '2\nhttps://ceph.example.test\npi-run-backups\nusers/alice\neu-west-1\n1\nyes\nACCESS_123\nSECRET/456+=\n' | env \
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DUMP_LOG="${DUMP_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null 2>&1

MANIFEST_FILE="${TMP}/manifest.json"
jq -n --arg request "${REQUEST_ID}" '{
    schemaVersion:1,
    requestId:$request,
    createdAt:"2026-08-01T10:00:00Z",
    scope:"complete",
    piRunVersion:"0.5.12",
    runtimeImage:"ghcr.io/aprilsoftware/pi-run:0.5.12",
    piVersion:"1.1.0",
    homeConfigurationSchemaVersion:1,
    profileSchemaVersion:1,
    workspaceRegistrySchemaVersion:1,
    snapshotConfigurationSchemaVersion:1,
    includedPaths:["config.json","profiles","skills","shared","workspaces","snapshots/config.json","snapshots/metadata/11111111-1111-4111-8111-111111111111.json"],
    excludedPaths:["machines","snapshots/secrets","snapshots/s3-credentials","snapshots/repository","snapshots/restore-staging"]
}' > "${MANIFEST_FILE}"
SNAPSHOT_METADATA="$(jq -nc --arg id "${SNAPSHOT_ID}" --arg request "${REQUEST_ID}" '[{
    id:$id,time:"2026-08-01T10:00:00Z",tags:["pi-run","scope=complete",("request="+$request)]
}]')"
export MANIFEST_FILE SNAPSHOT_METADATA

: > "${DOCKER_LOG}"
: > "${DUMP_LOG}"
output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DUMP_LOG="${DUMP_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    MANIFEST_FILE="${MANIFEST_FILE}" SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" \
    "${ROOT}/bin/pi-run" snapshot show "${SNAPSHOT_ID:0:12}")"
[[ "${output}" == *"Snapshot: ${SNAPSHOT_ID}"* &&
   "${output}" == *"Request: ${REQUEST_ID}"* &&
   "${output}" == *'Runtime image: ghcr.io/aprilsoftware/pi-run:0.5.12'* &&
   "${output}" == *'snapshots/s3-credentials'* ]] || fail "S3 show output is incomplete"
for argument in '--network' bridge '--no-lock' dump "${SNAPSHOT_ID}" '/input/snapshot-manifest.json' \
    'AWS_SHARED_CREDENTIALS_FILE=/s3-credentials' 's3.region=eu-west-1' 's3.bucket-lookup=path'; do
    grep -Fx -- "${argument}" "${DUMP_LOG}" >/dev/null || fail "missing dump argument: ${argument}"
done
grep -F "src=${HOME_DIR}/snapshots/secrets,dst=/secret,readonly" "${DUMP_LOG}" >/dev/null \
    || fail "snapshot secret was not mounted read-only"
grep -F "src=${HOME_DIR}/snapshots/s3-credentials,dst=/s3-credentials,readonly" "${DUMP_LOG}" >/dev/null \
    || fail "S3 credentials were not mounted read-only"
if grep -F 'dst=/repository' "${DUMP_LOG}" >/dev/null; then fail "S3 show mounted a local repository"; fi
if grep -E 'ACCESS_123|SECRET/456' "${DOCKER_LOG}" >/dev/null; then fail "credentials leaked into Docker arguments"; fi

env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DUMP_LOG="${DUMP_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    MANIFEST_FILE="${MANIFEST_FILE}" SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" \
    "${ROOT}/bin/pi-run" snapshot show "${SNAPSHOT_ID}" >/dev/null
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DUMP_LOG="${DUMP_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    MANIFEST_FILE="${MANIFEST_FILE}" SNAPSHOT_METADATA='[]' \
    "${ROOT}/bin/pi-run" snapshot show bbbbbbbbbbbb

AMBIGUOUS="$(jq -nc --arg request "${REQUEST_ID}" '[
    {id:"dddddddddddd1111111111111111111111111111111111111111111111111111",time:"2026-08-01T10:00:00Z",tags:["pi-run","scope=complete",("request="+$request)]},
    {id:"dddddddddddd2222222222222222222222222222222222222222222222222222",time:"2026-08-02T10:00:00Z",tags:["pi-run","scope=complete",("request="+$request)]}
]')"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DUMP_LOG="${DUMP_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    MANIFEST_FILE="${MANIFEST_FILE}" SNAPSHOT_METADATA="${AMBIGUOUS}" \
    "${ROOT}/bin/pi-run" snapshot show dddddddddddd
FOREIGN="$(jq -nc --arg id "${SNAPSHOT_ID}" '[{id:$id,time:"2026-08-01T10:00:00Z",tags:["foreign","scope=complete","request=11111111-1111-4111-8111-111111111111"]}]')"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DUMP_LOG="${DUMP_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    MANIFEST_FILE="${MANIFEST_FILE}" SNAPSHOT_METADATA="${FOREIGN}" \
    "${ROOT}/bin/pi-run" snapshot show "${SNAPSHOT_ID:0:12}"

BAD_MANIFEST="${TMP}/bad-manifest"
printf '{bad json\n' > "${BAD_MANIFEST}"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DUMP_LOG="${DUMP_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    MANIFEST_FILE="${BAD_MANIFEST}" SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" \
    "${ROOT}/bin/pi-run" snapshot show "${SNAPSHOT_ID:0:12}"
jq '.requestId="22222222-2222-4222-8222-222222222222"' "${MANIFEST_FILE}" > "${TMP}/mismatch.json"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DUMP_LOG="${DUMP_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    MANIFEST_FILE="${TMP}/mismatch.json" SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" \
    "${ROOT}/bin/pi-run" snapshot show "${SNAPSHOT_ID:0:12}"
head -c 262145 /dev/zero | tr '\0' x > "${TMP}/oversized"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DUMP_LOG="${DUMP_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    MANIFEST_FILE="${TMP}/oversized" SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" \
    "${ROOT}/bin/pi-run" snapshot show "${SNAPSHOT_ID:0:12}"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DUMP_LOG="${DUMP_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    MANIFEST_FILE="${MANIFEST_FILE}" SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" FAIL_DUMP=1 \
    "${ROOT}/bin/pi-run" snapshot show "${SNAPSHOT_ID:0:12}"

echo "S3 snapshot show tests passed"
