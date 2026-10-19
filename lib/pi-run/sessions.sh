# SPDX-License-Identifier: MIT
# shellcheck shell=bash

workspace_has_session_state() {
    local id="$1" profile_dir session_dir
    for profile_dir in "${PI_RUN_HOME_RESOLVED}/profiles"/*; do
        [[ -d "${profile_dir}" ]] || continue
        session_dir="${profile_dir}/sessions/${id}"
        [[ ! -e "${session_dir}" && ! -L "${session_dir}" ]] && continue
        [[ -d "${session_dir}" && ! -L "${session_dir}" ]] || return 0
        [[ -z "$(find "${session_dir}" -mindepth 1 -print -quit)" ]] || return 0
    done
    return 1
}

reconnect_workspace_for_sessions() {
    local target_id="$1" path="$2" current_id="${3:-}"
    local registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    local machine machine_entry remove_placeholder=true
    machine="$(machine_file)"

    acquire_workspace_lock
    initialize_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    [[ "$(jq -r --arg id "${target_id}" '[.workspaces[] | select(.id == $id)] | length' "${registry}")" == 1 ]] \
        || fail "restored workspace is no longer registered: ${target_id}"

    if [[ -n "${current_id}" && "${current_id}" != "${target_id}" ]]; then
        workspace_has_session_state "${current_id}" \
            && fail "the current checkout already has session state; automatic reconnection was refused"
        for machine_entry in "${PI_RUN_HOME_RESOLVED}/machines"/*.json; do
            [[ -f "${machine_entry}" ]] || continue
            validate_workspace_metadata "${machine_entry}"
            if [[ "${machine_entry}" == "${machine}" ]]; then
                [[ "$(jq -r --arg id "${current_id}" --arg path "${path}" \
                    '[.workspacePaths[] | select(.workspaceId == $id and .path != $path)] | length' \
                    "${machine_entry}")" == 0 ]] || remove_placeholder=false
            elif [[ "$(jq -r --arg id "${current_id}" \
                    '[.workspacePaths[] | select(.workspaceId == $id)] | length' \
                    "${machine_entry}")" != 0 ]]; then
                remove_placeholder=false
            fi
        done
    else
        remove_placeholder=false
    fi

    update_json "${machine}" \
        --arg target "${target_id}" --arg path "${path}" \
        ".workspacePaths = ([.workspacePaths[] | select(.workspaceId != \$target and .path != \$path)] + [{workspaceId:\$target,path:\$path}])"
    if [[ "${remove_placeholder}" == true ]]; then
        update_json "${registry}" --arg id "${current_id}" \
            ".workspaces = [.workspaces[] | select(.id != \$id)]"
    fi
    release_workspace_lock
}


SESSION_GROUP_PROFILES=()
SESSION_GROUP_WORKSPACES=()
SESSION_GROUP_NAMES=()
SESSION_GROUP_COUNTS=()
SESSION_GROUP_PATHS=()
SESSION_GROUP_STATUSES=()

validate_session_file() {
    local file="$1"
    local prefix header
    [[ -f "${file}" && ! -L "${file}" ]] \
        || fail "session must be a regular non-symlink file: ${file}"
    [[ "$(stat -c %h "${file}")" == 1 ]] \
        || fail "session file must not be hard-linked: ${file}"
    prefix="$(head -c 65537 "${file}")"
    header="${prefix%%$'\n'*}"
    (( ${#header} <= 65536 )) || fail "session header exceeds 64 KiB: ${file}"
    printf '%s' "${header}" | jq -e '
        type == "object" and
        .type == "session" and
        (.id | type == "string") and
        (.timestamp | type == "string") and
        (.cwd | type == "string") and
        (.version == null or (.version | type == "number"))
    ' >/dev/null || fail "invalid Pi session header: ${file}"
}

discover_session_groups() {
    local registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    local machine profiles_root profile_dir profile workspace_root workspace_dir workspace_id
    local session_file count metadata_count workspace_name path status
    local -a session_files

    SESSION_GROUP_PROFILES=()
    SESSION_GROUP_WORKSPACES=()
    SESSION_GROUP_NAMES=()
    SESSION_GROUP_COUNTS=()
    SESSION_GROUP_PATHS=()
    SESSION_GROUP_STATUSES=()

    machine="$(machine_file)"
    acquire_workspace_lock
    initialize_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    release_workspace_lock
    profiles_root="$(realpath "${PI_RUN_HOME_RESOLVED}/profiles")"

    shopt -s nullglob
    for profile_dir in "${profiles_root}"/*; do
        [[ -d "${profile_dir}" ]] || continue
        [[ ! -L "${profile_dir}" ]] || fail "profile directory must not be a symlink: ${profile_dir}"
        profile="$(basename "${profile_dir}")"
        validate_profile_name "${profile}"
        workspace_root="${profile_dir}/sessions"
        [[ -d "${workspace_root}" && ! -L "${workspace_root}" ]] \
            || fail "profile sessions path must be a non-symlink directory: ${workspace_root}"

        for workspace_dir in "${workspace_root}"/*; do
            [[ -d "${workspace_dir}" ]] || continue
            [[ ! -L "${workspace_dir}" ]] \
                || fail "workspace session directory must not be a symlink: ${workspace_dir}"
            workspace_id="$(basename "${workspace_dir}")"
            [[ "${workspace_id}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
                || fail "invalid workspace session directory: ${workspace_dir}"

            session_files=("${workspace_dir}"/*.jsonl)
            count=0
            for session_file in "${session_files[@]}"; do
                validate_session_file "${session_file}"
                count=$((count + 1))
            done
            (( count > 0 )) || continue

            metadata_count="$(jq -r --arg id "${workspace_id}" '[.workspaces[] | select(.id == $id)] | length' "${registry}")"
            workspace_name="unregistered"
            path=""
            status="unregistered"
            if [[ "${metadata_count}" == 1 ]]; then
                workspace_name="$(jq -r --arg id "${workspace_id}" '.workspaces[] | select(.id == $id) | .name' "${registry}")"
                path="$(jq -r --arg id "${workspace_id}" '
                    [.workspacePaths[] | select(.workspaceId == $id)] |
                    if length > 1 then error("duplicate workspace mapping")
                    else (.[0].path // "") end
                ' "${machine}")"
                status="unavailable"
                if [[ -n "${path}" && -d "${path}" && "$(realpath "${path}")" == "${path}" ]]; then
                    status="available"
                fi
            elif [[ "${metadata_count}" != 0 ]]; then
                fail "duplicate workspace ID in registry: ${workspace_id}"
            fi

            SESSION_GROUP_PROFILES+=("${profile}")
            SESSION_GROUP_WORKSPACES+=("${workspace_id,,}")
            SESSION_GROUP_NAMES+=("${workspace_name}")
            SESSION_GROUP_COUNTS+=("${count}")
            SESSION_GROUP_PATHS+=("${path}")
            SESSION_GROUP_STATUSES+=("${status}")
        done
    done
    shopt -u nullglob
}

list_session_groups() {
    local index profile name path status count
    local profile_width=7 workspace_width=12 name_width=4 count_width=8 status_width=6
    local -a profile_rows=() workspaces=() names=() counts=() statuses=() paths=()
    discover_session_groups
    for ((index=0; index<${#SESSION_GROUP_PROFILES[@]}; index++)); do
        profile="$(sanitize_display "${SESSION_GROUP_PROFILES[index]}")"
        name="$(sanitize_display "${SESSION_GROUP_NAMES[index]}")"
        path="$(sanitize_display "${SESSION_GROUP_PATHS[index]:--}")"
        status="$(sanitize_display "${SESSION_GROUP_STATUSES[index]}")"
        count="${SESSION_GROUP_COUNTS[index]}"
        profile_rows+=("${profile}")
        workspaces+=("${SESSION_GROUP_WORKSPACES[index]}")
        names+=("${name}")
        counts+=("${count}")
        statuses+=("${status}")
        paths+=("${path}")
        (( ${#profile} > profile_width )) && profile_width=${#profile}
        (( ${#SESSION_GROUP_WORKSPACES[index]} > workspace_width )) && workspace_width=${#SESSION_GROUP_WORKSPACES[index]}
        (( ${#name} > name_width )) && name_width=${#name}
        (( ${#count} > count_width )) && count_width=${#count}
        (( ${#status} > status_width )) && status_width=${#status}
    done
    printf '%-*s  %-*s  %-*s  %-*s  %-*s  %s\n' \
        "${profile_width}" PROFILE "${workspace_width}" 'WORKSPACE ID' \
        "${name_width}" NAME "${count_width}" SESSIONS "${status_width}" STATUS PATH
    for index in "${!profile_rows[@]}"; do
        printf '%-*s  %-*s  %-*s  %-*s  %-*s  %s\n' \
            "${profile_width}" "${profile_rows[index]}" \
            "${workspace_width}" "${workspaces[index]}" \
            "${name_width}" "${names[index]}" \
            "${count_width}" "${counts[index]}" \
            "${status_width}" "${statuses[index]}" \
            "${paths[index]}"
    done
}

session_display_name() {
    local file="$1" encoded name
    encoded="$(jq -c '
        select(.type == "session_info") |
        if (.name | type) == "string" then .name else null end
    ' "${file}" | tail -n 1)" || fail "invalid Pi session content: ${file}"
    if [[ -z "${encoded}" || "${encoded}" == null ]]; then
        printf '%s\n' '-'
        return 0
    fi
    name="$(jq -r '.' <<< "${encoded}")" || fail "invalid Pi session name: ${file}"
    name="$(sanitize_display "${name}")"
    printf '%s\n' "${name:--}"
}

list_workspace_sessions() {
    local requested_id="${1,,}" profiles_root profile_dir profile workspace_dir session_file
    local header session_id created name session_name index
    local profile_width=7 session_width=10 created_width=7 name_width=4
    local -a profiles=() session_ids=() created_values=() names=() files=()
    [[ "${requested_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "workspace ID must be a complete UUID: $1"
    profiles_root="$(realpath "${PI_RUN_HOME_RESOLVED}/profiles")"

    shopt -s nullglob
    for profile_dir in "${profiles_root}"/*; do
        [[ -d "${profile_dir}" && ! -L "${profile_dir}" ]] \
            || fail "profile directory must be a non-symlink directory: ${profile_dir}"
        profile="$(basename "${profile_dir}")"
        validate_profile_name "${profile}"
        workspace_dir="${profile_dir}/sessions/${requested_id}"
        [[ ! -e "${workspace_dir}" && ! -L "${workspace_dir}" ]] && continue
        [[ -d "${workspace_dir}" && ! -L "${workspace_dir}" && "$(realpath "${workspace_dir}")" == "${workspace_dir}" ]] \
            || fail "workspace session directory is unsafe: ${workspace_dir}"
        for session_file in "${workspace_dir}"/*.jsonl; do
            validate_session_file "${session_file}"
            header="$(head -n 1 "${session_file}")"
            IFS=$'\t' read -r session_id created < <(
                jq -er '[.id, .timestamp] | @tsv' <<< "${header}"
            ) || fail "could not read Pi session identity: ${session_file}"
            session_id="$(sanitize_display "${session_id}")"
            created="$(sanitize_display "${created}")"
            name="$(session_display_name "${session_file}")"
            session_name="$(sanitize_display "$(basename "${session_file}")")"
            profiles+=("${profile}")
            session_ids+=("${session_id}")
            created_values+=("${created}")
            names+=("${name}")
            files+=("${session_name}")
            (( ${#profile} > profile_width )) && profile_width=${#profile}
            (( ${#session_id} > session_width )) && session_width=${#session_id}
            (( ${#created} > created_width )) && created_width=${#created}
            (( ${#name} > name_width )) && name_width=${#name}
        done
    done
    shopt -u nullglob

    printf '%-*s  %-*s  %-*s  %-*s  %s\n' \
        "${profile_width}" PROFILE "${session_width}" 'SESSION ID' \
        "${created_width}" CREATED "${name_width}" NAME FILE
    for index in "${!profiles[@]}"; do
        printf '%-*s  %-*s  %-*s  %-*s  %s\n' \
            "${profile_width}" "${profiles[index]}" \
            "${session_width}" "${session_ids[index]}" \
            "${created_width}" "${created_values[index]}" \
            "${name_width}" "${names[index]}" "${files[index]}"
    done
}

# These selections are consumed by launcher dispatch after select_resume_target returns.
# shellcheck disable=SC2034
RESUME_WORKSPACE_PATH=""
# shellcheck disable=SC2034
RESUME_WORKSPACE_ID=""

reconnect_selected_session_group() {
    local selected="$1" default_path input_path path machine current_id response name
    [[ -t 0 && -t 2 ]] \
        || fail "the selected workspace is unavailable on this machine; run interactively to reconnect it"
    name="$(sanitize_display "${SESSION_GROUP_NAMES[selected]}")"
    default_path="$(realpath .)"
    printf 'The restored workspace %s has %s session(s), but no checkout is linked on this machine.\n' \
        "${name}" "${SESSION_GROUP_COUNTS[selected]}" >&2
    if ! read -r -p "Checkout path [${default_path}]: " input_path; then
        fail "no checkout path received"
    fi
    input_path="${input_path:-${default_path}}"
    [[ -d "${input_path}" ]] || fail "workspace does not exist: ${input_path}"
    path="$(realpath "${input_path}")"
    machine="$(machine_file)"
    initialize_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    current_id="$(jq -r --arg path "${path}" '
        [.workspacePaths[] | select(.path == $path)] |
        if length > 1 then error("duplicate workspace path")
        else (.[0].workspaceId // "") end
    ' "${machine}")"
    if [[ -n "${current_id}" && "${current_id}" != "${SESSION_GROUP_WORKSPACES[selected]}" ]] &&
       workspace_has_session_state "${current_id}"; then
        fail "that checkout already has sessions; choose another checkout path"
    fi
    if ! read -r -p "Reconnect this checkout to the restored sessions? [Y/n]: " response; then
        fail "reconnection confirmation was not received"
    fi
    case "${response,,}" in
        ""|y|yes) ;;
        *) fail "session reconnection cancelled" ;;
    esac
    reconnect_workspace_for_sessions \
        "${SESSION_GROUP_WORKSPACES[selected]}" "${path}" "${current_id}"
    SESSION_GROUP_PATHS[selected]="${path}"
    SESSION_GROUP_STATUSES[selected]=available
    printf 'Checkout reconnected to %s restored session(s).\n' "${SESSION_GROUP_COUNTS[selected]}" >&2
}

select_resume_target() {
    local requested_profile="${1:-}"
    local requested_workspace="${2:-}"
    local index selected=-1 choice name path
    discover_session_groups
    (( ${#SESSION_GROUP_PROFILES[@]} > 0 )) || fail "no sessions found"

    if [[ -n "${requested_profile}" ]]; then
        validate_profile_name "${requested_profile}"
        for ((index=0; index<${#SESSION_GROUP_PROFILES[@]}; index++)); do
            if [[ "${SESSION_GROUP_PROFILES[index]}" == "${requested_profile}" &&
                  "${SESSION_GROUP_WORKSPACES[index]}" == "${requested_workspace,,}" ]]; then
                selected="${index}"
                break
            fi
        done
        (( selected >= 0 )) \
            || fail "no sessions found for ${requested_profile}/${requested_workspace}"
    else
        [[ -t 0 && -t 2 ]] \
            || fail "interactive resume requires a terminal; use: pi-run resume <profile> <workspace-id>"
        printf 'Available session groups:\n' >&2
        for ((index=0; index<${#SESSION_GROUP_PROFILES[@]}; index++)); do
            name="$(sanitize_display "${SESSION_GROUP_NAMES[index]}")"
            path="$(sanitize_display "${SESSION_GROUP_PATHS[index]:--}")"
            printf '  %d) %s · %s · %s session(s) · %s · %s\n' \
                "$((index + 1))" "${SESSION_GROUP_PROFILES[index]}" "${name}" \
                "${SESSION_GROUP_COUNTS[index]}" "${SESSION_GROUP_STATUSES[index]}" "${path}" >&2
        done
        if ! read -r -p 'Selection: ' choice; then
            fail "no resume selection received"
        fi
        [[ "${choice}" =~ ^[0-9]+$ ]] || fail "invalid resume selection: ${choice}"
        selected=$((choice - 1))
        (( selected >= 0 && selected < ${#SESSION_GROUP_PROFILES[@]} )) \
            || fail "resume selection is out of range: ${choice}"
    fi

    if [[ "${SESSION_GROUP_STATUSES[selected]}" != "available" ]]; then
        [[ "${SESSION_GROUP_STATUSES[selected]}" == "unavailable" ]] \
            || fail "workspace session metadata is ${SESSION_GROUP_STATUSES[selected]} and cannot be reconnected automatically"
        reconnect_selected_session_group "${selected}"
    fi
    PROFILE="${SESSION_GROUP_PROFILES[selected]}"
    # Consumed by launcher dispatch after this function returns.
    # shellcheck disable=SC2034
    RESUME_WORKSPACE_ID="${SESSION_GROUP_WORKSPACES[selected]}"
    # shellcheck disable=SC2034
    RESUME_WORKSPACE_PATH="${SESSION_GROUP_PATHS[selected]}"
}

select_managed_repository_session_workspace() {
    local selected_path="$1" profile="$2" machine registry repository_count repository_id
    local association workspace_id branch path registry_count expected_path admin_dir actual_common actual_git_dir actual_branch
    local session_dir session_file file_time latest_time candidate_time candidate_head selected_time="" tie=false
    local selected_id="" selected_path_result="" selected_branch="" selected_common="" selected_head=""
    local LC_ALL=C
    local -a associations session_files
    validate_profile_name "${profile}"
    resolve_worktree_repository "${selected_path}"
    machine="$(machine_file)"
    registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    [[ -f "${machine}" ]] || fail "no managed worktree sessions are registered for this repository and profile"

    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    [[ "$(jq -r '.schemaVersion' "${machine}")" == 2 ]] \
        || fail "no managed worktree sessions are registered for this repository and profile"
    repository_count="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
        '[.repositories[] | select(.commonGitDir == $common)] | length' "${machine}")"
    [[ "${repository_count}" == 1 ]] \
        || fail "no uniquely registered managed repository is available for continuation"
    repository_id="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
        '.repositories[] | select(.commonGitDir == $common) | .id' "${machine}")"
    mapfile -t associations < <(jq -r --arg repository "${repository_id}" '
        .repositories[] | select(.id == $repository) | .managedWorkspaces[] |
        [.workspaceId, .branch] | @tsv
    ' "${machine}")
    release_workspace_lock

    for association in "${associations[@]}"; do
        IFS=$'\t' read -r workspace_id branch <<< "${association}"
        [[ "${branch}" == "pi-run/${workspace_id}" ]] \
            || fail "managed workspace branch metadata conflicts with its identity: ${workspace_id}"
        path="$(jq -r --arg id "${workspace_id}" '
            [.workspacePaths[] | select(.workspaceId == $id)] |
            if length == 1 then .[0].path else "" end
        ' "${machine}")"
        registry_count="$(jq -r --arg id "${workspace_id}" \
            '[.workspaces[] | select(.id == $id)] | length' "${registry}")"
        [[ -n "${path}" ]] || continue
        [[ "${registry_count}" != 0 ]] || continue
        [[ "${registry_count}" == 1 &&
           "$(jq -r --arg id "${workspace_id}" '.workspaces[] | select(.id == $id) | .kind' "${registry}")" == git ]] \
            || fail "portable workspace metadata conflicts with managed continuation: ${workspace_id}"
        expected_path="${PI_RUN_HOME_RESOLVED}/worktrees/${repository_id}/${workspace_id}"
        [[ "${path}" == "${expected_path}" ]] \
            || fail "managed workspace path metadata conflicts with its identity: ${workspace_id}"
        [[ -e "${path}" || -L "${path}" ]] || continue
        [[ -d "${path}" && ! -L "${path}" && "$(realpath "${path}")" == "${path}" &&
           "$(stat -c %u "${path}")" == "$(id -u)" ]] \
            || fail "managed continuation worktree is unsafe: ${path}"
        admin_dir="${WORKTREE_REPOSITORY_COMMON_DIR}/worktrees/${workspace_id}"
        [[ -d "${admin_dir}" && ! -L "${admin_dir}" && -f "${path}/.git" && ! -L "${path}/.git" ]] \
            || fail "managed continuation Git administration is unsafe: ${path}"
        actual_common="$(git -C "${path}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
        actual_git_dir="$(git -C "${path}" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
        actual_branch="$(git -C "${path}" symbolic-ref --quiet HEAD 2>/dev/null || true)"
        [[ "${actual_common}" == "${WORKTREE_REPOSITORY_COMMON_DIR}" &&
           "${actual_git_dir}" == "${admin_dir}" && "${actual_branch}" == "refs/heads/${branch}" ]] \
            || fail "managed continuation Git state conflicts with metadata: ${workspace_id}"

        session_dir="${PI_RUN_HOME_RESOLVED}/profiles/${profile}/sessions/${workspace_id}"
        [[ -e "${session_dir}" || -L "${session_dir}" ]] || continue
        [[ -d "${session_dir}" && ! -L "${session_dir}" && "$(realpath "${session_dir}")" == "${session_dir}" &&
           "$(stat -c %u "${session_dir}")" == "$(id -u)" ]] \
            || fail "managed workspace session directory is unsafe: ${session_dir}"
        shopt -s nullglob
        session_files=("${session_dir}"/*.jsonl)
        shopt -u nullglob
        (( ${#session_files[@]} > 0 )) || continue
        latest_time=""
        for session_file in "${session_files[@]}"; do
            validate_session_file "${session_file}"
            file_time="$(stat -c %y "${session_file}")"
            [[ -z "${latest_time}" || "${file_time}" > "${latest_time}" ]] && latest_time="${file_time}"
        done
        candidate_time="${latest_time}"
        candidate_head="$(git -C "${path}" rev-parse --verify HEAD 2>/dev/null)" \
            || fail "managed continuation worktree has no committed HEAD: ${workspace_id}"
        if [[ -z "${selected_id}" || "${candidate_time}" > "${selected_time}" ]]; then
            selected_id="${workspace_id}"
            selected_path_result="${path}"
            selected_branch="${branch}"
            selected_common="${WORKTREE_REPOSITORY_COMMON_DIR}"
            selected_head="${candidate_head}"
            selected_time="${candidate_time}"
            tie=false
        elif [[ "${candidate_time}" == "${selected_time}" ]]; then
            tie=true
        fi
    done

    [[ -n "${selected_id}" ]] \
        || fail "no managed worktree sessions are available for repository $(sanitize_display "${WORKTREE_REPOSITORY_NAME}") and profile ${profile}"
    [[ "${tie}" == false ]] \
        || fail "managed worktree continuation is ambiguous because multiple workspaces have equally recent sessions"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${selected_id}" "${selected_path_result}" "${selected_branch}" "${selected_common}" "${selected_head}"
}

pi_resume_requested() {
    local argument
    for argument in "${EXTRA_PI_ARGS[@]}"; do
        [[ "${argument}" == -r || "${argument}" == --resume ]] && return 0
    done
    return 1
}

maybe_reconnect_direct_resume() {
    local path="$1" current_id="$2" workspace_name index choice response selected=-1
    local -a candidates=()
    pi_resume_requested || return 0
    workspace_has_session_state "${current_id}" && return 0
    [[ -t 0 && -t 2 ]] || return 0

    workspace_name="$(basename "${path}")"
    discover_session_groups
    for ((index=0; index<${#SESSION_GROUP_PROFILES[@]}; index++)); do
        if [[ "${SESSION_GROUP_PROFILES[index]}" == "${PROFILE}" &&
              "${SESSION_GROUP_NAMES[index]}" == "${workspace_name}" &&
              "${SESSION_GROUP_STATUSES[index]}" == unavailable &&
              "${SESSION_GROUP_WORKSPACES[index]}" != "${current_id}" ]]; then
            candidates+=("${index}")
        fi
    done
    (( ${#candidates[@]} > 0 )) || return 0

    printf 'Restored sessions are available for this project:\n' >&2
    for ((index=0; index<${#candidates[@]}; index++)); do
        choice="${candidates[index]}"
        printf '  %d) %s — %s session(s)\n' "$((index + 1))" \
            "$(sanitize_display "${SESSION_GROUP_NAMES[choice]}")" \
            "${SESSION_GROUP_COUNTS[choice]}" >&2
    done
    if (( ${#candidates[@]} == 1 )); then
        selected="${candidates[0]}"
    else
        if ! read -r -p 'Selection (or q to start without restored sessions): ' choice; then
            return 0
        fi
        [[ "${choice,,}" != q ]] || return 0
        [[ "${choice}" =~ ^[0-9]+$ ]] || fail "invalid restored-session selection: ${choice}"
        index=$((choice - 1))
        (( index >= 0 && index < ${#candidates[@]} )) \
            || fail "restored-session selection is out of range: ${choice}"
        selected="${candidates[index]}"
    fi
    if ! read -r -p 'Reconnect this checkout to the restored sessions? [Y/n]: ' response; then
        return 0
    fi
    case "${response,,}" in
        ""|y|yes) ;;
        *) return 0 ;;
    esac
    reconnect_workspace_for_sessions \
        "${SESSION_GROUP_WORKSPACES[selected]}" "${path}" "${current_id}"
    # Consumed by launcher dispatch after direct reconnection returns.
    # shellcheck disable=SC2034
    WORKSPACE_ID="${SESSION_GROUP_WORKSPACES[selected]}"
    printf 'Checkout reconnected to %s restored session(s).\n' \
        "${SESSION_GROUP_COUNTS[selected]}" >&2
}

