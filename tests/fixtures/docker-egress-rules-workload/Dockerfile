# SPDX-License-Identifier: MIT

FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iproute2 libcap2-bin netcat-openbsd socat \
    && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
