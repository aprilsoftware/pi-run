#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-delete-test: $*" >&2
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

FULL_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHORT_ID=aaaaaaaaaaaa
REQUEST_ID=11111111-1111-4111-8111-111111111111
HOME_DIR="${TMP}/Pi Run"
STATE_FILE="${TMP}/snapshot-present"
DOCKER_LOG="${TMP}/docker.log"
FORGET_LOG="${TMP}/forget.log"
MANIFEST_FILE="${TMP}/manifest.json"
mkdir -p "${TMP}/fake-bin"

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
operation=
repository=
call="${DOCKER_LOG:?}.$$"
: > "${call}"
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${call}"
    case "${argument}" in
        RESTIC_REPOSITORY=/snapshots/*) repository=${argument#RESTIC_REPOSITORY=} ;;
        init|snapshots|dump|forget|check) operation=${argument} ;;
    esac
done
printf '%s\n' '---' >> "${DOCKER_LOG}"
cat "${call}" >> "${DOCKER_LOG}"
case "${operation}" in
    init)
        destination="${SNAPSHOT_TEST_ROOT:?}/${repository#/snapshots/}"
        mkdir "${destination}"
        printf repository > "${destination}/config"
        ;;
    snapshots)
        if [ -e "${STATE_FILE:?}" ]; then
            printf '%s\n' "${SNAPSHOT_METADATA:?}"
        else
            printf '[]\n'
        fi
        ;;
    dump)
        cat "${MANIFEST_FILE:?}"
        ;;
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

export DOCKER_LOG FORGET_LOG STATE_FILE MANIFEST_FILE
export SNAPSHOT_TEST_ROOT="${HOME_DIR}/snapshots"
: > "${DOCKER_LOG}"
: > "${FORGET_LOG}"
printf '1\nyes\n' | env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null

SNAPSHOT_METADATA="$(jq -nc --arg id "${FULL_ID}" --arg request "${REQUEST_ID}" '[{
    id:$id,time:"2026-08-02T11:30:00Z",hostname:"0123456789abcdef",
    tags:["pi-run","scope=complete",("request="+$request)]
}]')"
jq -n --arg request "${REQUEST_ID}" '{
    schemaVersion:1,requestId:$request,createdAt:"2026-08-02T11:29:59Z",scope:"complete",
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

expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot delete invalid

: > "${FORGET_LOG}"
touch "${STATE_FILE}"
cancel_output="$(printf 'no\n' | run_delete)"
[[ "${cancel_output}" == *'Snapshot deletion cancelled.'* ]] || fail "deletion cancellation was not reported"
[[ -e "${STATE_FILE}" && ! -s "${FORGET_LOG}" ]] || fail "cancelled deletion changed the repository"

: > "${DOCKER_LOG}"
: > "${FORGET_LOG}"
touch "${STATE_FILE}"
delete_output="$(printf '%s\n' "${FULL_ID}" | run_delete)"
[[ "${delete_output}" == *"Snapshot to delete: ${FULL_ID}"* &&
   "${delete_output}" == *'Machine: 0123456789abcdef'* &&
   "${delete_output}" == *'Repository structural check: OK'* &&
   "${delete_output}" == *"Snapshot deleted and repository pruned: ${FULL_ID}"* ]] \
    || fail "successful deletion output is incomplete"
[[ ! -e "${STATE_FILE}" ]] || fail "snapshot remained after deletion"
[[ "$(grep -Fxc -- '---' "${FORGET_LOG}")" == 1 ]] || fail "forget was not executed exactly once"
for argument in forget "${FULL_ID}" --prune --no-cache; do
    grep -Fx -- "${argument}" "${FORGET_LOG}" >/dev/null || fail "missing forget argument: ${argument}"
done
if grep -Fx -- '--no-lock' "${FORGET_LOG}" >/dev/null; then fail "forget disabled repository locking"; fi
grep -Fx -- check "${DOCKER_LOG}" >/dev/null || fail "structural check was not executed"
if grep -Fx -- '--read-data' "${DOCKER_LOG}" >/dev/null; then fail "post-prune check unexpectedly read all data"; fi
if grep -Ex -- 'unlock|repair' "${DOCKER_LOG}" >/dev/null; then fail "deletion attempted unlock or repair"; fi

: > "${FORGET_LOG}"
touch "${STATE_FILE}"
FAIL_FORGET=1
set +e
printf '%s\n' "${FULL_ID}" | run_delete >/dev/null 2>&1
status=$?
set -e
FAIL_FORGET=0
[[ ${status} -ne 0 ]] || fail "failed forget unexpectedly succeeded"
[[ "$(grep -Fxc -- '---' "${FORGET_LOG}")" == 1 ]] || fail "failed forget was retried"

FOREIGN_METADATA="$(jq -c '.[0].tags=["foreign","scope=complete","request=11111111-1111-4111-8111-111111111111"]' \
    <<< "${SNAPSHOT_METADATA}")"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_METADATA="${FOREIGN_METADATA}" "${ROOT}/bin/pi-run" snapshot delete "${SHORT_ID}"

exec {LOCK_FD}<"${HOME_DIR}"
flock -s "${LOCK_FD}"
shared_output="$(printf 'no\n' | run_delete)"
[[ "${shared_output}" == *'Snapshot deletion cancelled.'* && -e "${STATE_FILE}" ]] \
    || fail "a running Pi session blocked or changed snapshot deletion"
flock -u "${LOCK_FD}"
exec {LOCK_FD}<&-

exec {LOCK_FD}<"${HOME_DIR}/snapshots"
flock -x "${LOCK_FD}"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot delete "${SHORT_ID}"
flock -u "${LOCK_FD}"
exec {LOCK_FD}<&-

exec {LOCK_FD}<"${HOME_DIR}"
flock -x "${LOCK_FD}"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot delete "${SHORT_ID}"
flock -u "${LOCK_FD}"
exec {LOCK_FD}<&-

echo "snapshot delete and prune tests passed"
