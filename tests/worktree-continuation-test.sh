#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/tests/worktree-fixtures.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
REPOSITORY="${TMP}/repository"
DOCKER_LOG="${TMP}/docker.log"
CAPTURE_PREFIX="${TMP}/launch"
COUNT_FILE="${TMP}/count"
ID_A=11111111-1111-4111-8111-111111111111
ID_B=22222222-2222-4222-8222-222222222222

fail() {
    echo "worktree-continuation-test: $*" >&2
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
REPOSITORY_ID="$(register_worktree_repository_fixture "${ROOT}" "${HOME_DIR}" "${REPOSITORY}")"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create review --from default >/dev/null
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create empty --from default >/dev/null
MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
REGISTRY="${HOME_DIR}/workspaces/registry.json"
COMMON="${REPOSITORY}/.git"
WORKTREE_ROOT="${HOME_DIR}/worktrees/${REPOSITORY_ID}"
PATH_A="${WORKTREE_ROOT}/${ID_A}"
PATH_B="${WORKTREE_ROOT}/${ID_B}"
mkdir -p "${WORKTREE_ROOT}"
chmod 0700 "${HOME_DIR}/worktrees" "${WORKTREE_ROOT}"
git -C "${REPOSITORY}" worktree add -q -b "pi-run/${ID_A}" "${PATH_A}" main
git -C "${REPOSITORY}" worktree add -q -b "pi-run/${ID_B}" "${PATH_B}" main

publish_fixture() {
    local id="$1" path="$2"
    TEST_ROOT="${ROOT}" TEST_HOME="${HOME_DIR}" TEST_REPOSITORY="${REPOSITORY_ID}" \
        TEST_ID="${id}" TEST_PATH="${path}" bash -ceu '
            fail() { echo "pi-run: $*" >&2; exit 1; }
            PI_RUN_HOME_RESOLVED="${TEST_HOME}"
            source "${TEST_ROOT}/lib/pi-run/workspaces.sh"
            publish_managed_worktree_metadata \
                "${TEST_ID}" "${TEST_REPOSITORY}" "pi-run/${TEST_ID}" "${TEST_PATH}" >/dev/null
        '
}
publish_fixture "${ID_A}" "${PATH_A}"
publish_fixture "${ID_B}" "${PATH_B}"

create_session() {
    local profile="$1" id="$2" name="$3" epoch="$4" directory
    directory="${HOME_DIR}/profiles/${profile}/sessions/${id}"
    mkdir -p "${directory}"
    printf '{"type":"session","id":"%s","timestamp":"2026-10-20T12:00:00Z","cwd":"/workspace","version":1}\n' \
        "${name}" > "${directory}/${name}.jsonl"
    touch -d "@${epoch}" "${directory}/${name}.jsonl"
}
create_session default "${ID_A}" session-a 100
create_session default "${ID_B}" session-b 200
create_session review "${ID_A}" session-review 300

run_pi() {
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        PI_RUN_IMAGE=ghcr.io/aprilsoftware/pi-run:0.0.0-test \
        DOCKER_LOG="${DOCKER_LOG}" COUNT_FILE="${COUNT_FILE}" CAPTURE_PREFIX="${CAPTURE_PREFIX}" \
        "${ROOT}/bin/pi-run" "$@"
}

metadata_before="$(sha256sum "${MACHINE}" "${REGISTRY}")"
git_before="$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)"
run_pi --worktree "${REPOSITORY}" -c >/dev/null 2>"${TMP}/continue.err"
[[ "$(< "${COUNT_FILE}")" == 1 ]] || fail "managed continuation did not launch Pi once"
grep -F "workspace=${PATH_B}" "${CAPTURE_PREFIX}.1" >/dev/null \
    || fail "-c did not select the newest managed workspace"
grep -F "common=${COMMON}" "${CAPTURE_PREFIX}.1" >/dev/null \
    || fail "managed continuation did not mount common Git metadata"
grep -F "pointer-content=gitdir: /run/pi-run-git/common/worktrees/${ID_B}" "${CAPTURE_PREFIX}.1" >/dev/null \
    || fail "managed continuation generated the wrong .git pointer"
grep -F -- "--session-dir /profile/sessions/${ID_B}" "${CAPTURE_PREFIX}.1" >/dev/null \
    || fail "managed continuation selected the wrong session directory"
grep -F -- '-c' "${CAPTURE_PREFIX}.1" >/dev/null || fail "-c was not preserved for Pi"
grep -F "managed-worktree workspace-id=${ID_B}" "${TMP}/continue.err" >/dev/null \
    || fail "managed continuation did not report the selected workspace"
LOCK_B="$(grep '^lock=' "${CAPTURE_PREFIX}.1" | cut -d= -f2-)"
POINTER_B="$(grep '^pointer=' "${CAPTURE_PREFIX}.1" | cut -d= -f2-)"
[[ ! -e "${LOCK_B}" && ! -e "${POINTER_B}" ]] \
    || fail "managed continuation did not clean up its lock or pointer"
[[ "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before}" &&
   "$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)" == "${git_before}" ]] \
    || fail "managed continuation changed metadata or Git worktrees"

touch -d @400 "${HOME_DIR}/profiles/default/sessions/${ID_A}/session-a.jsonl"
run_pi --worktree "${REPOSITORY}" -r >/dev/null 2>"${TMP}/resume.err"
grep -F "workspace=${PATH_A}" "${CAPTURE_PREFIX}.2" >/dev/null \
    || fail "-r did not select the newest managed workspace"
grep -F -- '-r' "${CAPTURE_PREFIX}.2" >/dev/null || fail "-r was not preserved for Pi"

run_pi --profile review --worktree "${REPOSITORY}" -c >/dev/null 2>"${TMP}/profile.err"
grep -F "workspace=${PATH_A}" "${CAPTURE_PREFIX}.3" >/dev/null \
    || fail "managed continuation did not filter by profile"
grep -F -- "--session-dir /profile/sessions/${ID_A}" "${CAPTURE_PREFIX}.3" >/dev/null \
    || fail "profile-specific session directory was not selected"

count_before="$(< "${COUNT_FILE}")"
metadata_before="$(sha256sum "${MACHINE}" "${REGISTRY}")"
if run_pi --profile empty --worktree "${REPOSITORY}" -c >/dev/null 2>"${TMP}/empty.err"; then
    fail "managed continuation created a workspace without a session candidate"
fi
grep -F 'no managed worktree sessions are available' "${TMP}/empty.err" >/dev/null \
    || fail "no-candidate diagnostic was unclear"
[[ "$(< "${COUNT_FILE}")" == "${count_before}" &&
   "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before}" ]] \
    || fail "no-candidate rejection invoked Docker or changed metadata"

TIE_TIME='2026-10-20 12:00:00.123456789 +0000'
touch -d "${TIE_TIME}" "${HOME_DIR}/profiles/default/sessions/${ID_A}/session-a.jsonl"
touch -d "${TIE_TIME}" "${HOME_DIR}/profiles/default/sessions/${ID_B}/session-b.jsonl"
if run_pi --worktree "${REPOSITORY}" -c >/dev/null 2>"${TMP}/tie.err"; then
    fail "equal latest session times were not rejected"
fi
grep -F 'continuation is ambiguous' "${TMP}/tie.err" >/dev/null \
    || fail "ambiguous-continuation diagnostic was unclear"
[[ "$(< "${COUNT_FILE}")" == "${count_before}" ]] || fail "ambiguous continuation invoked Docker"

# A missing associated worktree is unavailable rather than selected.
git -C "${REPOSITORY}" worktree remove --force "${PATH_B}"
touch -d @500 "${HOME_DIR}/profiles/default/sessions/${ID_A}/session-a.jsonl"
run_pi --worktree "${REPOSITORY}" -c >/dev/null 2>"${TMP}/missing.err"
grep -F "workspace=${PATH_A}" "${CAPTURE_PREFIX}.4" >/dev/null \
    || fail "missing managed worktree was not excluded"
git -C "${REPOSITORY}" worktree add -q "${PATH_B}" "pi-run/${ID_B}"

# Present Git state that conflicts with metadata fails closed.
git -C "${PATH_B}" checkout --detach -q
touch -d @600 "${HOME_DIR}/profiles/default/sessions/${ID_B}/session-b.jsonl"
if run_pi --worktree "${REPOSITORY}" -c >/dev/null 2>"${TMP}/git-state.err"; then
    fail "mismatched managed Git state was accepted"
fi
grep -F 'Git state conflicts with metadata' "${TMP}/git-state.err" >/dev/null \
    || fail "mismatched-Git diagnostic was unclear"
git -C "${PATH_B}" checkout -q "pi-run/${ID_B}"

# An active owner for the selected workspace is enforced by launch routing.
touch -d @700 "${HOME_DIR}/profiles/default/sessions/${ID_A}/session-a.jsonl"
LOCK_DIR="${HOME_DIR}/worktrees/.launch-locks/${ID_A}"
mkdir -p "${LOCK_DIR}"
chmod 0700 "${HOME_DIR}/worktrees/.launch-locks" "${LOCK_DIR}"
START_TOKEN="$(TEST_ROOT="${ROOT}" bash -ceu 'source "${TEST_ROOT}/lib/pi-run/workspaces.sh"; process_start_token "'"$$"'"')"
jq -n --arg machine "$("${ROOT}/bin/pi-run" machine-id)" --argjson pid "$$" --arg start "${START_TOKEN}" \
    --arg workspace "${ID_A}" \
    '{schemaVersion:1,machineId:$machine,pid:$pid,processStartToken:$start,
      ownershipToken:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",workspaceId:$workspace,
      createdAt:"2026-10-20T12:00:00Z"}' > "${LOCK_DIR}/owner.json"
chmod 0600 "${LOCK_DIR}/owner.json"
if run_pi --worktree "${REPOSITORY}" -c >/dev/null 2>"${TMP}/active.err"; then
    fail "managed continuation bypassed an active workspace lock"
fi
grep -F 'already active' "${TMP}/active.err" >/dev/null \
    || fail "active managed continuation diagnostic was unclear"
rm -rf "${LOCK_DIR}"

if run_pi --worktree "${REPOSITORY}" -c -r >/dev/null 2>"${TMP}/selectors.err"; then
    fail "multiple managed continuation selectors were accepted"
fi
grep -F 'exactly one continuation or resume selector' "${TMP}/selectors.err" >/dev/null \
    || fail "multiple-selector diagnostic was unclear"

echo "Managed worktree continuation tests passed"
