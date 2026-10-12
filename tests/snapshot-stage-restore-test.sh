#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-stage-restore-test: $*" >&2
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

SNAPSHOT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
REQUEST_ID=11111111-1111-4111-8111-111111111111
mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
call="${DOCKER_LOG:?}.$$"
: > "${call}"
operation=
repository=
reference=
target=
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${call}"
    case "${argument}" in init|snapshots|restore) operation=${argument} ;; esac
    case "${argument}" in
        RESTIC_REPOSITORY=*) repository=${argument#RESTIC_REPOSITORY=} ;;
        type=bind,src=*,dst=/restore) target=${argument#type=bind,src=}; target=${target%,dst=/restore} ;;
        [0-9a-f]*) if [ "${#argument}" -eq 12 ] || [ "${#argument}" -eq 64 ]; then reference=${argument}; fi ;;
    esac
done
printf '%s\n' '---' >> "${DOCKER_LOG}"
cat "${call}" >> "${DOCKER_LOG}"
if [ "${operation}" = restore ]; then cat "${call}" >> "${RESTORE_LOG:?}"; fi
rm -f "${call}"
case "${operation}" in
    init)
        case "${repository}" in
            /snapshots/*)
                destination="${SNAPSHOT_TEST_ROOT:?}/${repository#/snapshots/}"
                mkdir "${destination}"
                printf repository > "${destination}/config"
                ;;
            s3:*) : > "${REMOTE_MARKER:?}" ;;
            *) exit 2 ;;
        esac
        ;;
    snapshots)
        case "${repository}" in s3:*) [ -e "${REMOTE_MARKER:?}" ] || exit 1 ;; esac
        if [ -n "${reference}" ]; then printf '%s\n' "${SNAPSHOT_METADATA:-[]}"; else printf '[]\n'; fi
        ;;
    restore)
        [ "${FAIL_RESTORE:-0}" = 0 ] || exit 1
        cp -a "${RESTORE_FIXTURE:?}/." "${target}/"
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

export DOCKER_LOG="${TMP}/docker.log" RESTORE_LOG="${TMP}/restore.log" REMOTE_MARKER="${TMP}/remote"
: > "${DOCKER_LOG}"
: > "${RESTORE_LOG}"

configure_local() {
    local home="$1"
    printf '1\nyes\n' | env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
        DOCKER_LOG="${DOCKER_LOG}" RESTORE_LOG="${RESTORE_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
        SNAPSHOT_TEST_ROOT="${home}/snapshots" \
        "${ROOT}/bin/pi-run" snapshot configure >/dev/null
}

configure_s3() {
    local home="$1"
    printf '2\nhttps://ceph.example.test\npi-run-backups\nusers/alice\neu-west-1\n1\nyes\nACCESS_123\nSECRET/456+=\n' | env \
        PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
        DOCKER_LOG="${DOCKER_LOG}" RESTORE_LOG="${RESTORE_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
        SNAPSHOT_TEST_ROOT="${home}/snapshots" \
        "${ROOT}/bin/pi-run" snapshot configure >/dev/null 2>&1
}

run_restore() {
    local home="$1" input="$2" reference="${3:-${SNAPSHOT_ID:0:12}}" command="" argument
    local -a invocation=(env "PATH=${TMP}/fake-bin:${PATH}" "PI_RUN_HOME=${home}"
        "DOCKER_LOG=${DOCKER_LOG}" "RESTORE_LOG=${RESTORE_LOG}" "REMOTE_MARKER=${REMOTE_MARKER}"
        "SNAPSHOT_TEST_ROOT=${home}/snapshots" "RESTORE_FIXTURE=${RESTORE_FIXTURE}"
        "SNAPSHOT_METADATA=${SNAPSHOT_METADATA}" "FAIL_RESTORE=${FAIL_RESTORE:-0}"
        "${ROOT}/bin/pi-run" snapshot restore "${reference}")
    for argument in "${invocation[@]}"; do printf -v command '%s%q ' "${command}" "${argument}"; done
    printf '%b' "${input}" | script -qefc "${command}" /dev/null
}

run_recover() {
    local home="$1" reference="${2:-${SNAPSHOT_ID:0:12}}"
    env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
        DOCKER_LOG="${DOCKER_LOG}" RESTORE_LOG="${RESTORE_LOG}" REMOTE_MARKER="${REMOTE_MARKER}" \
        SNAPSHOT_TEST_ROOT="${home}/snapshots" RESTORE_FIXTURE="${RESTORE_FIXTURE}" \
        SNAPSHOT_METADATA="${SNAPSHOT_METADATA}" FAIL_RESTORE="${FAIL_RESTORE:-0}" \
        "${ROOT}/bin/pi-run" snapshot recover "${reference}"
}

LOCAL_HOME="${TMP}/local"
configure_local "${LOCAL_HOME}"
FIXTURE="${TMP}/fixture"
mkdir -p "${FIXTURE}/input"
cp -a "${LOCAL_HOME}/config.json" "${LOCAL_HOME}/profiles" "${LOCAL_HOME}/skills" \
    "${LOCAL_HOME}/shared" "${LOCAL_HOME}/workspaces" "${FIXTURE}/input/"
printf '%s\n' '{"schemaVersion":1,"backend":"s3","endpoint":"https://ceph.example.test","bucket":"pi-run-backups","prefix":"users/other","region":"eu-west-1","bucketLookup":"path"}' \
    > "${FIXTURE}/input/snapshot-config.json"
jq -n --arg request "${REQUEST_ID}" '{
    schemaVersion:1,requestId:$request,createdAt:"2026-08-01T10:00:00Z",scope:"complete",
    piRunVersion:"0.5.12",runtimeImage:"ghcr.io/aprilsoftware/pi-run:0.5.12",piVersion:"1.1.0",
    homeConfigurationSchemaVersion:1,profileSchemaVersion:1,workspaceRegistrySchemaVersion:1,
    snapshotConfigurationSchemaVersion:1,
    includedPaths:["config.json","profiles","skills","shared","workspaces","snapshots/config.json","snapshots/metadata/11111111-1111-4111-8111-111111111111.json"],
    excludedPaths:["machines","snapshots/secrets","snapshots/s3-credentials","snapshots/repository","snapshots/restore-staging"]
}' > "${FIXTURE}/input/snapshot-manifest.json"
SNAPSHOT_METADATA="$(jq -nc --arg id "${SNAPSHOT_ID}" --arg request "${REQUEST_ID}" '[{
    id:$id,time:"2026-08-01T10:00:00Z",hostname:"0123456789abcdef",
    tags:["pi-run","scope=complete",("request="+$request)]
}]')"
export RESTORE_FIXTURE="${FIXTURE}" SNAPSHOT_METADATA

live_hash="$(sha256sum "${LOCAL_HOME}/config.json" "${LOCAL_HOME}/profiles/default/profile.json")"
: > "${RESTORE_LOG}"
recovery_output="$(run_recover "${LOCAL_HOME}")"
recovered="${LOCAL_HOME}/snapshots/recovered/${SNAPSHOT_ID}"
[[ "${recovery_output}" == *"Snapshot recovered: ${SNAPSHOT_ID}"* &&
   "${recovery_output}" == *"Path: ${recovered}"* &&
   "${recovery_output}" == *'Live Pi-Run data was not changed.'* ]] \
    || fail "local recovery output is incomplete"
[[ -f "${recovered}/config.json" && -d "${recovered}/profiles/default" &&
   -f "${recovered}/snapshot-config.json" && -f "${recovered}/snapshot-manifest.json" &&
   -f "${recovered}/recovery.json" && ! -e "${recovered}/input" ]] \
    || fail "recovered snapshot layout is invalid"
[[ "$(stat -c %a "${recovered}")" == 700 ]] || fail "recovered snapshot is not private"
jq -e --arg id "${SNAPSHOT_ID}" --arg request "${REQUEST_ID}" '
    .schemaVersion==1 and .snapshotId==$id and .requestId==$request and
    .scope=="complete" and .sourceBackend=="local" and .sourceMachine=="0123456789abcdef"
' "${recovered}/recovery.json" >/dev/null || fail "recovery metadata is invalid"
[[ "$(sha256sum "${LOCAL_HOME}/config.json" "${LOCAL_HOME}/profiles/default/profile.json")" == "${live_hash}" ]] \
    || fail "snapshot recovery changed live Pi-Run data"
printf preserved > "${recovered}/shared/recovery-sentinel"
expect_failure run_recover "${LOCAL_HOME}"
[[ "$(cat "${recovered}/shared/recovery-sentinel")" == preserved ]] \
    || fail "existing recovery was overwritten"
[[ -z "$(find "${LOCAL_HOME}/snapshots/recovered" -maxdepth 1 -name '.recover.*' -print -quit)" ]] \
    || fail "successful recovery left temporary data"
for argument in '--network' none '--no-lock' restore "${SNAPSHOT_ID}" '--target' /restore '--verify'; do
    grep -Fx -- "${argument}" "${RESTORE_LOG}" >/dev/null || fail "missing local recovery argument: ${argument}"
done
grep -F 'dst=/repository,readonly' "${RESTORE_LOG}" >/dev/null || fail "local recovery repository was not read-only"

: > "${RESTORE_LOG}"
expect_failure run_restore "${LOCAL_HOME}" "${SNAPSHOT_ID}\n"
[[ -z "$(find "${LOCAL_HOME}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
    || fail "configuration mismatch left local staging"
for argument in '--network' none '--no-lock' restore "${SNAPSHOT_ID}" '--target' /restore '--verify'; do
    grep -Fx -- "${argument}" "${RESTORE_LOG}" >/dev/null || fail "missing local restore argument: ${argument}"
done
grep -F 'dst=/repository,readonly' "${RESTORE_LOG}" >/dev/null || fail "local repository was not read-only"

S3_HOME="${TMP}/s3"
configure_s3 "${S3_HOME}"
LOCAL_FIXTURE="${TMP}/local-fixture"
cp -a "${FIXTURE}" "${LOCAL_FIXTURE}"
printf '%s\n' '{"schemaVersion":1,"backend":"local","repository":"repository"}' \
    > "${LOCAL_FIXTURE}/input/snapshot-config.json"
: > "${RESTORE_LOG}"
RESTORE_FIXTURE="${LOCAL_FIXTURE}" expect_failure run_restore "${S3_HOME}" "${SNAPSHOT_ID}\n" "${SNAPSHOT_ID}"
[[ -z "$(find "${S3_HOME}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
    || fail "configuration mismatch left S3 staging"
for argument in '--network' bridge 'AWS_SHARED_CREDENTIALS_FILE=/s3-credentials' \
    'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' 's3.region=eu-west-1' \
    's3.bucket-lookup=path' '--verify'; do
    grep -Fx -- "${argument}" "${RESTORE_LOG}" >/dev/null || fail "missing S3 restore argument: ${argument}"
done
grep -F 'src=/etc/ssl/certs/ca-certificates.crt,dst=/etc/ssl/certs/ca-certificates.crt,readonly' \
    "${RESTORE_LOG}" >/dev/null || fail "S3 restore did not mount the host CA bundle read-only"
if grep -F 'dst=/repository' "${RESTORE_LOG}" >/dev/null; then fail "S3 restore mounted a local repository"; fi
if grep -E 'ACCESS_123|SECRET/456' "${DOCKER_LOG}" >/dev/null; then fail "credentials leaked into Docker arguments"; fi

RESTORE_FIXTURE="${LOCAL_FIXTURE}"
: > "${RESTORE_LOG}"
recovery_output="$(run_recover "${S3_HOME}" "${SNAPSHOT_ID}")"
recovered="${S3_HOME}/snapshots/recovered/${SNAPSHOT_ID}"
[[ "${recovery_output}" == *"Path: ${recovered}"* && -f "${recovered}/profiles/default/profile.json" ]] \
    || fail "S3 snapshot recovery was not published"
jq -e '.sourceBackend=="s3"' "${recovered}/recovery.json" >/dev/null \
    || fail "S3 recovery metadata has the wrong backend"
for argument in '--network' bridge 'AWS_SHARED_CREDENTIALS_FILE=/s3-credentials' \
    'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' '--verify'; do
    grep -Fx -- "${argument}" "${RESTORE_LOG}" >/dev/null || fail "missing S3 recovery argument: ${argument}"
done

RECOVERY_FAILURE_HOME="${TMP}/recovery-failure"
cp -a "${S3_HOME}" "${RECOVERY_FAILURE_HOME}"
rm -rf "${RECOVERY_FAILURE_HOME}/snapshots/recovered"
FAIL_RESTORE=1 expect_failure run_recover "${RECOVERY_FAILURE_HOME}"
[[ ! -e "${RECOVERY_FAILURE_HOME}/snapshots/recovered/${SNAPSHOT_ID}" &&
   -z "$(find "${RECOVERY_FAILURE_HOME}/snapshots/recovered" -maxdepth 1 -name '.recover.*' -print -quit)" ]] \
    || fail "failed recovery left published or temporary data"
RESTORE_FIXTURE="${FIXTURE}"

failure_case() {
    local name="$1" fixture="$2" metadata="${3:-${SNAPSHOT_METADATA}}" fail_restore="${4:-0}"
    local home="${TMP}/case-${name}"
    cp -a "${S3_HOME}" "${home}"
    RESTORE_FIXTURE="${fixture}" SNAPSHOT_METADATA="${metadata}" FAIL_RESTORE="${fail_restore}" \
        expect_failure run_restore "${home}" "${SNAPSHOT_ID}\n"
    [[ -z "$(find "${home}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
        || fail "${name} restore left staging content"
}

WRONG_SCOPE="$(jq -nc --arg id "${SNAPSHOT_ID}" '[{id:$id,time:"2026-08-01T10:00:00Z",tags:["pi-run","scope=profile","request=11111111-1111-4111-8111-111111111111"]}]')"
failure_case wrong-scope "${FIXTURE}" "${WRONG_SCOPE}"
failure_case unknown "${FIXTURE}" '[]'
AMBIGUOUS="$(jq -nc '[
    {id:"dddddddddddd1111111111111111111111111111111111111111111111111111",time:"2026-08-01T00:00:00Z",tags:["pi-run","scope=complete","request=11111111-1111-4111-8111-111111111111"]},
    {id:"dddddddddddd2222222222222222222222222222222222222222222222222222",time:"2026-08-02T00:00:00Z",tags:["pi-run","scope=complete","request=22222222-2222-4222-8222-222222222222"]}
]')"
home="${TMP}/case-ambiguous"
cp -a "${S3_HOME}" "${home}"
SNAPSHOT_METADATA="${AMBIGUOUS}" expect_failure run_restore "${home}" "${SNAPSHOT_ID}\n" dddddddddddd
[[ -z "$(find "${home}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
    || fail "ambiguous restore left staging content"
UNSAFE="${TMP}/unsafe"
cp -a "${FIXTURE}" "${UNSAFE}"
ln -s /etc/passwd "${UNSAFE}/input/shared/unsafe-link"
failure_case unsafe "${UNSAFE}"
MISSING="${TMP}/missing"
cp -a "${FIXTURE}" "${MISSING}"
rm -rf "${MISSING}/input/shared"
failure_case missing "${MISSING}"
MISMATCH="${TMP}/mismatch"
cp -a "${FIXTURE}" "${MISMATCH}"
jq '.requestId="22222222-2222-4222-8222-222222222222"' \
    "${MISMATCH}/input/snapshot-manifest.json" > "${MISMATCH}/input/manifest.tmp"
mv "${MISMATCH}/input/manifest.tmp" "${MISMATCH}/input/snapshot-manifest.json"
failure_case mismatch "${MISMATCH}"
OVERSIZED="${TMP}/oversized"
cp -a "${FIXTURE}" "${OVERSIZED}"
head -c 262145 /dev/zero | tr '\0' x > "${OVERSIZED}/input/snapshot-manifest.json"
failure_case oversized "${OVERSIZED}"
failure_case restic-failure "${FIXTURE}" "${SNAPSHOT_METADATA}" 1

cancel_output="$(run_restore "${LOCAL_HOME}" 'no\n')"
[[ "${cancel_output}" == *'Snapshot restore cancelled.'* ]] || fail "restore cancellation was not reported"
[[ -z "$(find "${LOCAL_HOME}/snapshots/restore-staging" -mindepth 1 -print -quit)" ]] \
    || fail "cancelled restore created staging"

for removed in stage-restore restore-status cancel-restore apply-restore; do
    expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${LOCAL_HOME}" \
        "${ROOT}/bin/pi-run" snapshot "${removed}" "${SNAPSHOT_ID}"
done

echo "snapshot unified staging tests passed"
