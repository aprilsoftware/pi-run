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
        def timestamp: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
        def task_name: type == "string" and length > 0 and length <= 63 and test("^[a-z0-9][a-z0-9._-]*$");
        def workspace_path:
            (keys | sort == ["path", "workspaceId"]) and
            (.workspaceId | type == "string") and (.path | type == "string");
        def snapshot_auto:
            type == "object" and
            ((.onSessionExit // false) | type == "boolean");
        def task_lifecycle:
            (.createdAt | timestamp) and
            ((.state == "active" and .finishedAt == null) or
             (.state == "finishing" and .finishedAt == null) or
             (.state == "finished" and (.finishedAt | timestamp)));
        def task:
            (keys | sort == ["branch", "createdAt", "finishedAt", "name", "state", "workspaceId"]) and
            (.name | task_name) and (.workspaceId | uuid) and
            .branch == ("pi-run/" + .name) and task_lifecycle;
        def repository:
            (keys | sort == ["commonGitDir", "createdAt", "id", "name", "primaryPath", "tasks"]) and
            (.id | uuid) and
            (.name | type == "string" and length > 0 and length <= 255 and test("^[^\\x00-\\x1f\\x7f]+$")) and
            (.commonGitDir | host_path) and (.primaryPath | host_path) and (.createdAt | timestamp) and
            (.tasks | type == "array") and all(.tasks[]; task) and
            ([.tasks[].name] | length == (unique | length)) and
            ([.tasks[].branch] | length == (unique | length));
        (.repositories // []) as $repositories |
        .schemaVersion == 1 and
        ((keys - ["repositories", "snapshotAuto"]) | sort == ["machineId", "schemaVersion", "workspacePaths"]) and
        ((.snapshotAuto // {}) | snapshot_auto) and
        (.machineId | type == "string" and test("^[0-9a-f]{16}$")) and
        (.workspacePaths | type == "array") and all(.workspacePaths[]; workspace_path) and
        ([.workspacePaths[].workspaceId] | length == (unique | length)) and
        ([.workspacePaths[].path] | length == (unique | length)) and
        ((has("repositories") | not) or (.repositories | type == "array")) and
        ($repositories | type == "array") and all($repositories[]; repository) and
        ([$repositories[].id] | length == (unique | length)) and
        ([$repositories[].commonGitDir] | length == (unique | length)) and
        ([$repositories[].tasks[].workspaceId] | length == (unique | length)) and
        ([.workspacePaths[].workspaceId] as $mapped |
            all($repositories[].tasks[];
                .workspaceId as $id |
                if .state == "finished" then ($mapped | index($id)) == null
                else ($mapped | index($id)) != null end))
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

ensure_worktree_machine_metadata() {
    local machine
    machine="$(machine_file)"
    acquire_workspace_lock
    if [[ -e "${machine}" || -L "${machine}" ]]; then
        validate_worktree_machine_file "${machine}"
    else
        initialize_machine_file "${machine}"
        validate_worktree_machine_file "${machine}"
    fi
    validate_workspace_metadata "${machine}"
    if ! jq -e 'has("repositories")' "${machine}" >/dev/null; then
        update_json "${machine}" '.repositories = []'
        validate_worktree_machine_file "${machine}"
        validate_workspace_metadata "${machine}"
    fi
    release_workspace_lock
    printf '%s\n' "${machine}"
}

WORKTREE_REPOSITORY_NAME=""
WORKTREE_REPOSITORY_COMMON_DIR=""
WORKTREE_REPOSITORY_PRIMARY_PATH=""
WORKTREE_REPOSITORY_SELECTED_PATH=""

validate_worktree_task_name() {
    local name="$1"
    [[ ${#name} -le 63 && "${name}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
        || fail "worktree task name must start with a lowercase letter or digit, contain only lowercase letters, digits, '.', '_', or '-', and be at most 63 characters"
}

worktree_task_start_lock_id() {
    local repository_id="$1" task_name="$2" digest
    validate_worktree_task_name "${task_name}"
    digest="$(printf 'task-start\0%s\0%s' "${repository_id}" "${task_name}" | sha256sum | cut -c1-32)"
    printf '%s-%s-%s-%s-%s\n' \
        "${digest:0:8}" "${digest:8:4}" "${digest:12:4}" "${digest:16:4}" "${digest:20:12}"
}

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

list_managed_worktrees() {
    local include_finished="${1:-false}" machine registry repository repository_id name primary common repository_root
    local task task_name task_state workspace_id branch created path expected_path status registry_count admin_dir
    local actual_common actual_git_dir actual_branch repository_safe path_safe task_width task_length
    local -a repositories tasks
    machine="$(machine_file)"
    registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    [[ -f "${machine}" ]] || fail "machine workspace metadata is missing: ${machine}"
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    mapfile -t repositories < <(jq -c '(.repositories // []) | sort_by(.name, .id)[]' "${machine}")
    if (( ${#repositories[@]} == 0 )); then
        release_workspace_lock
        printf 'No managed repositories registered.\n'
        return 0
    fi

    for repository in "${repositories[@]}"; do
        repository_id="$(jq -r '.id' <<< "${repository}")"
        name="$(jq -r '.name' <<< "${repository}")"
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
        printf 'Repository: %s\n' "$(sanitize_display "${name}")"
        printf 'Primary checkout: %s\n' "$(sanitize_display "${primary}")"
        mapfile -t tasks < <(jq -c --argjson include_finished "${include_finished}" '
            [.tasks[] | select($include_finished or .state != "finished")] |
            sort_by(.createdAt, .name, .workspaceId)[]
        ' <<< "${repository}")
        if (( ${#tasks[@]} == 0 )); then
            printf 'Tasks: none\n\n'
            continue
        fi
        task_width=4
        for task in "${tasks[@]}"; do
            task_name="$(jq -r '.name' <<< "${task}")"
            task_length="${#task_name}"
            (( task_length <= task_width )) || task_width="${task_length}"
        done
        printf '  %-*s  %-10s  %-13s  %s\n' \
            "${task_width}" TASK STATE STATUS CREATED
        for task in "${tasks[@]}"; do
            task_name="$(jq -r '.name' <<< "${task}")"
            task_state="$(jq -r '.state' <<< "${task}")"
            workspace_id="$(jq -r '.workspaceId' <<< "${task}")"
            branch="$(jq -r '.branch' <<< "${task}")"
            created="$(jq -r '.createdAt' <<< "${task}")"
            path="$(jq -r --arg id "${workspace_id}" \
                '[.workspacePaths[] | select(.workspaceId == $id)] | .[0].path // "-"' "${machine}")"
            expected_path="${repository_root}/${task_name}"
            registry_count="$(jq -r --arg id "${workspace_id}" \
                '[.workspaces[] | select(.id == $id)] | length' "${registry}")"
            status=available
            if [[ "${task_state}" == finished ]]; then
                [[ "${registry_count}" == 1 &&
                   "$(jq -r --arg id "${workspace_id}" '.workspaces[] | select(.id == $id) | .kind' "${registry}")" == git ]] \
                    || fail "portable workspace metadata conflicts with finished task listing: ${workspace_id}"
                status=archived
            elif [[ "${path}" != "${expected_path}" ]]; then
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
                    admin_dir="${common}/worktrees/${task_name}"
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
            printf '  %-*s  %-10s  %-13s  %s\n' \
                "${task_width}" "$(sanitize_display "${task_name}")" \
                "${task_state}" "${status}" "${created}"
        done
        printf '\n'
    done
    release_workspace_lock
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
    local workspace_id="$1" worktrees root lock owner machine current_start token created attempt
    local owner_machine owner_pid owner_start stale actual_start status
    [[ "${workspace_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "invalid managed workspace UUID for launch lock: ${workspace_id}"
    [[ -z "${MANAGED_LAUNCH_LOCK_DIR}" && -z "${MANAGED_LAUNCH_LOCK_TOKEN}" ]] \
        || fail "this Pi-Run process already owns a managed workspace launch lock"
    worktrees="${PI_RUN_HOME_RESOLVED}/worktrees"
    if [[ ! -e "${worktrees}" && ! -L "${worktrees}" ]] && mkdir "${worktrees}" 2>/dev/null; then
        chmod 0700 "${worktrees}"
    fi
    [[ -d "${worktrees}" && ! -L "${worktrees}" && "$(realpath "${worktrees}")" == "${worktrees}" &&
       "$(stat -c %u "${worktrees}")" == "$(id -u)" && "$(stat -c %a "${worktrees}")" == 700 ]] \
        || fail "managed worktree root is unsafe: ${worktrees}"
    root="${worktrees}/.launch-locks"
    if [[ ! -e "${root}" && ! -L "${root}" ]] && mkdir "${root}" 2>/dev/null; then
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
    count="$(jq -r --arg id "${workspace_id}" \
        '[.repositories[]?.tasks[]? | select(.workspaceId == $id)] | length' "${machine}")"
    release_workspace_lock
    [[ "${count}" == 0 ]] && return 1
    [[ "${count}" == 1 ]] || fail "managed workspace association is ambiguous: ${workspace_id}"
}

confirm_managed_task_finish() {
    local task_name="$1" target_branch="$2" commits="$3" branch_present="$4"
    local changes="$5" ignored="$6" task_status="$7" response line
    [[ -t 0 && -t 2 && -r /dev/tty && -w /dev/tty ]] \
        || fail "worktree finish requires confirmation from an interactive terminal"
    {
        printf 'Task: %s\nTarget branch: %s\n' \
            "$(sanitize_display "${task_name}")" "$(sanitize_display "${target_branch}")"
        if [[ "${branch_present}" == true ]]; then
            printf 'Task changes to commit: %s\n' "${changes}"
            printf 'Ignored task paths to discard: %s\n' "${ignored}"
            printf 'Existing commits to merge: %s\n' "${commits}"
            if [[ -n "${task_status}" ]]; then
                printf 'Task working content:\n'
                while IFS= read -r line; do
                    printf '  %s\n' "$(sanitize_display "${line}")"
                done <<< "${task_status}"
            fi
            printf '\n'
            if (( changes > 0 )); then
                printf 'Finish will create commit "Complete task %s", then merge the task into %s.\n' \
                    "$(sanitize_display "${task_name}")" "$(sanitize_display "${target_branch}")"
            elif (( commits > 0 )); then
                printf 'Finish will merge the task into %s.\n' "$(sanitize_display "${target_branch}")"
            else
                printf 'The task is already integrated into %s.\n' "$(sanitize_display "${target_branch}")"
            fi
            if (( ignored > 0 )); then
                printf 'Ignored task content will be discarded when its checkout is removed.\n'
            fi
            printf 'Finish will remove the managed checkout and delete its local task branch.\n'
            printf 'Conversations remain as historical records. Pi-Run will not fetch, push,\n'
            printf 'or delete a remote branch.\n'
        else
            printf '\nFinish recovery will publish the already completed local cleanup.\n'
            printf 'Conversations remain available as historical records.\n'
        fi
        printf 'Type the complete task name to continue: %s\n' "$(sanitize_display "${task_name}")"
    } > /dev/tty
    printf '> ' > /dev/tty
    IFS= read -r response < /dev/tty || response=""
    [[ "${response}" == "${task_name}" ]]
}

resolve_named_managed_task() (
    local selected="$1" task_name="$2" machine repository_count repository_id task_count workspace_id path
    validate_worktree_task_name "${task_name}"
    resolve_worktree_repository "${selected}"
    machine="$(machine_file)"
    [[ -f "${machine}" ]] \
        || fail "no named worktree tasks are registered for this repository"

    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    repository_count="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
        '[.repositories[] | select(.commonGitDir == $common)] | length' "${machine}")"
    [[ "${repository_count}" == 1 ]] \
        || fail "no uniquely registered managed repository contains task: ${task_name}"
    repository_id="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
        '.repositories[] | select(.commonGitDir == $common) | .id' "${machine}")"
    task_count="$(jq -r --arg repository "${repository_id}" --arg name "${task_name}" \
        '[.repositories[] | select(.id == $repository) | .tasks[] |
            select(.name == $name and .state == "active")] | length' "${machine}")"
    [[ "${task_count}" == 1 ]] \
        || fail "no unique active worktree task is registered with name: ${task_name}"
    workspace_id="$(jq -r --arg repository "${repository_id}" --arg name "${task_name}" '
        .repositories[] | select(.id == $repository) | .tasks[] |
        select(.name == $name and .state == "active") | .workspaceId
    ' "${machine}")"
    path="$(jq -r --arg id "${workspace_id}" \
        '.workspacePaths[] | select(.workspaceId == $id) | .path' "${machine}")"
    release_workspace_lock
    printf '%s\t%s\n' "${workspace_id}" "${path}"
)

resolve_managed_task_for_finish() (
    local selected="$1" task_name="$2" machine registry repository_count repository_id task_count
    local workspace_id branch task_state path common primary root repository_root expected_path admin_dir registry_count
    local actual_common actual_git_dir actual_branch target target_git_dir target_branch target_head source_head
    validate_worktree_task_name "${task_name}"
    resolve_worktree_repository "${selected}"
    machine="$(machine_file)"
    registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    [[ -f "${machine}" ]] || fail "no named worktree tasks are registered for this repository"

    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    repository_count="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
        '[.repositories[] | select(.commonGitDir == $common)] | length' "${machine}")"
    [[ "${repository_count}" == 1 ]] \
        || fail "no uniquely registered managed repository contains task: ${task_name}"
    repository_id="$(jq -r --arg common "${WORKTREE_REPOSITORY_COMMON_DIR}" \
        '.repositories[] | select(.commonGitDir == $common) | .id' "${machine}")"
    task_count="$(jq -r --arg repository "${repository_id}" --arg name "${task_name}" \
        '[.repositories[] | select(.id == $repository) | .tasks[] | select(.name == $name)] | length' \
        "${machine}")"
    [[ "${task_count}" == 1 ]] || fail "no unique worktree task is registered with name: ${task_name}"
    workspace_id="$(jq -r --arg repository "${repository_id}" --arg name "${task_name}" '
        .repositories[] | select(.id == $repository) | .tasks[] | select(.name == $name) | .workspaceId
    ' "${machine}")"
    branch="$(jq -r --arg id "${workspace_id}" \
        '.repositories[].tasks[] | select(.workspaceId == $id) | .branch' "${machine}")"
    task_state="$(jq -r --arg id "${workspace_id}" \
        '.repositories[].tasks[] | select(.workspaceId == $id) | .state' "${machine}")"
    path="$(jq -r --arg id "${workspace_id}" \
        '[.workspacePaths[] | select(.workspaceId == $id)] | .[0].path // ""' "${machine}")"
    common="$(jq -r --arg id "${repository_id}" \
        '.repositories[] | select(.id == $id) | .commonGitDir' "${machine}")"
    primary="$(jq -r --arg id "${repository_id}" \
        '.repositories[] | select(.id == $id) | .primaryPath' "${machine}")"
    registry_count="$(jq -r --arg id "${workspace_id}" \
        '[.workspaces[] | select(.id == $id)] | length' "${registry}")"
    release_workspace_lock

    [[ "${task_state}" != finished ]] || fail "worktree task is already finished: ${task_name}"
    [[ "${task_state}" == active || "${task_state}" == finishing ]] \
        || fail "worktree task has unsupported lifecycle state: ${task_name}"
    root="${PI_RUN_HOME_RESOLVED}/worktrees"
    repository_root="${root}/${repository_id}"
    expected_path="${repository_root}/${task_name}"
    [[ -d "${root}" && ! -L "${root}" && "$(realpath "${root}")" == "${root}" &&
       "$(stat -c %u "${root}")" == "$(id -u)" && "$(stat -c %a "${root}")" == 700 &&
       -d "${repository_root}" && ! -L "${repository_root}" &&
       "$(realpath "${repository_root}")" == "${repository_root}" &&
       "$(stat -c %u "${repository_root}")" == "$(id -u)" &&
       "$(stat -c %a "${repository_root}")" == 700 ]] \
        || fail "managed finish worktree storage is missing or unsafe"
    [[ "${path}" == "${expected_path}" ]] \
        || fail "managed finish path conflicts with its workspace identity: ${workspace_id}"
    target="${WORKTREE_REPOSITORY_SELECTED_PATH}"
    [[ "${target}" != "${path}" ]] \
        || fail "worktree finish must run from the integration checkout, not the task checkout"
    [[ "${registry_count}" == 1 &&
       "$(jq -r --arg id "${workspace_id}" '.workspaces[] | select(.id == $id) | .kind' "${registry}")" == git ]] \
        || fail "portable workspace metadata conflicts with managed finish: ${workspace_id}"
    [[ -d "${common}" && ! -L "${common}" && -d "${primary}" && ! -L "${primary}" &&
       "$(realpath "${common}")" == "${common}" && "$(realpath "${primary}")" == "${primary}" &&
       "${common}" == "${primary}/.git" && "$(stat -c %u "${common}")" == "$(id -u)" &&
       "$(stat -c %u "${primary}")" == "$(id -u)" ]] \
        || fail "managed finish repository paths are missing or unsafe"
    target_git_dir="$(git -C "${target}" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    target_branch="$(git -C "${target}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    target_head="$(git -C "${target}" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
    [[ -n "${target_branch}" && "${target_head}" =~ ^[0-9a-f]{40,64}$ ]] \
        || fail "worktree finish requires an attached target branch"
    if [[ "${target_git_dir}" == "${common}" ]]; then
        [[ "${target}" == "${primary}" ]] \
            || fail "managed finish target Git administration conflicts with the primary checkout"
    else
        [[ "${target_git_dir}" == "${common}/worktrees/"* &&
           "${target_git_dir#"${common}"/worktrees/}" != */* &&
           -d "${target_git_dir}" && ! -L "${target_git_dir}" &&
           "$(stat -c %u "${target_git_dir}")" == "$(id -u)" &&
           -f "${target}/.git" && ! -L "${target}/.git" &&
           "$(stat -c %u "${target}/.git")" == "$(id -u)" &&
           "$(stat -c %h "${target}/.git")" == 1 ]] \
            || fail "managed finish target Git administration is unsafe"
    fi

    admin_dir="${common}/worktrees/${task_name}"
    if [[ ! -e "${path}" && ! -L "${path}" && ! -e "${admin_dir}" && ! -L "${admin_dir}" ]]; then
        [[ "${task_state}" == finishing ]] \
            || fail "managed finish checkout is missing: ${path}"
    else
        [[ -d "${path}" && ! -L "${path}" && "$(realpath "${path}")" == "${path}" &&
           "$(stat -c %u "${path}")" == "$(id -u)" && -d "${admin_dir}" && ! -L "${admin_dir}" &&
           "$(stat -c %u "${admin_dir}")" == "$(id -u)" && -f "${path}/.git" && ! -L "${path}/.git" &&
           "$(stat -c %u "${path}/.git")" == "$(id -u)" && "$(stat -c %h "${path}/.git")" == 1 ]] \
            || fail "managed finish worktree or Git administration is missing or unsafe: ${path}"
        actual_common="$(git -C "${path}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
        actual_git_dir="$(git -C "${path}" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
        actual_branch="$(git -C "${path}" symbolic-ref --quiet HEAD 2>/dev/null || true)"
        [[ "${actual_common}" == "${common}" && "${actual_git_dir}" == "${admin_dir}" &&
           "${actual_branch}" == "refs/heads/${branch}" ]] \
            || fail "managed finish Git state conflicts with metadata: ${workspace_id}"
    fi
    source_head="$(git -C "${target}" rev-parse --verify "refs/heads/${branch}^{commit}" 2>/dev/null || true)"
    if [[ ! "${source_head}" =~ ^[0-9a-f]{40,64}$ ]]; then
        [[ "${task_state}" == finishing && ! -e "${path}" && ! -L "${path}" &&
           ! -e "${admin_dir}" && ! -L "${admin_dir}" ]] \
            || fail "managed finish task branch is missing"
        source_head=""
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${task_state}" "${repository_id}" "${workspace_id}" "${branch}" "${path}" "${common}" \
        "${primary}" "${target}" "${target_git_dir}" "${target_branch}" "${target_head}" "${source_head}"
)

inspect_managed_task_finish_state() (
    local workspace_id="$1" path="$2" common="$3" task_name="$4" image pointer output status
    command -v docker >/dev/null 2>&1 || fail "docker is required for managed worktree finish inspection"
    image="${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}"
    docker image inspect "${image}" >/dev/null 2>&1 \
        || fail "runtime image is unavailable locally: ${image}"
    pointer="$(mktemp "${PI_RUN_HOME_RESOLVED}/worktrees/.finish-git-${workspace_id}.XXXXXX")"
    trap 'rm -f "${pointer}"' EXIT
    printf 'gitdir: /run/pi-run-git/common/worktrees/%s\n' "${task_name}" > "${pointer}"
    chmod 0600 "${pointer}"
    set +e
    output="$(docker run --rm --pull never --network none --cap-drop ALL \
        --security-opt no-new-privileges=true --read-only \
        --tmpfs "/tmp:rw,nosuid,nodev,noexec" --user "$(id -u):$(id -g)" \
        --env HOME=/tmp --env GIT_CONFIG_NOSYSTEM=1 --env GIT_OPTIONAL_LOCKS=0 \
        --env PI_RUN_FINISH_ACTION=inspect-task \
        --workdir /workspace --entrypoint bash \
        --mount "type=bind,src=${path},dst=/workspace,readonly" \
        --mount "type=bind,src=${common},dst=/run/pi-run-git/common,readonly" \
        --mount "type=bind,src=${pointer},dst=/workspace/.git,readonly" \
        "${image}" -ceu '
            if git ls-files --stage | awk '\''$1 == "160000" { found=1 } END { exit(found ? 0 : 1) }'\''; then
                exit 42
            fi
            if find . -mindepth 2 -name .git -print -quit | grep -q .; then
                exit 43
            fi
            git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false \
                status --porcelain=v1 --untracked-files=all --ignored=matching
        ' 2>/dev/null)"
    status=$?
    set -e
    case "${status}" in
        0) printf '%s\n' "${output}" ;;
        42) fail "worktree finish refuses repositories containing submodules" ;;
        43) fail "worktree finish refuses nested repositories" ;;
        *) fail "restricted worktree finish inspection failed" ;;
    esac
)

commit_managed_task_changes() (
    local workspace_id="$1" path="$2" common="$3" task_name="$4" expected_hash="$5"
    local user_name="$6" user_email="$7" image pointer status
    command -v docker >/dev/null 2>&1 || fail "docker is required for managed task commit"
    image="${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}"
    pointer="$(mktemp "${PI_RUN_HOME_RESOLVED}/worktrees/.finish-git-${workspace_id}.XXXXXX")"
    trap 'rm -f "${pointer}"' EXIT
    printf 'gitdir: /run/pi-run-git/common/worktrees/%s\n' "${task_name}" > "${pointer}"
    chmod 0600 "${pointer}"
    set +e
    docker run --rm --pull never --network none --cap-drop ALL \
        --security-opt no-new-privileges=true --read-only \
        --tmpfs "/tmp:rw,nosuid,nodev,noexec" --user "$(id -u):$(id -g)" \
        --env HOME=/tmp --env GIT_CONFIG_NOSYSTEM=1 \
        --env PI_RUN_FINISH_ACTION=commit-task --env "PI_RUN_TASK_NAME=${task_name}" \
        --env "PI_RUN_TASK_STATUS_SHA256=${expected_hash}" \
        --env "PI_RUN_GIT_USER_NAME=${user_name}" --env "PI_RUN_GIT_USER_EMAIL=${user_email}" \
        --workdir /workspace --entrypoint bash \
        --mount "type=bind,src=${path},dst=/workspace" \
        --mount "type=bind,src=${common},dst=/run/pi-run-git/common" \
        --mount "type=bind,src=${pointer},dst=/workspace/.git,readonly" \
        "${image}" -ceu '
            git_task() {
                git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false \
                    -c "user.name=${PI_RUN_GIT_USER_NAME}" -c "user.email=${PI_RUN_GIT_USER_EMAIL}" "$@"
            }
            status="$(git_task status --porcelain=v1 --untracked-files=all --ignored=matching)"
            actual_hash="$(printf "%s" "${status}" | sha256sum | cut -d " " -f 1)"
            test "${actual_hash}" = "${PI_RUN_TASK_STATUS_SHA256}" || exit 44
            git_task add -A
            git_task diff --cached --quiet && exit 45
            git_task commit -q --no-gpg-sign -m "Complete task ${PI_RUN_TASK_NAME}"
        '
    status=$?
    set -e
    case "${status}" in
        0) return 0 ;;
        44) fail "task content changed after finish confirmation; inspect and retry" ;;
        45) fail "task changes produced no committable content" ;;
        *) fail "restricted task commit failed; task remains active" ;;
    esac
)

remove_managed_task_ignored_content() (
    local workspace_id="$1" path="$2" common="$3" task_name="$4" expected_hash="$5"
    local image pointer status
    command -v docker >/dev/null 2>&1 || fail "docker is required for managed task cleanup"
    image="${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}"
    pointer="$(mktemp "${PI_RUN_HOME_RESOLVED}/worktrees/.finish-git-${workspace_id}.XXXXXX")"
    trap 'rm -f "${pointer}"' EXIT
    printf 'gitdir: /run/pi-run-git/common/worktrees/%s\n' "${task_name}" > "${pointer}"
    chmod 0600 "${pointer}"
    set +e
    docker run --rm --pull never --network none --cap-drop ALL \
        --security-opt no-new-privileges=true --read-only \
        --tmpfs "/tmp:rw,nosuid,nodev,noexec" --user "$(id -u):$(id -g)" \
        --env HOME=/tmp --env GIT_CONFIG_NOSYSTEM=1 --env GIT_OPTIONAL_LOCKS=0 \
        --env PI_RUN_FINISH_ACTION=clean-task \
        --env "PI_RUN_TASK_STATUS_SHA256=${expected_hash}" \
        --workdir /workspace --entrypoint bash \
        --mount "type=bind,src=${path},dst=/workspace" \
        --mount "type=bind,src=${common},dst=/run/pi-run-git/common,readonly" \
        --mount "type=bind,src=${pointer},dst=/workspace/.git,readonly" \
        "${image}" -ceu '
            git_task() {
                git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false "$@"
            }
            status="$(git_task status --porcelain=v1 --untracked-files=all --ignored=matching)"
            actual_hash="$(printf "%s" "${status}" | sha256sum | cut -d " " -f 1)"
            test "${actual_hash}" = "${PI_RUN_TASK_STATUS_SHA256}" || exit 44
            git_task clean -fdX -q
            test -z "$(git_task status --porcelain=v1 --untracked-files=all --ignored=matching)"
        '
    status=$?
    set -e
    case "${status}" in
        0) return 0 ;;
        44) fail "task content changed before ignored-content cleanup; inspect and retry" ;;
        *) fail "restricted ignored task-content cleanup failed; task remains active" ;;
    esac
)

managed_finish_container_git_dir() {
    local host_git_dir="$1" common="$2"
    if [[ "${host_git_dir}" == "${common}" ]]; then
        printf '/run/pi-run-git/common\n'
    else
        printf '/run/pi-run-git/common/worktrees/%s\n' "${host_git_dir#"${common}"/worktrees/}"
    fi
}

inspect_managed_finish_target_clean() (
    local target="$1" common="$2" target_git_dir="$3" target_branch="$4" target_head="$5"
    local source_head="${6:-}" image container_git_dir output status
    command -v docker >/dev/null 2>&1 || fail "docker is required for managed worktree finish inspection"
    image="${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}"
    docker image inspect "${image}" >/dev/null 2>&1 \
        || fail "runtime image is unavailable locally: ${image}"
    container_git_dir="$(managed_finish_container_git_dir "${target_git_dir}" "${common}")"
    set +e
    output="$(docker run --rm --pull never --network none --cap-drop ALL \
        --security-opt no-new-privileges=true --read-only \
        --tmpfs "/tmp:rw,nosuid,nodev,noexec" --user "$(id -u):$(id -g)" \
        --env HOME=/tmp --env GIT_CONFIG_NOSYSTEM=1 --env GIT_OPTIONAL_LOCKS=0 \
        --env PI_RUN_FINISH_ACTION=inspect-target \
        --env "PI_RUN_TARGET_GIT_DIR=${container_git_dir}" \
        --env "PI_RUN_TARGET_BRANCH=${target_branch}" --env "PI_RUN_TARGET_HEAD=${target_head}" \
        --env "PI_RUN_SOURCE_HEAD=${source_head}" \
        --workdir /workspace --entrypoint bash \
        --mount "type=bind,src=${target},dst=/workspace,readonly" \
        --mount "type=bind,src=${common},dst=/run/pi-run-git/common,readonly" \
        "${image}" -ceu '
            git_target() {
                git --git-dir="${PI_RUN_TARGET_GIT_DIR}" --work-tree=/workspace \
                    -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false "$@"
            }
            test "$(git_target symbolic-ref --quiet --short HEAD)" = "${PI_RUN_TARGET_BRANCH}"
            test "$(git_target rev-parse --verify HEAD^{commit})" = "${PI_RUN_TARGET_HEAD}"
            status="$(git_target status --porcelain=v1 --untracked-files=no)"
            test -z "${status}" || { printf "%s\n" "${status}"; exit 0; }
            if test -n "${PI_RUN_SOURCE_HEAD}"; then
                base="$(git_target merge-base "${PI_RUN_TARGET_HEAD}" "${PI_RUN_SOURCE_HEAD}")"
                mapfile -d "" changed < <(git_target diff --name-only -z --no-renames \
                    "${base}" "${PI_RUN_SOURCE_HEAD}")
                mapfile -d "" local_paths < <(
                    git_target ls-files --others --exclude-standard -z
                    git_target ls-files --others --ignored --exclude-standard -z
                )
                for changed_path in "${changed[@]}"; do
                    for local_path in "${local_paths[@]}"; do
                        if test "${changed_path}" = "${local_path}" ||
                           [[ "${changed_path}" == "${local_path}/"* ]] ||
                           [[ "${local_path}" == "${changed_path}/"* ]]; then
                            exit 44
                        fi
                    done
                done
            fi
        ' 2>/dev/null)"
    status=$?
    set -e
    if (( status == 44 )); then
        fail "worktree finish refuses target-local content that overlaps task changes"
    elif (( status != 0 )); then
        fail "restricted target-checkout inspection failed"
    fi
    [[ -z "${output}" ]] \
        || fail "worktree finish requires a target checkout without tracked modifications"
)

merge_managed_task_into_target() (
    local target="$1" common="$2" target_git_dir="$3" target_branch="$4" target_head="$5"
    local branch="$6" source_head="$7" user_name="$8" user_email="$9" task_name="${10}"
    local image container_git_dir status
    command -v docker >/dev/null 2>&1 || fail "docker is required for managed worktree finish merge"
    image="${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}"
    docker image inspect "${image}" >/dev/null 2>&1 \
        || fail "runtime image is unavailable locally: ${image}"
    container_git_dir="$(managed_finish_container_git_dir "${target_git_dir}" "${common}")"
    set +e
    docker run --rm --pull never --network none --cap-drop ALL \
        --security-opt no-new-privileges=true --read-only \
        --tmpfs "/tmp:rw,nosuid,nodev,noexec" --user "$(id -u):$(id -g)" \
        --env HOME=/tmp --env GIT_CONFIG_NOSYSTEM=1 \
        --env PI_RUN_FINISH_ACTION=merge \
        --env "PI_RUN_TARGET_GIT_DIR=${container_git_dir}" \
        --env "PI_RUN_TARGET_BRANCH=${target_branch}" --env "PI_RUN_TARGET_HEAD=${target_head}" \
        --env "PI_RUN_SOURCE_BRANCH=${branch}" --env "PI_RUN_SOURCE_HEAD=${source_head}" \
        --env "PI_RUN_GIT_USER_NAME=${user_name}" --env "PI_RUN_GIT_USER_EMAIL=${user_email}" \
        --env "PI_RUN_TASK_NAME=${task_name}" \
        --workdir /workspace --entrypoint bash \
        --mount "type=bind,src=${target},dst=/workspace" \
        --mount "type=bind,src=${common},dst=/run/pi-run-git/common" \
        "${image}" -ceu '
            git_target() {
                git --git-dir="${PI_RUN_TARGET_GIT_DIR}" --work-tree=/workspace \
                    -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.untrackedCache=false \
                    -c "user.name=${PI_RUN_GIT_USER_NAME}" -c "user.email=${PI_RUN_GIT_USER_EMAIL}" "$@"
            }
            target_restored() {
                test "$(git_target rev-parse --verify HEAD^{commit})" = "${PI_RUN_TARGET_HEAD}" &&
                    test -z "$(git_target status --porcelain=v1 --untracked-files=no)"
            }
            rollback_on_signal() {
                if git_target rev-parse --verify -q MERGE_HEAD >/dev/null; then
                    git_target merge --abort >/dev/null 2>&1 || true
                fi
                exit 43
            }
            trap rollback_on_signal HUP INT TERM
            test "$(git_target symbolic-ref --quiet --short HEAD)" = "${PI_RUN_TARGET_BRANCH}"
            test "$(git_target rev-parse --verify HEAD^{commit})" = "${PI_RUN_TARGET_HEAD}"
            test "$(git_target rev-parse --verify "refs/heads/${PI_RUN_SOURCE_BRANCH}^{commit}")" = \
                "${PI_RUN_SOURCE_HEAD}"
            test -z "$(git_target status --porcelain=v1 --untracked-files=no)"
            base="$(git_target merge-base "${PI_RUN_TARGET_HEAD}" "${PI_RUN_SOURCE_HEAD}")"
            mapfile -d "" changed < <(git_target diff --name-only -z --no-renames \
                "${base}" "${PI_RUN_SOURCE_HEAD}")
            mapfile -d "" local_paths < <(
                git_target ls-files --others --exclude-standard -z
                git_target ls-files --others --ignored --exclude-standard -z
            )
            for changed_path in "${changed[@]}"; do
                for local_path in "${local_paths[@]}"; do
                    if test "${changed_path}" = "${local_path}" ||
                       [[ "${changed_path}" == "${local_path}/"* ]] ||
                       [[ "${local_path}" == "${changed_path}/"* ]]; then
                        exit 44
                    fi
                done
            done
            if ! git_target merge --ff --no-edit --no-gpg-sign \
                -m "Merge Pi-Run task ${PI_RUN_TASK_NAME}" "refs/heads/${PI_RUN_SOURCE_BRANCH}"; then
                if git_target rev-parse --verify -q MERGE_HEAD >/dev/null; then
                    git_target merge --abort >/dev/null 2>&1 || exit 43
                fi
                target_restored && exit 42
                exit 43
            fi
            git_target merge-base --is-ancestor "${PI_RUN_SOURCE_HEAD}" HEAD
            test -z "$(git_target status --porcelain=v1 --untracked-files=no)"
        '
    status=$?
    set -e
    case "${status}" in
        0) return 0 ;;
        42) fail "task merge did not succeed; the target checkout was restored and the task remains active" ;;
        44) fail "worktree finish refuses target-local content that overlaps task changes" ;;
        *) fail "task merge failed and target recovery could not be verified; inspect the target checkout before retrying" ;;
    esac
)

mark_managed_task_finishing() (
    local workspace_id="$1" repository_id="$2" task_name="$3" branch="$4" path="$5" machine
    machine="$(machine_file)"
    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    jq -e --arg id "${workspace_id}" --arg repository "${repository_id}" --arg name "${task_name}" \
        --arg branch "${branch}" --arg path "${path}" '
        ([.repositories[] | select(.id == $repository) | .tasks[] |
            select(.workspaceId == $id and .name == $name and .branch == $branch and
                (.state == "active" or .state == "finishing"))] | length) == 1 and
        ([.workspacePaths[] | select(.workspaceId == $id and .path == $path)] | length) == 1
    ' "${machine}" >/dev/null || fail "managed task changed before finish transition: ${workspace_id}"
    # shellcheck disable=SC2016 # Dollar-prefixed names are jq variables.
    update_json "${machine}" --arg id "${workspace_id}" '
        (.repositories[].tasks[] | select(.workspaceId == $id) | .state) = "finishing"
    '
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    release_workspace_lock
)

complete_managed_task_finish() (
    local workspace_id="$1" repository_id="$2" task_name="$3" branch="$4" path="$5" admin_dir="$6" machine finished
    [[ ! -e "${path}" && ! -L "${path}" && ! -e "${admin_dir}" && ! -L "${admin_dir}" ]] \
        || fail "managed checkout still exists after finish removal: ${path}"
    machine="$(machine_file)"
    finished="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    jq -e --arg id "${workspace_id}" --arg repository "${repository_id}" --arg name "${task_name}" \
        --arg branch "${branch}" --arg path "${path}" '
        ([.repositories[] | select(.id == $repository) | .tasks[] |
            select(.workspaceId == $id and .name == $name and .branch == $branch and
                .state == "finishing")] | length) == 1 and
        ([.workspacePaths[] | select(.workspaceId == $id and .path == $path)] | length) == 1
    ' "${machine}" >/dev/null || fail "managed task changed before finish completion: ${workspace_id}"
    # shellcheck disable=SC2016 # Dollar-prefixed names are jq variables.
    update_json "${machine}" --arg id "${workspace_id}" --arg finished "${finished}" '
        del(.workspacePaths[] | select(.workspaceId == $id)) |
        (.repositories[].tasks[] | select(.workspaceId == $id)) |=
            (.state = "finished" | .finishedAt = $finished)
    '
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    release_workspace_lock
)

finish_managed_worktree_task() (
    local selected="$1" task_name="$2" initial current task_state repository_id workspace_id branch path common primary
    local target target_git_dir target_branch target_head source_head
    local current_state current_repository current_workspace current_branch current_path current_common current_primary
    local current_target current_target_git_dir current_target_branch current_target_head current_source_head
    local admin_dir commits branch_present=true user_name="" user_email=""
    local task_status="" post_status="" ignored_status="" post_ignored="" status_hash ignored_hash
    local changes=0 ignored=0
    initial="$(resolve_managed_task_for_finish "${selected}" "${task_name}")"
    IFS=$'\t' read -r task_state repository_id workspace_id branch path common primary target target_git_dir \
        target_branch target_head source_head <<< "${initial}"
    acquire_managed_launch_lock "${workspace_id}"
    trap 'release_managed_launch_lock >/dev/null 2>&1 || true' EXIT
    current="$(resolve_managed_task_for_finish "${selected}" "${task_name}")"
    IFS=$'\t' read -r current_state current_repository current_workspace current_branch current_path current_common \
        current_primary current_target current_target_git_dir current_target_branch current_target_head current_source_head \
        <<< "${current}"
    [[ "${repository_id}" == "${current_repository}" && "${workspace_id}" == "${current_workspace}" &&
       "${branch}" == "${current_branch}" && "${path}" == "${current_path}" &&
       "${common}" == "${current_common}" && "${primary}" == "${current_primary}" &&
       "${target}" == "${current_target}" && "${target_git_dir}" == "${current_target_git_dir}" &&
       "${target_branch}" == "${current_target_branch}" && "${target_head}" == "${current_target_head}" &&
       "${source_head}" == "${current_source_head}" ]] \
        || fail "managed task or target changed while acquiring its finish lock: ${task_name}"
    task_state="${current_state}"
    admin_dir="${common}/worktrees/${task_name}"
    if [[ -n "${source_head}" ]]; then
        commits="$(git -C "${target}" rev-list --count "${target_head}..${source_head}")" \
            || fail "could not compare task and target history"
    else
        commits=0
        branch_present=false
    fi
    if [[ -e "${path}" || -L "${path}" ]]; then
        task_status="$(inspect_managed_task_finish_state \
            "${workspace_id}" "${path}" "${common}" "${task_name}")"
        changes="$(awk 'length && substr($0,1,2) != "!!" { count++ } END { print count+0 }' \
            <<< "${task_status}")"
        ignored="$(awk 'length && substr($0,1,2) == "!!" { count++ } END { print count+0 }' \
            <<< "${task_status}")"
        ignored_status="$(awk 'length && substr($0,1,2) == "!!"' <<< "${task_status}")"
    fi

    if ! confirm_managed_task_finish "${task_name}" "${target_branch}" "${commits}" \
        "${branch_present}" "${changes}" "${ignored}" "${task_status}"; then
        printf 'Worktree finish cancelled.\n'
        release_managed_launch_lock || fail "could not release managed finish lock"
        trap - EXIT
        return 0
    fi

    if [[ -e "${path}" || -L "${path}" ]]; then
        if (( changes > 0 )); then
            user_name="$(git -C "${target}" config user.name || true)"
            user_email="$(git -C "${target}" config user.email || true)"
            [[ -n "${user_name}" && -n "${user_email}" ]] \
                || fail "a Git user name and email are required to commit task changes"
            status_hash="$(printf '%s' "${task_status}" | sha256sum | cut -d ' ' -f 1)"
            commit_managed_task_changes "${workspace_id}" "${path}" "${common}" "${task_name}" \
                "${status_hash}" "${user_name}" "${user_email}"
            source_head="$(git -C "${path}" rev-parse --verify 'HEAD^{commit}')" \
                || fail "committed task has no valid HEAD"
            commits="$(git -C "${target}" rev-list --count "${target_head}..${source_head}")" \
                || fail "could not compare committed task and target history"
        fi
        post_status="$(inspect_managed_task_finish_state \
            "${workspace_id}" "${path}" "${common}" "${task_name}")"
        post_ignored="$(awk 'length && substr($0,1,2) == "!!"' <<< "${post_status}")"
        [[ -z "$(awk 'length && substr($0,1,2) != "!!"' <<< "${post_status}")" ]] \
            || fail "task still has committable content after automatic commit"
        [[ "${post_ignored}" == "${ignored_status}" ]] \
            || fail "ignored task content changed after finish confirmation; inspect and retry"
        if (( commits > 0 )); then
            inspect_managed_finish_target_clean \
                "${target}" "${common}" "${target_git_dir}" "${target_branch}" "${target_head}" "${source_head}"
            if ! git -C "${target}" merge-base --is-ancestor "${target_head}" "${source_head}"; then
                [[ -n "${user_name}" ]] || user_name="$(git -C "${target}" config user.name || true)"
                [[ -n "${user_email}" ]] || user_email="$(git -C "${target}" config user.email || true)"
                [[ -n "${user_name}" && -n "${user_email}" ]] \
                    || fail "a Git user name and email are required to create the task merge commit"
            fi
            merge_managed_task_into_target \
                "${target}" "${common}" "${target_git_dir}" "${target_branch}" "${target_head}" \
                "${branch}" "${source_head}" "${user_name}" "${user_email}" "${task_name}"
            target_head="$(git -C "${target}" rev-parse --verify 'HEAD^{commit}')"
        fi
        git -C "${target}" merge-base --is-ancestor "${source_head}" "${target_head}" \
            || fail "task branch is not integrated into the target checkout"
        if [[ -n "${post_ignored}" ]]; then
            ignored_hash="$(printf '%s' "${post_status}" | sha256sum | cut -d ' ' -f 1)"
            remove_managed_task_ignored_content \
                "${workspace_id}" "${path}" "${common}" "${task_name}" "${ignored_hash}"
        fi
        [[ -z "$(inspect_managed_task_finish_state \
            "${workspace_id}" "${path}" "${common}" "${task_name}")" ]] \
            || fail "task checkout is not clean after finish preparation"
        mark_managed_task_finishing \
            "${workspace_id}" "${repository_id}" "${task_name}" "${branch}" "${path}"
        if ! git -c core.hooksPath=/dev/null -c core.fsmonitor=false -C "${primary}" \
            worktree remove "${path}"; then
            fail "Git worktree removal failed; task remains in finishing state for explicit retry"
        fi
    else
        [[ "${task_state}" == finishing ]] \
            || fail "managed finish checkout disappeared before removal: ${path}"
    fi
    if [[ -n "${source_head}" ]]; then
        git -C "${target}" merge-base --is-ancestor "${source_head}" HEAD \
            || fail "task branch is not integrated into the current target branch"
        if ! git -C "${target}" branch -d -- "${branch}" >/dev/null 2>&1; then
            fail "local task branch deletion failed; task remains in finishing state for explicit retry"
        fi
        [[ -z "$(git -C "${target}" rev-parse --verify "refs/heads/${branch}" 2>/dev/null || true)" ]] \
            || fail "local task branch still exists after deletion"
    fi
    complete_managed_task_finish \
        "${workspace_id}" "${repository_id}" "${task_name}" "${branch}" "${path}" "${admin_dir}"
    release_managed_launch_lock || fail "could not release managed finish lock"
    trap - EXIT
    printf 'Finished task: %s\nIntegrated into: %s\nRemoved managed checkout and local task branch.\n' \
        "$(sanitize_display "${task_name}")" "$(sanitize_display "${target_branch}")"
)

RESOLVED_MANAGED_TASK_NAME=""
RESOLVED_MANAGED_BRANCH=""
RESOLVED_MANAGED_COMMON_DIR=""
RESOLVED_MANAGED_HEAD=""

resolve_managed_workspace_launch() {
    local workspace_id="$1" worktree="$2" machine registry association_count repository_id task_name task_state branch mapped_path
    local common primary expected_path admin_dir registry_count actual_common actual_git_dir actual_branch
    RESOLVED_MANAGED_TASK_NAME=""
    RESOLVED_MANAGED_BRANCH=""
    RESOLVED_MANAGED_COMMON_DIR=""
    RESOLVED_MANAGED_HEAD=""
    machine="$(machine_file)"
    registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    [[ -f "${machine}" ]] || return 1

    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    association_count="$(jq -r --arg id "${workspace_id}" \
        '[.repositories[]?.tasks[]? | select(.workspaceId == $id)] | length' "${machine}")"
    if [[ "${association_count}" == 0 ]]; then
        release_workspace_lock
        return 1
    fi
    [[ "${association_count}" == 1 ]] || fail "managed workspace association is ambiguous: ${workspace_id}"
    repository_id="$(jq -r --arg id "${workspace_id}" '
        .repositories[] | select(any(.tasks[]; .workspaceId == $id)) | .id
    ' "${machine}")"
    task_name="$(jq -r --arg id "${workspace_id}" '
        .repositories[].tasks[] | select(.workspaceId == $id) | .name
    ' "${machine}")"
    task_state="$(jq -r --arg id "${workspace_id}" '
        .repositories[].tasks[] | select(.workspaceId == $id) | .state
    ' "${machine}")"
    branch="$(jq -r --arg id "${workspace_id}" '
        .repositories[].tasks[] | select(.workspaceId == $id) | .branch
    ' "${machine}")"
    mapped_path="$(jq -r --arg id "${workspace_id}" '.workspacePaths[] | select(.workspaceId == $id) | .path' "${machine}")"
    common="$(jq -r --arg id "${repository_id}" '.repositories[] | select(.id == $id) | .commonGitDir' "${machine}")"
    primary="$(jq -r --arg id "${repository_id}" '.repositories[] | select(.id == $id) | .primaryPath' "${machine}")"
    registry_count="$(jq -r --arg id "${workspace_id}" \
        '[.workspaces[] | select(.id == $id)] | length' "${registry}")"
    release_workspace_lock

    validate_worktree_task_name "${task_name}"
    [[ "${task_state}" == active ]] \
        || fail "managed worktree task is not active: ${task_name}"
    [[ "${branch}" == "pi-run/${task_name}" ]] \
        || fail "managed resume branch metadata conflicts with its task identity: ${workspace_id}"
    expected_path="${PI_RUN_HOME_RESOLVED}/worktrees/${repository_id}/${task_name}"
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
    admin_dir="${common}/worktrees/${task_name}"
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
    RESOLVED_MANAGED_TASK_NAME="${task_name}"
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
                createdAt:$created,tasks:[]}]
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

resolve_managed_task_start_identity() (
    local repository_id="$1" task_name="$2" machine registry existing_count workspace_id restarting=false
    local repository_name created display_name
    [[ "${repository_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "invalid managed repository UUID: ${repository_id}"
    validate_worktree_task_name "${task_name}"
    machine="$(machine_file)"
    registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    acquire_workspace_lock
    validate_worktree_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    [[ "$(jq -r --arg id "${repository_id}" \
        '[.repositories[] | select(.id == $id)] | length' "${machine}")" == 1 ]] \
        || fail "managed worktree repository identity is not registered uniquely: ${repository_id}"
    existing_count="$(jq -r --arg repository "${repository_id}" --arg name "${task_name}" '
        [.repositories[] | select(.id == $repository) | .tasks[] | select(.name == $name)] | length
    ' "${machine}")"
    if [[ "${existing_count}" == 0 ]]; then
        workspace_id="$(new_workspace_id)"
    elif [[ "${existing_count}" == 1 ]]; then
        workspace_id="$(jq -r --arg repository "${repository_id}" --arg name "${task_name}" '
            .repositories[] | select(.id == $repository) | .tasks[] |
            select(.name == $name and .state == "finished") | .workspaceId
        ' "${machine}")"
        [[ "${workspace_id}" =~ ^[0-9a-f-]{36}$ ]] \
            || fail "worktree task already exists in this repository: ${task_name}"
        [[ "$(jq -r --arg id "${workspace_id}" \
            '[.workspacePaths[] | select(.workspaceId == $id)] | length' "${machine}")" == 0 ]] \
            || fail "finished worktree task metadata is incomplete: ${task_name}"
        repository_name="$(jq -r --arg id "${repository_id}" \
            '.repositories[] | select(.id == $id) | .name' "${machine}")"
        created="$(jq -r --arg id "${workspace_id}" \
            '.repositories[].tasks[] | select(.workspaceId == $id) | .createdAt' "${machine}")"
        display_name="${repository_name}: ${task_name}"
        jq -e --arg id "${workspace_id}" --arg name "${display_name}" --arg created "${created}" '
            [.workspaces[] | select(.id == $id)] | .[0] |
            (keys | sort == ["createdAt","id","kind","name"]) and
            .name == $name and .kind == "git" and .createdAt == $created
        ' "${registry}" >/dev/null \
            || fail "finished worktree task registry metadata is incomplete: ${task_name}"
        restarting=true
    else
        fail "worktree task metadata is ambiguous: ${task_name}"
    fi
    release_workspace_lock
    printf '%s\t%s\n' "${workspace_id}" "${restarting}"
)

create_managed_worktree_checkout() (
    local workspace_id="$1" task_name="$2" selected="${3:-.}" machine registry record_count task_count repository_id branch base dirty
    local root repository_root worktree admin_dir image pointer="" git_dir output status
    local root_created=false repository_root_created=false
    [[ "${workspace_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "invalid managed workspace UUID: ${workspace_id}"
    validate_worktree_task_name "${task_name}"
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
        printf 'pi-run: selected checkout has uncommitted changes; task %s starts at %s and excludes them\n' \
            "$(sanitize_display "${task_name}")" "${base}" >&2
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
    task_count="$(jq -r --arg repository "${repository_id}" --arg name "${task_name}" \
        '[.repositories[] | select(.id == $repository) | .tasks[] | select(.name == $name)] | length' \
        "${machine}")"
    if [[ "${task_count}" == 0 ]]; then
        [[ "$(jq -r --arg id "${workspace_id}" \
            '[.workspacePaths[], .repositories[].tasks[] | select(.workspaceId == $id)] | length' \
            "${machine}")" == 0 ]] \
            || fail "managed workspace UUID already exists in machine metadata: ${workspace_id}"
        [[ "$(jq -r --arg id "${workspace_id}" \
            '[.workspaces[] | select(.id == $id)] | length' "${registry}")" == 0 ]] \
            || fail "managed workspace UUID already exists in the workspace registry: ${workspace_id}"
    elif [[ "${task_count}" == 1 ]]; then
        jq -e --arg repository "${repository_id}" --arg name "${task_name}" --arg id "${workspace_id}" '
            ([.repositories[] | select(.id == $repository) | .tasks[] |
                select(.name == $name and .workspaceId == $id and .state == "finished")] | length) == 1 and
            ([.workspacePaths[] | select(.workspaceId == $id)] | length) == 0
        ' "${machine}" >/dev/null \
            || fail "worktree task already exists in this repository: ${task_name}"
        [[ "$(jq -r --arg id "${workspace_id}" \
            '[.workspaces[] | select(.id == $id)] | length' "${registry}")" == 1 ]] \
            || fail "finished worktree task registry metadata is missing: ${task_name}"
    else
        fail "worktree task metadata is ambiguous: ${task_name}"
    fi

    branch="pi-run/${task_name}"
    git check-ref-format --branch "${branch}" >/dev/null 2>&1 \
        || fail "invalid managed worktree branch: ${branch}"
    if git -C "${WORKTREE_REPOSITORY_SELECTED_PATH}" show-ref --verify --quiet "refs/heads/${branch}"; then
        fail "managed worktree branch already exists: ${branch}"
    fi
    root="${PI_RUN_HOME_RESOLVED}/worktrees"
    repository_root="${root}/${repository_id}"
    worktree="${repository_root}/${task_name}"
    admin_dir="${WORKTREE_REPOSITORY_COMMON_DIR}/worktrees/${task_name}"
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
    printf 'gitdir: /run/pi-run-git/common/worktrees/%s\n' "${task_name}" > "${pointer}"
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
    local workspace_id="$1" task_name="$2" repository_id="$3" branch="$4" worktree="$5"
    local machine registry expected_path common primary admin_dir actual_common actual_git_dir actual_branch
    local machine_path_count machine_association_count registry_count created repository_name display_name registry_staging=""
    [[ "${workspace_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "invalid managed workspace UUID: ${workspace_id}"
    [[ "${repository_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "invalid managed repository UUID: ${repository_id}"
    validate_worktree_task_name "${task_name}"
    [[ "${branch}" == "pi-run/${task_name}" ]] \
        || fail "managed worktree branch does not match its task identity: ${branch}"
    expected_path="${PI_RUN_HOME_RESOLVED}/worktrees/${repository_id}/${task_name}"
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
    repository_name="$(jq -r --arg id "${repository_id}" '.repositories[] | select(.id == $id) | .name' "${machine}")"
    display_name="${repository_name}: ${task_name}"
    admin_dir="${common}/worktrees/${task_name}"

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
        [.repositories[].tasks[] | select(.workspaceId == $id)] | length
    ' "${machine}")"
    registry_count="$(jq -r --arg id "${workspace_id}" \
        '[.workspaces[] | select(.id == $id)] | length' "${registry}")"

    if [[ "${machine_path_count}" == 0 && "${machine_association_count}" == 0 ]]; then
        [[ "${registry_count}" == 0 ]] \
            || fail "portable workspace metadata exists without a managed machine association: ${workspace_id}"
        created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        # shellcheck disable=SC2016 # Dollar-prefixed names are jq variables.
        update_json "${machine}" --arg id "${workspace_id}" --arg path "${worktree}" \
            --arg repository "${repository_id}" --arg name "${task_name}" --arg branch "${branch}" \
            --arg created "${created}" '
            .workspacePaths += [{workspaceId:$id,path:$path}] |
            (.repositories[] | select(.id == $repository) | .tasks) +=
                [{name:$name,workspaceId:$id,branch:$branch,state:"active",createdAt:$created,finishedAt:null}]
        '
        validate_worktree_machine_file "${machine}"
        validate_workspace_metadata "${machine}"
    elif [[ "${machine_path_count}" == 0 && "${machine_association_count}" == 1 && "${registry_count}" == 1 ]] &&
         jq -e --arg id "${workspace_id}" --arg repository "${repository_id}" --arg name "${task_name}" \
            --arg branch "${branch}" '
            [.repositories[] | select(.id == $repository) | .tasks[] |
                select(.workspaceId == $id and .name == $name and .branch == $branch and
                    .state == "finished" and (.finishedAt | type == "string"))] | length == 1
         ' "${machine}" >/dev/null; then
        created="$(jq -r --arg id "${workspace_id}" '
            .repositories[].tasks[] | select(.workspaceId == $id) | .createdAt
        ' "${machine}")"
        # shellcheck disable=SC2016 # Dollar-prefixed names are jq variables.
        update_json "${machine}" --arg id "${workspace_id}" --arg path "${worktree}" '
            .workspacePaths += [{workspaceId:$id,path:$path}] |
            (.repositories[].tasks[] | select(.workspaceId == $id)) |=
                (.state = "active" | .finishedAt = null)
        '
        validate_worktree_machine_file "${machine}"
        validate_workspace_metadata "${machine}"
    elif [[ "${machine_path_count}" == 1 && "${machine_association_count}" == 1 ]]; then
        jq -e --arg id "${workspace_id}" --arg path "${worktree}" --arg repository "${repository_id}" \
            --arg name "${task_name}" --arg branch "${branch}" '
            ([.workspacePaths[] | select(.workspaceId == $id and .path == $path)] | length) == 1 and
            ([.repositories[] | select(.id == $repository) | .tasks[] |
                select(.name == $name and .workspaceId == $id and .branch == $branch and
                    .state == "active" and .finishedAt == null)] | length) == 1
        ' "${machine}" >/dev/null || fail "managed machine metadata conflicts with the prepared worktree"
        created="$(jq -r --arg id "${workspace_id}" '
            .repositories[].tasks[] | select(.workspaceId == $id) | .createdAt
        ' "${machine}")"
    else
        fail "managed machine metadata is incomplete or ambiguous: ${workspace_id}"
    fi

    registry_count="$(jq -r --arg id "${workspace_id}" \
        '[.workspaces[] | select(.id == $id)] | length' "${registry}")"
    if [[ "${registry_count}" == 0 ]]; then
        registry_staging="${registry}.tmp.$$"
        # shellcheck disable=SC2016 # Dollar-prefixed names are jq variables.
        if ! jq --arg id "${workspace_id}" --arg name "${display_name}" --arg created "${created}" \
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
        jq -e --arg id "${workspace_id}" --arg name "${display_name}" --arg created "${created}" '
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

