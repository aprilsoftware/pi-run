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
            ((keys - ["cidr", "domain", "host", "internet", "tcpPorts"]) | length == 0) and
            ([has("host"), has("domain"), has("cidr"), has("internet")] | map(select(.)) | length == 1) and
            ((has("host") | not) or (.host | hostname)) and
            ((has("domain") | not) or (.domain | hostname)) and
            ((has("cidr") | not) or
                (.cidr | type == "string" and test("^[0-9A-Fa-f:.]+/[0-9]{1,3}$"))) and
            ((has("internet") | not) or .internet == true) and
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
                  ([.network.allow[] | select(has("internet"))] | length <= 1) and
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

list_profile_network_rules() {
    local profile_dir config rule_count
    profile_dir="$(resolve_profile_directory)"
    validate_profile_config "${profile_dir}" "${PROFILE}"
    validate_profile_definition_files "${profile_dir}"
    config="${profile_dir}/profile.json"
    rule_count="$(jq -r '(.network.allow // []) | length' "${config}")"
    printf 'Profile: %s\nManual allow rules: %s\n' "${PROFILE}" "${rule_count}"
    jq -r '
        def selector:
            if .host then "host=" + .host
            elif .domain then "domain=" + .domain
            elif .cidr then "cidr=" + .cidr
            else "internet=public"
            end;
        def ports:
            if .tcpPorts then (.tcpPorts | sort | map(tostring) | join("|"))
            else "all"
            end;
        (.network.allow // [])[] | selector + " tcp=" + ports
    ' "${config}"
}

validate_network_rule_hostname() {
    local value="$1"
    jq -en --arg value "${value}" '
        $value | type == "string" and length <= 253 and
        test("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$") and
        (test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$") | not)
    ' >/dev/null
}

normalize_network_rule_cidr() {
    local value="$1" image output
    image="${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}"
    docker image inspect "${image}" >/dev/null 2>&1 \
        || fail "runtime image is unavailable for CIDR normalization: ${image}"
    if ! output="$(docker run --rm \
        --pull never \
        --network none \
        --user "$(id -u):$(id -g)" \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --read-only \
        --entrypoint /usr/local/bin/pi-run-network-policy-resolver \
        "${image}" --normalize-cidr "${value}")"; then
        fail "invalid or blocked CIDR network rule"
    fi
    [[ -n "${output}" && "${output}" != *$'\n'* &&
       "${output}" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] \
        || fail "CIDR normalizer returned invalid output"
    printf '%s\n' "${output}"
}

change_profile_network_rule() {
    local action="$1" selector="$2" destination="$3"
    shift 3
    local all_tcp=false argument port ports_json rule profile_dir config current_mode
    local match_count staging profile_lock_fd verb
    local -a ports=()
    declare -A seen_ports=()

    case "${action}" in add|remove) ;; *) fail "invalid network rule action: ${action}" ;; esac
    case "${selector}" in
        host|domain)
            destination="${destination,,}"
            validate_network_rule_hostname "${destination}" \
                || fail "invalid ${selector} network rule: ${destination}"
            ;;
        cidr)
            destination="$(normalize_network_rule_cidr "${destination}")"
            ;;
        internet)
            [[ -z "${destination}" ]] || fail "internet network rules do not take a destination"
            ;;
        *) fail "unsupported network rule selector: ${selector}" ;;
    esac

    while [[ $# -gt 0 ]]; do
        argument="$1"
        case "${argument}" in
            --tcp-port)
                [[ $# -ge 2 ]] || fail "--tcp-port requires a value"
                port="$2"
                if [[ ! "${port}" =~ ^[0-9]{1,5}$ ]] ||
                   (( 10#${port} < 1 || 10#${port} > 65535 )); then
                    fail "invalid TCP port: ${port}"
                fi
                port="$((10#${port}))"
                [[ -z "${seen_ports[${port}]:-}" ]] || fail "duplicate TCP port: ${port}"
                seen_ports["${port}"]=1
                ports+=("${port}")
                shift 2
                ;;
            --all-tcp)
                [[ "${all_tcp}" == false ]] || fail "duplicate --all-tcp"
                all_tcp=true
                shift
                ;;
            *) fail "unknown network rule option: ${argument}" ;;
        esac
    done
    if [[ "${all_tcp}" == true && ${#ports[@]} -gt 0 ]]; then
        fail "--all-tcp cannot be combined with --tcp-port"
    fi
    if [[ "${selector}" == internet && "${action}" == remove ]]; then
        [[ "${all_tcp}" == false && ${#ports[@]} -eq 0 ]] \
            || fail "internet rule removal does not take port options"
    elif [[ "${all_tcp}" == false && ${#ports[@]} -eq 0 ]]; then
        fail "specify at least one --tcp-port or --all-tcp"
    fi

    if [[ "${selector}" == internet && "${action}" == remove ]]; then
        rule=''
    elif [[ "${all_tcp}" == true ]]; then
        if [[ "${selector}" == internet ]]; then
            rule='{"internet":true}'
        else
            rule="$(jq -cn --arg selector "${selector}" --arg destination "${destination}" \
                '{($selector): $destination}')"
        fi
    else
        ports_json="$(printf '%s\n' "${ports[@]}" | jq -s 'sort')"
        if [[ "${selector}" == internet ]]; then
            rule="$(jq -cn --argjson ports "${ports_json}" \
                '{internet: true, tcpPorts: $ports}')"
        else
            rule="$(jq -cn --arg selector "${selector}" --arg destination "${destination}" \
                --argjson ports "${ports_json}" '{($selector): $destination, tcpPorts: $ports}')"
        fi
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
    [[ "${current_mode}" == restricted ]] \
        || fail "manual network rules require restricted mode; current mode is ${current_mode}"
    if [[ "${selector}" == internet ]]; then
        match_count="$(jq -r '[.network.allow[]? | select(.internet == true)] | length' "${config}")"
        if [[ "${action}" == remove && "${match_count}" -gt 0 ]]; then
            rule="$(jq -c '.network.allow[] | select(.internet == true)' "${config}")"
        fi
    else
        match_count="$(jq -r --argjson rule "${rule}" '
            def canonical: if .tcpPorts then .tcpPorts |= sort else . end;
            [(.network.allow // [])[] | select((. | canonical) == $rule)] | length
        ' "${config}")"
    fi
    if [[ "${action}" == add && "${match_count}" -gt 0 ]]; then
        fail "manual network rule already exists"
    fi
    if [[ "${action}" == remove && "${match_count}" -eq 0 ]]; then
        fail "manual network rule does not exist"
    fi

    staging="${profile_dir}/.profile.json.tmp.$$"
    [[ ! -e "${staging}" && ! -L "${staging}" ]] \
        || fail "profile configuration staging path already exists: ${staging}"
    trap 'rm -f "${staging:-}"' RETURN
    if [[ "${action}" == add ]]; then
        jq --argjson rule "${rule}" \
            '.network.allow = ((.network.allow // []) + [$rule])' "${config}" > "${staging}"
    elif [[ "${selector}" == internet ]]; then
        jq '
            .network.allow = [(.network.allow // [])[] | select(.internet != true)] |
            if (.network.allow | length) == 0 then del(.network.allow) else . end
        ' "${config}" > "${staging}"
    else
        jq --argjson rule "${rule}" '
            def canonical: if .tcpPorts then .tcpPorts |= sort else . end;
            .network.allow = [(.network.allow // [])[] | select((. | canonical) != $rule)] |
            if (.network.allow | length) == 0 then del(.network.allow) else . end
        ' "${config}" > "${staging}"
    fi
    chmod 0600 "${staging}"
    if ! validate_profile_config_file "${staging}" "${PROFILE}"; then
        rm -f "${staging}"
        fail "staged manual network rule is invalid"
    fi
    mv "${staging}" "${config}"
    trap - RETURN
    port="$(jq -r 'if .tcpPorts then (.tcpPorts | map(tostring) | join("|")) else "all" end' <<< "${rule}")"
    [[ "${action}" == add ]] && verb=Added || verb=Removed
    [[ "${selector}" == internet ]] && destination=public
    printf '%s manual network rule for %s: %s=%s tcp=%s\n' \
        "${verb}" "${PROFILE}" "${selector}" "${destination}" "${port}"
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

ensure_guardian_log_migration_directory() {
    local path="$1"
    if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        mkdir -m 0700 "${path}" || fail "could not create Guardian log migration directory: ${path}"
    fi
    [[ -d "${path}" && ! -L "${path}" && "$(realpath "${path}")" == "${path}" ]] \
        || fail "Guardian log migration directory is unsafe: ${path}"
    [[ "$(stat -c %a "${path}")" == 700 && "$(stat -c %u "${path}")" == "$(id -u)" ]] \
        || fail "Guardian log migration directory must be private and owned by the current user: ${path}"
}

validate_guardian_log_migration_file() {
    local path="$1" parent="$2"
    [[ -f "${path}" && ! -L "${path}" && "$(stat -c %h "${path}")" == 1 ]] \
        || fail "Guardian log migration file is unsafe: ${path}"
    [[ "$(stat -c %a "${path}")" == 600 && "$(stat -c %u "${path}")" == "$(id -u)" ]] \
        || fail "Guardian log migration file must be private and owned by the current user: ${path}"
    [[ "$(dirname "$(realpath "${path}")")" == "${parent}" ]] \
        || fail "Guardian log migration file escapes its directory: ${path}"
}

migrate_profile_guardian_logs() {
    local profile_dir="$1" guardian_dir logs_dir client_dir staging legacy source target entry name
    local -a source_names=(guardian.log guardian.log.1 guardian.log.2)
    local -a target_names=(events.jsonl events.jsonl.1 events.jsonl.2)
    local index present=false moved=0
    guardian_dir="${profile_dir}/guardian"
    logs_dir="${profile_dir}/logs"
    client_dir="${logs_dir}/guardian"
    staging="${client_dir}/.legacy-migration"
    legacy="${client_dir}/legacy"

    for source in "${source_names[@]}"; do
        [[ -e "${guardian_dir}/${source}" || -L "${guardian_dir}/${source}" ]] && present=true
    done
    [[ -e "${staging}" || -L "${staging}" ]] && present=true
    [[ -e "${legacy}" || -L "${legacy}" ]] && present=true
    [[ "${present}" == true ]] || return 0

    ensure_guardian_log_migration_directory "${logs_dir}"
    ensure_guardian_log_migration_directory "${client_dir}"
    if [[ -e "${legacy}" || -L "${legacy}" ]]; then
        [[ ! -e "${staging}" && ! -L "${staging}" ]] \
            || fail "Guardian legacy log migration has both staging and final directories: ${profile_dir}"
        for source in "${source_names[@]}"; do
            [[ ! -e "${guardian_dir}/${source}" && ! -L "${guardian_dir}/${source}" ]] \
                || fail "Guardian legacy log destination collides with an existing source: ${profile_dir}"
        done
        ensure_guardian_log_migration_directory "${legacy}"
        for entry in "${legacy}"/*; do
            [[ -e "${entry}" || -L "${entry}" ]] || continue
            name="$(basename "${entry}")"
            [[ " ${target_names[*]} " == *" ${name} "* ]] \
                || fail "unexpected Guardian legacy log entry: ${entry}"
            validate_guardian_log_migration_file "${entry}" "${legacy}"
        done
        return 0
    fi

    ensure_guardian_log_migration_directory "${staging}"
    for entry in "${staging}"/*; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        name="$(basename "${entry}")"
        [[ " ${target_names[*]} " == *" ${name} "* ]] \
            || fail "unexpected Guardian log migration staging entry: ${entry}"
        validate_guardian_log_migration_file "${entry}" "${staging}"
    done
    for index in 0 1 2; do
        source="${guardian_dir}/${source_names[index]}"
        target="${staging}/${target_names[index]}"
        if [[ -e "${source}" || -L "${source}" ]]; then
            [[ ! -e "${target}" && ! -L "${target}" ]] \
                || fail "Guardian log migration source and staging target both exist: ${source}"
            validate_guardian_log_migration_file "${source}" "${guardian_dir}"
            mv -T "${source}" "${target}"
            ((moved += 1))
        elif [[ -e "${target}" || -L "${target}" ]]; then
            validate_guardian_log_migration_file "${target}" "${staging}"
        fi
    done
    if [[ -z "$(find "${staging}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        rmdir "${staging}"
        return 0
    fi
    mv -T "${staging}" "${legacy}"
    ((GUARDIAN_LOG_MIGRATED_PROFILES += 1))
    ((GUARDIAN_LOG_MIGRATED_FILES += moved))
}

migrate_guardian_logs() {
    local profiles_root profile_dir name
    GUARDIAN_LOG_MIGRATED_PROFILES=0
    GUARDIAN_LOG_MIGRATED_FILES=0
    profiles_root="$(realpath "${PI_RUN_HOME_RESOLVED}/profiles")"
    for profile_dir in "${profiles_root}"/*; do
        [[ -e "${profile_dir}" || -L "${profile_dir}" ]] || continue
        [[ -d "${profile_dir}" && ! -L "${profile_dir}" && "$(dirname "$(realpath "${profile_dir}")")" == "${profiles_root}" ]] \
            || fail "profile path is unsafe during Guardian log migration: ${profile_dir}"
        name="$(basename "${profile_dir}")"
        validate_profile_name "${name}"
        validate_profile_config "${profile_dir}" "${name}"
        validate_profile_definition_files "${profile_dir}"
        migrate_profile_guardian_logs "${profile_dir}"
    done
    printf 'Guardian legacy log migration complete: %s profile(s), %s source file(s) moved.\n' \
        "${GUARDIAN_LOG_MIGRATED_PROFILES}" "${GUARDIAN_LOG_MIGRATED_FILES}"
}

