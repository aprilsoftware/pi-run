#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap '[[ -z "${ACTIVE_OWNER_PID:-}" ]] || kill "${ACTIVE_OWNER_PID}" 2>/dev/null || true; [[ -z "${ACTIVE_PID:-}" ]] || kill "${ACTIVE_PID}" 2>/dev/null || true; rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
LOCK_ROOT="${HOME_DIR}/worktrees/.launch-locks"
ID_NORMAL=11111111-1111-4111-8111-111111111111
ID_ACTIVE=22222222-2222-4222-8222-222222222222
ID_OTHER=33333333-3333-4333-8333-333333333333
ID_STALE=44444444-4444-4444-8444-444444444444
ID_REUSED=55555555-5555-4555-8555-555555555555
ID_UNSAFE=66666666-6666-4666-8666-666666666666
ID_TOKEN=77777777-7777-4777-8777-777777777777
TOKEN=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa

fail() {
    echo "worktree-lock-test: $*" >&2
    exit 1
}

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
mkdir -p "${HOME_DIR}/worktrees"
chmod 0700 "${HOME_DIR}/worktrees"
MACHINE_ID="$("${ROOT}/bin/pi-run" machine-id)"

run_action() {
    local action="$1" id="$2"
    TEST_ROOT="${ROOT}" TEST_HOME="${HOME_DIR}" TEST_ACTION="${action}" TEST_ID="${id}" \
        bash -ceu '
            fail() { echo "pi-run: $*" >&2; exit 1; }
            PI_RUN_HOME_RESOLVED="${TEST_HOME}"
            source "${TEST_ROOT}/lib/pi-run/workspaces.sh"
            case "${TEST_ACTION}" in
                acquire-release)
                    acquire_managed_launch_lock "${TEST_ID}"
                    directory="${MANAGED_LAUNCH_LOCK_DIR}"
                    test -f "${directory}/owner.json"
                    release_managed_launch_lock
                    test ! -e "${directory}"
                    ;;
                acquire-hold)
                    acquire_managed_launch_lock "${TEST_ID}"
                    printf "%s\n" "${MANAGED_LAUNCH_LOCK_DIR}" > "${TEST_READY}"
                    trap "exit 0" TERM INT
                    trap "release_managed_launch_lock" EXIT
                    while :; do sleep 1; done
                    ;;
                acquire)
                    acquire_managed_launch_lock "${TEST_ID}"
                    printf "%s\n" "${MANAGED_LAUNCH_LOCK_DIR}"
                    ;;
                token-mismatch)
                    acquire_managed_launch_lock "${TEST_ID}"
                    directory="${MANAGED_LAUNCH_LOCK_DIR}"
                    jq ".ownershipToken=\"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb\"" \
                        "${directory}/owner.json" > "${directory}/owner.json.tmp"
                    chmod 0600 "${directory}/owner.json.tmp"
                    mv "${directory}/owner.json.tmp" "${directory}/owner.json"
                    if release_managed_launch_lock; then exit 9; fi
                    test -d "${directory}"
                    printf "%s\n" "${directory}"
                    ;;
            esac
        '
}

create_owner() {
    local id="$1" pid="$2" start="$3" machine="${4:-${MACHINE_ID}}" directory
    directory="${LOCK_ROOT}/${id}"
    mkdir -p "${directory}"
    chmod 0700 "${LOCK_ROOT}" "${directory}"
    jq -n --arg machine "${machine}" --argjson pid "${pid}" --arg start "${start}" \
        --arg token "${TOKEN}" --arg workspace "${id}" \
        '{schemaVersion:1,machineId:$machine,pid:$pid,processStartToken:$start,
          ownershipToken:$token,workspaceId:$workspace,createdAt:"2026-10-20T12:00:00Z"}' \
        > "${directory}/owner.json"
    chmod 0600 "${directory}/owner.json"
}

run_action acquire-release "${ID_NORMAL}"
[[ ! -e "${LOCK_ROOT}/${ID_NORMAL}" ]] || fail "normal release retained its lock"

READY="${TMP}/active-ready"
TEST_READY="${READY}" run_action acquire-hold "${ID_ACTIVE}" &
ACTIVE_PID=$!
for _ in $(seq 1 50); do
    [[ -s "${READY}" ]] && break
    sleep 0.1
done
[[ -s "${READY}" ]] || fail "active fixture did not acquire its lock"
if run_action acquire "${ID_ACTIVE}" >/dev/null 2>"${TMP}/active.err"; then
    fail "second launch acquired an active workspace lock"
fi
grep -F 'already active' "${TMP}/active.err" >/dev/null \
    || fail "active-lock diagnostic was unclear"
run_action acquire-release "${ID_OTHER}"
ACTIVE_OWNER_PID="$(jq -r '.pid' "${LOCK_ROOT}/${ID_ACTIVE}/owner.json")"
kill "${ACTIVE_OWNER_PID}"
wait "${ACTIVE_PID}" 2>/dev/null || true
ACTIVE_OWNER_PID=""
ACTIVE_PID=""
[[ ! -e "${LOCK_ROOT}/${ID_ACTIVE}" ]] || fail "active fixture did not release its lock"

create_owner "${ID_STALE}" 99999999 1
run_action acquire-release "${ID_STALE}"
[[ ! -e "${LOCK_ROOT}/${ID_STALE}" ]] || fail "dead-PID stale lock was not recovered"
create_owner "${ID_REUSED}" "$$" 0
run_action acquire-release "${ID_REUSED}"
[[ ! -e "${LOCK_ROOT}/${ID_REUSED}" ]] || fail "start-token stale lock was not recovered"

expect_unsafe() {
    local label="$1"
    if run_action acquire "${ID_UNSAFE}" >/dev/null 2>"${TMP}/${label}.err"; then
        fail "unsafe lock was accepted: ${label}"
    fi
    grep -E 'unsafe or ambiguous|different machine|cannot be verified' "${TMP}/${label}.err" >/dev/null \
        || fail "unsafe-lock diagnostic was unclear: ${label}"
    rm -rf "${LOCK_ROOT:?}/${ID_UNSAFE}"
}

mkdir -p "${LOCK_ROOT}/${ID_UNSAFE}"
chmod 0700 "${LOCK_ROOT}/${ID_UNSAFE}"
expect_unsafe missing-owner

create_owner "${ID_UNSAFE}" 99999999 1
printf '{invalid\n' > "${LOCK_ROOT}/${ID_UNSAFE}/owner.json"
chmod 0600 "${LOCK_ROOT}/${ID_UNSAFE}/owner.json"
expect_unsafe malformed

create_owner "${ID_UNSAFE}" 99999999 1
mv "${LOCK_ROOT}/${ID_UNSAFE}/owner.json" "${TMP}/outside-owner"
ln -s "${TMP}/outside-owner" "${LOCK_ROOT}/${ID_UNSAFE}/owner.json"
expect_unsafe symlink

create_owner "${ID_UNSAFE}" 99999999 1
ln "${LOCK_ROOT}/${ID_UNSAFE}/owner.json" "${TMP}/owner-hardlink"
expect_unsafe hardlink
rm -f "${TMP}/owner-hardlink"

create_owner "${ID_UNSAFE}" 99999999 1
chmod 0644 "${LOCK_ROOT}/${ID_UNSAFE}/owner.json"
expect_unsafe wrong-mode

create_owner "${ID_UNSAFE}" 99999999 1 0000000000000000
expect_unsafe wrong-machine

create_owner "${ID_UNSAFE}" 99999999 1
touch "${LOCK_ROOT}/${ID_UNSAFE}/extra"
expect_unsafe extra-content

TOKEN_DIRECTORY="$(run_action token-mismatch "${ID_TOKEN}")"
[[ -d "${TOKEN_DIRECTORY}" ]] || fail "ownership-token mismatch removed the lock"
rm -rf "${TOKEN_DIRECTORY}"

[[ -z "$(find "${LOCK_ROOT}" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || fail "lock tests left unexpected lock state"
echo "Managed worktree lock tests passed"
