#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail
[[ $# -eq 1 && "$1" == --execute ]] || {
    echo "Usage: experiments/docker-egress-tcp-rules/probe.sh --execute" >&2
    exit 2
}
command -v docker >/dev/null 2>&1 || { echo "docker-egress-tcp-rules: docker unavailable" >&2; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUFFIX="$(date +%s)-$$"; NETWORK="pirun-rules-${SUFFIX}"
SIDECAR="pirun-rules-sidecar-${SUFFIX}"; WORKLOAD="pirun-rules-workload-${SUFFIX}"
TARGET="pirun-rules-target-${SUFFIX}"; ANY_TARGET="pirun-rules-any-${SUFFIX}"
DENIED_TARGET="pirun-rules-denied-${SUFFIX}"; WORKLOAD_UID=2000
PREFIX="${PI_RUN_EGRESS_RULES_IMAGE_PREFIX:-pi-run-egress-rules-probe}"
SIDECAR_IMAGE="${PREFIX}:sidecar"; WORKLOAD_IMAGE="${PREFIX}:workload"; TMP="$(mktemp -d)"

cleanup() {
    docker rm -f "${WORKLOAD}" "${SIDECAR}" "${TARGET}" "${ANY_TARGET}" \
        "${DENIED_TARGET}" >/dev/null 2>&1 || true
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
    rm -rf "${TMP}"
}
trap cleanup EXIT
fail() {
    echo "docker-egress-tcp-rules: FAIL: $*" >&2
    docker logs "${SIDECAR}" 2>&1 | tail -40 >&2 || true
    exit 1
}
expect_echo() {
    local label="$1" response
    shift
    response="$(printf probe | "$@" 2>/dev/null)" || fail "${label} failed"
    [[ "${response}" == probe ]] || fail "${label} returned unexpected data"
    echo "PASS allowed: ${label}"
}
expect_blocked() {
    local label="$1" response
    shift; set +e; response="$(printf probe | "$@" 2>/dev/null)"; set -e
    [[ "${response}" != probe ]] || fail "${label} unexpectedly succeeded"
    echo "PASS blocked: ${label}"
}

echo "Building disposable generalized-egress images..."
docker build --target sidecar -t "${SIDECAR_IMAGE}" -f "${DIR}/Dockerfile" "${DIR}" >/dev/null
docker build --target workload -t "${WORKLOAD_IMAGE}" -f "${DIR}/Dockerfile" "${DIR}" >/dev/null
docker network create "${NETWORK}" >/dev/null
start_target() {
    local name="$1" alias; shift
    local -a aliases=()
    for alias in "$@"; do aliases+=(--network-alias "${alias}"); done
    docker run -d --name "${name}" --network "${NETWORK}" "${aliases[@]}" \
        "${WORKLOAD_IMAGE}" sh -c '
            for port in 2222 2223 5432 8080 8081 9000 9001; do
                socat TCP-LISTEN:${port},reuseaddr,fork EXEC:/bin/cat &
            done
            socat UDP4-RECVFROM:9999,reuseaddr,fork EXEC:/bin/cat & wait
        ' >/dev/null
}
start_target "${TARGET}" exact.rules.test sub.wild.rules.test
start_target "${ANY_TARGET}" any.rules.test
start_target "${DENIED_TARGET}" denied.rules.test
TARGET_IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${TARGET}")"
ANY_TARGET_IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${ANY_TARGET}")"
DENIED_TARGET_IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${DENIED_TARGET}")"
[[ -n "${TARGET_IP}" && -n "${ANY_TARGET_IP}" && -n "${DENIED_TARGET_IP}" ]] \
    || fail "a disposable target has no address"
for container in "${TARGET}" "${ANY_TARGET}" "${DENIED_TARGET}"; do
    for _ in $(seq 1 30); do
        docker exec "${container}" nc -z 127.0.0.1 2222 >/dev/null 2>&1 && break
        sleep 0.1
    done
    docker exec "${container}" nc -z 127.0.0.1 2222 >/dev/null 2>&1 \
        || fail "disposable target did not become ready"
done

jq -n --arg target "${TARGET_IP}/32" --arg any "${ANY_TARGET_IP}/32" '{
 schemaVersion: 1, rules: [
  {host: "exact.rules.test", tcpPorts: [2222]},
  {domain: "wild.rules.test", tcpPorts: [8080]},
  {cidr: $target, tcpPorts: [5432]}, {cidr: $any}
 ]
}' > "${TMP}/rules.json"
chmod 0600 "${TMP}/rules.json"
for invalid_policy in \
    '{"schemaVersion":1,"rules":[]}' \
    '{"schemaVersion":1,"rules":[{"host":"one.test","domain":"two.test"}]}' \
    '{"schemaVersion":1,"rules":[{"host":"one.test","tcpPorts":[0]}]}' \
    '{"schemaVersion":1,"rules":[{"cidr":"10.0.0.0/99"}]}'; do
    printf '%s\n' "${invalid_policy}" > "${TMP}/invalid.json"
    if docker run --rm --network "${NETWORK}" --cap-add NET_ADMIN \
        --env "PI_RUN_WORKLOAD_UID=${WORKLOAD_UID}" \
        --mount "type=bind,src=${TMP}/invalid.json,dst=/policy/rules.json,readonly" \
        "${SIDECAR_IMAGE}" >/dev/null 2>&1; then
        fail "sidecar accepted an invalid rule policy"
    fi
done
echo "PASS blocked: invalid rule policies"

docker run -d --name "${SIDECAR}" --network "${NETWORK}" \
    --env "PI_RUN_WORKLOAD_UID=${WORKLOAD_UID}" --cap-add NET_ADMIN \
    --ulimit nofile=4096:4096 --security-opt no-new-privileges=true \
    --mount "type=bind,src=${TMP}/rules.json,dst=/policy/rules.json,readonly" \
    "${SIDECAR_IMAGE}" >/dev/null
for _ in $(seq 1 50); do
    docker exec "${SIDECAR}" test -f /tmp/pi-run-egress-ready >/dev/null 2>&1 && break
    sleep 0.2
done
docker exec "${SIDECAR}" test -f /tmp/pi-run-egress-ready >/dev/null 2>&1 \
    || fail "sidecar did not become ready"
docker run -d --name "${WORKLOAD}" --network "container:${SIDECAR}" \
    --user "${WORKLOAD_UID}:${WORKLOAD_UID}" --cap-drop ALL \
    --security-opt no-new-privileges=true "${WORKLOAD_IMAGE}" >/dev/null
docker exec "${WORKLOAD}" sh -c '! capsh --has-p=cap_net_admin 2>/dev/null' \
    || fail "workload retained NET_ADMIN"
docker exec "${WORKLOAD}" test ! -e /policy || fail "workload can see sidecar policy"

PROXY=(docker exec -i "${WORKLOAD}" nc -w 3 -X connect -x 127.0.0.1:3128)
DIRECT=(docker exec -i "${WORKLOAD}" nc -w 3)
expect_echo "exact host TCP/2222" "${PROXY[@]}" exact.rules.test 2222
expect_echo "domain suffix TCP/8080" "${PROXY[@]}" sub.wild.rules.test 8080
expect_echo "CIDR selected TCP/5432" "${DIRECT[@]}" "${TARGET_IP}" 5432
expect_echo "CIDR all TCP/9000" "${DIRECT[@]}" "${ANY_TARGET_IP}" 9000
expect_echo "CIDR all TCP/9001" "${DIRECT[@]}" "${ANY_TARGET_IP}" 9001
expect_blocked "exact host adjacent port" "${PROXY[@]}" exact.rules.test 2223
expect_blocked "domain suffix adjacent port" "${PROXY[@]}" sub.wild.rules.test 8081
expect_blocked "unlisted hostname" "${PROXY[@]}" denied.rules.test 2222
expect_blocked "IP literal through proxy" "${PROXY[@]}" "${TARGET_IP}" 2222
expect_blocked "host rule direct bypass" "${DIRECT[@]}" "${TARGET_IP}" 2222
expect_blocked "CIDR adjacent address" "${DIRECT[@]}" "${DENIED_TARGET_IP}" 5432
expect_blocked "UDP inside allowed CIDR" docker exec -i "${WORKLOAD}" nc -u -w 2 "${TARGET_IP}" 9999

docker kill "${SIDECAR}" >/dev/null
[[ "$(docker inspect -f '{{.State.Running}}' "${WORKLOAD}")" == true ]] \
    || fail "workload stopped with sidecar"
expect_blocked "sidecar termination bypass" "${DIRECT[@]}" "${DENIED_TARGET_IP}" 5432
echo "docker-egress-tcp-rules: PASS"
