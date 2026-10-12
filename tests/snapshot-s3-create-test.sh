#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-s3-create-test: $*" >&2
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

SNAPSHOT_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
call="${DOCKER_LOG:?}.$$"
: > "${call}"
operation=
request=
pi_entry=false
snapshot_id=
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${call}"
    case "${argument}" in
        init|snapshots|backup) operation=${argument} ;;
        request=*) request=${argument#request=} ;;
        pi) pi_entry=true ;;
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
            [ "${#argument}" -eq 64 ] && snapshot_id=${argument} || true
            ;;
    esac
done
printf '%s\n' '---' >> "${DOCKER_LOG}"
cat "${call}" >> "${DOCKER_LOG}"
if [ "${operation}" = backup ]; then cat "${call}" >> "${BACKUP_LOG:?}"; fi
rm -f "${call}"
if [ "${pi_entry}" = true ] && [ -z "${operation}" ]; then printf '1.1.0\n'; exit 0; fi
case "${operation}" in
    init) : > "${REMOTE_MARKER:?}" ;;
    backup)
        [ "${FAIL_BACKUP:-0}" = 0 ] || exit 1
        printf '%s\n' "${request}" > "${REMOTE_REQUEST:?}"
        if [ "${MALFORMED_BACKUP:-0}" = 1 ]; then
            printf '{"message_type":"summary","snapshot_id":"bad"}\n'
        else
            printf '{"message_type":"summary","snapshot_id":"%s"}\n' "${SNAPSHOT_ID:?}"
        fi
        ;;
    snapshots)
        [ -e "${REMOTE_MARKER:?}" ] || exit 1
        if [ -n "${snapshot_id}" ]; then
            request=$(cat "${REMOTE_REQUEST:?}")
            [ "${BAD_VERIFY:-0}" = 0 ] || request=00000000-0000-4000-8000-000000000000
            printf '[{"id":"%s","tags":["pi-run","scope=complete","request=%s","purpose=manual"]}]\n' \
                "${SNAPSHOT_ID:?}" "${request}"
        else
            printf '[]\n'
        fi
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

HOME_DIR="${TMP}/Pi Run"
export DOCKER_LOG="${TMP}/docker.log" BACKUP_LOG="${TMP}/backup.log"
export REMOTE_MARKER="${TMP}/remote" REMOTE_REQUEST="${TMP}/request" SNAPSHOT_ID
: > "${DOCKER_LOG}"
: > "${BACKUP_LOG}"
printf '2\nhttps://ceph.example.test\npi-run-backups\nusers/alice\neu-west-1\n1\nyes\nACCESS_123\nSECRET/456+=\n' | env \
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" BACKUP_LOG="${BACKUP_LOG}" \
    REMOTE_MARKER="${REMOTE_MARKER}" REMOTE_REQUEST="${REMOTE_REQUEST}" SNAPSHOT_ID="${SNAPSHOT_ID}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null 2>&1

: > "${DOCKER_LOG}"
: > "${BACKUP_LOG}"
output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" BACKUP_LOG="${BACKUP_LOG}" \
    REMOTE_MARKER="${REMOTE_MARKER}" REMOTE_REQUEST="${REMOTE_REQUEST}" SNAPSHOT_ID="${SNAPSHOT_ID}" \
    "${ROOT}/bin/pi-run" snapshot create)"
[[ "${output}" == *"Snapshot created: ${SNAPSHOT_ID}"* ]] || fail "S3 snapshot result is incomplete"
manifest="$(find "${HOME_DIR}/snapshots/metadata" -maxdepth 1 -type f -name '*.json' -print -quit)"
[[ -n "${manifest}" ]] || fail "S3 snapshot manifest was not retained"
request="$(jq -r .requestId "${manifest}")"
[[ "$(cat "${REMOTE_REQUEST}")" == "${request}" ]] || fail "request tag does not match manifest"
jq -e '
    .scope == "complete" and .purpose == "manual" and
    (.includedPaths | index("snapshots/config.json")) and
    (.excludedPaths | index("snapshots/secrets")) and
    (.excludedPaths | index("snapshots/s3-credentials"))
' "${manifest}" >/dev/null || fail "S3 manifest boundaries are invalid"
for argument in '--network' bridge '--cap-drop=ALL' '--security-opt=no-new-privileges' \
    '/tmp:rw,noexec,nosuid,nodev,size=256m' \
    'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' \
    '--no-cache' '--pack-size' 16 backup '--json' '--one-file-system' '--host' \
    "$("${ROOT}/bin/pi-run" machine-id)" \
    '--tag' pi-run scope=complete "request=${request}" purpose=manual 's3.region=eu-west-1' \
    's3.bucket-lookup=path' 's3.connections=2'; do
    grep -Fx -- "${argument}" "${BACKUP_LOG}" >/dev/null || fail "missing backup argument: ${argument}"
done
for destination in /secret /s3-credentials /etc/ssl/certs/ca-certificates.crt \
    /input/config.json /input/profiles /input/skills /input/shared /input/workspaces \
    /input/snapshot-config.json /input/snapshot-manifest.json; do
    grep -E "dst=${destination//\//\\/},readonly$" "${BACKUP_LOG}" >/dev/null \
        || fail "backup mount is not read-only: ${destination}"
done
if grep -F 'dst=/repository' "${BACKUP_LOG}" >/dev/null; then
    fail "S3 backup mounted a local repository"
fi
if grep -Fx 'RESTIC_CACHE_DIR=/tmp/restic-cache' "${BACKUP_LOG}" >/dev/null; then
    fail "S3 backup enabled a disposable Restic cache"
fi
if grep -E 'ACCESS_123|SECRET/456' "${DOCKER_LOG}" >/dev/null; then
    fail "S3 credentials were included in Docker arguments"
fi

manifest_count="$(find "${HOME_DIR}/snapshots/metadata" -maxdepth 1 -type f -name '*.json' | wc -l)"
for mode in failed malformed mismatch; do
    case "${mode}" in
        failed) extra=(FAIL_BACKUP=1) ;;
        malformed) extra=(MALFORMED_BACKUP=1) ;;
        mismatch) extra=(BAD_VERIFY=1) ;;
    esac
    expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        DOCKER_LOG="${DOCKER_LOG}" BACKUP_LOG="${BACKUP_LOG}" \
        REMOTE_MARKER="${REMOTE_MARKER}" REMOTE_REQUEST="${REMOTE_REQUEST}" SNAPSHOT_ID="${SNAPSHOT_ID}" \
        "${extra[@]}" "${ROOT}/bin/pi-run" snapshot create
    [[ "$(find "${HOME_DIR}/snapshots/metadata" -maxdepth 1 -type f -name '*.json' | wc -l)" == "${manifest_count}" ]] \
        || fail "${mode} S3 backup left local metadata"
    find "${HOME_DIR}/snapshots/metadata" -maxdepth 1 -name '.backup-output.tmp.*' -print -quit | grep -q . && \
        fail "${mode} S3 backup left temporary output"
done

echo "S3 snapshot creation tests passed"
