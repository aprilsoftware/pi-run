# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Globals are shared with bin/pi-run.
# shellcheck disable=SC2034

WORKER_MODE=false
WORKER_RESUME=false
WORKER_REFERENCE=""
WORKER_ROLE_INPUT=""
WORKER_BINDING_DIR=""
WORKER_CONTROL_DIR=""
WORKER_DOCKER_PID=""
WORKER_CLIENT_SETTLED=false
WORKER_LAUNCH_TOKEN=""
WORKER_LOCK_FD=""

# Bound Docker setup calls without putting a deadline on the long-lived stream.
worker_use_bounded_docker() {
    WORKER_DOCKER_COMMAND="$(type -P docker)" || return 0
    docker() { timeout -k 2 30 "${WORKER_DOCKER_COMMAND}" "$@"; }
}

worker_private_directory() {
    local path="$1"
    [[ -d "${path}" && ! -L "${path}" && "$(realpath "${path}")" == "${path}" &&
       "$(stat -c %u "${path}")" == "$(id -u)" && "$(stat -c %a "${path}")" == 700 ]]
}

worker_private_file() {
    local path="$1" maximum="$2"
    [[ -f "${path}" && ! -L "${path}" && "$(realpath "${path}")" == "${path}" &&
       "$(stat -c %h "${path}")" == 1 && "$(stat -c %u "${path}")" == "$(id -u)" &&
       "$(stat -c %a "${path}")" == 600 ]] && (( $(stat -c %s "${path}") <= maximum ))
}

validate_worker_binding() {
    local directory="$1" reference="${1##*/}" role_hash
    [[ "${reference}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
    worker_private_directory "${directory}" || return 1
    [[ "$(find "${directory}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" == $'binding.json\nrole.txt' ]] || return 1
    worker_private_file "${directory}/binding.json" 16384 && worker_private_file "${directory}/role.txt" 262144 || return 1
    (( $(stat -c %s "${directory}/role.txt") > 0 )) || return 1
    role_hash="$(sha256sum "${directory}/role.txt" | awk '{print $1}')" || return 1
    jq -e --arg ref "${reference}" --arg role "${role_hash}" '
        def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
        type == "object" and
        keys == ["configHash","createdAt","profile","reference","roleHash","runtimeId","schemaVersion","sessionFile","sessionId","workspaceId"] and
        .schemaVersion == 1 and .reference == $ref and .roleHash == $role and
        (.profile | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
        (.workspaceId | uuid) and (.configHash | test("^[0-9a-f]{64}$")) and
        (.runtimeId | test("^sha256:[0-9a-f]{64}$")) and
        (.createdAt | type == "string" and test("^[0-9T:Z.-]+$")) and
        ((.sessionId == null and .sessionFile == null) or
         ((.sessionId | uuid) and (.sessionFile | type == "string" and length < 200 and
           test("^[A-Za-z0-9_-]+[.]jsonl$"))))
    ' "${directory}/binding.json" >/dev/null 2>&1
}

validate_worker_snapshot_sources() {
    local root="$1" directory
    worker_private_directory "${root}" || fail "Worker binding root is unsafe: ${root}"
    while IFS= read -r -d '' directory; do
        validate_worker_binding "${directory}" || fail "Worker binding is invalid or unsafe: ${directory}"
    done < <(find "${root}" -mindepth 1 -maxdepth 1 -print0)
}

worker_load_reference() {
    local reference="$1"
    [[ "${reference}" =~ ^worker-v1:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$ ]] \
        || fail "invalid Worker reference"
    WORKER_REFERENCE="${BASH_REMATCH[1]}"
    WORKER_BINDING_DIR="${PI_RUN_HOME_RESOLVED}/worker-sessions/${WORKER_REFERENCE}"
    worker_private_directory "${PI_RUN_HOME_RESOLVED}/worker-sessions" && validate_worker_binding "${WORKER_BINDING_DIR}" \
        || fail "Worker binding is missing, changed, or unsafe"
    PROFILE="$(jq -r '.profile' "${WORKER_BINDING_DIR}/binding.json")"
    PROFILE_EXPLICIT=true
    WORKER_WORKSPACE_ID="$(jq -r '.workspaceId' "${WORKER_BINDING_DIR}/binding.json")"
    WORKER_SESSION_ID="$(jq -r '.sessionId // empty' "${WORKER_BINDING_DIR}/binding.json")"
    WORKER_SESSION_FILE="$(jq -r '.sessionFile // empty' "${WORKER_BINDING_DIR}/binding.json")"
}

worker_workspace_path() {
    local machine
    machine="$(machine_file)"
    [[ -f "${machine}" && ! -L "${machine}" ]] || return 0
    validate_workspace_metadata "${machine}"
    jq -er --arg id "${WORKER_WORKSPACE_ID}" '
        [.workspacePaths[] | select(.workspaceId == $id)] |
        if length > 1 then error("duplicate workspace mapping") else (.[0].path // "") end
    ' "${machine}"
}

worker_transcript_valid() {
    local file="${PI_RUN_HOME_RESOLVED}/profiles/${PROFILE}/sessions/${WORKER_WORKSPACE_ID}/${WORKER_SESSION_FILE}"
    [[ -n "${WORKER_SESSION_ID}" && -f "${file}" && ! -L "${file}" &&
       "$(realpath "${file}")" == "${file}" && "$(stat -c %h "${file}")" == 1 ]] || return 1
    local header
    header="$(head -c 65536 "${file}")"
    printf '%s' "${header%%$'\n'*}" | jq -e --arg id "${WORKER_SESSION_ID}" '
        .type == "session" and .id == $id and .cwd == "/workspace"
    ' >/dev/null 2>&1
}

# Hash configuration, never conversation/log/cache contents or ordinary source.
# Hash credential files without emitting their values. OAuth refresh state (auth.json)
# is deliberately excluded; profile/provider/key configuration remains included.
worker_config_hash() {
    (
    set -euo pipefail
    local path file skill
    printf 'workspace/.pi/settings.json\0'
    file="${WORKSPACE}/.pi/settings.json"
    if [[ -e "${file}" || -L "${file}" ]]; then
        [[ -f "${file}" && ! -L "${file}" && "$(realpath "${file}")" == "${file}" && "$(stat -c %h "${file}")" == 1 ]] || exit 1
        sha256sum < "${file}" || exit 1
    else
        printf 'absent\0'
    fi
    local -a paths=(profile.json AGENTS.md settings.json models.json web-search.json gitconfig
        guardian/config.json guardian/mode.json guardian/guardian.md
        guard/config.json caf/config.json caf/mode.json caf/caf.md credentials skills runtime)
    for path in "${paths[@]}"; do
        file="${PROFILE_DIR}/${path}"
        printf 'profile/%s\0' "${path}"
        if [[ ! -e "${file}" && ! -L "${file}" ]]; then printf 'absent\0'; continue; fi
        [[ "$(realpath "${file}")" == "${file}" && ! -L "${file}" ]] || exit 1
        if [[ -d "${file}" ]]; then
            [[ -z "$(find "${file}" ! -type f ! -type d -print -quit)" ]] || exit 1
            while IFS= read -r -d '' path; do
                [[ "$(stat -c %h "${path}")" == 1 ]] || exit 1
                printf '%s\0' "${path#"${PROFILE_DIR}/"}"
                sha256sum < "${path}" || exit 1
            done < <(find "${file}" -type f -print0 | LC_ALL=C sort -z)
        else
            [[ -f "${file}" && "$(stat -c %h "${file}")" == 1 ]] || exit 1
            sha256sum < "${file}" || exit 1
        fi
    done
    validate_global_skills_directory
    while IFS= read -r skill; do
        global_skill_is_active "${PROFILE_DIR}/profile.json" "${skill}" || continue
        file="${PI_RUN_HOME_RESOLVED}/skills/${skill}"
        validate_skill_source "${file}" "${skill}"
        while IFS= read -r -d '' path; do
            printf 'global/%s\0' "${path#"${PI_RUN_HOME_RESOLVED}/skills/"}"
            sha256sum < "${path}" || exit 1
        done < <(find "${file}" -type f -print0 | LC_ALL=C sort -z)
    done < <(global_skill_names)
    ) | sha256sum | awk '{print $1}'
}

worker_inspect() {
    local path saved=false config_changed=null current="" runtime="" runtime_matches=null
    worker_use_bounded_docker
    worker_load_reference "$1"
    path="$(worker_workspace_path)"
    WORKSPACE="${path}"
    worker_transcript_valid && saved=true
    PROFILE_DIR="$(resolve_profile_directory)"
    if [[ -n "${path}" && -d "${path}" && "$(realpath "${path}")" == "${path}" ]]; then
        current="$(worker_config_hash)" || fail "could not inspect Worker execution configuration"
        [[ "${current}" == "$(jq -r '.configHash' "${WORKER_BINDING_DIR}/binding.json")" ]] && config_changed=false || config_changed=true
    fi
    # Inspection is read-only and can report a missing Docker/runtime without repair.
    if runtime="$(select_profile_runtime_image id 2>/dev/null)"; then
        [[ "${runtime}" == "$(jq -r '.runtimeId' "${WORKER_BINDING_DIR}/binding.json")" ]] && runtime_matches=true || runtime_matches=false
    fi
    jq --arg ref "worker-v1:${WORKER_REFERENCE}" --arg path "${path}" --argjson saved "${saved}" \
        --argjson changed "${config_changed}" --argjson runtime "${runtime_matches}" \
        --argjson available "$([[ -n "${path}" && -d "${path}" && "$(realpath "${path}")" == "${path}" ]] && echo true || echo false)" '
        {schemaVersion,reference:$ref,profile,workspaceId,sessionId,sessionFile,roleHash,runtimeId,createdAt,
         workspacePath:$path,workspaceAvailable:$available,transcriptSaved:$saved,
         configurationChanged:$changed,runtimeMatches:$runtime,
         resumable:($saved and $available and ($changed == false) and ($runtime == true))}
    ' "${WORKER_BINDING_DIR}/binding.json"
}

worker_prepare_binding() {
    local runtime_id config_hash staging root="${PI_RUN_HOME_RESOLVED}/worker-sessions"
    worker_private_directory "${root}" || fail "Worker binding root is unsafe"
    runtime_id="${IMAGE}"
    [[ "${runtime_id}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "Worker requires a validated immutable runtime identity"
    config_hash="$(worker_config_hash)" || fail "could not fingerprint Worker configuration"
    if [[ -n "${MANAGED_WORKTREE_COMMON_DIR:-}" ]] &&
       { path_is_within "${root}" "${MANAGED_WORKTREE_COMMON_DIR}" || path_is_within "${MANAGED_WORKTREE_COMMON_DIR}" "${root}"; }; then
        fail "Worker Git mount would expose host binding metadata"
    fi
    if [[ "${WORKER_RESUME}" == true ]]; then
        validate_worker_binding "${WORKER_BINDING_DIR}" || fail "Worker binding changed during resume"
        [[ "${config_hash}" == "$(jq -r '.configHash' "${WORKER_BINDING_DIR}/binding.json")" ]] \
            || fail "Worker execution configuration changed; resume refused"
        [[ "${runtime_id}" == "$(jq -r '.runtimeId' "${WORKER_BINDING_DIR}/binding.json")" ]] \
            || fail "Worker prepared runtime changed; resume refused"
        worker_transcript_valid || fail "Worker transcript is missing or has a different identity; resume refused"
    else
        WORKER_REFERENCE="$(new_workspace_id)"
        WORKER_BINDING_DIR="${root}/${WORKER_REFERENCE}"
        staging="${PI_RUN_HOME_RESOLVED}/.worker-new-${WORKER_REFERENCE}"
        mkdir -m 0700 "${staging}"
        # Stage outside the visible binding namespace, then publish the pair together.
        if ! install -m 0600 "${WORKER_ROLE_INPUT}" "${staging}/role.txt"; then
            rm -rf -- "${staging}"; fail "could not copy Worker Role"
        fi
        if ! worker_private_file "${staging}/role.txt" 262144 || [[ ! -s "${staging}/role.txt" ]]; then
            rm -rf -- "${staging}"; fail "Role changed size or became unsafe while copying"
        fi
        jq -n --arg ref "${WORKER_REFERENCE}" --arg profile "${PROFILE}" --arg workspace "${WORKSPACE_ID}" \
            --arg role "$(sha256sum "${staging}/role.txt" | awk '{print $1}')" \
            --arg runtime "${runtime_id}" --arg config "${config_hash}" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
            {schemaVersion:1,reference:$ref,profile:$profile,workspaceId:$workspace,roleHash:$role,
             runtimeId:$runtime,configHash:$config,createdAt:$created,sessionId:null,sessionFile:null}
        ' > "${staging}/binding.json"
        mv -T "${staging}" "${WORKER_BINDING_DIR}"
    fi
    exec {WORKER_LOCK_FD}<"${WORKER_BINDING_DIR}"
    flock -n -x "${WORKER_LOCK_FD}" || fail "Worker session is already in use"
    # Use the immutable ID, never a tag that can be retargeted during startup.
    IMAGE="${runtime_id}"
    WORKER_CONTROL_DIR="$(mktemp -d /tmp/pi-run-worker.XXXXXX)"
    WORKER_LAUNCH_TOKEN="$(new_workspace_id)"
    mkdir -m 0700 "${WORKER_CONTROL_DIR}/channel"
    DOCKER_ARGS+=(--pull never --init --label "pi-run.worker-launch=${WORKER_LAUNCH_TOKEN}"
        --entrypoint /usr/local/bin/entrypoint.sh
        --mount "type=bind,src=${WORKER_BINDING_DIR}/role.txt,dst=/run/pi-run-role.txt,readonly"
        --mount "type=bind,src=${WORKER_CONTROL_DIR}/channel,dst=/run/pi-run-worker"
        --env "PI_RUN_WORKER_REFERENCE=worker-v1:${WORKER_REFERENCE}"
        --env "PI_RUN_WORKER_SESSION_ID=${WORKER_SESSION_ID:-}"
        --env "PI_RUN_WORKER_SESSION_DIR=${SESSION_DIR_CONTAINER}")
    PI_ARGS=(node /usr/local/lib/pi-run/worker-rpc.mjs "${PI_ARGS[@]}" --mode rpc --append-system-prompt /run/pi-run-role.txt)
    if [[ "${WORKER_RESUME}" == true ]]; then
        PI_ARGS+=(--session "${SESSION_DIR_CONTAINER}/${WORKER_SESSION_FILE}")
    fi
}

worker_commit_handshake() {
    local file="${WORKER_CONTROL_DIR}/channel/session.json" session_id session_file temporary
    worker_private_file "${file}" 4096 || fail "Worker returned unsafe session handshake"
    jq -e --arg directory "${SESSION_DIR_CONTAINER}/" '
        keys == ["sessionFile","sessionId"] and
        (.sessionId | type == "string" and test("^[0-9a-f-]{36}$")) and
        (.sessionFile | type == "string" and startswith($directory)) and
        (.sessionFile | ltrimstr($directory) | test("^[A-Za-z0-9_-]+[.]jsonl$"))
    ' "${file}" >/dev/null || fail "Worker returned invalid session handshake"
    session_id="$(jq -r '.sessionId' "${file}")"
    session_file="$(jq -r '.sessionFile | split("/")[-1]' "${file}")"
    if [[ "${WORKER_RESUME}" == true ]]; then
        [[ "${session_id}" == "${WORKER_SESSION_ID}" && "${session_file}" == "${WORKER_SESSION_FILE}" ]] \
            || fail "Worker selected a different session; refusing readiness"
    else
        temporary="${WORKER_BINDING_DIR}/binding.json.tmp"
        jq --arg id "${session_id}" --arg file "${session_file}" '.sessionId=$id | .sessionFile=$file' \
            "${WORKER_BINDING_DIR}/binding.json" > "${temporary}"
        mv -T "${temporary}" "${WORKER_BINDING_DIR}/binding.json"
        validate_worker_binding "${WORKER_BINDING_DIR}" || fail "Worker binding failed validation"
        sync -f "${WORKER_BINDING_DIR}" || fail "could not synchronize Worker binding"
    fi
    validate_worker_binding "${WORKER_BINDING_DIR}" || fail "Worker Role/binding changed during startup"
    [[ "$(worker_config_hash)" == "$(jq -r '.configHash' "${WORKER_BINDING_DIR}/binding.json")" ]] \
        || fail "Worker execution configuration changed during startup; readiness refused"
    printf 'ready\n' > "${WORKER_CONTROL_DIR}/channel/ack"
}

worker_run() {
    local attempt status=0
    # Explicit stdin duplication avoids Bash's /dev/null for asynchronous commands.
    command docker run "${DOCKER_ARGS[@]}" "${IMAGE}" "${PI_ARGS[@]}" <&0 &
    WORKER_DOCKER_PID=$!
    trap 'exit 143' TERM HUP
    trap 'exit 130' INT
    for ((attempt=0; attempt<600; attempt++)); do
        if [[ -e "${WORKER_CONTROL_DIR}/channel/session.json" ]]; then
            worker_commit_handshake
            break
        fi
        kill -0 "${WORKER_DOCKER_PID}" 2>/dev/null || break
        sleep 0.1
    done
    (( attempt < 600 )) || fail "Worker readiness timed out"
    wait "${WORKER_DOCKER_PID}" || status=$?
    WORKER_DOCKER_PID=""
    WORKER_CLIENT_SETTLED=true
    return "${status}"
}

worker_cleanup() {
    local containers id attempt failed=false
    [[ -n "${WORKER_LAUNCH_TOKEN}" ]] || return 0
    if [[ -n "${WORKER_DOCKER_PID}" ]]; then
        kill "${WORKER_DOCKER_PID}" 2>/dev/null || true
        for ((attempt=0; attempt<30; attempt++)); do
            kill -0 "${WORKER_DOCKER_PID}" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL "${WORKER_DOCKER_PID}" 2>/dev/null || true
        wait "${WORKER_DOCKER_PID}" 2>/dev/null || true
        WORKER_DOCKER_PID=""
    fi
    # Query by per-launch random label; never stop a container by reused PID/name.
    if containers="$(timeout -k 2 10 docker ps -aq --filter "label=pi-run.worker-launch=${WORKER_LAUNCH_TOKEN}")"; then
        for id in ${containers}; do
            if [[ ! "${id}" =~ ^[0-9a-f]{12,64}$ ]] || ! timeout -k 2 15 docker rm -f "${id}" >/dev/null 2>&1; then
                failed=true
            fi
        done
    else
        failed=true
    fi
    # Interrupted Docker creation may still be completing in the daemon. Do not
    # reclaim ownership merely because a disconnected client's query was empty.
    if [[ "${WORKER_CLIENT_SETTLED}" == false && -z "${containers:-}" ]]; then
        failed=true
    fi
    if [[ "${failed}" == true ]]; then
        echo 'pi-run: Worker cleanup could not be confirmed; launch lock retained for host investigation' >&2
        return 1
    fi
    [[ -z "${WORKER_CONTROL_DIR}" ]] || rm -rf -- "${WORKER_CONTROL_DIR}"
    WORKER_CONTROL_DIR=""
    WORKER_LAUNCH_TOKEN=""
    return 0
}

create_worktree_only() {
    local name="$1" repository="$2" repository_id identity workspace_id restarting created id repo branch path base
    validate_worktree_task_name "${name}"
    [[ -d "${repository}" ]] || fail "repository does not exist: ${repository}"
    repository="$(realpath "${repository}")"
    repository_id="$(ensure_worktree_repository_record "${repository}")"
    trap 'release_managed_launch_lock || true' EXIT
    acquire_managed_launch_lock "$(worktree_task_start_lock_id "${repository_id}" "${name}")"
    identity="$(resolve_managed_task_start_identity "${repository_id}" "${name}")"
    IFS=$'\t' read -r workspace_id restarting <<< "${identity}"
    created="$(create_managed_worktree_checkout "${workspace_id}" "${name}" "${repository}")"
    IFS=$'\t' read -r id repo branch path base <<< "${created}"
    [[ "${id}" == "${workspace_id}" && "${repo}" == "${repository_id}" ]] || fail "inconsistent worktree identity"
    publish_managed_worktree_metadata "${id}" "${name}" "${repo}" "${branch}" "${path}" >/dev/null
    release_managed_launch_lock || fail "could not release worktree creation lock"
    trap - EXIT
    jq -n --arg id "${id}" --arg repository "${repo}" --arg name "${name}" --arg branch "${branch}" \
        --arg path "${path}" --arg base "${base}" \
        '{schemaVersion:1,workspaceId:$id,repositoryId:$repository,name:$name,branch:$branch,path:$path,base:$base}'
}
