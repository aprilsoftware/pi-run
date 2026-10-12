#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-restore-state-test: $*" >&2
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
HOME_DIR="${TMP}/Pi Run"
mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
operation=
repository=
reference=
for argument in "$@"; do
    case "${argument}" in init|snapshots|restore) operation=${argument} ;; esac
    case "${argument}" in
        RESTIC_REPOSITORY=*) repository=${argument#RESTIC_REPOSITORY=} ;;
        [0-9a-f]*) if [ "${#argument}" -eq 12 ] || [ "${#argument}" -eq 64 ]; then reference=${argument}; fi ;;
    esac
done
case "${operation}" in
    init)
        destination="${SNAPSHOT_TEST_ROOT:?}/${repository#/snapshots/}"
        mkdir "${destination}"
        printf repository > "${destination}/config"
        ;;
    snapshots)
        if [ -n "${reference}" ]; then printf '%s\n' "${SNAPSHOT_METADATA:?}"; else printf '[]\n'; fi
        ;;
    restore) exit 1 ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

export SNAPSHOT_TEST_ROOT="${HOME_DIR}/snapshots"
printf '1\nyes\n' | env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null
SNAPSHOT_METADATA="$(jq -nc --arg id "${SNAPSHOT_ID}" --arg request "${REQUEST_ID}" '[{
    id:$id,time:"2026-08-01T10:00:00Z",hostname:"0123456789abcdef",
    tags:["pi-run","scope=complete",("request="+$request)]
}]')"
export SNAPSHOT_METADATA

TEMPLATE="${TMP}/pending-template"
mkdir -p "${TEMPLATE}/input"
cp -a "${HOME_DIR}/config.json" "${HOME_DIR}/profiles" "${HOME_DIR}/skills" \
    "${HOME_DIR}/shared" "${HOME_DIR}/workspaces" "${TEMPLATE}/input/"
printf '%s\n' '{"schemaVersion":1,"backend":"local","repository":"repository"}' \
    > "${TEMPLATE}/input/snapshot-config.json"
jq -n --arg request "${REQUEST_ID}" '{
    schemaVersion:1,requestId:$request,createdAt:"2026-08-01T10:00:00Z",scope:"complete",
    piRunVersion:"0.5.12",runtimeImage:"ghcr.io/aprilsoftware/pi-run:0.5.12",piVersion:"1.1.0",
    homeConfigurationSchemaVersion:1,profileSchemaVersion:1,workspaceRegistrySchemaVersion:1,
    snapshotConfigurationSchemaVersion:1,
    includedPaths:["config.json","profiles","skills","shared","workspaces","snapshots/config.json","snapshots/metadata/11111111-1111-4111-8111-111111111111.json"],
    excludedPaths:["machines","snapshots/secrets","snapshots/s3-credentials","snapshots/repository","snapshots/restore-staging"]
}' > "${TEMPLATE}/input/snapshot-manifest.json"
jq -n --arg id "${SNAPSHOT_ID}" --arg request "${REQUEST_ID}" '{
    schemaVersion:1,state:"validated",snapshotId:$id,requestId:$request,
    stagedAt:"2026-08-02T12:00:00Z",sourceBackend:"local"
}' > "${TEMPLATE}/stage.json"
chmod 0600 "${TEMPLATE}/stage.json"

staging="${HOME_DIR}/snapshots/restore-staging"
reset_staging() {
    find "${staging}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}
install_pending() {
    reset_staging
    cp -a "${TEMPLATE}" "${staging}/pending"
}
run_restore() {
    local input="$1" command="" argument
    local -a invocation=(env "PATH=${TMP}/fake-bin:${PATH}" "PI_RUN_HOME=${HOME_DIR}"
        "SNAPSHOT_TEST_ROOT=${SNAPSHOT_TEST_ROOT}" "SNAPSHOT_METADATA=${SNAPSHOT_METADATA}"
        "${ROOT}/bin/pi-run" snapshot restore "${SNAPSHOT_ID:0:12}")
    for argument in "${invocation[@]}"; do printf -v command '%s%q ' "${command}" "${argument}"; done
    printf '%b' "${input}" | script -qefc "${command}" /dev/null
}

live_hash="$(sha256sum "${HOME_DIR}/config.json" "${HOME_DIR}/profiles/default/profile.json")"

install_pending
expect_failure run_restore "${SNAPSHOT_ID}\n"
[[ -z "$(find "${staging}" -mindepth 1 -print -quit)" ]] \
    || fail "validated stale staging was not removed after the new staging failure"

install_pending
mv "${staging}/pending" "${staging}/.cancelled.${SNAPSHOT_ID}"
rm -rf "${staging}/.cancelled.${SNAPSHOT_ID}/input/profiles"
expect_failure run_restore "${SNAPSHOT_ID}\n"
[[ -z "$(find "${staging}" -mindepth 1 -print -quit)" ]] \
    || fail "interrupted cleanup staging was not removed"

reset_staging
mkdir "${staging}/.pending.12345"
printf partial > "${staging}/.pending.12345/partial"
expect_failure run_restore "${SNAPSHOT_ID}\n"
[[ -z "$(find "${staging}" -mindepth 1 -print -quit)" ]] \
    || fail "incomplete staging was not removed"

install_pending
jq '.state="broken"' "${staging}/pending/stage.json" > "${staging}/pending/stage.tmp"
mv "${staging}/pending/stage.tmp" "${staging}/pending/stage.json"
chmod 0600 "${staging}/pending/stage.json"
expect_failure run_restore "${SNAPSHOT_ID}\n"
[[ -d "${staging}/pending" ]] || fail "invalid pending state was deleted"

reset_staging
printf unknown > "${staging}/unknown"
expect_failure run_restore "${SNAPSHOT_ID}\n"
[[ -f "${staging}/unknown" ]] || fail "unknown staging state was deleted"

[[ "$(sha256sum "${HOME_DIR}/config.json" "${HOME_DIR}/profiles/default/profile.json")" == "${live_hash}" ]] \
    || fail "live data changed during staging cleanup tests"

for removed in stage-restore restore-status cancel-restore apply-restore; do
    expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        "${ROOT}/bin/pi-run" snapshot "${removed}" "${SNAPSHOT_ID}"
done

echo "snapshot unified restore state tests passed"
