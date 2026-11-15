#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

DEFAULT_CORE_ID="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DEFAULT_PREPARED_ID="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
DEFAULT_CONTEXT="1e3a46e7165f07fca07f4dc4686fdc098da9f6ff5437d96950ad03dd9df36e3e"
DEFAULT_SOURCE="4fe9e19d6673b45a251150c6f8bb2573e1c7c1e9d3e09372d144de75ce9660d3"

if [[ "${1:-}" == --emit-image ]]; then
    ref="${2:?}"
    state="${RUNTIME_IMAGE_STATE:-matching}"
    core_id="${RUNTIME_FIXTURE_CORE_ID:-${DEFAULT_CORE_ID}}"
    context="${RUNTIME_FIXTURE_CONTEXT:-${DEFAULT_CONTEXT}}"
    source="${RUNTIME_FIXTURE_SOURCE:-${DEFAULT_SOURCE}}"
    if [[ "${state}" == core-identity && "${ref}" != pi-run-profile:* ]]; then
        core_id="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    fi
    if [[ "${ref}" == pi-run-profile:* ]]; then
        [[ "${state}" != prepared-missing ]] || exit 1
        [[ "${state}" != malformed ]] || { printf '[]\n'; exit 0; }
        arch=amd64
        [[ "${state}" != prepared-architecture ]] || arch=arm64
        [[ "${state}" != stale ]] || source=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
        printf '[{"Id":"%s","Architecture":"%s","Config":{"Labels":{' \
            "${DEFAULT_PREPARED_ID}" "${arch}"
        printf '"io.aprilsoftware.pi-run.runtime.contract":"1",'
        printf '"io.aprilsoftware.pi-run.runtime.core-id":"%s",' "${core_id}"
        printf '"io.aprilsoftware.pi-run.runtime.context-sha256":"%s",' "${context}"
        printf '"io.aprilsoftware.pi-run.runtime.source-sha256":"%s",' "${source}"
        printf '"io.aprilsoftware.pi-run.runtime.architecture":"amd64"}}}]\n'
    else
        [[ "${state}" != core-missing ]] || exit 1
        arch=amd64
        [[ "${state}" != core-architecture ]] || arch=arm64
        printf '[{"Id":"%s","Architecture":"%s","Config":{"Labels":{}}}]\n' \
            "${core_id}" "${arch}"
    fi
    exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "runtime-launch-selection-test: $*" >&2
    exit 1
}

expect_failure() {
    local status
    set +e
    "$@" >"${TMP}/failure.out" 2>&1
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "command unexpectedly succeeded: $*"
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
case "${1:-} ${2:-}" in
    'info ') exit 0 ;;
    'image inspect') exec "${RUNTIME_IMAGE_FIXTURE:?}" --emit-image "${3:?}" ;;
    run\ *)
        printf '%s\n' "$@" > "${DOCKER_RUN_LOG:?}"
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export PATH="${TMP}/fake-bin:${PATH}"
export RUNTIME_IMAGE_FIXTURE="${ROOT}/tests/runtime-launch-selection-test.sh"
export DOCKER_RUN_LOG="${TMP}/docker-run.log"

home="${TMP}/Pi Run"
workspace="${TMP}/workspace"
mkdir -p "${workspace}"
PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" init >/dev/null

PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" runtime status > "${TMP}/identity.out"
actual_context="$(sed -n 's/^Context SHA-256: //p' "${TMP}/identity.out")"
actual_source="$(sed -n 's/^Source identity: //p' "${TMP}/identity.out")"
[[ "${actual_context}" == "${DEFAULT_CONTEXT}" && "${actual_source}" == "${DEFAULT_SOURCE}" ]] \
    || fail "shared launch fixture identity is out of date"

PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" "${workspace}" --version \
    > "${TMP}/launch.out" 2> "${TMP}/launch.err"
prepared_tag="$(sed -n 's/^pi-run: runtime=//p' "${TMP}/launch.err")"
[[ "${prepared_tag}" =~ ^pi-run-profile:[0-9a-f]{24}$ ]] \
    || fail "launch did not report its prepared profile image"
grep -Fx "${prepared_tag}" "${DOCKER_RUN_LOG}" >/dev/null \
    || fail "launch did not use the prepared profile image"
if grep -Fx "ghcr.io/aprilsoftware/pi-run:$(< "${ROOT}/VERSION")" "${DOCKER_RUN_LOG}" >/dev/null; then
    fail "launch fell back to the release image"
fi

PI_RUN_IMAGE=example.invalid/utility:override PI_RUN_HOME="${home}" \
    "${ROOT}/bin/pi-run" "${workspace}" --version >/dev/null 2> "${TMP}/override.err"
grep -Fx "${prepared_tag}" "${DOCKER_RUN_LOG}" >/dev/null \
    || fail "PI_RUN_IMAGE bypassed prepared profile selection"

for state in prepared-missing stale malformed prepared-architecture core-missing core-architecture core-identity; do
    rm -f "${DOCKER_RUN_LOG}"
    expect_failure env RUNTIME_IMAGE_STATE="${state}" PI_RUN_HOME="${home}" \
        "${ROOT}/bin/pi-run" "${workspace}" --version
    grep -F 'run: pi-run --profile default runtime build' "${TMP}/failure.out" >/dev/null \
        || fail "${state} failure omitted the rebuild command"
    [[ ! -e "${DOCKER_RUN_LOG}" ]] || fail "${state} failure started the workload container"
done

rm -rf "${home}/profiles/default/sessions"
mkdir -m 0700 "${home}/profiles/default/sessions"
rm -f "${DOCKER_RUN_LOG}"
printf '# local runtime change\n' >> "${home}/profiles/default/runtime/Dockerfile"
expect_failure env PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" "${workspace}" --version
grep -F 'prepared profile runtime is stale or incompatible' "${TMP}/failure.out" >/dev/null \
    || fail "changed runtime context did not refuse launch"
[[ -z "$(find "${home}/profiles/default/sessions" -mindepth 1 -print -quit)" ]] \
    || fail "failed launch created profile session state"
[[ ! -e "${DOCKER_RUN_LOG}" ]] || fail "changed runtime context started the workload container"

echo "runtime launch selection tests passed"
