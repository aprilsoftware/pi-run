#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-create-test: $*" >&2
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

assert_log_line() {
    grep -Fx -- "$1" "${DOCKER_LOG}" >/dev/null \
        || fail "missing Docker argument: $1"
}

HOME_DIR="${TMP}/Pi Run"
mkdir -p "${TMP}/fake-bin"

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
: > "${DOCKER_LOG:?}"
printf '%s\n' '--- docker call ---' >> "${DOCKER_CALL_LOG:?}"
repository=
entrypoint=
operation=
previous=
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG}"
    printf '%s\n' "${argument}" >> "${DOCKER_CALL_LOG}"
    [ "${previous}" != --entrypoint ] || entrypoint=${argument}
    case "${argument}" in
        RESTIC_REPOSITORY=/snapshots/*) repository=${argument#RESTIC_REPOSITORY=} ;;
        init|snapshots|backup) operation=${argument} ;;
    esac
    previous=${argument}
done
if [ "${entrypoint}" = pi ]; then
    printf '%s\n' "${FAKE_PI_VERSION:-1.1.0}"
    exit 0
fi
[ "${entrypoint}" = restic ] || exit 2
case "${operation}" in
    init)
        destination="${SNAPSHOT_TEST_ROOT:?}/${repository#/snapshots/}"
        mkdir "${destination}"
        printf 'restic repository\n' > "${destination}/config"
        ;;
    snapshots)
        printf '[]\n'
        ;;
    backup)
        [ "${FAIL_BACKUP:-0}" = 0 ] || exit 1
        printf '%s\n' '{"message_type":"status","seconds_elapsed":0}'
        printf '%s\n' '{"message_type":"summary","snapshot_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"
export DOCKER_CALL_LOG="${TMP}/docker-calls.log"
export SNAPSHOT_TEST_ROOT="${HOME_DIR}/snapshots"

printf '1\nyes\n' | env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null
printf 'shared data\n' > "${HOME_DIR}/shared/example.txt"
printf 'skill data\n' > "${HOME_DIR}/skills/example.txt"

create_output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot create)"
snapshot_id="$(printf '%s\n' "${create_output}" | awk '/^Snapshot created: / { print $3 }')"
manifest="$(printf '%s\n' "${create_output}" | awk '/^Manifest: / { sub(/^Manifest: /, ""); print }')"
[[ "${snapshot_id}" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] \
    || fail "create did not report the Restic snapshot ID"
[[ -f "${manifest}" && "$(stat -c %a "${manifest}")" == 600 ]] \
    || fail "snapshot manifest is missing or has unsafe permissions"
jq -e '
    .schemaVersion == 1 and .scope == "complete" and .purpose == "manual" and
    .piRunVersion == "0.7.0" and .piVersion == "1.1.0" and
    .runtimeImage == "ghcr.io/aprilsoftware/pi-run:0.7.0" and
    (.requestId | test("^[0-9a-f-]{36}$")) and
    (.includedPaths | index("profiles")) and
    (.excludedPaths | index("machines")) and
    (.excludedPaths | index("snapshots/secrets")) and
    (.excludedPaths | index("snapshots/repository"))
' "${manifest}" >/dev/null || fail "snapshot manifest is incomplete"
[[ -z "$(find "${HOME_DIR}/snapshots/metadata" -name '.backup-output.tmp.*' -print -quit)" ]] \
    || fail "successful snapshot left temporary output"

assert_log_line --network
assert_log_line none
assert_log_line --one-file-system
assert_log_line backup
assert_log_line --host
assert_log_line "$("${ROOT}/bin/pi-run" machine-id)"
assert_log_line purpose=manual
assert_log_line /input/config.json
assert_log_line /input/profiles
assert_log_line /input/skills
assert_log_line /input/shared
assert_log_line /input/workspaces
assert_log_line /input/snapshot-config.json
assert_log_line /input/snapshot-manifest.json
for mount in \
    "type=bind,src=${HOME_DIR}/config.json,dst=/input/config.json,readonly" \
    "type=bind,src=${HOME_DIR}/profiles,dst=/input/profiles,readonly" \
    "type=bind,src=${HOME_DIR}/skills,dst=/input/skills,readonly" \
    "type=bind,src=${HOME_DIR}/shared,dst=/input/shared,readonly" \
    "type=bind,src=${HOME_DIR}/workspaces,dst=/input/workspaces,readonly" \
    "type=bind,src=${HOME_DIR}/snapshots/config.json,dst=/input/snapshot-config.json,readonly" \
    "type=bind,src=${manifest},dst=/input/snapshot-manifest.json,readonly" \
    "type=bind,src=${HOME_DIR}/snapshots/secrets,dst=/secret,readonly"; do
    assert_log_line "${mount}"
done
assert_log_line "type=bind,src=${HOME_DIR}/snapshots/repository,dst=/repository"
if grep -F "src=${HOME_DIR}/machines" "${DOCKER_LOG}" >/dev/null; then
    fail "snapshot exposed machine-local metadata"
fi
grep -Fx pi "${DOCKER_CALL_LOG}" >/dev/null || fail "Pi version was not queried"

manifest_count="$(find "${HOME_DIR}/snapshots/metadata" -maxdepth 1 -name '*.json' | wc -l)"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" FAIL_BACKUP=1 \
    "${ROOT}/bin/pi-run" snapshot create
[[ "$(find "${HOME_DIR}/snapshots/metadata" -maxdepth 1 -name '*.json' | wc -l)" == "${manifest_count}" ]] \
    || fail "failed backup published a manifest"
[[ -z "$(find "${HOME_DIR}/snapshots/metadata" -name '.backup-output.tmp.*' -print -quit)" ]] \
    || fail "failed backup left temporary output"

ln -s "${TMP}" "${HOME_DIR}/shared/unsafe-link"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" "${ROOT}/bin/pi-run" snapshot create
rm "${HOME_DIR}/shared/unsafe-link"
mv "${HOME_DIR}/snapshots/metadata" "${HOME_DIR}/snapshots/metadata.real"
ln -s "${TMP}" "${HOME_DIR}/snapshots/metadata"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" "${ROOT}/bin/pi-run" snapshot create
rm "${HOME_DIR}/snapshots/metadata"
mv "${HOME_DIR}/snapshots/metadata.real" "${HOME_DIR}/snapshots/metadata"
printf 'linked data\n' > "${HOME_DIR}/shared/linked-a"
ln "${HOME_DIR}/shared/linked-a" "${HOME_DIR}/shared/linked-b"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" "${ROOT}/bin/pi-run" snapshot create

echo "snapshot creation tests passed"
