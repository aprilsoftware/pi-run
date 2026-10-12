# SPDX-License-Identifier: MIT
# shellcheck shell=bash

validate_release_version() {
    local version="$1" part
    local -a version_parts
    [[ "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
        || fail "invalid release version: ${version}"
    IFS=. read -r -a version_parts <<< "${version}"
    for part in "${version_parts[@]}"; do
        (( ${#part} <= 9 )) || fail "release version component is too large: ${version}"
    done
}

release_tag_version() {
    local tag="$1" version
    [[ "${tag}" == v* ]] || fail "invalid release tag: ${tag}; expected vX.Y.Z"
    version="${tag#v}"
    validate_release_version "${version}"
    printf '%s\n' "${version}"
}

version_is_newer() {
    local current="$1" target="$2" index current_number target_number
    local -a current_parts target_parts
    IFS=. read -r -a current_parts <<< "${current}"
    IFS=. read -r -a target_parts <<< "${target}"
    for index in 0 1 2; do
        current_number=$((10#${current_parts[index]}))
        target_number=$((10#${target_parts[index]}))
        (( target_number > current_number )) && return 0
        (( target_number < current_number )) && return 1
    done
    return 1
}

UPGRADE_APPLICATION_ROOT=""
UPGRADE_BIN_DIR=""
UPGRADE_INSTALLER=""

resolve_upgrade_installation() {
    local releases_dir current_link metadata_file
    local -a metadata_lines
    releases_dir="$(dirname "${INSTALL_ROOT}")"
    [[ "$(basename "${releases_dir}")" == releases ]] \
        || fail "upgrade requires an installed release, not a source checkout"
    UPGRADE_APPLICATION_ROOT="$(dirname "${releases_dir}")"
    current_link="${UPGRADE_APPLICATION_ROOT}/current"
    [[ -L "${current_link}" && "$(realpath "${current_link}")" == "${INSTALL_ROOT}" ]] \
        || fail "upgrade requires the active installed release"

    metadata_file="${UPGRADE_APPLICATION_ROOT}/bin-dir"
    [[ -f "${metadata_file}" && ! -L "${metadata_file}" ]] \
        || fail "installation metadata is missing or unsafe: ${metadata_file}"
    mapfile -t metadata_lines < "${metadata_file}"
    if (( ${#metadata_lines[@]} != 1 )) || [[ -z "${metadata_lines[0]}" ]]; then
        fail "installation metadata is invalid: ${metadata_file}"
    fi
    UPGRADE_BIN_DIR="${metadata_lines[0]}"

    UPGRADE_INSTALLER="${INSTALL_ROOT}/install.sh"
    [[ -x "${UPGRADE_INSTALLER}" && ! -L "${UPGRADE_INSTALLER}" ]] \
        || fail "installed upgrade helper is missing or unsafe: ${UPGRADE_INSTALLER}"
}

resolve_upgrade_token() {
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [[ -z "${token}" ]] && command -v gh >/dev/null 2>&1; then
        token="$(gh auth token 2>/dev/null || true)"
    fi
    [[ "${token}" != *$'\n'* && "${token}" != *$'\r'* ]] \
        || fail "GitHub token contains an invalid newline"
    printf '%s' "${token}"
}

query_latest_release_version() {
    local token="$1" url metadata http_code curl_status version
    command -v curl >/dev/null 2>&1 || fail "curl is required to check for upgrades"
    require_jq
    url="${PI_RUN_RELEASES_URL:-https://api.github.com/repos/aprilsoftware/pi-run/releases?per_page=100}"
    metadata="$(mktemp)"
    set +e
    if [[ -n "${token}" ]]; then
        http_code="$(curl -sS -L --max-filesize 4194304 -o "${metadata}" -w '%{http_code}' \
            --header @<(printf 'Authorization: Bearer %s\n' "${token}") \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' "${url}" 2>/dev/null)"
        curl_status=$?
    else
        http_code="$(curl -sS -L --max-filesize 4194304 -o "${metadata}" -w '%{http_code}' \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' "${url}" 2>/dev/null)"
        curl_status=$?
    fi
    set -e
    if (( curl_status != 0 )); then
        rm -f -- "${metadata}"
        fail "could not query published GitHub releases"
    fi
    case "${http_code}" in
        200)
            (( $(stat -c %s "${metadata}") <= 4194304 )) || {
                rm -f -- "${metadata}"
                fail "GitHub release metadata is too large"
            }
            ;;
        401|403)
            rm -f -- "${metadata}"
            fail "GitHub release authentication failed; set GH_TOKEN or GITHUB_TOKEN, or authenticate gh"
            ;;
        404)
            rm -f -- "${metadata}"
            if [[ -z "${token}" ]]; then
                fail "GitHub releases were not found or the repository is private; set GH_TOKEN or GITHUB_TOKEN, or authenticate gh"
            fi
            fail "GitHub releases were not found"
            ;;
        *)
            rm -f -- "${metadata}"
            fail "GitHub releases query returned HTTP ${http_code}"
            ;;
    esac
    version="$(jq -er '
        def one_uploaded($name):
            [.assets[]? | select(.name == $name and .state == "uploaded")] | length == 1;
        [
            .[]
            | select(type == "object" and .draft == false)
            | .tag_name as $tag
            | select($tag | type == "string" and test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"))
            | ($tag[1:] | split(".") | map(tonumber)) as $parts
            | ($tag[1:]) as $version
            | select(one_uploaded("install.sh"))
            | select(one_uploaded("pi-run-" + $version + ".tar.gz"))
            | select(one_uploaded("pi-run-" + $version + ".tar.gz.sha256"))
            | {version: $version, parts: $parts}
        ]
        | sort_by(.parts[0], .parts[1], .parts[2])
        | last
        | .version
    ' "${metadata}" 2>/dev/null)" || {
        rm -f -- "${metadata}"
        fail "no installable published Pi-Run release was found"
    }
    rm -f -- "${metadata}"
    validate_release_version "${version}"
    printf '%s\n' "${version}"
}

run_upgrade_target() {
    local target="$1" token
    validate_release_version "${PI_RUN_VERSION}"
    target="$(release_tag_version "${target}")"
    version_is_newer "${PI_RUN_VERSION}" "${target}" \
        || fail "upgrade target must be newer than v${PI_RUN_VERSION}: v${target}"
    token="$(resolve_upgrade_token)"
    GH_TOKEN="${token}" \
    PI_RUN_INSTALL_VERSION="${target}" \
    PI_RUN_INSTALL_ROOT="${UPGRADE_APPLICATION_ROOT}" \
    PI_RUN_BIN_DIR="${UPGRADE_BIN_DIR}" \
        "${UPGRADE_INSTALLER}"
}

run_latest_upgrade() {
    local check_only="$1" token latest
    validate_release_version "${PI_RUN_VERSION}"
    token="$(resolve_upgrade_token)"
    latest="$(query_latest_release_version "${token}")"
    if [[ "${latest}" == "${PI_RUN_VERSION}" ]]; then
        printf 'Pi-Run is up to date: v%s\n' "${PI_RUN_VERSION}"
        return 0
    fi
    version_is_newer "${PI_RUN_VERSION}" "${latest}" \
        || fail "latest GitHub release v${latest} is older than installed v${PI_RUN_VERSION}; refusing downgrade"
    if [[ "${check_only}" == true ]]; then
        printf 'Pi-Run update available: v%s (installed: v%s)\n' "${latest}" "${PI_RUN_VERSION}"
        return 0
    fi
    printf 'Upgrading Pi-Run from v%s to v%s...\n' "${PI_RUN_VERSION}" "${latest}"
    GH_TOKEN="${token}" \
    PI_RUN_INSTALL_VERSION="${latest}" \
    PI_RUN_INSTALL_ROOT="${UPGRADE_APPLICATION_ROOT}" \
    PI_RUN_BIN_DIR="${UPGRADE_BIN_DIR}" \
        "${UPGRADE_INSTALLER}"
}
