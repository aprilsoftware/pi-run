#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/tests/worktree-fixtures.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
ALPHA="${TMP}/alpha repository"
ZETA="${TMP}/zeta repository"
ID_AVAILABLE=11111111-1111-4111-8111-111111111111
ID_MISSING=22222222-2222-4222-8222-222222222222
ID_PENDING=33333333-3333-4333-8333-333333333333
ID_PATH=44444444-4444-4444-8444-444444444444
ID_GIT=55555555-5555-4555-8555-555555555555
ID_UNSAFE=66666666-6666-4666-8666-666666666666

fail() {
    echo "worktree-list-test: $*" >&2
    exit 1
}

initialize_repository() {
    local path="$1"
    git init -q -b main "${path}"
    git -C "${path}" config user.name fixture
    git -C "${path}" config user.email fixture@pi-run.invalid
    printf 'base\n' > "${path}/base.txt"
    git -C "${path}" add base.txt
    git -C "${path}" commit -qm base
}

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
initialize_repository "${ZETA}"
initialize_repository "${ALPHA}"
register_worktree_repository_fixture "${ROOT}" "${HOME_DIR}" "${ZETA}" >/dev/null
register_worktree_repository_fixture "${ROOT}" "${HOME_DIR}" "${ALPHA}" >/dev/null
MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
REGISTRY="${HOME_DIR}/workspaces/registry.json"
ALPHA_COMMON="${ALPHA}/.git"
ALPHA_REPOSITORY_ID="$(jq -r --arg common "${ALPHA_COMMON}" '.repositories[] | select(.commonGitDir == $common) | .id' "${MACHINE}")"
ALPHA_ROOT="${HOME_DIR}/worktrees/${ALPHA_REPOSITORY_ID}"
mkdir -p "${ALPHA_ROOT}"
chmod 0700 "${HOME_DIR}/worktrees" "${ALPHA_ROOT}"

path_for() {
    printf '%s/%s\n' "${ALPHA_ROOT}" "$1"
}
PATH_AVAILABLE="$(path_for "${ID_AVAILABLE}")"
PATH_MISSING="$(path_for "${ID_MISSING}")"
PATH_PENDING="$(path_for "${ID_PENDING}")"
PATH_GIT="$(path_for "${ID_GIT}")"
PATH_UNSAFE="$(path_for "${ID_UNSAFE}")"
PATH_CONFLICT="${TMP}/conflicting path"
UNSAFE_TARGET="${TMP}/unsafe-target"

git -C "${ALPHA}" worktree add -q -b "pi-run/available/${ID_AVAILABLE}" "${PATH_AVAILABLE}" main
git -C "${ALPHA}" worktree add -q -b "pi-run/pending/${ID_PENDING}" "${PATH_PENDING}" main
git -C "${ALPHA}" worktree add -q -b "other/${ID_GIT}" "${PATH_GIT}" main
git -C "${ALPHA}" worktree add -q -b "pi-run/unsafe/${ID_UNSAFE}" "${UNSAFE_TARGET}" main
ln -s "${UNSAFE_TARGET}" "${PATH_UNSAFE}"

jq --arg repository "${ALPHA_REPOSITORY_ID}" \
    --arg available "${ID_AVAILABLE}" --arg availablePath "${PATH_AVAILABLE}" \
    --arg missing "${ID_MISSING}" --arg missingPath "${PATH_MISSING}" \
    --arg pending "${ID_PENDING}" --arg pendingPath "${PATH_PENDING}" \
    --arg conflict "${ID_PATH}" --arg conflictPath "${PATH_CONFLICT}" \
    --arg git "${ID_GIT}" --arg gitPath "${PATH_GIT}" \
    --arg unsafe "${ID_UNSAFE}" --arg unsafePath "${PATH_UNSAFE}" '
    .workspacePaths += [
        {workspaceId:$available,path:$availablePath},
        {workspaceId:$missing,path:$missingPath},
        {workspaceId:$pending,path:$pendingPath},
        {workspaceId:$conflict,path:$conflictPath},
        {workspaceId:$git,path:$gitPath},
        {workspaceId:$unsafe,path:$unsafePath}
    ] |
    (.repositories[] | select(.id == $repository) | .tasks) += [
        {name:"unsafe",workspaceId:$unsafe,branch:("pi-run/unsafe/" + $unsafe),state:"active",createdAt:"2026-10-20T12:00:06Z",finishedAt:null},
        {name:"git-conflict",workspaceId:$git,branch:("pi-run/git-conflict/" + $git),state:"active",createdAt:"2026-10-20T12:00:05Z",finishedAt:null},
        {name:"path-conflict",workspaceId:$conflict,branch:("pi-run/path-conflict/" + $conflict),state:"active",createdAt:"2026-10-20T12:00:04Z",finishedAt:null},
        {name:"pending",workspaceId:$pending,branch:("pi-run/pending/" + $pending),state:"active",createdAt:"2026-10-20T12:00:03Z",finishedAt:null},
        {name:"missing",workspaceId:$missing,branch:("pi-run/missing/" + $missing),state:"active",createdAt:"2026-10-20T12:00:02Z",finishedAt:null},
        {name:"available",workspaceId:$available,branch:("pi-run/available/" + $available),state:"active",createdAt:"2026-10-20T12:00:01Z",finishedAt:null}
    ]
' "${MACHINE}" > "${MACHINE}.tmp"
mv "${MACHINE}.tmp" "${MACHINE}"
chmod 0600 "${MACHINE}"

jq --arg available "${ID_AVAILABLE}" --arg missing "${ID_MISSING}" \
    --arg conflict "${ID_PATH}" --arg git "${ID_GIT}" --arg unsafe "${ID_UNSAFE}" '
    .workspaces += [
        {id:$available,name:"alpha repository",kind:"git",createdAt:"2026-10-20T12:00:01Z"},
        {id:$missing,name:"alpha repository",kind:"git",createdAt:"2026-10-20T12:00:02Z"},
        {id:$conflict,name:"alpha repository",kind:"git",createdAt:"2026-10-20T12:00:04Z"},
        {id:$git,name:"alpha repository",kind:"git",createdAt:"2026-10-20T12:00:05Z"},
        {id:$unsafe,name:"alpha repository",kind:"git",createdAt:"2026-10-20T12:00:06Z"}
    ]
' "${REGISTRY}" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "${REGISTRY}"
chmod 0600 "${REGISTRY}"

metadata_before="$(sha256sum "${MACHINE}" "${REGISTRY}")"
git_before="$({ git -C "${ALPHA}" worktree list --porcelain; git -C "${ALPHA}" show-ref; } | sha256sum)"
output="$(cd "${TMP}" && PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree list)"
output_again="$(cd "${TMP}" && PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree list)"
[[ "${output}" == "${output_again}" ]] || fail "worktree listing was not deterministic"
for expected in \
    "available|${ID_AVAILABLE}|pi-run/available/${ID_AVAILABLE}|available" \
    "missing|${ID_MISSING}|pi-run/missing/${ID_MISSING}|missing" \
    "pending|${ID_PENDING}|pi-run/pending/${ID_PENDING}|pending" \
    "path-conflict|${ID_PATH}|pi-run/path-conflict/${ID_PATH}|path-conflict" \
    "git-conflict|${ID_GIT}|pi-run/git-conflict/${ID_GIT}|git-conflict" \
    "unsafe|${ID_UNSAFE}|pi-run/unsafe/${ID_UNSAFE}|unsafe"; do
    IFS='|' read -r task id branch status <<< "${expected}"
    line="$(grep -F "${id}" <<< "${output}")"
    [[ "${line}" == *"${task}"* && "${line}" == *"${branch}"* && "${line}" == *"${status}"* ]] \
        || fail "listing omitted task status row: ${expected}"
done
alpha_line="$(grep -n '^Repository: alpha repository ' <<< "${output}" | cut -d: -f1)"
zeta_line="$(grep -n '^Repository: zeta repository ' <<< "${output}" | cut -d: -f1)"
(( alpha_line < zeta_line )) || fail "repositories were not sorted by name"
if grep -F 'Preference:' <<< "${output}" >/dev/null; then
    fail "obsolete repository preference was listed"
fi
grep -A2 '^Repository: zeta repository ' <<< "${output}" | grep -Fx 'Tasks: none' >/dev/null \
    || fail "empty repository group was not listed"
[[ "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before}" &&
   "$({ git -C "${ALPHA}" worktree list --porcelain; git -C "${ALPHA}" show-ref; } | sha256sum)" == "${git_before}" &&
   ! -e "${HOME_DIR}/worktrees/.launch-locks" ]] \
    || fail "worktree listing changed metadata, Git state, or locks"

chmod 0644 "${MACHINE}"
if PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree list >/dev/null 2>"${TMP}/unsafe-machine.err"; then
    fail "worktree listing accepted unsafe machine metadata"
fi
grep -F 'permissions must be 600' "${TMP}/unsafe-machine.err" >/dev/null \
    || fail "unsafe-machine diagnostic was unclear"
chmod 0600 "${MACHINE}"

LEGACY_HOME="${TMP}/Legacy Home"
PI_RUN_HOME="${LEGACY_HOME}" "${ROOT}/bin/pi-run" init >/dev/null
PI_RUN_HOME="${LEGACY_HOME}" "${ROOT}/bin/pi-run" workspace list >/dev/null
LEGACY_MACHINE="${LEGACY_HOME}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
legacy_hash="$(sha256sum "${LEGACY_MACHINE}")"
legacy_inode="$(stat -c %i "${LEGACY_MACHINE}")"
legacy_output="$(PI_RUN_HOME="${LEGACY_HOME}" "${ROOT}/bin/pi-run" worktree list)"
[[ "${legacy_output}" == 'No managed repositories registered.' ]] \
    || fail "schema-v1 listing did not report an empty managed inventory"
[[ "$(sha256sum "${LEGACY_MACHINE}")" == "${legacy_hash}" &&
   "$(stat -c %i "${LEGACY_MACHINE}")" == "${legacy_inode}" ]] \
    || fail "schema-v1 listing migrated or rewrote machine metadata"

echo "Managed worktree listing tests passed"
