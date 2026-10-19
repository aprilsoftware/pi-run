#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
REPOSITORY="${TMP}/repository"
ID_A=11111111-1111-4111-8111-111111111111
ID_PENDING=22222222-2222-4222-8222-222222222222
ID_REGISTRY=33333333-3333-4333-8333-333333333333
ID_BRANCH=44444444-4444-4444-8444-444444444444
ID_MISSING=55555555-5555-4555-8555-555555555555
ID_INCOMPLETE=66666666-6666-4666-8666-666666666666
PENDING_TIME=2026-10-20T12:00:00Z

fail() {
    echo "worktree-publication-test: $*" >&2
    exit 1
}

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
git init -q -b main "${REPOSITORY}"
git -C "${REPOSITORY}" config user.name fixture
git -C "${REPOSITORY}" config user.email fixture@pi-run.invalid
printf 'base\n' > "${REPOSITORY}/base.txt"
git -C "${REPOSITORY}" add base.txt
git -C "${REPOSITORY}" commit -qm base
(
    cd "${REPOSITORY}"
    PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree enable >/dev/null
)
MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
REGISTRY="${HOME_DIR}/workspaces/registry.json"
REPOSITORY_ID="$(jq -r '.repositories[0].id' "${MACHINE}")"
WORKTREE_ROOT="${HOME_DIR}/worktrees/${REPOSITORY_ID}"
mkdir -p "${WORKTREE_ROOT}"
chmod 0700 "${HOME_DIR}/worktrees" "${WORKTREE_ROOT}"

worktree_path() {
    printf '%s/%s\n' "${WORKTREE_ROOT}" "$1"
}

create_worktree() {
    local id="$1" branch="${2:-pi-run/$1}" path
    path="$(worktree_path "${id}")"
    git -C "${REPOSITORY}" worktree add -q -b "${branch}" "${path}" main
}

remove_worktree() {
    local id="$1" branch="${2:-pi-run/$1}" path
    path="$(worktree_path "${id}")"
    git -C "${REPOSITORY}" worktree remove --force "${path}" >/dev/null 2>&1 || true
    git -C "${REPOSITORY}" branch -D "${branch}" >/dev/null 2>&1 || true
}

publish() {
    local id="$1" path="${2:-$(worktree_path "$1")}" branch="${3:-pi-run/$1}"
    TEST_ROOT="${ROOT}" TEST_HOME="${HOME_DIR}" TEST_ID="${id}" \
        TEST_REPOSITORY_ID="${REPOSITORY_ID}" TEST_BRANCH="${branch}" TEST_PATH="${path}" \
        bash -ceu '
            fail() { echo "pi-run: $*" >&2; exit 1; }
            PI_RUN_HOME_RESOLVED="${TEST_HOME}"
            source "${TEST_ROOT}/lib/pi-run/workspaces.sh"
            publish_managed_worktree_metadata \
                "${TEST_ID}" "${TEST_REPOSITORY_ID}" "${TEST_BRANCH}" "${TEST_PATH}"
        '
}

git_state() {
    {
        git -C "${REPOSITORY}" worktree list --porcelain
        git -C "${REPOSITORY}" show-ref
        git -c core.fsmonitor=false -C "${REPOSITORY}" status --porcelain
        for path in "${WORKTREE_ROOT}"/*; do
            [[ -d "${path}" ]] || continue
            git -c core.fsmonitor=false -C "${path}" status --porcelain
        done
    } | sha256sum
}

create_worktree "${ID_A}"
git_before="$(git_state)"
[[ "$(publish "${ID_A}")" == "${ID_A}" ]] || fail "publication returned the wrong workspace identity"
[[ "$(git_state)" == "${git_before}" ]] || fail "publication changed Git state"
PATH_A="$(worktree_path "${ID_A}")"
jq -e --arg id "${ID_A}" --arg path "${PATH_A}" --arg repository "${REPOSITORY_ID}" '
    ([.workspacePaths[] | select(.workspaceId == $id and .path == $path)] | length) == 1 and
    ([.repositories[] | select(.id == $repository) | .managedWorkspaces[] |
        select(.workspaceId == $id and .branch == ("pi-run/" + $id))] | length) == 1
' "${MACHINE}" >/dev/null || fail "machine metadata was not published together"
created="$(jq -r --arg id "${ID_A}" '.repositories[].managedWorkspaces[] | select(.workspaceId == $id) | .createdAt' "${MACHINE}")"
jq -e --arg id "${ID_A}" --arg name "$(basename "${REPOSITORY}")" --arg created "${created}" '
    [.workspaces[] | select(.id == $id)] | .[0] ==
        {id:$id,name:$name,kind:"git",createdAt:$created}
' "${REGISTRY}" >/dev/null || fail "portable metadata does not match the machine association"

machine_inode="$(stat -c %i "${MACHINE}")"
registry_inode="$(stat -c %i "${REGISTRY}")"
publish "${ID_A}" >/dev/null
[[ "$(stat -c %i "${MACHINE}")" == "${machine_inode}" &&
   "$(stat -c %i "${REGISTRY}")" == "${registry_inode}" ]] \
    || fail "idempotent publication rewrote metadata"

create_worktree "${ID_PENDING}"
PATH_PENDING="$(worktree_path "${ID_PENDING}")"
jq --arg id "${ID_PENDING}" --arg path "${PATH_PENDING}" --arg repository "${REPOSITORY_ID}" \
    --arg created "${PENDING_TIME}" '
    .workspacePaths += [{workspaceId:$id,path:$path}] |
    (.repositories[] | select(.id == $repository) | .managedWorkspaces) +=
        [{workspaceId:$id,branch:("pi-run/" + $id),createdAt:$created}]
' "${MACHINE}" > "${MACHINE}.tmp"
mv "${MACHINE}.tmp" "${MACHINE}"
chmod 0600 "${MACHINE}"
publish "${ID_PENDING}" >/dev/null
jq -e --arg id "${ID_PENDING}" --arg created "${PENDING_TIME}" '
    [.workspaces[] | select(.id == $id and .createdAt == $created and .kind == "git")] | length == 1
' "${REGISTRY}" >/dev/null || fail "machine-only pending publication was not recovered"
jq --arg id "${ID_PENDING}" '(.workspaces[] | select(.id == $id) | .name) = "conflict"' \
    "${REGISTRY}" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "${REGISTRY}"
chmod 0600 "${REGISTRY}"
if publish "${ID_PENDING}" >/dev/null 2>"${TMP}/conflict.err"; then
    fail "conflicting portable metadata was accepted"
fi
grep -F 'conflicts with the managed machine association' "${TMP}/conflict.err" >/dev/null \
    || fail "portable-conflict diagnostic was unclear"
jq --arg id "${ID_PENDING}" --arg name "$(basename "${REPOSITORY}")" \
    '(.workspaces[] | select(.id == $id) | .name) = $name' "${REGISTRY}" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "${REGISTRY}"
chmod 0600 "${REGISTRY}"

create_worktree "${ID_REGISTRY}"
jq --arg id "${ID_REGISTRY}" '
    .workspaces += [{id:$id,name:"repository",kind:"git",createdAt:"2026-10-20T12:00:00Z"}]
' "${REGISTRY}" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "${REGISTRY}"
chmod 0600 "${REGISTRY}"
machine_before="$(sha256sum "${MACHINE}")"
if publish "${ID_REGISTRY}" >/dev/null 2>"${TMP}/registry-only.err"; then
    fail "registry-only metadata was accepted"
fi
[[ "$(sha256sum "${MACHINE}")" == "${machine_before}" ]] \
    || fail "registry-only rejection changed machine metadata"
grep -F 'without a managed machine association' "${TMP}/registry-only.err" >/dev/null \
    || fail "registry-only diagnostic was unclear"
jq --arg id "${ID_REGISTRY}" '.workspaces |= map(select(.id != $id))' "${REGISTRY}" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "${REGISTRY}"
chmod 0600 "${REGISTRY}"
remove_worktree "${ID_REGISTRY}"

create_worktree "${ID_BRANCH}" "other/${ID_BRANCH}"
if publish "${ID_BRANCH}" >/dev/null 2>"${TMP}/branch.err"; then
    fail "wrong worktree branch was accepted"
fi
grep -F 'Git relationship does not match' "${TMP}/branch.err" >/dev/null \
    || fail "wrong-branch diagnostic was unclear"
remove_worktree "${ID_BRANCH}" "other/${ID_BRANCH}"

if publish "${ID_MISSING}" >/dev/null 2>"${TMP}/missing.err"; then
    fail "missing worktree was accepted"
fi
grep -F 'checkout is missing or unsafe' "${TMP}/missing.err" >/dev/null \
    || fail "missing-worktree diagnostic was unclear"
if publish "${ID_MISSING}" "${TMP}/moved" >/dev/null 2>"${TMP}/moved.err"; then
    fail "mismatched managed path was accepted"
fi
grep -F 'path does not match its workspace identity' "${TMP}/moved.err" >/dev/null \
    || fail "mismatched-path diagnostic was unclear"

create_worktree "${ID_INCOMPLETE}"
PATH_INCOMPLETE="$(worktree_path "${ID_INCOMPLETE}")"
jq --arg id "${ID_INCOMPLETE}" --arg path "${PATH_INCOMPLETE}" \
    '.workspacePaths += [{workspaceId:$id,path:$path}]' "${MACHINE}" > "${MACHINE}.tmp"
mv "${MACHINE}.tmp" "${MACHINE}"
chmod 0600 "${MACHINE}"
registry_before="$(sha256sum "${REGISTRY}")"
if publish "${ID_INCOMPLETE}" >/dev/null 2>"${TMP}/incomplete.err"; then
    fail "incomplete machine metadata was accepted"
fi
[[ "$(sha256sum "${REGISTRY}")" == "${registry_before}" ]] \
    || fail "incomplete machine metadata changed the portable registry"
grep -F 'incomplete or ambiguous' "${TMP}/incomplete.err" >/dev/null \
    || fail "incomplete-machine diagnostic was unclear"

remove_worktree "${ID_A}"
remove_worktree "${ID_PENDING}"
remove_worktree "${ID_INCOMPLETE}"
echo "Managed worktree publication tests passed"
