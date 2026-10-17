#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "private-release-install-test: $*" >&2
    exit 1
}

mkdir -p "${TMP}/release" "${TMP}/fake-bin" "${TMP}/home"
"${ROOT}/scripts/build-release" "${TMP}/release" >/dev/null
cat > "${TMP}/release/metadata.json" <<'EOF'
{
  "assets": [
    {
      "name": "pi-run-0.7.0.tar.gz",
      "url": "https://api.github.test/releases/assets/1"
    },
    {
      "name": "pi-run-0.7.0.tar.gz.sha256",
      "url": "https://api.github.test/releases/assets/2"
    }
  ]
}
EOF

cat > "${TMP}/fake-bin/curl" <<'EOF'
#!/bin/sh
set -eu
destination=""
url=""
authorized=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        *private-test-token*) exit 4 ;;
        -o)
            destination=$2
            shift 2
            ;;
        -H)
            case "$2" in
                "Authorization: Bearer private-test-token") exit 4 ;;
                @*) grep -Fx 'Authorization: Bearer private-test-token' "${2#@}" >/dev/null && authorized=true ;;
            esac
            shift 2
            ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
[ -n "$destination" ] && [ -n "$url" ] && [ "$authorized" = true ] || exit 2
printf '%s\n' "$url" >> "${CURL_LOG:?}"
case "$url" in
    https://api.github.com/repos/aprilsoftware/pi-run/releases/tags/v0.7.0)
        cp "${FIXTURE_RELEASE:?}/metadata.json" "$destination"
        ;;
    https://api.github.test/releases/assets/1)
        cp "${FIXTURE_RELEASE:?}/pi-run-0.7.0.tar.gz" "$destination"
        ;;
    https://api.github.test/releases/assets/2)
        cp "${FIXTURE_RELEASE:?}/pi-run-0.7.0.tar.gz.sha256" "$destination"
        ;;
    *) exit 3 ;;
esac
EOF
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = pull ] || exit 2
case "$2" in
    ghcr.io/aprilsoftware/pi-run:0.7.0|ghcr.io/aprilsoftware/pi-run-egress:0.7.0) ;;
    *) exit 2 ;;
esac
printf '%s\n' "$2" >> "${DOCKER_LOG:?}"
EOF
chmod 0755 "${TMP}/fake-bin/curl" "${TMP}/fake-bin/docker"

# GitHub release assets are commonly downloaded without executable permission.
cp "${ROOT}/install.sh" "${TMP}/downloaded-install.sh"
chmod 0644 "${TMP}/downloaded-install.sh"
[[ "$(stat -c '%a' "${TMP}/downloaded-install.sh")" == 644 ]]

export CURL_LOG="${TMP}/curl.log"
export DOCKER_LOG="${TMP}/docker.log"
export FIXTURE_RELEASE="${TMP}/release"
PATH="${TMP}/fake-bin:${PATH}" \
HOME="${TMP}/home" \
GH_TOKEN="private-test-token" \
PI_RUN_INSTALL_ROOT="${TMP}/application" \
PI_RUN_BIN_DIR="${TMP}/bin" \
sh "${TMP}/downloaded-install.sh" >/dev/null

[[ -L "${TMP}/bin/pi-run" ]] || fail "private install did not create executable link"
for component in doctor.sh upgrade.sh; do
    [[ -f "${TMP}/application/current/lib/pi-run/${component}" &&
       ! -L "${TMP}/application/current/lib/pi-run/${component}" ]] \
        || fail "private install did not activate component: ${component}"
done
[[ "$(cat "${TMP}/application/current/VERSION")" == 0.7.0 ]] \
    || fail "private install selected the wrong release"
grep -Fx 'ghcr.io/aprilsoftware/pi-run:0.7.0' "${DOCKER_LOG}" >/dev/null \
    || fail "private install did not pull the runtime image"
grep -Fx 'ghcr.io/aprilsoftware/pi-run-egress:0.7.0' "${DOCKER_LOG}" >/dev/null \
    || fail "private install did not pull the egress image"
[[ "$(wc -l < "${DOCKER_LOG}")" -eq 2 ]] \
    || fail "private install pulled an unexpected image set"
grep -Fx 'https://api.github.com/repos/aprilsoftware/pi-run/releases/tags/v0.7.0' \
    "${TMP}/curl.log" >/dev/null
grep -Fx 'https://api.github.test/releases/assets/1' "${TMP}/curl.log" >/dev/null
grep -Fx 'https://api.github.test/releases/assets/2' "${TMP}/curl.log" >/dev/null
if grep -F 'github.com/aprilsoftware/pi-run/releases/download' "${TMP}/curl.log" >/dev/null; then
    fail "private install used the unauthenticated browser download URL"
fi

echo "private release API installation test passed"
