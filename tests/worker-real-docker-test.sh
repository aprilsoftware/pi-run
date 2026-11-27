#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${PI_RUN_TEST_REAL_DOCKER:-0}" != 1 ]]; then
    echo 'worker-real-docker-test: SKIP (requires approved non-root host execution and a local candidate core image)'
    exit 0
fi
: "${PI_RUN_WORKER_TEST_CORE:?Set a local candidate core image built from this source}"
for command in docker bash jq git timeout; do command -v "${command}" >/dev/null; done
[[ "$(id -u)" != 0 && "$(id -g)" != 0 ]] || { echo 'Run as non-root on the Docker host' >&2; exit 1; }
TEST_TIMEOUT="${PI_RUN_WORKER_TEST_TIMEOUT_SECONDS:-90}"
if [[ ! "${TEST_TIMEOUT}" =~ ^[1-9][0-9]{0,2}$ ]] || (( TEST_TIMEOUT > 300 )); then
    echo 'PI_RUN_WORKER_TEST_TIMEOUT_SECONDS must be an integer from 1 to 300' >&2
    exit 1
fi
docker image inspect "${PI_RUN_WORKER_TEST_CORE}" >/dev/null
TMP="$(mktemp -d)"
PREPARED_TAG=""
cleanup() {
    local status=$?
    if (( status != 0 )); then
        # Failed/uncertain cleanup must not remove data still mounted by Docker.
        printf 'worker-real-docker-test: FAIL (exit %s); retained fixtures at %s and prepared image %s for inspection\n' \
            "${status}" "${TMP}" "${PREPARED_TAG:-not recorded}" >&2
        return
    fi
    [[ -z "${PREPARED_TAG}" ]] || docker image rm "${PREPARED_TAG}" >/dev/null 2>&1 || true
    rm -rf -- "${TMP}"
}
trap cleanup EXIT
export PI_RUN_HOME="${TMP}/home" PI_RUN_CORE_IMAGE="${PI_RUN_WORKER_TEST_CORE}" PI_RUN_IMAGE="${PI_RUN_WORKER_TEST_CORE}"
mkdir -p "${TMP}/repository"
git -C "${TMP}/repository" init -q -b main
git -C "${TMP}/repository" -c user.name=fixture -c user.email=fixture@example.invalid commit --allow-empty -qm fixture
"${ROOT}/bin/pi-run" init >/dev/null
"${ROOT}/bin/pi-run" network mode offline >/dev/null
# Explicit disposable build; launch itself never builds/pulls/falls back.
"${ROOT}/bin/pi-run" runtime build
PREPARED_TAG="$("${ROOT}/bin/pi-run" runtime status | awk '/^Prepared tag:/ {print $3}')"
"${ROOT}/bin/pi-run" worktree create worker-fixture "${TMP}/repository" --json > "${TMP}/worktree.json"
printf 'Offline Worker transport acceptance; no model work is requested.\n' > "${TMP}/role.txt"
# Bound the controller and its entire child process group, including Docker
# queries and wait after stdout closes. Allow the launcher time to handle TERM.
# This client needs only host Bash/jq; Node remains inside the candidate image.
timeout --kill-after=15s "${TEST_TIMEOUT}s" bash -s -- "${ROOT}" "${TMP}" <<'BASH'
set -euo pipefail
ROOT=$1 TMP=$2
fail() { printf 'worker-real-docker-test: %s\n' "$*" >&2; exit 1; }
PID="" INPUT="" OUTPUT=""
cleanup_worker() {
    local status=$?
    trap - EXIT
    [[ -z "${INPUT}" ]] || exec {INPUT}>&-
    if [[ -n "${PID}" ]]; then
        # Only signal our still-running child, not a recycled PID.
        case $'\n'$(jobs -pr)$'\n' in
            *$'\n'"${PID}"$'\n'*) kill -TERM "${PID}" 2>/dev/null || true ;;
        esac
        wait "${PID}" 2>/dev/null || true
    fi
    [[ -z "${OUTPUT}" ]] || exec {OUTPUT}<&-
    exit "${status}"
}
trap cleanup_worker EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
WORKTREE="$(jq -er '.path | strings | select(startswith("/"))' "${TMP}/worktree.json")"
WORKSPACE_ID="$(jq -er '.workspaceId | strings' "${TMP}/worktree.json")"
[[ "${WORKSPACE_ID}" =~ ^[0-9a-f-]{36}$ ]] || fail 'Invalid workspace identity'
coproc WORKER { exec "${ROOT}/bin/pi-run" worker launch "${WORKTREE}" --role-file "${TMP}/role.txt"; }
PID=${WORKER_PID}
CONTAINER="pi-default-${PID}"
# Bash may unset/close its original coprocess descriptors when the child exits.
# Keep stable duplicates, but close BOTH writer copies before expecting EOF.
ORIGINAL_INPUT=${WORKER[1]} ORIGINAL_OUTPUT=${WORKER[0]}
exec {INPUT}>&"${ORIGINAL_INPUT}" {OUTPUT}<&"${ORIGINAL_OUTPUT}"
exec {ORIGINAL_INPUT}>&- {ORIGINAL_OUTPUT}<&-
READY=false
LINE=""
while IFS= read -r LINE <&"${OUTPUT}"; do
    jq -e 'type == "object" and (.type | type == "string")' <<<"${LINE}" >/dev/null \
        || fail 'Invalid JSONL record from Worker'
    [[ "$(jq -r '.type' <<<"${LINE}")" == pi_run_worker_ready ]] || continue
    [[ "${READY}" == false ]] || fail 'Duplicate readiness record'
    READY=true
    DETAILS="$(docker inspect "${CONTAINER}")"
    jq -e '
        length == 1 and
        (.[0] | .Config.Tty == false and .HostConfig.NetworkMode == "none" and
         ([.Mounts[] | select(.Destination == "/run/pi-run-role.txt")] |
          length == 1 and .[0].RW == false) and
         all(.Mounts[]; .Destination | contains("docker.sock") | not))
    ' <<<"${DETAILS}" >/dev/null || fail 'Unexpected TTY, network, Role mount, or Docker socket mount'
    docker exec --user "$(id -u)" "${CONTAINER}" sh -c \
        'test ! -w /run/pi-run-role.txt && test -d /knowledge' \
        || fail 'Role permissions or knowledge initialization check failed'
    # Connection loss, not successful shutdown: must terminate with status 74.
    exec {INPUT}>&-
    INPUT=""
done
[[ -z "${LINE}" ]] || fail 'Incomplete JSONL record from Worker'
[[ "${READY}" == true ]] || fail 'Worker exited before readiness'
STATUS=0
wait "${PID}" || STATUS=$?
PID=""
[[ "${STATUS}" == 74 ]] || fail "Expected connection-loss exit 74, got ${STATUS}"
[[ ! -e "${PI_RUN_HOME}/worktrees/.launch-locks/${WORKSPACE_ID}" ]] || fail 'Workspace lock was retained'
# A failed inspect could mean Docker is unavailable, not that cleanup succeeded.
# Require a successful daemon query showing no matching running/stopped container.
REMAINING="$(docker ps -aq --filter "name=^/${CONTAINER}$")" || fail 'Cannot verify container cleanup'
[[ -z "${REMAINING}" ]] || fail 'Worker container was retained'
printf '%s\n' 'worker-real-docker-test: PASS (offline readiness, mount, knowledge, connection-loss and cleanup checks; no model calls)'
BASH
