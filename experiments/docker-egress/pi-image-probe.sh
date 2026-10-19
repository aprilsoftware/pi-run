#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

usage() {
    echo "Usage: experiments/docker-egress/pi-image-probe.sh --execute"
}

[[ $# -eq 1 && "$1" == --execute ]] || {
    usage >&2
    exit 2
}
command -v docker >/dev/null 2>&1 || {
    echo "docker-egress-pi-image-probe: required command unavailable: docker" >&2
    exit 1
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="${ROOT}/experiments/docker-egress"
SUFFIX="$(date +%s)-$$"
SIDECAR="pirun-pi-egress-${SUFFIX}"
WORKLOAD="pirun-pi-workload-${SUFFIX}"
SIDECAR_IMAGE="${PI_RUN_EGRESS_IMAGE_PREFIX:-pi-run-egress-probe}:sidecar"
PI_IMAGE="${PI_RUN_EGRESS_PI_IMAGE:-pi-run:egress-pi-test}"
STATE="$(mktemp -d)"
WORKSPACE="${STATE}/workspace"
SELECTED_PROFILE="${STATE}/profiles/selected"
SIBLING_PROFILE="${STATE}/profiles/sibling"
SESSION_ID="pi-egress-probe"

cleanup() {
    docker rm -f "${WORKLOAD}" "${SIDECAR}" >/dev/null 2>&1 || true
    rm -rf "${STATE}"
}
trap cleanup EXIT

fail() {
    echo "docker-egress-pi-image-probe: FAIL: $*" >&2
    docker logs "${WORKLOAD}" 2>&1 | tail -30 >&2 || true
    docker logs "${SIDECAR}" 2>&1 | tail -30 >&2 || true
    exit 1
}

expect_blocked() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "${label} unexpectedly succeeded"
    fi
    echo "PASS blocked: ${label}"
}

mkdir -p "${WORKSPACE}" "${SELECTED_PROFILE}/sessions" "${SIBLING_PROFILE}"
printf 'not mounted\n' > "${SIBLING_PROFILE}/sibling-marker"

if [[ -z "${PI_RUN_EGRESS_PI_IMAGE:-}" ]]; then
    echo "Building current Pi-Run image..."
    docker build -t "${PI_IMAGE}" -f "${ROOT}/docker/Dockerfile" "${ROOT}/docker" >/dev/null
fi
echo "Building disposable egress sidecar..."
docker build --target sidecar -t "${SIDECAR_IMAGE}" -f "${DIR}/Dockerfile" "${DIR}" >/dev/null

docker run -d --name "${SIDECAR}" \
    --env "PI_RUN_WORKLOAD_UID=$(id -u)" \
    --cap-add NET_ADMIN \
    --ulimit nofile=4096:4096 \
    --security-opt no-new-privileges=true \
    --mount "type=bind,src=${DIR}/allowed-hosts.txt,dst=/policy/allowed-hosts.txt,readonly" \
    "${SIDECAR_IMAGE}" >/dev/null

for _ in $(seq 1 50); do
    docker exec "${SIDECAR}" test -f /tmp/pi-run-egress-ready >/dev/null 2>&1 && break
    sleep 0.2
done
docker exec "${SIDECAR}" test -f /tmp/pi-run-egress-ready >/dev/null 2>&1 \
    || fail "sidecar did not become ready"

docker run -d --name "${WORKLOAD}" \
    --network "container:${SIDECAR}" \
    --cap-drop ALL \
    --cap-add CHOWN \
    --cap-add SETUID \
    --cap-add SETGID \
    --cap-add DAC_READ_SEARCH \
    --security-opt no-new-privileges=true \
    --workdir /workspace \
    --mount "type=bind,src=${WORKSPACE},dst=/workspace" \
    --mount "type=bind,src=${SELECTED_PROFILE},dst=/profile" \
    --env "HOST_UID=$(id -u)" \
    --env "HOST_GID=$(id -g)" \
    --env PI_RUN_SKIP_SSH_CONFIG=1 \
    --env PI_RUN_PROFILE=selected \
    --env PI_RUN_PROFILE_DIR=/profile \
    --env PI_CODING_AGENT_DIR=/profile \
    --env "PI_RUN_PROBE_SESSION_ID=${SESSION_ID}" \
    --entrypoint /usr/local/bin/entrypoint.sh \
    "${PI_IMAGE}" bash -ceu '
        test "$(id -u)" = "${HOST_UID}"
        test "$(id -g)" = "${HOST_GID}"
        test "${PWD}" = /workspace
        test ! -e /sibling
        pi --version > /workspace/pi-version.txt
        printf "%s:%s\n" "$(id -u)" "$(id -g)" > /workspace/runtime-identity
        printf "profile writable\n" > /profile/profile-marker
        mkdir -p "/profile/sessions/${PI_RUN_PROBE_SESSION_ID}"
        printf "session writable\n" > "/profile/sessions/${PI_RUN_PROBE_SESSION_ID}/session-marker"
        touch /workspace/entrypoint-ready
        exec sleep infinity
    ' >/dev/null

for _ in $(seq 1 50); do
    [[ -f "${WORKSPACE}/entrypoint-ready" ]] && break
    sleep 0.2
done
[[ -f "${WORKSPACE}/entrypoint-ready" ]] || fail "Pi-Run entrypoint did not become ready"
[[ -s "${WORKSPACE}/pi-version.txt" ]] || fail "pi --version produced no persisted output"
[[ "$(< "${WORKSPACE}/runtime-identity")" == "$(id -u):$(id -g)" ]] \
    || fail "Pi-Run image did not use the host identity"
[[ -f "${SELECTED_PROFILE}/profile-marker" ]] || fail "selected profile was not writable"
[[ -f "${SELECTED_PROFILE}/sessions/${SESSION_ID}/session-marker" ]] \
    || fail "session path was not writable"
[[ -f "${SIBLING_PROFILE}/sibling-marker" ]] || fail "sibling profile fixture changed"

docker exec "${WORKLOAD}" test ! -e /policy \
    || fail "Pi-Run image can see sidecar policy"
docker exec "${WORKLOAD}" test ! -e /sibling \
    || fail "Pi-Run image can see the sibling profile"
docker exec "${WORKLOAD}" python3 -c \
    'value=int(next(line.split()[1] for line in open("/proc/self/status") if line.startswith("CapEff:")),16); assert not value & (1 << 12)' \
    || fail "Pi-Run image retained NET_ADMIN"

docker exec \
    -e HTTPS_PROXY=http://127.0.0.1:3128 \
    -e https_proxy=http://127.0.0.1:3128 \
    "${WORKLOAD}" curl -fsS --max-time 15 https://example.com/ >/dev/null \
    || fail "allowed HTTPS hostname failed"
echo "PASS allowed: example.com:443"

docker exec \
    -e HTTPS_PROXY=http://127.0.0.1:3128 \
    -e NODE_USE_ENV_PROXY=1 \
    "${WORKLOAD}" node --input-type=module -e \
    'const response = await fetch("https://example.com/", {signal: AbortSignal.timeout(15000)}); if (!response.ok) throw new Error(`HTTP ${response.status}`); await response.arrayBuffer();' \
    || fail "allowed Node fetch through HTTPS proxy failed"
echo "PASS allowed: Node fetch through example.com:443"

expect_blocked "unlisted hostname" docker exec \
    -e HTTPS_PROXY=http://127.0.0.1:3128 "${WORKLOAD}" \
    curl -fsS --max-time 5 https://example.org/
expect_blocked "direct public IP" docker exec "${WORKLOAD}" \
    curl -kfsS --noproxy '*' --max-time 5 https://1.1.1.1/

docker kill "${SIDECAR}" >/dev/null
[[ "$(docker inspect -f '{{.State.Running}}' "${WORKLOAD}")" == true ]] \
    || fail "Pi-Run image stopped with sidecar"
expect_blocked "proxy termination" docker exec \
    -e HTTPS_PROXY=http://127.0.0.1:3128 "${WORKLOAD}" \
    curl -fsS --max-time 5 https://example.com/

echo "docker-egress-pi-image-probe: PASS"
