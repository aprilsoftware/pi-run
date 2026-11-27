#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Real Pi + unchanged Worker runtime; fixture HTTP endpoint is container-loopback only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${PI_RUN_TEST_REAL_DOCKER:-0}" != 1 ]]; then
    echo 'worker-roundtrip-real-docker-test: SKIP (requires approved non-root host Docker and a local candidate core)'
    exit 0
fi
: "${PI_RUN_WORKER_TEST_CORE:?Set a local candidate core image built from this source}"
for command in docker bash jq git timeout mkfifo sha256sum; do command -v "${command}" >/dev/null; done
HOST_UID="$(id -u)" HOST_GID="$(id -g)"
[[ "${HOST_UID}" != 0 && "${HOST_GID}" != 0 ]] || { echo 'Run as non-root on the Docker host' >&2; exit 1; }
CORE_ID="$(docker image inspect --format '{{.Id}}' "${PI_RUN_WORKER_TEST_CORE}")"
[[ "${CORE_ID}" =~ ^sha256:[0-9a-f]{64}$ ]]
umask 077
TMP="$(mktemp -d)"
TOKEN="$(< /proc/sys/kernel/random/uuid)"
PREPARED_TAG=""
cleanup() {
    local status=$? containers id failed=false file
    # Only helper containers carrying this invocation's random label are ours.
    if containers="$(timeout -k 2 10 docker ps -aq --filter "label=pi-run.worker-roundtrip=${TOKEN}")"; then
        for id in ${containers}; do
            [[ "${id}" =~ ^[0-9a-f]{12,64}$ ]] && timeout -k 2 15 docker rm -f "${id}" >/dev/null 2>&1 || failed=true
        done
    else failed=true; fi
    # After readiness the runner saves verified immutable Worker container IDs.
    for file in "${TMP}"/*.container-id; do
        [[ -f "${file}" ]] || continue
        id="$(< "${file}")"
        if containers="$(timeout -k 2 10 docker ps -aq --filter "id=${id}")"; then
            [[ -z "${containers}" ]] || timeout -k 2 15 docker rm -f "${id}" >/dev/null 2>&1 || failed=true
        else failed=true; fi
    done
    if (( status != 0 )) || [[ "${failed}" == true ]]; then
        printf 'worker-roundtrip-real-docker-test: FAIL; retained fixtures at %s (prepared image %s)\n' \
            "${TMP}" "${PREPARED_TAG:-not recorded}" >&2
        for file in "${TMP}"/*.log; do
            [[ -f "${file}" ]] || continue
            printf '\n--- %s ---\n' "${file##*/}" >&2
            tail -60 "${file}" >&2
        done
        (( status != 0 )) || status=1
        exit "${status}"
    fi
    [[ -z "${PREPARED_TAG}" ]] || docker image rm "${PREPARED_TAG}" >/dev/null 2>&1 || true
    rm -rf -- "${TMP}"
    echo 'worker-roundtrip-real-docker-test: PASS (multiple messages, saved history, exact resume, immutable Role, queued abort, shutdown and cleanup; no live provider)'
}
trap cleanup EXIT
export PI_RUN_HOME="${TMP}/home" PI_RUN_CORE_IMAGE="${CORE_ID}" PI_RUN_IMAGE="${CORE_ID}"
CLI="${ROOT}/bin/pi-run" FIXTURES="${ROOT}/tests/fixtures"
"${CLI}" init >/dev/null
"${CLI}" network mode offline >/dev/null
PROFILE="${PI_RUN_HOME}/profiles/default"
cp "${FIXTURES}/worker-roundtrip-models.json" "${PROFILE}/models.json"
if [[ -f "${PROFILE}/settings.json" ]]; then
    jq -s '.[0] * .[1]' "${PROFILE}/settings.json" "${FIXTURES}/worker-roundtrip-settings.json" > "${TMP}/settings.json"
    install -m 0600 "${TMP}/settings.json" "${PROFILE}/settings.json"
else
    install -m 0600 "${FIXTURES}/worker-roundtrip-settings.json" "${PROFILE}/settings.json"
fi
printf '\nWORKER_ROUNDTRIP_BASELINE\n' >> "${PROFILE}/AGENTS.md"
printf 'WORKER_ROUNDTRIP_ROLE_ORIGINAL\n' > "${TMP}/role.txt"
sha256sum < "${TMP}/role.txt" | awk '{print $1}' > "${TMP}/role-hash"
mkdir "${TMP}/repository"
git -C "${TMP}/repository" init -q -b main
git -C "${TMP}/repository" -c user.name=fixture -c user.email=fixture@example.invalid commit --allow-empty -qm fixture
"${CLI}" runtime build
PREPARED_TAG="$("${CLI}" runtime status | awk '/^Prepared tag:/ {print $3}')"
"${CLI}" worktree create worker-roundtrip "${TMP}/repository" --json > "${TMP}/worktree.json"

# Bound all RPC phases and Docker queries; allow launchers to perform TERM cleanup.
timeout --kill-after=15s 240s bash -s -- "${ROOT}" "${TMP}" "${CORE_ID}" "${HOST_UID}" "${HOST_GID}" "${TOKEN}" <<'BASH'
set -euo pipefail
ROOT=$1 TMP=$2 CORE_ID=$3 HOST_UID=$4 HOST_GID=$5 TOKEN=$6
CLI="${ROOT}/bin/pi-run" FIXTURES="${ROOT}/tests/fixtures"
WORKSPACE="$(jq -er '.path' "${TMP}/worktree.json")"
WORKSPACE_ID="$(jq -er '.workspaceId' "${TMP}/worktree.json")"
PID="" CLIENT_PID=""
fail() { printf 'worker-roundtrip-real-docker-test: %s\n' "$*" >&2; exit 1; }
cleanup_children() {
    local status=$? child
    trap - EXIT
    for child in "${PID}" "${CLIENT_PID}"; do
        [[ -n "${child}" ]] || continue
        case $'\n'$(jobs -pr)$'\n' in
            *$'\n'"${child}"$'\n'*) kill -TERM "${child}" 2>/dev/null || true ;;
        esac
    done
    [[ -z "${PID}" ]] || wait "${PID}" 2>/dev/null || true
    [[ -z "${CLIENT_PID}" ]] || wait "${CLIENT_PID}" 2>/dev/null || true
    exit "${status}"
}
trap cleanup_children EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
run_phase() {
    local phase=$1 reference=${2:-} transport="${TMP}/${1}" container controller id remaining
    mkdir "${transport}"
    mkfifo "${transport}/to-worker" "${transport}/from-worker"
    [[ "${phase}" != resume ]] || cp "${TMP}/launch/result.json" "${transport}/previous.json"
    controller="pi-run-worker-roundtrip-${TOKEN}-${phase}"
    printf 'Checking Worker %s with offline mock streaming...\n' "${phase}"
    # Controller sees only private FIFO/result files and read-only fixture code.
    # Node runs in this utility container, not on the Docker host.
    docker run --rm --pull never --name "${controller}" --label "pi-run.worker-roundtrip=${TOKEN}" \
        --network none --user "${HOST_UID}:${HOST_GID}" --cap-drop ALL --security-opt no-new-privileges \
        --mount "type=bind,src=${transport},dst=/transport" \
        --mount "type=bind,src=${FIXTURES}/worker-roundtrip-client.mjs,dst=/fixture/client.mjs,readonly" \
        --entrypoint node "${CORE_ID}" /fixture/client.mjs /transport "${phase}" \
        </dev/null > "${TMP}/${phase}-client.log" 2>&1 &
    CLIENT_PID=$!
    if [[ "${phase}" == launch ]]; then
        (exec "${CLI}" worker launch "${WORKSPACE}" --role-file "${TMP}/role.txt" \
            < "${transport}/to-worker" > "${transport}/from-worker" 2> "${TMP}/${phase}-worker.log") &
    else
        (exec "${CLI}" worker resume "${reference}" \
            < "${transport}/to-worker" > "${transport}/from-worker" 2> "${TMP}/${phase}-worker.log") &
    fi
    PID=$!
    container="pi-default-${PID}"
    for _ in {1..900}; do
        [[ ! -f "${transport}/ready.json" ]] || break
        if ! kill -0 "${PID}" 2>/dev/null || ! kill -0 "${CLIENT_PID}" 2>/dev/null; then
            fail "${phase}: process exited before readiness"
        fi
        sleep 0.1
    done
    [[ -f "${transport}/ready.json" ]] || fail "${phase}: readiness timed out"
    docker inspect "${container}" > "${transport}/container.json"
    jq -e --arg profile "${PI_RUN_HOME}/profiles/default" '
        length == 1 and (.[0] | .Config.Tty == false and .HostConfig.NetworkMode == "none" and
        any(.Mounts[]; .Source == $profile and .Destination == "/profile") and
        any(.Mounts[]; .Destination == "/run/pi-run-role.txt" and .RW == false) and
        all(.Mounts[]; .Destination | contains("docker.sock") | not))
    ' "${transport}/container.json" >/dev/null || fail "${phase}: unexpected container isolation"
    id="$(jq -er '.[0].Id' "${transport}/container.json")"
    [[ "${id}" =~ ^[0-9a-f]{64}$ ]] || fail 'Invalid container identity'
    printf '%s\n' "${id}" > "${TMP}/${phase}.container-id"
    # Install only a test server into the disposable container's writable layer.
    # The actual entrypoint, Pi, Worker adapter, and protection extensions stay unchanged.
    docker cp "${FIXTURES}/worker-roundtrip-provider.mjs" "${id}:/tmp/worker-roundtrip-provider.mjs"
    docker exec -d --user "${HOST_UID}:${HOST_GID}" "${id}" node /tmp/worker-roundtrip-provider.mjs \
        /profile/logs/worker-roundtrip-provider.jsonl
    for _ in {1..100}; do
        docker exec "${id}" test -f /tmp/worker-roundtrip-provider-ready.json && break
        sleep 0.1
    done
    docker exec "${id}" jq -e '.port == 18888' /tmp/worker-roundtrip-provider-ready.json >/dev/null \
        || fail "${phase}: loopback mock provider did not start"
    printf 'ready\n' > "${transport}/provider-ready"
    wait "${CLIENT_PID}" || fail "${phase}: controller assertions failed"
    CLIENT_PID=""
    wait "${PID}" || fail "${phase}: launcher did not exit successfully"
    PID=""
    [[ -s "${transport}/result.json" ]] || fail "${phase}: controller result missing"
    [[ ! -e "${PI_RUN_HOME}/worktrees/.launch-locks/${WORKSPACE_ID}" ]] || fail "${phase}: lock retained"
    remaining="$(docker ps -aq --filter "id=${id}")" || fail 'Cannot verify Worker cleanup'
    [[ -z "${remaining}" ]] || fail "${phase}: Worker container retained"
    remaining="$(docker ps -aq --filter "label=pi-run.worker-roundtrip=${TOKEN}")" || fail 'Cannot verify controller cleanup'
    [[ -z "${remaining}" ]] || fail "${phase}: controller container retained"
}
run_phase launch
REFERENCE="$(jq -er '.identity.reference' "${TMP}/launch/result.json")"
"${CLI}" worker inspect "${REFERENCE}" --json > "${TMP}/inspect-first.json"
jq -e --arg role "$(< "${TMP}/role-hash")" --slurpfile first "${TMP}/launch/result.json" '
    .resumable and .transcriptSaved and .configurationChanged == false and .runtimeMatches and
    .roleHash == $role and .sessionId == $first[0].identity.sessionId and
    .sessionFile == ($first[0].identity.sessionFile | split("/")[-1])
' "${TMP}/inspect-first.json" >/dev/null || fail 'Saved binding is not exactly resumable'
# The original caller-owned Role input is not the binding's immutable Role copy.
printf 'WORKER_ROUNDTRIP_ROLE_CHANGED\n' > "${TMP}/role.txt"
run_phase resume "${REFERENCE}"
"${CLI}" worker inspect "${REFERENCE}" --json > "${TMP}/inspect-final.json"
cmp "${TMP}/inspect-first.json" "${TMP}/inspect-final.json" || fail 'Resume changed binding identity/readiness'
[[ "$(find "${PI_RUN_HOME}/profiles/default/sessions/${WORKSPACE_ID}" -maxdepth 1 -name '*.jsonl' | wc -l)" == 1 ]] \
    || fail 'Resume created another conversation'
jq -se '
    ([.[] | select(.type == "request") | .prompt] == ["first","second","block","after-abort","resumed"]) and
    ([.[] | select(.type == "cancelled" and .prompt == "block")] | length == 1) and
    all(.[]; .type != "error")
' "${PI_RUN_HOME}/profiles/default/logs/worker-roundtrip-provider.jsonl" >/dev/null \
    || fail 'Provider requests/cancellation differed; queued work must not run'
BASH
