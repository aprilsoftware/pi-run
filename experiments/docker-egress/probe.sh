#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

usage() {
    echo "Usage: experiments/docker-egress/probe.sh --execute"
}

[[ $# -eq 1 && "$1" == --execute ]] || {
    usage >&2
    exit 2
}
command -v docker >/dev/null 2>&1 || {
    echo "docker-egress-probe: required command unavailable: docker" >&2
    exit 1
}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX="$(date +%s)-$$"
SIDECAR="pirun-egress-${SUFFIX}"
WORKLOAD="pirun-workload-${SUFFIX}"
TARGET="pirun-private-${SUFFIX}"
PREFIX="${PI_RUN_EGRESS_IMAGE_PREFIX:-pi-run-egress-probe}"
SIDECAR_IMAGE="${PREFIX}:sidecar"
WORKLOAD_IMAGE="${PREFIX}:workload"

cleanup() {
    docker rm -f "${WORKLOAD}" "${SIDECAR}" "${TARGET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
    echo "docker-egress-probe: FAIL: $*" >&2
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

echo "Building disposable egress images..."
docker build --target sidecar -t "${SIDECAR_IMAGE}" -f "${DIR}/Dockerfile" "${DIR}" >/dev/null
docker build --target workload -t "${WORKLOAD_IMAGE}" -f "${DIR}/Dockerfile" "${DIR}" >/dev/null

docker run -d --name "${TARGET}" --entrypoint busybox \
    "${WORKLOAD_IMAGE}" httpd -f -p 8080 >/dev/null
TARGET_IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${TARGET}")"
[[ -n "${TARGET_IP}" ]] || fail "private target has no address"

docker run -d --name "${SIDECAR}" \
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
    --security-opt no-new-privileges=true \
    "${WORKLOAD_IMAGE}" >/dev/null

docker exec "${WORKLOAD}" sh -c '! capsh --has-p=cap_net_admin 2>/dev/null' \
    || fail "workload retained NET_ADMIN"
docker exec "${WORKLOAD}" test ! -e /policy \
    || fail "workload can see sidecar policy"

docker exec \
    -e HTTPS_PROXY=http://127.0.0.1:3128 \
    -e https_proxy=http://127.0.0.1:3128 \
    "${WORKLOAD}" curl -fsS --max-time 15 https://example.com/ >/dev/null \
    || fail "allowed HTTPS hostname failed"
echo "PASS allowed: example.com:443"

expect_blocked "unlisted hostname" docker exec \
    -e HTTPS_PROXY=http://127.0.0.1:3128 "${WORKLOAD}" \
    curl -fsS --max-time 5 https://example.org/
expect_blocked "IP literal through proxy" docker exec \
    -e HTTPS_PROXY=http://127.0.0.1:3128 "${WORKLOAD}" \
    curl -kfsS --max-time 5 https://1.1.1.1/
expect_blocked "direct public IP" docker exec "${WORKLOAD}" \
    curl -kfsS --noproxy '*' --max-time 5 https://1.1.1.1/
expect_blocked "private container address" docker exec "${WORKLOAD}" \
    curl -fsS --noproxy '*' --max-time 5 "http://${TARGET_IP}:8080/"
expect_blocked "alternate DNS" docker exec "${WORKLOAD}" \
    dig +time=2 +tries=1 @1.1.1 example.com
expect_blocked "direct IPv6" docker exec "${WORKLOAD}" \
    nc -6 -z -w 3 2606:4700:4700::1111 443
expect_blocked "non-proxy TCP" docker exec "${WORKLOAD}" \
    nc -z -w 3 1.1.1.1 443

docker kill "${SIDECAR}" >/dev/null
[[ "$(docker inspect -f '{{.State.Running}}' "${WORKLOAD}")" == true ]] \
    || fail "workload stopped with sidecar"
expect_blocked "proxy termination" docker exec \
    -e HTTPS_PROXY=http://127.0.0.1:3128 "${WORKLOAD}" \
    curl -fsS --max-time 5 https://example.com/

echo "docker-egress-probe: PASS"
