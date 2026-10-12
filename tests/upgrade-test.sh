#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
unset GH_TOKEN GITHUB_TOKEN

fail() {
    echo "upgrade-test: $*" >&2
    exit 1
}

assert_contains() {
    local text="$1" expected="$2"
    [[ "${text}" == *"${expected}"* ]] || fail "expected output to contain: ${expected}"
}

make_release() {
    local version="$1"
    local source="${TMP}/source-${version}"
    mkdir -p "${source}/scripts"
    cp -R "${ROOT}/bin" "${ROOT}/lib" "${ROOT}/templates" "${source}/"
    cp "${ROOT}/LICENSE" "${ROOT}/install.sh" "${source}/"
    cp "${ROOT}/scripts/build-release" "${source}/scripts/"
    printf '%s\n' "${version}" > "${source}/VERSION"
    sed -i "s/^PI_RUN_DEFAULT_VERSION=.*/PI_RUN_DEFAULT_VERSION=${version}/" "${source}/install.sh"
    "${source}/scripts/build-release" "${TMP}/releases" >/dev/null
}

release_json() {
    local tag="$1" draft="${2:-false}" prerelease="${3:-false}" assets="${4:-complete}"
    local version="${tag#v}"
    jq -nc --arg tag "${tag}" --arg version "${version}" \
        --argjson draft "${draft}" --argjson prerelease "${prerelease}" --arg assets "${assets}" '
        def asset($name): {name:$name,state:"uploaded"};
        [asset("install.sh"), asset("pi-run-" + $version + ".tar.gz"),
         asset("pi-run-" + $version + ".tar.gz.sha256")] as $complete |
        {tag_name:$tag,draft:$draft,prerelease:$prerelease,
         assets:(if $assets == "missing" then $complete[0:2]
                 elif $assets == "duplicate" then $complete + [asset("install.sh")]
                 else $complete end)}
    '
}

write_releases() {
    printf '%s\n' "$@" | jq -s . > "${RELEASES_METADATA}"
}

make_release 0.5.3
make_release 0.5.4
make_release 0.5.5

COMPONENT_CASE="${TMP}/component-case"
mkdir -p "${COMPONENT_CASE}"
cp -R "${ROOT}/bin" "${ROOT}/lib" "${COMPONENT_CASE}/"
printf '%s\n' 0.5.12 > "${COMPONENT_CASE}/VERSION"
"${COMPONENT_CASE}/bin/pi-run" version >/dev/null
mv "${COMPONENT_CASE}/lib/pi-run/upgrade.sh" "${COMPONENT_CASE}/lib/pi-run/upgrade.saved"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a missing upgrade component"
assert_contains "${output}" "component is missing or unsafe"
ln -s /dev/null "${COMPONENT_CASE}/lib/pi-run/upgrade.sh"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a linked upgrade component"
assert_contains "${output}" "component is missing or unsafe"
rm "${COMPONENT_CASE}/lib/pi-run/upgrade.sh"
printf '%s\n' 'if malformed component' > "${COMPONENT_CASE}/lib/pi-run/upgrade.sh"
set +e
"${COMPONENT_CASE}/bin/pi-run" version >/dev/null 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a malformed upgrade component"
cp "${COMPONENT_CASE}/lib/pi-run/upgrade.saved" "${COMPONENT_CASE}/lib/pi-run/upgrade.sh"

mv "${COMPONENT_CASE}/lib/pi-run/doctor.sh" "${COMPONENT_CASE}/lib/pi-run/doctor.saved"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a missing doctor component"
assert_contains "${output}" "component is missing or unsafe"
ln -s /dev/null "${COMPONENT_CASE}/lib/pi-run/doctor.sh"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a linked doctor component"
assert_contains "${output}" "component is missing or unsafe"
rm "${COMPONENT_CASE}/lib/pi-run/doctor.sh"
printf '%s\n' 'if malformed doctor component' > "${COMPONENT_CASE}/lib/pi-run/doctor.sh"
set +e
"${COMPONENT_CASE}/bin/pi-run" version >/dev/null 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a malformed doctor component"
cp "${COMPONENT_CASE}/lib/pi-run/doctor.saved" "${COMPONENT_CASE}/lib/pi-run/doctor.sh"

mv "${COMPONENT_CASE}/lib/pi-run/profiles.sh" "${COMPONENT_CASE}/lib/pi-run/profiles.saved"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a missing profiles component"
assert_contains "${output}" "component is missing or unsafe"
ln -s /dev/null "${COMPONENT_CASE}/lib/pi-run/profiles.sh"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a linked profiles component"
assert_contains "${output}" "component is missing or unsafe"
rm "${COMPONENT_CASE}/lib/pi-run/profiles.sh"
printf '%s\n' 'if malformed profiles component' > "${COMPONENT_CASE}/lib/pi-run/profiles.sh"
set +e
"${COMPONENT_CASE}/bin/pi-run" version >/dev/null 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a malformed profiles component"
cp "${COMPONENT_CASE}/lib/pi-run/profiles.saved" "${COMPONENT_CASE}/lib/pi-run/profiles.sh"

mv "${COMPONENT_CASE}/lib/pi-run/skills.sh" "${COMPONENT_CASE}/lib/pi-run/skills.saved"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a missing skills component"
assert_contains "${output}" "component is missing or unsafe"
ln -s /dev/null "${COMPONENT_CASE}/lib/pi-run/skills.sh"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a linked skills component"
assert_contains "${output}" "component is missing or unsafe"
rm "${COMPONENT_CASE}/lib/pi-run/skills.sh"
printf '%s\n' 'if malformed skills component' > "${COMPONENT_CASE}/lib/pi-run/skills.sh"
set +e
"${COMPONENT_CASE}/bin/pi-run" version >/dev/null 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a malformed skills component"
cp "${COMPONENT_CASE}/lib/pi-run/skills.saved" "${COMPONENT_CASE}/lib/pi-run/skills.sh"

mv "${COMPONENT_CASE}/lib/pi-run/workspaces.sh" "${COMPONENT_CASE}/lib/pi-run/workspaces.saved"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a missing workspaces component"
assert_contains "${output}" "component is missing or unsafe"
ln -s /dev/null "${COMPONENT_CASE}/lib/pi-run/workspaces.sh"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a linked workspaces component"
assert_contains "${output}" "component is missing or unsafe"
rm "${COMPONENT_CASE}/lib/pi-run/workspaces.sh"
printf '%s\n' 'if malformed workspaces component' > "${COMPONENT_CASE}/lib/pi-run/workspaces.sh"
set +e
"${COMPONENT_CASE}/bin/pi-run" version >/dev/null 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a malformed workspaces component"
cp "${COMPONENT_CASE}/lib/pi-run/workspaces.saved" "${COMPONENT_CASE}/lib/pi-run/workspaces.sh"

mv "${COMPONENT_CASE}/lib/pi-run/snapshots.sh" "${COMPONENT_CASE}/lib/pi-run/snapshots.saved"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a missing snapshots component"
assert_contains "${output}" "component is missing or unsafe"
ln -s /dev/null "${COMPONENT_CASE}/lib/pi-run/snapshots.sh"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a linked snapshots component"
assert_contains "${output}" "component is missing or unsafe"
rm "${COMPONENT_CASE}/lib/pi-run/snapshots.sh"
printf '%s\n' 'if malformed snapshots component' > "${COMPONENT_CASE}/lib/pi-run/snapshots.sh"
set +e
"${COMPONENT_CASE}/bin/pi-run" version >/dev/null 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a malformed snapshots component"
cp "${COMPONENT_CASE}/lib/pi-run/snapshots.saved" "${COMPONENT_CASE}/lib/pi-run/snapshots.sh"

mv "${COMPONENT_CASE}/lib/pi-run/restore.sh" "${COMPONENT_CASE}/lib/pi-run/restore.saved"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a missing restore component"
assert_contains "${output}" "component is missing or unsafe"
ln -s /dev/null "${COMPONENT_CASE}/lib/pi-run/restore.sh"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a linked restore component"
assert_contains "${output}" "component is missing or unsafe"
rm "${COMPONENT_CASE}/lib/pi-run/restore.sh"
printf '%s\n' 'if malformed restore component' > "${COMPONENT_CASE}/lib/pi-run/restore.sh"
set +e
"${COMPONENT_CASE}/bin/pi-run" version >/dev/null 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a malformed restore component"
cp "${COMPONENT_CASE}/lib/pi-run/restore.saved" "${COMPONENT_CASE}/lib/pi-run/restore.sh"

mv "${COMPONENT_CASE}/lib/pi-run/sessions.sh" "${COMPONENT_CASE}/lib/pi-run/sessions.saved"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a missing sessions component"
assert_contains "${output}" "component is missing or unsafe"
ln -s /dev/null "${COMPONENT_CASE}/lib/pi-run/sessions.sh"
set +e
output="$("${COMPONENT_CASE}/bin/pi-run" version 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a linked sessions component"
assert_contains "${output}" "component is missing or unsafe"
rm "${COMPONENT_CASE}/lib/pi-run/sessions.sh"
printf '%s\n' 'if malformed sessions component' > "${COMPONENT_CASE}/lib/pi-run/sessions.sh"
set +e
"${COMPONENT_CASE}/bin/pi-run" version >/dev/null 2>&1
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "launcher accepted a malformed sessions component"

mkdir -p "${TMP}/fake-bin" "${TMP}/home"
REAL_CURL="$(command -v curl)"
cat > "${TMP}/fake-bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
is_releases=false
destination=""
authorized=false
args=("$@")
for ((index=0; index < ${#args[@]}; index++)); do
    argument="${args[index]}"
    case "${argument}" in
        "${RELEASES_URL:?}") is_releases=true ;;
        -o)
            ((index += 1))
            destination="${args[index]}"
            ;;
        -H|--header)
            ((index += 1))
            header="${args[index]}"
            if [[ "${header}" == @* ]]; then
                grep -Fx 'Authorization: Bearer private-test-token' "${header#@}" >/dev/null && authorized=true
            elif [[ "${header}" == 'Authorization: Bearer private-test-token' ]]; then
                exit 92
            fi
            ;;
    esac
done
if [[ "${is_releases}" == false ]]; then
    exec "${REAL_CURL:?}" "$@"
fi
printf '%s\n' releases >> "${CURL_LOG:?}"
if [[ "${EXPECT_AUTH:-false}" == true && "${authorized}" == false ]]; then
    exit 91
fi
if [[ "${RELEASES_CURL_STATUS:-0}" != 0 ]]; then
    exit "${RELEASES_CURL_STATUS}"
fi
code="${RELEASES_HTTP_CODE:-200}"
if [[ "${code}" == 200 ]]; then
    cp "${RELEASES_METADATA:?}" "${destination}"
fi
printf '%s' "${code}"
EOF
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
[ "$1" = pull ] || exit 2
printf '%s\n' "$2" >> "${DOCKER_LOG:?}"
[ "$2" != "${FAIL_IMAGE:-}" ]
EOF
cat > "${TMP}/fake-bin/gh" <<'EOF'
#!/bin/sh
if [ "${GH_AVAILABLE:-false}" = true ] && [ "$1" = auth ] && [ "$2" = token ]; then
    printf '%s\n' private-test-token
    printf '%s\n' token >> "${GH_LOG:?}"
    exit 0
fi
exit 1
EOF
chmod 0755 "${TMP}/fake-bin/curl" "${TMP}/fake-bin/docker" "${TMP}/fake-bin/gh"

export REAL_CURL
export CURL_LOG="${TMP}/curl.log"
export DOCKER_LOG="${TMP}/docker.log"
export GH_LOG="${TMP}/gh.log"
export RELEASES_METADATA="${TMP}/releases.json"
export RELEASES_URL='https://api.github.test/repos/aprilsoftware/pi-run/releases?per_page=100'

INSTALL_ROOT="${TMP}/application root"
BIN_DIR="${TMP}/executable dir"
HOME_DIR="${TMP}/home"
RELEASE_BASE="file://${TMP}/releases"

PATH="${TMP}/fake-bin:${PATH}" \
HOME="${HOME_DIR}" \
PI_RUN_RELEASE_BASE_URL="${RELEASE_BASE}" \
PI_RUN_INSTALL_ROOT="${INSTALL_ROOT}" \
PI_RUN_BIN_DIR="${BIN_DIR}" \
"${TMP}/source-0.5.3/install.sh" >/dev/null

[[ "$(cat "${INSTALL_ROOT}/bin-dir")" == "${BIN_DIR}" ]] \
    || fail "custom executable directory was not recorded"
printf 'user data\n' > "${HOME_DIR}/preserve"

# Explicit releases use GitHub's canonical vX.Y.Z tag spelling.
PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" PI_RUN_RELEASE_BASE_URL="${RELEASE_BASE}" \
    "${BIN_DIR}/pi-run" upgrade v0.5.4 >/dev/null
[[ "$(readlink "${INSTALL_ROOT}/current")" == 'releases/0.5.4' ]]
[[ "$(cat "${HOME_DIR}/preserve")" == 'user data' ]]
"${BIN_DIR}/pi-run" version | grep -F 'pi-run v0.5.4' >/dev/null
grep -Fx 'ghcr.io/aprilsoftware/pi-run:0.5.4' "${DOCKER_LOG}" >/dev/null

# Installation checks happen before release-list network access.
: > "${CURL_LOG}"
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" PI_RUN_RELEASES_URL="${RELEASES_URL}" \
    "${ROOT}/bin/pi-run" upgrade 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "source checkout accepted upgrade"
assert_contains "${output}" "upgrade requires an installed release"
[[ ! -s "${CURL_LOG}" ]] || fail "source checkout queried the release API"

# Check-only discovers a newer complete published release without mutation.
write_releases "$(release_json v0.5.5)"
output="$(PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" GH_AVAILABLE=false \
    PI_RUN_RELEASES_URL="${RELEASES_URL}" "${BIN_DIR}/pi-run" upgrade --check)"
assert_contains "${output}" "update available: v0.5.5 (installed: v0.5.4)"
[[ "$(readlink "${INSTALL_ROOT}/current")" == 'releases/0.5.4' ]]

# An authenticated gh session is used automatically and the resolved release
# is installed atomically.
: > "${GH_LOG}"
PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" GH_AVAILABLE=true EXPECT_AUTH=true \
PI_RUN_RELEASES_URL="${RELEASES_URL}" PI_RUN_RELEASE_BASE_URL="${RELEASE_BASE}" \
    "${BIN_DIR}/pi-run" upgrade >/dev/null
grep -Fx token "${GH_LOG}" >/dev/null || fail "authenticated gh session was not used"
[[ "$(readlink "${INSTALL_ROOT}/current")" == 'releases/0.5.5' ]]
[[ -d "${INSTALL_ROOT}/releases/0.5.3" && -d "${INSTALL_ROOT}/releases/0.5.4" ]]
[[ "$(cat "${HOME_DIR}/preserve")" == 'user data' ]]
grep -Fx 'ghcr.io/aprilsoftware/pi-run:0.5.5' "${DOCKER_LOG}" >/dev/null

# Current releases succeed without downloading or pulling another image.
before_pulls="$(wc -l < "${DOCKER_LOG}")"
output="$(PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" GH_AVAILABLE=false \
    PI_RUN_RELEASES_URL="${RELEASES_URL}" "${BIN_DIR}/pi-run" upgrade)"
assert_contains "${output}" "up to date: v0.5.5"
[[ "$(wc -l < "${DOCKER_LOG}")" == "${before_pulls}" ]]

# Explicit equal, older, and malformed targets are rejected.
for rejected in 0.5.6 0.5.5 v0.5.5 0.5.4 v0.5 01.0.0; do
    set +e
    output="$(HOME="${HOME_DIR}" "${BIN_DIR}/pi-run" upgrade "${rejected}" 2>&1)"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "accepted invalid upgrade target: ${rejected}"
done

# Selection uses the highest semantic version, includes prereleases, ignores
# drafts and ordering, and still refuses a list whose newest installable release
# would be a downgrade.
write_releases \
    "$(release_json v0.5.4)" \
    "$(release_json v9.0.0 true false)" \
    "$(release_json v0.5.6 false true)" \
    "$(release_json v0.5.5)"
output="$(PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" GH_AVAILABLE=false \
    PI_RUN_RELEASES_URL="${RELEASES_URL}" "${BIN_DIR}/pi-run" upgrade --check)"
assert_contains "${output}" "update available: v0.5.6 (installed: v0.5.5)"

write_releases "$(release_json v0.5.4)"
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" GH_AVAILABLE=false \
    PI_RUN_RELEASES_URL="${RELEASES_URL}" "${BIN_DIR}/pi-run" upgrade --check 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] && assert_contains "${output}" "refusing downgrade"

# Malformed tags and releases with missing or duplicate required assets are not
# installable, even when they have a numerically newer-looking name.
for metadata in \
    "$(release_json 0.5.6)" \
    "$(release_json v0.5.6 false false missing)" \
    "$(release_json v0.5.6 false false duplicate)" \
    "$(release_json v0.5.6 true false)"; do
    write_releases "${metadata}"
    set +e
    output="$(PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" GH_AVAILABLE=false \
        PI_RUN_RELEASES_URL="${RELEASES_URL}" "${BIN_DIR}/pi-run" upgrade --check 2>&1)"
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "accepted a release without canonical complete assets"
    assert_contains "${output}" "no installable published Pi-Run release"
done

# Authentication, not-found, and transport failures have actionable errors.
write_releases "$(release_json v0.5.6 false true)"
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" GH_AVAILABLE=false RELEASES_HTTP_CODE=404 \
    PI_RUN_RELEASES_URL="${RELEASES_URL}" "${BIN_DIR}/pi-run" upgrade --check 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] && assert_contains "${output}" "not found or the repository is private"
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" GH_TOKEN=bad RELEASES_HTTP_CODE=403 \
    PI_RUN_RELEASES_URL="${RELEASES_URL}" "${BIN_DIR}/pi-run" upgrade --check 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] && assert_contains "${output}" "authentication failed"
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" GH_AVAILABLE=false RELEASES_CURL_STATUS=7 \
    PI_RUN_RELEASES_URL="${RELEASES_URL}" "${BIN_DIR}/pi-run" upgrade --check 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] && assert_contains "${output}" "could not query"

# Existing atomic failure guarantees apply to the next explicit release.
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" PI_RUN_RELEASE_BASE_URL="${RELEASE_BASE}" \
    "${BIN_DIR}/pi-run" upgrade v0.5.6 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "missing release was accepted"
[[ "$(readlink "${INSTALL_ROOT}/current")" == 'releases/0.5.5' ]]

make_release 0.5.6
printf 'tampered\n' >> "${TMP}/releases/pi-run-0.5.6.tar.gz"
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" PI_RUN_RELEASE_BASE_URL="${RELEASE_BASE}" \
    "${BIN_DIR}/pi-run" upgrade v0.5.6 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "checksum failure was accepted"
assert_contains "${output}" "FAILED"
[[ ! -e "${INSTALL_ROOT}/releases/0.5.6" ]]

make_release 0.5.6
set +e
output="$(PATH="${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" PI_RUN_RELEASE_BASE_URL="${RELEASE_BASE}" \
    FAIL_IMAGE='ghcr.io/aprilsoftware/pi-run:0.5.6' "${BIN_DIR}/pi-run" upgrade v0.5.6 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "failed image pull was accepted"
[[ "$(readlink "${INSTALL_ROOT}/current")" == 'releases/0.5.5' ]]
[[ ! -e "${INSTALL_ROOT}/releases/0.5.6" ]]

mkdir -p "${TMP}/fail-copy-bin"
printf '#!/bin/sh\nexit 1\n' > "${TMP}/fail-copy-bin/cp"
chmod 0755 "${TMP}/fail-copy-bin/cp"
set +e
output="$(PATH="${TMP}/fail-copy-bin:${TMP}/fake-bin:${PATH}" HOME="${HOME_DIR}" \
    PI_RUN_RELEASE_BASE_URL="${RELEASE_BASE}" "${BIN_DIR}/pi-run" upgrade v0.5.6 2>&1)"
status=$?
set -e
[[ ${status} -ne 0 ]] || fail "failed staging copy was accepted"
[[ "$(readlink "${INSTALL_ROOT}/current")" == 'releases/0.5.5' ]]
[[ ! -e "${INSTALL_ROOT}/releases/0.5.6" ]]

echo "release-aware atomic upgrade tests passed"
