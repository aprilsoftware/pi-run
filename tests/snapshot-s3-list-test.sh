#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-s3-list-test: $*" >&2
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

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
operation=
tagged=false
previous=
printf '%s\n' '---' >> "${DOCKER_LOG:?}"
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG}"
    case "${argument}" in init|snapshots) operation=${argument} ;; esac
    if [ "${previous}" = --tag ] && [ "${argument}" = pi-run ]; then tagged=true; fi
    previous=${argument}
done
case "${operation}" in
    init) : > "${REMOTE_MARKER:?}" ;;
    snapshots)
        [ -e "${REMOTE_MARKER:?}" ] || exit 1
        if [ "${tagged}" = true ]; then
            [ "${FAIL_LIST:-0}" = 0 ] || exit 1
            printf '%s\n' "${SNAPSHOT_METADATA:-[]}"
        else
            printf '[]\n'
        fi
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

HOME_DIR="${TMP}/Pi Run"
export DOCKER_LOG="${TMP}/docker.log" REMOTE_MARKER="${TMP}/remote"
: > "${DOCKER_LOG}"
printf '2\nhttps://ceph.example.test\npi-run-backups\nusers/alice\neu-west-1\n1\nyes\nACCESS_123\nSECRET/456+=\n' | env \
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null 2>&1

OLDER=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
LATEST=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
SNAPSHOT_METADATA="$(jq -nc --arg older "${OLDER}" --arg latest "${LATEST}" '[
    {id:$older,time:"2026-08-01T10:00:00Z",hostname:"pi-run",tags:["pi-run","scope=complete","request=11111111-1111-4111-8111-111111111111"]},
    {id:$latest,time:"2026-08-02T11:30:00Z",hostname:"fedcba9876543210",tags:["request=22222222-2222-4222-8222-222222222222","pi-run","scope=complete"]}
]')"
export SNAPSHOT_METADATA
: > "${DOCKER_LOG}"
output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" \
    "${ROOT}/bin/pi-run" snapshot list)"
[[ "$(awk 'NR==2 {print $1}' <<< "${output}")" == "${OLDER:0:12}" &&
   "$(awk 'NR==3 {print $1}' <<< "${output}")" == "${LATEST:0:12}" ]] \
    || fail "S3 snapshots were not listed oldest first"
[[ "$(awk 'NR==2 {print $3}' <<< "${output}")" == '-' &&
   "$(awk 'NR==3 {print $3}' <<< "${output}")" == fedcba9876543210 &&
   "${output}" != *'REQUEST'* && "${output}" != *'22222222-2222-4222-8222-222222222222'* ]] \
    || fail "S3 machine provenance or request-column suppression is incorrect"
for argument in '--network' bridge '--no-lock' snapshots '--json' '--tag' pi-run \
    'AWS_SHARED_CREDENTIALS_FILE=/s3-credentials' 's3.region=eu-west-1' 's3.bucket-lookup=path'; do
    grep -Fx -- "${argument}" "${DOCKER_LOG}" >/dev/null || fail "missing list argument: ${argument}"
done
grep -F "src=${HOME_DIR}/snapshots/secrets,dst=/secret,readonly" "${DOCKER_LOG}" >/dev/null \
    || fail "snapshot secret was not mounted read-only"
grep -F "src=${HOME_DIR}/snapshots/s3-credentials,dst=/s3-credentials,readonly" "${DOCKER_LOG}" >/dev/null \
    || fail "S3 credentials were not mounted read-only"
if grep -E 'ACCESS_123|SECRET/456' "${DOCKER_LOG}" >/dev/null; then
    fail "S3 credentials were included in Docker arguments"
fi
if grep -Fx -- host "${DOCKER_LOG}" >/dev/null || grep -Fx -- none "${DOCKER_LOG}" >/dev/null; then
    fail "S3 listing used an unsafe or disabled network mode"
fi

empty="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" SNAPSHOT_METADATA='[]' \
    "${ROOT}/bin/pi-run" snapshot list)"
[[ "${empty}" == 'No Pi-Run snapshots.' ]] || fail "empty S3 repository output is incorrect"

MALFORMED="$(jq -nc --arg id "${OLDER}" '[
    {id:$id,time:"2026-08-01T10:00:00Z",tags:["pi-run","scope=complete"]}
]')"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" SNAPSHOT_METADATA="${MALFORMED}" \
    "${ROOT}/bin/pi-run" snapshot list
FOREIGN="$(jq -nc --arg id "${OLDER}" '[
    {id:$id,time:"2026-08-01T10:00:00Z",tags:["foreign","scope=complete","request=11111111-1111-4111-8111-111111111111"]}
]')"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" SNAPSHOT_METADATA="${FOREIGN}" \
    "${ROOT}/bin/pi-run" snapshot list
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" FAIL_LIST=1 \
    "${ROOT}/bin/pi-run" snapshot list

echo "S3 snapshot listing tests passed"
