#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/docker/ssh-credentials"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "ssh-key-add-test: $*" >&2
    exit 1
}

new_profile() {
    PROFILE="$(mktemp -d "${TMP}/profile.XXXXXX")"
    chmod 0700 "${PROFILE}"
    RUNTIME_HOME="${PROFILE}/runtime-home"
    mkdir -m 0700 "${RUNTIME_HOME}"
    COPY_LOG="${PROFILE}/copy.log"
}

prepare_store() {
    mkdir -p "${PROFILE}/credentials/ssh"
    chmod 0700 "${PROFILE}/credentials" "${PROFILE}/credentials/ssh"
}

run_add() {
    HOME="${RUNTIME_HOME}" PATH="${TMP}/fake-bin:${PATH}" PI_RUN_PROFILE_DIR="${PROFILE}" \
        SSH_COPY_ID_LOG="${COPY_LOG}" SSH_COPY_ID_STATUS="${SSH_COPY_ID_STATUS:-0}" \
        "${HELPER}" add "$1"
}

expect_add_failure() {
    local target="$1" expected="$2"
    set +e
    FAILURE_OUTPUT="$(run_add "${target}" 2>&1)"
    FAILURE_STATUS=$?
    set -e
    (( FAILURE_STATUS != 0 )) || fail "add unexpectedly succeeded for ${target}"
    [[ "${FAILURE_OUTPUT}" == *"${expected}"* ]] \
        || fail "failure did not contain '${expected}': ${FAILURE_OUTPUT}"
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/ssh-copy-id" <<'EOF'
#!/bin/sh
set -eu
{
    printf 'CALL\n'
    for argument in "$@"; do printf 'ARG=%s\n' "${argument}"; done
} >> "${SSH_COPY_ID_LOG:?}"
exit "${SSH_COPY_ID_STATUS:-0}"
EOF
chmod 0755 "${TMP}/fake-bin/ssh-copy-id"

# A new pair is private, matching, and passed once to ssh-copy-id with host checks.
new_profile
target=deploy@server.example.test
run_add "${target}" >/dev/null
ssh_dir="${PROFILE}/credentials/ssh"
private="${ssh_dir}/${target}"
public="${private}.pub"
[[ -f "${private}" && -f "${public}" ]] || fail "new key pair was not created"
[[ "$(stat -c '%a' "${PROFILE}/credentials")" == 700 ]] || fail "credential directory mode is not 700"
[[ "$(stat -c '%a' "${ssh_dir}")" == 700 ]] || fail "SSH directory mode is not 700"
[[ "$(stat -c '%a' "${private}")" == 600 ]] || fail "private key mode is not 600"
[[ "$(stat -c '%a' "${public}")" == 644 ]] || fail "public key mode is not 644"
[[ "$(stat -c '%a' "${RUNTIME_HOME}/.ssh")" == 700 ]] || fail "runtime SSH directory mode is not 700"
private_fp="$(ssh-keygen -y -P '' -f "${private}" | ssh-keygen -lf - | awk '{print $2}')"
public_fp="$(ssh-keygen -lf "${public}" | awk '{print $2}')"
[[ "${private_fp}" == "${public_fp}" ]] || fail "generated key pair does not match"
[[ "$(grep -c '^CALL$' "${COPY_LOG}")" == 1 ]] || fail "ssh-copy-id was not called exactly once"
grep -Fx "ARG=${public}" "${COPY_LOG}" >/dev/null || fail "public key path was not supplied"
grep -Fx "ARG=UserKnownHostsFile=${ssh_dir}/known_hosts" "${COPY_LOG}" >/dev/null \
    || fail "profile known_hosts was not supplied"
grep -Fx 'ARG=StrictHostKeyChecking=ask' "${COPY_LOG}" >/dev/null \
    || fail "host-key checking was not retained"
grep -Fx "ARG=${target}" "${COPY_LOG}" >/dev/null || fail "explicit target was not supplied"

# Repeating add reuses the pair, performs one new attempt, and preserves it on failure.
before="$(sha256sum "${private}" "${public}")"
SSH_COPY_ID_STATUS=23
expect_add_failure "${target}" "key pair retained"
after="$(sha256sum "${private}" "${public}")"
[[ "${before}" == "${after}" ]] || fail "existing pair changed after failed installation"
[[ "$(grep -c '^CALL$' "${COPY_LOG}")" == 2 ]] || fail "explicit retry did not make one new attempt"
unset SSH_COPY_ID_STATUS

# A first-attempt installation failure also retains a newly generated pair.
new_profile
COPY_LOG="${PROFILE}/copy.log"
SSH_COPY_ID_STATUS=17
expect_add_failure ops@failure.example.test "key pair retained"
[[ -f "${PROFILE}/credentials/ssh/ops@failure.example.test" &&
   -f "${PROFILE}/credentials/ssh/ops@failure.example.test.pub" ]] \
    || fail "new pair was removed after installation failure"
[[ "$(grep -c '^CALL$' "${COPY_LOG}")" == 1 ]] || fail "failed installation was retried"
unset SSH_COPY_ID_STATUS

# Existing incomplete, mismatched, malformed, encrypted, linked, and conflicting data is rejected locally.
new_profile
prepare_store
printf 'partial\n' > "${PROFILE}/credentials/ssh/user@partial.example.test.pub"
expect_add_failure user@partial.example.test "incomplete"
[[ ! -e "${COPY_LOG}" ]] || fail "partial pair reached ssh-copy-id"

new_profile
prepare_store
ssh-keygen -q -t ed25519 -N '' -f "${PROFILE}/credentials/ssh/user@mismatch.example.test"
ssh-keygen -q -t ed25519 -N '' -f "${TMP}/other-key"
cp "${TMP}/other-key.pub" "${PROFILE}/credentials/ssh/user@mismatch.example.test.pub"
expect_add_failure user@mismatch.example.test "does not match"

new_profile
prepare_store
ssh-keygen -q -t ed25519 -N '' -f "${PROFILE}/credentials/ssh/user@privatepub.example.test"
cp "${PROFILE}/credentials/ssh/user@privatepub.example.test" \
    "${PROFILE}/credentials/ssh/user@privatepub.example.test.pub"
expect_add_failure user@privatepub.example.test "public key is invalid"
[[ ! -e "${COPY_LOG}" ]] || fail "private material in a public file reached ssh-copy-id"

new_profile
prepare_store
ssh-keygen -q -t ed25519 -N '' -f "${PROFILE}/credentials/ssh/user@multipub.example.test"
printf '%s\n' "$(<"${TMP}/other-key.pub")" >> \
    "${PROFILE}/credentials/ssh/user@multipub.example.test.pub"
expect_add_failure user@multipub.example.test "public key is invalid"
[[ ! -e "${COPY_LOG}" ]] || fail "multiple public keys reached ssh-copy-id"

new_profile
prepare_store
ssh-keygen -q -t ed25519 -N secret -f "${PROFILE}/credentials/ssh/user@encrypted.example.test"
expect_add_failure user@encrypted.example.test "invalid or encrypted"

new_profile
prepare_store
ln -s /dev/null "${PROFILE}/credentials/ssh/user@linked.example.test"
ln -s /dev/null "${PROFILE}/credentials/ssh/user@linked.example.test.pub"
expect_add_failure user@linked.example.test "not a safe regular file"

new_profile
prepare_store
ssh-keygen -q -t ed25519 -N '' -f "${PROFILE}/credentials/ssh/admin@same.example.test"
expect_add_failure deploy@same.example.test "already has target"
expect_add_failure 'bad target' "invalid SSH target"

# The launcher requests an interactive, host-networked container with no workspace.
HOME_DIR="${TMP}/Pi Run"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
mkdir -p "${TMP}/docker-bin"
cat > "${TMP}/docker-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
: > "${DOCKER_LOG:?}"
for argument in "$@"; do printf '%s\n' "${argument}" >> "${DOCKER_LOG}"; done
EOF
chmod 0755 "${TMP}/docker-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"
PATH="${TMP}/docker-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    PI_RUN_IMAGE=example.invalid/pi-run:add-test \
    "${ROOT}/bin/pi-run" --profile default ssh-key add deploy@server.example.test
profile_dir="$(realpath "${HOME_DIR}/profiles/default")"
grep -Fx -- '-it' "${DOCKER_LOG}" >/dev/null || fail "interactive mode was not requested"
grep -Fx -- 'host' "${DOCKER_LOG}" >/dev/null || fail "host networking was not requested"
grep -Fx -- "type=bind,src=${profile_dir},dst=/profile" "${DOCKER_LOG}" >/dev/null \
    || fail "selected profile was not mounted read-write"
grep -Fx -- 'add' "${DOCKER_LOG}" >/dev/null || fail "add operation was not requested"
grep -Fx -- 'deploy@server.example.test' "${DOCKER_LOG}" >/dev/null || fail "target was not forwarded"
grep -Fx -- 'example.invalid/pi-run:add-test' "${DOCKER_LOG}" >/dev/null \
    || fail "runtime image override was ignored"
if grep -Eq 'dst=/workspace|dst=/profile,readonly|^none$' "${DOCKER_LOG}"; then
    fail "add exposed a workspace, mounted the profile read-only, or disabled networking"
fi

echo "SSH key add tests passed"
