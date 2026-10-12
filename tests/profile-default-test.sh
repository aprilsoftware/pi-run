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
mkdir -p "${WORKSPACE}" "${TMP}/fake-bin"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
[[ "$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default)" == default ]] \
    || fail "initial default profile is not default"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create development >/dev/null
output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default development)"
[[ "${output}" == "Default profile: development" ]] \
    || fail "setting the default returned unexpected output"
[[ "$(jq -r .defaultProfile "${HOME_DIR}/config.json")" == development ]] \
    || fail "home configuration was not updated"
[[ "$(stat -c %a "${HOME_DIR}/config.json")" == 600 ]] \
    || fail "home configuration permissions are not 600"
[[ "$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile default)" == development ]] \
    || fail "configured default was not reported"
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
