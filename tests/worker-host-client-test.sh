#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Exercise the host smoke controller without Docker, Node, or provider calls.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
mkdir -p "${TMP}/source/tests" "${TMP}/source/bin" "${TMP}/bin"
cp "${ROOT}/tests/worker-real-docker-test.sh" "${TMP}/source/tests/"
# A closed PATH proves the client works with NO host node/nodejs command.
for tool in bash dirname mktemp mkdir rm awk jq timeout sleep; do
    ln -s "$(command -v "${tool}")" "${TMP}/bin/${tool}"
done
if PATH="${TMP}/bin" command -v node >/dev/null || PATH="${TMP}/bin" command -v nodejs >/dev/null; then
    echo 'worker-host-client-test: fixture unexpectedly exposes Node' >&2
    exit 1
fi
cat > "${TMP}/bin/id" <<'SH'
#!/usr/bin/env bash
printf '1001\n'
SH
cat > "${TMP}/bin/git" <<'SH'
#!/usr/bin/env bash
# Git behavior is not under test here; only the host RPC controller is.
exit 0
SH
cat > "${TMP}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
    'image inspect') exit 0 ;;
    'image rm') printf 'removed\n' > "${FAKE_STATE}/image-removed"; exit 0 ;;
esac
case "$1" in
    inspect)
        [[ "$2" == "pi-default-$(<"${FAKE_STATE}/pid")" ]] || exit 99
        jq -n --arg mode "${FAKE_MODE}" '[{
            Config: {Tty: ($mode == "tty")},
            HostConfig: {NetworkMode: (if $mode == "network" then "host" else "none" end)},
            Mounts: ((if $mode == "role-missing" then [] else
                [{Destination: "/run/pi-run-role.txt", RW: ($mode == "role-writable")}] end) +
                (if $mode == "socket" then [{Destination: "/var/run/docker.sock", RW: true}] else [] end))
        }]'
        ;;
    exec)
        [[ "$2" == --user && "$3" == 1001 && "$4" == "pi-default-$(<"${FAKE_STATE}/pid")" ]]
        [[ "$5" == sh && "$6" == -c && "$7" == 'test ! -w /run/pi-run-role.txt && test -d /knowledge' ]]
        printf 'checked\n' > "${FAKE_STATE}/exec-checked"
        [[ "${FAKE_MODE}" != exec-failure ]]
        ;;
    ps)
        [[ "$2" == -aq && "$3" == --filter && "$4" == "name=^/pi-default-$(<"${FAKE_STATE}/pid")$" ]]
        [[ "${FAKE_MODE}" != daemon-unavailable ]] || exit 1
        [[ ! -e "${FAKE_STATE}/container" ]] || printf 'remaining-container\n'
        ;;
    *) exit 99 ;;
esac
SH
cat > "${TMP}/source/bin/pi-run" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ID=11111111-1111-4111-8111-111111111111
if [[ "$1" == init ]]; then exit 0; fi
case "$1 $2" in
    'runtime build') exit 0 ;;
    'runtime status') printf 'Prepared tag: fixture-profile:prepared\n'; exit 0 ;;
    'network mode') [[ "$3" == offline ]]; exit ;;
    'worktree create')
        mkdir -p "${FAKE_STATE}/worktree"
        jq -n --arg path "${FAKE_STATE}/worktree" --arg id "${ID}" '{path:$path,workspaceId:$id}'
        exit 0 ;;
esac
[[ "$1 $2" == 'worker launch' && "$4" == --role-file && -f "$5" ]]
printf '%s\n' "$$" > "${FAKE_STATE}/pid"
printf '%s\n' "${PI_RUN_HOME}" > "${FAKE_STATE}/home"
printf 'created\n' > "${FAKE_STATE}/container"
LOCK="${PI_RUN_HOME}/worktrees/.launch-locks/${ID}"
mkdir -p "${LOCK}"
cleanup() {
    [[ "${FAKE_MODE}" == container-retained ]] || rm -f "${FAKE_STATE}/container"
    [[ "${FAKE_MODE}" == lock-retained ]] || rm -rf "${LOCK}"
    printf 'cleaned\n' > "${FAKE_STATE}/child-cleaned"
}
trap cleanup EXIT
trap 'exit 143' TERM INT
case "${FAKE_MODE}" in
    no-ready) exit 42 ;;
    malformed) printf 'not-json\n'; exit 74 ;;
    incomplete) printf '{"type":"pi_run_worker_ready"}'; exit 74 ;;
    null-record) printf 'null\n'; exit 74 ;;
    hang-before-ready) while :; do sleep 1; done ;;
esac
printf '{"type":"extension_ui_request","message":"héllo"}\n'
# Deliberately split a readiness record across writes.
printf '{"type":"pi_run_'
sleep 0.02
printf 'worker_ready"}\n'
# No controller message is expected. EOF proves every writer copy was closed.
if IFS= read -r input; then exit 95; fi
printf 'EOF\n' > "${FAKE_STATE}/eof"
if [[ "${FAKE_MODE}" == closed-stdout-hang ]]; then
    exec 1>&-
    while :; do sleep 1; done
fi
if [[ "${FAKE_MODE}" == duplicate-ready ]]; then printf '{"type":"pi_run_worker_ready"}\n'; fi
printf '{"type":"pi_run_worker_exit"}\n'
[[ "${FAKE_MODE}" != wrong-status ]] || exit 0
exit 74
SH
chmod 0755 "${TMP}/bin/id" "${TMP}/bin/git" "${TMP}/bin/docker" "${TMP}/source/bin/pi-run"
run_case() {
    local mode=$1 expected=$2 message=${3:-} state="${TMP}/${1}" status=0
    mkdir -p "${state}/tmp"
    PATH="${TMP}/bin" TMPDIR="${state}/tmp" FAKE_STATE="${state}" FAKE_MODE="${mode}" \
        PI_RUN_TEST_REAL_DOCKER=1 PI_RUN_WORKER_TEST_CORE=fixture:core PI_RUN_WORKER_TEST_TIMEOUT_SECONDS=3 \
        bash "${TMP}/source/tests/worker-real-docker-test.sh" > "${state}/output" 2>&1 || status=$?
    if [[ "${status}" != "${expected}" ]]; then
        printf 'worker-host-client-test: %s: expected exit %s, got %s; output:\n' "${mode}" "${expected}" "${status}" >&2
        while IFS= read -r line; do printf '%s\n' "${line}" >&2; done < "${state}/output"
        exit 1
    fi
    if [[ -n "${message}" ]] && ! grep -Fq "${message}" "${state}/output"; then
        printf 'worker-host-client-test: %s: missing diagnostic %s\n' "${mode}" "${message}" >&2
        exit 1
    fi
    if kill -0 "$(<"${state}/pid")" 2>/dev/null; then
        echo "${mode}: child is still running" >&2
        exit 1
    fi
    if [[ "${expected}" == 0 ]]; then
        [[ -e "${state}/child-cleaned" && -e "${state}/eof" && -e "${state}/exec-checked" && -e "${state}/image-removed" ]]
        [[ ! -e "$(<"${state}/home")" ]]
    else
        if grep -Fq 'worker-real-docker-test: PASS' "${state}/output"; then
            echo "${mode}: falsely reported PASS" >&2
            exit 1
        fi
        [[ -d "$(<"${state}/home")" && ! -e "${state}/image-removed" ]]
    fi
}
run_case success 0 'worker-real-docker-test: PASS'
run_case no-ready 1 'Worker exited before readiness'
run_case malformed 1 'Invalid JSONL record'
run_case incomplete 1 'Incomplete JSONL record'
run_case null-record 1 'Invalid JSONL record'
for mode in tty network role-missing role-writable socket; do
    run_case "${mode}" 1 'Unexpected TTY, network, Role mount, or Docker socket mount'
done
run_case exec-failure 1 'Role permissions or knowledge initialization check failed'
run_case wrong-status 1 'Expected connection-loss exit 74, got 0'
run_case duplicate-ready 1 'Duplicate readiness record'
run_case lock-retained 1 'Workspace lock was retained'
run_case container-retained 1 'Worker container was retained'
run_case daemon-unavailable 1 'Cannot verify container cleanup'
run_case hang-before-ready 124 'FAIL (exit 124)'
run_case closed-stdout-hang 124 'FAIL (exit 124)'
PI_RUN_TEST_REAL_DOCKER=0 bash "${ROOT}/tests/worker-real-docker-test.sh" | grep -Fq 'SKIP'
printf '%s\n' 'worker-host-client-test: PASS (18 isolated no-Node controller cases and default opt-in SKIP; no real Docker)'
