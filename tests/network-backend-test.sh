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

set_network_mode() {
    local mode="$1" config="${HOME_DIR}/profiles/default/profile.json"
    jq --arg mode "${mode}" '.network = {mode: $mode}' "${config}" > "${config}.tmp"
    mv "${config}.tmp" "${config}"
}

set_restricted_network() {
    local config="${HOME_DIR}/profiles/default/profile.json"
    jq '.network = {mode: "restricted", allow: [
        {host: "git.example.test", tcpPorts: [443, 22]},
        {domain: "example.net"},
        {cidr: "10.20.30.0/24", tcpPorts: [5432]}
    ]}' "${config}" > "${config}.tmp"
    mv "${config}.tmp" "${config}"
}

HOME_DIR="${TMP}/Pi Run"
WORKSPACE="${TMP}/workspace"
mkdir -p "${WORKSPACE}" "${TMP}/fake-bin"
PI_RUN_HOME="${HOME_DIR}" "${PI_RUN}" init >/dev/null
SSH_CREDENTIAL_DIR="${HOME_DIR}/profiles/default/credentials/ssh"
mkdir -m 0700 "${SSH_CREDENTIAL_DIR}"
printf '%s\n' 'disposable private fixture' > "${SSH_CREDENTIAL_DIR}/user@ssh.example.test"
printf '%s\n' 'disposable public fixture' > "${SSH_CREDENTIAL_DIR}/user@ssh.example.test.pub"
chmod 0600 "${SSH_CREDENTIAL_DIR}/user@ssh.example.test"

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' '---' "$@" >> "${DOCKER_LOG:?}"
case "${1:-}" in
    run)
        sidecar=false
        resolver=false
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
            [ "$argument" = /usr/local/bin/pi-run-network-policy-resolver ] && resolver=true
            [ "$argument" = --cidfile ] && next_is_cidfile=true
            case "$argument" in
                type=bind,src=*,dst=/policy/rules.json,readonly)
                    policy_source=${argument#*src=}
                    policy_source=${policy_source%,dst=*}
                    ;;
            esac
        done
        if [ "$resolver" = true ]; then
            [ "${RESOLVER_FAIL:-0}" = 0 ] || exit 40
            if [ "${RESOLVER_OUTPUT+x}" = x ]; then
                printf '%s\n' "${RESOLVER_OUTPUT}"
            else
                printf '%s\n' '{"schemaVersion":1,"modelRules":[{"host":"model.example.test","tcpPorts":[443]}],"sshRules":[{"host":"ssh.example.test","tcpPorts":[22]}],"manualRules":[{"cidr":"10.20.30.0/24","tcpPorts":[5432]},{"domain":"example.net"},{"host":"git.example.test","tcpPorts":[22,443]}]}'
            fi
        elif [ "$sidecar" = true ]; then
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
export POLICY_CAPTURE="${TMP}/rules.json"
export POLICY_DIR_CAPTURE="${TMP}/policy-dir"

# A legacy profile without network configuration retains host networking.
config="${HOME_DIR}/profiles/default/profile.json"
jq 'del(.network)' "${config}" > "${config}.tmp"
mv "${config}.tmp" "${config}"
run_launch "${PI_RUN}" "${WORKSPACE}"
assert_network_mode host
grep -F 'pi-run: network=docker-host' "${TMP}/stderr" >/dev/null \
    || fail "default backend was not reported"
[[ "$(grep -Fxc -- '--network' "${DOCKER_LOG}")" -eq 1 ]] \
    || fail "default launch supplied multiple Docker network modes"

# Profile-selected offline launches map to Docker's network-none mode.
set_network_mode offline
run_launch "${PI_RUN}" "${WORKSPACE}"
assert_network_mode none
grep -F 'pi-run: network=docker-offline' "${TMP}/stderr" >/dev/null \
    || fail "offline backend was not reported"
if grep -Fx host "${DOCKER_LOG}" >/dev/null; then
    fail "offline launch retained host networking"
fi

# Resume launches retain the profile-selected offline backend.
machine_file="$(find "${HOME_DIR}/machines" -maxdepth 1 -type f -name '*.json' -print -quit)"
workspace_id="$(jq -r --arg path "${WORKSPACE}" \
    '.workspacePaths[] | select(.path == $path) | .workspaceId' "${machine_file}")"
session_dir="${HOME_DIR}/profiles/default/sessions/${workspace_id}"
printf '%s\n' \
    '{"type":"session","id":"11111111-1111-4111-8111-111111111111","timestamp":"2026-10-17T12:00:00Z","cwd":"/workspace","version":3}' \
    > "${session_dir}/offline-resume.jsonl"
run_launch "${PI_RUN}" resume default "${workspace_id}"
assert_network_mode none
grep -Fx -- '--resume' "${DOCKER_LOG}" >/dev/null \
    || fail "offline resume did not reach Pi"

# Restricted profiles resolve and freeze model and manual TCP rules.
set_restricted_network
rm -f "${POLICY_CAPTURE}" "${POLICY_DIR_CAPTURE}"
PI_RUN_EGRESS_IMAGE=example.invalid/pi-run-egress:test \
    run_launch "${PI_RUN}" "${WORKSPACE}"
grep -F 'pi-run: network=docker-restricted' "${TMP}/stderr" >/dev/null \
    || fail "restricted backend was not reported"
grep -F 'pi-run: model-tcp=model.example.test:443' "${TMP}/stderr" >/dev/null \
    || fail "model TCP exposure was not reported"
grep -F 'pi-run: ssh-tcp=1 managed target on port 22' "${TMP}/stderr" >/dev/null \
    || fail "managed SSH TCP exposure count was not reported"
[[ "$(< "${TMP}/stderr")" != *ssh.example.test* ]] \
    || fail "managed SSH hostname was disclosed in startup output"
grep -F 'pi-run: manual-tcp=cidr=10.20.30.0/24:5432,domain=example.net:*,host=git.example.test:22|443' \
    "${TMP}/stderr" >/dev/null || fail "manual TCP exposure was not reported"
jq -e '. == {schemaVersion: 1, rules: [
    {cidr: "10.20.30.0/24", tcpPorts: [5432]},
    {domain: "example.net"},
    {host: "git.example.test", tcpPorts: [22, 443]},
    {host: "model.example.test", tcpPorts: [443]},
    {host: "ssh.example.test", tcpPorts: [22]}
]}' "${POLICY_CAPTURE}" >/dev/null || fail "runtime TCP rule policy was incorrect"
[[ ! -e "$(< "${POLICY_DIR_CAPTURE}")" ]] \
    || fail "runtime hostname policy was not cleaned up"
grep -Fx 'example.invalid/pi-run-egress:test' "${DOCKER_LOG}" >/dev/null \
    || fail "selected egress image was not used"
grep -F 'dst=/policy/rules.json,readonly' "${DOCKER_LOG}" >/dev/null \
    || fail "policy was not mounted read-only"
[[ "$(grep -Fc 'dst=/policy/rules.json' "${DOCKER_LOG}")" -eq 1 ]] \
    || fail "policy was exposed to more than the sidecar"
[[ "$(grep -Fxc NET_ADMIN "${DOCKER_LOG}")" -eq 1 ]] \
    || fail "NET_ADMIN was not isolated to the sidecar"
[[ "$(grep -Fxc -- '--network' "${DOCKER_LOG}")" -eq 2 ]] \
    || fail "restricted launch did not isolate resolver and Pi networking"
grep -Fx -- '--pull' "${DOCKER_LOG}" >/dev/null \
    || fail "resolver did not prohibit implicit image pulls"
grep -F 'dst=/profile,readonly' "${DOCKER_LOG}" >/dev/null \
    || fail "resolver did not receive a read-only profile"
grep -F 'dst=/profile/profile.json,readonly' "${DOCKER_LOG}" >/dev/null \
    || fail "Pi did not receive a read-only profile configuration"
grep -F "src=${SSH_CREDENTIAL_DIR},dst=/profile/credentials/ssh,readonly" "${DOCKER_LOG}" >/dev/null \
    || fail "Pi did not receive read-only managed SSH credentials"
grep -Fx -- '--cap-drop=ALL' "${DOCKER_LOG}" >/dev/null \
    || fail "capabilities were not dropped"
grep -F -- '--ulimit' "${DOCKER_LOG}" >/dev/null \
    || fail "sidecar file-descriptor limit was omitted"
grep -F 'container:pi-egress-default-' "${DOCKER_LOG}" >/dev/null \
    || fail "Pi did not share the sidecar network namespace"
grep -Fx 'HTTPS_PROXY=http://127.0.0.1:3128' "${DOCKER_LOG}" >/dev/null \
    || fail "Pi did not receive the HTTPS proxy"
grep -Fx 'https_proxy=http://127.0.0.1:3128' "${DOCKER_LOG}" >/dev/null \
    || fail "Pi did not receive the lowercase HTTPS proxy"
grep -Fx 'NODE_USE_ENV_PROXY=1' "${DOCKER_LOG}" >/dev/null \
    || fail "Node environment proxy support was not enabled"
grep -Fx 'PI_RUN_NETWORK_MODE=restricted' "${DOCKER_LOG}" >/dev/null \
    || fail "restricted mode was not passed to runtime helpers"
ready_line="$(grep -n '/tmp/pi-run-egress-ready' "${DOCKER_LOG}" | head -1 | cut -d: -f1)"
runtime_line="$(grep -n -- '-it' "${DOCKER_LOG}" | head -1 | cut -d: -f1)"
(( ready_line < runtime_line )) || fail "Pi started before sidecar readiness"
grep -Fx rm "${DOCKER_LOG}" >/dev/null || fail "sidecar cleanup was not attempted"
if grep -Fx host "${DOCKER_LOG}" >/dev/null; then
    fail "restricted launch used host networking"
fi

# A failed offline launch propagates without a host-network retry.
set_network_mode offline
: > "${DOCKER_LOG}"
set +e
PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" DOCKER_RUN_STATUS=42 \
    "${PI_RUN}" "${WORKSPACE}" >"${TMP}/stdout" 2>"${TMP}/stderr"
status=$?
set -e
[[ ${status} -eq 42 ]] || fail "offline Docker failure was not propagated"
assert_network_mode none
[[ "$(grep -Fxc run "${DOCKER_LOG}")" -eq 1 ]] || fail "failed offline launch retried Docker"

# Resolver failures and malformed output prevent sidecar startup.
set_restricted_network
for failure in execution output; do
    : > "${DOCKER_LOG}"
    set +e
    if [[ "${failure}" == execution ]]; then
        PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" RESOLVER_FAIL=1 \
            "${PI_RUN}" "${WORKSPACE}" >"${TMP}/stdout" 2>"${TMP}/stderr"
    else
        PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" RESOLVER_OUTPUT='{}' \
            "${PI_RUN}" "${WORKSPACE}" >"${TMP}/stdout" 2>"${TMP}/stderr"
    fi
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "resolver ${failure} failure was accepted"
    [[ "$(grep -Fxc run "${DOCKER_LOG}")" -eq 1 ]] \
        || fail "resolver ${failure} failure reached the sidecar or Pi"
done

# Sidecar startup and readiness failures prevent Pi from starting and clean policy.
for failure in run ready; do
    : > "${DOCKER_LOG}"
    rm -f "${POLICY_CAPTURE}" "${POLICY_DIR_CAPTURE}"
    set +e
    if [[ "${failure}" == run ]]; then
        PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" SIDECAR_RUN_FAIL=1 \
            "${PI_RUN}" "${WORKSPACE}" >"${TMP}/stdout" 2>"${TMP}/stderr"
    else
        PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" READY_FAIL=1 \
            "${PI_RUN}" "${WORKSPACE}" >"${TMP}/stdout" 2>"${TMP}/stderr"
    fi
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "sidecar ${failure} failure was accepted"
    ! grep -Fx -- '-it' "${DOCKER_LOG}" >/dev/null || fail "Pi started after sidecar failure"
    [[ ! -e "$(< "${POLICY_DIR_CAPTURE}")" ]] || fail "sidecar failure retained policy"
done

# Pi failure removes the sidecar and policy without retrying through host networking.
: > "${DOCKER_LOG}"
rm -f "${POLICY_CAPTURE}" "${POLICY_DIR_CAPTURE}"
set +e
PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" DOCKER_RUN_STATUS=42 \
    "${PI_RUN}" "${WORKSPACE}" >"${TMP}/stdout" 2>"${TMP}/stderr"
status=$?
set -e
[[ ${status} -eq 42 ]] || fail "restricted Pi failure was not propagated"
[[ "$(grep -Fxc run "${DOCKER_LOG}")" -eq 3 ]] || fail "failed restricted launch retried Docker"
grep -Fx rm "${DOCKER_LOG}" >/dev/null || fail "failed restricted launch retained sidecar"
[[ ! -e "$(< "${POLICY_DIR_CAPTURE}")" ]] || fail "failed restricted launch retained policy"

# Sidecar cleanup failure is visible and makes the launch fail.
: > "${DOCKER_LOG}"
set +e
PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" DOCKER_RM_FAIL=1 \
    "${PI_RUN}" "${WORKSPACE}" >"${TMP}/stdout" 2>"${TMP}/stderr"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "sidecar cleanup failure was hidden"
grep -F 'warning: could not remove restricted egress sidecar' "${TMP}/stderr" >/dev/null \
    || fail "sidecar cleanup failure had no diagnostic"

# A broad workspace cannot expose private /tmp policy staging.
: > "${DOCKER_LOG}"
set +e
PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${PI_RUN}" /tmp >"${TMP}/stdout" 2>"${TMP}/stderr"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "restricted backend accepted an overlapping workspace"
grep -F 'restricted runtime policy staging would overlap workspace: /tmp' \
    "${TMP}/stderr" >/dev/null || fail "overlapping workspace had no clear diagnostic"
[[ ! -s "${DOCKER_LOG}" ]] || fail "overlapping workspace reached Docker"

# Structurally invalid profile rules fail before Docker.
config="${HOME_DIR}/profiles/default/profile.json"
for network in \
    '{"mode":"invalid"}' \
    '{"mode":"host","allow":[]}' \
    '{"mode":"restricted","allow":{}}' \
    '{"mode":"restricted","allow":[{"host":"one.test","domain":"two.test"}]}' \
    '{"mode":"restricted","allow":[{"domain":"*.example.test"}]}' \
    '{"mode":"restricted","allow":[{"host":"one.test","tcpPorts":[22,22]}]}' \
    '{"mode":"restricted","allow":[{"host":"one.test"},{"host":"one.test"}]}'; do
    jq --argjson network "${network}" '.network = $network' "${config}" > "${config}.tmp"
    mv "${config}.tmp" "${config}"
    : > "${DOCKER_LOG}"
    set +e
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        "${PI_RUN}" "${WORKSPACE}" >"${TMP}/stdout" 2>"${TMP}/stderr"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "invalid profile network policy was accepted: ${network}"
    [[ ! -s "${DOCKER_LOG}" ]] || fail "invalid profile network policy reached Docker"
done

# Removed per-launch network options are rejected before Docker.
for option in --network --allow-host; do
    : > "${DOCKER_LOG}"
    set +e
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        "${PI_RUN}" "${option}" ignored "${WORKSPACE}" >"${TMP}/stdout" 2>"${TMP}/stderr"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "removed launcher option was accepted: ${option}"
    grep -F "unknown launcher option: ${option}" "${TMP}/stderr" >/dev/null \
        || fail "removed launcher option had no clear diagnostic"
    [[ ! -s "${DOCKER_LOG}" ]] || fail "removed launcher option reached Docker"
done

echo "Network backend tests passed"
