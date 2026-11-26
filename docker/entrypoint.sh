#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

# Dynamic UID/GID adjustment entrypoint for pi-run.
# Changes the node user's UID/GID to match the host user's UID/GID,
# then drops privileges and runs Pi as node.

HOST_UID="${HOST_UID:?HOST_UID environment variable is required}"
HOST_GID="${HOST_GID:?HOST_GID environment variable is required}"

# Validate HOST_UID and HOST_GID.
if [[ ! "${HOST_UID}" =~ ^[0-9]+$ || ! "${HOST_GID}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: HOST_UID and HOST_GID must be numeric" >&2
    exit 1
fi

# Refuse root identity.
if [[ "${HOST_UID}" == 0 || "${HOST_GID}" == 0 ]]; then
    echo "ERROR: refusing to run Pi with UID or GID 0" >&2
    exit 1
fi

# Fail immediately if the expected image account is missing.
CURRENT_UID="$(id -u node)"
CURRENT_GID="$(id -g node)"

IDS_CHANGED=false

# Change the node group's GID first. Debian's groupmod updates users that
# use this group as their primary group so they continue to use it.
if [[ "${CURRENT_GID}" != "${HOST_GID}" ]]; then
    groupmod -g "${HOST_GID}" node
    IDS_CHANGED=true
fi

# Change node's UID if necessary.
if [[ "${CURRENT_UID}" != "${HOST_UID}" ]]; then
    usermod -u "${HOST_UID}" node
    IDS_CHANGED=true
fi

# Verify the resulting account identity before dropping privileges.
ACTUAL_UID="$(id -u node)"
ACTUAL_GID="$(id -g node)"

if [[ "${ACTUAL_UID}" != "${HOST_UID}" || "${ACTUAL_GID}" != "${HOST_GID}" ]]; then
    echo "ERROR: node identity is ${ACTUAL_UID}:${ACTUAL_GID}, expected ${HOST_UID}:${HOST_GID}" >&2
    exit 1
fi

# /knowledge is a stable model-facing path. The session knowledge extension
# updates only the per-container indirection under /run after Pi selects a
# session; persistent content remains in the mounted profile.
KNOWLEDGE_RUNTIME_DIR=/run/pi-run-knowledge
KNOWLEDGE_LINK=/knowledge
KNOWLEDGE_TARGET=${KNOWLEDGE_RUNTIME_DIR}/current
if [[ -e "${KNOWLEDGE_RUNTIME_DIR}" || -L "${KNOWLEDGE_RUNTIME_DIR}" ]]; then
    if [[ ! -d "${KNOWLEDGE_RUNTIME_DIR}" || -L "${KNOWLEDGE_RUNTIME_DIR}" ]]; then
        echo "ERROR: ${KNOWLEDGE_RUNTIME_DIR} must be a directory" >&2
        exit 1
    fi
fi
install -d -o "${HOST_UID}" -g "${HOST_GID}" -m 0700 "${KNOWLEDGE_RUNTIME_DIR}"
if [[ -e "${KNOWLEDGE_LINK}" || -L "${KNOWLEDGE_LINK}" ]]; then
    if [[ ! -L "${KNOWLEDGE_LINK}" || "$(readlink "${KNOWLEDGE_LINK}")" != "${KNOWLEDGE_TARGET}" ]]; then
        echo "ERROR: ${KNOWLEDGE_LINK} must be a symbolic link to ${KNOWLEDGE_TARGET}" >&2
        exit 1
    fi
else
    ln -s "${KNOWLEDGE_TARGET}" "${KNOWLEDGE_LINK}"
fi

# The image builds /home/node for node:1000:1000. Only rewrite it when the
# runtime UID/GID actually changed. DAC_READ_SEARCH + CHOWN are supplied by
# pi-run so the bootstrap can traverse and re-own restrictive home contents.
if [[ "${IDS_CHANGED}" == true ]]; then
    chown -R "${HOST_UID}:${HOST_GID}" /home/node
fi

export HOME=/home/node
export USER=node
export LOGNAME=node

# Java is optional in profile-derived runtimes. When present, bridge the mounted
# authoritative host PEM bundle into Java's ephemeral trust store. Missing or
# invalid Java trust inputs remain a startup failure for Java-capable runtimes.
/usr/local/bin/pi-run-java-trust-store \
    /etc/ssl/certs/java/cacerts \
    /etc/ssl/certs/ca-certificates.crt \
    /run/pi-run-java-cacerts.tmp \
    /usr/local/lib/pi-run

# Prepare ephemeral OpenSSH configuration as the mapped runtime user. Internal
# credential-management commands skip this so they can diagnose invalid keys.
if [[ "${PI_RUN_SKIP_SSH_CONFIG:-0}" != 1 ]]; then
    gosu node /usr/local/bin/ssh-credentials configure
fi

# Drop bootstrap privileges and replace the shell with Pi.
exec gosu node "$@"
