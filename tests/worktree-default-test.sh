#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
REPOSITORY="${TMP}/repository"
NON_GIT="${TMP}/ordinary directory"
DOCKER_LOG="${TMP}/docker.log"
COUNT_FILE="${TMP}/count"
CAPTURE_PREFIX="${TMP}/launch"

fail() {
    echo "worktree-default-test: $*" >&2
    exit 1
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${DOCKER_LOG:?}"
printf '\n' >> "${DOCKER_LOG}"
case "${1:-}" in
    image)
        [[ "${2:-}" == inspect ]]
        ;;
    run)
        shift
        materialize=false
        workspace=
        common=
        pointer=
        base=
        previous=
        for argument in "$@"; do
            if [[ "${previous}" == --entrypoint && "${argument}" == bash ]]; then
                materialize=true
            elif [[ "${previous}" == --mount ]]; then
                case "${argument}" in
                    type=bind,src=*,dst=/workspace)
                        workspace="${argument#*src=}"
                        workspace="${workspace%,dst=*}"
                        ;;
                    type=bind,src=*,dst=/run/pi-run-git/common)
                        common="${argument#*src=}"
                        common="${common%,dst=*}"
                        ;;
                    type=bind,src=*,dst=/workspace/.git,readonly)
                        pointer="${argument#*src=}"
                        pointer="${pointer%,dst=*}"
                        ;;
                esac
            elif [[ "${previous}" == --env && "${argument}" == PI_RUN_WORKTREE_BASE=* ]]; then
                base="${argument#*=}"
            fi
            previous="${argument}"
        done
        [[ -n "${workspace}" ]] || exit 2
        if [[ "${materialize}" == true ]]; then
            [[ -n "${base}" ]] || exit 2
            [[ "${MATERIALIZE_FAIL:-0}" != 1 ]] || exit 1
            git -C "${workspace}" -c core.hooksPath=/dev/null reset --hard "${base}" >/dev/null
            exit 0
        fi
        count=0
        [[ ! -f "${COUNT_FILE:?}" ]] || count="$(< "${COUNT_FILE}")"
        count=$((count + 1))
        printf '%s\n' "${count}" > "${COUNT_FILE}"
        if [[ -n "${pointer}" ]]; then
            [[ -f "${pointer}" && -n "${common}" ]] || exit 3
            home="${workspace%%/worktrees/*}"
            lock="$(find "${home}/worktrees/.launch-locks" -mindepth 2 -maxdepth 2 -name owner.json -print -quit)"
            [[ -f "${lock}" ]] || exit 4
        fi
        {
            printf 'workspace=%s\ncommon=%s\npointer=%s\n' "${workspace}" "${common}" "${pointer}"
            printf 'args='
            printf '%q ' "$@"
            printf '\n'
        } > "${CAPTURE_PREFIX:?}.${count}"
        ;;
    rm) ;;
    *) exit 2 ;;
esac
FAKE_DOCKER
chmod 0755 "${TMP}/fake-bin/docker"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
git init -q -b main "${REPOSITORY}"
git -C "${REPOSITORY}" config user.name fixture
git -C "${REPOSITORY}" config user.email fixture@pi-run.invalid
printf 'base\n' > "${REPOSITORY}/base.txt"
git -C "${REPOSITORY}" add base.txt
git -C "${REPOSITORY}" commit -qm base
mkdir "${NON_GIT}"
MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
REGISTRY="${HOME_DIR}/workspaces/registry.json"

run_pi() {
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        PI_RUN_IMAGE=ghcr.io/aprilsoftware/pi-run:0.0.0-test \
        DOCKER_LOG="${DOCKER_LOG}" COUNT_FILE="${COUNT_FILE}" CAPTURE_PREFIX="${CAPTURE_PREFIX}" \
        "${ROOT}/bin/pi-run" "$@"
}

if run_pi worktree start missing-path >/dev/null 2>"${TMP}/missing-start-path.err"; then
    fail "worktree start accepted a missing repository argument"
fi
grep -F 'Usage:' "${TMP}/missing-start-path.err" >/dev/null \
    || fail "missing worktree-start repository did not show usage"
if run_pi worktree start option-path -c >/dev/null 2>"${TMP}/option-start-path.err"; then
    fail "worktree start accepted an option as its repository argument"
fi
grep -F 'Usage:' "${TMP}/option-start-path.err" >/dev/null \
    || fail "option worktree-start repository did not show usage"
if run_pi worktree start absent-path "${TMP}/missing repository" \
    >/dev/null 2>"${TMP}/absent-start-path.err"; then
    fail "worktree start accepted a missing repository directory"
fi
grep -F 'workspace does not exist' "${TMP}/absent-start-path.err" >/dev/null \
    || fail "missing worktree-start repository directory diagnostic was unclear"

run_pi "${REPOSITORY}" --version >/dev/null 2>"${TMP}/unregistered.err"
grep -F "workspace=${REPOSITORY}" "${CAPTURE_PREFIX}.1" >/dev/null \
    || fail "unregistered repository did not preserve direct launch behavior"
[[ "$(jq -r '.schemaVersion' "${MACHINE}")" == 1 ]] \
    || fail "ordinary direct launch migrated schema-v1 machine metadata"
DIRECT_ID="$(jq -r --arg path "${REPOSITORY}" '.workspacePaths[] | select(.path == $path) | .workspaceId' "${MACHINE}")"

DIRECT_SESSION_DIR="${HOME_DIR}/profiles/default/sessions/${DIRECT_ID}"
mkdir -p "${DIRECT_SESSION_DIR}"
printf '{"type":"session","id":"direct","timestamp":"2026-10-20T12:00:00Z","cwd":"/workspace","version":1}\n' \
    > "${DIRECT_SESSION_DIR}/direct.jsonl"
run_pi "${REPOSITORY}" -c >/dev/null 2>"${TMP}/direct-continue.err"
grep -F "workspace=${REPOSITORY}" "${CAPTURE_PREFIX}.2" >/dev/null \
    || fail "ordinary continuation stopped using the direct checkout"
grep -F -- '-c' "${CAPTURE_PREFIX}.2" >/dev/null || fail "direct continuation did not preserve -c"
run_pi "${REPOSITORY}" -r >/dev/null 2>"${TMP}/direct-resume.err"
grep -F "workspace=${REPOSITORY}" "${CAPTURE_PREFIX}.3" >/dev/null \
    || fail "ordinary resume stopped using the direct checkout"

run_pi worktree start first-task "${REPOSITORY}" -- --version \
    >/dev/null 2>"${TMP}/first-task.err"
REPOSITORY_ID="$(jq -r '.repositories[0].id' "${MACHINE}")"
MANAGED_ID="$(jq -r '.repositories[0].tasks[0].workspaceId' "${MACHINE}")"
MANAGED_PATH="${HOME_DIR}/worktrees/${REPOSITORY_ID}/first-task"
grep -F "workspace=${MANAGED_PATH}" "${CAPTURE_PREFIX}.4" >/dev/null \
    || fail "worktree start did not create a managed task workspace"
grep -F 'profile=default task=first-task' "${TMP}/first-task.err" >/dev/null \
    || fail "worktree start did not report the task name"
grep -F "task-base=$(git -C "${MANAGED_PATH}" rev-parse HEAD)" "${TMP}/first-task.err" >/dev/null \
    || fail "worktree start did not report the task base"
for internal in "${REPOSITORY_ID}" "${MANAGED_ID}" "${MANAGED_PATH}"; do
    if grep -F "${internal}" "${TMP}/first-task.err" >/dev/null; then
        fail "worktree start exposed internal identity: ${internal}"
    fi
done

run_pi "${REPOSITORY}" --version >/dev/null 2>"${TMP}/direct-after-task.err"
grep -F "workspace=${REPOSITORY}" "${CAPTURE_PREFIX}.5" >/dev/null \
    || fail "ordinary launch stopped using the direct checkout"

(cd "${TMP}" && run_pi worktree start second-task repository --version) \
    >/dev/null 2>"${TMP}/second-task.err"
[[ "$(jq -r '.repositories[0].tasks | length' "${MACHINE}")" == 2 ]] \
    || fail "second named task was not published"
SECOND_ID="$(jq -r '.repositories[0].tasks[] | select(.name == "second-task") | .workspaceId' "${MACHINE}")"
SECOND_PATH="${HOME_DIR}/worktrees/${REPOSITORY_ID}/second-task"
grep -F -- '--version' "${CAPTURE_PREFIX}.6" >/dev/null \
    || fail "worktree start did not forward a direct Pi argument"

metadata_before="$(sha256sum "${MACHINE}" "${REGISTRY}")"
git_before="$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)"
main_count_before="$(< "${COUNT_FILE}")"
if run_pi worktree start first-task "${REPOSITORY}" -- --version \
    >/dev/null 2>"${TMP}/duplicate.err"; then
    fail "duplicate task name was accepted"
fi
grep -F 'worktree task already exists' "${TMP}/duplicate.err" >/dev/null \
    || fail "duplicate-task diagnostic was unclear"
[[ "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before}" &&
   "$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)" == "${git_before}" &&
   "$(< "${COUNT_FILE}")" == "${main_count_before}" ]] \
    || fail "duplicate task changed metadata, Git state, or launched Pi"

for invalid_name in Uppercase bad/name "$(printf 'a%.0s' {1..64})"; do
    if run_pi worktree start "${invalid_name}" "${REPOSITORY}" \
        >/dev/null 2>"${TMP}/invalid-name.err"; then
        fail "invalid task name was accepted: ${invalid_name}"
    fi
    grep -F 'worktree task name must' "${TMP}/invalid-name.err" >/dev/null \
        || fail "invalid-task-name diagnostic was unclear"
done

if run_pi worktree start third-task "${REPOSITORY}" -c \
    >/dev/null 2>"${TMP}/selector.err"; then
    fail "new worktree task accepted a continuation selector"
fi
grep -F 'new worktree task has no previous conversation' "${TMP}/selector.err" >/dev/null \
    || fail "new-task continuation diagnostic was unclear"
[[ "$(jq -r '[.repositories[].tasks[] | select(.name == "third-task")] | length' "${MACHINE}")" == 0 ]] \
    || fail "refused new-task continuation published task metadata"

archive_task() {
    local task_name="$1" workspace_id="$2" path="$3"
    git -C "${REPOSITORY}" worktree remove "${path}"
    git -C "${REPOSITORY}" branch -d "pi-run/${task_name}" >/dev/null
    jq --arg id "${workspace_id}" '
        del(.workspacePaths[] | select(.workspaceId == $id)) |
        (.repositories[].tasks[] | select(.workspaceId == $id)) |=
            (.state = "finished" | .finishedAt = "2026-10-22T16:00:00Z")
    ' "${MACHINE}" > "${MACHINE}.tmp"
    mv "${MACHINE}.tmp" "${MACHINE}"
    chmod 0600 "${MACHINE}"
}

archive_task second-task "${SECOND_ID}" "${SECOND_PATH}"
metadata_before="$(sha256sum "${MACHINE}" "${REGISTRY}")"
if MATERIALIZE_FAIL=1 run_pi worktree start second-task "${REPOSITORY}" --version \
    >/dev/null 2>"${TMP}/restart-failure.err"; then
    fail "failed finished-task recreation was accepted"
fi
grep -F 'materialization failed and its empty state was rolled back' \
    "${TMP}/restart-failure.err" >/dev/null || fail "restart rollback diagnostic was unclear"
[[ "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before}" &&
   ! -e "${SECOND_PATH}" &&
   ! -e "${REPOSITORY}/.git/worktrees/second-task" ]] \
    || fail "failed recreation changed archived metadata or left worktree state"
if git -C "${REPOSITORY}" show-ref --verify --quiet refs/heads/pi-run/second-task; then
    fail "failed recreation left its local task branch"
fi

run_pi worktree start second-task "${REPOSITORY}" --version \
    >/dev/null 2>"${TMP}/second-restart.err"
[[ "$(jq -r '.repositories[0].tasks[] | select(.name == "second-task") | .workspaceId' \
        "${MACHINE}")" == "${SECOND_ID}" &&
   "$(jq -r '.repositories[0].tasks[] | select(.name == "second-task") | .state' \
        "${MACHINE}")" == active ]] || fail "finished task did not reactivate its workspace identity"
grep -F 'restarting finished task second-task' "${TMP}/second-restart.err" >/dev/null \
    || fail "finished-task restart was not reported"
grep -F -- '--version' "${CAPTURE_PREFIX}.7" >/dev/null \
    || fail "restarted task did not forward a direct Pi argument"

archive_task first-task "${MANAGED_ID}" "${MANAGED_PATH}"
mkdir -p "${HOME_DIR}/profiles/default/sessions/${MANAGED_ID}"
printf '{"type":"session","id":"managed","timestamp":"2026-10-22T15:00:00Z","cwd":"/workspace","version":1}\n' \
    > "${HOME_DIR}/profiles/default/sessions/${MANAGED_ID}/managed.jsonl"
run_pi worktree start first-task "${REPOSITORY}" -c \
    >/dev/null 2>"${TMP}/first-restart.err"
[[ "$(jq -r '.repositories[0].tasks[] | select(.name == "first-task") | .workspaceId' \
        "${MACHINE}")" == "${MANAGED_ID}" &&
   "$(jq -r '.repositories[0].tasks[] | select(.name == "first-task") | .state' \
        "${MACHINE}")" == active ]] || fail "continued task did not reuse its workspace identity"
grep -F -- '-c' "${CAPTURE_PREFIX}.8" >/dev/null \
    || fail "restarted task did not forward continuation selection"
[[ -f "${HOME_DIR}/profiles/default/sessions/${MANAGED_ID}/managed.jsonl" ]] \
    || fail "restarting a finished task removed its conversation history"

for removed_flag in --worktree --no-worktree; do
    if run_pi "${removed_flag}" "${REPOSITORY}" >/dev/null 2>"${TMP}/removed-flag.err"; then
        fail "removed launcher flag was accepted: ${removed_flag}"
    fi
    grep -F 'unknown launcher option' "${TMP}/removed-flag.err" >/dev/null \
        || fail "removed launcher flag did not report an unknown option"
done

for removed_command in status enable disable; do
    metadata_before="$(sha256sum "${MACHINE}" "${REGISTRY}")"
    git_before="$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)"
    if (cd "${REPOSITORY}" && PI_RUN_HOME="${HOME_DIR}" \
        "${ROOT}/bin/pi-run" worktree "${removed_command}") \
        >"${TMP}/removed-${removed_command}.out" 2>"${TMP}/removed-${removed_command}.err"; then
        fail "removed worktree ${removed_command} command was accepted"
    fi
    grep -F 'Usage:' "${TMP}/removed-${removed_command}.err" >/dev/null \
        || fail "removed worktree ${removed_command} command did not show usage"
    [[ "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before}" &&
       "$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)" == "${git_before}" ]] \
        || fail "removed worktree ${removed_command} command changed metadata or Git state"
done

run_pi "${NON_GIT}" --version >/dev/null 2>"${TMP}/non-git.err"
grep -F "workspace=${NON_GIT}" "${CAPTURE_PREFIX}.9" >/dev/null \
    || fail "non-Git directory did not remain a direct workspace"

echo "Worktree direct-default and task-start tests passed"
