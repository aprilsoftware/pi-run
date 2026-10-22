#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
WORKSPACE_ID=11111111-1111-4111-8111-111111111111
REPOSITORY_ID=22222222-2222-4222-8222-222222222222
REPOSITORY_ID_B=33333333-3333-4333-8333-333333333333
WORKSPACE_ID_B=44444444-4444-4444-8444-444444444444

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
        || fail "failed initialization changed machine metadata: ${home}"
}

prepare_v07_home() {
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
        '{schemaVersion:1,machineId:$machine,workspacePaths:[{workspaceId:$id,path:"/tmp/worktree metadata fixture ü"}]}' \
        > "${CASE_MACHINE}"
    chmod 0600 "${CASE_MACHINE}"
}

prepare_v07_home initialization
jq '.snapshotAuto={onSessionExit:true}' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
session_dir="${CASE_HOME}/profiles/default/sessions/${WORKSPACE_ID}"
mkdir -p "${session_dir}"
printf '{"type":"session","id":"preserved"}\n' > "${session_dir}/preserved.jsonl"
registry_before="$(sha256sum "${CASE_HOME}/workspaces/registry.json")"
profile_before="$(sha256sum "${CASE_HOME}/profiles/default/profile.json")"
session_before="$(sha256sum "${session_dir}/preserved.jsonl")"
mapping_before="$(jq -c '.workspacePaths' "${CASE_MACHINE}")"
inode_before="$(stat -c %i "${CASE_MACHINE}")"
PI_RUN_HOME="${CASE_HOME}" "${ROOT}/bin/pi-run" workspace list >/dev/null
[[ "$(jq -r 'has("repositories")' "${CASE_MACHINE}")" == false ]] \
    || fail "ordinary workspace command initialized managed metadata"
[[ "$(run_ensure "${CASE_HOME}")" == "${CASE_MACHINE}" ]] \
    || fail "initialization returned the wrong machine file"
[[ "$(stat -c %i "${CASE_MACHINE}")" != "${inode_before}" ]] \
    || fail "initialization did not atomically replace the machine file"
jq -e --argjson paths "${mapping_before}" '
    .schemaVersion == 1 and .workspacePaths == $paths and .repositories == [] and
    .snapshotAuto.onSessionExit == true and
    (keys | sort == ["machineId","repositories","schemaVersion","snapshotAuto","workspacePaths"])
' "${CASE_MACHINE}" >/dev/null \
    || fail "v0.7 metadata initialization did not preserve machine state"
[[ "$(sha256sum "${CASE_HOME}/workspaces/registry.json")" == "${registry_before}" ]] \
    || fail "managed metadata initialization changed the v0.7 workspace registry"
[[ "$(sha256sum "${CASE_HOME}/profiles/default/profile.json")" == "${profile_before}" ]] \
    || fail "managed metadata initialization changed the v0.7 profile"
[[ "$(sha256sum "${session_dir}/preserved.jsonl")" == "${session_before}" ]] \
    || fail "managed metadata initialization changed the v0.7 session"
[[ "$(stat -c %a "${CASE_MACHINE}")" == 600 ]] \
    || fail "initialization published unsafe permissions"
[[ "$(PI_RUN_HOME="${CASE_HOME}" "${ROOT}/bin/pi-run" snapshot auto status)" == \
   'Automatic snapshots on successful Pi exit: enabled' ]] \
    || fail "automatic snapshot status failed after managed metadata initialization"
PI_RUN_HOME="${CASE_HOME}" "${ROOT}/bin/pi-run" workspace list >/dev/null
inode_before="$(stat -c %i "${CASE_MACHINE}")"
run_ensure "${CASE_HOME}" >/dev/null
[[ "$(stat -c %i "${CASE_MACHINE}")" == "${inode_before}" ]] \
    || fail "valid schema-v1 metadata was rewritten"

prepare_v07_home invalid-snapshot-auto
jq '.snapshotAuto={onSessionExit:"yes"}' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v07_home unsafe-mode
chmod 0644 "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v07_home hard-link
ln "${CASE_MACHINE}" "${CASE_MACHINE}.other"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v07_home wrong-machine
jq '.machineId="0000000000000000"' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v07_home extra-key
jq '.unexpected=true' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v07_home symlink
outside="${TMP}/outside-machine.json"
mv "${CASE_MACHINE}" "${outside}"
ln -s "${outside}" "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v07_home unsupported-schema
jq '.schemaVersion=99' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

prepare_v07_home null-repositories
jq '.repositories=null' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"

write_valid_lifecycle_case() {
    local name="$1" mutation="$2"
    prepare_v07_home "${name}"
    jq --arg repository "${REPOSITORY_ID}" --arg workspace "${WORKSPACE_ID}" '
        .repositories=[{
            id:$repository,name:"fixture",commonGitDir:"/tmp/repository/.git",
            primaryPath:"/tmp/repository",createdAt:"2026-10-20T12:00:00Z",
            tasks:[{name:"fixture",workspaceId:$workspace,
                branch:"pi-run/fixture",state:"active",
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

prepare_v07_home same-name-separate-repositories
jq --arg repositoryA "${REPOSITORY_ID}" --arg repositoryB "${REPOSITORY_ID_B}" \
    --arg workspaceA "${WORKSPACE_ID}" --arg workspaceB "${WORKSPACE_ID_B}" '
    .workspacePaths += [{workspaceId:$workspaceB,path:"/tmp/other-task"}] |
    .repositories=[
        {id:$repositoryA,name:"one",commonGitDir:"/tmp/one/.git",primaryPath:"/tmp/one",
         createdAt:"2026-10-20T12:00:00Z",tasks:[{name:"fixture",workspaceId:$workspaceA,
         branch:"pi-run/fixture",state:"active",createdAt:"2026-10-20T12:01:00Z",finishedAt:null}]},
        {id:$repositoryB,name:"two",commonGitDir:"/tmp/two/.git",primaryPath:"/tmp/two",
         createdAt:"2026-10-20T12:00:00Z",tasks:[{name:"fixture",workspaceId:$workspaceB,
         branch:"pi-run/fixture",state:"active",createdAt:"2026-10-20T12:01:00Z",finishedAt:null}]}
    ]
' "${CASE_MACHINE}" > "${CASE_MACHINE}.tmp"
mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
chmod 0600 "${CASE_MACHINE}"
run_ensure "${CASE_HOME}" >/dev/null \
    || fail "same task name in separate repositories was rejected"

write_task_case() {
    local name="$1" mutation="$2"
    prepare_v07_home "${name}"
    jq --arg repository "${REPOSITORY_ID}" --arg workspace "${WORKSPACE_ID}" '
        .repositories=[{
            id:$repository,name:"fixture",commonGitDir:"/tmp/repository/.git",
            primaryPath:"/tmp/repository",createdAt:"2026-10-20T12:00:00Z",
            tasks:[{name:"fixture",workspaceId:$workspace,
                branch:"pi-run/fixture",state:"active",
                createdAt:"2026-10-20T12:01:00Z",finishedAt:null}]
        }]
    ' "${CASE_MACHINE}" | jq --arg repositoryB "${REPOSITORY_ID_B}" "${mutation}" > "${CASE_MACHINE}.tmp"
    mv "${CASE_MACHINE}.tmp" "${CASE_MACHINE}"
    chmod 0600 "${CASE_MACHINE}"
    expect_unchanged_failure "${CASE_HOME}" "${CASE_MACHINE}"
}

write_task_case duplicate-repository-id \
    '.repositories += [(.repositories[0] | .commonGitDir="/tmp/other/.git" | .primaryPath="/tmp/other" | .tasks=[])]'
# shellcheck disable=SC2016 # $repositoryB is a jq variable.
write_task_case duplicate-common-directory \
    '.repositories += [(.repositories[0] | .id=$repositoryB | .primaryPath="/tmp/other" | .tasks=[])]'
# shellcheck disable=SC2016 # $repositoryB is a jq variable.
write_task_case duplicate-task-workspace \
    '.repositories += [(.repositories[0] | .id=$repositoryB | .commonGitDir="/tmp/other/.git" | .primaryPath="/tmp/other")]'
write_task_case duplicate-task-name \
    '.repositories[0].tasks += [(.repositories[0].tasks[0] | .workspaceId="44444444-4444-4444-8444-444444444444")]'
write_task_case active-without-path '.workspacePaths=[]'
write_task_case finishing-without-path '.repositories[0].tasks[0].state="finishing" | .workspacePaths=[]'
write_task_case finished-with-path \
    '.repositories[0].tasks[0].state="finished" | .repositories[0].tasks[0].finishedAt="2026-10-20T13:00:00Z"'
write_task_case finished-without-timestamp \
    '.repositories[0].tasks[0].state="finished" | .workspacePaths=[]'

echo "Worktree metadata tests passed"
