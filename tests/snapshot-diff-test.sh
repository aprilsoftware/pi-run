#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-diff-test: $*" >&2
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
BASELINE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
LATEST=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
mkdir -p "${TMP}/fake-bin"

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
: > "${DOCKER_LOG:?}"
repository=
operation=
tagged=false
previous=
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG}"
    case "${argument}" in
        RESTIC_REPOSITORY=/snapshots/*) repository=${argument#RESTIC_REPOSITORY=} ;;
        init|snapshots|diff) operation=${argument} ;;
    esac
    if [ "${previous}" = --tag ] && [ "${argument}" = pi-run ]; then tagged=true; fi
    previous=${argument}
done
case "${operation}" in
    init)
        destination="${SNAPSHOT_TEST_ROOT:?}/${repository#/snapshots/}"
        mkdir "${destination}"
        printf 'restic repository\n' > "${destination}/config"
        ;;
    snapshots)
        if [ "${tagged}" = true ]; then
            printf '%s\n' "${DIFF_METADATA:-[]}"
        else
            printf '[]\n'
        fi
        ;;
    diff)
        [ "${FAIL_DIFF:-0}" = 0 ] || exit 1
        printf '%s\n' "${DIFF_RESPONSE:-}"
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"
export SNAPSHOT_TEST_ROOT="${HOME_DIR}/snapshots"

printf '1\nyes\n' | env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null
DIFF_METADATA="$(jq -nc --arg baseline "${BASELINE}" --arg latest "${LATEST}" '[
    {id:$latest,time:"2026-08-02T11:30:00Z",tags:["pi-run","scope=complete","request=22222222-2222-4222-8222-222222222222"]},
    {id:$baseline,time:"2026-08-01T10:00:00Z",tags:["request=11111111-1111-4111-8111-111111111111","scope=complete","pi-run"]}
]')"
DIFF_RESPONSE="$(jq -nc --arg baseline "${BASELINE}" --arg latest "${LATEST}" '
    {message_type:"change",path:"/input/shared/old.txt",modifier:"-"},
    {message_type:"change",path:"/input/shared/new.txt",modifier:"+"},
    {message_type:"change",path:"/input/profiles/default/settings.json",modifier:"U"},
    {
        message_type:"statistics",source_snapshot:$baseline,target_snapshot:$latest,
        changed_files:1,
        added:{files:1,dirs:0,others:0,data_blobs:1,tree_blobs:2,bytes:20},
        removed:{files:1,dirs:0,others:0,data_blobs:1,tree_blobs:2,bytes:10}
    }
')"
export DIFF_METADATA DIFF_RESPONSE

output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot diff "${BASELINE:0:12}")"
[[ "${output}" == *"Baseline: ${BASELINE}"* &&
   "${output}" == *"Latest: ${LATEST}"* &&
   "${output}" == *"/input/shared/new.txt"* &&
   "${output}" == *"Changed files: 1"* &&
   "${output}" == *"Added: 1 files, 0 dirs, 20 bytes"* &&
   "${output}" == *"Removed: 1 files, 0 dirs, 10 bytes"* ]] \
    || fail "snapshot diff output is incomplete"
for argument in --no-lock diff --json --metadata "${BASELINE}" "${LATEST}"; do
    grep -Fx -- "${argument}" "${DOCKER_LOG}" >/dev/null \
        || fail "missing Restic diff argument: ${argument}"
done
grep -F "type=bind,src=${HOME_DIR}/snapshots,dst=/snapshots,readonly" "${DOCKER_LOG}" >/dev/null \
    || fail "diff did not use a read-only repository mount"

PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot diff "${BASELINE}" >/dev/null
latest_output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot diff "${LATEST:0:12}")"
[[ "${latest_output}" == *"selected snapshot is already latest"* ]] \
    || fail "latest snapshot was not handled directly"
if grep -Fx -- diff "${DOCKER_LOG}" >/dev/null; then
    fail "latest snapshot invoked Restic diff"
fi

expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" DIFF_METADATA="${DIFF_METADATA}" \
    DIFF_RESPONSE="${DIFF_RESPONSE}" "${ROOT}/bin/pi-run" snapshot diff dddddddddddd
AMBIGUOUS="$(jq -nc '[
    {id:"dddddddddddd1111111111111111111111111111111111111111111111111111",time:"2026-08-01T00:00:00Z",tags:["pi-run","scope=complete","request=11111111-1111-4111-8111-111111111111"]},
    {id:"dddddddddddd2222222222222222222222222222222222222222222222222222",time:"2026-08-02T00:00:00Z",tags:["pi-run","scope=complete","request=22222222-2222-4222-8222-222222222222"]}
]')"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" DIFF_METADATA="${AMBIGUOUS}" \
    DIFF_RESPONSE="${DIFF_RESPONSE}" "${ROOT}/bin/pi-run" snapshot diff dddddddddddd
MISMATCHED="$(jq -nc --arg latest "${LATEST}" '
    {message_type:"statistics",source_snapshot:"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",target_snapshot:$latest,changed_files:0,added:{files:0,dirs:0,others:0,data_blobs:0,tree_blobs:0,bytes:0},removed:{files:0,dirs:0,others:0,data_blobs:0,tree_blobs:0,bytes:0}}
')"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" DIFF_METADATA="${DIFF_METADATA}" \
    DIFF_RESPONSE="${MISMATCHED}" "${ROOT}/bin/pi-run" snapshot diff "${BASELINE:0:12}"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" DIFF_METADATA="${DIFF_METADATA}" \
    DIFF_RESPONSE='not-json' "${ROOT}/bin/pi-run" snapshot diff "${BASELINE:0:12}"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" DIFF_METADATA="${DIFF_METADATA}" \
    DIFF_RESPONSE="${DIFF_RESPONSE}" FAIL_DIFF=1 \
    "${ROOT}/bin/pi-run" snapshot diff "${BASELINE:0:12}"

echo "snapshot diff tests passed"
