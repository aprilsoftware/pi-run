#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${PI_RUN_TEST_REAL_DOCKER:-0}" != 1 ]]; then
    echo "worktree-e2e-test: SKIP (set PI_RUN_TEST_REAL_DOCKER=1 to use real Docker)"
    exit 0
fi

fail() {
    echo "worktree-e2e-test: $*" >&2
    exit 1
}

for command_name in docker git jq; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "required command unavailable: ${command_name}"
done

VERSION="$(tr -d '\r\n' < "${ROOT}/VERSION")"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "VERSION is invalid"
IMAGE="ghcr.io/aprilsoftware/pi-run:${VERSION}"
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
    || fail "version-matched runtime image is unavailable locally: ${IMAGE}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
REPOSITORY="${TMP}/source repository"

run_pi() {
    PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" "$@"
}

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
git init -q -b main "${REPOSITORY}"
git -C "${REPOSITORY}" config user.name fixture
git -C "${REPOSITORY}" config user.email fixture@pi-run.invalid
printf 'committed base\n' > "${REPOSITORY}/base.txt"
printf 'tracked original\n' > "${REPOSITORY}/tracked.txt"
git -C "${REPOSITORY}" add base.txt tracked.txt
git -C "${REPOSITORY}" commit -qm base
BASE="$(git -C "${REPOSITORY}" rev-parse HEAD)"
printf 'tracked dirty\n' > "${REPOSITORY}/tracked.txt"
printf 'primary only\n' > "${REPOSITORY}/primary-untracked.txt"
SOURCE_STATUS="$(git -C "${REPOSITORY}" status --porcelain=v1)"

MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
REGISTRY="${HOME_DIR}/workspaces/registry.json"

(cd "${REPOSITORY}" && run_pi worktree start task-a -- --version) \
    >"${TMP}/first.out" 2>"${TMP}/first.err"
REPOSITORY_ID="$(jq -r '.repositories[0].id' "${MACHINE}")"
[[ "${REPOSITORY_ID}" =~ ^[0-9a-f-]{36}$ ]] \
    || fail "repository metadata does not contain a UUID"
ID_A="$(jq -r '.repositories[0].tasks[] | select(.name == "task-a") | .workspaceId' "${MACHINE}")"
PATH_A="${HOME_DIR}/worktrees/${REPOSITORY_ID}/${ID_A}"
[[ -d "${PATH_A}" ]] || fail "first default launch did not create its worktree"
[[ -s "${TMP}/first.out" ]] \
    || fail "first real runtime launch produced no Pi version output"
PI_VERSION="$(< "${TMP}/first.out")"
grep -F "managed-worktree workspace-id=${ID_A}" "${TMP}/first.err" >/dev/null \
    || fail "first launch did not report its managed workspace"
grep -F "managed-worktree host=${PATH_A}" "${TMP}/first.err" >/dev/null \
    || fail "first launch did not report its managed path"

(cd "${REPOSITORY}" && run_pi worktree start task-b -- --version) \
    >"${TMP}/second.out" 2>"${TMP}/second.err"
[[ "$(jq -r '.repositories[0].tasks | length' "${MACHINE}")" == 2 ]] \
    || fail "second named task was not created"
ID_B="$(jq -r '.repositories[0].tasks[] | select(.name == "task-b") | .workspaceId' "${MACHINE}")"
PATH_B="${HOME_DIR}/worktrees/${REPOSITORY_ID}/${ID_B}"
[[ "${ID_A}" != "${ID_B}" && -d "${PATH_B}" ]] \
    || fail "managed launches did not receive distinct identities and paths"
[[ "$(< "${TMP}/second.out")" == "${PI_VERSION}" ]] \
    || fail "second real runtime launch reported inconsistent Pi version output"
grep -F "managed-worktree workspace-id=${ID_B}" "${TMP}/second.err" >/dev/null \
    || fail "second launch did not report its managed workspace"

for entry in "task-a:${ID_A}:${PATH_A}" "task-b:${ID_B}:${PATH_B}"; do
    task_name="${entry%%:*}"
    remainder="${entry#*:}"
    workspace_id="${remainder%%:*}"
    workspace_path="${remainder#*:}"
    [[ "$(git -C "${workspace_path}" branch --show-current)" == "pi-run/${task_name}/${workspace_id}" ]] \
        || fail "managed worktree has the wrong branch: ${workspace_id}"
    [[ "$(git -C "${workspace_path}" rev-parse HEAD)" == "${BASE}" ]] \
        || fail "managed worktree has the wrong base: ${workspace_id}"
    [[ "$(< "${workspace_path}/tracked.txt")" == 'tracked original' &&
       ! -e "${workspace_path}/primary-untracked.txt" ]] \
        || fail "managed worktree inherited uncommitted primary state: ${workspace_id}"
    [[ -d "${HOME_DIR}/profiles/default/sessions/${workspace_id}" ]] \
        || fail "managed workspace has no profile session directory: ${workspace_id}"
    grep -Fx "gitdir: ${REPOSITORY}/.git/worktrees/${workspace_id}" \
        "${workspace_path}/.git" >/dev/null \
        || fail "managed worktree did not retain its host Git pointer: ${workspace_id}"
done

[[ "$(git -C "${REPOSITORY}" branch --show-current)" == main &&
   "$(git -C "${REPOSITORY}" status --porcelain=v1)" == "${SOURCE_STATUS}" ]] \
    || fail "managed creation changed the primary checkout"

printf 'workspace A\n' > "${PATH_A}/workspace-a.txt"
git -C "${PATH_A}" add workspace-a.txt
printf 'workspace B\n' > "${PATH_B}/workspace-b.txt"
git -C "${PATH_B}" add workspace-b.txt
[[ "$(git -C "${PATH_A}" diff --cached --name-only)" == workspace-a.txt &&
   "$(git -C "${PATH_B}" diff --cached --name-only)" == workspace-b.txt &&
   ! -e "${PATH_A}/workspace-b.txt" && ! -e "${PATH_B}/workspace-a.txt" ]] \
    || fail "managed worktree files or indexes crossed workspace boundaries"

jq -e --arg a "${ID_A}" --arg b "${ID_B}" '
    .schemaVersion == 3 and
    ([.repositories[0].tasks[].workspaceId] | sort) == ([$a, $b] | sort) and
    ([.repositories[0].tasks[].name] | sort) == ["task-a","task-b"] and
    ([.workspacePaths[].workspaceId | select(. == $a or . == $b)] | length) == 2
' "${MACHINE}" >/dev/null || fail "machine metadata does not contain both named tasks"
jq -e --arg a "${ID_A}" --arg b "${ID_B}" '
    ([.workspaces[] | select((.id == $a or .id == $b) and .kind == "git")] | length) == 2
' "${REGISTRY}" >/dev/null || fail "portable metadata does not contain both managed workspaces"

metadata_before_list="$(sha256sum "${MACHINE}" "${REGISTRY}")"
(
    cd "${TMP}"
    PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree list >"${TMP}/list.out"
)
grep -F "Repository: source repository (${REPOSITORY_ID})" "${TMP}/list.out" >/dev/null \
    || fail "worktree list omitted the repository group"
if grep -F 'Preference:' "${TMP}/list.out" >/dev/null; then
    fail "worktree list reported the obsolete repository preference"
fi
for workspace_id in "${ID_A}" "${ID_B}"; do
    line="$(grep -F "${workspace_id}" "${TMP}/list.out")"
    [[ "${line}" == *available* ]] \
        || fail "worktree list did not report ${workspace_id} as available"
done
[[ "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before_list}" ]] \
    || fail "worktree list changed metadata"

managed_count="$(jq -r '.repositories[0].tasks | length' "${MACHINE}")"
run_pi "${REPOSITORY}" --version >"${TMP}/ordinary.out" 2>"${TMP}/ordinary.err"
[[ "$(< "${TMP}/ordinary.out")" == "${PI_VERSION}" ]] \
    || fail "ordinary direct launch did not execute the same real runtime"
grep -F "profile=default workspace=${REPOSITORY}" "${TMP}/ordinary.err" >/dev/null \
    || fail "ordinary launch did not use the primary checkout"
[[ "$(jq -r '.repositories[0].tasks | length' "${MACHINE}")" == "${managed_count}" ]] \
    || fail "ordinary direct launch created another task"

if [[ -d "${HOME_DIR}/worktrees/.launch-locks" ]] &&
   find "${HOME_DIR}/worktrees/.launch-locks" -mindepth 1 -print -quit | grep -q .; then
    fail "completed launches retained managed workspace locks"
fi
[[ "$(git -C "${REPOSITORY}" worktree list --porcelain | grep -c '^worktree ')" == 3 ]] \
    || fail "final Git state does not retain the primary and two managed worktrees"
jq -e '.repositories[0] | (has("enabled") or has("managedWorkspaces")) | not' \
    "${MACHINE}" >/dev/null || fail "prototype repository fields remain in task metadata"

echo "Managed worktree real-Docker end-to-end test passed"
