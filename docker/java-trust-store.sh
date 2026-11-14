#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "ERROR: Java trust setup requires DEFAULT_STORE HOST_BUNDLE TEMP_STORE HELPER_DIR" >&2
    exit 1
fi

DEFAULT_STORE="$1"
HOST_BUNDLE="$2"
TEMP_STORE="$3"
HELPER_DIR="$4"
HELPER_SOURCE="${HELPER_DIR}/PiRunJavaTrustStore.java"

/bin/rm -f -- "${TEMP_STORE}"

# A core-only runtime has no Java capability and needs no Java trust store.
if ! command -v java >/dev/null 2>&1; then
    exit 0
fi

for path in "${DEFAULT_STORE}" "${HOST_BUNDLE}" "${HELPER_SOURCE}"; do
    [[ -f "${path}" && ! -L "${path}" ]] || {
        echo "ERROR: Java trust input is missing or unsafe: ${path}" >&2
        exit 1
    }
done

trap '/bin/rm -f -- "${TEMP_STORE}"' EXIT
env -u JAVA_TOOL_OPTIONS -u JDK_JAVA_OPTIONS -u _JAVA_OPTIONS \
    java "${HELPER_SOURCE}" \
    "${DEFAULT_STORE}" \
    "${HOST_BUNDLE}" \
    "${TEMP_STORE}" \
    changeit
/bin/chmod 0444 "${TEMP_STORE}"
/bin/mv -T -- "${TEMP_STORE}" "${DEFAULT_STORE}"
trap - EXIT
