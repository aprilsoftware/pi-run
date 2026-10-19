# SPDX-License-Identifier: MIT
# shellcheck shell=bash

machine_id() {
    local source
    if [[ -s /etc/machine-id ]]; then
        source="$(< /etc/machine-id)"
    else
        source="$(hostname)"
    fi
    printf '%s:%s' "${source}" "$(id -u)" | sha256sum | cut -c1-16
}

machine_file() {
    printf '%s/machines/%s.json\n' "${PI_RUN_HOME_RESOLVED}" "$(machine_id)"
}

initialize_machine_file() {
    local file="$1"
    local id
    id="$(basename "${file}" .json)"
    if [[ ! -f "${file}" ]]; then
        local staging="${file}.tmp.$$"
        printf '{"schemaVersion":1,"machineId":"%s","workspacePaths":[]}\n' "${id}" > "${staging}"
        chmod 0600 "${staging}"
        mv "${staging}" "${file}"
    fi
}

validate_workspace_metadata() {
    local registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    local machine="$1"

    jq -e '
        .schemaVersion == 1 and
        (.workspaces | type == "array") and
        all(.workspaces[];
            (.id | type == "string") and
            (.name | type == "string") and
            (.kind == "git" or .kind == "directory") and
            (.createdAt | type == "string"))
    ' "${registry}" >/dev/null \
        || fail "invalid workspace registry: ${registry}"

    jq -e '
        def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
        def host_path: type == "string" and test("^/[\\x20-\\x7e]*$");
        def workspace_path:
            (keys | sort == ["path", "workspaceId"]) and
            (.workspaceId | uuid) and (.path | host_path);
        def managed_workspace:
            (keys | sort == ["branch", "createdAt", "workspaceId"]) and
            (.workspaceId | uuid) and
            (.branch | type == "string" and length > 0 and length <= 255 and test("^[^\\x00-\\x1f\\x7f]+$")) and
            (.createdAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"));
        def repository:
            (keys | sort == ["commonGitDir", "createdAt", "enabled", "id", "managedWorkspaces", "name", "primaryPath"]) and
            (.id | uuid) and
            (.name | type == "string" and length > 0 and length <= 255 and test("^[^\\x00-\\x1f\\x7f]+$")) and
            (.commonGitDir | host_path) and (.primaryPath | host_path) and
            (.enabled | type == "boolean") and
            (.createdAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
            (.managedWorkspaces | type == "array") and all(.managedWorkspaces[]; managed_workspace);
        if .schemaVersion == 1 then
            (.machineId | type == "string") and
            (.workspacePaths | type == "array") and
            all(.workspacePaths[];
                (.workspaceId | type == "string") and (.path | type == "string"))
        else
            .schemaVersion == 2 and
            (keys | sort == ["machineId", "repositories", "schemaVersion", "workspacePaths"]) and
            (.machineId | type == "string" and test("^[0-9a-f]{16}$")) and
            (.workspacePaths | type == "array") and all(.workspacePaths[]; workspace_path) and
            ([.workspacePaths[].workspaceId] | length == (unique | length)) and
            ([.workspacePaths[].path] | length == (unique | length)) and
            (.repositories | type == "array") and all(.repositories[]; repository) and
            ([.repositories[].id] | length == (unique | length)) and
            ([.repositories[].commonGitDir] | length == (unique | length)) and
            ([.repositories[].managedWorkspaces[].workspaceId] | length == (unique | length)) and
            ([.workspacePaths[].workspaceId] as $mapped |
                all(.repositories[].managedWorkspaces[]; .workspaceId as $id | ($mapped | index($id)) != null))
        end
    ' "${machine}" >/dev/null \
        || fail "invalid machine workspace mapping: ${machine}"
}

validate_worktree_machine_file() {
    local file="$1" expected_id
    expected_id="$(basename "${file}" .json)"
    [[ -f "${file}" && ! -L "${file}" && "$(realpath "${file}")" == "${file}" ]] \
        || fail "worktree machine metadata must be a regular non-symlink file: ${file}"
    [[ "$(stat -c %h "${file}")" == 1 ]] \
        || fail "worktree machine metadata must not be hard-linked: ${file}"
    [[ "$(stat -c %a "${file}")" == 600 ]] \
        || fail "worktree machine metadata permissions must be 600: ${file}"
    [[ "$(stat -c %u "${file}")" == "$(id -u)" ]] \
        || fail "worktree machine metadata must be owned by the current user: ${file}"
    [[ "${expected_id}" =~ ^[0-9a-f]{16}$ &&
       "$(jq -r '.machineId // ""' "${file}")" == "${expected_id}" ]] \
        || fail "worktree machine metadata has the wrong machine identity: ${file}"
}

validate_worktree_machine_v1_migration() {
    local file="$1"
    jq -e '
        (keys | sort == ["machineId", "schemaVersion", "workspacePaths"]) and
        .schemaVersion == 1 and (.machineId | type == "string" and test("^[0-9a-f]{16}$")) and
        (.workspacePaths | type == "array") and
        all(.workspacePaths[];
            (keys | sort == ["path", "workspaceId"]) and
            (.workspaceId | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
            (.path | type == "string" and test("^/[\\x20-\\x7e]*$"))) and
        ([.workspacePaths[].workspaceId] | length == (unique | length)) and
        ([.workspacePaths[].path] | length == (unique | length))
    ' "${file}" >/dev/null \
        || fail "machine metadata cannot be migrated safely: ${file}"
}

ensure_worktree_machine_metadata() {
    local machine schema
    machine="$(machine_file)"
    acquire_workspace_lock
    if [[ -e "${machine}" || -L "${machine}" ]]; then
        validate_worktree_machine_file "${machine}"
    else
        initialize_machine_file "${machine}"
        validate_worktree_machine_file "${machine}"
    fi
    validate_workspace_metadata "${machine}"
    schema="$(jq -r '.schemaVersion' "${machine}")"
    if [[ "${schema}" == 1 ]]; then
        validate_worktree_machine_v1_migration "${machine}"
        update_json "${machine}" '.schemaVersion = 2 | .repositories = []'
        validate_worktree_machine_file "${machine}"
        validate_workspace_metadata "${machine}"
    elif [[ "${schema}" != 2 ]]; then
        fail "unsupported worktree machine metadata schema: ${machine}"
    fi
    release_workspace_lock
    printf '%s\n' "${machine}"
}

WORKTREE_REPOSITORY_NAME=""
WORKTREE_REPOSITORY_COMMON_DIR=""
WORKTREE_REPOSITORY_PRIMARY_PATH=""
WORKTREE_REPOSITORY_SELECTED_PATH=""

resolve_worktree_repository() {
    local input="${1:-.}" selected top common_raw common primary name path
    command -v git >/dev/null 2>&1 || fail "git is required for worktree management"
    [[ -d "${input}" ]] || fail "repository path does not exist: ${input}"
    selected="$(realpath "${input}")"
    [[ "$(git -C "${selected}" rev-parse --is-inside-work-tree 2>/dev/null)" == true &&
       "$(git -C "${selected}" rev-parse --is-bare-repository 2>/dev/null)" == false ]] \
        || fail "current directory is not inside a supported non-bare Git repository"
    top="$(git -C "${selected}" rev-parse --path-format=absolute --show-toplevel)" \
        || fail "could not resolve the selected Git worktree"
    common_raw="$(git -C "${selected}" rev-parse --path-format=absolute --git-common-dir)" \
        || fail "could not resolve the common Git directory"
    common="$(realpath "${common_raw}")"
    top="$(realpath "${top}")"
    [[ "${common_raw}" == "${common}" && "${common}" == */.git ]] \
        || fail "repository must use an ordinary canonical .git directory"
    primary="${common%/.git}"
    [[ -d "${primary}" && ! -L "${primary}" && -d "${common}" && ! -L "${common}" &&
       -d "${top}" && ! -L "${top}" ]] \
        || fail "repository paths must be ordinary non-symlink directories"
    for path in "${primary}" "${common}" "${top}"; do
        [[ "$(stat -c %u "${path}")" == "$(id -u)" ]] \
            || fail "repository path must be owned by the current user: ${path}"
    done
    [[ "$(git -C "${primary}" rev-parse --path-format=absolute --show-toplevel 2>/dev/null)" == "${primary}" &&
       "$(git -C "${primary}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" == "${common}" ]] \
        || fail "common Git metadata does not match its primary checkout"
    name="$(basename "${primary}")"
    jq -en --arg name "${name}" --arg common "${common}" --arg primary "${primary}" '
        ($name | length > 0 and length <= 255 and test("^[^\\x00-\\x1f\\x7f]+$")) and
        ($common | test("^/[\\x20-\\x7e]*$")) and ($primary | test("^/[\\x20-\\x7e]*$"))
    ' >/dev/null || fail "repository name or paths cannot be represented safely"
    WORKTREE_REPOSITORY_NAME="${name}"
    WORKTREE_REPOSITORY_COMMON_DIR="${common}"
    WORKTREE_REPOSITORY_PRIMARY_PATH="${primary}"
    WORKTREE_REPOSITORY_SELECTED_PATH="${top}"
}

print_worktree_preference() {
    local machine="$1" record
    record="$(jq -c --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
        '.repositories[]? | select(.commonGitDir == $common)' "${machine}")"
    printf 'Repository: %s\n' "$(sanitize_display "${WORKTREE_REPOSITORY_NAME}")"
    if [[ -z "${record}" ]]; then
        printf 'Repository ID: -\nWorktree mode: disabled (not registered)\nManaged workspaces: 0\n'
    else
        jq -r '
            "Repository ID: \(.id)",
            "Worktree mode: \(if .enabled then "enabled" else "disabled" end)",
            "Managed workspaces: \(.managedWorkspaces | length)"
        ' <<< "${record}"
    fi
    printf 'Primary checkout: %s\n' "$(sanitize_display "${WORKTREE_REPOSITORY_PRIMARY_PATH}")"
}

show_worktree_preference() {
    local machine
    resolve_worktree_repository
    machine="$(ensure_worktree_machine_metadata)"
    print_worktree_preference "${machine}"
}

list_managed_worktrees() {
    local machine registry schema repository repository_id name enabled primary common repository_root
    local workspace workspace_id branch created path expected_path status registry_count admin_dir
    local actual_common actual_git_dir actual_branch repository_safe path_safe
    local -a repositories managed_workspaces
    machine="$(machine_file)"
    registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    [[ -f "${machine}" ]] || fail "machine workspace metadata is missing: ${machine}"
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    schema="$(jq -r '.schemaVersion' "${machine}")"
    if [[ "${schema}" == 1 ]]; then
        printf 'No managed repositories registered.\n'
        return 0
    fi

    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    mapfile -t repositories < <(jq -c '.repositories | sort_by(.name, .id)[]' "${machine}")
    if (( ${#repositories[@]} == 0 )); then
        release_workspace_lock
        printf 'No managed repositories registered.\n'
        return 0
    fi

    for repository in "${repositories[@]}"; do
        repository_id="$(jq -r '.id' <<< "${repository}")"
        name="$(jq -r '.name' <<< "${repository}")"
        enabled="$(jq -r 'if .enabled then "enabled" else "disabled" end' <<< "${repository}")"
        primary="$(jq -r '.primaryPath' <<< "${repository}")"
        common="$(jq -r '.commonGitDir' <<< "${repository}")"
        repository_root="${PI_RUN_HOME_RESOLVED}/worktrees/${repository_id}"
        repository_safe=false
        if [[ -d "${primary}" && ! -L "${primary}" && -d "${common}" && ! -L "${common}" &&
              "$(realpath "${primary}")" == "${primary}" && "$(realpath "${common}")" == "${common}" &&
              "${common}" == "${primary}/.git" && "$(stat -c %u "${primary}")" == "$(id -u)" &&
              "$(stat -c %u "${common}")" == "$(id -u)" ]]; then
            repository_safe=true
        fi
        printf 'Repository: %s (%s)\n' "$(sanitize_display "${name}")" "${repository_id}"
        printf 'Preference: %s\n' "${enabled}"
        printf 'Primary checkout: %s\n' "$(sanitize_display "${primary}")"
        mapfile -t managed_workspaces < <(jq -c '.managedWorkspaces | sort_by(.createdAt, .workspaceId)[]' <<< "${repository}")
        if (( ${#managed_workspaces[@]} == 0 )); then
            printf 'Managed workspaces: none\n\n'
            continue
        fi
        printf '  %-36s  %-43s  %-20s  %-13s  %s\n' \
            'WORKSPACE ID' BRANCH CREATED STATUS PATH
        for workspace in "${managed_workspaces[@]}"; do
            workspace_id="$(jq -r '.workspaceId' <<< "${workspace}")"
            branch="$(jq -r '.branch' <<< "${workspace}")"
            created="$(jq -r '.createdAt' <<< "${workspace}")"
            path="$(jq -r --arg id "${workspace_id}" '.workspacePaths[] | select(.workspaceId == $id) | .path' "${machine}")"
            expected_path="${repository_root}/${workspace_id}"
            registry_count="$(jq -r --arg id "${workspace_id}" \
                '[.workspaces[] | select(.id == $id)] | length' "${registry}")"
            status=available
            if [[ "${path}" != "${expected_path}" ]]; then
                status="path-conflict"
            elif [[ "${registry_count}" == 0 ]]; then
                status=pending
            elif [[ "${registry_count}" != 1 ||
                    "$(jq -r --arg id "${workspace_id}" '.workspaces[] | select(.id == $id) | .kind' "${registry}")" != git ]]; then
                fail "portable workspace metadata conflicts with managed workspace listing: ${workspace_id}"
            elif [[ ! -e "${path}" && ! -L "${path}" ]]; then
                status=missing
            else
                path_safe=false
                if [[ "${repository_safe}" == true && -d "${path}" && ! -L "${path}" &&
                      "$(realpath "${path}")" == "${path}" && "$(stat -c %u "${path}")" == "$(id -u)" &&
                      -d "${repository_root}" && ! -L "${repository_root}" &&
                      "$(realpath "${repository_root}")" == "${repository_root}" &&
                      "$(stat -c %u "${repository_root}")" == "$(id -u)" &&
                      "$(stat -c %a "${repository_root}")" == 700 ]]; then
                    path_safe=true
                fi
                if [[ "${path_safe}" == false ]]; then
                    status=unsafe
                else
                    admin_dir="${common}/worktrees/${workspace_id}"
                    if [[ ! -d "${admin_dir}" || -L "${admin_dir}" ||
                          "$(stat -c %u "${admin_dir}" 2>/dev/null)" != "$(id -u)" ||
                          ! -f "${path}/.git" || -L "${path}/.git" ||
                          "$(stat -c %u "${path}/.git" 2>/dev/null)" != "$(id -u)" ||
                          "$(stat -c %h "${path}/.git" 2>/dev/null)" != 1 ]]; then
                        status=unsafe
                    else
                        actual_common="$(git -C "${path}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
                        actual_git_dir="$(git -C "${path}" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
                        actual_branch="$(git -C "${path}" symbolic-ref --quiet HEAD 2>/dev/null || true)"
                        if [[ "${actual_common}" != "${common}" || "${actual_git_dir}" != "${admin_dir}" ||
                              "${actual_branch}" != "refs/heads/${branch}" ]]; then
                            status="git-conflict"
                        fi
                    fi
                fi
            fi
            printf '  %-36s  %-43s  %-20s  %-13s  %s\n' \
                "${workspace_id}" "$(sanitize_display "${branch}")" "${created}" "${status}" \
                "$(sanitize_display "${path}")"
        done
        printf '\n'
    done
    release_workspace_lock
}

worktree_preference_enabled_for_path() {
    local selected="$1" machine schema common_raw common count enabled
    command -v git >/dev/null 2>&1 || return 1
    [[ -d "${selected}" ]] || return 1
    [[ "$(git -C "${selected}" rev-parse --is-inside-work-tree 2>/dev/null)" == true &&
       "$(git -C "${selected}" rev-parse --is-bare-repository 2>/dev/null)" == false ]] || return 1
    machine="$(machine_file)"
    [[ -f "${machine}" ]] || return 1
    validate_workspace_metadata "${machine}"
    schema="$(jq -r '.schemaVersion' "${machine}")"
    [[ "${schema}" == 2 ]] || return 1
    validate_worktree_machine_file "${machine}"
    common_raw="$(git -C "${selected}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
        || return 1
    [[ -e "${common_raw}" ]] || return 1
    common="$(realpath "${common_raw}")"

    acquire_workspace_lock
    validate_workspace_metadata "${machine}"
    count="$(jq -r --arg common "${common}" \
        '[.repositories[] | select(.commonGitDir == $common)] | length' "${machine}")"
    [[ "${count}" == 0 || "${count}" == 1 ]] || fail "repository metadata is ambiguous"
    if [[ "${count}" == 0 ]]; then
        release_workspace_lock
        return 1
    fi
    enabled="$(jq -r --arg common "${common}" \
        '.repositories[] | select(.commonGitDir == $common) | .enabled' "${machine}")"
    release_workspace_lock
    [[ "${enabled}" == true ]] || return 1
    resolve_worktree_repository "${selected}"
}

MANAGED_LAUNCH_LOCK_DIR=""
MANAGED_LAUNCH_LOCK_TOKEN=""

process_start_token() {
    local pid="$1" stat rest
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 2
    [[ -e "/proc/${pid}/stat" ]] || return 1
    [[ -r "/proc/${pid}/stat" ]] || return 2
    stat="$(< "/proc/${pid}/stat")"
    [[ "${stat}" == *") "* ]] || return 2
    rest="${stat##*) }"
    # The tail begins with field 3, so process start time (field 22) is item 20.
    # shellcheck disable=SC2086 # Intentional splitting of procfs fields.
    set -- ${rest}
    (( $# >= 20 )) && [[ "${20}" =~ ^[0-9]+$ ]] || return 2
    printf '%s\n' "${20}"
}

validate_managed_launch_lock_owner() {
    local directory="$1" owner="${1}/owner.json"
    [[ -d "${directory}" && ! -L "${directory}" && "$(realpath "${directory}")" == "${directory}" &&
       "$(stat -c %u "${directory}")" == "$(id -u)" && "$(stat -c %a "${directory}")" == 700 ]] \
        || return 1
    [[ "$(find "${directory}" -mindepth 1 -maxdepth 1 -printf '%f\n')" == owner.json ]] || return 1
    [[ -f "${owner}" && ! -L "${owner}" && "$(realpath "${owner}")" == "${owner}" &&
       "$(stat -c %h "${owner}")" == 1 && "$(stat -c %u "${owner}")" == "$(id -u)" &&
       "$(stat -c %a "${owner}")" == 600 ]] || return 1
    jq -e '
        (keys | sort == ["createdAt","machineId","ownershipToken","pid","processStartToken","schemaVersion","workspaceId"]) and
        .schemaVersion == 1 and
        (.machineId | type == "string" and test("^[0-9a-f]{16}$")) and
        (.pid | type == "number" and floor == . and . >= 1) and
        (.processStartToken | type == "string" and test("^[0-9]+$")) and
        (.ownershipToken | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        (.workspaceId | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
        (.createdAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' "${owner}" >/dev/null 2>&1
}

acquire_managed_launch_lock() {
    local workspace_id="$1" root lock owner machine current_start token created attempt
    local owner_machine owner_pid owner_start stale actual_start status
    [[ "${workspace_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "invalid managed workspace UUID for launch lock: ${workspace_id}"
    [[ -z "${MANAGED_LAUNCH_LOCK_DIR}" && -z "${MANAGED_LAUNCH_LOCK_TOKEN}" ]] \
        || fail "this Pi-Run process already owns a managed workspace launch lock"
    root="${PI_RUN_HOME_RESOLVED}/worktrees/.launch-locks"
    if [[ ! -e "${root}" && ! -L "${root}" ]]; then
        mkdir "${root}"
        chmod 0700 "${root}"
    fi
    [[ -d "${root}" && ! -L "${root}" && "$(realpath "${root}")" == "${root}" &&
       "$(stat -c %u "${root}")" == "$(id -u)" && "$(stat -c %a "${root}")" == 700 ]] \
        || fail "managed launch lock root is unsafe: ${root}"
    lock="${root}/${workspace_id}"
    machine="$(machine_id)"
    current_start="$(process_start_token "$$")" \
        || fail "could not determine the current process start token"

    for attempt in 1 2; do
        if mkdir "${lock}" 2>/dev/null; then
            chmod 0700 "${lock}"
            token="$(new_workspace_id)"
            created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            owner="${lock}/owner.json"
            jq -n --arg machine "${machine}" --argjson pid "$$" --arg start "${current_start}" \
                --arg token "${token}" --arg workspace "${workspace_id}" --arg created "${created}" \
                '{schemaVersion:1,machineId:$machine,pid:$pid,processStartToken:$start,
                  ownershipToken:$token,workspaceId:$workspace,createdAt:$created}' > "${owner}.tmp"
            chmod 0600 "${owner}.tmp"
            mv "${owner}.tmp" "${owner}"
            MANAGED_LAUNCH_LOCK_DIR="${lock}"
            MANAGED_LAUNCH_LOCK_TOKEN="${token}"
            return 0
        fi
        validate_managed_launch_lock_owner "${lock}" \
            || fail "managed workspace launch lock is unsafe or ambiguous: ${lock}"
        owner="${lock}/owner.json"
        owner_machine="$(jq -r '.machineId' "${owner}")"
        owner_pid="$(jq -r '.pid' "${owner}")"
        owner_start="$(jq -r '.processStartToken' "${owner}")"
        [[ "${owner_machine}" == "${machine}" && "$(jq -r '.workspaceId' "${owner}")" == "${workspace_id}" ]] \
            || fail "managed workspace launch lock belongs to different machine metadata: ${lock}"
        set +e
        actual_start="$(process_start_token "${owner_pid}")"
        status=$?
        set -e
        if (( status == 0 )) && [[ "${actual_start}" == "${owner_start}" ]]; then
            fail "managed workspace is already active: ${workspace_id} (pid ${owner_pid})"
        elif (( status > 1 )); then
            fail "managed workspace launch lock owner cannot be verified safely: ${lock}"
        fi
        stale="${root}/.stale-${workspace_id}-$(new_workspace_id)"
        if mv -T "${lock}" "${stale}" 2>/dev/null; then
            validate_managed_launch_lock_owner "${stale}" \
                || fail "renamed stale managed launch lock became unsafe: ${stale}"
            rm "${stale}/owner.json"
            rmdir "${stale}"
        elif (( attempt == 2 )); then
            fail "managed workspace launch lock changed during stale recovery: ${lock}"
        fi
    done
    fail "could not acquire managed workspace launch lock: ${workspace_id}"
}

release_managed_launch_lock() {
    local owner token
    [[ -n "${MANAGED_LAUNCH_LOCK_DIR}" && -n "${MANAGED_LAUNCH_LOCK_TOKEN}" ]] || return 0
    validate_managed_launch_lock_owner "${MANAGED_LAUNCH_LOCK_DIR}" || return 1
    owner="${MANAGED_LAUNCH_LOCK_DIR}/owner.json"
    token="$(jq -r '.ownershipToken' "${owner}")"
    [[ "${token}" == "${MANAGED_LAUNCH_LOCK_TOKEN}" ]] || return 1
    rm "${owner}" || return 1
    rmdir "${MANAGED_LAUNCH_LOCK_DIR}" || return 1
    MANAGED_LAUNCH_LOCK_DIR=""
    MANAGED_LAUNCH_LOCK_TOKEN=""
}

managed_workspace_association_exists() {
    local workspace_id="$1" machine count
    machine="$(machine_file)"
    [[ -f "${machine}" ]] || return 1
    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    if [[ "$(jq -r '.schemaVersion' "${machine}")" != 2 ]]; then
        release_workspace_lock
        return 1
    fi
    count="$(jq -r --arg id "${workspace_id}" \
        '[.repositories[].managedWorkspaces[] | select(.workspaceId == $id)] | length' "${machine}")"
    release_workspace_lock
    [[ "${count}" == 0 ]] && return 1
    [[ "${count}" == 1 ]] || fail "managed workspace association is ambiguous: ${workspace_id}"
}

RESOLVED_MANAGED_BRANCH=""
RESOLVED_MANAGED_COMMON_DIR=""
RESOLVED_MANAGED_HEAD=""

resolve_managed_workspace_launch() {
    local workspace_id="$1" worktree="$2" machine registry association_count repository_id branch mapped_path
    local common primary expected_path admin_dir registry_count actual_common actual_git_dir actual_branch
    RESOLVED_MANAGED_BRANCH=""
    RESOLVED_MANAGED_COMMON_DIR=""
    RESOLVED_MANAGED_HEAD=""
    machine="$(machine_file)"
    registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    [[ -f "${machine}" ]] || return 1

    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    if [[ "$(jq -r '.schemaVersion' "${machine}")" != 2 ]]; then
        release_workspace_lock
        return 1
    fi
    association_count="$(jq -r --arg id "${workspace_id}" \
        '[.repositories[].managedWorkspaces[] | select(.workspaceId == $id)] | length' "${machine}")"
    if [[ "${association_count}" == 0 ]]; then
        release_workspace_lock
        return 1
    fi
    [[ "${association_count}" == 1 ]] || fail "managed workspace association is ambiguous: ${workspace_id}"
    repository_id="$(jq -r --arg id "${workspace_id}" '
        .repositories[] | select(any(.managedWorkspaces[]; .workspaceId == $id)) | .id
    ' "${machine}")"
    branch="$(jq -r --arg id "${workspace_id}" '
        .repositories[].managedWorkspaces[] | select(.workspaceId == $id) | .branch
    ' "${machine}")"
    mapped_path="$(jq -r --arg id "${workspace_id}" '.workspacePaths[] | select(.workspaceId == $id) | .path' "${machine}")"
    common="$(jq -r --arg id "${repository_id}" '.repositories[] | select(.id == $id) | .commonGitDir' "${machine}")"
    primary="$(jq -r --arg id "${repository_id}" '.repositories[] | select(.id == $id) | .primaryPath' "${machine}")"
    registry_count="$(jq -r --arg id "${workspace_id}" \
        '[.workspaces[] | select(.id == $id)] | length' "${registry}")"
    release_workspace_lock

    [[ "${branch}" == "pi-run/${workspace_id}" ]] \
        || fail "managed resume branch metadata conflicts with its workspace identity: ${workspace_id}"
    expected_path="${PI_RUN_HOME_RESOLVED}/worktrees/${repository_id}/${workspace_id}"
    [[ "${mapped_path}" == "${expected_path}" && "${worktree}" == "${expected_path}" ]] \
        || fail "managed resume path conflicts with its workspace identity: ${workspace_id}"
    [[ "${registry_count}" == 1 &&
       "$(jq -r --arg id "${workspace_id}" '.workspaces[] | select(.id == $id) | .kind' "${registry}")" == git ]] \
        || fail "portable workspace metadata conflicts with managed resume: ${workspace_id}"
    [[ -d "${worktree}" && ! -L "${worktree}" && "$(realpath "${worktree}")" == "${worktree}" &&
       "$(stat -c %u "${worktree}")" == "$(id -u)" ]] \
        || fail "managed resume worktree is missing or unsafe: ${worktree}"
    [[ -d "${common}" && ! -L "${common}" && -d "${primary}" && ! -L "${primary}" &&
       "$(realpath "${common}")" == "${common}" && "$(realpath "${primary}")" == "${primary}" &&
       "${common}" == "${primary}/.git" && "$(stat -c %u "${common}")" == "$(id -u)" &&
       "$(stat -c %u "${primary}")" == "$(id -u)" ]] \
        || fail "managed resume repository paths are missing or unsafe"
    admin_dir="${common}/worktrees/${workspace_id}"
    [[ -d "${admin_dir}" && ! -L "${admin_dir}" && -f "${worktree}/.git" && ! -L "${worktree}/.git" ]] \
        || fail "managed resume Git administration is missing or unsafe: ${worktree}"
    actual_common="$(git -C "${worktree}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    actual_git_dir="$(git -C "${worktree}" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    actual_branch="$(git -C "${worktree}" symbolic-ref --quiet HEAD 2>/dev/null || true)"
    [[ "${actual_common}" == "${common}" && "${actual_git_dir}" == "${admin_dir}" &&
       "${actual_branch}" == "refs/heads/${branch}" ]] \
        || fail "managed resume Git state conflicts with metadata: ${workspace_id}"
    # Consumed by launcher dispatch after managed association resolution.
    # shellcheck disable=SC2034
    RESOLVED_MANAGED_HEAD="$(git -C "${worktree}" rev-parse --verify HEAD 2>/dev/null)" \
        || fail "managed resume worktree has no committed HEAD: ${workspace_id}"
    # shellcheck disable=SC2034
    RESOLVED_MANAGED_BRANCH="${branch}"
    # shellcheck disable=SC2034
    RESOLVED_MANAGED_COMMON_DIR="${common}"
}

ensure_worktree_repository_record() {
    local selected="${1:-.}" machine count repository_id created
    resolve_worktree_repository "${selected}"
    machine="$(ensure_worktree_machine_metadata)"
    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    count="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
        '[.repositories[] | select(.commonGitDir == $common)] | length' "${machine}")"
    [[ "${count}" == 0 || "${count}" == 1 ]] || fail "repository metadata is ambiguous"
    if [[ "${count}" == 0 ]]; then
        repository_id="$(new_workspace_id)"
        created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        # shellcheck disable=SC2016 # Dollar-prefixed names are jq variables.
        update_json "${machine}" --arg id "${repository_id}" --arg name "${WORKTREE_REPOSITORY_NAME}" \
            --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" --arg primary "${WORKTREE_REPOSITORY_PRIMARY_PATH}" \
            --arg created "${created}" '
            .repositories += [{id:$id,name:$name,commonGitDir:$common,primaryPath:$primary,
                enabled:false,createdAt:$created,managedWorkspaces:[]}]
        '
    else
        repository_id="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
            '.repositories[] | select(.commonGitDir == $common) | .id' "${machine}")"
        jq -e --arg id "${repository_id}" --arg name "${WORKTREE_REPOSITORY_NAME}" \
            --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" --arg primary "${WORKTREE_REPOSITORY_PRIMARY_PATH}" '
            [.repositories[] | select(.id == $id and .name == $name and
                .commonGitDir == $common and .primaryPath == $primary)] | length == 1
        ' "${machine}" >/dev/null || fail "registered repository metadata no longer matches the selected checkout"
    fi
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    release_workspace_lock
    printf '%s\n' "${repository_id}"
}

create_managed_worktree_checkout() (
    local workspace_id="$1" selected="${2:-.}" machine registry record_count repository_id branch base dirty
    local root repository_root worktree admin_dir image pointer="" git_dir output status
    local root_created=false repository_root_created=false
    [[ "${workspace_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "invalid managed workspace UUID: ${workspace_id}"
    command -v docker >/dev/null 2>&1 || fail "docker is required for managed worktree creation"
    resolve_worktree_repository "${selected}"
    machine="$(ensure_worktree_machine_metadata)"
    registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    image="${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}"
    docker image inspect "${image}" >/dev/null 2>&1 \
        || fail "runtime image is unavailable locally: ${image}"

    base="$(git -C "${WORKTREE_REPOSITORY_SELECTED_PATH}" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
        || fail "selected repository does not have a committed HEAD"
    [[ "${base}" =~ ^[0-9a-f]{40,64}$ ]] || fail "selected repository returned an invalid HEAD commit"
    dirty="$(git -c core.fsmonitor=false -c core.untrackedCache=false \
        -C "${WORKTREE_REPOSITORY_SELECTED_PATH}" status --porcelain --untracked-files=normal)" \
        || fail "could not inspect the selected checkout state"
    if [[ -n "${dirty}" ]]; then
        printf 'pi-run: selected checkout has uncommitted changes; managed worktree %s starts at %s and excludes them\n' \
            "${workspace_id}" "${base}" >&2
    fi

    acquire_workspace_lock
    trap 'rm -f "${pointer:-}"; rmdir "${WORKSPACE_LOCK:-}" 2>/dev/null || true' EXIT
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    record_count="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
        '[.repositories[] | select(.commonGitDir == $common)] | length' "${machine}")"
    [[ "${record_count}" == 1 ]] || fail "repository is not registered uniquely for managed worktrees"
    repository_id="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
        '.repositories[] | select(.commonGitDir == $common) | .id' "${machine}")"
    [[ "${repository_id}" =~ ^[0-9a-f-]{36}$ ]] || fail "repository metadata has an invalid identity"
    [[ "$(jq -r --arg id "${workspace_id}" \
        '[.workspacePaths[], .repositories[].managedWorkspaces[] | select(.workspaceId == $id)] | length' \
        "${machine}")" == 0 ]] || fail "managed workspace UUID already exists in machine metadata: ${workspace_id}"
    [[ "$(jq -r --arg id "${workspace_id}" \
        '[.workspaces[] | select(.id == $id)] | length' "${registry}")" == 0 ]] \
        || fail "managed workspace UUID already exists in the workspace registry: ${workspace_id}"

    branch="pi-run/${workspace_id}"
    git check-ref-format --branch "${branch}" >/dev/null 2>&1 \
        || fail "invalid managed worktree branch: ${branch}"
    if git -C "${WORKTREE_REPOSITORY_SELECTED_PATH}" show-ref --verify --quiet "refs/heads/${branch}"; then
        fail "managed worktree branch already exists: ${branch}"
    fi
    root="${PI_RUN_HOME_RESOLVED}/worktrees"
    repository_root="${root}/${repository_id}"
    worktree="${repository_root}/${workspace_id}"
    admin_dir="${WORKTREE_REPOSITORY_COMMON_DIR}/worktrees/${workspace_id}"
    for output in "${root}" "${repository_root}" "${worktree}" "${WORKTREE_REPOSITORY_COMMON_DIR}"; do
        [[ "${output}" != *,* ]] || fail "managed worktree paths containing commas are not supported: ${output}"
    done
    for output in "${worktree}" "${admin_dir}"; do
        [[ ! -e "${output}" && ! -L "${output}" ]] \
            || fail "managed worktree path already exists: ${output}"
    done
    for output in "${root}" "${repository_root}"; do
        if [[ -e "${output}" || -L "${output}" ]]; then
            [[ -d "${output}" && ! -L "${output}" && "$(realpath "${output}")" == "${output}" &&
               "$(stat -c %u "${output}")" == "$(id -u)" && "$(stat -c %a "${output}")" == 700 ]] \
                || fail "managed worktree directory is unsafe: ${output}"
        else
            mkdir "${output}"
            chmod 0700 "${output}"
            if [[ "${output}" == "${root}" ]]; then
                root_created=true
            else
                repository_root_created=true
            fi
        fi
    done

    if ! git -C "${WORKTREE_REPOSITORY_SELECTED_PATH}" worktree add --no-checkout -q \
        -b "${branch}" "${worktree}" "${base}"; then
        if [[ ! -e "${worktree}" && ! -L "${worktree}" && ! -e "${admin_dir}" &&
              "$(git -C "${WORKTREE_REPOSITORY_SELECTED_PATH}" rev-parse --verify "refs/heads/${branch}" 2>/dev/null || true)" == "${base}" ]]; then
            git -C "${WORKTREE_REPOSITORY_SELECTED_PATH}" branch -D "${branch}" >/dev/null 2>&1 || true
        fi
        if [[ -e "${worktree}" || -e "${admin_dir}" ||
              -n "$(git -C "${WORKTREE_REPOSITORY_SELECTED_PATH}" rev-parse --verify "refs/heads/${branch}" 2>/dev/null || true)" ]]; then
            fail "managed worktree administration failed; partial state was preserved at ${worktree}"
        fi
        [[ "${repository_root_created}" == false ]] || rmdir "${repository_root}" 2>/dev/null || true
        [[ "${root_created}" == false ]] || rmdir "${root}" 2>/dev/null || true
        fail "managed worktree administration failed and its empty state was rolled back"
    fi
    git_dir="$(git -C "${worktree}" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    [[ "${git_dir}" == "${admin_dir}" && -d "${admin_dir}" && ! -L "${admin_dir}" &&
       -f "${worktree}/.git" && ! -L "${worktree}/.git" ]] \
        || fail "created managed worktree has unexpected Git administration"

    pointer="$(mktemp "${root}/.git-pointer-${workspace_id}.XXXXXX")"
    printf 'gitdir: /run/pi-run-git/common/worktrees/%s\n' "${workspace_id}" > "${pointer}"
    chmod 0600 "${pointer}"
    set +e
    docker run --rm --pull never --network none --cap-drop ALL \
        --security-opt no-new-privileges=true --read-only \
        --tmpfs "/tmp:rw,nosuid,nodev,noexec" --user "$(id -u):$(id -g)" \
        --env HOME=/tmp --env GIT_CONFIG_NOSYSTEM=1 --env "PI_RUN_WORKTREE_BASE=${base}" \
        --workdir /workspace --entrypoint bash \
        --mount "type=bind,src=${worktree},dst=/workspace" \
        --mount "type=bind,src=${WORKTREE_REPOSITORY_COMMON_DIR},dst=/run/pi-run-git/common" \
        --mount "type=bind,src=${pointer},dst=/workspace/.git,readonly" \
        "${image}" -ceu '
            git -c core.hooksPath=/dev/null reset --hard "${PI_RUN_WORKTREE_BASE}" >/dev/null
            test "$(git rev-parse HEAD)" = "${PI_RUN_WORKTREE_BASE}"
        '
    status=$?
    set -e
    rm -f "${pointer}"
    pointer=""
    if (( status != 0 )); then
        output="$(find "${worktree}" -mindepth 1 -maxdepth 1 ! -name .git -print -quit 2>/dev/null || true)"
        if [[ -z "${output}" &&
              "$(git -C "${worktree}" rev-parse --verify HEAD 2>/dev/null || true)" == "${base}" &&
              "$(git -C "${worktree}" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)" == "${admin_dir}" ]]; then
            git -C "${WORKTREE_REPOSITORY_SELECTED_PATH}" worktree remove --force "${worktree}" >/dev/null 2>&1 || true
            if [[ ! -e "${worktree}" && ! -e "${admin_dir}" ]]; then
                git -C "${WORKTREE_REPOSITORY_SELECTED_PATH}" branch -D "${branch}" >/dev/null 2>&1 || true
            fi
        fi
        if [[ -e "${worktree}" || -e "${admin_dir}" ||
              -n "$(git -C "${WORKTREE_REPOSITORY_SELECTED_PATH}" rev-parse --verify "refs/heads/${branch}" 2>/dev/null || true)" ]]; then
            fail "managed worktree materialization failed; partial state was preserved at ${worktree}"
        fi
        [[ "${repository_root_created}" == false ]] || rmdir "${repository_root}" 2>/dev/null || true
        [[ "${root_created}" == false ]] || rmdir "${root}" 2>/dev/null || true
        fail "managed worktree materialization failed and its empty state was rolled back"
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${workspace_id}" "${repository_id}" "${branch}" "${worktree}" "${base}"
    release_workspace_lock
)

publish_managed_worktree_metadata() (
    local workspace_id="$1" repository_id="$2" branch="$3" worktree="$4"
    local machine registry expected_path common primary admin_dir actual_common actual_git_dir actual_branch
    local machine_path_count machine_association_count registry_count created name registry_staging=""
    [[ "${workspace_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "invalid managed workspace UUID: ${workspace_id}"
    [[ "${repository_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "invalid managed repository UUID: ${repository_id}"
    [[ "${branch}" == "pi-run/${workspace_id}" ]] \
        || fail "managed worktree branch does not match its workspace identity: ${branch}"
    expected_path="${PI_RUN_HOME_RESOLVED}/worktrees/${repository_id}/${workspace_id}"
    [[ "${worktree}" == "${expected_path}" ]] \
        || fail "managed worktree path does not match its workspace identity: ${worktree}"

    machine="$(ensure_worktree_machine_metadata)"
    registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    acquire_workspace_lock
    trap 'rm -f "${registry_staging:-}"; rmdir "${WORKSPACE_LOCK:-}" 2>/dev/null || true' EXIT
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    [[ "$(jq -r --arg id "${repository_id}" '[.repositories[] | select(.id == $id)] | length' "${machine}")" == 1 ]] \
        || fail "managed worktree repository identity is not registered uniquely: ${repository_id}"
    common="$(jq -r --arg id "${repository_id}" '.repositories[] | select(.id == $id) | .commonGitDir' "${machine}")"
    primary="$(jq -r --arg id "${repository_id}" '.repositories[] | select(.id == $id) | .primaryPath' "${machine}")"
    name="$(jq -r --arg id "${repository_id}" '.repositories[] | select(.id == $id) | .name' "${machine}")"
    admin_dir="${common}/worktrees/${workspace_id}"

    [[ -d "${worktree}" && ! -L "${worktree}" && "$(realpath "${worktree}")" == "${worktree}" &&
       "$(stat -c %u "${worktree}")" == "$(id -u)" ]] \
        || fail "managed worktree checkout is missing or unsafe: ${worktree}"
    [[ -d "${common}" && ! -L "${common}" && -d "${primary}" && ! -L "${primary}" &&
       "$(realpath "${common}")" == "${common}" && "$(realpath "${primary}")" == "${primary}" &&
       "${common}" == "${primary}/.git" && "$(stat -c %u "${common}")" == "$(id -u)" &&
       "$(stat -c %u "${primary}")" == "$(id -u)" ]] \
        || fail "managed worktree repository paths are missing or unsafe"
    [[ -d "${admin_dir}" && ! -L "${admin_dir}" && -f "${worktree}/.git" && ! -L "${worktree}/.git" ]] \
        || fail "managed worktree Git administration is missing or unsafe: ${worktree}"
    actual_common="$(git -C "${worktree}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    actual_git_dir="$(git -C "${worktree}" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    actual_branch="$(git -C "${worktree}" symbolic-ref --quiet HEAD 2>/dev/null || true)"
    [[ "${actual_common}" == "${common}" && "${actual_git_dir}" == "${admin_dir}" &&
       "${actual_branch}" == "refs/heads/${branch}" ]] \
        || fail "managed worktree Git relationship does not match its metadata"

    machine_path_count="$(jq -r --arg id "${workspace_id}" --arg path "${worktree}" '
        [.workspacePaths[] | select(.workspaceId == $id or .path == $path)] | length
    ' "${machine}")"
    machine_association_count="$(jq -r --arg id "${workspace_id}" '
        [.repositories[].managedWorkspaces[] | select(.workspaceId == $id)] | length
    ' "${machine}")"
    registry_count="$(jq -r --arg id "${workspace_id}" \
        '[.workspaces[] | select(.id == $id)] | length' "${registry}")"

    if [[ "${machine_path_count}" == 0 && "${machine_association_count}" == 0 ]]; then
        [[ "${registry_count}" == 0 ]] \
            || fail "portable workspace metadata exists without a managed machine association: ${workspace_id}"
        created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        # shellcheck disable=SC2016 # Dollar-prefixed names are jq variables.
        update_json "${machine}" --arg id "${workspace_id}" --arg path "${worktree}" \
            --arg repository "${repository_id}" --arg branch "${branch}" --arg created "${created}" '
            .workspacePaths += [{workspaceId:$id,path:$path}] |
            (.repositories[] | select(.id == $repository) | .managedWorkspaces) +=
                [{workspaceId:$id,branch:$branch,createdAt:$created}]
        '
        validate_worktree_machine_file "${machine}"
        validate_workspace_metadata "${machine}"
    elif [[ "${machine_path_count}" == 1 && "${machine_association_count}" == 1 ]]; then
        jq -e --arg id "${workspace_id}" --arg path "${worktree}" --arg repository "${repository_id}" \
            --arg branch "${branch}" '
            ([.workspacePaths[] | select(.workspaceId == $id and .path == $path)] | length) == 1 and
            ([.repositories[] | select(.id == $repository) | .managedWorkspaces[] |
                select(.workspaceId == $id and .branch == $branch)] | length) == 1
        ' "${machine}" >/dev/null || fail "managed machine metadata conflicts with the prepared worktree"
        created="$(jq -r --arg id "${workspace_id}" '
            .repositories[].managedWorkspaces[] | select(.workspaceId == $id) | .createdAt
        ' "${machine}")"
    else
        fail "managed machine metadata is incomplete or ambiguous: ${workspace_id}"
    fi

    registry_count="$(jq -r --arg id "${workspace_id}" \
        '[.workspaces[] | select(.id == $id)] | length' "${registry}")"
    if [[ "${registry_count}" == 0 ]]; then
        registry_staging="${registry}.tmp.$$"
        # shellcheck disable=SC2016 # Dollar-prefixed names are jq variables.
        if ! jq --arg id "${workspace_id}" --arg name "${name}" --arg created "${created}" \
            '.workspaces += [{id:$id,name:$name,kind:"git",createdAt:$created}]' \
            "${registry}" > "${registry_staging}"; then
            fail "portable workspace publication failed; the machine association remains pending: ${workspace_id}"
        fi
        if ! chmod 0600 "${registry_staging}"; then
            fail "portable workspace publication failed; the machine association remains pending: ${workspace_id}"
        fi
        if ! mv "${registry_staging}" "${registry}"; then
            fail "portable workspace publication failed; the machine association remains pending: ${workspace_id}"
        fi
        registry_staging=""
        validate_workspace_metadata "${machine}"
    elif [[ "${registry_count}" == 1 ]]; then
        jq -e --arg id "${workspace_id}" --arg name "${name}" --arg created "${created}" '
            [.workspaces[] | select(.id == $id)] | .[0] |
            (keys | sort == ["createdAt","id","kind","name"]) and
            .name == $name and .kind == "git" and .createdAt == $created
        ' "${registry}" >/dev/null || fail "portable workspace metadata conflicts with the managed machine association"
    else
        fail "portable workspace metadata is ambiguous: ${workspace_id}"
    fi

    release_workspace_lock
    printf '%s\n' "${workspace_id}"
)

set_worktree_preference() {
    local enabled="$1" machine count current id created changed=false
    resolve_worktree_repository
    machine="$(ensure_worktree_machine_metadata)"
    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    count="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
        '[.repositories[] | select(.commonGitDir == $common)] | length' "${machine}")"
    [[ "${count}" == 0 || "${count}" == 1 ]] || fail "repository metadata is ambiguous"
    if [[ "${count}" == 0 && "${enabled}" == true ]]; then
        id="$(new_workspace_id)"
        created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        # shellcheck disable=SC2016 # Dollar-prefixed names are jq variables.
        update_json "${machine}" --arg id "${id}" --arg name "${WORKTREE_REPOSITORY_NAME}" \
            --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" --arg primary "${WORKTREE_REPOSITORY_PRIMARY_PATH}" \
            --arg created "${created}" \
            '.repositories += [{id:$id,name:$name,commonGitDir:$common,primaryPath:$primary,enabled:true,createdAt:$created,managedWorkspaces:[]}]'
        changed=true
    elif [[ "${count}" == 1 ]]; then
        current="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
            '.repositories[] | select(.commonGitDir == $common) | .enabled' "${machine}")"
        if [[ "${current}" != "${enabled}" ]]; then
            # shellcheck disable=SC2016 # Dollar-prefixed names are jq variables.
            update_json "${machine}" --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" --argjson enabled "${enabled}" \
                '(.repositories[] | select(.commonGitDir == $common) | .enabled) = $enabled'
            changed=true
        fi
    fi
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    release_workspace_lock
    print_worktree_preference "${machine}"
    if [[ "${changed}" == true ]]; then
        printf 'Preference updated; existing workspaces and sessions are unchanged.\n'
    else
        printf 'Preference unchanged.\n'
    fi
}

WORKSPACE_LOCK=""
acquire_workspace_lock() {
    WORKSPACE_LOCK="${PI_RUN_HOME_RESOLVED}/workspaces/.registry.lock"
    if ! mkdir "${WORKSPACE_LOCK}" 2>/dev/null; then
        fail "workspace registry is locked: ${WORKSPACE_LOCK}"
    fi
    trap 'rmdir "${WORKSPACE_LOCK}" 2>/dev/null || true' EXIT
}

release_workspace_lock() {
    rmdir "${WORKSPACE_LOCK}"
    WORKSPACE_LOCK=""
    trap - EXIT
}

update_json() {
    local file="$1"
    shift
    local temporary="${file}.tmp.$$"
    if ! jq "$@" "${file}" > "${temporary}"; then
        rm -f "${temporary}"
        fail "could not update JSON file: ${file}"
    fi
    chmod 0600 "${temporary}"
    mv "${temporary}" "${file}"
}

new_workspace_id() {
    local id=""
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        id="$(< /proc/sys/kernel/random/uuid)"
    elif command -v uuidgen >/dev/null 2>&1; then
        id="$(uuidgen)"
    fi
    [[ "${id}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        || fail "could not generate a workspace UUID"
    printf '%s\n' "${id,,}"
}


ensure_workspace_registered() {
    local path="$1"
    local registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    local machine
    local id
    machine="$(machine_file)"

    acquire_workspace_lock
    initialize_machine_file "${machine}"
    validate_workspace_metadata "${machine}"

    id="$(jq -r --arg path "${path}" '
        [.workspacePaths[] | select(.path == $path)] |
        if length > 1 then error("duplicate workspace path")
        else (.[0].workspaceId // "") end
    ' "${machine}")"

    if [[ -n "${id}" ]]; then
        [[ "$(jq -r --arg id "${id}" '[.workspaces[] | select(.id == $id)] | length' "${registry}")" == 1 ]] \
            || fail "machine mapping references an unknown workspace: ${id}"
        release_workspace_lock
        printf '%s\n' "${id}"
        return 0
    fi

    id="$(new_workspace_id)"
    local name kind created_at
    name="$(basename "${path}")"
    kind="directory"
    if git -C "${path}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        kind="git"
    fi
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    update_json "${registry}" \
        --arg id "${id}" --arg name "${name}" --arg kind "${kind}" --arg createdAt "${created_at}" \
        ".workspaces += [{id:\$id,name:\$name,kind:\$kind,createdAt:\$createdAt}]"
    update_json "${machine}" \
        --arg id "${id}" --arg path "${path}" \
        ".workspacePaths += [{workspaceId:\$id,path:\$path}]"
    release_workspace_lock

    echo "pi-run: registered workspace ${name} (${id})" >&2
    printf '%s\n' "${id}"
}

list_workspaces() {
    local registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    local machine row id name path id_width=2 name_width=4
    local -a rows ids=() names=() paths=()
    machine="$(machine_file)"
    acquire_workspace_lock
    initialize_machine_file "${machine}"
    validate_workspace_metadata "${machine}"

    mapfile -t rows < <(jq -r --slurpfile machine "${machine}" '
        .workspaces[] as $workspace |
        ($machine[0].workspacePaths |
            map(select(.workspaceId == $workspace.id)) |
            (.[0].path // "-")) as $path |
        [$workspace.id, $workspace.name, $path] | @tsv
    ' "${registry}")
    release_workspace_lock
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r id name path <<< "${row}"
        id="$(sanitize_display "${id}")"
        name="$(sanitize_display "${name}")"
        path="$(sanitize_display "${path}")"
        ids+=("${id}")
        names+=("${name}")
        paths+=("${path}")
        (( ${#id} > id_width )) && id_width=${#id}
        (( ${#name} > name_width )) && name_width=${#name}
    done
    printf '%-*s  %-*s  %s\n' "${id_width}" ID "${name_width}" NAME PATH
    for id in "${!ids[@]}"; do
        printf '%-*s  %-*s  %s\n' "${id_width}" "${ids[id]}" \
            "${name_width}" "${names[id]}" "${paths[id]}"
    done
}

link_workspace() {
    local id="$1"
    local input_path="$2"
    local registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    local machine path existing

    [[ -d "${input_path}" ]] || fail "workspace does not exist: ${input_path}"
    path="$(realpath "${input_path}")"
    machine="$(machine_file)"

    acquire_workspace_lock
    initialize_machine_file "${machine}"
    validate_workspace_metadata "${machine}"

    [[ "$(jq -r --arg id "${id}" '[.workspaces[] | select(.id == $id)] | length' "${registry}")" == 1 ]] \
        || fail "unknown workspace ID: ${id}"
    existing="$(jq -r --arg path "${path}" '
        [.workspacePaths[] | select(.path == $path)] |
        if length > 1 then error("duplicate workspace path")
        else (.[0].workspaceId // "") end
    ' "${machine}")"
    [[ -z "${existing}" || "${existing}" == "${id}" ]] \
        || fail "workspace path is already linked to ${existing}: ${path}"

    update_json "${machine}" \
        --arg id "${id}" --arg path "${path}" \
        ".workspacePaths = ([.workspacePaths[] | select(.workspaceId != \$id and .path != \$path)] + [{workspaceId:\$id,path:\$path}])"
    release_workspace_lock
    printf 'Linked workspace %s to %s\n' "${id}" "${path}"
}

