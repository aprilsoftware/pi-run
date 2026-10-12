#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/docker/ssh-credentials"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "ssh-key-remove-test: $*" >&2
    exit 1
}

new_profile() {
    PROFILE="$(mktemp -d "${TMP}/profile.XXXXXX")"
    SSH_DIR="${PROFILE}/credentials/ssh"
    mkdir -p "${SSH_DIR}"
    chmod 0700 "${PROFILE}" "${PROFILE}/credentials" "${SSH_DIR}"
}

make_key() {
    ssh-keygen -q -t ed25519 -N '' -f "${SSH_DIR}/$1"
}

run_remove() {
    local answer="$1" target="$2"
    printf '%s\n' "${answer}" | PI_RUN_PROFILE_DIR="${PROFILE}" "${HELPER}" remove "${target}"
}

expect_failure() {
    local answer="$1" target="$2" expected="$3"
    set +e
    FAILURE_OUTPUT="$(run_remove "${answer}" "${target}" 2>&1)"
    FAILURE_STATUS=$?
    set -e
    (( FAILURE_STATUS != 0 )) || fail "remove unexpectedly succeeded for ${target}"
    [[ "${FAILURE_OUTPUT}" == *"${expected}"* ]] \
        || fail "failure did not contain '${expected}': ${FAILURE_OUTPUT}"
}

# Confirmed removal deletes only the exact pair.
new_profile
make_key deploy@server.example.test
make_key keep@other.example.test
printf 'trusted host fixture\n' > "${SSH_DIR}/known_hosts"
known_before="$(sha256sum "${SSH_DIR}/known_hosts")"
unrelated_before="$(sha256sum "${SSH_DIR}/keep@other.example.test" "${SSH_DIR}/keep@other.example.test.pub")"
output="$(run_remove yes deploy@server.example.test 2>&1)"
[[ ! -e "${SSH_DIR}/deploy@server.example.test" &&
   ! -e "${SSH_DIR}/deploy@server.example.test.pub" ]] || fail "selected pair was not removed"
[[ "$(sha256sum "${SSH_DIR}/known_hosts")" == "${known_before}" ]] || fail "known_hosts changed"
[[ "$(sha256sum "${SSH_DIR}/keep@other.example.test" "${SSH_DIR}/keep@other.example.test.pub")" == "${unrelated_before}" ]] \
    || fail "unrelated key changed"
[[ "${output}" == *"Remote authorized_keys was not changed."* ]] \
    || fail "remote authorization warning was missing"
[[ -d "${SSH_DIR}" ]] || fail "credential directory was removed"

# Partial pairs can be removed.
new_profile
make_key partial@server.example.test
rm "${SSH_DIR}/partial@server.example.test.pub"
run_remove y partial@server.example.test >/dev/null 2>&1
[[ ! -e "${SSH_DIR}/partial@server.example.test" ]] || fail "private-only key was not removed"
new_profile
make_key partial@server.example.test
rm "${SSH_DIR}/partial@server.example.test"
run_remove y partial@server.example.test >/dev/null 2>&1
[[ ! -e "${SSH_DIR}/partial@server.example.test.pub" ]] || fail "public-only key was not removed"

# Cancellation preserves both files.
new_profile
make_key cancel@server.example.test
before="$(sha256sum "${SSH_DIR}/cancel@server.example.test" "${SSH_DIR}/cancel@server.example.test.pub")"
expect_failure n cancel@server.example.test "Removal cancelled"
after="$(sha256sum "${SSH_DIR}/cancel@server.example.test" "${SSH_DIR}/cancel@server.example.test.pub")"
[[ "${before}" == "${after}" ]] || fail "cancelled removal changed the pair"

# Final symlinks are unlinked without touching their targets.
new_profile
outside_private="${TMP}/outside-private"
outside_public="${TMP}/outside-public"
printf 'outside private\n' > "${outside_private}"
printf 'outside public\n' > "${outside_public}"
ln -s "${outside_private}" "${SSH_DIR}/linked@server.example.test"
ln -s "${outside_public}" "${SSH_DIR}/linked@server.example.test.pub"
run_remove yes linked@server.example.test >/dev/null 2>&1
[[ ! -L "${SSH_DIR}/linked@server.example.test" &&
   ! -L "${SSH_DIR}/linked@server.example.test.pub" ]] || fail "key symlinks were not removed"
[[ "$(<"${outside_private}")" == "outside private" && "$(<"${outside_public}")" == "outside public" ]] \
    || fail "symlink targets were modified"

# Invalid and missing targets do not affect stored data.
new_profile
make_key keep@server.example.test
before="$(sha256sum "${SSH_DIR}/keep@server.example.test" "${SSH_DIR}/keep@server.example.test.pub")"
expect_failure yes '../bad' "invalid SSH target"
missing_output="$(run_remove yes absent@server.example.test)"
[[ "${missing_output}" == "No local SSH key files found for absent@server.example.test." ]] \
    || fail "missing target was not reported"
[[ "$(sha256sum "${SSH_DIR}/keep@server.example.test" "${SSH_DIR}/keep@server.example.test.pub")" == "${before}" ]] \
    || fail "invalid or missing removal changed unrelated data"

# The launcher uses an interactive, networkless container and no workspace.
HOME_DIR="${TMP}/Pi Run"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
: > "${DOCKER_LOG:?}"
for argument in "$@"; do printf '%s\n' "${argument}" >> "${DOCKER_LOG}"; done
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"
PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    PI_RUN_IMAGE=example.invalid/pi-run:remove-test \
    "${ROOT}/bin/pi-run" --profile default ssh-key remove deploy@server.example.test
profile_dir="$(realpath "${HOME_DIR}/profiles/default")"
grep -Fx -- '-it' "${DOCKER_LOG}" >/dev/null || fail "interactive mode was not requested"
grep -Fx -- 'none' "${DOCKER_LOG}" >/dev/null || fail "networking was not disabled"
grep -Fx -- "type=bind,src=${profile_dir},dst=/profile" "${DOCKER_LOG}" >/dev/null \
    || fail "selected profile was not mounted read-write"
grep -Fx -- 'remove' "${DOCKER_LOG}" >/dev/null || fail "remove operation was not requested"
grep -Fx -- 'deploy@server.example.test' "${DOCKER_LOG}" >/dev/null || fail "target was not forwarded"
grep -Fx -- 'example.invalid/pi-run:remove-test' "${DOCKER_LOG}" >/dev/null \
    || fail "runtime image override was ignored"
if grep -Eq 'dst=/workspace|dst=/profile,readonly|^host$' "${DOCKER_LOG}"; then
    fail "remove exposed a workspace, mounted the profile read-only, or enabled host networking"
fi

echo "SSH key removal tests passed"
