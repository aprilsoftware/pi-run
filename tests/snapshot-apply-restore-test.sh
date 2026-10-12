#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap '[[ -z "${LOCK_PID:-}" ]] || kill "${LOCK_PID}" 2>/dev/null || true; rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-apply-restore-test: $*" >&2
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

RESTORE_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RESTORE_REQUEST=11111111-1111-4111-8111-111111111111
PRE_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
operation=
repository=
reference=
request=
target=
pi_entry=false
printf '%s\n' '---' >> "${DOCKER_LOG:?}"
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG}"
    case "${argument}" in init|snapshots|backup|restore) operation=${argument} ;; esac
    case "${argument}" in
        RESTIC_REPOSITORY=*) repository=${argument#RESTIC_REPOSITORY=} ;;
        type=bind,src=*,dst=/restore) target=${argument#type=bind,src=}; target=${target%,dst=/restore} ;;
        request=*) request=${argument#request=} ;;
        pi) pi_entry=true ;;
        [0-9a-f]*)
            if [ "${#argument}" -eq 12 ] || [ "${#argument}" -eq 64 ]; then reference=${argument}; fi
            ;;
    esac
done
if [ "${pi_entry}" = true ] && [ -z "${operation}" ]; then printf '1.1.0\n'; exit 0; fi
case "${operation}" in
    init)
        destination="${SNAPSHOT_TEST_ROOT:?}/${repository#/snapshots/}"
        mkdir "${destination}"
        printf 'restic repository\n' > "${destination}/config"
        ;;
    backup)
        [ "${FAIL_BACKUP:-0}" = 0 ] || exit 1
        printf '%s\n' "${request}" > "${BACKUP_REQUEST:?}"
        printf '{"message_type":"summary","snapshot_id":"%s"}\n' "${PRE_ID:?}"
        ;;
    snapshots)
        if [ -z "${reference}" ]; then
            printf '[]\n'
        else
            case "${RESTORE_ID:?}" in
                "${reference}"*)
                    printf '[{"id":"%s","time":"2026-08-01T10:00:00Z","hostname":"0123456789abcdef","tags":["pi-run","scope=complete","request=%s"]}]\n' \
                        "${RESTORE_ID}" "${RESTORE_REQUEST:?}"
                    ;;
                *)
                    request=$(cat "${BACKUP_REQUEST:?}")
                    printf '[{"id":"%s","time":"2026-08-03T10:00:00Z","tags":["pi-run","scope=complete","request=%s","purpose=pre-restore"]}]\n' \
                        "${PRE_ID:?}" "${request}"
                    ;;
            esac
        fi
        ;;
    restore)
        cp -a "${RESTORE_FIXTURE:?}/." "${target}/"
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

REAL_MV="$(command -v mv)"
cat > "${TMP}/fake-bin/mv" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"${REAL_MV}" "\$@"
case "\$*" in
    *restore-staging/pending*restore-staging/applying*|*restore-staging/applying/input/*|*restore-staging/applying/rollback/*)
        count=0
        [[ ! -f "\${MOVE_COUNT_FILE:-}" ]] || count="\$(<"\${MOVE_COUNT_FILE}")"
        count=\$((count + 1))
        printf '%s\n' "\${count}" > "\${MOVE_COUNT_FILE}"
        if [[ "\${count}" == "\${FAIL_MOVE_AFTER:-never}" && ! -e "\${MOVE_FAILED_FILE:-}" ]]; then
            : > "\${MOVE_FAILED_FILE}"
            if [[ "\${FAIL_MOVE_MODE:-error}" == kill ]]; then
                kill -KILL "\${PPID}"
                exit 137
            fi
            exit 1
        fi
        ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/mv"

export DOCKER_LOG="${TMP}/docker.log" BACKUP_REQUEST="${TMP}/backup-request" PRE_ID
: > "${DOCKER_LOG}"

run_pi() {
    local home="$1"
    shift
    env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
        DOCKER_LOG="${DOCKER_LOG}" BACKUP_REQUEST="${BACKUP_REQUEST}" PRE_ID="${PRE_ID}" \
        RESTORE_ID="${RESTORE_ID}" RESTORE_REQUEST="${RESTORE_REQUEST}" \
        RESTORE_FIXTURE="${home}/snapshots/restore-fixture" SNAPSHOT_TEST_ROOT="${home}/snapshots" \
        FAIL_BACKUP="${FAIL_BACKUP:-0}" MOVE_COUNT_FILE="${MOVE_COUNT_FILE:-${TMP}/unused-count}" \
        MOVE_FAILED_FILE="${MOVE_FAILED_FILE:-${TMP}/unused-failed}" \
        FAIL_MOVE_AFTER="${FAIL_MOVE_AFTER:-never}" FAIL_MOVE_MODE="${FAIL_MOVE_MODE:-error}" \
        "${ROOT}/bin/pi-run" "$@"
}

run_pi_detached() {
    local home="$1"
    shift
    setsid env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
        DOCKER_LOG="${DOCKER_LOG}" BACKUP_REQUEST="${BACKUP_REQUEST}" PRE_ID="${PRE_ID}" \
        RESTORE_ID="${RESTORE_ID}" RESTORE_REQUEST="${RESTORE_REQUEST}" \
        RESTORE_FIXTURE="${home}/snapshots/restore-fixture" SNAPSHOT_TEST_ROOT="${home}/snapshots" \
        FAIL_BACKUP="${FAIL_BACKUP:-0}" "${ROOT}/bin/pi-run" "$@"
}

run_pi_tty() {
    local home="$1" input="$2" command="" argument
    shift 2
    local -a invocation=(env "PATH=${TMP}/fake-bin:${PATH}" "PI_RUN_HOME=${home}"
        "DOCKER_LOG=${DOCKER_LOG}" "BACKUP_REQUEST=${BACKUP_REQUEST}" "PRE_ID=${PRE_ID}"
        "RESTORE_ID=${RESTORE_ID}" "RESTORE_REQUEST=${RESTORE_REQUEST}"
        "RESTORE_FIXTURE=${home}/snapshots/restore-fixture" "SNAPSHOT_TEST_ROOT=${home}/snapshots"
        "FAIL_BACKUP=${FAIL_BACKUP:-0}" "MOVE_COUNT_FILE=${MOVE_COUNT_FILE:-${TMP}/tty-move-count}"
        "MOVE_FAILED_FILE=${MOVE_FAILED_FILE:-${TMP}/tty-move-failed}"
        "FAIL_MOVE_AFTER=${FAIL_MOVE_AFTER:-never}" "FAIL_MOVE_MODE=${FAIL_MOVE_MODE:-error}"
        "${ROOT}/bin/pi-run" "$@")
    for argument in "${invocation[@]}"; do
        printf -v command '%s%q ' "${command}" "${argument}"
    done
    printf '%b' "${input}" | script -qefc "${command}" /dev/null
}

configure_local() {
    local home="$1"
    printf '1\nyes\n' | run_pi "${home}" snapshot configure >/dev/null
}

create_restore_fixture() {
    local home="$1" backend="$2"
    local fixture="${home}/snapshots/restore-fixture"
    rm -rf "${fixture}"
    mkdir -m 0700 "${fixture}" "${fixture}/input"
    cp -a "${home}/config.json" "${home}/profiles" "${home}/skills" \
        "${home}/shared" "${home}/workspaces" "${fixture}/input/"
    rm -rf "${fixture}/input/shared/"*
    printf 'restored\n' > "${fixture}/input/shared/restored.txt"
    cp "${home}/snapshots/config.json" "${fixture}/input/snapshot-config.json"
    jq -n --arg request "${RESTORE_REQUEST}" '{
        schemaVersion:1,requestId:$request,createdAt:"2026-08-01T10:00:00Z",scope:"complete",
        piRunVersion:"0.5.12",runtimeImage:"ghcr.io/aprilsoftware/pi-run:0.5.12",piVersion:"1.1.0",
        homeConfigurationSchemaVersion:1,profileSchemaVersion:1,workspaceRegistrySchemaVersion:1,
        snapshotConfigurationSchemaVersion:1,
        includedPaths:["config.json","profiles","skills","shared","workspaces","snapshots/config.json","snapshots/metadata/11111111-1111-4111-8111-111111111111.json"],
        excludedPaths:["machines","snapshots/secrets","snapshots/s3-credentials","snapshots/repository","snapshots/restore-staging"]
    }' > "${fixture}/input/snapshot-manifest.json"
    [[ "${backend}" == local || "${backend}" == s3 ]] || fail "invalid restore fixture backend"
}

CURRENT_WORKSPACE_ID=66666666-6666-4666-8666-666666666666
RESTORED_WORKSPACE_ID=77777777-7777-4777-8777-777777777777
RECONNECT_CHECKOUT=""
prepare_reconnect_case() {
    local home="$1" machine registry staged_registry session_dir
    cp -a "${LOCAL_BASE}" "${home}"
    RECONNECT_CHECKOUT="${home}-checkout/pi-run"
    mkdir -p "${RECONNECT_CHECKOUT}"
    run_pi "${home}" workspace list >/dev/null
    machine="$(find "${home}/machines" -maxdepth 1 -type f -name '*.json' -print -quit)"
    registry="${home}/workspaces/registry.json"
    staged_registry="${home}/snapshots/restore-fixture/input/workspaces/registry.json"
    jq --arg id "${CURRENT_WORKSPACE_ID}" \
        '.workspaces += [{id:$id,name:"pi-run",kind:"git",createdAt:"2026-10-10T10:00:00Z"}]' \
        "${registry}" > "${registry}.tmp"
    mv "${registry}.tmp" "${registry}"
    chmod 0600 "${registry}"
    jq --arg id "${CURRENT_WORKSPACE_ID}" --arg path "${RECONNECT_CHECKOUT}" \
        '.workspacePaths += [{workspaceId:$id,path:$path}]' "${machine}" > "${machine}.tmp"
    mv "${machine}.tmp" "${machine}"
    chmod 0600 "${machine}"
    jq --arg id "${RESTORED_WORKSPACE_ID}" \
        '.workspaces += [{id:$id,name:"pi-run",kind:"git",createdAt:"2026-10-09T10:00:00Z"}]' \
        "${staged_registry}" > "${staged_registry}.tmp"
    mv "${staged_registry}.tmp" "${staged_registry}"
    chmod 0600 "${staged_registry}"
    session_dir="${home}/snapshots/restore-fixture/input/profiles/default/sessions/${RESTORED_WORKSPACE_ID}"
    mkdir -p "${session_dir}"
    printf '%s\n' \
        '{"type":"session","id":"88888888-8888-4888-8888-888888888888","timestamp":"2026-10-10T12:00:00Z","cwd":"/workspace","version":3}' \
        > "${session_dir}/restored.jsonl"
}

LOCAL_BASE="${TMP}/local-base"
configure_local "${LOCAL_BASE}"
printf 'old\n' > "${LOCAL_BASE}/shared/old.txt"
printf 'machine-preserved\n' > "${LOCAL_BASE}/machines/preserved"
create_restore_fixture "${LOCAL_BASE}" local

LOCAL_HOME="${TMP}/local-apply"
cp -a "${LOCAL_BASE}" "${LOCAL_HOME}"
: > "${DOCKER_LOG}"
output="$(run_pi_tty "${LOCAL_HOME}" "${RESTORE_ID}\n" snapshot restore "${RESTORE_ID:0:12}")"
[[ "${output}" == *"Restore applied: ${RESTORE_ID}"* &&
   "${output}" == *"Pre-restore snapshot: ${PRE_ID}"* &&
   "${output}" == *'ready for the next launch'* ]] || fail "local apply output is incomplete"
[[ -f "${LOCAL_HOME}/shared/restored.txt" && ! -e "${LOCAL_HOME}/shared/old.txt" ]] \
    || fail "restored portable state was not applied"
[[ "$(cat "${LOCAL_HOME}/machines/preserved")" == machine-preserved ]] || fail "machine mappings were changed"
[[ -f "${LOCAL_HOME}/snapshots/secrets" && -d "${LOCAL_HOME}/snapshots/repository" ]] \
    || fail "snapshot secrets or repository were changed"
[[ -z "$(find "${LOCAL_HOME}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
    || fail "successful apply left transaction state"
[[ -n "$(find "${LOCAL_HOME}/snapshots/metadata" -type f -name '*.json' -print -quit)" ]] \
    || fail "pre-restore snapshot metadata was not retained"
grep -Fx -- 'purpose=pre-restore' "${DOCKER_LOG}" >/dev/null \
    || fail "pre-restore snapshot purpose was not passed to Restic"

PRE_FAILURE_HOME="${TMP}/pre-restore-failure"
cp -a "${LOCAL_BASE}" "${PRE_FAILURE_HOME}"
FAIL_BACKUP=1 expect_failure run_pi_tty "${PRE_FAILURE_HOME}" "${RESTORE_ID}\n" \
    snapshot restore "${RESTORE_ID:0:12}"
[[ -f "${PRE_FAILURE_HOME}/shared/old.txt" && ! -e "${PRE_FAILURE_HOME}/shared/restored.txt" ]] \
    || fail "pre-restore snapshot failure changed live data"
[[ -z "$(find "${PRE_FAILURE_HOME}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
    || fail "pre-restore snapshot failure left staging state"

RECONNECT_HOME="${TMP}/reconnect-apply"
prepare_reconnect_case "${RECONNECT_HOME}"
: > "${DOCKER_LOG}"
output="$(run_pi_tty "${RECONNECT_HOME}" "${RESTORE_ID}\n\n" snapshot restore "${RESTORE_ID:0:12}")"
[[ "${output}" == *'Restore can reconnect local checkouts to restored sessions:'* &&
   "${output}" == *"${RECONNECT_CHECKOUT} -> pi-run (1 session(s))"* &&
   "${output}" == *'Reconnected 1 local checkout(s) to restored sessions.'* ]] \
    || fail "restore-time workspace reconnection output is incomplete"
machine="$(find "${RECONNECT_HOME}/machines" -maxdepth 1 -type f -name '*.json' -print -quit)"
jq -e --arg id "${RESTORED_WORKSPACE_ID}" --arg path "${RECONNECT_CHECKOUT}" '
    [.workspacePaths[] | select(.workspaceId == $id and .path == $path)] | length == 1
' "${machine}" >/dev/null || fail "restore did not reconnect the local checkout"
jq -e --arg id "${CURRENT_WORKSPACE_ID}" '
    [.workspaces[] | select(.id == $id)] | length == 0
' "${RECONNECT_HOME}/workspaces/registry.json" >/dev/null \
    || fail "restore retained the empty pre-restore workspace identity"
[[ -f "${RECONNECT_HOME}/profiles/default/sessions/${RESTORED_WORKSPACE_ID}/restored.jsonl" &&
   -d "${RECONNECT_CHECKOUT}" ]] || fail "restore reconnection changed sessions or source files"

DEFERRED_HOME="${TMP}/deferred-apply"
prepare_reconnect_case "${DEFERRED_HOME}"
deferred_checkout="${RECONNECT_CHECKOUT}"
expect_failure run_pi_detached "${DEFERRED_HOME}" snapshot restore "${RESTORE_ID:0:12}"
[[ -z "$(find "${DEFERRED_HOME}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
    || fail "non-interactive restore left staging state"
machine="$(find "${DEFERRED_HOME}/machines" -maxdepth 1 -type f -name '*.json' -print -quit)"
jq -e --arg id "${CURRENT_WORKSPACE_ID}" --arg path "${deferred_checkout}" '
    [.workspacePaths[] | select(.workspaceId == $id and .path == $path)] | length == 1
' "${machine}" >/dev/null || fail "non-interactive restore changed the machine mapping"

DECLINED_HOME="${TMP}/declined-reconnect"
prepare_reconnect_case "${DECLINED_HOME}"
declined_checkout="${RECONNECT_CHECKOUT}"
output="$(run_pi_tty "${DECLINED_HOME}" "${RESTORE_ID}\nn\n" snapshot restore "${RESTORE_ID:0:12}")"
[[ "${output}" == *'Restore can reconnect local checkouts'* &&
   "${output}" == *'Workspace reconnection was deferred'* ]] \
    || fail "declined restore reconnection was not deferred"
machine="$(find "${DECLINED_HOME}/machines" -maxdepth 1 -type f -name '*.json' -print -quit)"
jq -e --arg id "${CURRENT_WORKSPACE_ID}" --arg path "${declined_checkout}" '
    [.workspacePaths[] | select(.workspaceId == $id and .path == $path)] | length == 1
' "${machine}" >/dev/null || fail "declined restore reconnection changed the mapping"

AMBIGUOUS_HOME="${TMP}/ambiguous-reconnect"
prepare_reconnect_case "${AMBIGUOUS_HOME}"
ambiguous_checkout="${RECONNECT_CHECKOUT}"
AMBIGUOUS_ID=99999999-9999-4999-8999-999999999999
staged_registry="${AMBIGUOUS_HOME}/snapshots/restore-fixture/input/workspaces/registry.json"
jq --arg id "${AMBIGUOUS_ID}" \
    '.workspaces += [{id:$id,name:"pi-run",kind:"git",createdAt:"2026-10-08T10:00:00Z"}]' \
    "${staged_registry}" > "${staged_registry}.tmp"
mv "${staged_registry}.tmp" "${staged_registry}"
mkdir -p "${AMBIGUOUS_HOME}/snapshots/restore-fixture/input/profiles/default/sessions/${AMBIGUOUS_ID}"
printf '%s\n' \
    '{"type":"session","id":"99999999-9999-4999-8999-999999999998","timestamp":"2026-10-10T12:00:00Z","cwd":"/workspace","version":3}' \
    > "${AMBIGUOUS_HOME}/snapshots/restore-fixture/input/profiles/default/sessions/${AMBIGUOUS_ID}/restored.jsonl"
output="$(run_pi_tty "${AMBIGUOUS_HOME}" "${RESTORE_ID}\n" snapshot restore "${RESTORE_ID:0:12}")"
[[ "${output}" != *'Restore can reconnect local checkouts'* ]] \
    || fail "ambiguous restored workspaces were offered for automatic reconnection"
machine="$(find "${AMBIGUOUS_HOME}/machines" -maxdepth 1 -type f -name '*.json' -print -quit)"
jq -e --arg id "${CURRENT_WORKSPACE_ID}" --arg path "${ambiguous_checkout}" '
    [.workspacePaths[] | select(.workspaceId == $id and .path == $path)] | length == 1
' "${machine}" >/dev/null || fail "ambiguous restore changed the mapping"

CONFLICT_HOME="${TMP}/session-conflict-reconnect"
prepare_reconnect_case "${CONFLICT_HOME}"
conflict_checkout="${RECONNECT_CHECKOUT}"
mkdir -p "${CONFLICT_HOME}/profiles/default/sessions/${CURRENT_WORKSPACE_ID}"
printf '%s\n' \
    '{"type":"session","id":"55555555-5555-4555-8555-555555555555","timestamp":"2026-10-10T12:00:00Z","cwd":"/workspace","version":3}' \
    > "${CONFLICT_HOME}/profiles/default/sessions/${CURRENT_WORKSPACE_ID}/current.jsonl"
output="$(run_pi_tty "${CONFLICT_HOME}" "${RESTORE_ID}\n" snapshot restore "${RESTORE_ID:0:12}")"
[[ "${output}" != *'Restore can reconnect local checkouts'* ]] \
    || fail "checkout with local session state was offered for reconnection"
machine="$(find "${CONFLICT_HOME}/machines" -maxdepth 1 -type f -name '*.json' -print -quit)"
jq -e --arg id "${CURRENT_WORKSPACE_ID}" --arg path "${conflict_checkout}" '
    [.workspacePaths[] | select(.workspaceId == $id and .path == $path)] | length == 1
' "${machine}" >/dev/null || fail "session conflict changed the mapping"

MISSING_HOME="${TMP}/missing-checkout-reconnect"
prepare_reconnect_case "${MISSING_HOME}"
missing_checkout="${RECONNECT_CHECKOUT}"
rmdir "${missing_checkout}"
output="$(run_pi_tty "${MISSING_HOME}" "${RESTORE_ID}\n" snapshot restore "${RESTORE_ID:0:12}")"
[[ "${output}" != *'Restore can reconnect local checkouts'* ]] \
    || fail "missing checkout was offered for reconnection"
machine="$(find "${MISSING_HOME}/machines" -maxdepth 1 -type f -name '*.json' -print -quit)"
jq -e --arg id "${CURRENT_WORKSPACE_ID}" --arg path "${missing_checkout}" '
    [.workspacePaths[] | select(.workspaceId == $id and .path == $path)] | length == 1
' "${machine}" >/dev/null || fail "missing checkout changed the mapping"

LOCK_HOME="${TMP}/lock-home"
cp -a "${LOCAL_BASE}" "${LOCK_HOME}"
ready="${TMP}/lock-ready"
(
    exec 8<"${LOCK_HOME}"
    flock -s 8
    : > "${ready}"
    sleep 30
) &
LOCK_PID=$!
while [[ ! -e "${ready}" ]]; do sleep 0.02; done
expect_failure run_pi "${LOCK_HOME}" snapshot restore "${RESTORE_ID}"
[[ -z "$(find "${LOCK_HOME}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
    || fail "lock contention created staging state"
kill "${LOCK_PID}" 2>/dev/null || true
wait "${LOCK_PID}" 2>/dev/null || true
LOCK_PID=""

S3_BASE="${TMP}/s3-base"
cp -a "${LOCAL_BASE}" "${S3_BASE}"
rm -rf "${S3_BASE}/snapshots/repository"
printf '%s\n' '{"schemaVersion":1,"backend":"s3","endpoint":"https://ceph.example.test","bucket":"pi-run-backups","prefix":"users/alice","region":"eu-west-1","bucketLookup":"path"}' \
    > "${S3_BASE}/snapshots/config.json"
printf '[default]\naws_access_key_id = ACCESS_123\naws_secret_access_key = SECRET/456+=\n' \
    > "${S3_BASE}/snapshots/s3-credentials"
chmod 0600 "${S3_BASE}/snapshots/config.json" "${S3_BASE}/snapshots/s3-credentials"
create_restore_fixture "${S3_BASE}" s3
MISMATCH_HOME="${TMP}/mismatch"
cp -a "${S3_BASE}" "${MISMATCH_HOME}"
jq '.prefix="users/other"' "${MISMATCH_HOME}/snapshots/restore-fixture/input/snapshot-config.json" \
    > "${MISMATCH_HOME}/snapshots/restore-fixture/input/config.tmp"
mv "${MISMATCH_HOME}/snapshots/restore-fixture/input/config.tmp" \
    "${MISMATCH_HOME}/snapshots/restore-fixture/input/snapshot-config.json"
expect_failure run_pi_tty "${MISMATCH_HOME}" "${RESTORE_ID}\n" snapshot restore "${RESTORE_ID}"
[[ -z "$(find "${MISMATCH_HOME}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
    || fail "configuration mismatch left staging state"

S3_HOME="${TMP}/s3-apply"
cp -a "${S3_BASE}" "${S3_HOME}"
: > "${DOCKER_LOG}"
run_pi_tty "${S3_HOME}" "${RESTORE_ID}\n" snapshot restore "${RESTORE_ID}" >/dev/null
[[ -f "${S3_HOME}/shared/restored.txt" ]] || fail "S3-backed restore was not applied"
for argument in '--network' bridge 'AWS_SHARED_CREDENTIALS_FILE=/s3-credentials' backup; do
    grep -Fx -- "${argument}" "${DOCKER_LOG}" >/dev/null || fail "missing S3 pre-restore backup argument: ${argument}"
done
if grep -E 'ACCESS_123|SECRET/456' "${DOCKER_LOG}" >/dev/null; then fail "S3 credentials leaked into Docker arguments"; fi

for step in $(seq 1 13); do
    CRASH_HOME="${TMP}/crash-${step}"
    cp -a "${LOCAL_BASE}" "${CRASH_HOME}"
    MOVE_COUNT_FILE="${TMP}/move-count-${step}"
    MOVE_FAILED_FILE="${TMP}/move-failed-${step}"
    FAIL_MOVE_AFTER="${step}"
    FAIL_MOVE_MODE='kill'
    expect_failure run_pi_tty "${CRASH_HOME}" "${RESTORE_ID}\n" snapshot restore "${RESTORE_ID}"
    FAIL_MOVE_AFTER=never
    FAIL_MOVE_MODE='error'
    run_pi "${CRASH_HOME}" snapshot status >/dev/null
    [[ -d "${CRASH_HOME}/snapshots/restore-staging/pending" && -f "${CRASH_HOME}/shared/old.txt" &&
       ! -e "${CRASH_HOME}/shared/restored.txt" ]] || fail "crash recovery failed after move ${step}"
    [[ -z "$(find "${CRASH_HOME}/snapshots/restore-staging" -maxdepth 1 -name 'apply-transaction.json' -print -quit)" ]] \
        || fail "crash recovery left a transaction journal after move ${step}"
    run_pi_tty "${CRASH_HOME}" "${RESTORE_ID}\n" snapshot restore "${RESTORE_ID}" >/dev/null
    [[ -f "${CRASH_HOME}/shared/restored.txt" &&
       -z "$(find "${CRASH_HOME}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
        || fail "next restore did not clean recovered staging after move ${step}"
done

ERROR_HOME="${TMP}/error-rollback"
cp -a "${LOCAL_BASE}" "${ERROR_HOME}"
MOVE_COUNT_FILE="${TMP}/error-count"
MOVE_FAILED_FILE="${TMP}/error-failed"
FAIL_MOVE_AFTER=6
FAIL_MOVE_MODE='error'
expect_failure run_pi_tty "${ERROR_HOME}" "${RESTORE_ID}\n" snapshot restore "${RESTORE_ID}"
FAIL_MOVE_AFTER=never
[[ -f "${ERROR_HOME}/shared/old.txt" && ! -e "${ERROR_HOME}/shared/restored.txt" &&
   -z "$(find "${ERROR_HOME}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
    || fail "ordinary apply failure did not roll back and clean staging"

echo "snapshot apply restore tests passed"
