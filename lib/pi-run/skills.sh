# SPDX-License-Identifier: MIT
# shellcheck shell=bash

skill_frontmatter_value() {
    local file="$1"
    local key="$2"
    awk -v key="${key}" '
        NR == 1 { if ($0 != "---") exit 2; inside = 1; next }
        inside && $0 == "---" { exit }
        inside && index($0, key ":") == 1 {
            value = substr($0, length(key) + 2)
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            if ((substr(value,1,1) == "\"" && substr(value,length(value),1) == "\"") ||
                (substr(value,1,1) == "\047" && substr(value,length(value),1) == "\047"))
                value = substr(value,2,length(value)-2)
            print value
            exit
        }
    ' "${file}"
}

validate_skill_source() {
    local source_dir="$1"
    local expected_name="$2"
    local root_device path entry_count=0 file_count=0 total_size=0 size links
    local document_name description

    [[ -d "${source_dir}" && ! -L "${source_dir}" ]] \
        || fail "skill source must be a non-symlink directory: ${source_dir}"
    [[ -f "${source_dir}/SKILL.md" && ! -L "${source_dir}/SKILL.md" ]] \
        || fail "skill source is missing a regular SKILL.md: ${source_dir}"

    document_name="$(skill_frontmatter_value "${source_dir}/SKILL.md" name)" \
        || fail "SKILL.md must start with YAML frontmatter"
    description="$(skill_frontmatter_value "${source_dir}/SKILL.md" description)" \
        || fail "SKILL.md must start with YAML frontmatter"
    [[ -n "${document_name}" && -n "${description}" ]] \
        || fail "SKILL.md requires non-empty name and description fields"
    [[ "${document_name}" == "${expected_name}" ]] \
        || fail "SKILL.md name '${document_name}' does not match '${expected_name}'"

    root_device="$(stat -c %d "${source_dir}")"
    while IFS= read -r -d '' path; do
        entry_count=$((entry_count + 1))
        (( entry_count <= 1000 )) || fail "skill contains more than 1000 entries"
        [[ ! -L "${path}" ]] || fail "skill contains a symbolic link: ${path}"
        [[ "$(stat -c %d "${path}")" == "${root_device}" ]] \
            || fail "skill crosses a filesystem boundary: ${path}"
        if [[ -d "${path}" ]]; then
            continue
        fi
        [[ -f "${path}" ]] || fail "skill contains a special file: ${path}"
        links="$(stat -c %h "${path}")"
        [[ "${links}" == 1 ]] || fail "skill contains a hard-linked file: ${path}"
        size="$(stat -c %s "${path}")"
        (( size <= 10485760 )) || fail "skill file exceeds 10 MiB: ${path}"
        file_count=$((file_count + 1))
        total_size=$((total_size + size))
        (( file_count <= 500 )) || fail "skill contains more than 500 files"
        (( total_size <= 52428800 )) || fail "skill exceeds 50 MiB total"
    done < <(find -P "${source_dir}" -xdev -mindepth 1 -print0)
}

validate_profile_skills_directory() {
    local profile_dir="$1"
    local skills_dir="${profile_dir}/skills"
    local path name count=0
    [[ -d "${skills_dir}" && ! -L "${skills_dir}" ]] \
        || fail "profile requires a non-symlink skills directory: ${skills_dir}"

    while IFS= read -r -d '' path; do
        count=$((count + 1))
        (( count <= 64 )) || fail "profile contains more than 64 local skills"
        [[ -d "${path}" && ! -L "${path}" ]] \
            || fail "profile skills directory contains a non-skill entry: ${path}"
        name="$(basename "${path}")"
        validate_skill_name "${name}"
        validate_skill_source "${path}" "${name}"
    done < <(find -P "${skills_dir}" -xdev -mindepth 1 -maxdepth 1 -print0)
}

profile_skill_names() {
    local profile_dir="$1"
    find -P "${profile_dir}/skills" -xdev -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | LC_ALL=C sort
}

validate_global_skills_directory() {
    local skills_dir="${PI_RUN_HOME_RESOLVED}/skills" path name
    [[ -d "${skills_dir}" && ! -L "${skills_dir}" && "$(realpath "${skills_dir}")" == "${skills_dir}" ]] \
        || fail "global skills path must be a non-symlink directory: ${skills_dir}"
    while IFS= read -r -d '' path; do
        [[ -d "${path}" && ! -L "${path}" ]] \
            || fail "global skills directory contains a non-skill entry: ${path}"
        name="$(basename "${path}")"
        validate_skill_name "${name}"
    done < <(find -P "${skills_dir}" -xdev -mindepth 1 -maxdepth 1 -print0)
}

global_skill_names() {
    find -P "${PI_RUN_HOME_RESOLVED}/skills" -xdev -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | LC_ALL=C sort
}

profile_loads_all_global_skills() {
    local profile_config="$1"
    jq -e '((has("skills") | not) or .skills == null)' "${profile_config}" >/dev/null
}

global_skill_is_active() {
    local profile_config="$1" name="$2"
    profile_loads_all_global_skills "${profile_config}" ||
        jq -e --arg name "${name}" '.skills | index($name) != null' "${profile_config}" >/dev/null
}

validate_profile_global_skill_filter() {
    local profile_config="$1" name path
    profile_loads_all_global_skills "${profile_config}" && return 0
    while IFS= read -r name; do
        path="${PI_RUN_HOME_RESOLVED}/skills/${name}"
        [[ -d "${path}" && ! -L "${path}" ]] \
            || fail "profile selects a missing global skill: ${name}"
    done < <(jq -r '.skills[]' "${profile_config}")
}

list_skills() {
    local profile_dir profile_name profile_config name index status type_width=4 name_width=4
    local -a types=(core core) names=(pi-run profile-management) statuses=(active active)
    declare -A profile_skill_set=()
    profile_dir="$(resolve_profile_directory)"
    profile_name="$(basename "${profile_dir}")"
    profile_config="${profile_dir}/profile.json"
    validate_profile_config "${profile_dir}" "${profile_name}"
    validate_profile_skills_directory "${profile_dir}"
    validate_global_skills_directory
    validate_profile_global_skill_filter "${profile_config}"
    while IFS= read -r name; do
        if [[ -n "${name}" ]]; then
            profile_skill_set["${name}"]=1
            types+=(profile)
            names+=("${name}")
            statuses+=(active)
        fi
    done < <(profile_skill_names "${profile_dir}")
    while IFS= read -r name; do
        if [[ -n "${name}" ]]; then
            validate_skill_source "${PI_RUN_HOME_RESOLVED}/skills/${name}" "${name}"
            status=filtered
            if global_skill_is_active "${profile_config}" "${name}"; then
                [[ -z "${profile_skill_set[${name}]:-}" ]] \
                    || fail "skill exists in both active global and profile directories: ${name}"
                status=active
            fi
            types+=(global)
            names+=("${name}")
            statuses+=("${status}")
        fi
    done < <(global_skill_names)
    for index in "${!types[@]}"; do
        (( ${#types[index]} > type_width )) && type_width=${#types[index]}
        (( ${#names[index]} > name_width )) && name_width=${#names[index]}
    done
    printf '%-*s  %-*s  %s\n' "${type_width}" TYPE "${name_width}" NAME STATUS
    for index in "${!types[@]}"; do
        printf '%-*s  %-*s  %s\n' "${type_width}" "${types[index]}" \
            "${name_width}" "${names[index]}" "${statuses[index]}"
    done
}

