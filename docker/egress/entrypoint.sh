#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

POLICY=/policy/rules.json
CONFIG=/tmp/pi-run-squid.conf
READY=/tmp/pi-run-egress-ready

fail() {
    echo "pi-run-egress-rules: $*" >&2
    exit 1
}

WORKLOAD_UID="${PI_RUN_WORKLOAD_UID:-}"
[[ "${WORKLOAD_UID}" =~ ^(0|[1-9][0-9]*)$ ]] || fail "invalid workload UID"
PROXY_UID="$(id -u proxy)"
[[ "${WORKLOAD_UID}" != "${PROXY_UID}" ]] || fail "workload UID collides with proxy UID"
[[ -f "${POLICY}" && ! -L "${POLICY}" ]] || fail "missing regular rule policy"

jq -e '
    def hostname:
        type == "string" and length <= 253 and
        test("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$") and
        (test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$") | not);
    def ports:
        (has("tcpPorts") | not) or
        ((.tcpPorts | type == "array") and (.tcpPorts | length > 0) and
         ((.tcpPorts | unique | length) == (.tcpPorts | length)) and
         all(.tcpPorts[]; type == "number" and floor == . and . >= 1 and . <= 65535));
    type == "object" and keys == ["rules", "schemaVersion"] and
    .schemaVersion == 1 and (.rules | type == "array") and (.rules | length > 0) and
    all(.rules[];
        type == "object" and
        ((keys - ["cidr", "domain", "host", "tcpPorts"]) | length == 0) and
        ([has("host"), has("domain"), has("cidr")] | map(select(.)) | length == 1) and
        ((has("host") | not) or (.host | hostname)) and
        ((has("domain") | not) or (.domain | hostname)) and
        ((has("cidr") | not) or
            (.cidr | type == "string" and test("^[0-9A-Fa-f:.]+/[0-9]{1,3}$"))) and
        ports)
' "${POLICY}" >/dev/null || fail "invalid rule policy"

cat > "${CONFIG}" <<'EOF'
http_port 127.0.0.1:3128
max_filedescriptors 4096
pinger_enable off
acl CONNECT method CONNECT
http_access deny !CONNECT
EOF

while IFS=$'\t' read -r index kind destination ports; do
    acl="destination_${index}"
    case "${kind}" in
        host) printf 'acl %s dstdomain -n %s\n' "${acl}" "${destination}" >> "${CONFIG}" ;;
        domain) printf 'acl %s dstdomain -n .%s\n' "${acl}" "${destination}" >> "${CONFIG}" ;;
        cidr) printf 'acl %s dst %s\n' "${acl}" "${destination}" >> "${CONFIG}" ;;
        *) fail "invalid normalized rule kind" ;;
    esac
    if [[ "${ports}" == all ]]; then
        printf 'http_access allow CONNECT %s\n' "${acl}" >> "${CONFIG}"
    else
        port_acl="ports_${index}"
        printf 'acl %s port %s\n' "${port_acl}" "${ports//,/ }" >> "${CONFIG}"
        printf 'http_access allow CONNECT %s %s\n' "${acl}" "${port_acl}" >> "${CONFIG}"
    fi
done < <(jq -r '
    .rules | to_entries[] |
    .key as $index | .value as $rule |
    (if $rule.host then "host" elif $rule.domain then "domain" else "cidr" end) as $kind |
    ($rule[$kind]) as $destination |
    (if $rule.tcpPorts then ($rule.tcpPorts | map(tostring) | join(",")) else "all" end) as $ports |
    [$index, $kind, $destination, $ports] | @tsv
' "${POLICY}")

cat >> "${CONFIG}" <<'EOF'
http_access deny all
cache deny all
access_log stdio:/tmp/pi-run-squid-access.log
cache_log /tmp/pi-run-squid-cache.log
cache_store_log none
pid_filename /tmp/pi-run-squid.pid
visible_hostname pi-run-egress-rules
EOF

configure_firewall() {
    local family="$1" command="$2" gateway destination port
    "${command}" -w -F OUTPUT
    "${command}" -w -P OUTPUT DROP
    "${command}" -w -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    "${command}" -w -A OUTPUT -o lo -p udp -j ACCEPT
    "${command}" -w -A OUTPUT -o lo -p tcp --dport 3128 -j ACCEPT
    "${command}" -w -A OUTPUT -m owner --uid-owner "${PROXY_UID}" -p udp --dport 53 -j ACCEPT
    "${command}" -w -A OUTPUT -m owner --uid-owner "${PROXY_UID}" -p tcp --dport 53 -j ACCEPT

    if [[ "${family}" == 4 ]]; then
        for destination in 0.0.0.0/8 127.0.0.0/8 169.254.0.0/16 224.0.0.0/4; do
            "${command}" -w -A OUTPUT -d "${destination}" -j REJECT
        done
        gateway="$(ip -4 route show default | awk 'NR == 1 { print $3 }')"
    else
        for destination in ::/128 ::1/128 fe80::/10 ff00::/8; do
            "${command}" -w -A OUTPUT -d "${destination}" -j REJECT
        done
        gateway="$(ip -6 route show default | awk 'NR == 1 { print $3 }')"
    fi
    [[ -z "${gateway}" ]] || "${command}" -w -A OUTPUT -d "${gateway}" -j REJECT

    while IFS=$'\t' read -r destination ports; do
        if [[ "${family}" == 4 && "${destination}" == *:* ]] ||
           [[ "${family}" == 6 && "${destination}" != *:* ]]; then
            continue
        fi
        if [[ "${ports}" == all ]]; then
            "${command}" -w -A OUTPUT -m owner --uid-owner "${WORKLOAD_UID}" \
                -d "${destination}" -p tcp -j ACCEPT
        else
            IFS=, read -r -a port_list <<< "${ports}"
            for port in "${port_list[@]}"; do
                "${command}" -w -A OUTPUT -m owner --uid-owner "${WORKLOAD_UID}" \
                    -d "${destination}" -p tcp --dport "${port}" -j ACCEPT
            done
        fi
    done < <(jq -r '
        .rules[] | select(.cidr) |
        [.cidr, (if .tcpPorts then (.tcpPorts | map(tostring) | join(",")) else "all" end)] |
        @tsv
    ' "${POLICY}")

    "${command}" -w -A OUTPUT -m owner --uid-owner "${PROXY_UID}" -p tcp -j ACCEPT
}

configure_firewall 4 iptables
configure_firewall 6 ip6tables

install -o proxy -g proxy -m 0640 /dev/null /tmp/pi-run-squid-access.log
install -o proxy -g proxy -m 0640 /dev/null /tmp/pi-run-squid-cache.log
squid -k parse -f "${CONFIG}" >/dev/null
squid -N -f "${CONFIG}" -d 1 &
SQUID_PID=$!
trap 'kill "${SQUID_PID}" 2>/dev/null || true; wait "${SQUID_PID}" 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
    if squidclient -h 127.0.0.1 -p 3128 http://invalid.invalid/ >/dev/null 2>&1; then
        touch "${READY}"
        wait "${SQUID_PID}"
        exit $?
    fi
    sleep 0.2
done
fail "proxy did not become ready"
