#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "runtime-status-test: $*" >&2
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

field() {
    local label="$1" file="$2"
    sed -n "s/^${label}: //p" "${file}"
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
case "${1:-} ${2:-}" in
    'info ')
        [ "${DOCKER_MODE:-}" != daemon-unavailable ]
        ;;
    'image inspect')
        image=${3:-}
        if [ "${image}" = "${CORE_REF:?}" ]; then
            [ "${DOCKER_MODE:-}" != core-missing ] || exit 1
            printf '[{"Id":"%s","Architecture":"%s","Config":{"Labels":{}}}]\n' \
                "${CORE_ID:?}" "${CORE_ARCH:-amd64}"
            exit 0
        fi
        [ "${image}" = "${PREPARED_TAG:-}" ] || exit 1
        case "${DOCKER_MODE:-}" in
            prepared-missing|core-ready) exit 1 ;;
            matching)
                source_label=${EXPECTED_SOURCE:?}
                context_label=${EXPECTED_CONTEXT:?}
                ;;
            stale)
                source_label=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
                context_label=${EXPECTED_CONTEXT:?}
                ;;
            *) exit 1 ;;
        esac
        printf '[{"Id":"%s","Architecture":"%s","Config":{"Labels":{' \
            "${PREPARED_ID:?}" "${PREPARED_ARCH:-amd64}"
        printf '"io.aprilsoftware.pi-run.runtime.contract":"1",'
        printf '"io.aprilsoftware.pi-run.runtime.core-id":"%s",' "${CORE_ID}"
        printf '"io.aprilsoftware.pi-run.runtime.context-sha256":"%s",' "${context_label}"
        printf '"io.aprilsoftware.pi-run.runtime.source-sha256":"%s",' "${source_label}"
        printf '"io.aprilsoftware.pi-run.runtime.architecture":"amd64"}}}]\n'
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

export PATH="${TMP}/fake-bin:${PATH}"
export DOCKER_LOG="${TMP}/docker.log"
export CORE_REF=example.invalid/pi-run-core:test
CORE_ID="sha256:$(printf 'a%.0s' {1..64})"
PREPARED_ID="sha256:$(printf 'b%.0s' {1..64})"
export CORE_ID PREPARED_ID

UNINITIALIZED="${TMP}/uninitialized"
expect_failure env PI_RUN_HOME="${UNINITIALIZED}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" runtime status
[[ ! -e "${UNINITIALIZED}" ]] || fail "runtime status initialized an absent home"

HOME_DIR="${TMP}/Pi Run"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
runtime_dir="${HOME_DIR}/profiles/default/runtime"
dockerfile="${runtime_dir}/Dockerfile"
dockerfile_hash="$(sha256sum "${dockerfile}" | awk '{print $1}')"

: > "${DOCKER_LOG}"
DOCKER_MODE=daemon-unavailable PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" runtime status > "${TMP}/unavailable.out"
grep -Fx 'Core state: unavailable (Docker daemon unavailable)' \
    "${TMP}/unavailable.out" >/dev/null || fail "daemon-unavailable state was not reported"
[[ "$(sha256sum "${dockerfile}" | awk '{print $1}')" == "${dockerfile_hash}" ]] \
    || fail "runtime status changed the Dockerfile"

: > "${DOCKER_LOG}"
DOCKER_MODE=core-missing PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" runtime status > "${TMP}/missing-core.out"
grep -Fx 'Core state: missing' "${TMP}/missing-core.out" >/dev/null \
    || fail "missing core image was not reported"
grep -Fx 'Prepared state: unavailable' "${TMP}/missing-core.out" >/dev/null \
    || fail "missing core did not make prepared state unavailable"

DOCKER_MODE=core-ready PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" runtime status > "${TMP}/prepared-missing.out"
context_sha="$(field 'Context SHA-256' "${TMP}/prepared-missing.out")"
source_sha="$(field 'Source identity' "${TMP}/prepared-missing.out")"
prepared_tag="$(field 'Prepared tag' "${TMP}/prepared-missing.out")"
[[ "${context_sha}" =~ ^[0-9a-f]{64}$ && "${source_sha}" =~ ^[0-9a-f]{64}$ ]] \
    || fail "runtime status did not produce stable source identities"
grep -Fx 'Core state: ready' "${TMP}/prepared-missing.out" >/dev/null \
    || fail "ready core image was not reported"
grep -Fx 'Prepared state: missing' "${TMP}/prepared-missing.out" >/dev/null \
    || fail "missing prepared image was not reported"

export PREPARED_TAG="${prepared_tag}"
export EXPECTED_CONTEXT="${context_sha}"
export EXPECTED_SOURCE="${source_sha}"
DOCKER_MODE=matching PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" runtime status > "${TMP}/matching.out"
grep -Fx 'Prepared state: matching' "${TMP}/matching.out" >/dev/null \
    || fail "matching prepared image labels were not accepted"
grep -Fx "Prepared identity: ${PREPARED_ID}" "${TMP}/matching.out" >/dev/null \
    || fail "prepared image identity was not reported"
DOCKER_MODE=stale PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" runtime status > "${TMP}/stale.out"
grep -Fx 'Prepared state: stale' "${TMP}/stale.out" >/dev/null \
    || fail "stale prepared image labels were not reported"

CORE_ARCH=arm64 DOCKER_MODE=core-ready PI_RUN_HOME="${HOME_DIR}" \
    PI_RUN_CORE_IMAGE="${CORE_REF}" "${ROOT}/bin/pi-run" runtime status \
    > "${TMP}/architecture.out"
grep -Fx 'Core state: incompatible architecture (arm64)' \
    "${TMP}/architecture.out" >/dev/null || fail "core architecture mismatch was not reported"
unset CORE_ARCH

identity_profile="${HOME_DIR}/profiles/identity"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create identity >/dev/null
identity_runtime="${identity_profile}/runtime"
DOCKER_MODE=core-missing PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" --profile identity runtime status > "${TMP}/identity-1.out"
identity_1="$(field 'Context SHA-256' "${TMP}/identity-1.out")"
printf 'one\n' > "${identity_runtime}/asset"
DOCKER_MODE=core-missing PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" --profile identity runtime status > "${TMP}/identity-2.out"
identity_2="$(field 'Context SHA-256' "${TMP}/identity-2.out")"
chmod 0640 "${identity_runtime}/asset"
DOCKER_MODE=core-missing PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" --profile identity runtime status > "${TMP}/identity-3.out"
identity_3="$(field 'Context SHA-256' "${TMP}/identity-3.out")"
mv "${identity_runtime}/asset" "${identity_runtime}/renamed"
DOCKER_MODE=core-missing PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" --profile identity runtime status > "${TMP}/identity-4.out"
identity_4="$(field 'Context SHA-256' "${TMP}/identity-4.out")"
ln -s first-target "${identity_runtime}/link"
DOCKER_MODE=core-missing PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" --profile identity runtime status > "${TMP}/identity-5.out"
identity_5="$(field 'Context SHA-256' "${TMP}/identity-5.out")"
rm "${identity_runtime}/link"
ln -s second-target "${identity_runtime}/link"
DOCKER_MODE=core-missing PI_RUN_HOME="${HOME_DIR}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${ROOT}/bin/pi-run" --profile identity runtime status > "${TMP}/identity-6.out"
identity_6="$(field 'Context SHA-256' "${TMP}/identity-6.out")"
[[ "${identity_1}" != "${identity_2}" && "${identity_2}" != "${identity_3}" &&
   "${identity_3}" != "${identity_4}" && "${identity_4}" != "${identity_5}" &&
   "${identity_5}" != "${identity_6}" ]] \
    || fail "runtime identity ignored content, mode, path, or symlink-target changes"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create changing >/dev/null
changing_runtime="${HOME_DIR}/profiles/changing/runtime"
printf 'before\n' > "${changing_runtime}/changing"
real_cat="$(command -v cat)"
mkdir "${TMP}/changing-bin"
cat > "${TMP}/changing-bin/cat" <<'EOF'
#!/bin/sh
set -eu
changing=false
for argument in "$@"; do
    [ "${argument}" != ./changing ] || changing=true
done
if [ "${changing}" = true ] && [ ! -e "${CAT_CHANGED:?}" ]; then
    "${REAL_CAT:?}" "$@"
    : > "${CAT_CHANGED}"
    printf 'after\n' >> ./changing
    exit 0
fi
exec "${REAL_CAT:?}" "$@"
EOF
chmod 0755 "${TMP}/changing-bin/cat"
expect_failure env PATH="${TMP}/changing-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    PI_RUN_CORE_IMAGE="${CORE_REF}" DOCKER_MODE=core-missing \
    CAT_CHANGED="${TMP}/cat-changed" REAL_CAT="${real_cat}" \
    "${ROOT}/bin/pi-run" --profile changing runtime status
grep -F 'changed during inspection' "${TMP}/failure.out" >/dev/null \
    || fail "changing runtime context did not fail closed"

if grep -E '(^| )(pull|build|run)( |$)' "${DOCKER_LOG}" >/dev/null; then
    fail "runtime status invoked a mutating Docker operation"
fi

"${ROOT}/scripts/build-release" "${TMP}/release" >/dev/null
version="$(tr -d '\r\n' < "${ROOT}/VERSION")"
tar -xzf "${TMP}/release/pi-run-${version}.tar.gz" -C "${TMP}"
package="${TMP}/pi-run-${version}"
packaged_home="${TMP}/packaged-home"
PI_RUN_HOME="${packaged_home}" "${package}/bin/pi-run" init >/dev/null
DOCKER_MODE=core-ready PI_RUN_HOME="${packaged_home}" PI_RUN_CORE_IMAGE="${CORE_REF}" \
    "${package}/bin/pi-run" runtime status > "${TMP}/packaged.out"
grep -E '^Source identity: [0-9a-f]{64}$' "${TMP}/packaged.out" >/dev/null \
    || fail "packaged runtime status did not produce a source identity"

echo "runtime status tests passed"
