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

(
    cd "${REPOSITORY}"
    PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree enable >"${TMP}/enable.out"
)
grep -F 'Worktree mode: enabled' "${TMP}/enable.out" >/dev/null \
    || fail "worktree enable did not report the enabled preference"

MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
REGISTRY="${HOME_DIR}/workspaces/registry.json"
REPOSITORY_ID="$(jq -r '.repositories[0].id' "${MACHINE}")"
[[ "${REPOSITORY_ID}" =~ ^[0-9a-f-]{36}$ ]] \
    || fail "repository metadata does not contain a UUID"

run_pi "${REPOSITORY}" --version >"${TMP}/first.out" 2>"${TMP}/first.err"
ID_A="$(jq -r '.repositories[0].managedWorkspaces[0].workspaceId' "${MACHINE}")"
PATH_A="${HOME_DIR}/worktrees/${REPOSITORY_ID}/${ID_A}"
[[ -d "${PATH_A}" ]] || fail "first default launch did not create its worktree"
[[ -s "${TMP}/first.out" ]] \
    || fail "first real runtime launch produced no Pi version output"
PI_VERSION="$(< "${TMP}/first.out")"
grep -F "managed-worktree workspace-id=${ID_A}" "${TMP}/first.err" >/dev/null \
    || fail "first launch did not report its managed workspace"
grep -F "managed-worktree host=${PATH_A}" "${TMP}/first.err" >/dev/null \
    || fail "first launch did not report its managed path"

run_pi "${REPOSITORY}" --version >"${TMP}/second.out" 2>"${TMP}/second.err"
[[ "$(jq -r '.repositories[0].managedWorkspaces | length' "${MACHINE}")" == 2 ]] \
    || fail "second default launch did not create another managed workspace"
ID_B="$(jq -r '.repositories[0].managedWorkspaces[1].workspaceId' "${MACHINE}")"
PATH_B="${HOME_DIR}/worktrees/${REPOSITORY_ID}/${ID_B}"
[[ "${ID_A}" != "${ID_B}" && -d "${PATH_B}" ]] \
    || fail "managed launches did not receive distinct identities and paths"
[[ "$(< "${TMP}/second.out")" == "${PI_VERSION}" ]] \
    || fail "second real runtime launch reported inconsistent Pi version output"
grep -F "managed-worktree workspace-id=${ID_B}" "${TMP}/second.err" >/dev/null \
    || fail "second launch did not report its managed workspace"

for entry in "${ID_A}:${PATH_A}" "${ID_B}:${PATH_B}"; do
    workspace_id="${entry%%:*}"
    workspace_path="${entry#*:}"
    [[ "$(git -C "${workspace_path}" branch --show-current)" == "pi-run/${workspace_id}" ]] \
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
    .repositories[0].enabled == true and
    ([.repositories[0].managedWorkspaces[].workspaceId] | sort) == ([$a, $b] | sort) and
    ([.workspacePaths[].workspaceId | select(. == $a or . == $b)] | length) == 2
' "${MACHINE}" >/dev/null || fail "machine metadata does not contain both managed workspaces"
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
grep -F 'Preference: enabled' "${TMP}/list.out" >/dev/null \
    || fail "worktree list omitted the enabled preference"
for workspace_id in "${ID_A}" "${ID_B}"; do
    line="$(grep -F "${workspace_id}" "${TMP}/list.out")"
    [[ "${line}" == *available* ]] \
        || fail "worktree list did not report ${workspace_id} as available"
done
[[ "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before_list}" ]] \
    || fail "worktree list changed metadata"

create_session() {
    local workspace_id="$1" name="$2" epoch="$3" directory
    directory="${HOME_DIR}/profiles/default/sessions/${workspace_id}"
    printf '{"type":"session","id":"%s","timestamp":"2026-10-20T12:00:00Z","cwd":"/workspace","version":1}\n' \
        "${name}" > "${directory}/${name}.jsonl"
    touch -d "@${epoch}" "${directory}/${name}.jsonl"
}
create_session "${ID_A}" session-a 100
create_session "${ID_B}" session-b 200

managed_count="$(jq -r '.repositories[0].managedWorkspaces | length' "${MACHINE}")"
run_pi "${REPOSITORY}" -c --version >"${TMP}/continue.out" 2>"${TMP}/continue.err"
[[ "$(< "${TMP}/continue.out")" == "${PI_VERSION}" ]] \
    || fail "managed continuation did not execute the same real runtime"
grep -F "managed-worktree workspace-id=${ID_B}" "${TMP}/continue.err" >/dev/null \
    || fail "managed continuation did not select the newest transcript"
grep -F "managed-worktree host=${PATH_B}" "${TMP}/continue.err" >/dev/null \
    || fail "managed continuation did not reopen the selected path"
[[ "$(jq -r '.repositories[0].managedWorkspaces | length' "${MACHINE}")" == "${managed_count}" ]] \
    || fail "managed continuation created another workspace"

run_pi --no-worktree "${REPOSITORY}" --version >"${TMP}/direct.out" 2>"${TMP}/direct.err"
[[ "$(< "${TMP}/direct.out")" == "${PI_VERSION}" ]] \
    || fail "direct override did not execute the same real runtime"
grep -F "profile=default workspace=${REPOSITORY}" "${TMP}/direct.err" >/dev/null \
    || fail "--no-worktree did not use the primary checkout"
[[ "$(jq -r '.repositories[0].enabled' "${MACHINE}")" == true &&
   "$(jq -r '.repositories[0].managedWorkspaces | length' "${MACHINE}")" == "${managed_count}" ]] \
    || fail "--no-worktree changed preference or created a managed workspace"

(
    cd "${REPOSITORY}"
    PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree disable >"${TMP}/disable.out"
)
grep -F 'Worktree mode: disabled' "${TMP}/disable.out" >/dev/null \
    || fail "worktree disable did not report the disabled preference"
run_pi "${REPOSITORY}" --version >"${TMP}/disabled.out" 2>"${TMP}/disabled.err"
[[ "$(< "${TMP}/disabled.out")" == "${PI_VERSION}" ]] \
    || fail "disabled direct launch did not execute the same real runtime"
grep -F "profile=default workspace=${REPOSITORY}" "${TMP}/disabled.err" >/dev/null \
    || fail "disabled preference did not restore direct launches"
[[ "$(jq -r '.repositories[0].managedWorkspaces | length' "${MACHINE}")" == "${managed_count}" ]] \
    || fail "disabled direct launch created another managed workspace"

if [[ -d "${HOME_DIR}/worktrees/.launch-locks" ]] &&
   find "${HOME_DIR}/worktrees/.launch-locks" -mindepth 1 -print -quit | grep -q .; then
    fail "completed launches retained managed workspace locks"
fi
[[ "$(git -C "${REPOSITORY}" worktree list --porcelain | grep -c '^worktree ')" == 3 ]] \
    || fail "final Git state does not retain the primary and two managed worktrees"
[[ "$(jq -r '.repositories[0].enabled' "${MACHINE}")" == false ]] \
    || fail "final repository preference is not disabled"

echo "Managed worktree real-Docker end-to-end test passed"
