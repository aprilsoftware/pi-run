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

# The image builds /home/node for node:1000:1000. Only rewrite it when the
# runtime UID/GID actually changed. DAC_READ_SEARCH + CHOWN are supplied by
# pi-run so the bootstrap can traverse and re-own restrictive home contents.
if [[ "${IDS_CHANGED}" == true ]]; then
    chown -R "${HOST_UID}:${HOST_GID}" /home/node
fi

export HOME=/home/node
export USER=node
export LOGNAME=node

# Prepare ephemeral OpenSSH configuration as the mapped runtime user. Internal
# credential-management commands skip this so they can diagnose invalid keys.
if [[ "${PI_RUN_SKIP_SSH_CONFIG:-0}" != 1 ]]; then
    gosu node /usr/local/bin/ssh-credentials configure
fi

# Drop bootstrap privileges and replace the shell with Pi.
exec gosu node "$@"
