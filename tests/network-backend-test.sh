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
printf '%s\n' '---' "$@" >> "${DOCKER_LOG:?}"
case "${1:-}" in
    run)
        sidecar=false
        policy_source=
        cidfile=
        next_is_cidfile=false
        for argument in "$@"; do
            if [ "$next_is_cidfile" = true ]; then
                cidfile=$argument
                next_is_cidfile=false
                continue
            fi
            [ "$argument" = NET_ADMIN ] && sidecar=true
            [ "$argument" = --cidfile ] && next_is_cidfile=true
            case "$argument" in
                type=bind,src=*,dst=/policy/allowed-hosts.txt,readonly)
                    policy_source=${argument#*src=}
                    policy_source=${policy_source%,dst=*}
                    ;;
            esac
        done
        if [ "$sidecar" = true ]; then
            [ -n "$policy_source" ] && [ -n "$cidfile" ] || exit 3
            cp "$policy_source" "${POLICY_CAPTURE:?}"
            dirname "$policy_source" > "${POLICY_DIR_CAPTURE:?}"
            printf '%s\n' abcdef0123456789abcdef0123456789 > "$cidfile"
            [ "${SIDECAR_RUN_FAIL:-0}" = 0 ] || exit 41
            echo fake-sidecar-id
        else
            exit "${DOCKER_RUN_STATUS:-0}"
        fi
        ;;
    exec)
        [ "${READY_FAIL:-0}" = 0 ]
        ;;
    logs) echo fake-sidecar-log ;;
    rm) [ "${DOCKER_RM_FAIL:-0}" = 0 ] ;;
    *) exit 2 ;;
esac
EOF
cat > "${TMP}/fake-bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "${TMP}/fake-bin/docker" "${TMP}/fake-bin/sleep"
export DOCKER_LOG="${TMP}/docker.log"
export POLICY_CAPTURE="${TMP}/allowed-hosts.txt"
export POLICY_DIR_CAPTURE="${TMP}/policy-dir"

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

# Restricted launches stage an exact private policy and gate Pi on the sidecar.
rm -f "${POLICY_CAPTURE}" "${POLICY_DIR_CAPTURE}"
PI_RUN_EGRESS_IMAGE=example.invalid/pi-run-egress:test \
    run_launch "${PI_RUN}" --network docker-restricted \
        --allow-host example.com --allow-host api.example.net "${WORKSPACE}"
grep -F 'pi-run: network=docker-restricted' "${TMP}/stderr" >/dev/null \
    || fail "restricted backend was not reported"
grep -F 'pi-run: allowed-https=example.com:443,api.example.net:443' \
    "${TMP}/stderr" >/dev/null || fail "restricted exposure was not reported"
printf '%s\n' example.com api.example.net > "${TMP}/expected-policy"
cmp -s "${TMP}/expected-policy" "${POLICY_CAPTURE}" \
    || fail "runtime hostname policy was incorrect"
[[ ! -e "$(< "${POLICY_DIR_CAPTURE}")" ]] \
    || fail "runtime hostname policy was not cleaned up"
grep -Fx 'example.invalid/pi-run-egress:test' "${DOCKER_LOG}" >/dev/null \
    || fail "selected egress image was not used"
grep -F 'dst=/policy/allowed-hosts.txt,readonly' "${DOCKER_LOG}" >/dev/null \
    || fail "policy was not mounted read-only"
[[ "$(grep -Fc 'dst=/policy/allowed-hosts.txt' "${DOCKER_LOG}")" -eq 1 ]] \
    || fail "policy was exposed to more than the sidecar"
[[ "$(grep -Fxc NET_ADMIN "${DOCKER_LOG}")" -eq 1 ]] \
    || fail "NET_ADMIN was not isolated to the sidecar"
grep -Fx -- '--cap-drop=ALL' "${DOCKER_LOG}" >/dev/null \
    || fail "Pi capabilities were not dropped"
grep -F -- '--ulimit' "${DOCKER_LOG}" >/dev/null \
    || fail "sidecar file-descriptor limit was omitted"
grep -F 'container:pi-egress-default-' "${DOCKER_LOG}" >/dev/null \
    || fail "Pi did not share the sidecar network namespace"
grep -Fx 'HTTPS_PROXY=http://127.0.0.1:3128' "${DOCKER_LOG}" >/dev/null \
    || fail "Pi did not receive the HTTPS proxy"
grep -Fx 'https_proxy=http://127.0.0.1:3128' "${DOCKER_LOG}" >/dev/null \
    || fail "Pi did not receive the lowercase HTTPS proxy"
ready_line="$(grep -n '/tmp/pi-run-egress-ready' "${DOCKER_LOG}" | head -1 | cut -d: -f1)"
runtime_line="$(grep -n 'ghcr.io/aprilsoftware/pi-run:0.6.3' "${DOCKER_LOG}" | head -1 | cut -d: -f1)"
(( ready_line < runtime_line )) || fail "Pi started before sidecar readiness"
grep -Fx rm "${DOCKER_LOG}" >/dev/null || fail "sidecar cleanup was not attempted"
if grep -Fx host "${DOCKER_LOG}" >/dev/null; then
    fail "restricted launch used host networking"
fi

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

# Sidecar startup and readiness failures prevent Pi from starting and clean policy.
for failure in run ready; do
    : > "${DOCKER_LOG}"
    rm -f "${POLICY_CAPTURE}" "${POLICY_DIR_CAPTURE}"
    set +e
    if [[ "${failure}" == run ]]; then
        PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" SIDECAR_RUN_FAIL=1 \
            "${PI_RUN}" --network docker-restricted --allow-host example.com "${WORKSPACE}" \
            >"${TMP}/stdout" 2>"${TMP}/stderr"
    else
        PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" READY_FAIL=1 \
            "${PI_RUN}" --network docker-restricted --allow-host example.com "${WORKSPACE}" \
            >"${TMP}/stdout" 2>"${TMP}/stderr"
    fi
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "sidecar ${failure} failure was accepted"
    if grep -Fx 'ghcr.io/aprilsoftware/pi-run:0.6.3' "${DOCKER_LOG}" >/dev/null; then
        fail "Pi started after sidecar ${failure} failure"
    fi
    [[ ! -e "$(< "${POLICY_DIR_CAPTURE}")" ]] \
        || fail "sidecar ${failure} failure retained policy"
done

# Pi failure removes the sidecar and policy without retrying through host networking.
: > "${DOCKER_LOG}"
rm -f "${POLICY_CAPTURE}" "${POLICY_DIR_CAPTURE}"
set +e
PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" DOCKER_RUN_STATUS=42 \
    "${PI_RUN}" --network docker-restricted --allow-host example.com "${WORKSPACE}" \
    >"${TMP}/stdout" 2>"${TMP}/stderr"
status=$?
set -e
[[ ${status} -eq 42 ]] || fail "restricted Pi failure was not propagated"
[[ "$(grep -Fxc run "${DOCKER_LOG}")" -eq 2 ]] \
    || fail "failed restricted launch retried Docker"
grep -Fx rm "${DOCKER_LOG}" >/dev/null || fail "failed restricted launch retained sidecar"
[[ ! -e "$(< "${POLICY_DIR_CAPTURE}")" ]] || fail "failed restricted launch retained policy"
if grep -Fx host "${DOCKER_LOG}" >/dev/null; then
    fail "failed restricted launch fell back to host networking"
fi

# A sidecar cleanup failure is visible and makes the launch fail.
: > "${DOCKER_LOG}"
set +e
PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" DOCKER_RM_FAIL=1 \
    "${PI_RUN}" --network docker-restricted --allow-host example.com "${WORKSPACE}" \
    >"${TMP}/stdout" 2>"${TMP}/stderr"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "sidecar cleanup failure was hidden"
grep -F 'warning: could not remove restricted egress sidecar' "${TMP}/stderr" >/dev/null \
    || fail "sidecar cleanup failure had no diagnostic"

# Invalid selections and policy combinations fail before Docker.
for backend in invalid docker-restricted; do
    : > "${DOCKER_LOG}"
    set +e
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        "${PI_RUN}" --network "${backend}" "${WORKSPACE}" \
        >"${TMP}/stdout" 2>"${TMP}/stderr"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "invalid backend selection was accepted: ${backend}"
    [[ ! -s "${DOCKER_LOG}" ]] || fail "invalid backend selection reached Docker: ${backend}"
done

for hostname in '*.example.com' 'https://example.com' '1.1.1.1' \
    'example.com:443' localhost Example.com example..com example.com.; do
    : > "${DOCKER_LOG}"
    set +e
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        "${PI_RUN}" --network docker-restricted --allow-host "${hostname}" "${WORKSPACE}" \
        >"${TMP}/stdout" 2>"${TMP}/stderr"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "invalid exact hostname was accepted: ${hostname}"
    [[ ! -s "${DOCKER_LOG}" ]] || fail "invalid exact hostname reached Docker: ${hostname}"
done

for backend in docker-host docker-offline; do
    : > "${DOCKER_LOG}"
    set +e
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        "${PI_RUN}" --network "${backend}" --allow-host example.com "${WORKSPACE}" \
        >"${TMP}/stdout" 2>"${TMP}/stderr"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "${backend} accepted a hostname policy"
    [[ ! -s "${DOCKER_LOG}" ]] || fail "${backend} hostname policy reached Docker"
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
