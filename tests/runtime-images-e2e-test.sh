#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${PI_RUN_TEST_REAL_DOCKER:-0}" != 1 ]]; then
    echo "runtime-images-e2e-test: SKIP (set PI_RUN_TEST_REAL_DOCKER=1 to use real Docker)"
    exit 0
fi

fail() {
    echo "runtime-images-e2e-test: $*" >&2
    exit 1
}

for command_name in docker jq script sha256sum; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "required command unavailable: ${command_name}"
done
[[ "$(uname -s)" == Linux && "$(uname -m)" =~ ^(x86_64|amd64)$ ]] \
    || fail "real-Docker runtime acceptance requires Linux/amd64"
docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
[[ "${HOST_UID}" != 0 && "${HOST_GID}" != 0 ]] \
    || fail "real-Docker runtime acceptance must run as a non-root user"
[[ -f /etc/ssl/certs/ca-certificates.crt ]] \
    || fail "host CA bundle is unavailable"

if [[ -r /proc/sys/kernel/random/uuid ]]; then
    suffix="$(tr -d - < /proc/sys/kernel/random/uuid)"
elif command -v uuidgen >/dev/null 2>&1; then
    suffix="$(uuidgen | tr -d - | tr '[:upper:]' '[:lower:]')"
else
    fail "no UUID source is available"
fi
[[ "${suffix}" =~ ^[0-9a-f]{32}$ ]] || fail "generated image suffix is invalid"

TMP="$(mktemp -d)"
HOME_DIR="${TMP}/Pi Run"
WORKSPACE="${TMP}/workspace"
CORE_TAG="pi-run-runtime-e2e-core:${suffix}"
PREPARED_TAG=""
cleanup() {
    if [[ -n "${PREPARED_TAG}" ]]; then
        docker image rm -f "${PREPARED_TAG}" >/dev/null 2>&1 || true
    fi
    docker image rm -f "${CORE_TAG}" >/dev/null 2>&1 || true
    rm -rf "${TMP}"
}
trap cleanup EXIT
mkdir -p "${WORKSPACE}"

printf 'Building disposable Pi-Run core image...\n'
docker build \
    --file "${ROOT}/docker/core/Dockerfile" \
    --tag "${CORE_TAG}" \
    "${ROOT}/docker"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" runtime add all >/dev/null
cmp "${ROOT}/templates/runtime/full-development.Dockerfile" \
    "${HOME_DIR}/profiles/default/runtime/Dockerfile" \
    || fail "runtime add all did not produce the maintained full-development Dockerfile"

printf 'Building disposable full-development profile image...\n'
PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_TAG}" \
    "${ROOT}/bin/pi-run" runtime build
status_output="$(PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_TAG}" \
    "${ROOT}/bin/pi-run" runtime status)"
PREPARED_TAG="$(sed -n 's/^Prepared tag: //p' <<<"${status_output}")"
[[ "${PREPARED_TAG}" =~ ^pi-run-profile:[0-9a-f]{24}$ ]] \
    || fail "runtime status returned an invalid prepared image tag"
grep -Fx 'Prepared state: matching' <<<"${status_output}" >/dev/null \
    || fail "built full-development image is not matching"

printf 'Checking mapped startup, Java CA initialization, and privilege drop...\n'
mapped_identity="$(docker run --rm --pull never --network none \
    --cap-drop ALL \
    --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_READ_SEARCH \
    --security-opt no-new-privileges \
    --mount "type=bind,src=${HOME_DIR}/profiles/default,dst=/profile" \
    --mount "type=bind,src=/etc/ssl/certs/ca-certificates.crt,dst=/etc/ssl/certs/ca-certificates.crt,readonly" \
    --env "HOST_UID=${HOST_UID}" --env "HOST_GID=${HOST_GID}" \
    --env PI_RUN_SKIP_SSH_CONFIG=1 \
    --entrypoint /usr/local/bin/entrypoint.sh \
    "${PREPARED_TAG}" bash -c 'printf "%s:%s\n" "$(id -u)" "$(id -g)"; test -r /etc/ssl/certs/java/cacerts')"
[[ "${mapped_identity}" == "${HOST_UID}:${HOST_GID}" ]] \
    || fail "entrypoint did not map and drop to the host identity"

printf 'Checking full-development capabilities without network access...\n'
docker run --rm --pull never --network none \
    --entrypoint bash "${PREPARED_TAG}" -c '
        set -euo pipefail
        pi --version
        node --version
        git --version
        ssh -V
        restic version
        shellcheck --version
        python3 -c "print(\"python-ok\")"
        printf "%s\n" "#include <stdio.h>" "int main(void){puts(\"c-ok\");}" > /tmp/main.c
        gcc /tmp/main.c -o /tmp/main-c
        test "$(/tmp/main-c)" = c-ok
        printf "%s\n" "#include <iostream>" "int main(){std::cout << \"cpp-ok\\n\";}" > /tmp/main.cpp
        g++ /tmp/main.cpp -o /tmp/main-cpp
        test "$(/tmp/main-cpp)" = cpp-ok
        printf "%s\n" "public class Main { public static void main(String[] a) { System.out.println(\"java-ok\"); } }" > /tmp/Main.java
        javac /tmp/Main.java
        test "$(java -cp /tmp Main)" = java-ok
        mvn --version
        printf "%s\n" "fn main(){println!(\"rust-ok\");}" > /tmp/main.rs
        rustc /tmp/main.rs -o /tmp/main-rust
        test "$(/tmp/main-rust)" = rust-ok
        cargo --version
        rustfmt --version
        cargo clippy --version
        ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote \
            ansible localhost -i localhost, -c local -m ansible.builtin.ping
        xvfb-run --server-args="-screen 0 1280x720x24 -nolisten tcp" true
        ldconfig -p | grep -F "libxcb-xkb.so.1"
        ldconfig -p | grep -F "libxkbcommon-x11.so.0"
        CI=true FLUTTER_SUPPRESS_ANALYTICS=true flutter --version
        dart --version
        mysql --version
        psql --version
        redis-cli --version
        sqlite3 --version
        kubectl version --client
        helm version --short
        kustomize version
        yq --version
    '

printf 'Checking the real launcher with the prepared profile image...\n'
printf -v launch_command '%q ' env \
    "PI_RUN_HOME=${HOME_DIR}" \
    "PI_RUN_CORE_IMAGE=${CORE_TAG}" \
    "PI_RUN_IMAGE=${CORE_TAG}" \
    "${ROOT}/bin/pi-run" "${WORKSPACE}" --version
script -qefc "${launch_command}" /dev/null > "${TMP}/launcher.out"
grep -E '(^|[^0-9])1\.5\.2([^0-9]|$)' "${TMP}/launcher.out" >/dev/null \
    || fail "real launcher did not execute the expected Pi version"

printf 'runtime image real-Docker acceptance passed\n'
