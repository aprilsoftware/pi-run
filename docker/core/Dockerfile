# SPDX-License-Identifier: MIT

ARG RESTIC_VERSION=0.19.1
ARG RESTIC_LINUX_AMD64_SHA256=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c

FROM debian:trixie-slim AS restic-downloader
ARG RESTIC_VERSION
ARG RESTIC_LINUX_AMD64_SHA256
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bzip2 \
        ca-certificates \
        curl \
    && curl -fsSLo /tmp/restic.bz2 \
        "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2" \
    && echo "${RESTIC_LINUX_AMD64_SHA256}  /tmp/restic.bz2" | sha256sum -c - \
    && bunzip2 /tmp/restic.bz2 \
    && install -D -m 0755 /tmp/restic /out/restic \
    && rm -rf /var/lib/apt/lists/* /tmp/restic

FROM node:24-trixie-slim

ARG PI_VERSION=1.5.2
ARG PI_WEB_ACCESS_VERSION=0.47.0
ARG PI_OKF_VERSION=0.4.0

ENV DEBIAN_FRONTEND=noninteractive

# Pi-Run's core contains only launch-contract and maintained workflow
# dependencies. Profile-owned Dockerfiles add development toolchains.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        fd-find \
        git \
        gosu \
        jq \
        netcat-openbsd \
        openssh-client \
        openssl \
        passwd \
        ripgrep \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

RUN corepack enable

COPY --from=restic-downloader /out/restic /usr/local/bin/restic
COPY licenses/restic-LICENSE /usr/local/share/licenses/restic/LICENSE
COPY licenses/pi-run-LICENSE /usr/local/share/licenses/pi-run/LICENSE

RUN npm install -g \
        "@earendil-works/pi-coding-agent@${PI_VERSION}" \
        "pi-web-access@${PI_WEB_ACCESS_VERSION}" \
        "pi-okf@${PI_OKF_VERSION}"

COPY extensions/cache/cache-policy-agent.ts /usr/local/lib/node_modules/pi-run-extensions/cache/
COPY extensions/plan/plan-agent.ts /usr/local/lib/node_modules/pi-run-extensions/plan/
COPY extensions/guard/guard-runtime-contract.ts /usr/local/lib/node_modules/pi-run-extensions/guard/
COPY extensions/guard/guard-runtime.ts /usr/local/lib/node_modules/pi-run-extensions/guard/
COPY extensions/guard/guard-viewer.ts /usr/local/lib/node_modules/pi-run-extensions/guard/
COPY extensions/guard/guard-journal.ts /usr/local/lib/node_modules/pi-run-extensions/guard/
COPY extensions/guard/guard-evidence.ts /usr/local/lib/node_modules/pi-run-extensions/guard/
COPY extensions/guard/guard-reviewer-agent.ts /usr/local/lib/node_modules/pi-run-extensions/guard/
COPY extensions/knowledge/knowledge-agent.ts /usr/local/lib/node_modules/pi-run-extensions/knowledge/
COPY extensions/guardian/guardian-log-safety.ts /usr/local/lib/node_modules/pi-run-extensions/guardian/
COPY extensions/guardian/guardian-log-viewer.ts /usr/local/lib/node_modules/pi-run-extensions/guardian/
COPY extensions/guardian/guardian-review-trace.ts /usr/local/lib/node_modules/pi-run-extensions/guardian/
COPY extensions/guardian/guardian-reviewer.ts /usr/local/lib/node_modules/pi-run-extensions/guardian/
COPY extensions/guardian/guardian-agent.ts /usr/local/lib/node_modules/pi-run-extensions/guardian/
COPY extensions/caf/caf-log-viewer.ts /usr/local/lib/node_modules/pi-run-extensions/caf/
COPY extensions/caf/caf-protocol.ts /usr/local/lib/node_modules/pi-run-extensions/caf/
COPY extensions/caf/caf-agent.ts /usr/local/lib/node_modules/pi-run-extensions/caf/
COPY extensions/snapshot/snapshot-agent.ts /usr/local/lib/node_modules/pi-run-extensions/snapshot/
COPY extensions/todo/todo-agent.ts /usr/local/lib/node_modules/pi-run-extensions/todo/
COPY extensions/title/title-agent.ts /usr/local/lib/node_modules/pi-run-extensions/title/
COPY skills/ /usr/local/share/pi-run/skills/
RUN test -f /usr/local/share/pi-run/skills/pi-run/SKILL.md \
    && test -f /usr/local/share/pi-run/skills/profile-management/SKILL.md \
    && chmod -R a-w /usr/local/share/pi-run/skills

ENV PI_CODING_AGENT_DIR=/profile
ENV PI_TELEMETRY=0
ENV PI_SKIP_VERSION_CHECK=1

COPY entrypoint.sh ssh-credentials /usr/local/bin/
COPY java-trust-store.sh /usr/local/bin/pi-run-java-trust-store
COPY PiRunJavaTrustStore.java /usr/local/lib/pi-run/PiRunJavaTrustStore.java
COPY network-policy-resolver.mjs /usr/local/bin/pi-run-network-policy-resolver
RUN chmod 0755 \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/pi-run-java-trust-store \
        /usr/local/bin/ssh-credentials \
        /usr/local/bin/pi-run-network-policy-resolver

WORKDIR /workspace

RUN set -eux; \
    bash --version; \
    node --version; \
    npm --version; \
    git --version; \
    ssh -V; \
    command -v nc; \
    openssl version; \
    jq --version; \
    fd --version; \
    fdfind --version; \
    rg --version; \
    restic version; \
    pi --version; \
    ! command -v java; \
    ! command -v javac; \
    ! command -v python3; \
    ! command -v gcc; \
    ! command -v rustc; \
    ! command -v flutter; \
    ! command -v ansible; \
    ! command -v kubectl; \
    ! command -v psql

USER root

ENTRYPOINT ["/usr/local/bin/entrypoint.sh", "pi"]
