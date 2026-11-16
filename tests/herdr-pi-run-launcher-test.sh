#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

TEST_NAME="herdr-pi-run-launcher-test"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${PI_RUN_TEST_HERDR:-0}" != 1 ]]; then
    echo "${TEST_NAME}: SKIP (set PI_RUN_TEST_HERDR=1 and HERDR_BIN to test Herdr)"
    exit 0
fi

fail() {
    echo "${TEST_NAME}: FAIL: $*" >&2
    if [[ -n "${SERVER_LOG:-}" && -f "${SERVER_LOG}" ]]; then
        echo "--- Herdr server log ---" >&2
        tail -80 "${SERVER_LOG}" >&2 || true
    fi
    exit 1
}

for command_name in git jq grep mktemp sort; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "required command unavailable: ${command_name}"
done
[[ "$(uname -s)" == Linux ]] || fail "this compatibility probe requires Linux"

HERDR_BIN="${HERDR_BIN:-}"
[[ -n "${HERDR_BIN}" && -x "${HERDR_BIN}" ]] \
    || fail "HERDR_BIN must name an executable verified Herdr binary"
HERDR_BIN="$(cd "$(dirname "${HERDR_BIN}")" && pwd)/$(basename "${HERDR_BIN}")"
EXPECTED_VERSION="${PI_RUN_TEST_HERDR_VERSION:-0.9.5}"
VERSION_OUTPUT="$(${HERDR_BIN} --version 2>&1)"
grep -E "(^|[^0-9])${EXPECTED_VERSION//./\\.}([^0-9]|$)" <<<"${VERSION_OUTPUT}" >/dev/null \
    || fail "expected Herdr ${EXPECTED_VERSION}, got: ${VERSION_OUTPUT}"

TMP="$(mktemp -d)"
HOME="${TMP}/home"
XDG_CONFIG_HOME="${TMP}/config"
XDG_STATE_HOME="${TMP}/state"
XDG_CACHE_HOME="${TMP}/cache"
XDG_RUNTIME_DIR="${TMP}/runtime"
PI_RUN_HOME="${TMP}/Pi Run"
REPOSITORY="${TMP}/source repository"
FAKE_BIN="${TMP}/fake-bin"
CAPTURE_DIR="${TMP}/captures"
CONTROL_DIR="${TMP}/controls"
SERVER_LOG="${TMP}/server.log"
SESSION="pi-run-launcher-$$"
SERVER_PID=""

export HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR

cleanup() {
    local status=$?
    if [[ -x "${HERDR_BIN}" ]]; then
        "${HERDR_BIN}" session stop "${SESSION}" --json >/dev/null 2>&1 || true
        "${HERDR_BIN}" session delete "${SESSION}" --json >/dev/null 2>&1 || true
    fi
    if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
        kill "${SERVER_PID}" >/dev/null 2>&1 || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf "${TMP}"
    exit "${status}"
}
trap cleanup EXIT INT TERM

mkdir -p "${HOME}" "${XDG_CONFIG_HOME}/herdr" "${XDG_STATE_HOME}" \
    "${XDG_CACHE_HOME}" "${XDG_RUNTIME_DIR}" "${FAKE_BIN}" \
    "${CAPTURE_DIR}" "${CONTROL_DIR}" "${REPOSITORY}"
chmod 0700 "${XDG_RUNTIME_DIR}"
cat > "${XDG_CONFIG_HOME}/herdr/config.toml" <<'EOF_CONFIG'
onboarding = false

[update]
manifest_check = false

[terminal]
default_shell = "/bin/bash"
shell_mode = "non_login"
EOF_CONFIG

cat > "${FAKE_BIN}/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-}" in
    'info ')
        exit 0
        ;;
    'image inspect')
        exec "${RUNTIME_IMAGE_FIXTURE:?}" --emit-image "${3:?}"
        ;;
esac

case "${1:-}" in
    run)
        shift
        materialize=false
        workspace=
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
                esac
            elif [[ "${previous}" == --env && "${argument}" == PI_RUN_WORKTREE_BASE=* ]]; then
                base="${argument#*=}"
            fi
            previous="${argument}"
        done
        [[ -n "${workspace}" ]] || exit 2
        if [[ "${materialize}" == true ]]; then
            [[ -n "${base}" ]] || exit 2
            git -C "${workspace}" -c core.hooksPath=/dev/null reset --hard "${base}" >/dev/null
            exit 0
        fi
        kind=direct
        [[ "${workspace}" != */worktrees/*/* ]] || kind=managed
        printf '%s\n' "$@" > "${DOCKER_CAPTURE_DIR:?}/${kind}.args"
        env | sort > "${DOCKER_CAPTURE_DIR}/${kind}.host-env"
        touch "${DOCKER_CONTROL_DIR:?}/${kind}.ready"
        printf '\033[2J\033[HWorking...\npi-run-%s\n' "${kind}"
        while [[ ! -e "${DOCKER_CONTROL_DIR}/${kind}.idle" ]]; do
            sleep 0.1
        done
        printf '\033[2J\033[HReady\npi-run-%s\n' "${kind}"
        while [[ ! -e "${DOCKER_CONTROL_DIR}/${kind}.exit" ]]; do
            sleep 0.1
        done
        ;;
    rm)
        ;;
    *)
        exit 2
        ;;
esac
EOF_DOCKER
chmod 0755 "${FAKE_BIN}/docker"

PI_RUN_HOME="${PI_RUN_HOME}" "${ROOT}/bin/pi-run" init >/dev/null
git init -q -b main "${REPOSITORY}"
git -C "${REPOSITORY}" config user.name fixture
git -C "${REPOSITORY}" config user.email fixture@pi-run.invalid
printf 'base\n' > "${REPOSITORY}/base.txt"
git -C "${REPOSITORY}" add base.txt
git -C "${REPOSITORY}" commit -qm base

herdr() {
    "${HERDR_BIN}" --session "${SESSION}" "$@"
}

wait_until() {
    local description="$1"
    shift
    for _ in $(seq 1 150); do
        if "$@"; then
            return 0
        fi
        sleep 0.1
    done
    fail "timed out waiting for ${description}"
}

server_ready() {
    local output
    output="$(herdr status server --json 2>/dev/null)" || return 1
    jq -e '.status == "running"' <<<"${output}" >/dev/null
}

launches_ready() {
    [[ -s "${CAPTURE_DIR}/direct.args" && -s "${CAPTURE_DIR}/managed.args" &&
       -s "${CAPTURE_DIR}/direct.host-env" && -s "${CAPTURE_DIR}/managed.host-env" &&
       -e "${CONTROL_DIR}/direct.ready" && -e "${CONTROL_DIR}/managed.ready" ]]
}

agents_match() {
    local expected="$1" agents
    agents="$(herdr agent list 2>/dev/null)" || return 1
    jq -e --arg direct "${DIRECT_PANE}" --arg managed "${MANAGED_PANE}" \
        --arg cwd "${REPOSITORY}" --arg expected "${expected}" '
        .result.agents as $agents
        | ([$agents[] | select(.pane_id == $direct)] | length) == 1
        and ([$agents[] | select(.pane_id == $managed)] | length) == 1
        and all($agents[] | select(.pane_id == $direct or .pane_id == $managed);
            .agent == "pi"
            and .cwd == $cwd
            and (if $expected == "working" then .agent_status == "working"
                 else (.agent_status == "idle" or .agent_status == "done") end)
            and (has("agent_session") | not))
    ' <<<"${agents}" >/dev/null
}

no_agents() {
    local agents
    agents="$(herdr agent list 2>/dev/null)" || return 1
    jq -e '.result.agents | length == 0' <<<"${agents}" >/dev/null
}

printf 'Starting disposable Herdr %s headless server...\n' "${EXPECTED_VERSION}"
herdr server >"${SERVER_LOG}" 2>&1 &
SERVER_PID=$!
wait_until "the disposable Herdr server" server_ready

direct_workspace="$(herdr workspace create --cwd "${REPOSITORY}" --label direct --no-focus)"
managed_workspace="$(herdr workspace create --cwd "${REPOSITORY}" --label managed --no-focus)"
DIRECT_PANE="$(jq -er '.result.root_pane.pane_id' <<<"${direct_workspace}")"
MANAGED_PANE="$(jq -er '.result.root_pane.pane_id' <<<"${managed_workspace}")"
[[ "${DIRECT_PANE}" != "${MANAGED_PANE}" ]] || fail "launch panes are not distinct"

printf -v common_env \
    'HERDR_AGENT=pi PATH=%q PI_RUN_HOME=%q RUNTIME_IMAGE_FIXTURE=%q DOCKER_CAPTURE_DIR=%q DOCKER_CONTROL_DIR=%q' \
    "${FAKE_BIN}:${PATH}" "${PI_RUN_HOME}" "${ROOT}/tests/runtime-launch-selection-test.sh" \
    "${CAPTURE_DIR}" "${CONTROL_DIR}"
printf -v direct_command '%s exec %q %q --version' \
    "${common_env}" "${ROOT}/bin/pi-run" "${REPOSITORY}"
printf -v managed_command '%s exec %q worktree start herdr-task %q -- --version' \
    "${common_env}" "${ROOT}/bin/pi-run" "${REPOSITORY}"
herdr pane run "${DIRECT_PANE}" "${direct_command}" >/dev/null
wait_until "the direct Pi-Run launcher invocation" test -e "${CONTROL_DIR}/direct.ready"
herdr pane run "${MANAGED_PANE}" "${managed_command}" >/dev/null

wait_until "both Pi-Run launcher invocations" launches_ready
wait_until "both launchers to be detected as working Pi agents" agents_match working

for kind in direct managed; do
    host_env="${CAPTURE_DIR}/${kind}.host-env"
    docker_args="${CAPTURE_DIR}/${kind}.args"
    grep -Fx 'HERDR_AGENT=pi' "${host_env}" >/dev/null \
        || fail "${kind} host Docker process lost HERDR_AGENT=pi"
    socket_path="$(sed -n 's/^HERDR_SOCKET_PATH=//p' "${host_env}")"
    herdr_path="$(sed -n 's/^HERDR_BIN_PATH=//p' "${host_env}")"
    [[ -n "${socket_path}" && -n "${herdr_path}" ]] \
        || fail "${kind} host Docker process was not running inside Herdr"
    ! grep -E '^HERDR_' "${docker_args}" >/dev/null \
        || fail "${kind} Docker arguments forwarded a Herdr variable"
    ! grep -F "${socket_path}" "${docker_args}" >/dev/null \
        || fail "${kind} Docker arguments exposed the Herdr socket"
    ! grep -F "${herdr_path}" "${docker_args}" >/dev/null \
        || fail "${kind} Docker arguments exposed the Herdr CLI"
done

MACHINE="${PI_RUN_HOME}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
WORKSPACE_ID="$(jq -er '.repositories[0].tasks[] | select(.name == "herdr-task") | .workspaceId' \
    "${MACHINE}")"
LOCK="${PI_RUN_HOME}/worktrees/.launch-locks/${WORKSPACE_ID}/owner.json"
[[ -f "${LOCK}" ]] || fail "managed launch lock was absent while Pi-Run was active"

for pane in "${DIRECT_PANE}" "${MANAGED_PANE}"; do
    explain="$(herdr agent explain "${pane}" --json)"
    jq -e '.agent == "pi" and .state == "working" and .matched_rule.id == "working_literal"' \
        <<<"${explain}" >/dev/null || fail "working-state detection failed for ${pane}"
done

touch "${CONTROL_DIR}/direct.idle" "${CONTROL_DIR}/managed.idle"
wait_until "both Pi-Run launchers to settle" agents_match idle
for pane in "${DIRECT_PANE}" "${MANAGED_PANE}"; do
    explain="$(herdr agent explain "${pane}" --json)"
    jq -e '.agent == "pi" and .state == "idle" and
        .fallback_reason == "default_known_agent_idle_fallback"' \
        <<<"${explain}" >/dev/null || fail "idle-state detection failed for ${pane}"
done

touch "${CONTROL_DIR}/direct.exit" "${CONTROL_DIR}/managed.exit"
wait_until "normal launcher exit to clear the agent list" no_agents
wait_until "managed launch lock cleanup" test ! -e "${LOCK}"
[[ -d "${PI_RUN_HOME}/worktrees" &&
   "$(jq -r '[.repositories[0].tasks[] | select(.name == "herdr-task" and .state == "active")] | length' \
       "${MACHINE}")" == 1 ]] || fail "normal exit did not preserve the managed worktree"

printf '%s: PASS\n' "${TEST_NAME}"
