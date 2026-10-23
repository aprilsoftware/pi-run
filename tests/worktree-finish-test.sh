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
        source_head=
        task_name=
        status_hash=
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
            elif [[ "${previous}" == --env && "${argument}" == PI_RUN_SOURCE_HEAD=* ]]; then
                source_head="${argument#*=}"
            elif [[ "${previous}" == --env && "${argument}" == PI_RUN_TASK_NAME=* ]]; then
                task_name="${argument#*=}"
            elif [[ "${previous}" == --env && "${argument}" == PI_RUN_TASK_STATUS_SHA256=* ]]; then
                status_hash="${argument#*=}"
            fi
            previous="${argument}"
        done
        [[ -n "${workspace}" ]] || exit 2
        count=0
        [[ ! -f "${DOCKER_COUNT_FILE:?}" ]] || count="$(< "${DOCKER_COUNT_FILE}")"
        printf '%s\n' "$((count + 1))" > "${DOCKER_COUNT_FILE}"
        [[ "${FAKE_FINISH_MODE:-ok}" != fail ]] || exit 1
        if [[ "${action}" == commit-task && "${FAKE_FINISH_MODE:-ok}" == commit-fail ]]; then
            exit 1
        elif [[ "${action}" == commit-task ]]; then
            current="$(git -C "${workspace}" status --porcelain=v1 --untracked-files=all --ignored=matching)"
            [[ "$(printf '%s' "${current}" | sha256sum | cut -d ' ' -f 1)" == "${status_hash}" ]] \
                || exit 44
            git -C "${workspace}" add -A
            git -C "${workspace}" diff --cached --quiet && exit 45
            git -C "${workspace}" -c core.hooksPath=/dev/null commit -qm "Complete task ${task_name}"
            exit 0
        elif [[ "${action}" == clean-task ]]; then
            current="$(git -C "${workspace}" status --porcelain=v1 --untracked-files=all --ignored=matching)"
            [[ "$(printf '%s' "${current}" | sha256sum | cut -d ' ' -f 1)" == "${status_hash}" ]] \
                || exit 44
            git -C "${workspace}" clean -fdX -q
            [[ -z "$(git -C "${workspace}" status --porcelain=v1 --untracked-files=all --ignored=matching)" ]]
            exit 0
        elif [[ "${action}" == merge ]]; then
            target_before="$(git -C "${workspace}" rev-parse HEAD)"
            if git -C "${workspace}" -c core.hooksPath=/dev/null \
                merge --ff --no-edit --no-gpg-sign -m "Merge Pi-Run task ${task_name}" \
                "refs/heads/${source_branch}"; then
                exit 0
            fi
            git -C "${workspace}" merge --abort >/dev/null 2>&1 || exit 43
            [[ "$(git -C "${workspace}" rev-parse HEAD)" == "${target_before}" &&
               -z "$(git -C "${workspace}" status --porcelain=v1 --untracked-files=no)" ]] \
                && exit 42
            exit 43
        fi
        if [[ "${action}" == inspect-target ]]; then
            status="$(git -C "${workspace}" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
                -c core.untrackedCache=false status --porcelain=v1 --untracked-files=no)"
            if [[ -n "${status}" ]]; then
                printf '%s\n' "${status}"
                exit 0
            fi
            if [[ -n "${source_head}" ]]; then
                base="$(git -C "${workspace}" merge-base HEAD "${source_head}")"
                mapfile -d '' changed < <(git -C "${workspace}" diff --name-only -z --no-renames \
                    "${base}" "${source_head}")
                mapfile -d '' local_paths < <(
                    git -C "${workspace}" ls-files --others --exclude-standard -z
                    git -C "${workspace}" ls-files --others --ignored --exclude-standard -z
                )
                for changed_path in "${changed[@]}"; do
                    for local_path in "${local_paths[@]}"; do
                        if [[ "${changed_path}" == "${local_path}" ||
                              "${changed_path}" == "${local_path}/"* ||
                              "${local_path}" == "${changed_path}/"* ]]; then
                            exit 44
                        fi
                    done
                done
            fi
            exit 0
        fi
        if git -C "${workspace}" ls-files --stage |
            awk '$1 == "160000" { found=1 } END { exit(found ? 0 : 1) }'; then
            exit 42
        fi
        if find "${workspace}" -mindepth 2 -name .git -print -quit | grep -q .; then
            exit 43
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
    WORKTREE="${HOME_DIR}/worktrees/${REPOSITORY_ID}/${TASK_NAME}"
    BRANCH="pi-run/${TASK_NAME}"
    ADMIN="${REPOSITORY}/.git/worktrees/${TASK_NAME}"
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
                "pi-run/${TEST_TASK_NAME}" "${TEST_PATH}" >/dev/null
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
   "$(docker_count)" == 1 ]] || fail "cancelled finish changed task state"

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

git -C "${WORKTREE}" update-index --add --cacheinfo 160000,"$(git -C "${REPOSITORY}" rev-parse HEAD)",nested-module
if run_confirmed_finish "${TASK_NAME}" "${TMP}/submodule.out"; then
    fail "submodule task was accepted for finish"
fi
grep -F 'refuses repositories containing submodules' "${TMP}/submodule.out" >/dev/null \
    || fail "submodule refusal was unclear"
git -C "${WORKTREE}" rm --cached -q nested-module

mkdir "${WORKTREE}/nested-repository"
git -C "${WORKTREE}/nested-repository" init -q
if run_confirmed_finish "${TASK_NAME}" "${TMP}/nested.out"; then
    fail "nested repository task was accepted for finish"
fi
grep -F 'refuses nested repositories' "${TMP}/nested.out" >/dev/null \
    || fail "nested-repository refusal was unclear"
rm -rf "${WORKTREE}/nested-repository"

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

# An already-integrated task does not inspect unrelated target content because no merge occurs.
printf 'preserve target ignored content\n' > "${REPOSITORY}/preserved.ignored"
# The now-stale lock must be recovered by the successful finish.
run_confirmed_finish "${TASK_NAME}" "${TMP}/success.out"
grep -F "Finished task: ${TASK_NAME}" "${TMP}/success.out" >/dev/null \
    || fail "successful finish was not reported"
grep -F 'Integrated into: main' "${TMP}/success.out" >/dev/null \
    || fail "successful finish did not report its target branch"
if grep -F "${WORKSPACE_ID}" "${TMP}/success.out" >/dev/null; then
    fail "successful finish exposed its internal workspace identity"
fi
[[ ! -e "${WORKTREE}" && ! -e "${ADMIN}" && ! -e "${LOCK_DIR}" &&
   "$(< "${REPOSITORY}/preserved.ignored")" == 'preserve target ignored content' ]] \
    || fail "successful finish changed ignored target content or left checkout state"
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

setup_case auto-commit aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
printf 'modified task content\n' > "${WORKTREE}/base.txt"
printf 'staged task content\n' > "${WORKTREE}/staged.txt"
git -C "${WORKTREE}" add staged.txt
printf 'untracked task content\n' > "${WORKTREE}/untracked.txt"
printf 'discard ignored task content\n' > "${WORKTREE}/cache.ignored"
printf 'preserve ignored target content\n' > "${REPOSITORY}/preserved.ignored"
run_confirmed_finish "${TASK_NAME}" "${TMP}/auto-commit.out"
grep -F 'Task changes to commit: 3' "${TMP}/auto-commit.out" >/dev/null \
    || fail "finish did not report task changes to commit"
grep -F 'Ignored task paths to discard: 1' "${TMP}/auto-commit.out" >/dev/null \
    || fail "finish did not report ignored task content"
grep -F "Finish will create commit \"Complete task ${TASK_NAME}\"" \
    "${TMP}/auto-commit.out" >/dev/null \
    || fail "finish did not disclose its automatic task commit"
[[ "$(git -C "${REPOSITORY}" log -1 --format=%s)" == "Complete task ${TASK_NAME}" &&
   "$(< "${REPOSITORY}/base.txt")" == 'modified task content' &&
   "$(< "${REPOSITORY}/staged.txt")" == 'staged task content' &&
   "$(< "${REPOSITORY}/untracked.txt")" == 'untracked task content' &&
   "$(< "${REPOSITORY}/preserved.ignored")" == 'preserve ignored target content' &&
   ! -e "${REPOSITORY}/cache.ignored" && ! -e "${WORKTREE}" ]] \
    || fail "finish did not commit task content, discard ignored output, and preserve target content"

setup_case commit-failure cccccccc-cccc-4ccc-8ccc-cccccccccccc
printf 'pending task content\n' > "${WORKTREE}/pending.txt"
task_head="$(git -C "${WORKTREE}" rev-parse HEAD)"
FAKE_FINISH_MODE=commit-fail
if run_confirmed_finish "${TASK_NAME}" "${TMP}/commit-failure.out"; then
    fail "failed automatic task commit was accepted"
fi
unset FAKE_FINISH_MODE
grep -F 'restricted task commit failed; task remains active' \
    "${TMP}/commit-failure.out" >/dev/null || fail "commit-failure diagnostic was unclear"
[[ "$(git -C "${WORKTREE}" rev-parse HEAD)" == "${task_head}" &&
   "$(< "${WORKTREE}/pending.txt")" == 'pending task content' &&
   "$(jq -r '.repositories[0].tasks[0].state' "${MACHINE}")" == active ]] \
    || fail "failed task commit changed task work or lifecycle state"

setup_case target-dirty 55555555-5555-4555-8555-555555555555
printf 'task result\n' > "${WORKTREE}/task-result.txt"
git -C "${WORKTREE}" add task-result.txt
git -C "${WORKTREE}" commit -qm 'task result'
printf 'target dirty\n' >> "${REPOSITORY}/base.txt"
if run_confirmed_finish "${TASK_NAME}" "${TMP}/target-dirty.out"; then
    fail "dirty target checkout was accepted for finish"
fi
grep -F 'requires a target checkout without tracked modifications' \
    "${TMP}/target-dirty.out" >/dev/null || fail "dirty-target refusal was unclear"
[[ -d "${WORKTREE}" && "$(jq -r '.repositories[0].tasks[0].state' "${MACHINE}")" == active ]] \
    || fail "dirty-target refusal changed task state"
git -C "${REPOSITORY}" checkout -- base.txt

setup_case fast-forward 66666666-6666-4666-8666-666666666666
printf 'task result\n' > "${WORKTREE}/task-result.txt"
git -C "${WORKTREE}" add task-result.txt
git -C "${WORKTREE}" commit -qm 'task result'
task_head="$(git -C "${WORKTREE}" rev-parse HEAD)"
printf 'preserve ignored content\n' > "${REPOSITORY}/cache.ignored"
printf 'preserve untracked content\n' > "${REPOSITORY}/local-config.txt"
run_confirmed_finish "${TASK_NAME}" "${TMP}/fast-forward.out"
[[ "$(git -C "${REPOSITORY}" rev-parse HEAD)" == "${task_head}" &&
   "$(< "${REPOSITORY}/task-result.txt")" == 'task result' &&
   "$(< "${REPOSITORY}/cache.ignored")" == 'preserve ignored content' &&
   "$(< "${REPOSITORY}/local-config.txt")" == 'preserve untracked content' ]] \
    || fail "finish did not preserve unrelated target-local content"
if git -C "${REPOSITORY}" show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    fail "fast-forward finish retained the task branch"
fi

setup_case ignored-overlap 99999999-9999-4999-8999-999999999999
printf 'task replacement\n' > "${WORKTREE}/cache.ignored"
git -C "${WORKTREE}" add -f cache.ignored
git -C "${WORKTREE}" commit -qm 'track previously ignored path'
printf 'preserve target ignored content\n' > "${REPOSITORY}/cache.ignored"
if run_confirmed_finish "${TASK_NAME}" "${TMP}/ignored-overlap.out"; then
    fail "ignored target content overlapping task changes was accepted"
fi
grep -F 'refuses target-local content that overlaps task changes' \
    "${TMP}/ignored-overlap.out" >/dev/null \
    || fail "ignored target collision refusal was unclear"
[[ "$(< "${REPOSITORY}/cache.ignored")" == 'preserve target ignored content' &&
   "$(jq -r '.repositories[0].tasks[0].state' "${MACHINE}")" == active &&
   -d "${WORKTREE}" ]] \
    || fail "ignored target collision changed target content or task state"

setup_case parent-overlap bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
mkdir "${WORKTREE}/local-config"
printf 'task content\n' > "${WORKTREE}/local-config/settings"
git -C "${WORKTREE}" add local-config/settings
git -C "${WORKTREE}" commit -qm 'task child path'
printf 'preserve target parent\n' > "${REPOSITORY}/local-config"
if run_confirmed_finish "${TASK_NAME}" "${TMP}/parent-overlap.out"; then
    fail "parent target path overlapping task changes was accepted"
fi
grep -F 'refuses target-local content that overlaps task changes' \
    "${TMP}/parent-overlap.out" >/dev/null || fail "parent collision refusal was unclear"
[[ "$(< "${REPOSITORY}/local-config")" == 'preserve target parent' && -d "${WORKTREE}" ]] \
    || fail "parent target collision changed target content or task state"

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
