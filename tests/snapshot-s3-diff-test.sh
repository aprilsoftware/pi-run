#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-s3-diff-test: $*" >&2
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

BASELINE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
LATEST=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
call="${DOCKER_LOG:?}.$$"
: > "${call}"
operation=
tagged=false
previous=
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${call}"
    case "${argument}" in init|snapshots|diff) operation=${argument} ;; esac
    if [ "${previous}" = --tag ] && [ "${argument}" = pi-run ]; then tagged=true; fi
    previous=${argument}
done
printf '%s\n' '---' >> "${DOCKER_LOG}"
cat "${call}" >> "${DOCKER_LOG}"
if [ "${operation}" = diff ]; then cat "${call}" >> "${DIFF_LOG:?}"; fi
rm -f "${call}"
case "${operation}" in
    init) : > "${REMOTE_MARKER:?}" ;;
    snapshots)
        [ -e "${REMOTE_MARKER:?}" ] || exit 1
        if [ "${tagged}" = true ]; then printf '%s\n' "${SNAPSHOT_METADATA:-[]}"; else printf '[]\n'; fi
        ;;
    diff)
        [ "${FAIL_DIFF:-0}" = 0 ] || exit 1
        printf '%s\n' "${DIFF_RESPONSE:-}"
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

HOME_DIR="${TMP}/Pi Run"
export DOCKER_LOG="${TMP}/docker.log" DIFF_LOG="${TMP}/diff.log" REMOTE_MARKER="${TMP}/remote"
: > "${DOCKER_LOG}"
: > "${DIFF_LOG}"
printf '2\nhttps://ceph.example.test\npi-run-backups\nusers/alice\neu-west-1\n1\nyes\nACCESS_123\nSECRET/456+=\n' | env \
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DIFF_LOG="${DIFF_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null 2>&1

SNAPSHOT_METADATA="$(jq -nc --arg baseline "${BASELINE}" --arg latest "${LATEST}" '[
    {id:$latest,time:"2026-08-02T11:30:00Z",tags:["pi-run","scope=complete","request=22222222-2222-4222-8222-222222222222"]},
    {id:$baseline,time:"2026-08-01T10:00:00Z",tags:["request=11111111-1111-4111-8111-111111111111","scope=complete","pi-run"]}
]')"
DIFF_RESPONSE="$(jq -nc --arg baseline "${BASELINE}" --arg latest "${LATEST}" '
    {message_type:"change",path:"/input/shared/old.txt",modifier:"-"},
    {message_type:"change",path:"/input/shared/new.txt",modifier:"+"},
    {message_type:"change",path:"/input/profiles/default/settings.json",modifier:"U"},
    {message_type:"statistics",source_snapshot:$baseline,target_snapshot:$latest,changed_files:1,
     added:{files:1,dirs:0,others:0,data_blobs:1,tree_blobs:2,bytes:20},
     removed:{files:1,dirs:0,others:0,data_blobs:1,tree_blobs:2,bytes:10}}
')"
export SNAPSHOT_METADATA DIFF_RESPONSE

: > "${DOCKER_LOG}"
: > "${DIFF_LOG}"
output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DIFF_LOG="${DIFF_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" DIFF_RESPONSE="${DIFF_RESPONSE}" \
    "${ROOT}/bin/pi-run" snapshot diff "${BASELINE:0:12}")"
[[ "${output}" == *"Baseline: ${BASELINE}"* && "${output}" == *"Latest: ${LATEST}"* &&
   "${output}" == *'/input/shared/new.txt'* && "${output}" == *'Changed files: 1'* &&
   "${output}" == *'Added: 1 files, 0 dirs, 20 bytes'* ]] || fail "S3 diff output is incomplete"
for argument in '--network' bridge '--no-lock' diff '--json' '--metadata' "${BASELINE}" "${LATEST}" \
    'AWS_SHARED_CREDENTIALS_FILE=/s3-credentials' 's3.region=eu-west-1' 's3.bucket-lookup=path'; do
    grep -Fx -- "${argument}" "${DIFF_LOG}" >/dev/null || fail "missing diff argument: ${argument}"
done
grep -F "src=${HOME_DIR}/snapshots/secrets,dst=/secret,readonly" "${DIFF_LOG}" >/dev/null \
    || fail "snapshot secret was not mounted read-only"
grep -F "src=${HOME_DIR}/snapshots/s3-credentials,dst=/s3-credentials,readonly" "${DIFF_LOG}" >/dev/null \
    || fail "S3 credentials were not mounted read-only"
if grep -F 'dst=/repository' "${DIFF_LOG}" >/dev/null; then fail "S3 diff mounted a local repository"; fi
if grep -E 'ACCESS_123|SECRET/456' "${DOCKER_LOG}" >/dev/null; then fail "credentials leaked into Docker arguments"; fi

env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DIFF_LOG="${DIFF_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" DIFF_RESPONSE="${DIFF_RESPONSE}" \
    "${ROOT}/bin/pi-run" snapshot diff "${BASELINE}" >/dev/null
: > "${DIFF_LOG}"
latest_output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DIFF_LOG="${DIFF_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" DIFF_RESPONSE="${DIFF_RESPONSE}" \
    "${ROOT}/bin/pi-run" snapshot diff "${LATEST:0:12}")"
[[ "${latest_output}" == *'selected snapshot is already latest'* && ! -s "${DIFF_LOG}" ]] \
    || fail "latest S3 snapshot invoked Restic diff"

expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DIFF_LOG="${DIFF_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" DIFF_RESPONSE="${DIFF_RESPONSE}" \
    "${ROOT}/bin/pi-run" snapshot diff dddddddddddd
AMBIGUOUS="$(jq -nc '[
    {id:"dddddddddddd1111111111111111111111111111111111111111111111111111",time:"2026-08-01T00:00:00Z",tags:["pi-run","scope=complete","request=11111111-1111-4111-8111-111111111111"]},
    {id:"dddddddddddd2222222222222222222222222222222222222222222222222222",time:"2026-08-02T00:00:00Z",tags:["pi-run","scope=complete","request=22222222-2222-4222-8222-222222222222"]}
]')"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DIFF_LOG="${DIFF_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    SNAPSHOT_METADATA="${AMBIGUOUS}" DIFF_RESPONSE="${DIFF_RESPONSE}" \
    "${ROOT}/bin/pi-run" snapshot diff dddddddddddd
MISMATCHED="$(jq -nc --arg latest "${LATEST}" '{message_type:"statistics",source_snapshot:"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",target_snapshot:$latest,changed_files:0,added:{files:0,dirs:0,others:0,data_blobs:0,tree_blobs:0,bytes:0},removed:{files:0,dirs:0,others:0,data_blobs:0,tree_blobs:0,bytes:0}}')"
for response in 'not-json' "${MISMATCHED}"; do
    expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        DOCKER_LOG="${DOCKER_LOG}" DIFF_LOG="${DIFF_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
        SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" DIFF_RESPONSE="${response}" \
        "${ROOT}/bin/pi-run" snapshot diff "${BASELINE:0:12}"
done
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" DIFF_LOG="${DIFF_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" DIFF_RESPONSE="${DIFF_RESPONSE}" FAIL_DIFF=1 \
    "${ROOT}/bin/pi-run" snapshot diff "${BASELINE:0:12}"

echo "S3 snapshot diff tests passed"
