#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="${ROOT}/experiments/docker-egress/probe.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "docker-egress-probe-test: $*" >&2
    exit 1
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
case "$1" in
    build)
        [[ "${TEST_BUILD_FAIL:-0}" == 0 ]]
        ;;
    run)
        echo fake-container-id
        ;;
    inspect)
        case "$*" in
            *NetworkSettings.Networks*) echo 172.18.0.99 ;;
            *State.Running*) echo true ;;
            *) exit 2 ;;
        esac
        ;;
    exec)
        case "$*" in
            *'/tmp/pi-run-egress-ready'*) exit 0 ;;
            *'example.org'*) exit 1 ;;
            *' curl '*'1.1.1.1'*) exit 1 ;;
            *'172.18.0.99'*) exit 1 ;;
            *' dig '*|*' nc '*) exit 1 ;;
            *'example.com'*) [[ ! -e "${SIDECAR_KILLED:?}" ]] ;;
            *) exit 0 ;;
        esac
        ;;
    kill)
        : > "${SIDECAR_KILLED:?}"
        ;;
    rm|logs) ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

export DOCKER_LOG="${TMP}/docker.log"
export SIDECAR_KILLED="${TMP}/sidecar-killed"
output="$(PATH="${TMP}/fake-bin:${PATH}" "$PROBE" --execute)"
[[ "$output" == *'docker-egress-probe: PASS'* ]] || fail "successful probe did not pass"
grep -F 'build --target sidecar' "$DOCKER_LOG" >/dev/null \
    || fail "sidecar image was not built"
grep -F -- '--cap-add NET_ADMIN' "$DOCKER_LOG" >/dev/null \
    || fail "sidecar did not receive NET_ADMIN"
grep -F -- '--ulimit nofile=4096:4096' "$DOCKER_LOG" >/dev/null \
    || fail "sidecar file-descriptor limit was not bounded"
grep -Fx 'max_filedescriptors 4096' \
    "${ROOT}/experiments/docker-egress/entrypoint.sh" >/dev/null \
    || fail "Squid file-descriptor limit was not bounded"
grep -Fx 'pinger_enable off' \
    "${ROOT}/experiments/docker-egress/entrypoint.sh" >/dev/null \
    || fail "Squid ICMP helper was not disabled"
grep -F 'busybox ca-certificates curl' \
    "${ROOT}/experiments/docker-egress/Dockerfile" >/dev/null \
    || fail "workload image has no HTTPS trust store"
grep -F 'access_log stdio:/tmp/pi-run-squid-access.log' \
    "${ROOT}/experiments/docker-egress/entrypoint.sh" >/dev/null \
    || fail "Squid access log is not proxy-writable"
[[ "$(grep -c '^install -o proxy -g proxy -m 0640 /dev/null /tmp/pi-run-squid-.*\.log$' \
    "${ROOT}/experiments/docker-egress/entrypoint.sh")" -eq 2 ]] \
    || fail "Squid log files are not initialized separately"
grep -F 'tail -n +1 -F /tmp/pi-run-squid-access.log' \
    "${ROOT}/experiments/docker-egress/entrypoint.sh" >/dev/null \
    || fail "Squid logs are not forwarded to Docker logs"
grep -Fx 'iptables -w -A OUTPUT -o lo -p udp -j ACCEPT' \
    "${ROOT}/experiments/docker-egress/entrypoint.sh" >/dev/null \
    || fail "IPv4 loopback UDP was not allowed for proxy IPC"
grep -Fx 'ip6tables -w -A OUTPUT -o lo -p udp -j ACCEPT' \
    "${ROOT}/experiments/docker-egress/entrypoint.sh" >/dev/null \
    || fail "IPv6 loopback UDP was not allowed for proxy IPC"
grep -F 'expect_blocked "alternate DNS"' \
    "${ROOT}/experiments/docker-egress/probe.sh" >/dev/null \
    || fail "external UDP denial is not tested"
grep -F -- 'dst=/policy/allowed-hosts.txt,readonly' "$DOCKER_LOG" >/dev/null \
    || fail "policy was not mounted read-only"
grep -F -- '--network container:pirun-egress-' "$DOCKER_LOG" >/dev/null \
    || fail "workload did not share the sidecar network namespace"
grep -F -- '--cap-drop ALL' "$DOCKER_LOG" >/dev/null \
    || fail "workload capabilities were not dropped"
grep -F 'kill pirun-egress-' "$DOCKER_LOG" >/dev/null \
    || fail "fail-closed termination was not tested"
grep -F 'rm -f pirun-workload-' "$DOCKER_LOG" >/dev/null \
    || fail "containers were not cleaned up"
if grep -F -- '--network host' "$DOCKER_LOG" >/dev/null; then
    fail "probe used host networking"
fi

: > "$DOCKER_LOG"
rm -f "$SIDECAR_KILLED"
set +e
PATH="${TMP}/fake-bin:${PATH}" TEST_BUILD_FAIL=1 "$PROBE" --execute >/dev/null 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail "probe accepted a failed image build"
grep -F 'rm -f pirun-workload-' "$DOCKER_LOG" >/dev/null \
    || fail "failed probe did not attempt cleanup"

set +e
"$PROBE" >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 2 ]] || fail "probe ran without explicit execution approval"

echo "Docker egress probe test passed"
