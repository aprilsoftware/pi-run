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

