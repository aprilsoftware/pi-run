#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_RUN="${ROOT}/bin/pi-run"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "network-backend-test: $*" >&2
    exit 1
}

assert_network_mode() {
    local expected="$1"
    awk -v expected="${expected}" '
        previous == "--network" && $0 == expected { found = 1 }
        { previous = $0 }
        END { exit(found ? 0 : 1) }
    ' "${DOCKER_LOG}" || fail "missing Docker network mode: ${expected}"
}

run_launch() {
    : > "${DOCKER_LOG}"
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        "$@" >"${TMP}/stdout" 2>"${TMP}/stderr"
}

HOME_DIR="${TMP}/Pi Run"
WORKSPACE="${TMP}/workspace"
mkdir -p "${WORKSPACE}" "${TMP}/fake-bin"
PI_RUN_HOME="${HOME_DIR}" "${PI_RUN}" init >/dev/null

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG:?}"
done
exit "${DOCKER_RUN_STATUS:-0}"
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"

# Existing launches retain host networking and identify the effective backend.
run_launch "${PI_RUN}" "${WORKSPACE}"
assert_network_mode host
grep -F 'pi-run: network=docker-host' "${TMP}/stderr" >/dev/null \
    || fail "default backend was not reported"
[[ "$(grep -Fxc -- '--network' "${DOCKER_LOG}")" -eq 1 ]] \
    || fail "default launch supplied multiple Docker network modes"

# Explicit offline launches map to Docker's network-none mode.
run_launch "${PI_RUN}" --network docker-offline "${WORKSPACE}"
assert_network_mode none
grep -F 'pi-run: network=docker-offline' "${TMP}/stderr" >/dev/null \
    || fail "offline backend was not reported"
if grep -Fx host "${DOCKER_LOG}" >/dev/null; then
    fail "offline launch retained host networking"
fi

# Explicit resume launches retain the selected offline backend.
machine_file="$(find "${HOME_DIR}/machines" -maxdepth 1 -type f -name '*.json' -print -quit)"
workspace_id="$(jq -r --arg path "${WORKSPACE}" \
    '.workspacePaths[] | select(.path == $path) | .workspaceId' "${machine_file}")"
session_dir="${HOME_DIR}/profiles/default/sessions/${workspace_id}"
printf '%s\n' \
    '{"type":"session","id":"11111111-1111-4111-8111-111111111111","timestamp":"2026-10-17T12:00:00Z","cwd":"/workspace","version":3}' \
    > "${session_dir}/offline-resume.jsonl"
run_launch "${PI_RUN}" --network docker-offline resume default "${workspace_id}"
assert_network_mode none
grep -Fx -- '--resume' "${DOCKER_LOG}" >/dev/null \
    || fail "offline resume did not reach Pi"

# A failed offline launch propagates the failure without a host-network retry.
: > "${DOCKER_LOG}"
set +e
PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" DOCKER_RUN_STATUS=42 \
    "${PI_RUN}" --network docker-offline "${WORKSPACE}" \
    >"${TMP}/stdout" 2>"${TMP}/stderr"
status=$?
set -e
[[ ${status} -eq 42 ]] || fail "offline Docker failure was not propagated"
assert_network_mode none
[[ "$(grep -Fxc run "${DOCKER_LOG}")" -eq 1 ]] \
    || fail "failed offline launch retried Docker"
if grep -Fx host "${DOCKER_LOG}" >/dev/null; then
    fail "failed offline launch fell back to host networking"
fi

# Invalid selections and use on management commands fail before Docker.
for backend in invalid docker-restricted; do
    : > "${DOCKER_LOG}"
    set +e
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        "${PI_RUN}" --network "${backend}" "${WORKSPACE}" \
        >"${TMP}/stdout" 2>"${TMP}/stderr"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "unsupported backend was accepted: ${backend}"
    [[ ! -s "${DOCKER_LOG}" ]] || fail "unsupported backend reached Docker: ${backend}"
done

: > "${DOCKER_LOG}"
set +e
PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${PI_RUN}" --network docker-offline doctor \
    >"${TMP}/stdout" 2>"${TMP}/stderr"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "management command accepted a network backend"
[[ ! -s "${DOCKER_LOG}" ]] || fail "management command backend reached Docker"

set +e
"${PI_RUN}" --network >"${TMP}/stdout" 2>"${TMP}/stderr"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "missing backend value was accepted"
grep -F -- '--network requires a value' "${TMP}/stderr" >/dev/null \
    || fail "missing backend value had no clear diagnostic"

echo "Network backend tests passed"
