#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/docker/ssh-credentials"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "ssh-key-list-test: $*" >&2
    exit 1
}

make_key() {
    local directory="$1" target="$2" passphrase="${3:-}"
    ssh-keygen -q -t ed25519 -N "${passphrase}" -f "${directory}/${target}"
}

status_for() {
    local output="$1" target="$2"
    awk -v target="${target}" '$1 == target { print $2 }' <<< "${output}"
}

fingerprint_for() {
    local output="$1" target="$2"
    awk -v target="${target}" '$1 == target { print $3 }' <<< "${output}"
}

PROFILE="${TMP}/profile"
SSH_DIR="${PROFILE}/credentials/ssh"
mkdir -p "${SSH_DIR}"
chmod 0700 "${PROFILE}" "${PROFILE}/credentials" "${SSH_DIR}"

make_key "${SSH_DIR}" valid@valid.example.test
valid_fp="$(ssh-keygen -lf "${SSH_DIR}/valid@valid.example.test.pub" | awk '{print $2}')"

make_key "${SSH_DIR}" private@private.example.test
rm "${SSH_DIR}/private@private.example.test.pub"

make_key "${SSH_DIR}" public@public.example.test
rm "${SSH_DIR}/public@public.example.test"

make_key "${SSH_DIR}" encrypted@encrypted.example.test secret

make_key "${SSH_DIR}" invalidpub@invalidpub.example.test
printf 'invalid public key\n' > "${SSH_DIR}/invalidpub@invalidpub.example.test.pub"

make_key "${SSH_DIR}" mismatch@mismatch.example.test
make_key "${TMP}" replacement
cp "${TMP}/replacement.pub" "${SSH_DIR}/mismatch@mismatch.example.test.pub"

make_key "${SSH_DIR}" deploy@ambiguous.example.test
make_key "${SSH_DIR}" admin@ambiguous.example.test
make_key "${SSH_DIR}" locked@ambiguous.example.test secret
make_key "${SSH_DIR}" operator@long-control-plane.office2.example.test

ln -s /dev/null "${SSH_DIR}/unsafe@unsafe.example.test"
printf 'not a key\n' > "${SSH_DIR}/loose@loose.example.test"
chmod 0644 "${SSH_DIR}/loose@loose.example.test"
ln -s /dev/null "${SSH_DIR}/known_hosts"

before="$(find "${SSH_DIR}" -type f -printf '%P ' -exec sha256sum {} \; | sort)"
output="$(PI_RUN_PROFILE_DIR="${PROFILE}" "${HELPER}" list)"
after="$(find "${SSH_DIR}" -type f -printf '%P ' -exec sha256sum {} \; | sort)"
[[ "${before}" == "${after}" ]] || fail "listing modified credential contents"

[[ "$(status_for "${output}" valid@valid.example.test)" == valid ]] || fail "valid pair not reported"
[[ "$(fingerprint_for "${output}" valid@valid.example.test)" == "${valid_fp}" ]] \
    || fail "valid fingerprint is incorrect"
[[ "$(status_for "${output}" private@private.example.test)" == private-only ]] \
    || fail "private-only key not reported"
[[ "$(status_for "${output}" public@public.example.test)" == public-only ]] \
    || fail "public-only key not reported"
[[ "$(status_for "${output}" encrypted@encrypted.example.test)" == invalid-or-encrypted-private ]] \
    || fail "encrypted private key not reported"
[[ "$(status_for "${output}" invalidpub@invalidpub.example.test)" == invalid-public ]] \
    || fail "invalid public key not reported"
[[ "$(status_for "${output}" mismatch@mismatch.example.test)" == mismatched-pair ]] \
    || fail "mismatched pair not reported"
[[ "$(status_for "${output}" deploy@ambiguous.example.test)" == ambiguous-host:valid ]] \
    || fail "first ambiguous target not reported"
[[ "$(status_for "${output}" admin@ambiguous.example.test)" == ambiguous-host:valid ]] \
    || fail "second ambiguous target not reported"
[[ "$(status_for "${output}" locked@ambiguous.example.test)" == ambiguous-host:invalid-or-encrypted-private ]] \
    || fail "long ambiguous status not reported"
[[ "$(status_for "${output}" unsafe@unsafe.example.test)" == unsafe-entry ]] \
    || fail "linked key not reported as unsafe"
[[ "$(status_for "${output}" loose@loose.example.test)" == unsafe-entry ]] \
    || fail "permissive private key not reported as unsafe"
[[ "$(status_for "${output}" known_hosts)" == unsafe-entry ]] \
    || fail "linked known_hosts not reported as unsafe"
[[ "${output}" != *"OPENSSH PRIVATE KEY"* ]] || fail "listing exposed private-key contents"

header="$(sed -n '1p' <<< "${output}")"
status_column="$(awk 'NR == 1 { print index($0, "STATUS") }' <<< "${header}")"
fingerprint_column="$(awk 'NR == 1 { print index($0, "FINGERPRINT") }' <<< "${header}")"
[[ "${status_column}" -gt 1 && "${fingerprint_column}" -gt "${status_column}" ]] \
    || fail "listing headers are missing or unordered"
while IFS= read -r row; do
    read -r _target row_status row_fingerprint <<< "${row}"
    [[ "${row:$((status_column - 1)):${#row_status}}" == "${row_status}" ]] \
        || fail "status is not aligned with its header: ${row}"
    [[ "${row:$((fingerprint_column - 1)):${#row_fingerprint}}" == "${row_fingerprint}" ]] \
        || fail "fingerprint is not aligned with its header: ${row}"
done < <(tail -n +2 <<< "${output}")

EMPTY_PROFILE="${TMP}/empty-profile"
mkdir -m 0700 "${EMPTY_PROFILE}"
empty_output="$(PI_RUN_PROFILE_DIR="${EMPTY_PROFILE}" "${HELPER}" list)"
[[ "${empty_output}" == "No SSH keys stored." ]] || fail "empty store was not reported explicitly"

# The launcher uses a short-lived, networkless container and a read-only profile.
HOME_DIR="${TMP}/Pi Run"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
: > "${DOCKER_LOG:?}"
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG}"
done
printf 'container-list-output\n'
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"
launcher_output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    PI_RUN_IMAGE=example.invalid/pi-run:list-test \
    "${ROOT}/bin/pi-run" --profile default ssh-key list)"
[[ "${launcher_output}" == "container-list-output" ]] || fail "launcher did not return container output"

profile_dir="$(realpath "${HOME_DIR}/profiles/default")"
grep -Fx -- "type=bind,src=${profile_dir},dst=/profile,readonly" "${DOCKER_LOG}" >/dev/null \
    || fail "selected profile was not mounted read-only"
grep -Fx -- 'none' "${DOCKER_LOG}" >/dev/null || fail "network was not disabled"
grep -Fx -- 'PI_RUN_SKIP_SSH_CONFIG=1' "${DOCKER_LOG}" >/dev/null \
    || fail "management configuration bypass was not supplied"
grep -Fx -- '/usr/local/bin/entrypoint.sh' "${DOCKER_LOG}" >/dev/null \
    || fail "runtime entrypoint was not selected"
grep -Fx -- '/usr/local/bin/ssh-credentials' "${DOCKER_LOG}" >/dev/null \
    || fail "credential helper was not invoked"
grep -Fx -- 'list' "${DOCKER_LOG}" >/dev/null || fail "list operation was not requested"
grep -Fx -- 'example.invalid/pi-run:list-test' "${DOCKER_LOG}" >/dev/null \
    || fail "runtime image override was ignored"
if grep -Eq 'dst=/workspace|^host$|^-it$' "${DOCKER_LOG}"; then
    fail "listing exposed a workspace, host network, or interactive terminal"
fi

echo "SSH key listing tests passed"
