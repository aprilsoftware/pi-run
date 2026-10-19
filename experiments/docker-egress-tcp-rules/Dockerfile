# SPDX-License-Identifier: MIT

FROM debian:trixie-slim AS sidecar
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iproute2 iptables jq squid squidclient \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/pi-run-egress-rules
RUN chmod 0755 /usr/local/bin/pi-run-egress-rules
ENTRYPOINT ["/usr/local/bin/pi-run-egress-rules"]

FROM debian:trixie-slim AS workload
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iproute2 libcap2-bin netcat-openbsd socat \
    && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
