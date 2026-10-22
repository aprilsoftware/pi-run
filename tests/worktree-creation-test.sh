#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/tests/worktree-fixtures.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
REPOSITORY="${TMP}/repository"
DOCKER_LOG="${TMP}/docker.log"
HOOK_MARKER="${TMP}/host-hook-marker"
ID_A=11111111-1111-4111-8111-111111111111
ID_B=22222222-2222-4222-8222-222222222222
ID_COLLISION=33333333-3333-4333-8333-333333333333
ID_PATH=44444444-4444-4444-8444-444444444444
ID_ADMIN=55555555-5555-4555-8555-555555555555
ID_EMPTY=66666666-6666-4666-8666-666666666666
ID_PARTIAL=77777777-7777-4777-8777-777777777777

fail() {
    echo "worktree-creation-test: $*" >&2
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
        worktree=
        base=
        while (( $# > 0 )); do
            case "$1" in
                --mount)
                    case "$2" in
                        type=bind,src=*,dst=/workspace)
                            worktree="${2#*src=}"
                            worktree="${worktree%,dst=*}"
                            ;;
                    esac
                    shift 2
                    ;;
                --env)
                    case "$2" in
                        PI_RUN_WORKTREE_BASE=*) base="${2#*=}" ;;
                    esac
                    shift 2
                    ;;
                *) shift ;;
            esac
        done
        [[ -n "${worktree}" && -n "${base}" ]] || exit 2
        case "${FAKE_DOCKER_MODE:-ok}" in
            ok)
                git -C "${worktree}" -c core.hooksPath=/dev/null reset --hard "${base}" >/dev/null
                ;;
            empty-fail)
                exit 42
                ;;
            partial-fail)
                printf 'partial\n' > "${worktree}/partial.txt"
                exit 43
                ;;
            *) exit 2 ;;
        esac
        ;;
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
cat > "${REPOSITORY}/.git/hooks/post-checkout" <<EOF
#!/bin/sh
printf 'host hook ran\n' > '${HOOK_MARKER}'
EOF
chmod 0755 "${REPOSITORY}/.git/hooks/post-checkout"
REPOSITORY_ID="$(register_worktree_repository_fixture "${ROOT}" "${HOME_DIR}" "${REPOSITORY}")"
MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
BASE="$(git -C "${REPOSITORY}" rev-parse HEAD)"

task_name_for_id() {
    printf 'task-%s\n' "${1%%-*}"
}

branch_for_id() {
    printf 'pi-run/%s\n' "$(task_name_for_id "$1")"
}

path_for_id() {
    printf '%s/worktrees/%s/%s\n' "${HOME_DIR}" "${REPOSITORY_ID}" "$(task_name_for_id "$1")"
}

run_create() {
    local selected="$1" id="$2" mode="${3:-ok}" task_name
    task_name="$(task_name_for_id "${id}")"
    PATH="${TMP}/fake-bin:${PATH}" DOCKER_LOG="${DOCKER_LOG}" FAKE_DOCKER_MODE="${mode}" \
        TEST_ROOT="${ROOT}" TEST_HOME="${HOME_DIR}" TEST_SELECTED="${selected}" TEST_ID="${id}" \
        TEST_TASK_NAME="${task_name}" \
        bash -ceu '
            fail() { echo "pi-run: $*" >&2; exit 1; }
            DEFAULT_IMAGE=ghcr.io/aprilsoftware/pi-run:0.0.0-test
            PI_RUN_HOME_RESOLVED="${TEST_HOME}"
            source "${TEST_ROOT}/lib/pi-run/workspaces.sh"
            cd "${TEST_SELECTED}"
            create_managed_worktree_checkout "${TEST_ID}" "${TEST_TASK_NAME}"
        '
}

cleanup_worktree() {
    local id="$1" path
    path="$(path_for_id "${id}")"
    git -C "${REPOSITORY}" worktree remove --force "${path}" >/dev/null 2>&1 || true
    git -C "${REPOSITORY}" branch -D "$(branch_for_id "${id}")" >/dev/null 2>&1 || true
}

printf 'dirty\n' > "${REPOSITORY}/dirty-untracked"
result="$(run_create "${REPOSITORY}" "${ID_A}" 2>"${TMP}/attached.err")"
IFS=$'\t' read -r workspace_id repository_id branch path base <<< "${result}"
[[ "${workspace_id}" == "${ID_A}" && "${repository_id}" == "${REPOSITORY_ID}" &&
   "${branch}" == "$(branch_for_id "${ID_A}")" && "${base}" == "${BASE}" ]] \
    || fail "creation returned unexpected identities"
[[ "${path}" == "$(path_for_id "${ID_A}")" &&
   "$(cat "${path}/base.txt")" == base ]] || fail "managed checkout was not materialized"
[[ ! -e "${HOOK_MARKER}" ]] || fail "managed checkout executed post-checkout on the host"
grep -F 'has uncommitted changes' "${TMP}/attached.err" >/dev/null \
    || fail "dirty selected checkout was not reported"
jq -e --arg id "${ID_A}" '
    ([.workspacePaths[] | select(.workspaceId == $id)] | length) == 0 and
    ([.repositories[].tasks[] | select(.workspaceId == $id)] | length) == 0
' "${MACHINE}" >/dev/null || fail "creation primitive published machine metadata"
jq -e --arg id "${ID_A}" '[.workspaces[] | select(.id == $id)] | length == 0' \
    "${HOME_DIR}/workspaces/registry.json" >/dev/null \
    || fail "creation primitive published portable metadata"
cleanup_worktree "${ID_A}"

git -C "${REPOSITORY}" checkout --detach -q "${BASE}"
result="$(run_create "${REPOSITORY}" "${ID_B}" 2>/dev/null)"
[[ "${result}" == *$'\t'"$(branch_for_id "${ID_B}")"$'\t'* && "${result}" == *$'\t'"${BASE}" ]] \
    || fail "detached HEAD creation used the wrong branch or base"
cleanup_worktree "${ID_B}"
git -C "${REPOSITORY}" checkout -q main

REGISTRY="${HOME_DIR}/workspaces/registry.json"
jq --arg id "${ID_COLLISION}" \
    '.workspaces += [{id:$id,name:"collision",kind:"git",createdAt:"2026-10-20T12:00:00Z"}]' \
    "${REGISTRY}" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "${REGISTRY}"
chmod 0600 "${REGISTRY}"
if run_create "${REPOSITORY}" "${ID_COLLISION}" >/dev/null 2>"${TMP}/collision.err"; then
    fail "metadata UUID collision was accepted"
fi
grep -F 'already exists in the workspace registry' "${TMP}/collision.err" >/dev/null \
    || fail "metadata collision diagnostic was unclear"
jq --arg id "${ID_COLLISION}" '.workspaces |= map(select(.id != $id))' "${REGISTRY}" > "${REGISTRY}.tmp"
mv "${REGISTRY}.tmp" "${REGISTRY}"
chmod 0600 "${REGISTRY}"

git -C "${REPOSITORY}" branch "$(branch_for_id "${ID_COLLISION}")" "${BASE}"
if run_create "${REPOSITORY}" "${ID_COLLISION}" >/dev/null 2>"${TMP}/branch.err"; then
    fail "branch collision was accepted"
fi
git -C "${REPOSITORY}" branch -D "$(branch_for_id "${ID_COLLISION}")" >/dev/null

mkdir -p "$(path_for_id "${ID_PATH}")"
chmod 0700 "${HOME_DIR}/worktrees" "${HOME_DIR}/worktrees/${REPOSITORY_ID}"
if run_create "${REPOSITORY}" "${ID_PATH}" >/dev/null 2>"${TMP}/path.err"; then
    fail "checkout path collision was accepted"
fi
rm -rf "$(path_for_id "${ID_PATH}")"

mkdir -p "${REPOSITORY}/.git/worktrees/$(task_name_for_id "${ID_ADMIN}")"
if run_create "${REPOSITORY}" "${ID_ADMIN}" >/dev/null 2>"${TMP}/admin.err"; then
    fail "Git administration collision was accepted"
fi
rm -rf "${REPOSITORY}/.git/worktrees/$(task_name_for_id "${ID_ADMIN}")"

if run_create "${REPOSITORY}" "${ID_EMPTY}" empty-fail >/dev/null 2>"${TMP}/empty.err"; then
    fail "empty materialization failure was accepted"
fi
[[ ! -e "$(path_for_id "${ID_EMPTY}")" &&
   ! -e "${REPOSITORY}/.git/worktrees/$(task_name_for_id "${ID_EMPTY}")" ]] \
    || fail "empty failed worktree was not rolled back"
if git -C "${REPOSITORY}" show-ref --verify --quiet "refs/heads/$(branch_for_id "${ID_EMPTY}")"; then
    fail "empty failed branch was not rolled back"
fi
grep -F 'empty state was rolled back' "${TMP}/empty.err" >/dev/null \
    || fail "empty rollback diagnostic was unclear"

if run_create "${REPOSITORY}" "${ID_PARTIAL}" partial-fail >/dev/null 2>"${TMP}/partial.err"; then
    fail "partial materialization failure was accepted"
fi
PARTIAL_PATH="$(path_for_id "${ID_PARTIAL}")"
[[ -f "${PARTIAL_PATH}/partial.txt" &&
   -d "${REPOSITORY}/.git/worktrees/$(task_name_for_id "${ID_PARTIAL}")" ]] \
    || fail "ambiguous partial worktree was not preserved"
git -C "${REPOSITORY}" show-ref --verify --quiet "refs/heads/$(branch_for_id "${ID_PARTIAL}")" \
    || fail "ambiguous partial branch was not preserved"
grep -F 'partial state was preserved' "${TMP}/partial.err" >/dev/null \
    || fail "partial-state diagnostic was unclear"
cleanup_worktree "${ID_PARTIAL}"

for option in '--pull never' '--network none' '--cap-drop ALL' \
    '--security-opt no-new-privileges=true' '--read-only' '--user' \
    '--env HOME=/tmp' '--env GIT_CONFIG_NOSYSTEM=1' '--workdir /workspace'; do
    grep -F -- "${option}" "${DOCKER_LOG}" >/dev/null \
        || fail "creation omitted Docker isolation option: ${option}"
done
grep -F 'ghcr.io/aprilsoftware/pi-run:0.0.0-test' "${DOCKER_LOG}" >/dev/null \
    || fail "creation did not use the selected local runtime image"
grep -F 'core.hooksPath=/dev/null' "${DOCKER_LOG}" >/dev/null \
    || fail "creation did not disable bootstrap hooks"
if grep -E '(^| )(--network host|pull |build |/var/run/docker.sock|/run/docker.sock)' "${DOCKER_LOG}" >/dev/null; then
    fail "creation used a forbidden Docker operation or mount"
fi

UNBORN="${TMP}/unborn"
git init -q -b main "${UNBORN}"
register_worktree_repository_fixture "${ROOT}" "${HOME_DIR}" "${UNBORN}" >/dev/null
if run_create "${UNBORN}" 88888888-8888-4888-8888-888888888888 >/dev/null 2>"${TMP}/unborn.err"; then
    fail "unborn repository was accepted"
fi
grep -F 'does not have a committed HEAD' "${TMP}/unborn.err" >/dev/null \
    || fail "unborn repository diagnostic was unclear"

echo "Managed worktree creation tests passed"
