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

for command_name in docker git jq script; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "required command unavailable: ${command_name}"
done

VERSION="$(tr -d '\r\n' < "${ROOT}/VERSION")"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "VERSION is invalid"
IMAGE="${PI_RUN_TEST_IMAGE:-ghcr.io/aprilsoftware/pi-run:${VERSION}}"
docker image inspect "${IMAGE}" >/dev/null 2>&1 \
    || fail "selected runtime image is unavailable locally: ${IMAGE}"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
REPOSITORY="${TMP}/source repository"

run_pi() {
    PI_RUN_HOME="${HOME_DIR}" PI_RUN_IMAGE="${IMAGE}" "${ROOT}/bin/pi-run" "$@"
}

run_confirmed_finish() {
    local task_name="$1" answer="${2:-$1}" command
    printf -v command '%q ' env "PI_RUN_HOME=${HOME_DIR}" "PI_RUN_IMAGE=${IMAGE}" \
        "${ROOT}/bin/pi-run" worktree finish "${task_name}"
    printf '%s\n' "${answer}" | \
        script -qefc "cd $(printf '%q' "${REPOSITORY}") && ${command}" /dev/null
}

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
git init -q -b main "${REPOSITORY}"
git -C "${REPOSITORY}" config user.name fixture
git -C "${REPOSITORY}" config user.email fixture@pi-run.invalid
printf 'committed base\n' > "${REPOSITORY}/base.txt"
printf 'tracked original\n' > "${REPOSITORY}/tracked.txt"
printf 'local-ignored/\n' > "${REPOSITORY}/.gitignore"
git -C "${REPOSITORY}" add base.txt tracked.txt .gitignore
git -C "${REPOSITORY}" commit -qm base
BASE="$(git -C "${REPOSITORY}" rev-parse HEAD)"
printf 'tracked dirty\n' > "${REPOSITORY}/tracked.txt"
printf 'primary only\n' > "${REPOSITORY}/primary-untracked.txt"
SOURCE_STATUS="$(git -C "${REPOSITORY}" status --porcelain=v1)"

MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
REGISTRY="${HOME_DIR}/workspaces/registry.json"

(cd "${REPOSITORY}" && run_pi worktree start task-a . -- --version) \
    >"${TMP}/first.out" 2>"${TMP}/first.err"
REPOSITORY_ID="$(jq -r '.repositories[0].id' "${MACHINE}")"
[[ "${REPOSITORY_ID}" =~ ^[0-9a-f-]{36}$ ]] \
    || fail "repository metadata does not contain a UUID"
ID_A="$(jq -r '.repositories[0].tasks[] | select(.name == "task-a") | .workspaceId' "${MACHINE}")"
PATH_A="${HOME_DIR}/worktrees/${REPOSITORY_ID}/task-a"
[[ -d "${PATH_A}" ]] || fail "first default launch did not create its worktree"
[[ -s "${TMP}/first.out" ]] \
    || fail "first real runtime launch produced no Pi version output"
PI_VERSION="$(< "${TMP}/first.out")"
grep -F 'profile=default task=task-a' "${TMP}/first.err" >/dev/null \
    || fail "first launch did not report its task name"
grep -F "task-base=${BASE}" "${TMP}/first.err" >/dev/null \
    || fail "first launch did not report its task base"
if grep -F "${ID_A}" "${TMP}/first.err" >/dev/null ||
   grep -F "${PATH_A}" "${TMP}/first.err" >/dev/null; then
    fail "first launch exposed internal worktree identity"
fi

(cd "${REPOSITORY}" && run_pi worktree start task-b . -- --version) \
    >"${TMP}/second.out" 2>"${TMP}/second.err"
[[ "$(jq -r '.repositories[0].tasks | length' "${MACHINE}")" == 2 ]] \
    || fail "second named task was not created"
ID_B="$(jq -r '.repositories[0].tasks[] | select(.name == "task-b") | .workspaceId' "${MACHINE}")"
PATH_B="${HOME_DIR}/worktrees/${REPOSITORY_ID}/task-b"
[[ "${ID_A}" != "${ID_B}" && -d "${PATH_B}" ]] \
    || fail "managed launches did not receive distinct identities and paths"
[[ "$(< "${TMP}/second.out")" == "${PI_VERSION}" ]] \
    || fail "second real runtime launch reported inconsistent Pi version output"
grep -F 'profile=default task=task-b' "${TMP}/second.err" >/dev/null \
    || fail "second launch did not report task-b"
if grep -F "${ID_B}" "${TMP}/second.err" >/dev/null ||
   grep -F "${PATH_B}" "${TMP}/second.err" >/dev/null; then
    fail "second launch exposed internal worktree identity"
fi

for entry in "task-a:${ID_A}:${PATH_A}" "task-b:${ID_B}:${PATH_B}"; do
    task_name="${entry%%:*}"
    remainder="${entry#*:}"
    workspace_id="${remainder%%:*}"
    workspace_path="${remainder#*:}"
    [[ "$(git -C "${workspace_path}" branch --show-current)" == "pi-run/${task_name}" ]] \
        || fail "managed worktree has the wrong branch: ${workspace_id}"
    [[ "$(git -C "${workspace_path}" rev-parse HEAD)" == "${BASE}" ]] \
        || fail "managed worktree has the wrong base: ${workspace_id}"
    [[ "$(< "${workspace_path}/tracked.txt")" == 'tracked original' &&
       ! -e "${workspace_path}/primary-untracked.txt" ]] \
        || fail "managed worktree inherited uncommitted primary state: ${workspace_id}"
    [[ -d "${HOME_DIR}/profiles/default/sessions/${workspace_id}" ]] \
        || fail "managed workspace has no profile session directory: ${workspace_id}"
    grep -Fx "gitdir: ${REPOSITORY}/.git/worktrees/${task_name}" \
        "${workspace_path}/.git" >/dev/null \
        || fail "managed worktree did not retain its host Git pointer: ${workspace_id}"
done

[[ "$(git -C "${REPOSITORY}" branch --show-current)" == main &&
   "$(git -C "${REPOSITORY}" status --porcelain=v1)" == "${SOURCE_STATUS}" ]] \
    || fail "managed creation changed the primary checkout"

metadata_before_open="$(sha256sum "${MACHINE}" "${REGISTRY}")"
git_before_open="$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)"
(cd "${REPOSITORY}" && run_pi worktree open task-a . --version) \
    >"${TMP}/open.out" 2>"${TMP}/open.err"
[[ "$(< "${TMP}/open.out")" == "${PI_VERSION}" ]] \
    || fail "named task open did not execute the same real runtime"
grep -F 'profile=default task=task-a' "${TMP}/open.err" >/dev/null \
    || fail "named task open did not report task-a"
grep -F "task-head=${BASE}" "${TMP}/open.err" >/dev/null \
    || fail "named task open did not report task-a's current revision"
if grep -F "${ID_A}" "${TMP}/open.err" >/dev/null ||
   grep -F "${PATH_A}" "${TMP}/open.err" >/dev/null; then
    fail "named task open exposed internal worktree identity"
fi
[[ "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before_open}" &&
   "$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)" == "${git_before_open}" ]] \
    || fail "named task open changed metadata or Git worktrees"
printf '{"type":"session","id":"lifecycle","timestamp":"2026-10-20T12:00:00Z","cwd":"/workspace","version":1}\n' \
    > "${HOME_DIR}/profiles/default/sessions/${ID_A}/lifecycle.jsonl"

printf 'workspace A\n' > "${PATH_A}/workspace-a.txt"
git -C "${PATH_A}" add workspace-a.txt
printf 'workspace B\n' > "${PATH_B}/workspace-b.txt"
git -C "${PATH_B}" add workspace-b.txt
[[ "$(git -C "${PATH_A}" diff --cached --name-only)" == workspace-a.txt &&
   "$(git -C "${PATH_B}" diff --cached --name-only)" == workspace-b.txt &&
   ! -e "${PATH_A}/workspace-b.txt" && ! -e "${PATH_B}/workspace-a.txt" ]] \
    || fail "managed worktree files or indexes crossed workspace boundaries"

jq -e --arg a "${ID_A}" --arg b "${ID_B}" '
    .schemaVersion == 1 and
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
grep -Fx 'Repository: source repository' "${TMP}/list.out" >/dev/null \
    || fail "worktree list omitted the repository group"
if grep -F 'Preference:' "${TMP}/list.out" >/dev/null; then
    fail "worktree list reported the obsolete repository preference"
fi
for task_name in task-a task-b; do
    line="$(awk -v task="${task_name}" '$1 == task { print; exit }' "${TMP}/list.out")"
    [[ "${line}" == *active* && "${line}" == *available* ]] \
        || fail "worktree list did not report ${task_name} as available"
done
for internal in "${REPOSITORY_ID}" "${ID_A}" "${ID_B}" "${PATH_A}" "${PATH_B}"; do
    if grep -F "${internal}" "${TMP}/list.out" >/dev/null; then
        fail "worktree list exposed internal identity: ${internal}"
    fi
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

run_confirmed_finish task-a cancel >"${TMP}/cancel-finish.out" 2>&1
grep -F 'Task changes to commit: 1' "${TMP}/cancel-finish.out" >/dev/null \
    || fail "finish did not report staged task content"
grep -F 'Worktree finish cancelled.' "${TMP}/cancel-finish.out" >/dev/null \
    || fail "finish cancellation was unclear"
[[ -d "${PATH_A}" && "$(jq -r '.repositories[0].tasks[] | select(.name == "task-a") | .state' \
    "${MACHINE}")" == active ]] || fail "cancelled finish changed task-a"

# Prepare uncommitted task work; finish commits and integrates it while task-b stays isolated and dirty.
git -C "${PATH_A}" reset --hard -q "${BASE}"
printf 'completed task A\n' > "${PATH_A}/task-a-result.txt"
git -C "${REPOSITORY}" checkout -q -- tracked.txt
rm "${REPOSITORY}/primary-untracked.txt"
mkdir "${REPOSITORY}/local-ignored"
printf 'preserve target ignored content\n' > "${REPOSITORY}/local-ignored/credentials"
[[ "$(git -C "${PATH_A}" status --porcelain=v1 --ignored=matching)" == '?? task-a-result.txt' &&
   -z "$(git -C "${REPOSITORY}" status --porcelain=v1)" ]] \
    || fail "task-a and its integration checkout could not be prepared for finish"
[[ "$(git -C "${PATH_B}" diff --cached --name-only)" == workspace-b.txt ]] \
    || fail "preparing task-a changed task-b"
registry_before_finish="$(sha256sum "${REGISTRY}")"
session_before_finish="$(sha256sum "${HOME_DIR}/profiles/default/sessions/${ID_A}/lifecycle.jsonl")"
run_confirmed_finish task-a >"${TMP}/finish.out" 2>&1
grep -F 'Finished task: task-a' "${TMP}/finish.out" >/dev/null \
    || fail "successful task finish was not reported"
grep -F 'Integrated into: main' "${TMP}/finish.out" >/dev/null \
    || fail "successful task finish did not report its integration target"
if grep -F "${ID_A}" "${TMP}/finish.out" >/dev/null; then
    fail "successful task finish exposed its internal workspace identity"
fi
[[ ! -e "${PATH_A}" && ! -e "${REPOSITORY}/.git/worktrees/task-a" ]] \
    || fail "task-a checkout or Git administration remains after finish"
[[ "$(git -C "${REPOSITORY}" log -1 --format=%s)" == 'Complete task task-a' &&
   "$(< "${REPOSITORY}/task-a-result.txt")" == 'completed task A' &&
   "$(< "${REPOSITORY}/local-ignored/credentials")" == 'preserve target ignored content' ]] \
    || fail "task-a was not integrated without changing ignored target content"
if git -C "${REPOSITORY}" show-ref --verify --quiet "refs/heads/pi-run/task-a"; then
    fail "task-a branch remains after finish"
fi
[[ "$(sha256sum "${REGISTRY}")" == "${registry_before_finish}" &&
   "$(sha256sum "${HOME_DIR}/profiles/default/sessions/${ID_A}/lifecycle.jsonl")" == \
       "${session_before_finish}" ]] \
    || fail "finish changed portable identity or task-a sessions"
jq -e --arg a "${ID_A}" --arg b "${ID_B}" '
    ([.workspacePaths[] | select(.workspaceId == $a)] | length) == 0 and
    ([.workspacePaths[] | select(.workspaceId == $b)] | length) == 1 and
    ([.repositories[0].tasks[] | select(.workspaceId == $a and .state == "finished" and
        (.finishedAt | type == "string"))] | length) == 1 and
    ([.repositories[0].tasks[] | select(.workspaceId == $b and .state == "active")] | length) == 1
' "${MACHINE}" >/dev/null || fail "finish published incorrect task lifecycle metadata"
[[ -d "${PATH_B}" && "$(git -C "${PATH_B}" diff --cached --name-only)" == workspace-b.txt ]] \
    || fail "finishing task-a changed task-b"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree list >"${TMP}/list-after.out"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree list --all >"${TMP}/list-all.out"
line_a="$(awk '$1 == "task-a" { print; exit }' "${TMP}/list-after.out")"
[[ -z "${line_a}" ]] || fail "normal listing retained finished task-a"
line_a="$(awk '$1 == "task-a" { print; exit }' "${TMP}/list-all.out")"
line_b="$(awk '$1 == "task-b" { print; exit }' "${TMP}/list-after.out")"
[[ "${line_a}" == *finished* && "${line_a}" == *archived* &&
   "${line_b}" == *active* && "${line_b}" == *available* ]] \
    || fail "task listings do not distinguish finished task-a from active task-b"
for internal in "${REPOSITORY_ID}" "${ID_A}" "${ID_B}" "${PATH_A}" "${PATH_B}"; do
    if grep -F "${internal}" "${TMP}/list-all.out" >/dev/null; then
        fail "historical worktree list exposed internal identity: ${internal}"
    fi
done
if (cd "${REPOSITORY}" && run_pi worktree open task-a . --version) \
    >/dev/null 2>"${TMP}/finished-open.err"; then
    fail "finished task-a was reopened"
fi
grep -F 'no unique active worktree task' "${TMP}/finished-open.err" >/dev/null \
    || fail "finished task open refusal was unclear"
if run_pi resume default "${ID_A}" >/dev/null 2>"${TMP}/finished-resume.err"; then
    fail "finished task-a was resumed"
fi
grep -F 'managed worktree is unavailable' "${TMP}/finished-resume.err" >/dev/null \
    || fail "finished task resume refusal was unclear"

if [[ -d "${HOME_DIR}/worktrees/.launch-locks" ]] &&
   find "${HOME_DIR}/worktrees/.launch-locks" -mindepth 1 -print -quit | grep -q .; then
    fail "completed lifecycle operations retained managed workspace locks"
fi
[[ "$(git -C "${REPOSITORY}" worktree list --porcelain | grep -c '^worktree ')" == 2 ]] \
    || fail "final Git state does not retain exactly the primary and active task-b worktrees"
jq -e '.repositories[0] | (has("enabled") or has("managedWorkspaces")) | not' \
    "${MACHINE}" >/dev/null || fail "prototype repository fields remain in task metadata"

echo "Managed worktree real-Docker start/open/finish lifecycle test passed"
