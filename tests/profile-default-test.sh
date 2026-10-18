#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "profile-default-test: $*" >&2
    exit 1
}

expect_failure() {
    local output status
    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "command unexpectedly succeeded: $*"
}

HOME_DIR="${TMP}/Pi Run"
WORKSPACE="${TMP}/workspace"
mkdir -p "${WORKSPACE}" "${TMP}/fake-bin" "${TMP}/cidr-bin"
export CIDR_DOCKER_LOG="${TMP}/cidr-docker.log"
cat > "${TMP}/cidr-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${CIDR_DOCKER_LOG:?}"
case "${1:-}" in
    image)
        [[ "${2:-}" == inspect && "${3:-}" != missing:test ]]
        ;;
    run)
        value="${*: -1}"
        case "${value}" in
            10.20.30.17/24|10.20.30.99/24) printf '%s\n' '10.20.30.0/24' ;;
            10.40.50.17/24|10.40.50.99/24) printf '%s\n' '10.40.50.0/24' ;;
            2001:0DB8:0:0::1/64|2001:db8::99/64) printf '%s\n' '2001:db8::/64' ;;
            127.0.0.1/32) exit 1 ;;
            *) printf '%s\n' "${value}" ;;
        esac
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/cidr-bin/docker"
export PATH="${TMP}/cidr-bin:${PATH}"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
[[ "$(jq -r '.network.mode' "${HOME_DIR}/profiles/default/profile.json")" == host ]] \
    || fail "initial default profile does not select host networking"
[[ "$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default)" == default ]] \
    || fail "initial default profile is not default"
network_output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network show)"
[[ "${network_output}" == $'Profile: default\nNetwork mode: host (configured)\nManual allow rules: 0' ]] \
    || fail "configured network mode display was incorrect"
default_config="${HOME_DIR}/profiles/default/profile.json"
jq 'del(.network)' "${default_config}" > "${default_config}.tmp"
mv "${default_config}.tmp" "${default_config}"
network_output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network show)"
[[ "${network_output}" == $'Profile: default\nNetwork mode: host (compatibility default)\nManual allow rules: 0' ]] \
    || fail "compatibility network mode display was incorrect"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network mode host >/dev/null
[[ "$(jq -r '.network.mode' "${default_config}")" == host &&
   "$(stat -c %a "${default_config}")" == 600 ]] \
    || fail "network mode command did not materialize host mode safely"
config_inode="$(stat -c %i "${default_config}")"
network_output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network mode host)"
[[ "${network_output}" == *'Network mode for default: host (unchanged)'* &&
   "$(stat -c %i "${default_config}")" == "${config_inode}" ]] \
    || fail "same network mode was not idempotent"
exec {network_lock_fd}<"${HOME_DIR}/profiles/default"
flock -x "${network_lock_fd}"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network mode offline \
    >"${TMP}/locked-network.out" &
network_pid=$!
sleep 0.1
kill -0 "${network_pid}" 2>/dev/null \
    || fail "network mode command did not wait for the profile lock"
flock -u "${network_lock_fd}"
wait "${network_pid}"
exec {network_lock_fd}>&-
[[ "$(jq -r '.network.mode' "${default_config}")" == offline ]] \
    || fail "network mode command did not continue after profile unlock"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network mode restricted >/dev/null
[[ "$(jq -c '.network' "${default_config}")" == '{"mode":"restricted"}' ]] \
    || fail "network mode command did not select restricted mode"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network mode offline >/dev/null
[[ "$(jq -c '.network' "${default_config}")" == '{"mode":"offline"}' ]] \
    || fail "network mode command did not select offline mode"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network mode host >/dev/null
cp "${default_config}" "${TMP}/network-mode.before"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network mode invalid
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network mode restricted --discard-rules
cmp "${TMP}/network-mode.before" "${default_config}" \
    || fail "invalid network mode command changed the profile"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    network allow add host blocked.example.test --tcp-port 443
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    network allow add internet --all-tcp
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network mode restricted >/dev/null
jq '.network.allow = [{cidr: "10.20.30.0/24", tcpPorts: [5432]}]' \
    "${default_config}" > "${default_config}.tmp"
mv "${default_config}.tmp" "${default_config}"
network_output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow list)"
[[ "${network_output}" == $'Profile: default\nManual allow rules: 1\ncidr=10.20.30.0/24 tcp=5432' ]] \
    || fail "manual network rule list was incorrect"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    cidr 10.20.30.17/24 --tcp-port 5432
cp "${default_config}" "${TMP}/cidr-image-unavailable.before"
expect_failure env PI_RUN_HOME="${HOME_DIR}" PI_RUN_IMAGE=missing:test \
    "${ROOT}/bin/pi-run" network allow add cidr 10.40.50.17/24 --all-tcp
cmp "${TMP}/cidr-image-unavailable.before" "${default_config}" \
    || fail "unavailable CIDR normalizer image changed the profile"
network_output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    cidr 2001:0DB8:0:0::1/64 --tcp-port 5432 --tcp-port 22)"
[[ "${network_output}" == *'Added manual network rule for default: cidr=2001:db8::/64 tcp=22|5432'* ]] \
    || fail "IPv6 CIDR rule was not normalized"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    cidr 10.40.50.17/24 --all-tcp >/dev/null
jq -e '.network.allow == [
    {cidr: "10.20.30.0/24", tcpPorts: [5432]},
    {cidr: "2001:db8::/64", tcpPorts: [22, 5432]},
    {cidr: "10.40.50.0/24"}
]' "${default_config}" >/dev/null || fail "CIDR rule additions were not canonical"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow remove \
    cidr 2001:db8::99/64 --tcp-port 22
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow remove \
    cidr 2001:db8::99/64 --tcp-port 5432 --tcp-port 22 >/dev/null
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow remove \
    cidr 10.40.50.99/24 --all-tcp >/dev/null
jq -e '.network.allow == [{cidr: "10.20.30.0/24", tcpPorts: [5432]}]' \
    "${default_config}" >/dev/null || fail "CIDR removal changed an unrelated rule"
grep -E '^image inspect .+' "${CIDR_DOCKER_LOG}" >/dev/null \
    || fail "CIDR normalizer did not require a local runtime image"
! grep -E '^pull( |$)' "${CIDR_DOCKER_LOG}" >/dev/null \
    || fail "CIDR normalizer attempted to pull an image"
grep -F -- '--pull never' "${CIDR_DOCKER_LOG}" >/dev/null \
    || fail "CIDR normalizer did not disable implicit image pulls"
grep -F -- '--network none' "${CIDR_DOCKER_LOG}" >/dev/null \
    || fail "CIDR normalizer did not use offline networking"
grep -F -- '--cap-drop=ALL' "${CIDR_DOCKER_LOG}" >/dev/null \
    || fail "CIDR normalizer did not drop capabilities"
grep -F -- '--security-opt=no-new-privileges' "${CIDR_DOCKER_LOG}" >/dev/null \
    || fail "CIDR normalizer did not set no-new-privileges"
grep -F -- '--read-only' "${CIDR_DOCKER_LOG}" >/dev/null \
    || fail "CIDR normalizer did not use a read-only image filesystem"
if grep -F -- '--mount' "${CIDR_DOCKER_LOG}" >/dev/null; then
    fail "CIDR normalizer received an unexpected mount"
fi
exec {network_rule_lock_fd}<"${HOME_DIR}/profiles/default"
flock -x "${network_rule_lock_fd}"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add internet \
    --tcp-port 8443 --tcp-port 443 > "${TMP}/locked-network-rule.out" &
network_rule_pid=$!
sleep 0.1
kill -0 "${network_rule_pid}" 2>/dev/null \
    || fail "internet rule command did not wait for the profile lock"
flock -u "${network_rule_lock_fd}"
wait "${network_rule_pid}"
exec {network_rule_lock_fd}>&-
network_output="$(< "${TMP}/locked-network-rule.out")"
[[ "${network_output}" == *'Added manual network rule for default: internet=public tcp=443|8443'* &&
   "${network_output}" == *'Changes apply to new launches; running sessions are unchanged.'* ]] \
    || fail "internet network rule addition returned unexpected output"
network_output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    host Git.Example.Test --tcp-port 443 --tcp-port 22)"
[[ "${network_output}" == *'Added manual network rule for default: host=git.example.test tcp=22|443'* ]] \
    || fail "host network rule addition returned unexpected output"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    domain Example.Test --all-tcp >/dev/null
jq -e '.network.allow == [
    {cidr: "10.20.30.0/24", tcpPorts: [5432]},
    {internet: true, tcpPorts: [443, 8443]},
    {host: "git.example.test", tcpPorts: [22, 443]},
    {domain: "example.test"}
]' "${default_config}" >/dev/null || fail "network rule additions were not normalized or preserved"
[[ "$(stat -c %a "${default_config}")" == 600 ]] \
    || fail "network rule command did not preserve private configuration permissions"
cp "${default_config}" "${TMP}/network-rules-cli.before"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    host git.example.test --tcp-port 22 --tcp-port 443
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    host other.example.test --tcp-port 22 --tcp-port 022
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    host other.example.test --all-tcp --tcp-port 22
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    host invalid --tcp-port 22
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    cidr 127.0.0.1/32 --all-tcp
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    internet --all-tcp
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    internet --tcp-port 0
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow add \
    internet --all-tcp --tcp-port 443
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow remove \
    internet --all-tcp
cmp "${TMP}/network-rules-cli.before" "${default_config}" \
    || fail "invalid network rule command changed the profile"
cp "${default_config}" "${TMP}/network-rules-valid"
jq '.network.allow += [{internet: true, tcpPorts: [443]}]' \
    "${default_config}" > "${default_config}.tmp"
mv "${default_config}.tmp" "${default_config}"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network show
mv "${TMP}/network-rules-valid" "${default_config}"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow remove \
    host GIT.EXAMPLE.TEST --tcp-port 443 --tcp-port 22 >/dev/null
jq -e '.network.allow == [
    {cidr: "10.20.30.0/24", tcpPorts: [5432]},
    {internet: true, tcpPorts: [443, 8443]},
    {domain: "example.test"}
]' "${default_config}" >/dev/null || fail "host rule removal changed unrelated rules"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow remove \
    domain example.test --all-tcp >/dev/null
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow remove \
    domain example.test --all-tcp
network_output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    network allow remove internet)"
[[ "${network_output}" == *'Removed manual network rule for default: internet=public tcp=443|8443'* ]] \
    || fail "internet network rule removal returned unexpected output"
network_output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    network allow add internet --all-tcp)"
[[ "${network_output}" == *'Added manual network rule for default: internet=public tcp=all'* ]] \
    || fail "all-TCP internet rule addition returned unexpected output"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network allow remove internet >/dev/null
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    network allow remove internet
jq -e '.network.allow == [{cidr: "10.20.30.0/24", tcpPorts: [5432]}]' \
    "${default_config}" >/dev/null || fail "internet rule changes affected an unrelated CIDR"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network mode host --discard-rules >/dev/null

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create development >/dev/null
[[ "$(jq -r '.network.mode' "${HOME_DIR}/profiles/development/profile.json")" == host ]] \
    || fail "created profile did not preserve its source network policy"
output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default development)"
[[ "${output}" == "Default profile: development" ]] \
    || fail "setting the default returned unexpected output"
[[ "$(jq -r .defaultProfile "${HOME_DIR}/config.json")" == development ]] \
    || fail "home configuration was not updated"
[[ "$(stat -c %a "${HOME_DIR}/config.json")" == 600 ]] \
    || fail "home configuration permissions are not 600"
[[ "$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default)" == development ]] \
    || fail "configured default was not reported"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" --profile default network mode offline >/dev/null
[[ "$(jq -r '.network.mode' "${HOME_DIR}/profiles/default/profile.json")" == offline &&
   "$(jq -r '.network.mode' "${HOME_DIR}/profiles/development/profile.json")" == host ]] \
    || fail "explicit profile network change affected the configured default"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" --profile default network mode host >/dev/null
profile_list="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile list)"
expected_list=$'NAME         DEFAULT\ndefault      -\ndevelopment  yes'
[[ "${profile_list}" == "${expected_list}" ]] \
    || fail "profile list did not identify the configured default"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    profile export development "${TMP}/exported-profile"
[[ ! -e "${TMP}/exported-profile" ]] || fail "removed profile export command created data"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    profile import "${HOME_DIR}/profiles/default"

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
case "${1:-}" in
    info) exit 0 ;;
    image) [ "${2:-}" = inspect ]; exit ;;
    run)
        : > "${DOCKER_LOG:?}"
        for argument in "$@"; do printf '%s\n' "$argument" >> "${DOCKER_LOG}"; done
        exit 0
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"

PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" "${WORKSPACE}" >/dev/null 2>&1

grep -Fx "type=bind,src=${HOME_DIR}/profiles/development,dst=/profile" "${DOCKER_LOG}" >/dev/null \
    || fail "launch did not use the configured default profile"

PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" --profile default "${WORKSPACE}" >/dev/null 2>&1

grep -Fx "type=bind,src=${HOME_DIR}/profiles/default,dst=/profile" "${DOCKER_LOG}" >/dev/null \
    || fail "explicit profile did not override the configured default"
[[ "$(jq -r .defaultProfile "${HOME_DIR}/config.json")" == development ]] \
    || fail "explicit profile changed the saved default"

doctor_output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" doctor)"
[[ "${doctor_output}" == *"home configuration is valid; default profile: development"* ]] \
    || fail "doctor did not report the configured default"
[[ "${doctor_output}" == *"selected profile configuration is valid: development"* ]] \
    || fail "doctor did not inspect the configured default"

development_config="${HOME_DIR}/profiles/development/profile.json"
jq '.network = {mode: "restricted", allow: [
    {host: "git.example.test", tcpPorts: [22]},
    {cidr: "10.20.30.0/24", tcpPorts: [5432]}
]}' "${development_config}" > "${development_config}.tmp"
mv "${development_config}.tmp" "${development_config}"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    profile create network-copy --from development >/dev/null
jq -e '.network == {mode: "restricted", allow: [
    {host: "git.example.test", tcpPorts: [22]},
    {cidr: "10.20.30.0/24", tcpPorts: [5432]}
]}' "${HOME_DIR}/profiles/network-copy/profile.json" >/dev/null \
    || fail "profile creation did not preserve a restricted network policy"
cp "${development_config}" "${TMP}/network-rules.before"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" network mode offline
cmp "${TMP}/network-rules.before" "${development_config}" \
    || fail "refused network mode change discarded manual rules"
network_output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    network mode offline --discard-rules)"
[[ "$(jq -c '.network' "${development_config}")" == '{"mode":"offline"}' &&
   "${network_output}" == *'Discarded manual allow rules: 2'* ]] \
    || fail "explicit network rule discard was not applied"

cp "${HOME_DIR}/config.json" "${TMP}/config.before"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default missing
cmp "${TMP}/config.before" "${HOME_DIR}/config.json" \
    || fail "missing-profile failure changed home configuration"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default ../invalid
cmp "${TMP}/config.before" "${HOME_DIR}/config.json" \
    || fail "invalid-name failure changed home configuration"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create incomplete >/dev/null
rm "${HOME_DIR}/profiles/incomplete/guardian/guardian.md"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default incomplete
cmp "${TMP}/config.before" "${HOME_DIR}/config.json" \
    || fail "incomplete-profile failure changed home configuration"

cp -a "${HOME_DIR}/profiles/development" "${HOME_DIR}/profiles/linked-target"
jq '.name = "linked"' "${HOME_DIR}/profiles/linked-target/profile.json" \
    > "${HOME_DIR}/profiles/linked-target/profile.json.tmp"
mv "${HOME_DIR}/profiles/linked-target/profile.json.tmp" \
    "${HOME_DIR}/profiles/linked-target/profile.json"
ln -s linked-target "${HOME_DIR}/profiles/linked"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default linked
cmp "${TMP}/config.before" "${HOME_DIR}/config.json" \
    || fail "unsafe-profile failure changed home configuration"

mv "${HOME_DIR}/config.json" "${HOME_DIR}/config.real"
ln "${HOME_DIR}/config.real" "${HOME_DIR}/config.json"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default default
rm "${HOME_DIR}/config.json"
mv "${HOME_DIR}/config.real" "${HOME_DIR}/config.json"
[[ "$(jq -r .defaultProfile "${HOME_DIR}/config.json")" == development ]] \
    || fail "unsafe-config rejection changed the saved default"

echo "default profile tests passed"
