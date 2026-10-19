# SPDX-License-Identifier: MIT

FROM debian:trixie-slim AS sidecar
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates iptables squid squidclient \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/pi-run-egress-entrypoint
RUN chmod 0755 /usr/local/bin/pi-run-egress-entrypoint
ENTRYPOINT ["/usr/local/bin/pi-run-egress-entrypoint"]

FROM debian:trixie-slim AS workload
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        busybox ca-certificates curl dnsutils iproute2 libcap2-bin netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
