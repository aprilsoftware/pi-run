#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

POLICY=/policy/allowed-hosts.txt
CONFIG=/tmp/pi-run-squid.conf
READY=/tmp/pi-run-egress-ready

fail() {
    echo "pi-run-egress: $*" >&2
    exit 1
}

WORKLOAD_UID="${PI_RUN_WORKLOAD_UID:-}"
[[ "${WORKLOAD_UID}" =~ ^(0|[1-9][0-9]*)$ ]] \
    || fail "invalid workload UID"
PROXY_UID="$(id -u proxy)"
[[ "${WORKLOAD_UID}" != "${PROXY_UID}" ]] \
    || fail "workload UID collides with proxy UID: ${PROXY_UID}"

[[ -f "${POLICY}" && ! -L "${POLICY}" ]] || fail "missing regular hostname policy"
while IFS= read -r host || [[ -n "${host}" ]]; do
    [[ "${host}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "${host}" == *.* ]] \
        || fail "invalid exact hostname in policy"
done < "${POLICY}"
[[ -s "${POLICY}" ]] || fail "hostname policy is empty"

cat > "${CONFIG}" <<'EOF'
http_port 127.0.0.1:3128
max_filedescriptors 4096
pinger_enable off
acl CONNECT method CONNECT
acl SSL_ports port 443
acl allowed_hosts dstdomain -n "/policy/allowed-hosts.txt"
http_access deny !CONNECT
http_access deny CONNECT !SSL_ports
http_access allow CONNECT allowed_hosts
http_access deny all
cache deny all
access_log stdio:/tmp/pi-run-squid-access.log
cache_log /tmp/pi-run-squid-cache.log
cache_store_log none
pid_filename /tmp/pi-run-squid.pid
visible_hostname pi-run-egress
EOF

iptables -w -F OUTPUT
iptables -w -P OUTPUT DROP
iptables -w -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -w -A OUTPUT -o lo -p udp -j ACCEPT
iptables -w -A OUTPUT -o lo -p tcp --dport 3128 -j ACCEPT
iptables -w -A OUTPUT -m owner --uid-owner "${PROXY_UID}" -p udp --dport 53 -j ACCEPT
iptables -w -A OUTPUT -m owner --uid-owner "${PROXY_UID}" -p tcp --dport 53 -j ACCEPT
for subnet in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4; do
    iptables -w -A OUTPUT -m owner --uid-owner "${PROXY_UID}" -d "${subnet}" -j REJECT
done
iptables -w -A OUTPUT -m owner --uid-owner "${PROXY_UID}" -p tcp --dport 443 -j ACCEPT

ip6tables -w -F OUTPUT
ip6tables -w -P OUTPUT DROP
ip6tables -w -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -w -A OUTPUT -o lo -p udp -j ACCEPT
ip6tables -w -A OUTPUT -o lo -p tcp --dport 3128 -j ACCEPT
ip6tables -w -A OUTPUT -m owner --uid-owner "${PROXY_UID}" -p udp --dport 53 -j ACCEPT
ip6tables -w -A OUTPUT -m owner --uid-owner "${PROXY_UID}" -p tcp --dport 53 -j ACCEPT
for subnet in ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8; do
    ip6tables -w -A OUTPUT -m owner --uid-owner "${PROXY_UID}" -d "${subnet}" -j REJECT
done
ip6tables -w -A OUTPUT -m owner --uid-owner "${PROXY_UID}" -p tcp --dport 443 -j ACCEPT

install -o proxy -g proxy -m 0640 /dev/null /tmp/pi-run-squid-access.log
install -o proxy -g proxy -m 0640 /dev/null /tmp/pi-run-squid-cache.log
squid -k parse -f "${CONFIG}" >/dev/null
tail -n +1 -F /tmp/pi-run-squid-access.log /tmp/pi-run-squid-cache.log &
TAIL_PID=$!
squid -N -f "${CONFIG}" -d 1 &
SQUID_PID=$!
trap 'kill "${SQUID_PID}" "${TAIL_PID}" 2>/dev/null || true; wait "${SQUID_PID}" "${TAIL_PID}" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
    if squidclient -h 127.0.0.1 -p 3128 http://invalid.invalid/ >/dev/null 2>&1; then
        touch "${READY}"
        wait "${SQUID_PID}"
        exit $?
    fi
    sleep 0.2
done
fail "proxy did not become ready"
