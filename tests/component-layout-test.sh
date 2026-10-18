#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "component-layout-test: $*" >&2
    exit 1
}

SPDX='# SPDX-License-Identifier: MIT'
[[ "$(sed -n '2p' "${ROOT}/install.sh")" == "${SPDX}" ]] \
    || fail "standalone installer has no SPDX license identifier"
[[ "$(sed -n '1p' "${ROOT}/docker/Dockerfile")" == "${SPDX}" ]] \
    || fail "Dockerfile has no SPDX license identifier"
[[ "$(sed -n '1p' "${ROOT}/docker/egress/Dockerfile")" == "${SPDX}" ]] \
    || fail "egress Dockerfile has no SPDX license identifier"
[[ "$(sed -n '2p' "${ROOT}/docker/network-policy-resolver.mjs")" == "//${SPDX#\#}" ]] \
    || fail "network policy resolver has no SPDX license identifier"
[[ "$(sed -n '2p' "${ROOT}/docker/egress/entrypoint.sh")" == "${SPDX}" ]] \
    || fail "egress entrypoint has no SPDX license identifier"
[[ "$(sed -n '1p' "${ROOT}/.github/workflows/release.yml")" == "${SPDX}" ]] \
    || fail "release workflow has no SPDX license identifier"
[[ "$(sed -n '2p' "${BASH_SOURCE[0]}")" == "${SPDX}" ]] \
    || fail "packaging test has no SPDX license identifier"
image_license="${ROOT}/docker/licenses/pi-run-LICENSE"
[[ -f "${image_license}" && ! -L "${image_license}" ]] \
    || fail "runtime image license is missing or unsafe"
cmp -s "${ROOT}/LICENSE" "${image_license}" \
    || fail "runtime image license differs from the repository license"
grep -Fx 'COPY licenses/pi-run-LICENSE /usr/local/share/licenses/pi-run/LICENSE' \
    "${ROOT}/docker/Dockerfile" >/dev/null \
    || fail "Dockerfile does not install the Pi-Run license"
grep -Fx 'COPY licenses/pi-run-LICENSE /usr/local/share/licenses/pi-run/LICENSE' \
    "${ROOT}/docker/egress/Dockerfile" >/dev/null \
    || fail "egress Dockerfile does not install the Pi-Run license"
grep -Fx 'COPY network-policy-resolver.mjs /usr/local/bin/pi-run-network-policy-resolver' \
    "${ROOT}/docker/Dockerfile" >/dev/null \
    || fail "runtime image does not install the network policy resolver"
[[ -f "${ROOT}/docker/network-policy-resolver.mjs" && \
   ! -L "${ROOT}/docker/network-policy-resolver.mjs" ]] \
    || fail "network policy resolver is missing or unsafe"
[[ -x "${ROOT}/docker/egress/entrypoint.sh" && ! -L "${ROOT}/docker/egress/entrypoint.sh" ]] \
    || fail "egress entrypoint is missing or unsafe"
cmp -s "${ROOT}/experiments/docker-egress/entrypoint.sh" \
    "${ROOT}/docker/egress/entrypoint.sh" \
    || fail "production egress entrypoint differs from the proven experiment"
grep -Fx '  RUNTIME_IMAGE_NAME: ghcr.io/aprilsoftware/pi-run' \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow has no versioned runtime image name"
grep -Fx '  EGRESS_IMAGE_NAME: ghcr.io/aprilsoftware/pi-run-egress' \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow has no versioned egress image name"
grep -Fx "            --tag \"\${RUNTIME_IMAGE_NAME}:\${PI_RUN_VERSION}\" \\" \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow does not version the runtime image"
grep -Fx "            --file docker/egress/Dockerfile \\" \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow does not build the egress Dockerfile"
grep -Fx "            --tag \"\${EGRESS_IMAGE_NAME}:\${PI_RUN_VERSION}\" \\" \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow does not version the egress image"
grep -Fx "          for image in \"\${RUNTIME_IMAGE_NAME}\" \"\${EGRESS_IMAGE_NAME}\"; do" \
    "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow does not push both images"
if grep -E -- '--tag .*:latest|docker push .*:latest' \
    "${ROOT}/.github/workflows/release.yml" >/dev/null; then
    fail "release workflow publishes a mutable latest image"
fi
grep -Fx "            \"LICENSE\" \\" "${ROOT}/.github/workflows/release.yml" >/dev/null \
    || fail "release workflow does not publish the license"

EXPECTED="$(printf '%s\n' \
    doctor.sh profiles.sh restore.sh sessions.sh skills.sh snapshots.sh \
    upgrade.sh workspaces.sh | LC_ALL=C sort)"

assert_component_set() {
    local label="$1" actual="$2"
    if [[ "${actual}" != "${EXPECTED}" ]]; then
        printf 'component-layout-test: %s component set differs\nexpected:\n%s\nactual:\n%s\n' \
            "${label}" "${EXPECTED}" "${actual}" >&2
        exit 1
    fi
}

actual="$(find "${ROOT}/lib/pi-run" -mindepth 1 -maxdepth 1 -type f -name '*.sh' \
    -printf '%f\n' | LC_ALL=C sort)"
assert_component_set "source tree" "${actual}"

actual="$(awk -F/ '
    /^validate_component "\$\{PI_RUN_LIB_ROOT\}\// {
        name=$NF; gsub(/"/, "", name); print name
    }
' "${ROOT}/bin/pi-run" | LC_ALL=C sort)"
assert_component_set "launcher validation" "${actual}"

actual="$(awk -F/ '
    /^source "\$\{PI_RUN_LIB_ROOT\}\// {
        name=$NF; gsub(/"/, "", name); print name
    }
' "${ROOT}/bin/pi-run" | LC_ALL=C sort)"
assert_component_set "launcher loading" "${actual}"

actual="$(grep '^for required in ' "${ROOT}/scripts/build-release" |
    grep -oE 'lib/pi-run/[A-Za-z0-9._-]+\.sh' | sed 's|.*/||' | LC_ALL=C sort)"
assert_component_set "release build" "${actual}"

installer_line="$(grep '^for COMPONENT_NAME in ' "${ROOT}/install.sh")"
installer_line="${installer_line#for COMPONENT_NAME in }"
installer_line="${installer_line%; do}"
actual="$(for component in ${installer_line}; do printf '%s\n' "${component}"; done | LC_ALL=C sort)"
assert_component_set "installer" "${actual}"

for component in ${EXPECTED}; do
    path="${ROOT}/lib/pi-run/${component}"
    [[ -f "${path}" && ! -L "${path}" ]] || fail "unsafe source component: ${component}"
    [[ "$(stat -c %a "${path}")" == 644 ]] || fail "source component mode is not 644: ${component}"
    [[ "$(stat -c %h "${path}")" == 1 ]] || fail "source component is hard-linked: ${component}"
done

"${ROOT}/scripts/build-release" "${TMP}/release" >/dev/null
version="$(tr -d '\r\n' < "${ROOT}/VERSION")"
archive="${TMP}/release/pi-run-${version}.tar.gz"
actual="$(tar -tzf "${archive}" |
    sed -n "s|^pi-run-${version}/lib/pi-run/\([^/][^/]*\.sh\)$|\1|p" |
    LC_ALL=C sort)"
assert_component_set "release archive" "${actual}"

tar -xzf "${archive}" -C "${TMP}"
package="${TMP}/pi-run-${version}"
[[ ! -e "${package}/README.md" && ! -L "${package}/README.md" ]] \
    || fail "archive unexpectedly contains the repository README"
[[ -f "${package}/LICENSE" && ! -L "${package}/LICENSE" ]] \
    || fail "archive license is missing or unsafe"
cmp -s "${ROOT}/LICENSE" "${package}/LICENSE" \
    || fail "archive license differs from the repository license"
[[ -x "${package}/bin/pi-run" && ! -L "${package}/bin/pi-run" ]] \
    || fail "archive launcher is missing or unsafe"
for component in ${EXPECTED}; do
    path="${package}/lib/pi-run/${component}"
    [[ -f "${path}" && ! -L "${path}" ]] || fail "unsafe archive component: ${component}"
    [[ "$(stat -c %a "${path}")" == 644 ]] || fail "archive component mode is not 644: ${component}"
    [[ "$(stat -c %h "${path}")" == 1 ]] || fail "archive component is hard-linked: ${component}"
done

echo "component layout and packaging tests passed"
