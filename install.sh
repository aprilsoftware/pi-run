#!/bin/sh
# SPDX-License-Identifier: MIT

set -eu
umask 022

PI_RUN_DEFAULT_VERSION=0.10.9
REPOSITORY=aprilsoftware/pi-run

fail() {
    echo "pi-run installer: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    command_exists "$1" || fail "required command is unavailable: $1"
}

require_command grep
PI_RUN_VERSION=${PI_RUN_INSTALL_VERSION:-${PI_RUN_DEFAULT_VERSION}}
printf '%s\n' "${PI_RUN_VERSION}" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
    || fail "invalid release version: ${PI_RUN_VERSION}"
RUNTIME_IMAGE="ghcr.io/aprilsoftware/pi-run:${PI_RUN_VERSION}"
EGRESS_IMAGE="ghcr.io/aprilsoftware/pi-run-egress:${PI_RUN_VERSION}"
ARCHIVE="pi-run-${PI_RUN_VERSION}.tar.gz"
CHECKSUM="${ARCHIVE}.sha256"
DEFAULT_RELEASE_BASE="https://github.com/${REPOSITORY}/releases/download/v${PI_RUN_VERSION}"
RELEASE_BASE=${PI_RUN_RELEASE_BASE_URL:-${DEFAULT_RELEASE_BASE}}

[ -n "${HOME:-}" ] || fail "HOME is not set"
require_command readlink
require_command realpath

DATA_HOME=${XDG_DATA_HOME:-"${HOME}/.local/share"}
INSTALL_ROOT_INPUT=${PI_RUN_INSTALL_ROOT:-"${DATA_HOME}/pi-run"}
BIN_DIR_INPUT=${PI_RUN_BIN_DIR:-"${HOME}/.local/bin"}
INSTALL_ROOT=$(realpath -m "${INSTALL_ROOT_INPUT}")
BIN_DIR=$(realpath -m "${BIN_DIR_INPUT}")
BIN_LINK="${BIN_DIR}/pi-run"

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

print_path_instruction() {
    quoted_bin_dir=$(shell_quote "${BIN_DIR}")
    echo "To use Pi-Run in this terminal now, run:"
    printf "  export PATH=%s:\"\$PATH\"\n" "${quoted_bin_dir}"
}

path_config_target() {
    configured_shell=${SHELL:-}
    shell_name=${configured_shell##*/}
    case "${shell_name}" in
        bash) printf '%s\n' "${HOME}/.bashrc" ;;
        zsh) printf '%s\n' "${HOME}/.zshrc" ;;
        sh|dash|ash|ksh|mksh) printf '%s\n' "${HOME}/.profile" ;;
        *) return 1 ;;
    esac
}

configure_shell_path() {
    case ":${PATH:-}:" in
        *":${BIN_DIR}:"*) return ;;
    esac

    config_target=$(path_config_target) || {
        echo "Executable directory is not on PATH; shell '${SHELL:-unknown}' is not supported for automatic configuration."
        print_path_instruction
        return
    }
    if [ -L "${config_target}" ] || { [ -e "${config_target}" ] && [ ! -f "${config_target}" ]; }; then
        echo "Executable directory is not on PATH; refusing unsafe shell configuration target: ${config_target}"
        print_path_instruction
        return
    fi
    if [ -e "${config_target}" ] && [ ! -w "${config_target}" ]; then
        echo "Executable directory is not on PATH; shell configuration is not writable: ${config_target}"
        print_path_instruction
        return
    fi
    quoted_bin_dir=$(shell_quote "${BIN_DIR}")
    if grep -Fqx '# >>> pi-run PATH >>>' "${config_target}" 2>/dev/null; then
        if ! grep -Fqx '# <<< pi-run PATH <<<' "${config_target}"; then
            echo "Executable directory is not on PATH; refusing incomplete Pi-Run block in ${config_target}."
        elif grep -Fqx "_pi_run_bin_dir=${quoted_bin_dir}" "${config_target}"; then
            echo "Pi-Run PATH configuration already exists in ${config_target}."
        else
            echo "Executable directory is not on PATH; refusing a Pi-Run block for a different directory in ${config_target}."
        fi
        print_path_instruction
        return
    fi
    if grep -Fqx '# <<< pi-run PATH <<<' "${config_target}" 2>/dev/null; then
        echo "Executable directory is not on PATH; refusing incomplete Pi-Run block in ${config_target}."
        print_path_instruction
        return
    fi

    configure_path=false
    case "${PATH_SETUP_MODE}" in
        yes) configure_path=true ;;
        no) ;;
        ask)
            if ( : </dev/tty ) 2>/dev/null; then
                printf '%s' "Add a managed Pi-Run PATH entry to ${config_target}? [Y/n] " >/dev/tty
                answer=
                IFS= read -r answer </dev/tty || answer=n
                case "${answer}" in
                    ''|y|Y|yes|YES|Yes) configure_path=true ;;
                esac
            else
                echo "No interactive terminal is available; shell PATH configuration was skipped."
            fi
            ;;
    esac

    if [ "${configure_path}" = true ]; then
        if {
            printf '\n# >>> pi-run PATH >>>\n'
            printf '_pi_run_bin_dir=%s\n' "${quoted_bin_dir}"
            cat <<'EOF'
case ":${PATH:-}:" in
    *":${_pi_run_bin_dir}:"*) ;;
    *) PATH="${_pi_run_bin_dir}:${PATH:-}"; export PATH ;;
esac
unset _pi_run_bin_dir
# <<< pi-run PATH <<<
EOF
        } >> "${config_target}"; then
            echo "Added Pi-Run PATH configuration to ${config_target}; new shells will load it."
        else
            echo "Could not update shell configuration: ${config_target}"
        fi
    else
        echo "Shell PATH configuration was not changed."
    fi
    print_path_instruction
}

case "${INSTALL_ROOT}" in
    /|"${HOME}") fail "refusing unsafe installation root: ${INSTALL_ROOT}" ;;
esac

managed_bin_link() {
    [ -L "${BIN_LINK}" ] || return 1
    link_target=$(readlink "${BIN_LINK}")
    case "${link_target}" in
        /*) resolved_target=$(realpath -m "${link_target}") ;;
        *) resolved_target=$(realpath -m "${BIN_DIR}/${link_target}") ;;
    esac
    case "${resolved_target}" in
        "${INSTALL_ROOT}"/*) return 0 ;;
        *) return 1 ;;
    esac
}

uninstall() {
    if [ -e "${BIN_LINK}" ] || [ -L "${BIN_LINK}" ]; then
        managed_bin_link || fail "refusing to remove unrelated executable: ${BIN_LINK}"
        rm -f -- "${BIN_LINK}"
    fi

    if [ -L "${INSTALL_ROOT}" ]; then
        fail "refusing to recursively remove a symlinked installation root: ${INSTALL_ROOT}"
    fi
    if [ -e "${INSTALL_ROOT}" ]; then
        [ -d "${INSTALL_ROOT}" ] || fail "installation root is not a directory: ${INSTALL_ROOT}"
        rm -rf -- "${INSTALL_ROOT}"
    fi

    echo "Pi-Run application files removed. User data was preserved under ${PI_RUN_HOME:-${HOME}/Pi-Run}."
}

case "${1:-}" in
    --uninstall)
        [ $# -eq 1 ] || fail "usage: install.sh [--uninstall]"
        uninstall
        exit 0
        ;;
    "") ;;
    *) fail "usage: install.sh [--uninstall]" ;;
esac

require_command sed
PATH_SETUP_MODE=${PI_RUN_CONFIGURE_PATH:-ask}
case "${PATH_SETUP_MODE}" in
    ask|yes|no) ;;
    *) fail "PI_RUN_CONFIGURE_PATH must be ask, yes, or no" ;;
esac

[ "$(uname -s)" = Linux ] || fail "only Linux is currently supported"
case "$(uname -m)" in
    x86_64|amd64) ;;
    *) fail "only Linux/amd64 is currently supported" ;;
esac

for command_name in curl docker sha256sum tar; do
    require_command "${command_name}"
done

if [ -L "${INSTALL_ROOT}" ]; then
    fail "installation root must not be a symlink: ${INSTALL_ROOT}"
fi
if [ -e "${INSTALL_ROOT}" ] && [ ! -d "${INSTALL_ROOT}" ]; then
    fail "installation root is not a directory: ${INSTALL_ROOT}"
fi
if [ -e "${BIN_LINK}" ] || [ -L "${BIN_LINK}" ]; then
    managed_bin_link || fail "refusing to overwrite unrelated executable: ${BIN_LINK}"
fi
INSTALL_METADATA="${INSTALL_ROOT}/bin-dir"
if [ -e "${INSTALL_METADATA}" ] || [ -L "${INSTALL_METADATA}" ]; then
    if [ ! -f "${INSTALL_METADATA}" ] || [ -L "${INSTALL_METADATA}" ]; then
        fail "installation metadata is unsafe: ${INSTALL_METADATA}"
    fi
    [ "$(cat "${INSTALL_METADATA}")" = "${BIN_DIR}" ] \
        || fail "installation metadata uses a different executable directory"
fi
case "${BIN_DIR}" in
    *'
'*) fail "executable directory must not contain a newline" ;;
esac
CURRENT_LINK="${INSTALL_ROOT}/current"
if { [ -e "${CURRENT_LINK}" ] || [ -L "${CURRENT_LINK}" ]; } && [ ! -L "${CURRENT_LINK}" ]; then
    fail "refusing to replace a non-symlink current path: ${CURRENT_LINK}"
fi

RELEASE_DIR="${INSTALL_ROOT}/releases/${PI_RUN_VERSION}"
if [ -e "${RELEASE_DIR}" ] || [ -L "${RELEASE_DIR}" ]; then
    fail "Pi-Run ${PI_RUN_VERSION} is already installed: ${RELEASE_DIR}"
fi

TEMP_DIR=$(mktemp -d)
STAGED_RELEASE=""
cleanup() {
    rm -rf -- "${TEMP_DIR}"
    if [ -n "${STAGED_RELEASE}" ]; then
        rm -rf -- "${STAGED_RELEASE}"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

download() {
    source_url=$1
    destination=$2
    asset_name=${source_url##*/}
    token=${GH_TOKEN:-${GITHUB_TOKEN:-}}

    if [ -n "${token}" ] && [ "${RELEASE_BASE}" = "${DEFAULT_RELEASE_BASE}" ]; then
        require_command jq
        auth_header="${TEMP_DIR}/github-auth-header"
        if [ ! -f "${auth_header}" ]; then
            carriage_return=$(printf '\r')
            case "${token}" in
                *"${carriage_return}"*|*'
'*) fail "GitHub token contains an invalid newline" ;;
            esac
            printf 'Authorization: Bearer %s\n' "${token}" > "${auth_header}"
            chmod 0600 "${auth_header}"
        fi
        release_metadata="${TEMP_DIR}/github-release.json"
        if [ ! -f "${release_metadata}" ]; then
            if ! curl -fsSL \
                -H "@${auth_header}" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                -o "${release_metadata}" \
                "https://api.github.com/repos/${REPOSITORY}/releases/tags/v${PI_RUN_VERSION}" 2>/dev/null; then
                fail "could not access GitHub release v${PI_RUN_VERSION}; verify the release and authentication"
            fi
        fi
        asset_url=$(jq -er --arg name "${asset_name}" \
            '[.assets[] | select(.name == $name)] | if length == 1 then .[0].url else error("release asset missing or duplicated") end' \
            "${release_metadata}") \
            || fail "private release asset is missing or duplicated: ${asset_name}"
        if ! curl -fsSL \
            -H "@${auth_header}" \
            -H "Accept: application/octet-stream" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -o "${destination}" \
            "${asset_url}" 2>/dev/null; then
            fail "could not download authenticated release asset: ${asset_name}"
        fi
    elif ! curl -fsSL -o "${destination}" "${source_url}" 2>/dev/null; then
        if [ "${RELEASE_BASE}" = "${DEFAULT_RELEASE_BASE}" ]; then
            fail "release asset is unavailable or private; set GH_TOKEN or GITHUB_TOKEN: ${asset_name}"
        fi
        fail "could not download release asset: ${asset_name}"
    fi
}

echo "Downloading Pi-Run ${PI_RUN_VERSION}..."
download "${RELEASE_BASE}/${ARCHIVE}" "${TEMP_DIR}/${ARCHIVE}"
download "${RELEASE_BASE}/${CHECKSUM}" "${TEMP_DIR}/${CHECKSUM}"
(
    cd "${TEMP_DIR}"
    sha256sum -c "${CHECKSUM}"
)

tar -xzf "${TEMP_DIR}/${ARCHIVE}" -C "${TEMP_DIR}"
PACKAGE_DIR="${TEMP_DIR}/pi-run-${PI_RUN_VERSION}"
if [ ! -d "${PACKAGE_DIR}" ] || [ -L "${PACKAGE_DIR}" ]; then
    fail "release archive has no expected package directory"
fi
[ -x "${PACKAGE_DIR}/bin/pi-run" ] || fail "release archive has no executable launcher"
for COMPONENT_NAME in doctor.sh profiles.sh restore.sh sessions.sh skills.sh snapshots.sh upgrade.sh workspaces.sh; do
    COMPONENT="${PACKAGE_DIR}/lib/pi-run/${COMPONENT_NAME}"
    if [ ! -f "${COMPONENT}" ] || [ -L "${COMPONENT}" ] || [ "$(stat -c %h "${COMPONENT}")" != 1 ]; then
        fail "release archive has no safe component: ${COMPONENT_NAME}"
    fi
done
if [ ! -f "${PACKAGE_DIR}/install.sh" ] || [ -L "${PACKAGE_DIR}/install.sh" ]; then
    fail "release archive has no safe installer"
fi
[ "$(tr -d '\r\n' < "${PACKAGE_DIR}/VERSION")" = "${PI_RUN_VERSION}" ] \
    || fail "release archive version does not match installer"
if find "${PACKAGE_DIR}" -mindepth 1 ! -type d ! -type f -print -quit | grep -q .; then
    fail "release archive contains a symlink or special file"
fi

# Pull both version-matched images before changing the active installation.
# Private packages require a prior `docker login ghcr.io`; the installer never
# handles registry credentials.
for IMAGE in "${RUNTIME_IMAGE}" "${EGRESS_IMAGE}"; do
    echo "Pulling ${IMAGE}..."
    docker pull "${IMAGE}"
done

mkdir -p "${INSTALL_ROOT}/releases" "${BIN_DIR}"
STAGED_RELEASE="${INSTALL_ROOT}/releases/.${PI_RUN_VERSION}.tmp.$$"
if [ -e "${STAGED_RELEASE}" ] || [ -L "${STAGED_RELEASE}" ]; then
    fail "staging path already exists: ${STAGED_RELEASE}"
fi
cp -R "${PACKAGE_DIR}" "${STAGED_RELEASE}"
mv "${STAGED_RELEASE}" "${RELEASE_DIR}"
STAGED_RELEASE=""

METADATA_TMP="${INSTALL_ROOT}/.bin-dir.tmp.$$"
printf '%s\n' "${BIN_DIR}" > "${METADATA_TMP}"
chmod 0600 "${METADATA_TMP}"
mv -Tf "${METADATA_TMP}" "${INSTALL_METADATA}"

CURRENT_TMP="${INSTALL_ROOT}/.current.tmp.$$"
BIN_TMP="${BIN_DIR}/.pi-run.tmp.$$"
rm -f -- "${CURRENT_TMP}" "${BIN_TMP}"
ln -s "releases/${PI_RUN_VERSION}" "${CURRENT_TMP}"
mv -Tf "${CURRENT_TMP}" "${INSTALL_ROOT}/current"
ln -s "${INSTALL_ROOT}/current/bin/pi-run" "${BIN_TMP}"
mv -Tf "${BIN_TMP}" "${BIN_LINK}"

echo "Pi-Run ${PI_RUN_VERSION} installed at ${INSTALL_ROOT}."
echo "Executable: ${BIN_LINK}"
configure_shell_path
