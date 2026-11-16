#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

TEST_NAME="herdr-real-docker-test"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${PI_RUN_TEST_HERDR:-0}" != 1 || "${PI_RUN_TEST_REAL_DOCKER:-0}" != 1 ]]; then
    echo "${TEST_NAME}: SKIP (set PI_RUN_TEST_HERDR=1, PI_RUN_TEST_REAL_DOCKER=1, and HERDR_BIN)"
    exit 0
fi

fail() {
    echo "${TEST_NAME}: FAIL: $*" >&2
    if [[ -n "${SERVER_LOG:-}" && -f "${SERVER_LOG}" ]]; then
        echo "--- Herdr server log ---" >&2
        tail -80 "${SERVER_LOG}" >&2 || true
    fi
    if [[ -n "${PANE_ID:-}" && -n "${HERDR_BIN:-}" && -x "${HERDR_BIN}" ]]; then
        echo "--- Herdr pane output ---" >&2
        herdr pane read "${PANE_ID}" --source recent-unwrapped --lines 120 \
            >&2 2>/dev/null || true
    fi
    if [[ -n "${CONTAINER_ID:-}" ]]; then
        echo "--- Pi-Run container inspect ---" >&2
        docker inspect "${CONTAINER_ID}" >&2 2>/dev/null || true
    fi
    exit 1
}

for command_name in docker find git jq grep mkfifo mktemp ps script setsid sort stty timeout tr wc; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "required command unavailable: ${command_name}"
done
[[ "$(uname -s)" == Linux && "$(uname -m)" =~ ^(x86_64|amd64)$ ]] \
    || fail "real-Docker Herdr acceptance requires Linux/amd64"
[[ "$(id -u)" != 0 && "$(id -g)" != 0 ]] \
    || fail "real-Docker Herdr acceptance must run as a non-root user"
docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable"

HERDR_BIN="${HERDR_BIN:-}"
[[ -n "${HERDR_BIN}" && -x "${HERDR_BIN}" ]] \
    || fail "HERDR_BIN must name an executable verified Herdr binary"
HERDR_BIN="$(cd "$(dirname "${HERDR_BIN}")" && pwd)/$(basename "${HERDR_BIN}")"
EXPECTED_HERDR_VERSION="${PI_RUN_TEST_HERDR_VERSION:-0.9.5}"
HERDR_VERSION_OUTPUT="$(${HERDR_BIN} --version 2>&1)"
grep -E "(^|[^0-9])${EXPECTED_HERDR_VERSION//./\\.}([^0-9]|$)" \
    <<<"${HERDR_VERSION_OUTPUT}" >/dev/null \
    || fail "expected Herdr ${EXPECTED_HERDR_VERSION}, got: ${HERDR_VERSION_OUTPUT}"

VERSION="$(tr -d '\r\n' < "${ROOT}/VERSION")"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION is invalid"
CORE_IMAGE="${PI_RUN_TEST_CORE_IMAGE:-ghcr.io/aprilsoftware/pi-run:${VERSION}}"
EGRESS_IMAGE="${PI_RUN_TEST_EGRESS_IMAGE:-ghcr.io/aprilsoftware/pi-run-egress:${VERSION}}"
docker image inspect "${CORE_IMAGE}" >/dev/null 2>&1 \
    || fail "selected core image is unavailable locally: ${CORE_IMAGE}"
docker image inspect "${EGRESS_IMAGE}" >/dev/null 2>&1 \
    || fail "selected egress image is unavailable locally: ${EGRESS_IMAGE}"

TMP="$(mktemp -d)"
HOME="${TMP}/home"
XDG_CONFIG_HOME="${TMP}/config"
XDG_STATE_HOME="${TMP}/state"
XDG_CACHE_HOME="${TMP}/cache"
XDG_RUNTIME_DIR="${TMP}/runtime"
PI_RUN_HOME="${TMP}/Pi Run"
WORKSPACE="${TMP}/workspace"
SERVER_LOG="${TMP}/server.log"
SESSION="pi-run-real-docker-$$"
SERVER_PID=""
CONTAINER_ID=""
PANE_ID=""
DIRECT_CONTAINER_ID=""
DIRECT_PANE_ID=""
MANAGED_CONTAINER_ID=""
MANAGED_PANE_ID=""
ACTIVE_WORKSPACE="${WORKSPACE}"
HERDR_SOCKET=""
PREPARED_TAG=""
MACHINE=""
MANAGED_WORKSPACE_ID=""
MANAGED_WORKTREE=""
MANAGED_LOCK=""
SIDECAR_ID=""
CONTROLLER_PID=""
LOSS_CLIENT_PID=""

export HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR

cleanup() {
    local status=$?
    if [[ -n "${CONTROLLER_PID}" ]] && kill -0 "${CONTROLLER_PID}" >/dev/null 2>&1; then
        kill "${CONTROLLER_PID}" >/dev/null 2>&1 || true
        wait "${CONTROLLER_PID}" 2>/dev/null || true
    fi
    if [[ -n "${LOSS_CLIENT_PID}" ]] && kill -0 "${LOSS_CLIENT_PID}" >/dev/null 2>&1; then
        kill -KILL -- "-${LOSS_CLIENT_PID}" >/dev/null 2>&1 || true
        wait "${LOSS_CLIENT_PID}" 2>/dev/null || true
    fi
    if [[ -x "${HERDR_BIN}" ]]; then
        "${HERDR_BIN}" session stop "${SESSION}" --json >/dev/null 2>&1 || true
        "${HERDR_BIN}" session delete "${SESSION}" --json >/dev/null 2>&1 || true
    fi
    for container in "${CONTAINER_ID}" "${DIRECT_CONTAINER_ID}" \
        "${MANAGED_CONTAINER_ID}" "${SIDECAR_ID}"; do
        [[ -z "${container}" ]] || docker rm -f "${container}" >/dev/null 2>&1 || true
    done
    if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
        kill "${SERVER_PID}" >/dev/null 2>&1 || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf "${TMP}"
    exit "${status}"
}
trap cleanup EXIT INT TERM

mkdir -p "${HOME}" "${XDG_CONFIG_HOME}/herdr" "${XDG_STATE_HOME}" \
    "${XDG_CACHE_HOME}" "${XDG_RUNTIME_DIR}" "${WORKSPACE}"
chmod 0700 "${XDG_RUNTIME_DIR}"
cat > "${XDG_CONFIG_HOME}/herdr/config.toml" <<'EOF_CONFIG'
onboarding = false

[update]
manifest_check = false

[terminal]
default_shell = "/bin/bash"
shell_mode = "non_login"
EOF_CONFIG

PI_RUN_HOME="${PI_RUN_HOME}" "${ROOT}/bin/pi-run" init >/dev/null
printf '1\nyes\n' | PI_RUN_HOME="${PI_RUN_HOME}" PI_RUN_IMAGE="${CORE_IMAGE}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null
PI_RUN_HOME="${PI_RUN_HOME}" "${ROOT}/bin/pi-run" network mode offline >/dev/null
runtime_status="$(PI_RUN_HOME="${PI_RUN_HOME}" PI_RUN_CORE_IMAGE="${CORE_IMAGE}" \
    "${ROOT}/bin/pi-run" runtime status)"
if ! grep -Fx 'Prepared state: matching' <<<"${runtime_status}" >/dev/null; then
    printf 'Building disposable minimal profile image from local core...\n'
    PI_RUN_HOME="${PI_RUN_HOME}" PI_RUN_CORE_IMAGE="${CORE_IMAGE}" \
        "${ROOT}/bin/pi-run" runtime build >/dev/null
    runtime_status="$(PI_RUN_HOME="${PI_RUN_HOME}" PI_RUN_CORE_IMAGE="${CORE_IMAGE}" \
        "${ROOT}/bin/pi-run" runtime status)"
fi
PREPARED_TAG="$(sed -n 's/^Prepared tag: //p' <<<"${runtime_status}")"
[[ "${PREPARED_TAG}" =~ ^pi-run-profile:[0-9a-f]{24}$ ]] \
    || fail "runtime status returned an invalid prepared image tag"
grep -Fx 'Prepared state: matching' <<<"${runtime_status}" >/dev/null \
    || fail "prepared profile image is not matching"

git init -q -b main "${WORKSPACE}"
git -C "${WORKSPACE}" config user.name fixture
git -C "${WORKSPACE}" config user.email fixture@pi-run.invalid
printf 'real Docker Herdr acceptance\n' > "${WORKSPACE}/README.txt"
git -C "${WORKSPACE}" add README.txt
git -C "${WORKSPACE}" commit -qm base

herdr() {
    "${HERDR_BIN}" --session "${SESSION}" "$@"
}

wait_until() {
    local description="$1"
    shift
    for _ in $(seq 1 200); do
        if "$@"; then
            return 0
        fi
        sleep 0.1
    done
    fail "timed out waiting for ${description}"
}

server_ready() {
    local status
    status="$(herdr status server --json 2>/dev/null)" || return 1
    jq -e '.status == "running"' <<<"${status}" >/dev/null
}

agent_idle() {
    local agents
    agents="$(herdr agent list 2>/dev/null)" || return 1
    jq -e --arg pane "${PANE_ID}" '
        [.result.agents[] | select(.pane_id == $pane and .agent == "pi" and
            (.agent_status == "idle" or .agent_status == "done") and
            (has("agent_session") | not))] | length == 1
    ' <<<"${agents}" >/dev/null
}

both_agents_idle() {
    local agents
    agents="$(herdr agent list 2>/dev/null)" || return 1
    jq -e --arg direct "${DIRECT_PANE_ID}" --arg managed "${MANAGED_PANE_ID}" \
        --arg cwd "${WORKSPACE}" '
        .result.agents as $agents
        | ([$agents[] | select(.pane_id == $direct)] | length) == 1
        and ([$agents[] | select(.pane_id == $managed)] | length) == 1
        and all($agents[] | select(.pane_id == $direct or .pane_id == $managed);
            .agent == "pi" and .cwd == $cwd and
            (.agent_status == "idle" or .agent_status == "done") and
            (has("agent_session") | not))
    ' <<<"${agents}" >/dev/null
}

frame_size_seen() {
    local output="$1" cols="$2" rows="$3"
    [[ -s "${output}" ]] || return 1
    jq -e -s --argjson cols "${cols}" --argjson rows "${rows}" '
        any(.[]; .type == "terminal.frame" and .width == $cols and .height == $rows)
    ' "${output}" >/dev/null 2>&1
}

run_terminal_attachment() {
    local label="$1" initial_cols="$2" initial_rows="$3"
    local resized_cols="${4:-}" resized_rows="${5:-}"
    local fifo="${TMP}/${label}.input" output="${TMP}/${label}.frames" error="${TMP}/${label}.err"
    local controller_fd
    mkfifo "${fifo}"
    herdr terminal session control "${DIRECT_PANE_ID}" \
        --cols "${initial_cols}" --rows "${initial_rows}" \
        <"${fifo}" >"${output}" 2>"${error}" &
    CONTROLLER_PID=$!
    exec {controller_fd}>"${fifo}"
    wait_until "${label} initial terminal frame" \
        frame_size_seen "${output}" "${initial_cols}" "${initial_rows}"
    if [[ -n "${resized_cols}" ]]; then
        printf '{"type":"terminal.resize","cols":%s,"rows":%s}\n' \
            "${resized_cols}" "${resized_rows}" >&"${controller_fd}"
        wait_until "${label} resized terminal frame" \
            frame_size_seen "${output}" "${resized_cols}" "${resized_rows}"
    fi
    printf '{"type":"terminal.release"}\n' >&"${controller_fd}"
    exec {controller_fd}>&-
    if ! wait "${CONTROLLER_PID}"; then
        cat "${error}" >&2 || true
        fail "${label} terminal controller failed"
    fi
    CONTROLLER_PID=""
}

run_tui_detach() {
    local label="$1" cols="$2" rows="$3"
    local output="${TMP}/${label}.tui" error="${TMP}/${label}.err" command
    printf -v command 'stty cols %q rows %q; exec %q --session %q' \
        "${cols}" "${rows}" "${HERDR_BIN}" "${SESSION}"
    if ! { sleep 1; printf '\002q'; } | \
        timeout 20 script -qefc "${command}" /dev/null >"${output}" 2>"${error}"; then
        cat "${error}" >&2 || true
        fail "${label} full-screen Herdr client did not detach cleanly"
    fi
    [[ -s "${output}" ]] || fail "${label} full-screen Herdr client produced no terminal output"
}

file_nonempty() {
    [[ -s "$1" ]]
}

run_tui_loss() {
    local label="$1" cols="$2" rows="$3"
    local fifo="${TMP}/${label}.input" output="${TMP}/${label}.tui"
    local error="${TMP}/${label}.err" command loss_fd pgid wait_status
    mkfifo "${fifo}"
    printf -v command 'stty cols %q rows %q; exec %q --session %q' \
        "${cols}" "${rows}" "${HERDR_BIN}" "${SESSION}"
    setsid script -qefc "${command}" /dev/null \
        <"${fifo}" >"${output}" 2>"${error}" &
    LOSS_CLIENT_PID=$!
    exec {loss_fd}>"${fifo}"
    wait_until "${label} full-screen client output" file_nonempty "${output}"
    pgid="$(ps -o pgid= -p "${LOSS_CLIENT_PID}" | tr -d '[:space:]')"
    [[ "${pgid}" == "${LOSS_CLIENT_PID}" ]] \
        || fail "${label} client did not start in an isolated process group"
    sleep 1
    kill -KILL -- "-${LOSS_CLIENT_PID}"
    set +e
    wait "${LOSS_CLIENT_PID}"
    wait_status=$?
    set -e
    exec {loss_fd}>&-
    LOSS_CLIENT_PID=""
    (( wait_status != 0 )) || fail "${label} client did not terminate abruptly"
}

find_pi_container() {
    local id inspect match=""
    while IFS= read -r id; do
        [[ -n "${id}" ]] || continue
        inspect="$(docker inspect "${id}" 2>/dev/null)" || continue
        if jq -e --arg workspace "${ACTIVE_WORKSPACE}" '
            any(.[0].Mounts[]; .Source == $workspace and .Destination == "/workspace")
        ' <<<"${inspect}" >/dev/null; then
            [[ -z "${match}" ]] || return 1
            match="${id}"
        fi
    done < <(docker ps -q)
    [[ -n "${match}" ]] || return 1
    CONTAINER_ID="${match}"
}

validate_container_boundary() {
    local label="$1" expected_network="$2" session_mode="${3:-none}" inspect
    inspect="$(docker inspect "${CONTAINER_ID}")"
    jq -e --arg image "${PREPARED_TAG}" --arg network "${expected_network}" \
        --arg session_mode "${session_mode}" '
        .[0].Config.Image == $image and
        (if $network == "container" then
            (.[0].HostConfig.NetworkMode | startswith("container:"))
         else .[0].HostConfig.NetworkMode == $network end) and
        all(.[0].Config.Env[]; startswith("HERDR_") | not) and
        (if $session_mode == "exact" then (.[0].Config.Cmd | index("--session")) != null
         else (.[0].Config.Cmd | index("--session")) == null end) and
        all(.[0].Config.Cmd[]; contains("herdr") | not)
    ' <<<"${inspect}" >/dev/null \
        || fail "${label} container identity, network, environment, or command is unsafe"
    jq -e --arg runtime "${XDG_RUNTIME_DIR}" --arg config "${XDG_CONFIG_HOME}/herdr" \
        --arg state "${XDG_STATE_HOME}/herdr" --arg socket "${HERDR_SOCKET}" '
        all(.[0].Mounts[];
            (.Source | startswith($runtime) | not) and
            (.Source | startswith($config) | not) and
            (.Source | startswith($state) | not) and
            .Source != $socket and .Destination != $socket)
    ' <<<"${inspect}" >/dev/null \
        || fail "${label} container received a Herdr control-plane mount"
    docker exec "${CONTAINER_ID}" sh -c \
        '! env | grep -E "^HERDR_" >/dev/null && ! command -v herdr >/dev/null' \
        || fail "Herdr environment or CLI is available inside the ${label} container"
}

managed_metadata_ready() {
    [[ -f "${MACHINE}" ]] || return 1
    jq -e '[.repositories[0].tasks[] |
        select(.name == "herdr-task" and .state == "active")] | length == 1' \
        "${MACHINE}" >/dev/null 2>&1
}

managed_lock_gone() {
    [[ ! -e "${MANAGED_LOCK}" ]]
}

container_gone() {
    ! docker inspect "${CONTAINER_ID}" >/dev/null 2>&1
}

agent_gone() {
    local agents
    agents="$(herdr agent list 2>/dev/null)" || return 1
    jq -e --arg pane "${PANE_ID}" \
        '[.result.agents[] | select(.pane_id == $pane)] | length == 0' \
        <<<"${agents}" >/dev/null
}

snapshot_restart_reported() {
    local output
    output="$(herdr pane read "${PANE_ID}" --source recent-unwrapped --lines 160 2>/dev/null)" \
        || return 1
    grep -F 'Snapshot status: ready' <<<"${output}" >/dev/null &&
        grep -F 'Reopening Pi session' <<<"${output}" >/dev/null
}

snapshot_restarted_tui_ready() {
    local output count
    output="$(herdr pane read "${PANE_ID}" --source recent-unwrapped --lines 240 2>/dev/null)" \
        || return 1
    count="$(grep -Fc 'Warning: No models available.' <<<"${output}")"
    (( count >= 2 ))
}

printf 'Starting disposable Herdr %s headless server...\n' "${EXPECTED_HERDR_VERSION}"
herdr server >"${SERVER_LOG}" 2>&1 &
SERVER_PID=$!
wait_until "the disposable Herdr server" server_ready
server_status="$(herdr status server --json)"
HERDR_SOCKET="$(jq -er '.socket' <<<"${server_status}")"

workspace_response="$(herdr workspace create --cwd "${WORKSPACE}" --label real-docker --no-focus)"
PANE_ID="$(jq -er '.result.root_pane.pane_id' <<<"${workspace_response}")"
printf -v launch_command \
    'HERDR_AGENT=pi PI_RUN_HOME=%q PI_RUN_CORE_IMAGE=%q PI_RUN_IMAGE=%q exec %q %q' \
    "${PI_RUN_HOME}" "${CORE_IMAGE}" "${CORE_IMAGE}" "${ROOT}/bin/pi-run" "${WORKSPACE}"
herdr pane run "${PANE_ID}" "${launch_command}" >/dev/null

wait_until "the real direct Pi-Run container" find_pi_container
wait_until "direct Pi to become idle in Herdr" agent_idle
validate_container_boundary direct none
DIRECT_CONTAINER_ID="${CONTAINER_ID}"
DIRECT_PANE_ID="${PANE_ID}"

sleep 1
docker inspect "${DIRECT_CONTAINER_ID}" >/dev/null 2>&1 \
    || fail "Pi-Run container did not remain alive without an attached Herdr TUI"
agent_idle || fail "Pi agent did not remain visible on the headless Herdr server"

run_terminal_attachment direct-attach 100 30 132 44
docker inspect "${DIRECT_CONTAINER_ID}" >/dev/null 2>&1 \
    || fail "direct attachment release stopped the Pi-Run container"
agent_idle || fail "direct attachment release stopped Herdr Pi detection"
run_terminal_attachment direct-reattach 90 26
docker inspect "${DIRECT_CONTAINER_ID}" >/dev/null 2>&1 \
    || fail "direct reattachment release stopped the Pi-Run container"
agent_idle || fail "direct reattachment release stopped Herdr Pi detection"

run_tui_detach tui-detach 110 34
docker inspect "${DIRECT_CONTAINER_ID}" >/dev/null 2>&1 \
    || fail "full-screen Herdr detach stopped the Pi-Run container"
agent_idle || fail "full-screen Herdr detach stopped Pi detection"
server_ready || fail "full-screen Herdr detach stopped the server"
run_tui_detach tui-reattach 126 42
docker inspect "${DIRECT_CONTAINER_ID}" >/dev/null 2>&1 \
    || fail "full-screen Herdr reattach stopped the Pi-Run container"
agent_idle || fail "full-screen Herdr reattach stopped Pi detection"
server_ready || fail "full-screen Herdr reattach stopped the server"

MACHINE="${PI_RUN_HOME}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
managed_response="$(herdr workspace create --cwd "${WORKSPACE}" --label managed-worktree --no-focus)"
PANE_ID="$(jq -er '.result.root_pane.pane_id' <<<"${managed_response}")"
printf -v managed_command \
    'HERDR_AGENT=pi PI_RUN_HOME=%q PI_RUN_CORE_IMAGE=%q PI_RUN_IMAGE=%q exec %q worktree start herdr-task %q' \
    "${PI_RUN_HOME}" "${CORE_IMAGE}" "${CORE_IMAGE}" "${ROOT}/bin/pi-run" "${WORKSPACE}"
herdr pane run "${PANE_ID}" "${managed_command}" >/dev/null

wait_until "managed worktree metadata" managed_metadata_ready
repository_id="$(jq -er '.repositories[0].id' "${MACHINE}")"
MANAGED_WORKSPACE_ID="$(jq -er '.repositories[0].tasks[] |
    select(.name == "herdr-task") | .workspaceId' "${MACHINE}")"
MANAGED_WORKTREE="${PI_RUN_HOME}/worktrees/${repository_id}/herdr-task"
MANAGED_LOCK="${PI_RUN_HOME}/worktrees/.launch-locks/${MANAGED_WORKSPACE_ID}/owner.json"
ACTIVE_WORKSPACE="${MANAGED_WORKTREE}"
wait_until "the real managed Pi-Run container" find_pi_container
wait_until "managed Pi to become idle in Herdr" agent_idle
MANAGED_CONTAINER_ID="${CONTAINER_ID}"
MANAGED_PANE_ID="${PANE_ID}"
[[ "${DIRECT_CONTAINER_ID}" != "${MANAGED_CONTAINER_ID}" ]] \
    || fail "direct and managed launches resolved to the same container"
[[ -f "${MANAGED_LOCK}" ]] || fail "managed launch lock was absent while Pi was active"
validate_container_boundary managed none
managed_inspect="$(docker inspect "${MANAGED_CONTAINER_ID}")"
jq -e --arg workspace "${MANAGED_WORKTREE}" '
    any(.[0].Mounts[]; .Source == $workspace and .Destination == "/workspace") and
    any(.[0].Mounts[]; .Destination == "/run/pi-run-git/common") and
    any(.[0].Mounts[]; .Destination == "/workspace/.git" and .RW == false)
' <<<"${managed_inspect}" >/dev/null \
    || fail "managed container did not receive the bounded worktree mounts"

wait_until "both simultaneous Pi agents to be idle" both_agents_idle
lock_count="$(find "${PI_RUN_HOME}/worktrees/.launch-locks" -name owner.json -type f | wc -l)"
[[ "${lock_count}" == 1 && -f "${MANAGED_LOCK}" ]] \
    || fail "simultaneous launches did not retain exactly the managed task lock"
sleep 1
docker inspect "${DIRECT_CONTAINER_ID}" "${MANAGED_CONTAINER_ID}" >/dev/null 2>&1 \
    || fail "a simultaneous Pi-Run container did not remain alive headlessly"
both_agents_idle || fail "simultaneous Pi agents did not remain visible in Herdr"

run_tui_loss tui-client-loss 118 36
docker inspect "${DIRECT_CONTAINER_ID}" "${MANAGED_CONTAINER_ID}" >/dev/null 2>&1 \
    || fail "abrupt Herdr client loss stopped a Pi-Run container"
both_agents_idle || fail "abrupt Herdr client loss stopped Pi detection"
server_ready || fail "abrupt Herdr client loss stopped the server"
[[ -f "${MANAGED_LOCK}" ]] || fail "abrupt Herdr client loss released the managed lock"
run_tui_detach tui-after-loss 124 40
docker inspect "${DIRECT_CONTAINER_ID}" "${MANAGED_CONTAINER_ID}" >/dev/null 2>&1 \
    || fail "reattachment after client loss stopped a Pi-Run container"
both_agents_idle || fail "reattachment after client loss stopped Pi detection"
server_ready || fail "reattachment after client loss stopped the server"
[[ -f "${MANAGED_LOCK}" ]] || fail "reattachment after client loss released the managed lock"

PANE_ID="${DIRECT_PANE_ID}"
CONTAINER_ID="${DIRECT_CONTAINER_ID}"
herdr pane send-keys "${PANE_ID}" ctrl+d >/dev/null
wait_until "normal direct Pi exit to remove only its container" container_gone
wait_until "normal direct Pi exit to clear only its Herdr detection" agent_gone
DIRECT_CONTAINER_ID=""
CONTAINER_ID="${MANAGED_CONTAINER_ID}"
PANE_ID="${MANAGED_PANE_ID}"
docker inspect "${MANAGED_CONTAINER_ID}" >/dev/null 2>&1 \
    || fail "direct Pi exit disturbed the managed container"
agent_idle || fail "direct Pi exit disturbed managed Herdr detection"
[[ -f "${MANAGED_LOCK}" ]] || fail "direct Pi exit released the managed task lock"

herdr pane send-keys "${MANAGED_PANE_ID}" ctrl+d >/dev/null
wait_until "normal managed Pi exit to remove its container" container_gone
wait_until "normal managed Pi exit to clear Herdr detection" agent_gone
wait_until "normal managed Pi exit to release its lock" managed_lock_gone
MANAGED_CONTAINER_ID=""
CONTAINER_ID=""
[[ -d "${MANAGED_WORKTREE}" &&
   "$(git -C "${MANAGED_WORKTREE}" branch --show-current)" == pi-run/herdr-task ]] \
    || fail "ordinary managed exit removed or changed the managed checkout"
jq -e --arg workspace "${MANAGED_WORKSPACE_ID}" '
    [.repositories[0].tasks[] | select(.name == "herdr-task" and
        .workspaceId == $workspace and .state == "active")] | length == 1
' "${MACHINE}" >/dev/null || fail "ordinary managed exit changed active task metadata"

PI_RUN_HOME="${PI_RUN_HOME}" "${ROOT}/bin/pi-run" network mode restricted >/dev/null
PI_RUN_HOME="${PI_RUN_HOME}" "${ROOT}/bin/pi-run" network allow add host \
    example.invalid --tcp-port 443 >/dev/null
restricted_response="$(herdr workspace create --cwd "${WORKSPACE}" \
    --label restricted-network --no-focus)"
PANE_ID="$(jq -er '.result.root_pane.pane_id' <<<"${restricted_response}")"
ACTIVE_WORKSPACE="${WORKSPACE}"
printf -v restricted_command \
    'HERDR_AGENT=pi PI_RUN_HOME=%q PI_RUN_CORE_IMAGE=%q PI_RUN_IMAGE=%q PI_RUN_EGRESS_IMAGE=%q exec %q %q' \
    "${PI_RUN_HOME}" "${CORE_IMAGE}" "${CORE_IMAGE}" "${EGRESS_IMAGE}" \
    "${ROOT}/bin/pi-run" "${WORKSPACE}"
herdr pane run "${PANE_ID}" "${restricted_command}" >/dev/null

wait_until "the restricted Pi-Run container" find_pi_container
wait_until "restricted Pi to become idle in Herdr" agent_idle
validate_container_boundary restricted container
restricted_inspect="$(docker inspect "${CONTAINER_ID}")"
network_mode="$(jq -er '.[0].HostConfig.NetworkMode' <<<"${restricted_inspect}")"
sidecar_ref="${network_mode#container:}"
sidecar_inspect="$(docker inspect "${sidecar_ref}")" \
    || fail "restricted workload did not reference a live sidecar"
SIDECAR_ID="$(jq -er '.[0].Id' <<<"${sidecar_inspect}")"

jq -e '
    ([.[0].Config.Env[] | select(. == "HTTPS_PROXY=http://127.0.0.1:3128")] | length) == 1 and
    ([.[0].Config.Env[] | select(. == "https_proxy=http://127.0.0.1:3128")] | length) == 1 and
    ([.[0].Config.Env[] | select(. == "NODE_USE_ENV_PROXY=1")] | length) == 1 and
    ((.[0].HostConfig.CapAdd // [] | index("NET_ADMIN")) == null) and
    all(.[0].Mounts[]; .Destination != "/policy/rules.json")
' <<<"${restricted_inspect}" >/dev/null \
    || fail "restricted workload received unsafe networking authority"
jq -e --arg image "${EGRESS_IMAGE}" --arg runtime "${XDG_RUNTIME_DIR}" \
    --arg config "${XDG_CONFIG_HOME}/herdr" --arg state "${XDG_STATE_HOME}/herdr" '
    .[0].Config.Image == $image and
    ((.[0].HostConfig.CapAdd // []) | index("NET_ADMIN") != null) and
    any(.[0].Mounts[]; .Destination == "/policy/rules.json" and .RW == false) and
    all(.[0].Config.Env[]; startswith("HERDR_") | not) and
    all(.[0].Mounts[];
        (.Source | startswith($runtime) | not) and
        (.Source | startswith($config) | not) and
        (.Source | startswith($state) | not))
' <<<"${sidecar_inspect}" >/dev/null \
    || fail "restricted sidecar authority or Herdr isolation is incorrect"
run_tui_detach restricted-detach 116 38
docker inspect "${CONTAINER_ID}" "${SIDECAR_ID}" >/dev/null 2>&1 \
    || fail "Herdr detach stopped a restricted container"
agent_idle || fail "Herdr detach stopped restricted Pi detection"
server_ready || fail "Herdr detach stopped the server during restricted launch"

herdr pane send-keys "${PANE_ID}" ctrl+d >/dev/null
wait_until "normal restricted Pi exit to remove the workload" container_gone
restricted_sidecar_gone() {
    ! docker inspect "${SIDECAR_ID}" >/dev/null 2>&1
}
wait_until "normal restricted Pi exit to remove the sidecar" restricted_sidecar_gone
wait_until "normal restricted Pi exit to clear Herdr detection" agent_gone
CONTAINER_ID=""
SIDECAR_ID=""

PI_RUN_HOME="${PI_RUN_HOME}" "${ROOT}/bin/pi-run" network mode host --discard-rules >/dev/null
egress_before="$(docker ps --filter "ancestor=${EGRESS_IMAGE}" -q | sort)"
host_response="$(herdr workspace create --cwd "${WORKSPACE}" \
    --label host-network --no-focus)"
PANE_ID="$(jq -er '.result.root_pane.pane_id' <<<"${host_response}")"
ACTIVE_WORKSPACE="${WORKSPACE}"
printf -v host_command \
    'HERDR_AGENT=pi PI_RUN_HOME=%q PI_RUN_CORE_IMAGE=%q PI_RUN_IMAGE=%q exec %q %q' \
    "${PI_RUN_HOME}" "${CORE_IMAGE}" "${CORE_IMAGE}" "${ROOT}/bin/pi-run" "${WORKSPACE}"
herdr pane run "${PANE_ID}" "${host_command}" >/dev/null

wait_until "the host-network Pi-Run container" find_pi_container
wait_until "host-network Pi to become idle in Herdr" agent_idle
validate_container_boundary host-network host
host_inspect="$(docker inspect "${CONTAINER_ID}")"
jq -e '
    all(.[0].Config.Env[];
        . != "HTTPS_PROXY=http://127.0.0.1:3128" and
        . != "https_proxy=http://127.0.0.1:3128" and
        . != "NODE_USE_ENV_PROXY=1")
' <<<"${host_inspect}" >/dev/null \
    || fail "host-network workload retained restricted proxy configuration"
egress_during="$(docker ps --filter "ancestor=${EGRESS_IMAGE}" -q | sort)"
[[ "${egress_during}" == "${egress_before}" ]] \
    || fail "host-network launch created an egress sidecar"

run_tui_detach host-network-detach 114 37
docker inspect "${CONTAINER_ID}" >/dev/null 2>&1 \
    || fail "Herdr detach stopped the host-network container"
agent_idle || fail "Herdr detach stopped host-network Pi detection"
server_ready || fail "Herdr detach stopped the server during host-network launch"

herdr pane send-keys "${PANE_ID}" ctrl+d >/dev/null
wait_until "normal host-network Pi exit to remove the workload" container_gone
wait_until "normal host-network Pi exit to clear Herdr detection" agent_gone
CONTAINER_ID=""
egress_after="$(docker ps --filter "ancestor=${EGRESS_IMAGE}" -q | sort)"
[[ "${egress_after}" == "${egress_before}" ]] \
    || fail "host-network launch changed the running egress sidecar set"

PI_RUN_HOME="${PI_RUN_HOME}" "${ROOT}/bin/pi-run" network mode offline >/dev/null
snapshot_workspace_id="$(jq -er --arg path "${WORKSPACE}" '
    .workspacePaths[] | select(.path == $path) | .workspaceId' "${MACHINE}")"
snapshot_session_dir="${PI_RUN_HOME}/profiles/default/sessions/${snapshot_workspace_id}"
snapshot_session_file="${snapshot_session_dir}/snapshot-restart.jsonl"
snapshot_session_container="/profile/sessions/${snapshot_workspace_id}/snapshot-restart.jsonl"
mkdir -p "${snapshot_session_dir}"
printf '%s\n' \
    '{"type":"session","version":3,"id":"88888888-8888-4888-8888-888888888888","timestamp":"2026-11-01T12:00:00.000Z","cwd":"/workspace"}' \
    > "${snapshot_session_file}"
chmod 0600 "${snapshot_session_file}"

snapshot_response="$(herdr workspace create --cwd "${WORKSPACE}" \
    --label snapshot-restart --no-focus)"
PANE_ID="$(jq -er '.result.root_pane.pane_id' <<<"${snapshot_response}")"
ACTIVE_WORKSPACE="${WORKSPACE}"
printf -v snapshot_command \
    'HERDR_AGENT=pi PI_RUN_HOME=%q PI_RUN_CORE_IMAGE=%q PI_RUN_IMAGE=%q exec %q %q --session %q' \
    "${PI_RUN_HOME}" "${CORE_IMAGE}" "${CORE_IMAGE}" "${ROOT}/bin/pi-run" \
    "${WORKSPACE}" "${snapshot_session_container}"
herdr pane run "${PANE_ID}" "${snapshot_command}" >/dev/null

wait_until "the initial snapshot-restart Pi container" find_pi_container
wait_until "snapshot-restart Pi to become idle" agent_idle
validate_container_boundary snapshot-initial none exact
initial_snapshot_container="${CONTAINER_ID}"
initial_snapshot_inspect="$(docker inspect "${initial_snapshot_container}")"
jq -e --arg session "${snapshot_session_container}" '
    .[0].Config.Cmd as $cmd |
    ($cmd | index("--session")) as $index |
    $index != null and $cmd[$index + 1] == $session and
    all(.[0].Mounts[];
        .Destination != "/snapshots" and .Destination != "/repository" and
        .Destination != "/secret" and .Destination != "/s3-credentials")
' <<<"${initial_snapshot_inspect}" >/dev/null \
    || fail "initial snapshot-restart container exposed repository state or the wrong session"

herdr pane send-text "${PANE_ID}" /snapshot >/dev/null
herdr pane send-keys "${PANE_ID}" enter >/dev/null
herdr pane wait-output "${PANE_ID}" --match 'Pi-Run snapshots' \
    --source visible --timeout 10000 >/dev/null
herdr pane send-keys "${PANE_ID}" enter >/dev/null
CONTAINER_ID="${initial_snapshot_container}"
wait_until "the initial Pi container to exit for snapshot status" container_gone
CONTAINER_ID=""
wait_until "the restarted Pi container" find_pi_container
[[ "${CONTAINER_ID}" != "${initial_snapshot_container}" ]] \
    || fail "snapshot status reused the exited container"
wait_until "snapshot status and exact-session restart report" snapshot_restart_reported
wait_until "the restarted Pi TUI to finish startup" snapshot_restarted_tui_ready
wait_until "restarted Pi to become idle in Herdr" agent_idle
validate_container_boundary snapshot-restarted none exact
restarted_snapshot_inspect="$(docker inspect "${CONTAINER_ID}")"
jq -e --arg session "${snapshot_session_container}" '
    .[0].Config.Cmd as $cmd |
    ($cmd | index("--session")) as $index |
    $index != null and $cmd[$index + 1] == $session and
    all(.[0].Mounts[];
        .Destination != "/snapshots" and .Destination != "/repository" and
        .Destination != "/secret" and .Destination != "/s3-credentials")
' <<<"${restarted_snapshot_inspect}" >/dev/null \
    || fail "snapshot restart exposed repository state or reopened the wrong session"
[[ -z "$(find "${PI_RUN_HOME}/snapshots/requests" -type f -name request.json -print -quit)" ]] \
    || fail "snapshot restart retained its handled request file"

# Prove that the restarted TUI accepts input, then deterministically empty its
# editor before using Pi's documented Ctrl+D exit binding.
herdr pane send-text "${PANE_ID}" PI_RUN_SNAPSHOT_RESTART_INPUT >/dev/null
herdr pane wait-output "${PANE_ID}" --match 'PI_RUN_SNAPSHOT_RESTART_INPUT' \
    --source visible --timeout 10000 >/dev/null
herdr pane send-keys "${PANE_ID}" ctrl+u >/dev/null
herdr pane send-keys "${PANE_ID}" ctrl+k >/dev/null
sleep 1
herdr pane send-keys "${PANE_ID}" ctrl+d >/dev/null
wait_until "normal restarted Pi exit to remove the container" container_gone
wait_until "normal restarted Pi exit to clear Herdr detection" agent_gone
CONTAINER_ID=""

printf '%s: PASS\n' "${TEST_NAME}"
