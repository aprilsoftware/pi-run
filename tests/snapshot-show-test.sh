#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-show-test: $*" >&2
    exit 1
}

expect_failure() {
    local status
    set +e
    "$@" >/dev/null 2>&1
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "command unexpectedly succeeded: $*"
}

HOME_DIR="${TMP}/Pi Run"
FULL_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHORT_ID=aaaaaaaaaaaa
REQUEST_ID=11111111-1111-4111-8111-111111111111
mkdir -p "${TMP}/fake-bin"

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
: > "${DOCKER_LOG:?}"
printf '%s\n' '--- docker call ---' >> "${DOCKER_CALL_LOG:?}"
repository=
operation=
resolving=false
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG}"
    printf '%s\n' "${argument}" >> "${DOCKER_CALL_LOG}"
    case "${argument}" in
        RESTIC_REPOSITORY=/snapshots/*) repository=${argument#RESTIC_REPOSITORY=} ;;
        init|snapshots|dump) operation=${argument} ;;
    esac
    if [ "${argument}" = "${EXPECTED_SHORT_ID:-}" ] || [ "${argument}" = "${EXPECTED_FULL_ID:-}" ]; then
        resolving=true
    fi
done
case "${operation}" in
    init)
        destination="${SNAPSHOT_TEST_ROOT:?}/${repository#/snapshots/}"
        mkdir "${destination}"
        printf 'restic repository\n' > "${destination}/config"
        ;;
    snapshots)
        if [ "${resolving}" = true ]; then
            [ "${FAIL_RESOLVE:-0}" = 0 ] || exit 1
            printf '%s\n' "${SHOW_METADATA:-[]}"
        else
            printf '[]\n'
        fi
        ;;
    dump)
        [ "${FAIL_DUMP:-0}" = 0 ] || exit 1
        if [ -n "${SHOW_MANIFEST:-}" ]; then
            printf '%s\n' "${SHOW_MANIFEST}"
        else
            printf '{}\n'
        fi
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"
export DOCKER_CALL_LOG="${TMP}/docker-calls.log"
export SNAPSHOT_TEST_ROOT="${HOME_DIR}/snapshots"
export EXPECTED_SHORT_ID="${SHORT_ID}"
export EXPECTED_FULL_ID="${FULL_ID}"

printf '1\nyes\n' | env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null
SHOW_METADATA="$(jq -nc \
    --arg id "${FULL_ID}" --arg request "${REQUEST_ID}" \
    '[{id:$id,time:"2026-08-02T11:30:00Z",tags:["pi-run","scope=complete",("request="+$request)]}]')"
SHOW_MANIFEST="$(jq -nc \
    --arg request "${REQUEST_ID}" \
    '{
        schemaVersion:1,
        requestId:$request,
        createdAt:"2026-08-02T11:29:59Z",
        scope:"complete",
        piRunVersion:"0.5.12",
        runtimeImage:"ghcr.io/aprilsoftware/pi-run:0.5.12",
        piVersion:"1.1.0",
        homeConfigurationSchemaVersion:1,
        profileSchemaVersion:1,
        workspaceRegistrySchemaVersion:1,
        snapshotConfigurationSchemaVersion:1,
        includedPaths:["config.json","profiles","skills","shared","workspaces","snapshots/config.json",("snapshots/metadata/"+$request+".json")],
        excludedPaths:["machines","snapshots/secrets","snapshots/repository","snapshots/restore-staging"]
    }')"
export SHOW_METADATA SHOW_MANIFEST

show_output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot show "${SHORT_ID}")"
[[ "${show_output}" == *"Snapshot: ${FULL_ID}"* &&
   "${show_output}" == *"Created: 2026-08-02T11:30:00Z"* &&
   "${show_output}" == *"Scope: complete"* &&
   "${show_output}" == *"Request: ${REQUEST_ID}"* &&
   "${show_output}" == *"Pi-Run: 0.5.12"* &&
   "${show_output}" == *"Pi: 1.1.0"* &&
   "${show_output}" == *"Included:"* &&
   "${show_output}" == *"Excluded:"* ]] \
    || fail "snapshot details are incomplete"
grep -Fx -- '--no-lock' "${DOCKER_LOG}" >/dev/null || fail "dump did not disable locking"
grep -Fx -- 'dump' "${DOCKER_LOG}" >/dev/null || fail "manifest was not dumped through Restic"
grep -Fx -- "${FULL_ID}" "${DOCKER_LOG}" >/dev/null || fail "dump did not use the resolved full ID"
grep -Fx -- '/input/snapshot-manifest.json' "${DOCKER_LOG}" >/dev/null \
    || fail "dump used the wrong manifest path"
grep -F "type=bind,src=${HOME_DIR}/snapshots,dst=/snapshots,readonly" "${DOCKER_LOG}" >/dev/null \
    || fail "show did not use a read-only repository mount"
grep -Fx -- "${SHORT_ID}" "${DOCKER_CALL_LOG}" >/dev/null \
    || fail "short snapshot ID was not resolved"

PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot show "${FULL_ID}" >/dev/null
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" SHOW_METADATA='[]' SHOW_MANIFEST="${SHOW_MANIFEST}" \
    "${ROOT}/bin/pi-run" snapshot show "${SHORT_ID}"
FOREIGN="$(jq -c '.[0].tags=["unrelated"]' <<< "${SHOW_METADATA}")"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" SHOW_METADATA="${FOREIGN}" SHOW_MANIFEST="${SHOW_MANIFEST}" \
    "${ROOT}/bin/pi-run" snapshot show "${SHORT_ID}"
AMBIGUOUS="$(jq -nc --argjson first "${SHOW_METADATA}" --arg id "${FULL_ID/a/b}" \
    '$first + [{id:$id,time:"2026-08-01T00:00:00Z",tags:["pi-run","scope=complete","request=22222222-2222-4222-8222-222222222222"]}]')"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" SHOW_METADATA="${AMBIGUOUS}" SHOW_MANIFEST="${SHOW_MANIFEST}" \
    "${ROOT}/bin/pi-run" snapshot show "${SHORT_ID}"
MISMATCHED="$(jq -c '.requestId="33333333-3333-4333-8333-333333333333"' <<< "${SHOW_MANIFEST}")"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" SHOW_METADATA="${SHOW_METADATA}" SHOW_MANIFEST="${MISMATCHED}" \
    "${ROOT}/bin/pi-run" snapshot show "${SHORT_ID}"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" SHOW_METADATA="${SHOW_METADATA}" SHOW_MANIFEST='not-json' \
    "${ROOT}/bin/pi-run" snapshot show "${SHORT_ID}"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" SHOW_METADATA="${SHOW_METADATA}" FAIL_DUMP=1 \
    "${ROOT}/bin/pi-run" snapshot show "${SHORT_ID}"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" "${ROOT}/bin/pi-run" snapshot show invalid
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" "${ROOT}/bin/pi-run" snapshot show aaaaaaaaaaaaa

echo "snapshot show tests passed"
