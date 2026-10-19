#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
REPOSITORY="${TMP}/source repository"
DOCKER_LOG="${TMP}/docker.log"
MAIN_COUNT_FILE="${TMP}/main-count"
LIVE_DOCKER="${PI_RUN_TEST_REAL_DOCKER:-0}"

fail() {
    echo "worktree-launch-test: $*" >&2
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
            [[ "${FAKE_DOCKER_MODE:-ok}" != materialize-fail ]] || exit 42
            git -C "${workspace}" -c core.hooksPath=/dev/null reset --hard "${base}" >/dev/null
            exit 0
        fi
        count=0
        [[ ! -f "${MAIN_COUNT_FILE:?}" ]] || count="$(< "${MAIN_COUNT_FILE}")"
        count=$((count + 1))
        printf '%s\n' "${count}" > "${MAIN_COUNT_FILE}"
        capture="${MAIN_CAPTURE_PREFIX:?}.${count}"
        {
            printf 'workspace=%s\ncommon=%s\npointer=%s\n' "${workspace}" "${common}" "${pointer}"
            [[ -z "${pointer}" ]] || printf 'pointer-content=%s\n' "$(< "${pointer}")"
            printf 'args='
            printf '%q ' "$@"
            printf '\n'
        } > "${capture}"
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
BASE="$(git -C "${REPOSITORY}" rev-parse HEAD)"
printf 'source-only\n' > "${REPOSITORY}/dirty-untracked"

run_pi() {
    if [[ "${LIVE_DOCKER}" == 1 ]]; then
        PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" "$@"
    else
        PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
            PI_RUN_IMAGE=ghcr.io/aprilsoftware/pi-run:0.0.0-test \
            DOCKER_LOG="${DOCKER_LOG}" MAIN_COUNT_FILE="${MAIN_COUNT_FILE}" \
            MAIN_CAPTURE_PREFIX="${TMP}/main" FAKE_DOCKER_MODE="${FAKE_DOCKER_MODE:-ok}" \
            "${ROOT}/bin/pi-run" "$@"
    fi
}

(
    cd "${TMP}"
    run_pi --worktree "${REPOSITORY}" --version >"${TMP}/launch.out" 2>"${TMP}/launch.err"
)
MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
REPOSITORY_ID="$(jq -r '.repositories[0].id' "${MACHINE}")"
WORKSPACE_ID="$(jq -r '.repositories[0].managedWorkspaces[0].workspaceId' "${MACHINE}")"
BRANCH="pi-run/${WORKSPACE_ID}"
WORKTREE="${HOME_DIR}/worktrees/${REPOSITORY_ID}/${WORKSPACE_ID}"
[[ "${WORKSPACE_ID}" =~ ^[0-9a-f-]{36}$ && -d "${WORKTREE}" ]] \
    || fail "explicit launch did not create a managed workspace"
[[ "$(cat "${WORKTREE}/base.txt")" == base && ! -e "${WORKTREE}/dirty-untracked" ]] \
    || fail "managed launch did not use the committed source state"
[[ -f "${REPOSITORY}/dirty-untracked" && "$(git -C "${REPOSITORY}" branch --show-current)" == main ]] \
    || fail "managed launch changed the source checkout"
[[ "$(git -C "${WORKTREE}" branch --show-current)" == "${BRANCH}" &&
   "$(git -C "${WORKTREE}" rev-parse HEAD)" == "${BASE}" ]] \
    || fail "managed launch used the wrong branch or base"
jq -e --arg repository "${REPOSITORY_ID}" --arg workspace "${WORKSPACE_ID}" --arg path "${WORKTREE}" '
    .repositories[0].id == $repository and .repositories[0].enabled == false and
    .repositories[0].managedWorkspaces[0].workspaceId == $workspace and
    ([.workspacePaths[] | select(.workspaceId == $workspace and .path == $path)] | length) == 1
' "${MACHINE}" >/dev/null || fail "explicit launch published incorrect machine metadata"
jq -e --arg workspace "${WORKSPACE_ID}" '
    [.workspaces[] | select(.id == $workspace and .kind == "git")] | length == 1
' "${HOME_DIR}/workspaces/registry.json" >/dev/null \
    || fail "explicit launch did not publish portable workspace metadata"
[[ -d "${HOME_DIR}/profiles/default/sessions/${WORKSPACE_ID}" ]] \
    || fail "managed launch did not select its own session directory"
for report in \
    "managed-worktree workspace-id=${WORKSPACE_ID}" \
    "managed-worktree branch=${BRANCH} base=${BASE}" \
    "managed-worktree host=${WORKTREE}" \
    'selected checkout has uncommitted changes'; do
    grep -F "${report}" "${TMP}/launch.err" >/dev/null \
        || fail "managed launch omitted startup report: ${report}"
done
status_output="$(cd "${REPOSITORY}" && PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree status)"
[[ "${status_output}" == *'Worktree mode: disabled'* ]] \
    || fail "explicit launch enabled the repository preference"

if [[ "${LIVE_DOCKER}" != 1 ]]; then
    [[ "$(< "${MAIN_COUNT_FILE}")" == 1 ]] || fail "managed launch did not start Pi exactly once"
    CAPTURE="${TMP}/main.1"
    grep -F "workspace=${WORKTREE}" "${CAPTURE}" >/dev/null \
        || fail "managed checkout was not mounted at /workspace"
    COMMON="${REPOSITORY}/.git"
    grep -F "common=${COMMON}" "${CAPTURE}" >/dev/null \
        || fail "common Git metadata was not mounted"
    grep -F "pointer-content=gitdir: /run/pi-run-git/common/worktrees/${WORKSPACE_ID}" "${CAPTURE}" >/dev/null \
        || fail "generated container .git pointer was incorrect"
    POINTER="$(grep '^pointer=' "${CAPTURE}" | cut -d= -f2-)"
    [[ -n "${POINTER}" && ! -e "${POINTER}" && ! -e "$(dirname "${POINTER}")" ]] \
        || fail "managed Git pointer staging was not cleaned up"
    grep -F -- '--version' "${CAPTURE}" >/dev/null \
        || fail "Pi arguments were not preserved"

    managed_count="$(jq -r '.repositories[0].managedWorkspaces | length' "${MACHINE}")"
    worktree_count="$(git -C "${REPOSITORY}" worktree list --porcelain | grep -c '^worktree ')"
    docker_before="$(wc -l < "${DOCKER_LOG}")"
    for resume_argument in -c --continue -r --resume; do
        if run_pi --worktree "${REPOSITORY}" "${resume_argument}" >/dev/null 2>"${TMP}/resume.err"; then
            fail "managed fresh launch accepted ${resume_argument}"
        fi
        grep -F 'creates only fresh sessions' "${TMP}/resume.err" >/dev/null \
            || fail "managed continuation rejection was unclear"
    done
    [[ "$(jq -r '.repositories[0].managedWorkspaces | length' "${MACHINE}")" == "${managed_count}" &&
       "$(git -C "${REPOSITORY}" worktree list --porcelain | grep -c '^worktree ')" == "${worktree_count}" &&
       "$(wc -l < "${DOCKER_LOG}")" == "${docker_before}" ]] \
        || fail "rejected continuation changed Git, metadata, or Docker state"

    run_pi "${REPOSITORY}" --version >/dev/null 2>"${TMP}/direct.err"
    [[ "$(< "${MAIN_COUNT_FILE}")" == 2 ]] || fail "direct launch did not start Pi"
    grep -F "workspace=${REPOSITORY}" "${TMP}/main.2" >/dev/null \
        || fail "launch without --worktree stopped using the direct checkout"
    grep -Fx 'common=' "${TMP}/main.2" >/dev/null \
        || fail "direct launch unexpectedly mounted common Git metadata"

    managed_count="$(jq -r '.repositories[0].managedWorkspaces | length' "${MACHINE}")"
    main_before="$(< "${MAIN_COUNT_FILE}")"
    if FAKE_DOCKER_MODE=materialize-fail run_pi --worktree "${REPOSITORY}" --version \
        >/dev/null 2>"${TMP}/failed-create.err"; then
        fail "failed managed creation launched successfully"
    fi
    [[ "$(< "${MAIN_COUNT_FILE}")" == "${main_before}" &&
       "$(jq -r '.repositories[0].managedWorkspaces | length' "${MACHINE}")" == "${managed_count}" ]] \
        || fail "failed managed creation launched Pi or published metadata"
else
    [[ -s "${TMP}/launch.out" ]] \
        || fail "real-Docker managed launch did not execute Pi --version"
fi

echo "Managed worktree launch tests passed"
