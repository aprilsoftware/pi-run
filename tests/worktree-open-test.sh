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
HOME_DIR="${TMP}/Pi Run"
REPOSITORY="${TMP}/repository"
DOCKER_LOG="${TMP}/docker.log"
CAPTURE_PREFIX="${TMP}/launch"
COUNT_FILE="${TMP}/count"
WORKSPACE_ID=11111111-1111-4111-8111-111111111111
TASK_NAME=api-refactor

fail() {
    echo "worktree-open-test: $*" >&2
    exit 1
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${DOCKER_LOG:?}"
printf '\n' >> "${DOCKER_LOG}"
[[ "${1:-}" == run ]] || exit 2
shift
workspace=
common=
pointer=
previous=
for argument in "$@"; do
    if [[ "${previous}" == --mount ]]; then
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
    fi
    previous="${argument}"
done
[[ -n "${workspace}" && -n "${common}" && -f "${pointer}" ]] || exit 3
home="${workspace%%/worktrees/*}"
lock="$(find "${home}/worktrees/.launch-locks" -mindepth 2 -maxdepth 2 -name owner.json -print -quit)"
[[ -f "${lock}" ]] || exit 4
count=0
[[ ! -f "${COUNT_FILE:?}" ]] || count="$(< "${COUNT_FILE}")"
count=$((count + 1))
printf '%s\n' "${count}" > "${COUNT_FILE}"
{
    printf 'workspace=%s\ncommon=%s\npointer=%s\n' "${workspace}" "${common}" "${pointer}"
    printf 'args='
    printf '%q ' "$@"
    printf '\n'
} > "${CAPTURE_PREFIX:?}.${count}"
FAKE_DOCKER
chmod 0755 "${TMP}/fake-bin/docker"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
git init -q -b main "${REPOSITORY}"
git -C "${REPOSITORY}" config user.name fixture
git -C "${REPOSITORY}" config user.email fixture@pi-run.invalid
printf 'base\n' > "${REPOSITORY}/base.txt"
git -C "${REPOSITORY}" add base.txt
git -C "${REPOSITORY}" commit -qm base
HEAD_COMMIT="$(git -C "${REPOSITORY}" rev-parse HEAD)"
REPOSITORY_ID="$(register_worktree_repository_fixture "${ROOT}" "${HOME_DIR}" "${REPOSITORY}")"
MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
REGISTRY="${HOME_DIR}/workspaces/registry.json"
WORKTREE="${HOME_DIR}/worktrees/${REPOSITORY_ID}/${TASK_NAME}"
BRANCH="pi-run/${TASK_NAME}"
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
SESSION_DIR="${HOME_DIR}/profiles/default/sessions/${WORKSPACE_ID}"
mkdir -p "${SESSION_DIR}"
printf '{"type":"session","id":"session-a","timestamp":"2026-10-20T12:00:00Z","cwd":"/workspace","version":1}\n' \
    > "${SESSION_DIR}/session-a.jsonl"

run_pi() {
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        PI_RUN_IMAGE=ghcr.io/aprilsoftware/pi-run:0.0.0-test \
        DOCKER_LOG="${DOCKER_LOG}" COUNT_FILE="${COUNT_FILE}" CAPTURE_PREFIX="${CAPTURE_PREFIX}" \
        "${ROOT}/bin/pi-run" "$@"
}

if run_pi worktree open "${TASK_NAME}" >/dev/null 2>"${TMP}/missing-open-path.err"; then
    fail "worktree open accepted a missing repository argument"
fi
grep -F 'Usage:' "${TMP}/missing-open-path.err" >/dev/null \
    || fail "missing worktree-open repository did not show usage"
if run_pi worktree open "${TASK_NAME}" -c >/dev/null 2>"${TMP}/option-open-path.err"; then
    fail "worktree open accepted an option as its repository argument"
fi
grep -F 'Usage:' "${TMP}/option-open-path.err" >/dev/null \
    || fail "option worktree-open repository did not show usage"

metadata_before="$(sha256sum "${MACHINE}" "${REGISTRY}")"
git_before="$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)"
for entry in 'fresh|--version|--version ' 'continue|-c| -c ' 'resume|-r| -r '; do
    IFS='|' read -r label argument expected <<< "${entry}"
    (cd "${TMP}" && run_pi worktree open "${TASK_NAME}" repository "${argument}") \
        >/dev/null 2>"${TMP}/${label}.err"
    count="$(< "${COUNT_FILE}")"
    grep -F "workspace=${WORKTREE}" "${CAPTURE_PREFIX}.${count}" >/dev/null \
        || fail "${label} open did not mount the named task worktree"
    grep -F -- "--session-dir /profile/sessions/${WORKSPACE_ID}" "${CAPTURE_PREFIX}.${count}" >/dev/null \
        || fail "${label} open selected the wrong session directory"
    grep -F -- "${expected}" "${CAPTURE_PREFIX}.${count}" >/dev/null \
        || fail "${label} open did not preserve its Pi arguments"
    grep -F "profile=default task=${TASK_NAME}" "${TMP}/${label}.err" >/dev/null \
        || fail "${label} open omitted task reporting"
    grep -F "task-head=${HEAD_COMMIT}" "${TMP}/${label}.err" >/dev/null \
        || fail "${label} open omitted current revision reporting"
    for internal in "${WORKSPACE_ID}" "${BRANCH}" "${WORKTREE}"; do
        if grep -F "${internal}" "${TMP}/${label}.err" >/dev/null; then
            fail "${label} open exposed internal identity: ${internal}"
        fi
    done
done
[[ "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before}" &&
   "$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)" == "${git_before}" ]] \
    || fail "opening a task changed metadata or Git worktrees"

count_before="$(< "${COUNT_FILE}")"
if run_pi worktree open missing-task "${REPOSITORY}" \
    >/dev/null 2>"${TMP}/missing.err"; then
    fail "missing task was opened"
fi
grep -F 'no unique active worktree task is registered with name: missing-task' "${TMP}/missing.err" >/dev/null \
    || fail "missing-task diagnostic was unclear"
if run_pi worktree open "${TASK_NAME}" "${REPOSITORY}" -c -r \
    >/dev/null 2>"${TMP}/selectors.err"; then
    fail "worktree open accepted multiple continuation selectors"
fi
grep -F 'accepts at most one continuation or resume selector' "${TMP}/selectors.err" >/dev/null \
    || fail "multiple-selector diagnostic was unclear"
[[ "$(< "${COUNT_FILE}")" == "${count_before}" ]] \
    || fail "rejected task opens started Docker"

cp "${MACHINE}" "${TMP}/machine.saved"
mkdir "${TMP}/wrong-path"
jq --arg id "${WORKSPACE_ID}" --arg path "${TMP}/wrong-path" \
    '(.workspacePaths[] | select(.workspaceId == $id) | .path) = $path' \
    "${MACHINE}" > "${MACHINE}.tmp"
mv "${MACHINE}.tmp" "${MACHINE}"
chmod 0600 "${MACHINE}"
if run_pi worktree open "${TASK_NAME}" "${REPOSITORY}" \
    >/dev/null 2>"${TMP}/path.err"; then
    fail "task with a conflicting path mapping was opened"
fi
grep -F 'path conflicts with its workspace identity' "${TMP}/path.err" >/dev/null \
    || fail "conflicting-path diagnostic was unclear"
mv "${TMP}/machine.saved" "${MACHINE}"
chmod 0600 "${MACHINE}"
[[ "$(< "${COUNT_FILE}")" == "${count_before}" ]] \
    || fail "conflicting task state started Docker"

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
if run_pi worktree open "${TASK_NAME}" "${REPOSITORY}" \
    >/dev/null 2>"${TMP}/active.err"; then
    fail "active task was opened concurrently"
fi
grep -F 'managed workspace is already active' "${TMP}/active.err" >/dev/null \
    || fail "active-task diagnostic was unclear"
kill "${ACTIVE_PID}"
wait "${ACTIVE_PID}" 2>/dev/null || true
ACTIVE_PID=""
rm "${LOCK_DIR}/owner.json"
rmdir "${LOCK_DIR}"
[[ "$(< "${COUNT_FILE}")" == "${count_before}" ]] \
    || fail "active-task refusal started Docker"

echo "Named worktree task open tests passed"
