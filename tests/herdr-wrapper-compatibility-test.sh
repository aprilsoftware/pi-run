#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

TEST_NAME="herdr-wrapper-compatibility-test"

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

for command_name in jq env grep mktemp sort; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "required command unavailable: ${command_name}"
done
[[ "$(uname -s)" == Linux ]] || fail "this compatibility probe requires Linux"

HERDR_BIN="${HERDR_BIN:-}"
[[ -n "${HERDR_BIN}" ]] || fail "HERDR_BIN must name the verified Herdr binary"
[[ -x "${HERDR_BIN}" ]] || fail "HERDR_BIN is not executable: ${HERDR_BIN}"
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
WORKSPACE="${TMP}/shared-workspace"
CONTROL_ONE="${TMP}/control-one"
CONTROL_TWO="${TMP}/control-two"
AUDIT_ONE="${TMP}/workload-one.env"
AUDIT_TWO="${TMP}/workload-two.env"
SERVER_LOG="${TMP}/server.log"
WRAPPER="${TMP}/host-wrapper.sh"
SESSION="pi-run-wrapper-$$"
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
    "${XDG_CACHE_HOME}" "${XDG_RUNTIME_DIR}" "${WORKSPACE}" \
    "${CONTROL_ONE}" "${CONTROL_TWO}"
chmod 0700 "${XDG_RUNTIME_DIR}"
cat > "${XDG_CONFIG_HOME}/herdr/config.toml" <<'EOF_CONFIG'
onboarding = false

[update]
manifest_check = false

[terminal]
default_shell = "/bin/bash"
shell_mode = "non_login"
EOF_CONFIG

cat > "${WRAPPER}" <<'EOF_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

control_dir="$1"
audit_file="$2"
label="$3"

printf '%s\n' "$$" > "${control_dir}/pid"
env -i \
    HOME="${HOME}" \
    PATH="${PATH}" \
    TERM="${TERM:-xterm-256color}" \
    LANG="${LANG:-C.UTF-8}" \
    /usr/bin/env | sort > "${audit_file}"
printf '\033[2J\033[HWorking...\n%s\n' "${label}"
while [[ ! -e "${control_dir}/idle" ]]; do
    sleep 0.1
done
printf '\033[2J\033[HReady\n%s\n' "${label}"
while [[ ! -e "${control_dir}/exit" ]]; do
    sleep 0.1
done
EOF_WRAPPER
chmod 0700 "${WRAPPER}"

herdr() {
    "${HERDR_BIN}" --session "${SESSION}" "$@"
}

wait_until() {
    local description="$1"
    shift
    for _ in $(seq 1 100); do
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

both_audits_ready() {
    [[ -s "${AUDIT_ONE}" && -s "${AUDIT_TWO}" ]]
}

agents_working() {
    local agents
    agents="$(herdr agent list 2>/dev/null)" || return 1
    jq -e --arg one "${PANE_ONE}" --arg two "${PANE_TWO}" --arg cwd "${WORKSPACE}" '
        .result.agents as $agents
        | ([$agents[] | select(.pane_id == $one)] | length) == 1
        and ([$agents[] | select(.pane_id == $two)] | length) == 1
        and all($agents[] | select(.pane_id == $one or .pane_id == $two);
            .agent == "pi"
            and .agent_status == "working"
            and .cwd == $cwd
            and (has("agent_session") | not))
    ' <<<"${agents}" >/dev/null
}

agents_idle_or_done() {
    local agents
    agents="$(herdr agent list 2>/dev/null)" || return 1
    jq -e --arg one "${PANE_ONE}" --arg two "${PANE_TWO}" '
        .result.agents as $agents
        | ([$agents[] | select(.pane_id == $one)] | length) == 1
        and ([$agents[] | select(.pane_id == $two)] | length) == 1
        and all($agents[] | select(.pane_id == $one or .pane_id == $two);
            .agent_status == "idle" or .agent_status == "done")
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

workspace_one="$(herdr workspace create --cwd "${WORKSPACE}" --label wrapper-one --no-focus)"
workspace_two="$(herdr workspace create --cwd "${WORKSPACE}" --label wrapper-two --no-focus)"
PANE_ONE="$(jq -er '.result.root_pane.pane_id' <<<"${workspace_one}")"
PANE_TWO="$(jq -er '.result.root_pane.pane_id' <<<"${workspace_two}")"
[[ "${PANE_ONE}" != "${PANE_TWO}" ]] || fail "separate workspaces returned the same pane"

printf -v command_one 'HERDR_AGENT=pi exec %q %q %q %q' \
    "${WRAPPER}" "${CONTROL_ONE}" "${AUDIT_ONE}" wrapper-one
printf -v command_two 'HERDR_AGENT=pi exec %q %q %q %q' \
    "${WRAPPER}" "${CONTROL_TWO}" "${AUDIT_TWO}" wrapper-two
herdr pane run "${PANE_ONE}" "${command_one}" >/dev/null
herdr pane run "${PANE_TWO}" "${command_two}" >/dev/null

wait_until "both sanitized workload audits" both_audits_ready
if grep -E '^HERDR_' "${AUDIT_ONE}" "${AUDIT_TWO}" >/dev/null; then
    fail "synthetic inner workload inherited Herdr control variables"
fi
wait_until "two working Pi wrapper agents" agents_working

for pane in "${PANE_ONE}" "${PANE_TWO}"; do
    explain="$(herdr agent explain "${pane}" --json)"
    jq -e '
        .agent == "pi"
        and .state == "working"
        and .matched_rule.id == "working_literal"
    ' <<<"${explain}" >/dev/null \
        || fail "Pi working-state manifest did not classify pane ${pane}"
done

sleep 1
agents_working || fail "wrapper agents did not remain live on the headless server"

touch "${CONTROL_ONE}/idle" "${CONTROL_TWO}/idle"
wait_until "both Pi wrappers to settle" agents_idle_or_done
for pane in "${PANE_ONE}" "${PANE_TWO}"; do
    explain="$(herdr agent explain "${pane}" --json)"
    jq -e '
        .agent == "pi"
        and .state == "idle"
        and .fallback_reason == "default_known_agent_idle_fallback"
    ' <<<"${explain}" >/dev/null \
        || fail "Pi idle fallback did not classify pane ${pane}"
done

touch "${CONTROL_ONE}/exit" "${CONTROL_TWO}/exit"
wait_until "normal wrapper exit to clear the agent list" no_agents

printf '%s: PASS\n' "${TEST_NAME}"
