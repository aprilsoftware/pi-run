#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/tests/worktree-fixtures.sh"
TMP="$(mktemp -d)"
ACTIVE_PID=""
cleanup() {
    if [[ -n "${ACTIVE_PID}" ]]; then
        kill "${ACTIVE_PID}" 2>/dev/null || true
        wait "${ACTIVE_PID}" 2>/dev/null || true
    fi
    rm -rf "${TMP}"
}
trap cleanup EXIT

fail() {
    echo "worktree-finish-test: $*" >&2
    exit 1
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    image)
        [[ "${2:-}" == inspect ]]
        ;;
    run)
        shift
        workspace=
        action=inspect-task
        source_branch=
        task_name=
        previous=
        for argument in "$@"; do
            if [[ "${previous}" == --mount &&
                  ( "${argument}" == type=bind,src=*,dst=/workspace ||
                    "${argument}" == type=bind,src=*,dst=/workspace,readonly ) ]]; then
                workspace="${argument#*src=}"
                workspace="${workspace%,dst=*}"
            elif [[ "${previous}" == --env && "${argument}" == PI_RUN_FINISH_ACTION=* ]]; then
                action="${argument#*=}"
            elif [[ "${previous}" == --env && "${argument}" == PI_RUN_SOURCE_BRANCH=* ]]; then
                source_branch="${argument#*=}"
            elif [[ "${previous}" == --env && "${argument}" == PI_RUN_TASK_NAME=* ]]; then
                task_name="${argument#*=}"
            fi
            previous="${argument}"
        done
        [[ -n "${workspace}" ]] || exit 2
        count=0
        [[ ! -f "${DOCKER_COUNT_FILE:?}" ]] || count="$(< "${DOCKER_COUNT_FILE}")"
        printf '%s\n' "$((count + 1))" > "${DOCKER_COUNT_FILE}"
        [[ "${FAKE_FINISH_MODE:-ok}" != fail ]] || exit 1
        if [[ "${action}" == merge ]]; then
            target_before="$(git -C "${workspace}" rev-parse HEAD)"
            if git -C "${workspace}" -c core.hooksPath=/dev/null \
                merge --ff --no-edit --no-gpg-sign -m "Merge Pi-Run task ${task_name}" \
                "refs/heads/${source_branch}"; then
                exit 0
            fi
            git -C "${workspace}" merge --abort >/dev/null 2>&1 || exit 43
            [[ "$(git -C "${workspace}" rev-parse HEAD)" == "${target_before}" &&
               -z "$(git -C "${workspace}" status --porcelain=v1 --untracked-files=all --ignored=matching)" ]] \
                && exit 42
            exit 43
        fi
        if git -C "${workspace}" ls-files --stage |
            awk '$1 == "160000" { found=1 } END { exit(found ? 0 : 1) }'; then
            exit 42
        fi
        git -C "${workspace}" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
            -c core.untrackedCache=false status --porcelain=v1 --untracked-files=all --ignored=matching
        ;;
    *) exit 2 ;;
esac
FAKE_DOCKER
chmod 0755 "${TMP}/fake-bin/docker"

setup_case() {
    local label="$1" workspace_id="$2"
    HOME_DIR="${TMP}/${label}/Pi Run"
    REPOSITORY="${TMP}/${label}/repository"
    TASK_NAME="${label}-task"
    WORKSPACE_ID="${workspace_id}"
    DOCKER_COUNT_FILE="${TMP}/${label}/docker-count"
    mkdir -p "${TMP}/${label}"
    PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
    git init -q -b main "${REPOSITORY}"
    git -C "${REPOSITORY}" config user.name fixture
    git -C "${REPOSITORY}" config user.email fixture@pi-run.invalid
    printf 'base\n' > "${REPOSITORY}/base.txt"
    printf '*.ignored\n' > "${REPOSITORY}/.gitignore"
    git -C "${REPOSITORY}" add base.txt .gitignore
    git -C "${REPOSITORY}" commit -qm base
    REPOSITORY_ID="$(register_worktree_repository_fixture "${ROOT}" "${HOME_DIR}" "${REPOSITORY}")"
    MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
    REGISTRY="${HOME_DIR}/workspaces/registry.json"
    WORKTREE="${HOME_DIR}/worktrees/${REPOSITORY_ID}/${WORKSPACE_ID}"
    BRANCH="pi-run/${TASK_NAME}/${WORKSPACE_ID}"
    ADMIN="${REPOSITORY}/.git/worktrees/${WORKSPACE_ID}"
    SESSION_DIR="${HOME_DIR}/profiles/default/sessions/${WORKSPACE_ID}"
    mkdir -p "$(dirname "${WORKTREE}")"
    chmod 0700 "${HOME_DIR}/worktrees" "$(dirname "${WORKTREE}")"
    git -C "${REPOSITORY}" worktree add -q -b "${BRANCH}" "${WORKTREE}" main
    TEST_ROOT="${ROOT}" TEST_HOME="${HOME_DIR}" TEST_REPOSITORY="${REPOSITORY_ID}" \
        TEST_ID="${WORKSPACE_ID}" TEST_TASK_NAME="${TASK_NAME}" TEST_PATH="${WORKTREE}" bash -ceu '
            fail() { echo "pi-run: $*" >&2; exit 1; }
            PI_RUN_HOME_RESOLVED="${TEST_HOME}"
            source "${TEST_ROOT}/lib/pi-run/workspaces.sh"
            publish_managed_worktree_metadata \
                "${TEST_ID}" "${TEST_TASK_NAME}" "${TEST_REPOSITORY}" \
                "pi-run/${TEST_TASK_NAME}/${TEST_ID}" "${TEST_PATH}" >/dev/null
        '
    mkdir -p "${SESSION_DIR}"
    printf '{"type":"session","id":"saved","timestamp":"2026-10-20T12:00:00Z","cwd":"/workspace","version":1}\n' \
        > "${SESSION_DIR}/saved.jsonl"
}

docker_count() {
    if [[ -f "${DOCKER_COUNT_FILE}" ]]; then
        printf '%s\n' "$(< "${DOCKER_COUNT_FILE}")"
    else
        printf '0\n'
    fi
}

finish_command() {
    printf -v FINISH_COMMAND '%q ' env \
        "PATH=${TMP}/fake-bin:${PATH}" "PI_RUN_HOME=${HOME_DIR}" \
        PI_RUN_IMAGE=ghcr.io/aprilsoftware/pi-run:0.0.0-test \
        "DOCKER_COUNT_FILE=${DOCKER_COUNT_FILE}" "FAKE_FINISH_MODE=${FAKE_FINISH_MODE:-ok}" \
        "${ROOT}/bin/pi-run" worktree finish "${TASK_NAME}"
}

run_confirmed_finish() {
    local answer="$1" output="$2"
    finish_command
    printf '%s\n' "${answer}" | script -qefc "cd $(printf '%q' "${REPOSITORY}") && ${FINISH_COMMAND}" /dev/null \
        > "${output}" 2>&1
}

set_task_state() {
    local state="$1"
    jq --arg id "${WORKSPACE_ID}" --arg state "${state}" '
        (.repositories[].tasks[] | select(.workspaceId == $id) | .state) = $state |
        (.repositories[].tasks[] | select(.workspaceId == $id) | .finishedAt) = null
    ' "${MACHINE}" > "${MACHINE}.tmp"
    mv "${MACHINE}.tmp" "${MACHINE}"
    chmod 0600 "${MACHINE}"
}

setup_case main 11111111-1111-4111-8111-111111111111
registry_before="$(sha256sum "${REGISTRY}")"
session_before="$(sha256sum "${SESSION_DIR}/saved.jsonl")"

run_confirmed_finish wrong-answer "${TMP}/cancel.out"
grep -F 'Worktree finish cancelled.' "${TMP}/cancel.out" >/dev/null \
    || fail "finish cancellation was not reported"
[[ -d "${WORKTREE}" && -d "${ADMIN}" && "$(jq -r '.repositories[0].tasks[0].state' "${MACHINE}")" == active &&
   "$(docker_count)" == 0 ]] || fail "cancelled finish changed task state"

if (cd "${REPOSITORY}" && PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    PI_RUN_IMAGE=ghcr.io/aprilsoftware/pi-run:0.0.0-test DOCKER_COUNT_FILE="${DOCKER_COUNT_FILE}" \
    "${ROOT}/bin/pi-run" worktree finish "${TASK_NAME}") >/dev/null 2>"${TMP}/noninteractive.err"; then
    fail "non-interactive finish was accepted"
fi
grep -F 'requires confirmation from an interactive terminal' "${TMP}/noninteractive.err" >/dev/null \
    || fail "non-interactive finish diagnostic was unclear"

if (cd "${WORKTREE}" && PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree finish "${TASK_NAME}") \
    >/dev/null 2>"${TMP}/target-cwd.err"; then
    fail "finish from inside the target worktree was accepted"
fi
grep -F 'must run from the integration checkout, not the task checkout' "${TMP}/target-cwd.err" >/dev/null \
    || fail "target-current-directory diagnostic was unclear"

assert_dirty_refused() {
    local label="$1"
    count_before="$(docker_count)"
    if run_confirmed_finish "${TASK_NAME}" "${TMP}/${label}.out"; then
        fail "${label} task state was accepted for finish"
    fi
    grep -F 'refuses staged, modified, untracked, ignored, or nested-repository content' \
        "${TMP}/${label}.out" >/dev/null || fail "${label} refusal was unclear"
    [[ "$(jq -r '.repositories[0].tasks[0].state' "${MACHINE}")" == active &&
       "$(docker_count)" == $((count_before + 1)) ]] || fail "${label} refusal changed lifecycle state"
}

printf 'modified\n' >> "${WORKTREE}/base.txt"
assert_dirty_refused modified
git -C "${WORKTREE}" checkout -- base.txt
printf 'staged\n' >> "${WORKTREE}/base.txt"
git -C "${WORKTREE}" add base.txt
assert_dirty_refused staged
git -C "${WORKTREE}" reset --hard -q
printf 'untracked\n' > "${WORKTREE}/untracked.txt"
assert_dirty_refused untracked
rm "${WORKTREE}/untracked.txt"
printf 'ignored\n' > "${WORKTREE}/cache.ignored"
assert_dirty_refused ignored
rm "${WORKTREE}/cache.ignored"

git -C "${WORKTREE}" update-index --add --cacheinfo 160000,"$(git -C "${REPOSITORY}" rev-parse HEAD)",nested-module
if run_confirmed_finish "${TASK_NAME}" "${TMP}/submodule.out"; then
    fail "submodule task was accepted for finish"
fi
grep -F 'refuses repositories containing submodules' "${TMP}/submodule.out" >/dev/null \
    || fail "submodule refusal was unclear"
git -C "${WORKTREE}" rm --cached -q nested-module

FAKE_FINISH_MODE=fail
if run_confirmed_finish "${TASK_NAME}" "${TMP}/inspection-fail.out"; then
    fail "failed restricted inspection was accepted"
fi
unset FAKE_FINISH_MODE
grep -F 'restricted worktree finish inspection failed' "${TMP}/inspection-fail.out" >/dev/null \
    || fail "restricted-inspection failure was unclear"
[[ "$(jq -r '.repositories[0].tasks[0].state' "${MACHINE}")" == active ]] \
    || fail "failed restricted inspection changed lifecycle state"

sleep 30 &
ACTIVE_PID=$!
stat="$(< "/proc/${ACTIVE_PID}/stat")"
rest="${stat##*) }"
# shellcheck disable=SC2086 # Intentional splitting of procfs fields.
set -- ${rest}
start_token="${20}"
LOCK_DIR="${HOME_DIR}/worktrees/.launch-locks/${WORKSPACE_ID}"
mkdir "${LOCK_DIR}"
chmod 0700 "${LOCK_DIR}"
jq -n --arg machine "$("${ROOT}/bin/pi-run" machine-id)" --argjson pid "${ACTIVE_PID}" \
    --arg start "${start_token}" --arg token 22222222-2222-4222-8222-222222222222 \
    --arg workspace "${WORKSPACE_ID}" --arg created 2026-10-20T12:00:00Z \
    '{schemaVersion:1,machineId:$machine,pid:$pid,processStartToken:$start,
      ownershipToken:$token,workspaceId:$workspace,createdAt:$created}' > "${LOCK_DIR}/owner.json"
chmod 0600 "${LOCK_DIR}/owner.json"
if run_confirmed_finish "${TASK_NAME}" "${TMP}/active.out"; then
    fail "active task was finished"
fi
grep -F 'managed workspace is already active' "${TMP}/active.out" >/dev/null \
    || fail "active-task finish diagnostic was unclear"
kill "${ACTIVE_PID}"
wait "${ACTIVE_PID}" 2>/dev/null || true
ACTIVE_PID=""

# The now-stale lock must be recovered by the successful finish.
run_confirmed_finish "${TASK_NAME}" "${TMP}/success.out"
grep -F "Finished task: ${TASK_NAME}" "${TMP}/success.out" >/dev/null \
    || fail "successful finish was not reported"
grep -F 'Integrated into: main' "${TMP}/success.out" >/dev/null \
    || fail "successful finish did not report its target branch"
if grep -F "${WORKSPACE_ID}" "${TMP}/success.out" >/dev/null; then
    fail "successful finish exposed its internal workspace identity"
fi
[[ ! -e "${WORKTREE}" && ! -e "${ADMIN}" && ! -e "${LOCK_DIR}" ]] \
    || fail "successful finish left checkout administration or locks"
if git -C "${REPOSITORY}" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    fail "finish retained the local task branch"
fi
jq -e --arg id "${WORKSPACE_ID}" '
    ([.workspacePaths[] | select(.workspaceId == $id)] | length) == 0 and
    ([.repositories[].tasks[] | select(.workspaceId == $id and .state == "finished" and
        (.finishedAt | type == "string"))] | length) == 1
' "${MACHINE}" >/dev/null || fail "finish did not publish historical task metadata"
[[ "$(sha256sum "${REGISTRY}")" == "${registry_before}" &&
   "$(sha256sum "${SESSION_DIR}/saved.jsonl")" == "${session_before}" ]] \
    || fail "finish changed the registry or conversation history"
normal_list="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree list)"
all_list="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree list --all)"
[[ -z "$(awk -v task="${TASK_NAME}" '$1 == task { print; exit }' <<< "${normal_list}")" ]] \
    || fail "normal listing included a finished task"
finished_line="$(awk -v task="${TASK_NAME}" '$1 == task { print; exit }' <<< "${all_list}")"
[[ "${finished_line}" == *finished* && "${finished_line}" == *archived* ]] \
    || fail "--all listing omitted finished task state"
if grep -F "${WORKSPACE_ID}" <<< "${all_list}" >/dev/null; then
    fail "--all listing exposed the internal workspace identity"
fi
if PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    worktree open "${TASK_NAME}" "${REPOSITORY}" \
    >/dev/null 2>"${TMP}/finished-open.err"; then
    fail "finished task was reopened"
fi
grep -F 'no unique active worktree task' "${TMP}/finished-open.err" >/dev/null \
    || fail "finished-task open diagnostic was unclear"
if PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" resume default "${WORKSPACE_ID}" \
    >/dev/null 2>"${TMP}/finished-resume.err"; then
    fail "finished task was resumed"
fi
grep -F 'managed worktree is unavailable' "${TMP}/finished-resume.err" >/dev/null \
    || fail "finished-task resume diagnostic was unclear"

setup_case target-dirty 55555555-5555-4555-8555-555555555555
printf 'target dirty\n' > "${REPOSITORY}/target-dirty.txt"
if run_confirmed_finish "${TASK_NAME}" "${TMP}/target-dirty.out"; then
    fail "dirty target checkout was accepted for finish"
fi
grep -F 'requires a clean target checkout' "${TMP}/target-dirty.out" >/dev/null \
    || fail "dirty-target refusal was unclear"
[[ -d "${WORKTREE}" && "$(jq -r '.repositories[0].tasks[0].state' "${MACHINE}")" == active ]] \
    || fail "dirty-target refusal changed task state"
rm "${REPOSITORY}/target-dirty.txt"

setup_case fast-forward 66666666-6666-4666-8666-666666666666
printf 'task result\n' > "${WORKTREE}/task-result.txt"
git -C "${WORKTREE}" add task-result.txt
git -C "${WORKTREE}" commit -qm 'task result'
task_head="$(git -C "${WORKTREE}" rev-parse HEAD)"
run_confirmed_finish "${TASK_NAME}" "${TMP}/fast-forward.out"
[[ "$(git -C "${REPOSITORY}" rev-parse HEAD)" == "${task_head}" &&
   "$(< "${REPOSITORY}/task-result.txt")" == 'task result' ]] \
    || fail "finish did not fast-forward the target branch"
if git -C "${REPOSITORY}" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    fail "fast-forward finish retained the task branch"
fi

setup_case merge-commit 77777777-7777-4777-8777-777777777777
printf 'task result\n' > "${WORKTREE}/task-result.txt"
git -C "${WORKTREE}" add task-result.txt
git -C "${WORKTREE}" commit -qm 'task result'
task_head="$(git -C "${WORKTREE}" rev-parse HEAD)"
printf 'target result\n' > "${REPOSITORY}/target-result.txt"
git -C "${REPOSITORY}" add target-result.txt
git -C "${REPOSITORY}" commit -qm 'target result'
target_head="$(git -C "${REPOSITORY}" rev-parse HEAD)"
run_confirmed_finish "${TASK_NAME}" "${TMP}/merge-commit.out"
merge_head="$(git -C "${REPOSITORY}" rev-parse HEAD)"
[[ "$(git -C "${REPOSITORY}" rev-list --parents -n 1 "${merge_head}")" == \
   "${merge_head} ${target_head} ${task_head}" &&
   "$(git -C "${REPOSITORY}" log -1 --format=%s)" == "Merge Pi-Run task ${TASK_NAME}" &&
   "$(< "${REPOSITORY}/task-result.txt")" == 'task result' &&
   "$(< "${REPOSITORY}/target-result.txt")" == 'target result' ]] \
    || fail "finish did not create the expected merge commit"
if git -C "${REPOSITORY}" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    fail "merge-commit finish retained the task branch"
fi

setup_case conflict 88888888-8888-4888-8888-888888888888
printf 'task version\n' > "${WORKTREE}/base.txt"
git -C "${WORKTREE}" add base.txt
git -C "${WORKTREE}" commit -qm 'task conflict'
printf 'target version\n' > "${REPOSITORY}/base.txt"
git -C "${REPOSITORY}" add base.txt
git -C "${REPOSITORY}" commit -qm 'target conflict'
target_head="$(git -C "${REPOSITORY}" rev-parse HEAD)"
if run_confirmed_finish "${TASK_NAME}" "${TMP}/conflict.out"; then
    fail "conflicting task merge was accepted"
fi
grep -F 'target checkout was restored and the task remains active' "${TMP}/conflict.out" >/dev/null \
    || fail "merge-conflict rollback diagnostic was unclear"
[[ "$(git -C "${REPOSITORY}" rev-parse HEAD)" == "${target_head}" &&
   -z "$(git -C "${REPOSITORY}" status --porcelain=v1 --untracked-files=all --ignored=matching)" &&
   ! -e "${REPOSITORY}/.git/MERGE_HEAD" && -d "${WORKTREE}" &&
   "$(jq -r '.repositories[0].tasks[0].state' "${MACHINE}")" == active ]] \
    || fail "merge conflict did not restore the target and preserve the active task"

setup_case missing 22222222-2222-4222-8222-222222222222
git -C "${REPOSITORY}" worktree remove "${WORKTREE}"
if (cd "${REPOSITORY}" && PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree finish "${TASK_NAME}") \
    >/dev/null 2>"${TMP}/missing.err"; then
    fail "missing active task was finished"
fi
grep -F 'managed finish checkout is missing' "${TMP}/missing.err" >/dev/null \
    || fail "missing active task diagnostic was unclear"

setup_case recovery-before 33333333-3333-4333-8333-333333333333
set_task_state finishing
run_confirmed_finish "${TASK_NAME}" "${TMP}/recovery-before.out"
[[ "$(jq -r '.repositories[0].tasks[0].state' "${MACHINE}")" == finished ]] \
    || fail "finishing task with checkout was not recovered"

setup_case recovery-after 44444444-4444-4444-8444-444444444444
set_task_state finishing
git -C "${REPOSITORY}" worktree remove "${WORKTREE}"
count_before="$(docker_count)"
run_confirmed_finish "${TASK_NAME}" "${TMP}/recovery-after.out"
[[ "$(jq -r '.repositories[0].tasks[0].state' "${MACHINE}")" == finished &&
   "$(docker_count)" == "${count_before}" ]] \
    || fail "post-removal finishing state was not completed without inspection"

echo "Managed worktree finish tests passed"
