# SPDX-License-Identifier: MIT

FROM node:24-trixie

ARG PI_VERSION=1.1.0
ARG PI_WEB_ACCESS_VERSION=0.37.0
ARG PI_OKF_VERSION=0.4.0
ARG RESTIC_VERSION=0.19.1
ARG RESTIC_LINUX_AMD64_SHA256=f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c

ARG FLUTTER_VERSION=3.47.2
ARG KUBECTL_VERSION=1.37.0
ARG HELM_VERSION=4.2.0
ARG KUSTOMIZE_VERSION=5.8.1
ARG YQ_VERSION=4.53.3

ENV DEBIAN_FRONTEND=noninteractive

#
# General development workstation
#
# The image intentionally contains a broad set of development and
# operations tools.
#
# Tools do not grant authority:
# credentials, mounts, kubeconfigs, SSH identities, API keys, etc.
# are provided separately by profiles/runtime configuration.
#

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        \
        # General shell/development tools
        bash \
        bash-completion \
        ca-certificates \
        curl \
        wget \
        git \
        jq \
        less \
        file \
        patch \
        procps \
        rsync \
        openssh-client \
        openssl \
        ripgrep \
        tree \
        zip \
        unzip \
        bzip2 \
        xz-utils \
        tar \
        \
        # Developer utility belt
        libxml2-utils \
        xmlstarlet \
        shellcheck \
        dos2unix \
        lsof \
        strace \
        socat \
        bc \
        gettext-base \
        \
        # Networking / diagnostics
        dnsutils \
        iproute2 \
        iputils-ping \
        netcat-openbsd \
        traceroute \
        \
        # Infrastructure automation
        ansible \
        \
        # Java
        openjdk-21-jdk-headless \
        maven \
        \
        # Python
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        pipx \
        \
        # C / C++
        build-essential \
        clang \
        clang-format \
        cmake \
        ninja-build \
        gdb \
        pkg-config \
        \
        # Flutter Linux development dependencies
        libgtk-3-dev \
        libglu1-mesa \
        \
        # Useful service clients
        postgresql-client \
        redis-tools \
        default-mysql-client \
        sqlite3 \
    && rm -rf /var/lib/apt/lists/*

#
# JavaScript / TypeScript
#
# Node and npm come from node:24-trixie.
# Corepack provides project-controlled pnpm/yarn versions.
#

RUN corepack enable

#
# Flutter / Dart.
#
# Flutter is installed globally but owned by the unprivileged node user
# because Flutter maintains SDK cache/artifact state under its installation.
#

RUN curl -fsSLo /tmp/flutter.tar.xz \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    && tar -xJf /tmp/flutter.tar.xz -C /opt \
    && rm -f /tmp/flutter.tar.xz \
    && chown -R node:node /opt/flutter

#
# kubectl
#

RUN curl -fsSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod 0755 /usr/local/bin/kubectl

#
# Helm
#

RUN curl -fsSLo /tmp/helm.tar.gz \
        "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
    && tar -xzf /tmp/helm.tar.gz -C /tmp \
    && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tar.gz /tmp/linux-amd64

#
# Standalone Kustomize.
#
# kubectl already provides `kubectl kustomize`, but the standalone
# binary is useful for repositories/scripts that explicitly expect it.
#

RUN curl -fsSLo /tmp/kustomize.tar.gz \
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
    && tar -xzf /tmp/kustomize.tar.gz -C /tmp \
    && install -m 0755 /tmp/kustomize /usr/local/bin/kustomize \
    && rm -f /tmp/kustomize.tar.gz /tmp/kustomize

#
# mikefarah/yq.
#
# We install this explicitly instead of Debian's package so Pi gets
# the commonly expected Go yq CLI and syntax.
#

RUN curl -fsSLo /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
    && chmod 0755 /usr/local/bin/yq

#
# Restic.
#
# Snapshot commands are implemented separately. Bundling the pinned binary here
# ensures they will not depend on a host Restic installation.
#

RUN curl -fsSLo /tmp/restic.bz2 \
        "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2" \
    && echo "${RESTIC_LINUX_AMD64_SHA256}  /tmp/restic.bz2" | sha256sum -c - \
    && bunzip2 /tmp/restic.bz2 \
    && install -m 0755 /tmp/restic /usr/local/bin/restic \
    && rm -f /tmp/restic

COPY licenses/restic-LICENSE /usr/local/share/licenses/restic/LICENSE
COPY licenses/pi-run-LICENSE /usr/local/share/licenses/pi-run/LICENSE

#
# Pi + baseline extensions.
#
# pi-web-access provides web/search access.
#

RUN npm install -g \
        "@earendil-works/pi-coding-agent@${PI_VERSION}" \
        "pi-web-access@${PI_WEB_ACCESS_VERSION}" \
        "pi-okf@${PI_OKF_VERSION}"

# Copy Guardian and the core Pi-Run skills into the versioned runtime image.
COPY extensions/plan-agent.ts /usr/local/lib/node_modules/plan-agent/
COPY extensions/guard-runtime.ts /usr/local/lib/node_modules/guardian-agent/
COPY extensions/guard-viewer.ts /usr/local/lib/node_modules/guardian-agent/
COPY extensions/guard-journal.ts /usr/local/lib/node_modules/guardian-agent/
COPY extensions/guard-evidence.ts /usr/local/lib/node_modules/guardian-agent/
COPY extensions/guard-reviewer-agent.ts /usr/local/lib/node_modules/guardian-agent/
COPY extensions/guardian-agent.ts /usr/local/lib/node_modules/guardian-agent/
COPY extensions/caf-agent.ts /usr/local/lib/node_modules/guardian-agent/
COPY extensions/snapshot-agent.ts /usr/local/lib/node_modules/snapshot-agent/
COPY skills/ /usr/local/share/pi-run/skills/
RUN test -f /usr/local/share/pi-run/skills/pi-run/SKILL.md \
    && test -f /usr/local/share/pi-run/skills/profile-management/SKILL.md \
    && chmod -R a-w /usr/local/share/pi-run/skills

ENV PATH="/opt/flutter/bin:/home/node/.local/bin:${PATH}"

#
# The selected profile is mounted directly by pi-run and is the authoritative
# Pi configuration and session directory.
#

ENV PI_CODING_AGENT_DIR=/profile
ENV PI_TELEMETRY=0
ENV PI_SKIP_VERSION_CHECK=1

# Install gosu for privilege dropping
RUN apt-get update && \
    apt-get install -y --no-install-recommends gosu && \
    rm -rf /var/lib/apt/lists/*

# Install the dynamic UID/GID entrypoint and profile SSH configuration helper.
COPY entrypoint.sh ssh-credentials /usr/local/bin/
COPY network-policy-resolver.mjs /usr/local/bin/pi-run-network-policy-resolver
RUN chmod 0755 \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/ssh-credentials \
        /usr/local/bin/pi-run-network-policy-resolver

WORKDIR /workspace

# System-level Git config for Flutter directory (before switching to node)
RUN git config --system --add safe.directory /opt/flutter

# Switch to node user for Flutter initialization
USER node

RUN flutter config --no-analytics \
    && dart --disable-analytics \
    && flutter --version \
    && chmod -R a+rwX /opt/flutter/bin/cache

# Validation tests as node
RUN set -eux; \
    node --version; \
    npm --version; \
    java -version; \
    javac -version; \
    mvn --version; \
    python3 --version; \
    pip3 --version; \
    ansible --version; \
    ansible-playbook --version; \
    ansible-galaxy --version; \
    ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote \
        ansible localhost -i localhost, -c local -m ansible.builtin.ping; \
    rm -rf /tmp/ansible-local /tmp/ansible-remote; \
    gcc --version; \
    g++ --version; \
    clang --version; \
    cmake --version; \
    ninja --version; \
    kubectl version --client; \
    helm version --short; \
    kustomize version; \
    yq --version; \
    flutter --version; \
    dart --version; \
    restic version; \
    pi --version

# Switch back to root for runtime entrypoint
USER root

ENTRYPOINT ["/usr/local/bin/entrypoint.sh", "pi"]
