#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-menu-test: $*" >&2
    exit 1
}

HOME_DIR="${TMP}/Pi Run"
mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
printf '%s\n' '--- docker call ---' >> "${DOCKER_LOG:?}"
repository=
entrypoint=
operation=
previous=
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG}"
    [ "${previous}" != --entrypoint ] || entrypoint=${argument}
    case "${argument}" in
        RESTIC_REPOSITORY=/snapshots/*) repository=${argument#RESTIC_REPOSITORY=} ;;
        init|snapshots|backup|check) operation=${argument} ;;
    esac
    previous=${argument}
done
if [ "${entrypoint}" = pi ]; then
    printf '1.1.0\n'
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
        printf '%s\n' '{"message_type":"summary","snapshot_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
        ;;
    check)
        printf '%s\n' '{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}'
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"
export SNAPSHOT_TEST_ROOT="${HOME_DIR}/snapshots"
: > "${DOCKER_LOG}"

run_menu() {
    env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        SNAPSHOT_TEST_ROOT="${SNAPSHOT_TEST_ROOT}" DOCKER_LOG="${DOCKER_LOG}" \
        "${ROOT}/bin/pi-run" snapshot
}

# The unconfigured menu re-prompts invalid input and enters the configuration
# wizard without requiring a separate command.
output="$(printf 'wrong\n1\n1\nyes\n' | run_menu 2>&1)"
[[ "${output}" == *'Snapshots are not configured.'* &&
   "${output}" == *'Enter 1 to configure snapshots or q to cancel.'* &&
   "${output}" == *'Choose snapshot storage:'* ]] \
    || fail "unconfigured menu did not guide configuration"
[[ -f "${HOME_DIR}/snapshots/config.json" && -f "${HOME_DIR}/snapshots/repository/config" ]] \
    || fail "menu configuration did not create the local repository"

output="$(printf '1\n' | run_menu 2>&1)"
[[ "${output}" == *'Snapshot management:'* && "${output}" == *'Snapshot status: ready'* ]] \
    || fail "status menu action was not dispatched"

output="$(printf '3\n' | run_menu 2>&1)"
[[ "${output}" == *'No Pi-Run snapshots.'* ]] || fail "list menu action was not dispatched"

calls_before="$(grep -c '^--- docker call ---$' "${DOCKER_LOG}")"
output="$(printf '2\nno\n' | run_menu 2>&1)"
[[ "${output}" == *'Snapshot creation cancelled.'* ]] || fail "create cancellation was not reported"
[[ "$(grep -c '^--- docker call ---$' "${DOCKER_LOG}")" == "${calls_before}" ]] \
    || fail "declined creation invoked Docker"

output="$(printf '2\nyes\n' | run_menu 2>&1)"
[[ "${output}" == *'Snapshot created: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'* ]] \
    || fail "confirmed create menu action was not dispatched"

calls_before="$(grep -c '^--- docker call ---$' "${DOCKER_LOG}")"
output="$(printf '4\nno\n' | run_menu 2>&1)"
[[ "${output}" == *'downloads all stored data'* && "${output}" == *'Snapshot check cancelled.'* ]] \
    || fail "check warning or cancellation is missing"
[[ "$(grep -c '^--- docker call ---$' "${DOCKER_LOG}")" == "${calls_before}" ]] \
    || fail "declined integrity check invoked Docker"

output="$(printf 'bad\n4\nyes\n' | run_menu 2>&1)"
[[ "${output}" == *'Enter 1, 2, 3, 4, or q to cancel.'* &&
   "${output}" == *'Snapshot check: OK'* && "${output}" == *'Data verification: complete'* ]] \
    || fail "confirmed check action or invalid-input guidance is missing"

output="$(printf 'q\n' | run_menu 2>&1)"
[[ "${output}" == *'Snapshot menu cancelled.'* ]] || fail "explicit menu cancellation was not reported"
output="$(run_menu </dev/null 2>&1)"
[[ "${output}" == *'Snapshot menu cancelled.'* ]] || fail "menu EOF was not handled as cancellation"

echo "snapshot interactive menu tests passed"
