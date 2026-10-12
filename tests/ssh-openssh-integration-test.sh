#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "ssh-openssh-integration-test: $*" >&2
    exit 1
}

PROFILE="${TMP}/profile"
SSH_DIR="${PROFILE}/credentials/ssh"
RUNTIME_HOME="${TMP}/home"
TARGET=deploy@server.example.test
mkdir -p "${SSH_DIR}" "${RUNTIME_HOME}"
chmod 0700 "${PROFILE}" "${PROFILE}/credentials" "${SSH_DIR}" "${RUNTIME_HOME}"
ssh-keygen -q -t ed25519 -N '' -f "${SSH_DIR}/${TARGET}"
printf 'server.example.test ssh-ed25519 fixture\n' > "${SSH_DIR}/known_hosts"
before="$(find "${SSH_DIR}" -type f -printf '%P ' -exec sha256sum {} \; | sort)"
HOME="${RUNTIME_HOME}" PI_RUN_PROFILE_DIR="${PROFILE}" \
    "${ROOT}/docker/ssh-credentials" configure
config="${RUNTIME_HOME}/.ssh/config"

resolved="$(ssh -G -F "${config}" server.example.test 2>/dev/null)"
[[ "${resolved}" == *$'user deploy'* ]] || fail "ssh -G did not infer the remote user"
[[ "${resolved}" == *$'identitiesonly yes'* ]] || fail "ssh -G did not restrict identities"
[[ "${resolved}" == *"identityfile ${SSH_DIR}/${TARGET}"* ]] \
    || fail "ssh -G did not select the profile private key"
[[ "${resolved}" == *"userknownhostsfile ${SSH_DIR}/known_hosts"* ]] \
    || fail "ssh -G did not select profile known_hosts"

PROXY="${TMP}/capture-proxy"
cat > "${PROXY}" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$@" > "${CAPTURE:?}"
exit 1
EOF
chmod 0755 "${PROXY}"
printf 'fixture\n' > "${TMP}/local-file"

run_client_check() {
    local name="$1" capture="${TMP}/capture-${1}" status
    shift
    set +e
    CAPTURE="${capture}" "$@" >"${TMP}/${name}.log" 2>&1
    status=$?
    set -e
    (( status != 0 )) || fail "${name} unexpectedly connected"
    [[ -f "${capture}" ]] || fail "${name} did not invoke the local ProxyCommand"
    mapfile -t proxy_args < "${capture}"
    [[ "${proxy_args[*]}" == "deploy server.example.test" ]] \
        || fail "${name} resolved unexpected connection values: ${proxy_args[*]}"
}

proxy_option="ProxyCommand=${PROXY} %r %h"
run_client_check ssh ssh -F "${config}" -o "${proxy_option}" server.example.test true
run_client_check scp scp -F "${config}" -o "${proxy_option}" \
    "${TMP}/local-file" server.example.test:/tmp/pi-run-test
run_client_check sftp sftp -F "${config}" -o "${proxy_option}" \
    -b /dev/null server.example.test

if command -v ansible >/dev/null 2>&1; then
    printf '[servers]\nserver.example.test\n' > "${TMP}/inventory"
    capture="${TMP}/capture-ansible"
    set +e
    HOME="${RUNTIME_HOME}" CAPTURE="${capture}" ANSIBLE_HOST_KEY_CHECKING=True \
        ANSIBLE_SSH_COMMON_ARGS="-o 'ProxyCommand=${PROXY} %r %h'" \
        ansible -i "${TMP}/inventory" servers -m ping >"${TMP}/ansible.log" 2>&1
    status=$?
    set -e
    (( status != 0 )) || fail "Ansible unexpectedly connected through the failing proxy"
    [[ -f "${capture}" ]] || fail "Ansible did not invoke OpenSSH for the inventory hostname"
    mapfile -t proxy_args < "${capture}"
    [[ "${proxy_args[*]}" == "deploy server.example.test" ]] \
        || fail "Ansible did not use the inferred SSH user: ${proxy_args[*]}"
    echo "Ansible OpenSSH configuration check passed"
else
    echo "Ansible OpenSSH configuration check skipped: ansible is unavailable"
fi

after="$(find "${SSH_DIR}" -type f -printf '%P ' -exec sha256sum {} \; | sort)"
[[ "${before}" == "${after}" ]] || fail "integration checks modified stored credentials"

echo "OpenSSH client integration tests passed"
