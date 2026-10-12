#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/docker/ssh-credentials"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "ssh-credentials-test: $*" >&2
    exit 1
}

new_case() {
    CASE_ROOT="$(mktemp -d "${TMP}/case.XXXXXX")"
    PROFILE="${CASE_ROOT}/profile"
    RUNTIME_HOME="${CASE_ROOT}/home"
    mkdir -p "${PROFILE}/credentials/ssh" "${RUNTIME_HOME}"
    chmod 0700 "${PROFILE}" "${PROFILE}/credentials" \
        "${PROFILE}/credentials/ssh" "${RUNTIME_HOME}"
}

make_key() {
    local target="$1" passphrase="${2:-}"
    ssh-keygen -q -t ed25519 -N "${passphrase}" \
        -f "${PROFILE}/credentials/ssh/${target}"
}

run_configure() {
    HOME="${RUNTIME_HOME}" PI_RUN_PROFILE_DIR="${PROFILE}" \
        "${HELPER}" configure
}

expect_failure() {
    local expected="$1"
    set +e
    FAILURE_OUTPUT="$(run_configure 2>&1)"
    FAILURE_STATUS=$?
    set -e
    (( FAILURE_STATUS != 0 )) || fail "configuration unexpectedly succeeded"
    [[ "${FAILURE_OUTPUT}" == *"${expected}"* ]] \
        || fail "failure did not contain '${expected}': ${FAILURE_OUTPUT}"
}

# A private key is sufficient; startup must not require or modify its public key.
new_case
make_key deploy@server.example.test
rm "${PROFILE}/credentials/ssh/deploy@server.example.test.pub"
printf 'server.example.test ssh-ed25519 fixture\n' > "${PROFILE}/credentials/ssh/known_hosts"
before="$(sha256sum "${PROFILE}/credentials/ssh/"*)"
run_configure
after="$(sha256sum "${PROFILE}/credentials/ssh/"*)"
[[ "${before}" == "${after}" ]] || fail "configuration modified stored credentials"
config="${RUNTIME_HOME}/.ssh/config"
[[ "$(stat -c '%a' "${RUNTIME_HOME}/.ssh")" == 700 ]] || fail "runtime SSH directory mode is not 700"
[[ "$(stat -c '%a' "${config}")" == 600 ]] || fail "runtime config mode is not 600"
resolved="$(ssh -G -F "${config}" server.example.test 2>/dev/null)"
[[ "${resolved}" == *$'user deploy'* ]] || fail "SSH user was not inferred"
[[ "${resolved}" == *$'identitiesonly yes'* ]] || fail "IdentitiesOnly was not enabled"
[[ "${resolved}" == *"identityfile ${PROFILE}/credentials/ssh/deploy@server.example.test"* ]] \
    || fail "private key path was not selected"
[[ "${resolved}" == *"userknownhostsfile ${PROFILE}/credentials/ssh/known_hosts"* ]] \
    || fail "profile known_hosts was not selected"
set +e
ssh -F "${config}" -o BatchMode=yes -o ProxyCommand=false server.example.test \
    >"${CASE_ROOT}/ssh.log" 2>&1
ssh_status=$?
set -e
(( ssh_status != 0 )) || fail "local failing ProxyCommand unexpectedly connected"

# No credentials means no runtime SSH files.
new_case
rmdir "${PROFILE}/credentials/ssh"
run_configure
[[ ! -e "${RUNTIME_HOME}/.ssh/config" ]] || fail "empty credentials created a config"

# Existing runtime configuration is never overwritten.
new_case
make_key deploy@server.example.test
mkdir -m 0700 "${RUNTIME_HOME}/.ssh"
printf 'Host existing\n' > "${RUNTIME_HOME}/.ssh/config"
expect_failure "refusing to overwrite"
[[ "$(<"${RUNTIME_HOME}/.ssh/config")" == "Host existing" ]] || fail "existing config changed"

# Multiple users for one host require an explicit future selection mechanism.
new_case
make_key deploy@server.example.test
make_key admin@server.example.test
expect_failure "ambiguous SSH hostname"
[[ ! -e "${RUNTIME_HOME}/.ssh/config" ]] || fail "ambiguous keys created a config"

# Invalid and encrypted private keys fail without prompting.
new_case
printf 'not a key\n' > "${PROFILE}/credentials/ssh/deploy@server.example.test"
chmod 0600 "${PROFILE}/credentials/ssh/deploy@server.example.test"
expect_failure "invalid or encrypted"
new_case
make_key deploy@server.example.test secret
expect_failure "invalid or encrypted"

# Unsafe names and filesystem objects are rejected.
new_case
printf 'bad\n' > "${PROFILE}/credentials/ssh/not-a-target"
expect_failure "unsafe SSH credential filename"
new_case
outside="${CASE_ROOT}/outside"
printf 'bad\n' > "${outside}"
ln -s "${outside}" "${PROFILE}/credentials/ssh/deploy@server.example.test"
expect_failure "regular non-symlink"
new_case
mkfifo "${PROFILE}/credentials/ssh/deploy@server.example.test"
expect_failure "regular non-symlink"
new_case
make_key deploy@server.example.test
ln "${PROFILE}/credentials/ssh/deploy@server.example.test" \
    "${PROFILE}/credentials/ssh/admin@other.example.test"
expect_failure "must not be hard-linked"

# Unsafe directory permissions and known_hosts links are rejected.
new_case
chmod 0750 "${PROFILE}/credentials/ssh"
expect_failure "must not be accessible"
new_case
make_key deploy@server.example.test
ln -s /dev/null "${PROFILE}/credentials/ssh/known_hosts"
expect_failure "known_hosts must be a regular non-symlink"

echo "SSH credential configuration tests passed"
