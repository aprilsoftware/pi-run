#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-list-test: $*" >&2
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
mkdir -p "${TMP}/fake-bin"

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
: > "${DOCKER_LOG:?}"
repository=
operation=
tagged=false
previous=
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG}"
    case "${argument}" in
        RESTIC_REPOSITORY=/snapshots/*) repository=${argument#RESTIC_REPOSITORY=} ;;
        init|snapshots) operation=${argument} ;;
    esac
    if [ "${previous}" = --tag ] && [ "${argument}" = pi-run ]; then tagged=true; fi
    previous=${argument}
done
case "${operation}" in
    init)
        destination="${SNAPSHOT_TEST_ROOT:?}/${repository#/snapshots/}"
        mkdir "${destination}"
        printf 'restic repository\n' > "${destination}/config"
        ;;
    snapshots)
        if [ "${tagged}" = true ]; then
            [ "${FAIL_LIST:-0}" = 0 ] || exit 1
            printf '%s\n' "${LIST_RESPONSE:-[]}"
        else
            printf '[]\n'
        fi
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"
export SNAPSHOT_TEST_ROOT="${HOME_DIR}/snapshots"

printf '1\nyes\n' | env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot configure >/dev/null
secret_value="$(< "${HOME_DIR}/snapshots/secrets")"
state_before="$(sha256sum "${HOME_DIR}/snapshots/config.json" \
    "${HOME_DIR}/snapshots/secrets" "${HOME_DIR}/snapshots/repository/config")"

LIST_RESPONSE="$(jq -nc '[
    {
        time: "2026-08-01T10:00:00Z",
        id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        hostname: "pi-run",
        tags: ["pi-run", "scope=complete", "request=11111111-1111-4111-8111-111111111111"]
    },
    {
        time: "2026-08-02T11:30:00Z",
        id: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        hostname: "0123456789abcdef",
        tags: ["request=22222222-2222-4222-8222-222222222222", "scope=complete", "purpose=pre-restore", "pi-run"]
    }
]')"
export LIST_RESPONSE
list_output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot list)"
[[ "$(printf '%s\n' "${list_output}" | sed -n '2p' | awk '{print $1}')" == bbbbbbbbbbbb ]] \
    || fail "snapshots were not listed oldest first"
[[ "$(printf '%s\n' "${list_output}" | sed -n '3p' | awk '{print $1}')" == cccccccccccc ]] \
    || fail "newest snapshot was not listed last"
[[ "${list_output}" == *'MACHINE'* && "${list_output}" == *'PURPOSE'* &&
   "${list_output}" == *'0123456789abcdef'* &&
   "$(printf '%s\n' "${list_output}" | awk 'NR==3 {print $5}')" == 'pre-restore' &&
   "$(printf '%s\n' "${list_output}" | awk 'NR==2 {print $3}')" == '-' &&
   "$(printf '%s\n' "${list_output}" | awk 'NR==2 {print $5}')" == '-' &&
   "${list_output}" == *'complete'* ]] || fail "snapshot provenance, scope, or purpose is missing"
[[ "${list_output}" != *'22222222-2222-4222-8222-222222222222'* &&
   "${list_output}" != *'REQUEST'* ]] || fail "default snapshot list exposed internal request IDs"
[[ "${list_output}" != *"${secret_value}"* ]] || fail "snapshot secret was printed"
[[ "${state_before}" == "$(sha256sum "${HOME_DIR}/snapshots/config.json" \
    "${HOME_DIR}/snapshots/secrets" "${HOME_DIR}/snapshots/repository/config")" ]] \
    || fail "snapshot list modified repository configuration"
grep -Fx -- '--no-lock' "${DOCKER_LOG}" >/dev/null || fail "list did not disable locking"
grep -Fx -- '--tag' "${DOCKER_LOG}" >/dev/null || fail "list did not filter by tag"
grep -Fx -- 'pi-run' "${DOCKER_LOG}" >/dev/null || fail "list used the wrong tag"
grep -F "type=bind,src=${HOME_DIR}/snapshots,dst=/snapshots,readonly" "${DOCKER_LOG}" >/dev/null \
    || fail "list did not use a read-only repository mount"

empty_output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" LIST_RESPONSE='[]' \
    "${ROOT}/bin/pi-run" snapshot list)"
[[ "${empty_output}" == "No Pi-Run snapshots." ]] || fail "empty list output is unclear"

MALFORMED='[{"time":"not-a-time","id":"short","tags":["pi-run"]}]'
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" LIST_RESPONSE="${MALFORMED}" \
    "${ROOT}/bin/pi-run" snapshot list
INVALID_HOST="$(jq -nc '[{time:"2026-08-01T10:00:00Z",id:("b"*64),hostname:"workstation-name",tags:["pi-run","scope=complete","request=11111111-1111-4111-8111-111111111111"]}]')"
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" LIST_RESPONSE="${INVALID_HOST}" \
    "${ROOT}/bin/pi-run" snapshot list
INVALID_PURPOSE="$(jq -nc '[{time:"2026-08-01T10:00:00Z",id:("b"*64),tags:["pi-run","scope=complete","request=11111111-1111-4111-8111-111111111111","purpose=other"]}]')"
DUPLICATE_PURPOSE="$(jq -nc '[{time:"2026-08-01T10:00:00Z",id:("b"*64),tags:["pi-run","scope=complete","request=11111111-1111-4111-8111-111111111111","purpose=manual","purpose=automatic"]}]')"
for invalid in "${INVALID_PURPOSE}" "${DUPLICATE_PURPOSE}"; do
    expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" LIST_RESPONSE="${invalid}" \
        "${ROOT}/bin/pi-run" snapshot list
done
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" LIST_RESPONSE='[]' FAIL_LIST=1 \
    "${ROOT}/bin/pi-run" snapshot list

echo "snapshot list tests passed"
