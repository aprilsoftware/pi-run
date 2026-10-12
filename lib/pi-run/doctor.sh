# SPDX-License-Identifier: MIT
# shellcheck shell=bash

DOCTOR_FAILURES=0
DOCTOR_WARNINGS=0

doctor_ok() {
    printf 'OK    %s\n' "$*"
}

doctor_warn() {
    DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1))
    printf 'WARN  %s\n' "$*"
}

doctor_fail() {
    DOCTOR_FAILURES=$((DOCTOR_FAILURES + 1))
    printf 'FAIL  %s\n' "$*"
}

doctor_wsl_home_filesystem() {
    local path="${PI_RUN_HOME_RESOLVED}" filesystem
    # Check the nearest existing ancestor without creating an uninitialized home.
    while [[ ! -e "${path}" && "${path}" != / ]]; do
        path="${path%/*}"
        path="${path:-/}"
    done
    if ! filesystem="$(stat -f -c %T -- "${path}" 2>/dev/null)"; then
        doctor_warn "could not determine WSL data-home filesystem: ${path}"
        return 0
    fi
    case "${filesystem}" in
        9p|drvfs|ntfs|ntfs3)
            doctor_fail \
                "WSL data home is Windows-backed (${filesystem});" \
                "use a Linux-side folder such as ~/Pi-Run, accessible through Windows Explorer"
            ;;
        *) doctor_ok "WSL data-home filesystem: ${filesystem}" ;;
    esac
}

run_doctor() {
    local command_name image profile_dir mode configured_default default_dir kernel
    local wsl=false
    image="${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}"

    if [[ "$(uname -s)" == Linux && "$(uname -m)" =~ ^(x86_64|amd64)$ ]]; then
        kernel="$(uname -r)"
        case "${kernel,,}" in
            *microsoft-standard*|*wsl2*)
                wsl=true
                doctor_ok "platform: WSL2 Linux/amd64"
                ;;
            *-microsoft)
                wsl=true
                doctor_fail \
                    "WSL1 is unsupported; convert the distribution to WSL2 from Windows using" \
                    "wsl --set-version <distribution> 2"
                ;;
            *)
                doctor_ok "platform: Linux/amd64"
                if [[ "${kernel,,}" == *microsoft* ||
                      -n "${WSL_INTEROP:-}${WSL_DISTRO_NAME:-}" ]]; then
                    wsl=true
                    doctor_warn \
                        "unrecognized WSL kernel; confirm WSL2 using" \
                        "wsl --list --verbose in Windows"
                fi
                ;;
        esac
        if [[ "${wsl}" == true ]]; then
            doctor_warn \
                "WSL integration is experimental; Docker Engine can run inside Ubuntu/Debian" \
                "without Docker Desktop; host networking refers to the Docker host, not automatically Windows"
        fi
    else
        doctor_fail "unsupported platform: $(uname -s)/$(uname -m)"
    fi

    for command_name in docker flock jq readlink realpath sha256sum stat sync timeout; do
        if command -v "${command_name}" >/dev/null 2>&1; then
            doctor_ok "command available: ${command_name}"
        else
            doctor_fail "required command unavailable: ${command_name}"
        fi
    done

    if [[ "${wsl}" == true ]] && command -v stat >/dev/null 2>&1; then
        doctor_wsl_home_filesystem
    fi

    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        doctor_ok "workspace UUID source available: Linux kernel"
    elif command -v uuidgen >/dev/null 2>&1; then
        doctor_ok "workspace UUID source available: uuidgen"
    else
        doctor_fail "no workspace UUID source is available"
    fi

    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            doctor_ok "Docker daemon is reachable"
            if docker image inspect "${image}" >/dev/null 2>&1; then
                doctor_ok "runtime image available: ${image}"
            else
                doctor_fail "runtime image unavailable locally: ${image}; run: docker pull ${image}"
            fi
        else
            doctor_fail "Docker daemon is unavailable"
            if [[ "${wsl}" == true ]]; then
                doctor_warn \
                    "in WSL, check Docker Engine service and normal-user access with" \
                    "systemctl status docker and docker info"
            fi
        fi
    fi

    if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
        doctor_ok "CA bundle available"
    else
        doctor_fail "CA bundle missing: /etc/ssl/certs/ca-certificates.crt"
    fi

    for command_name in \
        "${VERSION_FILE}" \
        "${PROFILE_TEMPLATE_ROOT}/default/profile.json" \
        "${PROFILE_TEMPLATE_ROOT}/default/AGENTS.md" \
        "${PROFILE_TEMPLATE_ROOT}/default/guardian/guardian.md"; do
        if [[ -f "${command_name}" && ! -L "${command_name}" ]]; then
            doctor_ok "installed resource: ${command_name#"${INSTALL_ROOT}"/}"
        else
            doctor_fail "installed resource missing or unsafe: ${command_name}"
        fi
    done

    if [[ ! -e "${PI_RUN_HOME_RESOLVED}" ]]; then
        doctor_warn "Pi-Run home is not initialized: ${PI_RUN_HOME_RESOLVED}"
    elif [[ -L "${PI_RUN_HOME_RESOLVED}" || ! -d "${PI_RUN_HOME_RESOLVED}" ]]; then
        doctor_fail "Pi-Run home is not a safe directory: ${PI_RUN_HOME_RESOLVED}"
    else
        mode="$(stat -c '%a' "${PI_RUN_HOME_RESOLVED}" 2>/dev/null || true)"
        if [[ "${mode}" == 700 ]]; then
            doctor_ok "Pi-Run home permissions: 700"
        else
            doctor_fail "Pi-Run home permissions must be 700, found: ${mode:-unknown}"
        fi

        if command -v jq >/dev/null 2>&1 && configured_default="$(read_home_default_profile)"; then
            doctor_ok "home configuration is valid; default profile: ${configured_default}"
            if (default_dir="$(resolve_named_profile_directory "${configured_default}")" &&
                validate_profile_config "${default_dir}" "${configured_default}" &&
                validate_profile_definition_files "${default_dir}" &&
                validate_profile_skills_directory "${default_dir}") >/dev/null 2>&1; then
                doctor_ok "configured default profile is usable: ${configured_default}"
            else
                doctor_fail "configured default profile is missing, unsafe, or invalid: ${configured_default}"
            fi
        else
            doctor_fail "home configuration is missing or invalid"
        fi

        profile_dir="${PI_RUN_HOME_RESOLVED}/profiles/${PROFILE}"
        if [[ -L "${profile_dir}" || ! -d "${profile_dir}" ]]; then
            doctor_fail "selected profile is missing or unsafe: ${PROFILE}"
        else
            mode="$(stat -c '%a' "${profile_dir}" 2>/dev/null || true)"
            if [[ "${mode}" == 700 ]]; then
                doctor_ok "profile permissions: 700"
            else
                doctor_fail "profile permissions must be 700, found: ${mode:-unknown}"
            fi
            if [[ -f "${profile_dir}/AGENTS.md" && ! -L "${profile_dir}/AGENTS.md" &&
                  -d "${profile_dir}/guardian" && ! -L "${profile_dir}/guardian" &&
                  -f "${profile_dir}/guardian/guardian.md" && ! -L "${profile_dir}/guardian/guardian.md" ]]; then
                doctor_ok "selected profile instructions are present: ${PROFILE}"
            else
                doctor_fail "selected profile instructions are missing or unsafe: ${PROFILE}"
            fi
            if command -v jq >/dev/null 2>&1 &&
                (validate_profile_config "${profile_dir}" "${PROFILE}" >/dev/null 2>&1); then
                doctor_ok "selected profile configuration is valid: ${PROFILE}"
            else
                doctor_fail "selected profile configuration is invalid: ${PROFILE}"
            fi
        fi
    fi

    if (( DOCTOR_FAILURES > 0 )); then
        printf 'Doctor: FAIL (%d failure(s), %d warning(s))\n' "${DOCTOR_FAILURES}" "${DOCTOR_WARNINGS}"
        return 1
    fi
    printf 'Doctor: PASS (%d warning(s))\n' "${DOCTOR_WARNINGS}"
}
