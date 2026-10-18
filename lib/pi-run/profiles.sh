# SPDX-License-Identifier: MIT
# shellcheck shell=bash

list_profiles() {
    local profiles_dir="${PI_RUN_HOME_RESOLVED}/profiles"
    local profile_dir name default_profile name_width=4
    local -a names=()

    default_profile="$(read_home_default_profile)" \
        || fail "home configuration is missing, invalid, or unsafe: ${PI_RUN_HOME_RESOLVED}/config.json"
    if [[ -d "${profiles_dir}" ]]; then
        for profile_dir in "${profiles_dir}"/*; do
            if [[ -d "${profile_dir}" && -f "${profile_dir}/profile.json" ]]; then
                name="$(basename "${profile_dir}")"
                names+=("${name}")
                (( ${#name} > name_width )) && name_width=${#name}
            fi
        done
    fi

    printf '%-*s  %s\n' "${name_width}" NAME DEFAULT
    for name in "${names[@]}"; do
        if [[ "${name}" == "${default_profile}" ]]; then
            printf '%-*s  yes\n' "${name_width}" "${name}"
        else
            printf '%-*s  -\n' "${name_width}" "${name}"
        fi
    done
}

resolve_named_profile_directory() {
    local name="$1"
    local profiles_root profile_input profile_dir
    validate_profile_name "${name}"
    profiles_root="$(realpath "${PI_RUN_HOME_RESOLVED}/profiles")"
    profile_input="${profiles_root}/${name}"
    [[ -d "${profile_input}" && ! -L "${profile_input}" ]] || fail "unknown or unsafe profile: ${name}"
    profile_dir="$(realpath "${profile_input}")"
    case "${profile_dir}" in
        "${profiles_root}"/*) ;;
        *) fail "profile escapes Pi-Run home: ${name}" ;;
    esac
    [[ -f "${profile_dir}/profile.json" ]] \
        || fail "profile configuration is missing: ${profile_dir}/profile.json"
    printf '%s\n' "${profile_dir}"
}

resolve_profile_directory() {
    resolve_named_profile_directory "${PROFILE}"
}

validate_profile_config_file() {
    local config="$1"
    local name="$2"
    if ! jq -e --arg name "${name}" '
        def hostname:
            type == "string" and length <= 253 and
            test("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$") and
            (test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$") | not);
        def ports:
            (has("tcpPorts") | not) or
            ((.tcpPorts | type == "array") and (.tcpPorts | length > 0) and
             ((.tcpPorts | unique | length) == (.tcpPorts | length)) and
             all(.tcpPorts[]; type == "number" and floor == . and . >= 1 and . <= 65535));
        def rule:
            type == "object" and
            ((keys - ["cidr", "domain", "host", "tcpPorts"]) | length == 0) and
            ([has("host"), has("domain"), has("cidr")] | map(select(.)) | length == 1) and
            ((has("host") | not) or (.host | hostname)) and
            ((has("domain") | not) or (.domain | hostname)) and
            ((has("cidr") | not) or
                (.cidr | type == "string" and test("^[0-9A-Fa-f:.]+/[0-9]{1,3}$"))) and
            ports;
        .schemaVersion == 1 and
        .name == $name and
        ((has("skills") | not) or .skills == null or
            ((.skills | type == "array") and
             ((.skills | unique | length) == (.skills | length)) and
             all(.skills[];
                (type == "string") and (length <= 64) and
                test("^[a-z0-9]+(-[a-z0-9]+)*$") and
                . != "pi-run" and . != "profile-management"))) and
        (has("guardian") | not) and
        ((has("network") | not) or
            ((.network | type == "object") and
             (if .network.mode == "restricted" then
                ((.network | keys) == ["mode"] or
                 ((.network | keys) == ["allow", "mode"] and
                  (.network.allow | type == "array") and
                  ((.network.allow | unique | length) == (.network.allow | length)) and
                  all(.network.allow[]; rule)))
              else
                ((.network.mode == "host" or .network.mode == "offline") and
                 (.network | keys) == ["mode"])
              end))) and
        (.resources | type == "object") and
        (.resources | keys == ["shared"]) and
        (.resources.shared == "disabled" or .resources.shared == "read-write")
    ' "${config}" >/dev/null; then
        return 1
    fi
}

validate_profile_config() {
    local profile_dir="$1"
    local name="$2"
    local config="${profile_dir}/profile.json"
    validate_profile_config_file "${config}" "${name}" \
        || fail "invalid profile configuration: ${config}"
}

validate_profile_definition_files() {
    local profile_dir="$1"
    local file path guardian_dir="${profile_dir}/guardian"
    [[ -d "${guardian_dir}" && ! -L "${guardian_dir}" ]] \
        || fail "Guardian definition directory must be a non-symlink directory: ${guardian_dir}"
    [[ "$(realpath "${guardian_dir}")" == "${guardian_dir}" ]] \
        || fail "Guardian definition directory escapes its profile: ${guardian_dir}"
    for file in profile.json AGENTS.md guardian/guardian.md; do
        path="${profile_dir}/${file}"
        [[ -f "${path}" && ! -L "${path}" ]] \
            || fail "profile definition must be a regular non-symlink file: ${path}"
        [[ "$(stat -c %h "${path}")" == 1 ]] \
            || fail "profile definition must not be hard-linked: ${path}"
        case "$(realpath "${path}")" in
            "${profile_dir}"/*) ;;
            *) fail "profile definition escapes its directory: ${path}" ;;
        esac
    done
}

materialize_profile_definition() {
    local source_dir="$1"
    local name="$2"
    local profiles_root target staging
    validate_profile_name "${name}"
    profiles_root="$(realpath "${PI_RUN_HOME_RESOLVED}/profiles")"
    target="${profiles_root}/${name}"
    [[ ! -e "${target}" && ! -L "${target}" ]] \
        || fail "profile already exists: ${name}"

    staging="${profiles_root}/.${name}.tmp.$$"
    [[ ! -e "${staging}" ]] || fail "profile staging path already exists: ${staging}"
    trap 'rm -rf "${staging:-}"' EXIT
    mkdir -m 0700 "${staging}"
    jq --arg name "${name}" '.name = $name | .skills = null' \
        "${source_dir}/profile.json" > "${staging}/profile.json"
    chmod 0600 "${staging}/profile.json"
    install -m 0600 "${source_dir}/AGENTS.md" "${staging}/AGENTS.md"
    mkdir -m 0700 "${staging}/credentials" "${staging}/sessions" "${staging}/guardian" "${staging}/skills"
    install -m 0600 "${source_dir}/guardian/guardian.md" "${staging}/guardian/guardian.md"
    cp -a "${source_dir}/skills/." "${staging}/skills/"
    chmod -R u+rwX,go-w "${staging}/skills"
    mv "${staging}" "${target}"
    trap - EXIT
}

create_profile() {
    local name="$1"
    local source_name="$2"
    local source_dir
    validate_profile_name "${name}"
    validate_profile_name "${source_name}"
    source_dir="$(resolve_named_profile_directory "${source_name}")"
    validate_profile_config "${source_dir}" "${source_name}"
    validate_profile_definition_files "${source_dir}"
    validate_profile_skills_directory "${source_dir}"
    materialize_profile_definition "${source_dir}" "${name}"
    printf 'Created profile %s from %s.\n' "${name}" "${source_name}"
}

set_default_profile() {
    local name="$1"
    local profile_dir config current staging
    validate_profile_name "${name}"
    profile_dir="$(resolve_named_profile_directory "${name}")"
    validate_profile_config "${profile_dir}" "${name}"
    validate_profile_definition_files "${profile_dir}"
    validate_profile_skills_directory "${profile_dir}"

    config="${PI_RUN_HOME_RESOLVED}/config.json"
    current="$(read_home_default_profile)" \
        || fail "home configuration is missing, invalid, or unsafe: ${config}"
    if [[ "${current}" == "${name}" ]]; then
        printf 'Default profile: %s\n' "${name}"
        return 0
    fi

    staging="${PI_RUN_HOME_RESOLVED}/.config.json.tmp.$$"
    [[ ! -e "${staging}" && ! -L "${staging}" ]] \
        || fail "home configuration staging path already exists: ${staging}"
    trap 'rm -f "${staging:-}"' RETURN
    jq --arg name "${name}" '.defaultProfile = $name' "${config}" > "${staging}"
    chmod 0600 "${staging}"
    mv "${staging}" "${config}"
    trap - RETURN
    printf 'Default profile: %s\n' "${name}"
}

show_profile_network() {
    local profile_dir config mode source rule_count
    profile_dir="$(resolve_profile_directory)"
    validate_profile_config "${profile_dir}" "${PROFILE}"
    validate_profile_definition_files "${profile_dir}"
    config="${profile_dir}/profile.json"
    if jq -e 'has("network")' "${config}" >/dev/null; then
        mode="$(jq -r '.network.mode' "${config}")"
        source=configured
    else
        mode=host
        source="compatibility default"
    fi
    rule_count="$(jq -r '(.network.allow // []) | length' "${config}")"
    printf 'Profile: %s\nNetwork mode: %s (%s)\nManual allow rules: %s\n' \
        "${PROFILE}" "${mode}" "${source}" "${rule_count}"
}

set_profile_network_mode() {
    local mode="$1" discard_rules="$2"
    local profile_dir config current_mode has_network rule_count staging profile_lock_fd
    case "${mode}" in
        host|offline|restricted) ;;
        *) fail "invalid network mode: ${mode}" ;;
    esac
    if [[ "${discard_rules}" == true && "${mode}" == restricted ]]; then
        fail "--discard-rules is valid only with host or offline mode"
    fi

    profile_dir="$(resolve_profile_directory)"
    exec {profile_lock_fd}<"${profile_dir}" \
        || fail "could not open profile directory for locking: ${profile_dir}"
    flock -x "${profile_lock_fd}" \
        || fail "could not lock profile directory: ${profile_dir}"
    validate_profile_config "${profile_dir}" "${PROFILE}"
    validate_profile_definition_files "${profile_dir}"
    config="${profile_dir}/profile.json"
    current_mode="$(jq -r '.network.mode // "host"' "${config}")"
    has_network="$(jq -r 'has("network")' "${config}")"
    rule_count="$(jq -r '(.network.allow // []) | length' "${config}")"

    if [[ "${mode}" != restricted && "${rule_count}" -gt 0 && "${discard_rules}" == false ]]; then
        fail "network mode change would discard ${rule_count} manual allow rule(s); use --discard-rules"
    fi
    if [[ "${current_mode}" == "${mode}" && "${has_network}" == true ]]; then
        printf 'Network mode for %s: %s (unchanged)\n' "${PROFILE}" "${mode}"
        printf 'Changes apply to new launches; running sessions are unchanged.\n'
        return 0
    fi

    staging="${profile_dir}/.profile.json.tmp.$$"
    [[ ! -e "${staging}" && ! -L "${staging}" ]] \
        || fail "profile configuration staging path already exists: ${staging}"
    trap 'rm -f "${staging:-}"' RETURN
    if ! jq --arg mode "${mode}" '.network = {mode: $mode}' "${config}" > "${staging}"; then
        rm -f "${staging}"
        fail "could not stage profile network mode"
    fi
    chmod 0600 "${staging}"
    if ! validate_profile_config_file "${staging}" "${PROFILE}"; then
        rm -f "${staging}"
        fail "staged profile network configuration is invalid"
    fi
    mv "${staging}" "${config}"
    trap - RETURN
    printf 'Network mode for %s: %s\n' "${PROFILE}" "${mode}"
    if [[ "${rule_count}" -gt 0 ]]; then
        printf 'Discarded manual allow rules: %s\n' "${rule_count}"
    fi
    printf 'Changes apply to new launches; running sessions are unchanged.\n'
}

run_profile_ssh_key_command() {
    local action="$1" profile_dir image network mount
    shift
    local -a interactive=()
    profile_dir="$(resolve_profile_directory)"
    validate_profile_config "${profile_dir}" "${PROFILE}"
    validate_profile_definition_files "${profile_dir}"
    image="${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}"

    case "${action}" in
        list)
            network=none
            mount="type=bind,src=${profile_dir},dst=/profile,readonly"
            ;;
        add|remove)
            if [[ "${action}" == add ]]; then
                network=host
            else
                network=none
            fi
            mount="type=bind,src=${profile_dir},dst=/profile"
            interactive=(-it)
            ;;
        *) fail "unsupported SSH key command: ${action}" ;;
    esac

    docker run \
        --rm \
        "${interactive[@]}" \
        --cap-drop=ALL \
        --cap-add=CHOWN \
        --cap-add=SETUID \
        --cap-add=SETGID \
        --cap-add=DAC_READ_SEARCH \
        --security-opt=no-new-privileges \
        --network "${network}" \
        --mount "${mount}" \
        --env "HOST_UID=$(id -u)" \
        --env "HOST_GID=$(id -g)" \
        --env PI_RUN_PROFILE_DIR=/profile \
        --env PI_RUN_SKIP_SSH_CONFIG=1 \
        --entrypoint /usr/local/bin/entrypoint.sh \
        "${image}" \
        /usr/local/bin/ssh-credentials "${action}" "$@"
}

list_profile_ssh_keys() {
    run_profile_ssh_key_command list
}

add_profile_ssh_key() {
    run_profile_ssh_key_command add "$1"
}

remove_profile_ssh_key() {
    run_profile_ssh_key_command remove "$1"
}

