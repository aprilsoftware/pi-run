#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-s3-config-test: $*" >&2
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
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG:?}"
    case "${argument}" in init|snapshots) operation=${argument} ;; esac
done
case "${operation}" in
    snapshots)
        [ -e "${REMOTE_MARKER:?}" ] || exit 1
        printf '[]\n'
        ;;
    init)
        case "${FAIL_INIT:-0}" in
            hard) exit 1 ;;
            timeout) exit 124 ;;
            uncertain) : > "${REMOTE_MARKER}"; exit 1 ;;
            *) : > "${REMOTE_MARKER}" ;;
        esac
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

run_configure() {
    local home="$1" operation="${2:-1}"
    {
        printf '2\nhttps://ceph.example.test:8443\npi-run-backups\nusers/alice\neu-west-1\n%s\nyes\nACCESS_123\nSECRET/456+=\n' "${operation}"
        [[ "${operation}" != 2 ]] || printf 'EXISTING-RESTIC-PASSWORD\n'
    } | env \
        PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
        DOCKER_LOG="${DOCKER_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
        FAIL_INIT="${FAIL_INIT:-0}" \
        "${ROOT}/bin/pi-run" snapshot configure
}

HOME_DIR="${TMP}/Pi Run"
export DOCKER_LOG="${TMP}/docker.log" REMOTE_MARKER="${TMP}/remote"
: > "${DOCKER_LOG}"
output="$(run_configure "${HOME_DIR}" 2>&1)"
[[ "${output}" == *'HTTPS S3 API endpoint'* && "${output}" == *'Repository operation:'* &&
   "${output}" == *'S3 snapshot repository:'* && "${output}" == *'Operation: create new'* &&
   "${output}" == *'Endpoint:  https://ceph.example.test:8443'* &&
   "${output}" == *'Bucket:    pi-run-backups'* && "${output}" == *'Prefix:    users/alice'* &&
   "${output}" == *'Creating encrypted S3 repository...'* &&
   "${output}" == *'Verifying encrypted S3 repository...'* ]] \
    || fail "S3 configuration guidance or summary is incomplete"
[[ "${output}" != *ACCESS_123* && "${output}" != *SECRET/456* ]] \
    || fail "S3 credentials were printed"
[[ -f "${HOME_DIR}/snapshots/config.json" && -f "${HOME_DIR}/snapshots/secrets" &&
   -f "${HOME_DIR}/snapshots/s3-credentials" && ! -e "${HOME_DIR}/snapshots/repository" ]] \
    || fail "S3 configuration layout is incomplete"
[[ "$(stat -c %a "${HOME_DIR}/snapshots/config.json")" == 600 &&
   "$(stat -c %a "${HOME_DIR}/snapshots/secrets")" == 600 &&
   "$(stat -c %a "${HOME_DIR}/snapshots/s3-credentials")" == 600 ]] \
    || fail "S3 configuration files are not private"
jq -e '
    .schemaVersion == 1 and .backend == "s3" and
    .endpoint == "https://ceph.example.test:8443" and
    .bucket == "pi-run-backups" and .prefix == "users/alice" and
    .region == "eu-west-1" and .bucketLookup == "path"
' "${HOME_DIR}/snapshots/config.json" >/dev/null || fail "S3 configuration is invalid"
grep -Fx '[default]' "${HOME_DIR}/snapshots/s3-credentials" >/dev/null
grep -Fx 'aws_access_key_id = ACCESS_123' "${HOME_DIR}/snapshots/s3-credentials" >/dev/null
grep -Fx 'aws_secret_access_key = SECRET/456+=' "${HOME_DIR}/snapshots/s3-credentials" >/dev/null
if grep -E 'ACCESS_123|SECRET/456' "${DOCKER_LOG}" >/dev/null; then
    fail "S3 credentials were included in Docker arguments"
fi
for argument in '--network' bridge '--cap-drop=ALL' '--security-opt=no-new-privileges' \
    'AWS_SHARED_CREDENTIALS_FILE=/s3-credentials' 'RESTIC_PASSWORD_FILE=/secret' \
    'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' \
    'RESTIC_REPOSITORY=s3:https://ceph.example.test:8443/pi-run-backups/users/alice' \
    's3.region=eu-west-1' 's3.bucket-lookup=path'; do
    grep -Fx -- "${argument}" "${DOCKER_LOG}" >/dev/null || fail "missing Docker argument: ${argument}"
done
if grep -Fx -- host "${DOCKER_LOG}" >/dev/null || grep -Fx -- none "${DOCKER_LOG}" >/dev/null; then
    fail "S3 operation used an unsafe or disabled network mode"
fi
grep -E 'src=.+,dst=/secret,readonly$' "${DOCKER_LOG}" >/dev/null \
    || fail "snapshot secret was not mounted read-only"
grep -E 'src=.+,dst=/s3-credentials,readonly$' "${DOCKER_LOG}" >/dev/null \
    || fail "S3 credentials were not mounted read-only"
grep -F 'src=/etc/ssl/certs/ca-certificates.crt,dst=/etc/ssl/certs/ca-certificates.crt,readonly' \
    "${DOCKER_LOG}" >/dev/null || fail "host CA bundle was not mounted read-only"

: > "${DOCKER_LOG}"
status="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
    "${ROOT}/bin/pi-run" snapshot status)"
[[ "${status}" == *'Snapshot backend: s3'* && "${status}" == *'Snapshot status: ready'* ]] \
    || fail "S3 status output is incomplete"
INVALID_HOME="${TMP}/invalid-inputs"
INVALID_REMOTE="${TMP}/invalid-inputs-remote"
invalid_output="$(printf '2\nhttp://ceph.example.test\nhttps://ceph.example.test\nBad_Bucket\nvalid-bucket\n../bad\nvalid/prefix\nBAD REGION\n\nbad operation\n1\nyes\nbad key\nACCESS_123\nbad secret\nSECRET/456+=\n' | env \
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${INVALID_HOME}" \
    DOCKER_LOG="${TMP}/invalid-inputs.log" REMOTE_MARKER="${INVALID_REMOTE}" \
    "${ROOT}/bin/pi-run" snapshot configure 2>&1)"
for explanation in \
    'Enter an HTTPS endpoint' \
    'Enter a valid lowercase S3 bucket name' \
    'Use slash-separated letters' \
    'Enter a lowercase S3 region' \
    'Enter 1 to create a new repository' \
    'The access key must contain' \
    'The secret key contains unsupported'; do
    [[ "${invalid_output}" == *"${explanation}"* ]] || fail "missing input guidance: ${explanation}"
done
jq -e '.region == "us-east-1" and .backend == "s3"' \
    "${INVALID_HOME}/snapshots/config.json" >/dev/null || fail "default region was not applied"
[[ "${invalid_output}" != *ACCESS_123* && "${invalid_output}" != *SECRET/456* ]] \
    || fail "re-prompted credentials were printed"

FAIL_HOME="${TMP}/failure"
FAIL_INIT=hard REMOTE_MARKER="${TMP}/failure-remote" \
    expect_failure run_configure "${FAIL_HOME}"
for path in config.json secrets s3-credentials repository; do
    [[ ! -e "${FAIL_HOME}/snapshots/${path}" ]] \
        || fail "failed S3 configuration published ${path}"
done
find "${FAIL_HOME}/snapshots" -maxdepth 1 -name '.*.tmp.*' -print -quit | grep -q . && \
    fail "failed S3 configuration left staging state"

EXISTING_HOME="${TMP}/existing"
REMOTE_MARKER="${TMP}/existing-remote"
: > "${REMOTE_MARKER}"
DOCKER_LOG="${TMP}/existing.log"
: > "${DOCKER_LOG}"
existing_output="$(run_configure "${EXISTING_HOME}" 2 2>&1)"
[[ "${existing_output}" == *'Operation: connect existing'* &&
   "${existing_output}" == *'Opening and verifying existing encrypted S3 repository...'* ]] \
    || fail "existing repository guidance is incomplete"
[[ "$(< "${EXISTING_HOME}/snapshots/secrets")" == 'EXISTING-RESTIC-PASSWORD' ]] \
    || fail "existing Restic recovery password was not stored"
[[ "${existing_output}" != *'EXISTING-RESTIC-PASSWORD'* ]] \
    || fail "existing Restic recovery password was printed"
if grep -Fx init "${DOCKER_LOG}" >/dev/null; then
    fail "existing S3 repository was initialized again"
fi

UNCERTAIN_HOME="${TMP}/uncertain"
REMOTE_MARKER="${TMP}/uncertain-remote"
DOCKER_LOG="${TMP}/uncertain.log"
: > "${DOCKER_LOG}"
FAIL_INIT=uncertain run_configure "${UNCERTAIN_HOME}" >/dev/null 2>&1
[[ -f "${UNCERTAIN_HOME}/snapshots/config.json" ]] \
    || fail "uncertain successful initialization was not recovered"

TIMEOUT_HOME="${TMP}/timeout"
REMOTE_MARKER="${TMP}/timeout-remote"
DOCKER_LOG="${TMP}/timeout.log"
: > "${DOCKER_LOG}"
set +e
timeout_output="$(FAIL_INIT=timeout run_configure "${TIMEOUT_HOME}" 2>&1)"
timeout_status=$?
set -e
[[ ${timeout_status} -ne 0 && "${timeout_output}" == *'timed out after 90 seconds'* ]] \
    || fail "S3 configuration timeout was not reported"
[[ ! -e "${TIMEOUT_HOME}/snapshots/config.json" ]] || fail "timed-out configuration was published"

echo "S3 snapshot configuration tests passed"
