#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
WORKSPACE_ID=11111111-1111-4111-8111-111111111111
REPOSITORY_ID=22222222-2222-4222-8222-222222222222
REPOSITORY_ID_B=33333333-3333-4333-8333-333333333333

fail() {
    echo "worktree-metadata-test: $*" >&2
    exit 1
}

run_ensure() {
    local home="$1"
    PI_RUN_TEST_ROOT="${ROOT}" PI_RUN_TEST_HOME="${home}" bash -ceu '
        fail() { echo "pi-run: $*" >&2; exit 1; }
        source "${PI_RUN_TEST_ROOT}/lib/pi-run/workspaces.sh"
        PI_RUN_HOME_RESOLVED="${PI_RUN_TEST_HOME}"
        ensure_worktree_machine_metadata
    '
}

expect_unchanged_failure() {
    local home="$1" machine="$2" before status
    before="$(sha256sum "${machine}")"
    set +e
    run_ensure "${home}" >/dev/null 2>&1
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "unsafe machine metadata was accepted: ${home}"
    [[ "$(sha256sum "${machine}")" == "${before}" ]] \
        || fail "failed migration changed machine metadata: ${home}"
}

prepare_v1_home() {
    local name="$1" machine_name machine_id_value
    CASE_HOME="${TMP}/${name}/Pi Run"
    PI_RUN_HOME="${CASE_HOME}" "${ROOT}/bin/pi-run" init >/dev/null
    CASE_MACHINE="${CASE_HOME}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
    jq --arg id "${WORKSPACE_ID}" \
        '.workspaces += [{id:$id,name:"fixture",kind:"git",createdAt:"2026-10-20T12:00:00Z"}]' \
        "${CASE_HOME}/workspaces/registry.json" > "${CASE_HOME}/workspaces/registry.json.tmp"
    mv "${CASE_HOME}/workspaces/registry.json.tmp" "${CASE_HOME}/workspaces/registry.json"
    chmod 0600 "${CASE_HOME}/workspaces/registry.json"
    machine_name="${CASE_MACHINE##*/}"
    machine_id_value="${machine_name%.json}"
    jq -n --arg machine "${machine_id_value}" --arg id "${WORKSPACE_ID}" \
        '{schemaVersion:1,machineId:$machine,workspacePaths:[{workspaceId:$id,path:"/tmp/worktree metadata fixture"}]}' \
        > "${CASE_MACHINE}"
    chmod 0600 "${CASE_MACHINE}"
}

prepare_v1_home migration
mapping_before="$(jq -c '.workspacePaths' "${CASE_MACHINE}")"
inode_before="$(stat -c %i "${CASE_MACHINE}")"
PI_RUN_HOME="${CASE_HOME}" "${ROOT}/bin/pi-run" workspace list >/dev/null
[[ "$(jq -r '.schemaVersion' "${CASE_MACHINE}")" == 1 ]] \
    || fail "ordinary workspace command migrated machine metadata"
[[ "$(run_ensure "${CASE_HOME}")" == "${CASE_MACHINE}" ]] \
    || fail "migration returned the wrong machine file"
[[ "$(stat -c %i "${CASE_MACHINE}")" != "${inode_before}" ]] \
    || fail "migration did not atomically replace the machine file"
jq -e --argjson paths "${mapping_before}" '
    .schemaVersion == 3 and .workspacePaths == $paths and .repositories == [] and
    (keys | sort == ["machineId","repositories","schemaVersion","workspacePaths"])
' "${CASE_MACHINE}" >/dev/null || fail "v1 migration did not preserve the selected state"
[[ "$(stat -c %a "${CASE_MACHINE}")" == 600 ]] || fail "migration published unsafe permissions"
PI_RUN_HOME="${CASE_HOME}" "${ROOT}/bin/pi-run" workspace list >/dev/null
inode_before="$(stat -c %i "${CASE_MACHINE}")"
run_ensure "${CASE_HOME}" >/dev/null
[[ "$(stat -c %i "${CASE_MACHINE}")" == "${inode_before}" ]] \
    || fail "valid v3 metadata was rewritten"

prepare_v1_home snapshot-auto
jq '.snapshotAuto={onSessionExit:true}' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
run_ensure "${CASE_HOME}" >/dev/null
jq -e '
    .schemaVersion == 3 and .snapshotAuto.onSessionExit == true and
    .repositories == [] and
    (keys | sort == ["machineId","repositories","schemaVersion","snapshotAuto","workspacePaths"])
' "${CASE_MACHINE}" >/dev/null \
    || fail "v1 migration did not preserve automatic snapshot configuration"
[[ "$(PI_RUN_HOME="${CASE_HOME}" "${ROOT}/bin/pi-run" snapshot auto status)" == \
   'Automatic snapshots on successful Pi exit: enabled' ]] \
    || fail "automatic snapshot status failed after worktree metadata migration"

prepare_v1_home invalid-snapshot-auto
jq '.snapshotAuto={onSessionExit:"yes"}' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v1_home unsafe-mode
chmod 0644 "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v1_home hard-link
ln "${CASE_MACHINE}" "${CASE_MACHINE}.other"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v1_home wrong-machine
jq '.machineId="0000000000000000"' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v1_home extra-key
jq '.unexpected=true' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v1_home symlink
outside="${TMP}/outside-machine.json"
mv "${CASE_MACHINE}" "${outside}"
ln -s "${outside}" "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v1_home withdrawn-v2
jq '.schemaVersion=2 | .repositories=[]' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
before="$(sha256sum "${CASE_MACHINE}")"
if run_ensure "${CASE_HOME}" >/dev/null 2>"${TMP}/withdrawn-v2.err"; then
    fail "withdrawn schema-v2 metadata was accepted"
fi
grep -F 'withdrawn v0.8 worktree metadata requires cleanup' "${TMP}/withdrawn-v2.err" >/dev/null \
    || fail "withdrawn schema-v2 metadata did not report cleanup requirement"
[[ "$(sha256sum "${CASE_MACHINE}")" == "${before}" ]] \
    || fail "withdrawn schema-v2 refusal changed machine metadata"

write_valid_lifecycle_case() {
    local name="$1" mutation="$2"
    prepare_v1_home "${name}"
    jq --arg repository "${REPOSITORY_ID}" --arg workspace "${WORKSPACE_ID}" '
        .schemaVersion=3 | .repositories=[{
            id:$repository,name:"fixture",commonGitDir:"/tmp/repository/.git",
            primaryPath:"/tmp/repository",createdAt:"2026-10-20T12:00:00Z",
            tasks:[{name:"fixture",workspaceId:$workspace,
                branch:("pi-run/fixture/" + $workspace),state:"active",
                createdAt:"2026-10-20T12:01:00Z",finishedAt:null}]
        }]
    ' "${CASE_MACHINE}" | jq "${mutation}" > "${CASE_MACHINE}.tmp"
    mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
    chmod 0600 "${CASE_MACHINE}"
    run_ensure "${CASE_HOME}" >/dev/null
}

write_valid_lifecycle_case valid-finishing '.repositories[0].tasks[0].state="finishing"'
write_valid_lifecycle_case valid-finished '
    .repositories[0].tasks[0].state="finished" |
    .repositories[0].tasks[0].finishedAt="2026-10-20T13:00:00Z" |
    .workspacePaths=[]
'

write_v3_case() {
    local name="$1" mutation="$2"
    prepare_v1_home "${name}"
    jq --arg repository "${REPOSITORY_ID}" --arg workspace "${WORKSPACE_ID}" '
        .schemaVersion=3 | .repositories=[{
            id:$repository,name:"fixture",commonGitDir:"/tmp/repository/.git",
            primaryPath:"/tmp/repository",createdAt:"2026-10-20T12:00:00Z",
            tasks:[{name:"fixture",workspaceId:$workspace,
                branch:("pi-run/fixture/" + $workspace),state:"active",
                createdAt:"2026-10-20T12:01:00Z",finishedAt:null}]
        }]
    ' "${CASE_MACHINE}" | jq --arg repositoryB "${REPOSITORY_ID_B}" "${mutation}" > "${CASE_MACHINE}.tmp"
    mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
    chmod 0600 "${CASE_MACHINE}"
    expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"
}

write_v3_case duplicate-repository-id \
    '.repositories += [(.repositories[0] | .commonGitDir="/tmp/other/.git" | .primaryPath="/tmp/other" | .tasks=[])]'
# shellcheck disable=SC2016 # $repositoryB is a jq variable.
write_v3_case duplicate-common-directory \
    '.repositories += [(.repositories[0] | .id=$repositoryB | .primaryPath="/tmp/other" | .tasks=[])]'
# shellcheck disable=SC2016 # $repositoryB is a jq variable.
write_v3_case duplicate-task-workspace \
    '.repositories += [(.repositories[0] | .id=$repositoryB | .commonGitDir="/tmp/other/.git" | .primaryPath="/tmp/other")]'
write_v3_case duplicate-task-name \
    '.repositories[0].tasks += [(.repositories[0].tasks[0] | .workspaceId="44444444-4444-4444-8444-444444444444" | .branch="pi-run/fixture/44444444-4444-4444-8444-444444444444")]'
write_v3_case active-without-path '.workspacePaths=[]'
write_v3_case finishing-without-path '.repositories[0].tasks[0].state="finishing" | .workspacePaths=[]'
write_v3_case finished-with-path \
    '.repositories[0].tasks[0].state="finished" | .repositories[0].tasks[0].finishedAt="2026-10-20T13:00:00Z"'
write_v3_case finished-without-timestamp \
    '.repositories[0].tasks[0].state="finished" | .workspacePaths=[]'

echo "Worktree metadata tests passed"
