# syntax=docker/dockerfile:1
# SPDX-License-Identifier: MIT

ARG PI_RUN_BASE_IMAGE
FROM ${PI_RUN_BASE_IMAGE}

# BEGIN PI-RUN BUNDLE utility-belt
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash-completion \
        bc \
        bzip2 \
        dos2unix \
        file \
        gettext-base \
        less \
        libxml2-utils \
        lsof \
        patch \
        procps \
        rsync \
        shellcheck \
        socat \
        strace \
        tar \
        tree \
        unzip \
        wget \
        xmlstarlet \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*
# END PI-RUN BUNDLE utility-belt

# BEGIN PI-RUN BUNDLE network-diagnostics
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        dnsutils \
        iproute2 \
        iputils-ping \
        traceroute \
    && rm -rf /var/lib/apt/lists/*
# END PI-RUN BUNDLE network-diagnostics

# BEGIN PI-RUN BUNDLE python-development
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        pipx \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*
ENV PATH="/home/node/.local/bin:${PATH}"
RUN python3 --version && pip3 --version && pipx --version
# END PI-RUN BUNDLE python-development

# BEGIN PI-RUN BUNDLE operations
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ansible \
    && rm -rf /var/lib/apt/lists/*
RUN ansible --version \
    && ansible-playbook --version \
    && ansible-galaxy --version \
    && ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote \
        ansible localhost -i localhost, -c local -m ansible.builtin.ping \
    && rm -rf /tmp/ansible-local /tmp/ansible-remote
# END PI-RUN BUNDLE operations

# BEGIN PI-RUN BUNDLE native-development
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        clang \
        clang-format \
        cmake \
        gdb \
        ninja-build \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN gcc --version \
    && g++ --version \
    && clang --version \
    && cmake --version \
    && ninja --version
# END PI-RUN BUNDLE native-development

# BEGIN PI-RUN BUNDLE java-development
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        maven \
        openjdk-21-jdk-headless \
    && rm -rf /var/lib/apt/lists/*
RUN java -version && javac -version && mvn --version
# END PI-RUN BUNDLE java-development

# BEGIN PI-RUN BUNDLE rust-development
USER root
ARG RUST_VERSION=1.99.1
COPY --from=rust:1.99.1-trixie /usr/local/cargo /usr/local/cargo
COPY --from=rust:1.99.1-trixie /usr/local/rustup /usr/local/rustup
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH="/usr/local/cargo/bin:${PATH}"
RUN rustup component add --toolchain "${RUST_VERSION}" rustfmt clippy \
    && chmod -R a+w "${RUSTUP_HOME}" "${CARGO_HOME}" \
    && rustc --version | grep -E "^rustc ${RUST_VERSION} " \
    && cargo --version \
    && rustfmt --version \
    && cargo clippy --version
# END PI-RUN BUNDLE rust-development

# BEGIN PI-RUN BUNDLE headless-gui
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libasound2-dev \
        libgl1-mesa-dri \
        libglu1-mesa \
        libgtk-3-dev \
        libxcb-xkb1 \
        libxkbcommon-x11-0 \
        mesa-vulkan-drivers \
        pkg-config \
        xauth \
        xvfb \
    && rm -rf /var/lib/apt/lists/*
RUN pkg-config --modversion alsa \
    && xvfb-run --server-args="-screen 0 1280x720x24 -nolisten tcp" true \
    && find /usr/share/vulkan/icd.d -maxdepth 1 -type f -name '*.json' -print -quit | grep -q . \
    && find /usr/lib -type f -path '*/dri/*_dri.so' -print -quit | grep -q . \
    && ldconfig -p | grep -F 'libxcb-xkb.so.1' \
    && ldconfig -p | grep -F 'libxkbcommon-x11.so.0'
# END PI-RUN BUNDLE headless-gui

# BEGIN PI-RUN BUNDLE flutter-development
USER root
ARG FLUTTER_VERSION=3.47.2
RUN apt-get update \
    && apt-get install -y --no-install-recommends tar xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSLo /tmp/flutter.tar.xz \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    && tar -xJf /tmp/flutter.tar.xz -C /opt \
    && rm -f /tmp/flutter.tar.xz \
    && chown -R node:node /opt/flutter \
    && git config --system --add safe.directory /opt/flutter
ENV PATH="/opt/flutter/bin:${PATH}"
USER node
RUN flutter config --no-analytics \
    && dart --disable-analytics \
    && flutter --version \
    && chmod -R a+rwX /opt/flutter/bin/cache
USER root
# END PI-RUN BUNDLE flutter-development

# BEGIN PI-RUN BUNDLE database-clients
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        default-mysql-client \
        postgresql-client \
        redis-tools \
        sqlite3 \
    && rm -rf /var/lib/apt/lists/*
RUN command -v mysql \
    && command -v psql \
    && command -v redis-cli \
    && command -v sqlite3
# END PI-RUN BUNDLE database-clients

# BEGIN PI-RUN BUNDLE kubernetes
USER root
ARG KUBECTL_VERSION=1.37.0
ARG HELM_VERSION=4.2.0
ARG KUSTOMIZE_VERSION=5.8.1
ARG YQ_VERSION=4.53.3
RUN apt-get update \
    && apt-get install -y --no-install-recommends gzip tar \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod 0755 /usr/local/bin/kubectl \
    && curl -fsSLo /tmp/helm.tar.gz \
        "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
    && tar -xzf /tmp/helm.tar.gz -C /tmp \
    && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tar.gz /tmp/linux-amd64 \
    && curl -fsSLo /tmp/kustomize.tar.gz \
        "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
    && tar -xzf /tmp/kustomize.tar.gz -C /tmp \
    && install -m 0755 /tmp/kustomize /usr/local/bin/kustomize \
    && rm -f /tmp/kustomize.tar.gz /tmp/kustomize \
    && curl -fsSLo /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
    && chmod 0755 /usr/local/bin/yq
RUN kubectl version --client \
    && helm version --short \
    && kustomize version \
    && yq --version
# END PI-RUN BUNDLE kubernetes
