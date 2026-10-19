#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
REPOSITORY="${TMP}/repository"
DOCKER_LOG="${TMP}/docker.log"
CAPTURE_PREFIX="${TMP}/launch"
COUNT_FILE="${TMP}/count"
WORKSPACE_ID=11111111-1111-4111-8111-111111111111

fail() {
    echo "worktree-global-resume-test: $*" >&2
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
workspace_id="${workspace##*/}"
lock="${home}/worktrees/.launch-locks/${workspace_id}/owner.json"
[[ -f "${lock}" ]] || exit 4
count=0
[[ ! -f "${COUNT_FILE:?}" ]] || count="$(< "${COUNT_FILE}")"
count=$((count + 1))
printf '%s\n' "${count}" > "${COUNT_FILE}"
{
    printf 'workspace=%s\ncommon=%s\npointer=%s\nlock=%s\n' \
        "${workspace}" "${common}" "${pointer}" "${lock}"
    printf 'pointer-content=%s\n' "$(< "${pointer}")"
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
(
    cd "${REPOSITORY}"
    PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree enable >/dev/null
)
MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
REGISTRY="${HOME_DIR}/workspaces/registry.json"
REPOSITORY_ID="$(jq -r '.repositories[0].id' "${MACHINE}")"
WORKTREE="${HOME_DIR}/worktrees/${REPOSITORY_ID}/${WORKSPACE_ID}"
BRANCH="pi-run/${WORKSPACE_ID}"
COMMON="${REPOSITORY}/.git"
ADMIN="${COMMON}/worktrees/${WORKSPACE_ID}"
mkdir -p "$(dirname "${WORKTREE}")"
chmod 0700 "${HOME_DIR}/worktrees" "$(dirname "${WORKTREE}")"
git -C "${REPOSITORY}" worktree add -q -b "${BRANCH}" "${WORKTREE}" main
TEST_ROOT="${ROOT}" TEST_HOME="${HOME_DIR}" TEST_REPOSITORY="${REPOSITORY_ID}" \
    TEST_ID="${WORKSPACE_ID}" TEST_PATH="${WORKTREE}" bash -ceu '
        fail() { echo "pi-run: $*" >&2; exit 1; }
        PI_RUN_HOME_RESOLVED="${TEST_HOME}"
        source "${TEST_ROOT}/lib/pi-run/workspaces.sh"
        publish_managed_worktree_metadata \
            "${TEST_ID}" "${TEST_REPOSITORY}" "pi-run/${TEST_ID}" "${TEST_PATH}" >/dev/null
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

metadata_before="$(sha256sum "${MACHINE}" "${REGISTRY}")"
git_before="$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)"
run_pi resume default "${WORKSPACE_ID}" >/dev/null 2>"${TMP}/explicit.err"
[[ "$(< "${COUNT_FILE}")" == 1 ]] || fail "explicit managed global resume did not launch Pi"
grep -F "workspace=${WORKTREE}" "${CAPTURE_PREFIX}.1" >/dev/null \
    || fail "explicit global resume did not mount the managed worktree"
grep -F "common=${COMMON}" "${CAPTURE_PREFIX}.1" >/dev/null \
    || fail "explicit global resume did not mount common Git metadata"
grep -F "pointer-content=gitdir: /run/pi-run-git/common/worktrees/${WORKSPACE_ID}" "${CAPTURE_PREFIX}.1" >/dev/null \
    || fail "explicit global resume generated the wrong .git pointer"
grep -F -- "--session-dir /profile/sessions/${WORKSPACE_ID}" "${CAPTURE_PREFIX}.1" >/dev/null \
    || fail "explicit global resume selected the wrong session directory"
grep -F -- '--resume' "${CAPTURE_PREFIX}.1" >/dev/null || fail "global resume did not preserve --resume for Pi"
grep -F "managed-worktree branch=${BRANCH} head=${HEAD_COMMIT}" "${TMP}/explicit.err" >/dev/null \
    || fail "managed global resume omitted branch and head reporting"
LOCK="$(grep '^lock=' "${CAPTURE_PREFIX}.1" | cut -d= -f2-)"
POINTER="$(grep '^pointer=' "${CAPTURE_PREFIX}.1" | cut -d= -f2-)"
[[ ! -e "${LOCK}" && ! -e "${POINTER}" ]] \
    || fail "managed global resume did not clean up its lock or pointer"
[[ "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before}" &&
   "$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)" == "${git_before}" ]] \
    || fail "managed global resume changed metadata or Git worktrees"

printf -v interactive_command '%q ' env \
    "PATH=${TMP}/fake-bin:${PATH}" "PI_RUN_HOME=${HOME_DIR}" \
    PI_RUN_IMAGE=ghcr.io/aprilsoftware/pi-run:0.0.0-test \
    "DOCKER_LOG=${DOCKER_LOG}" "COUNT_FILE=${COUNT_FILE}" "CAPTURE_PREFIX=${CAPTURE_PREFIX}" \
    "${ROOT}/bin/pi-run" resume
printf '1\n' | script -qefc "${interactive_command}" /dev/null >/dev/null
[[ "$(< "${COUNT_FILE}")" == 2 ]] || fail "interactive managed global resume did not launch Pi"
grep -F "workspace=${WORKTREE}" "${CAPTURE_PREFIX}.2" >/dev/null \
    || fail "interactive global resume did not select the managed worktree"

count_before="$(< "${COUNT_FILE}")"
cp "${MACHINE}" "${TMP}/machine.saved"
mkdir "${TMP}/wrong-path"
jq --arg id "${WORKSPACE_ID}" --arg path "${TMP}/wrong-path" \
    '(.workspacePaths[] | select(.workspaceId == $id) | .path) = $path' \
    "${MACHINE}" > "${MACHINE}.tmp"
mv "${MACHINE}.tmp" "${MACHINE}"
chmod 0600 "${MACHINE}"
if run_pi resume default "${WORKSPACE_ID}" >/dev/null 2>"${TMP}/path.err"; then
    fail "managed global resume accepted a conflicting path mapping"
fi
grep -F 'path conflicts with its workspace identity' "${TMP}/path.err" >/dev/null \
    || fail "managed resume path diagnostic was unclear"
mv "${TMP}/machine.saved" "${MACHINE}"
chmod 0600 "${MACHINE}"

git -C "${WORKTREE}" checkout --detach -q
if run_pi resume default "${WORKSPACE_ID}" >/dev/null 2>"${TMP}/branch.err"; then
    fail "managed global resume accepted a detached worktree"
fi
grep -F 'Git state conflicts with metadata' "${TMP}/branch.err" >/dev/null \
    || fail "managed resume branch diagnostic was unclear"
git -C "${WORKTREE}" checkout -q "${BRANCH}"

mv "${ADMIN}" "${ADMIN}.missing"
if run_pi resume default "${WORKSPACE_ID}" >/dev/null 2>"${TMP}/admin.err"; then
    fail "managed global resume accepted missing Git administration"
fi
grep -F 'Git administration is missing or unsafe' "${TMP}/admin.err" >/dev/null \
    || fail "managed resume administration diagnostic was unclear"
mv "${ADMIN}.missing" "${ADMIN}"

LOCK_DIR="${HOME_DIR}/worktrees/.launch-locks/${WORKSPACE_ID}"
mkdir -p "${LOCK_DIR}"
chmod 0700 "${HOME_DIR}/worktrees/.launch-locks" "${LOCK_DIR}"
START_TOKEN="$(TEST_ROOT="${ROOT}" bash -ceu 'source "${TEST_ROOT}/lib/pi-run/workspaces.sh"; process_start_token "'"$$"'"')"
jq -n --arg machine "$("${ROOT}/bin/pi-run" machine-id)" --argjson pid "$$" --arg start "${START_TOKEN}" \
    --arg workspace "${WORKSPACE_ID}" \
    '{schemaVersion:1,machineId:$machine,pid:$pid,processStartToken:$start,
      ownershipToken:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",workspaceId:$workspace,
      createdAt:"2026-10-20T12:00:00Z"}' > "${LOCK_DIR}/owner.json"
chmod 0600 "${LOCK_DIR}/owner.json"
if run_pi resume default "${WORKSPACE_ID}" >/dev/null 2>"${TMP}/active.err"; then
    fail "managed global resume bypassed an active launch lock"
fi
grep -F 'already active' "${TMP}/active.err" >/dev/null \
    || fail "managed global resume active-lock diagnostic was unclear"
rm -rf "${LOCK_DIR}"

# A known managed association that has lost its checkout is not reconnected as direct.
git -C "${REPOSITORY}" worktree remove --force "${WORKTREE}"
metadata_before="$(sha256sum "${MACHINE}" "${REGISTRY}")"
if run_pi resume default "${WORKSPACE_ID}" >/dev/null 2>"${TMP}/missing.err"; then
    fail "unavailable managed worktree was resumed as an ordinary checkout"
fi
grep -F 'cannot be reconnected as an ordinary checkout' "${TMP}/missing.err" >/dev/null \
    || fail "unavailable managed-worktree diagnostic was unclear"
[[ "$(< "${COUNT_FILE}")" == "${count_before}" &&
   "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before}" ]] \
    || fail "failed managed global resumes invoked Docker or changed metadata"

echo "Managed worktree global resume tests passed"
