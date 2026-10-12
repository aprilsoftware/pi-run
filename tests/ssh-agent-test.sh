#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
SOCKET_PID=""
cleanup() {
    if [[ -n "${SOCKET_PID}" ]]; then
        kill "${SOCKET_PID}" 2>/dev/null || true
        wait "${SOCKET_PID}" 2>/dev/null || true
    fi
    rm -rf "${TMP}"
}
trap cleanup EXIT

fail() {
    echo "ssh-agent-test: $*" >&2
    exit 1
}

HOME_DIR="${TMP}/Pi Run"
WORKSPACE="${TMP}/workspace"
mkdir -p "${WORKSPACE}" "${TMP}/fake-bin"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
profile_config="${HOME_DIR}/profiles/default/profile.json"

jq -e '.resources == {"shared":"read-write"}' "${profile_config}" >/dev/null \
    || fail "new profile still contains SSH-agent configuration"
help_output="$("${ROOT}/bin/pi-run" --help 2>&1)"
[[ "${help_output}" != *"ssh-agent"* ]] || fail "launcher help still advertises SSH-agent commands"

set +e
removed_output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" --profile default ssh-agent status 2>&1)"
removed_status=$?
set -e
(( removed_status != 0 )) || fail "removed ssh-agent command still succeeded"
[[ "${removed_output}" != *"Request:"* && "${removed_output}" != *"Grant:"* ]] \
    || fail "removed command still produced SSH-agent status"

# Removed profile fields are invalid rather than silently retained.
jq '.resources.sshAgent = "requested"' "${profile_config}" > "${profile_config}.tmp"
chmod 0600 "${profile_config}.tmp"
mv "${profile_config}.tmp" "${profile_config}"
set +e
legacy_output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" "${WORKSPACE}" 2>&1)"
legacy_status=$?
set -e
(( legacy_status != 0 )) || fail "legacy SSH-agent profile configuration was accepted"
[[ "${legacy_output}" == *"invalid profile configuration"* ]] \
    || fail "legacy configuration failed for the wrong reason: ${legacy_output}"
jq 'del(.resources.sshAgent)' "${profile_config}" > "${profile_config}.tmp"
chmod 0600 "${profile_config}.tmp"
mv "${profile_config}.tmp" "${profile_config}"

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
: > "${DOCKER_LOG:?}"
for argument in "$@"; do printf '%s\n' "${argument}" >> "${DOCKER_LOG}"; done
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"

SOCKET_PATH="${TMP}/agent.sock"
python3 - "${SOCKET_PATH}" <<'PY' &
import socket
import sys
import time

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[1])
sock.listen(1)
time.sleep(60)
PY
SOCKET_PID=$!
for _ in {1..50}; do
    [[ -S "${SOCKET_PATH}" ]] && break
    sleep 0.02
done
[[ -S "${SOCKET_PATH}" ]] || fail "test socket did not start"

SSH_AUTH_SOCK="${SOCKET_PATH}" PATH="${TMP}/fake-bin:${PATH}" \
    PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" "${WORKSPACE}" >/dev/null 2>&1
if grep -E 'SSH_AUTH_SOCK|ssh-agent|agent\.sock' "${DOCKER_LOG}" >/dev/null; then
    fail "launcher still exposed the host SSH agent"
fi

machine_file="$(find "${HOME_DIR}/machines" -mindepth 1 -maxdepth 1 -type f -name '*.json' -print -quit)"
[[ -n "${machine_file}" ]] || fail "machine metadata was not created"
jq -e 'has("profileGrants") | not' "${machine_file}" >/dev/null \
    || fail "new machine metadata still contains profile grants"

echo "SSH-agent removal tests passed"
