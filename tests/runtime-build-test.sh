#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "runtime-build-test: $*" >&2
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

assert_clean_stages() {
    [[ ! -e "${DOCKER_STATE}/stage-tag" && ! -e "${DOCKER_STATE}/frozen-tag" ]] \
        || fail "temporary runtime build tags were not cleaned"
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
state=${DOCKER_STATE:?}
log=${DOCKER_LOG:?}
core_id=${CORE_ID:?}
built_id=${BUILT_ID:?}
mkdir -p "$state"
printf 'COMMAND' >> "$log"
for argument in "$@"; do printf ' <%s>' "$argument" >> "$log"; done
printf '\n' >> "$log"

label_value() {
    key=$1 file=$2
    sed -n "s|^${key}=||p" "$file"
}

emit_built() {
    labels=$1
    arch=${BUILT_ARCH:-amd64}
    contract=$(label_value io.aprilsoftware.pi-run.runtime.contract "$labels")
    core=$(label_value io.aprilsoftware.pi-run.runtime.core-id "$labels")
    context=$(label_value io.aprilsoftware.pi-run.runtime.context-sha256 "$labels")
    source=$(label_value io.aprilsoftware.pi-run.runtime.source-sha256 "$labels")
    architecture=$(label_value io.aprilsoftware.pi-run.runtime.architecture "$labels")
    [ "${DOCKER_MODE:-}" != bad-label ] || source=wrong
    printf '[{"Id":"%s","Architecture":"%s","Config":{"Labels":{' "$built_id" "$arch"
    printf '"io.aprilsoftware.pi-run.runtime.contract":"%s",' "$contract"
    printf '"io.aprilsoftware.pi-run.runtime.core-id":"%s",' "$core"
    printf '"io.aprilsoftware.pi-run.runtime.context-sha256":"%s",' "$context"
    printf '"io.aprilsoftware.pi-run.runtime.source-sha256":"%s",' "$source"
    printf '"io.aprilsoftware.pi-run.runtime.architecture":"%s"}}}]\n' "$architecture"
}

case "${1:-} ${2:-}" in
    'info ')
        [ "${DOCKER_MODE:-}" != daemon-fail ]
        ;;
    'image inspect')
        ref=${3:-}
        if [ "$ref" = "${CORE_REF:?}" ]; then
            [ "${DOCKER_MODE:-}" != core-missing ] || exit 1
            if [ "${DOCKER_MODE:-}" = core-change ] && [ -e "$state/build-complete" ]; then
                printf '[{"Id":"%s","Architecture":"amd64","Config":{"Labels":{}}}]\n' \
                    "${CHANGED_CORE_ID:?}"
            else
                printf '[{"Id":"%s","Architecture":"%s","Config":{"Labels":{}}}]\n' \
                    "$core_id" "${CORE_ARCH:-amd64}"
            fi
        elif [ -e "$state/frozen-tag" ] && [ "$ref" = "$(cat "$state/frozen-tag")" ]; then
            printf '[{"Id":"%s","Architecture":"amd64","Config":{"Labels":{}}}]\n' "$core_id"
        elif [ -e "$state/stage-tag" ] && [ "$ref" = "$(cat "$state/stage-tag")" ]; then
            emit_built "$state/built-labels"
        elif [ -e "$state/prepared-tag" ] && [ "$ref" = "$(cat "$state/prepared-tag")" ]; then
            emit_built "$state/prepared-labels"
        else
            exit 1
        fi
        ;;
    'image tag')
        source=${3:-} target=${4:-}
        case "$target" in
            pi-run-core-stage:*)
                [ "$source" = "$core_id" ] || exit 3
                printf '%s\n' "$target" > "$state/frozen-tag"
                ;;
            pi-run-profile:*)
                [ "${DOCKER_MODE:-}" != activation-fail ] || exit 4
                [ -e "$state/stage-tag" ] && [ "$source" = "$(cat "$state/stage-tag")" ] || exit 5
                printf '%s\n' "$target" > "$state/prepared-tag"
                cp "$state/built-labels" "$state/prepared-labels"
                ;;
            *) exit 6 ;;
        esac
        ;;
    'image rm')
        [ "${3:-}" = -f ] || exit 7
        ref=${4:-}
        if [ -e "$state/stage-tag" ] && [ "$ref" = "$(cat "$state/stage-tag")" ]; then
            rm -f "$state/stage-tag"
        fi
        if [ -e "$state/frozen-tag" ] && [ "$ref" = "$(cat "$state/frozen-tag")" ]; then
            rm -f "$state/frozen-tag"
        fi
        ;;
    'build --pull=false')
        : > "$state/pending-labels"
        stage=
        context=
        shift
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --build-arg)
                    shift
                    printf '%s\n' "$1" > "$state/build-arg"
                    ;;
                --label)
                    shift
                    printf '%s\n' "$1" >> "$state/pending-labels"
                    ;;
                --tag)
                    shift
                    stage=$1
                    ;;
                *) context=$1 ;;
            esac
            shift
        done
        case "$(cat "$state/build-arg")" in
            PI_RUN_BASE_IMAGE=pi-run-core-stage:*) ;;
            *) exit 8 ;;
        esac
        [ "$(wc -l < "$state/pending-labels")" -eq 5 ] || exit 9
        [ -n "$stage" ] && [ -d "$context" ] || exit 10
        [ "${DOCKER_MODE:-}" != build-fail ] || exit 11
        if [ "${DOCKER_MODE:-}" = wait ]; then
            : > "${BUILD_STARTED:?}"
            while [ ! -e "${BUILD_RELEASE:?}" ]; do sleep 0.05; done
        fi
        mv "$state/pending-labels" "$state/built-labels"
        printf '%s\n' "$stage" > "$state/stage-tag"
        : > "$state/build-complete"
        if [ "${DOCKER_MODE:-}" = context-change ]; then
            printf '# changed during build\n' >> "$context/Dockerfile"
        fi
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

export PATH="${TMP}/fake-bin:${PATH}"
export DOCKER_STATE="${TMP}/docker-state"
export DOCKER_LOG="${TMP}/docker.log"
CORE_ID="sha256:$(printf 'a%.0s' {1..64})"
CHANGED_CORE_ID="sha256:$(printf 'c%.0s' {1..64})"
BUILT_ID="sha256:$(printf 'b%.0s' {1..64})"
export CORE_ID CHANGED_CORE_ID BUILT_ID
version="$(tr -d '\r\n' < "${ROOT}/VERSION")"
export CORE_REF="ghcr.io/aprilsoftware/pi-run:${version}"

uninitialized="${TMP}/uninitialized"
expect_failure env PI_RUN_HOME="${uninitialized}" "${ROOT}/bin/pi-run" runtime build
[[ ! -e "${uninitialized}" ]] || fail "runtime build initialized an absent home"

home="${TMP}/Pi Run"
PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" init >/dev/null
: > "${DOCKER_LOG}"
PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" runtime build > "${TMP}/success.out"
grep -E '^Built profile runtime: pi-run-profile:[0-9a-f]{24}$' "${TMP}/success.out" >/dev/null \
    || fail "successful build did not report the prepared image"
grep -Fx "Image identity: ${BUILT_ID}" "${TMP}/success.out" >/dev/null \
    || fail "successful build did not report the built image identity"
grep -E '^Source identity: [0-9a-f]{64}$' "${TMP}/success.out" >/dev/null \
    || fail "successful build did not report the source identity"
[[ -e "${DOCKER_STATE}/prepared-tag" ]] || fail "successful build did not activate a prepared tag"
assert_clean_stages
if grep -E 'COMMAND <(pull|run)>' "${DOCKER_LOG}" >/dev/null; then
    fail "runtime build pulled or ran an image"
fi
grep -F 'COMMAND <build> <--pull=false>' "${DOCKER_LOG}" >/dev/null \
    || fail "runtime build did not disable pulling"
for label in contract core-id context-sha256 source-sha256 architecture; do
    grep -F "io.aprilsoftware.pi-run.runtime.${label}=" "${DOCKER_STATE}/prepared-labels" >/dev/null \
        || fail "runtime build omitted label: ${label}"
done

DOCKER_MODE=normal PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" runtime status \
    > "${TMP}/status.out"
grep -Fx 'Prepared state: matching' "${TMP}/status.out" >/dev/null \
    || fail "runtime status did not accept the built image"

expect_failure env PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" runtime build --yes
grep -F 'Usage:' "${TMP}/failure.out" >/dev/null || fail "obsolete --yes flag was accepted"

build_started="${TMP}/build-started"
build_release="${TMP}/build-release"
DOCKER_MODE=wait BUILD_STARTED="${build_started}" BUILD_RELEASE="${build_release}" \
    PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" runtime build > "${TMP}/locked-build.out" &
build_pid=$!
for _ in {1..200}; do
    [[ -e "${build_started}" ]] && break
    sleep 0.02
done
[[ -e "${build_started}" ]] || fail "locked runtime build did not reach Docker"
if flock -n "${home}/profiles/default" true; then
    kill "${build_pid}" 2>/dev/null || true
    fail "runtime build did not hold the exclusive profile lock"
fi
: > "${build_release}"
wait "${build_pid}"
assert_clean_stages

prepared_before="$(sha256sum "${DOCKER_STATE}/prepared-labels" "${DOCKER_STATE}/prepared-tag")"
for mode in build-fail core-change bad-label activation-fail; do
    rm -f "${DOCKER_STATE}/build-complete"
    expect_failure env PI_RUN_HOME="${home}" DOCKER_MODE="${mode}" \
        "${ROOT}/bin/pi-run" runtime build
    assert_clean_stages
    [[ "$(sha256sum "${DOCKER_STATE}/prepared-labels" "${DOCKER_STATE}/prepared-tag")" == \
       "${prepared_before}" ]] || fail "${mode} replaced the previous prepared image"
done

rm -f "${DOCKER_STATE}/build-complete"
expect_failure env PI_RUN_HOME="${home}" DOCKER_MODE=bad-architecture BUILT_ARCH=arm64 \
    "${ROOT}/bin/pi-run" runtime build
assert_clean_stages
[[ "$(sha256sum "${DOCKER_STATE}/prepared-labels" "${DOCKER_STATE}/prepared-tag")" == \
   "${prepared_before}" ]] || fail "architecture failure replaced the prepared image"

rm -f "${DOCKER_STATE}/build-complete"
expect_failure env PI_RUN_HOME="${home}" DOCKER_MODE=context-change \
    "${ROOT}/bin/pi-run" runtime build
assert_clean_stages
[[ "$(sha256sum "${DOCKER_STATE}/prepared-labels" "${DOCKER_STATE}/prepared-tag")" == \
   "${prepared_before}" ]] || fail "context race replaced the prepared image"
grep -F 'changed during the build' "${TMP}/failure.out" >/dev/null \
    || fail "context race did not fail closed"

rm -rf "${DOCKER_STATE}"
mkdir -p "${DOCKER_STATE}"
: > "${DOCKER_LOG}"
expect_failure env PI_RUN_HOME="${home}" DOCKER_MODE=core-missing \
    "${ROOT}/bin/pi-run" runtime build
grep -F "core runtime image is unavailable locally: ${CORE_REF}" "${TMP}/failure.out" >/dev/null \
    || fail "missing local core image was not reported"
if grep -F 'COMMAND <pull>' "${DOCKER_LOG}" >/dev/null; then
    fail "missing core caused an automatic pull"
fi

"${ROOT}/scripts/build-release" "${TMP}/release" >/dev/null
tar -xzf "${TMP}/release/pi-run-${version}.tar.gz" -C "${TMP}"
package="${TMP}/pi-run-${version}"
packaged_home="${TMP}/packaged-home"
rm -rf "${DOCKER_STATE}"
mkdir -p "${DOCKER_STATE}"
PI_RUN_HOME="${packaged_home}" "${package}/bin/pi-run" init >/dev/null
PI_RUN_HOME="${packaged_home}" "${package}/bin/pi-run" runtime build \
    > "${TMP}/packaged.out"
grep -E '^Built profile runtime: pi-run-profile:[0-9a-f]{24}$' \
    "${TMP}/packaged.out" >/dev/null || fail "packaged runtime build failed"
assert_clean_stages

echo "runtime build tests passed"
