# SPDX-License-Identifier: MIT

FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        iproute2 \
        iptables \
        jq \
        squid \
        squidclient \
    && rm -rf /var/lib/apt/lists/*

COPY licenses/pi-run-LICENSE /usr/local/share/licenses/pi-run/LICENSE
COPY egress/entrypoint.sh /usr/local/bin/pi-run-egress-entrypoint
RUN chmod 0755 /usr/local/bin/pi-run-egress-entrypoint

ENTRYPOINT ["/usr/local/bin/pi-run-egress-entrypoint"]
