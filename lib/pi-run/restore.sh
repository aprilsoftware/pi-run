# SPDX-License-Identifier: MIT
# shellcheck shell=bash

SNAPSHOT_RESTORE_TMP=""

cleanup_snapshot_restore() {
    [[ -z "${SNAPSHOT_RESTORE_TMP}" ]] || rm -rf -- "${SNAPSHOT_RESTORE_TMP}"
}

run_snapshot_restore() {
    local snapshot_id="$1" target="$2" backend repository region
    local root="${PI_RUN_HOME_RESOLVED}/snapshots"
    backend="$(jq -r '.backend' "${root}/config.json")"
    if [[ "${backend}" == local ]]; then
        docker run --rm \
            --network none \
            --cap-drop=ALL \
            --security-opt=no-new-privileges \
            --read-only \
            --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
            --user "$(id -u):$(id -g)" \
            --mount "type=bind,src=${root}/repository,dst=/repository,readonly" \
            --mount "type=bind,src=${root}/secrets,dst=/secret,readonly" \
            --mount "type=bind,src=${target},dst=/restore" \
            --env RESTIC_REPOSITORY=/repository \
            --env RESTIC_PASSWORD_FILE=/secret \
            --env RESTIC_CACHE_DIR=/tmp/restic-cache \
            --entrypoint restic \
            "${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}" \
            --no-lock restore "${snapshot_id}" --target /restore --verify
    else
        IFS=$'\t' read -r repository region < <(s3_snapshot_connection)
        docker run --rm \
            --network bridge \
            --cap-drop=ALL \
            --security-opt=no-new-privileges \
            --read-only \
            --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
            --user "$(id -u):$(id -g)" \
            --mount "type=bind,src=${root}/secrets,dst=/secret,readonly" \
            --mount "type=bind,src=${root}/s3-credentials,dst=/s3-credentials,readonly" \
            --mount "type=bind,src=${CA_BUNDLE},dst=${CA_BUNDLE},readonly" \
            --mount "type=bind,src=${target},dst=/restore" \
            --env "RESTIC_REPOSITORY=${repository}" \
            --env RESTIC_PASSWORD_FILE=/secret \
            --env AWS_SHARED_CREDENTIALS_FILE=/s3-credentials \
            --env AWS_PROFILE=default \
            --env "AWS_DEFAULT_REGION=${region}" \
            --env "SSL_CERT_FILE=${CA_BUNDLE}" \
            --env RESTIC_CACHE_DIR=/tmp/restic-cache \
            --entrypoint restic \
            "${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}" \
            -o "s3.region=${region}" -o s3.bucket-lookup=path \
            --no-lock restore "${snapshot_id}" --target /restore --verify
    fi
}

validate_staged_restore() {
    local target="$1" request_id="$2" path profile_dir profile_name
    local input="${target}/input"
    local snapshot_config="${target}/input/snapshot-config.json" endpoint bucket prefix region
    local expected=$'config.json\nprofiles\nshared\nskills\nsnapshot-config.json\nsnapshot-manifest.json\nworkspaces'
    [[ -d "${input}" && ! -L "${input}" ]] || fail "restored snapshot is missing its input directory"
    if [[ -e "${target}/stage.json" || -L "${target}/stage.json" ]]; then
        [[ "$(find "${target}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" == $'input\nstage.json' ]] \
            || fail "restored snapshot contains unexpected top-level content"
    else
        [[ "$(find "${target}" -mindepth 1 -maxdepth 1 -printf '%f\n')" == input ]] \
            || fail "restored snapshot contains unexpected top-level content"
    fi
    [[ "$(find "${input}" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)" == "${expected}" ]] \
        || fail "restored snapshot has an unexpected complete-snapshot layout"
    for path in config.json snapshot-config.json snapshot-manifest.json; do
        [[ -f "${input}/${path}" && ! -L "${input}/${path}" ]] \
            || fail "restored snapshot is missing required file: ${path}"
    done
    for path in profiles skills shared workspaces; do
        [[ -d "${input}/${path}" && ! -L "${input}/${path}" ]] \
            || fail "restored snapshot is missing required directory: ${path}"
    done
    path="$(find -P "${input}" -xdev -mindepth 1 ! -type f ! -type d -print -quit)"
    [[ -z "${path}" ]] || fail "restored snapshot contains a link or special file: ${path}"
    path="$(find -P "${input}" -xdev -type f -links +1 -print -quit)"
    [[ -z "${path}" ]] || fail "restored snapshot contains a hard-linked file: ${path}"
    jq -e '
        .schemaVersion == 1 and (.defaultProfile | type == "string") and
        (.defaultProfile | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
        (keys | sort == ["defaultProfile", "schemaVersion"])
    ' "${input}/config.json" >/dev/null || fail "restored home configuration is invalid"
    profile_name="$(jq -r '.defaultProfile' "${input}/config.json")"
    [[ -d "${input}/profiles/${profile_name}" ]] || fail "restored default profile is missing"
    for profile_dir in "${input}/profiles"/*; do
        [[ -d "${profile_dir}" ]] || continue
        profile_name="$(basename "${profile_dir}")"
        validate_profile_name "${profile_name}"
        validate_profile_config "${profile_dir}" "${profile_name}"
        validate_profile_definition_files "${profile_dir}"
        validate_profile_skills_directory "${profile_dir}"
    done
    [[ "$(find "${input}/workspaces" -mindepth 1 -maxdepth 1 -printf '%f\n')" == registry.json ]] \
        || fail "restored workspace metadata contains unexpected content"
    jq -e '
        .schemaVersion == 1 and (.workspaces | type == "array") and
        all(.workspaces[];
            (.id | type == "string") and (.name | type == "string") and
            (.kind == "git" or .kind == "directory") and (.createdAt | type == "string"))
    ' "${input}/workspaces/registry.json" >/dev/null || fail "restored workspace registry is invalid"
    if [[ "$(jq -r '.backend // ""' "${snapshot_config}")" == local ]]; then
        jq -e '.schemaVersion == 1 and .backend == "local" and .repository == "repository" and
            (keys | sort == ["backend", "repository", "schemaVersion"])' \
            "${snapshot_config}" >/dev/null || fail "restored snapshot configuration is invalid"
    else
        jq -e '.schemaVersion == 1 and .backend == "s3" and .bucketLookup == "path" and
            (keys | sort == ["backend", "bucket", "bucketLookup", "endpoint", "prefix", "region", "schemaVersion"])' \
            "${snapshot_config}" >/dev/null || fail "restored snapshot configuration is invalid"
        IFS=$'\t' read -r endpoint bucket prefix region < <(
            jq -r '[.endpoint, .bucket, .prefix, .region] | @tsv' "${snapshot_config}")
        validate_s3_settings "${endpoint}" "${bucket}" "${prefix}" "${region}"
    fi
    (( $(stat -c %s "${input}/snapshot-manifest.json") <= 262144 )) \
        || fail "restored snapshot manifest is too large"
    jq -e --arg request "${request_id}" --arg metadata "snapshots/metadata/${request_id}.json" '
        . as $manifest |
        .schemaVersion == 1 and .requestId == $request and .scope == "complete" and
        ((.purpose == null) or (.purpose == "manual") or (.purpose == "automatic") or (.purpose == "pre-restore")) and
        (.createdAt | type == "string") and (.createdAt | test("^[0-9T:+.-]+Z$")) and
        (.piRunVersion | type == "string") and (.piRunVersion | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
        (.piVersion | type == "string") and (.piVersion | test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][A-Za-z0-9._-]+)?$")) and
        (.runtimeImage | type == "string") and (.runtimeImage | test("^[A-Za-z0-9][A-Za-z0-9._/:@+-]*$")) and
        .homeConfigurationSchemaVersion == 1 and .profileSchemaVersion == 1 and
        .workspaceRegistrySchemaVersion == 1 and .snapshotConfigurationSchemaVersion == 1 and
        (.includedPaths | type == "array") and
        all(.includedPaths[]; (type == "string") and test("^[\\x20-\\x7e]+$")) and
        all(["config.json", "profiles", "skills", "shared", "workspaces", "snapshots/config.json", $metadata][];
            . as $required | ($manifest.includedPaths | index($required))) and
        (.excludedPaths | type == "array") and
        all(.excludedPaths[]; (type == "string") and test("^[\\x20-\\x7e]+$")) and
        all(["machines", "snapshots/secrets", "snapshots/s3-credentials", "snapshots/repository", "snapshots/restore-staging"][];
            . as $required | ($manifest.excludedPaths | index($required)))
    ' "${input}/snapshot-manifest.json" >/dev/null || fail "restored snapshot manifest is invalid or mismatched"
}

stage_snapshot_restore() {
    local reference="$1" metadata resolved snapshot_id _scope request_id staged_at backend
    local root="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging" pending="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging/pending"
    local temporary="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging/.pending.$$"
    [[ "${reference}" =~ ^([0-9a-f]{12}|[0-9a-f]{64})$ ]] \
        || fail "snapshot ID must be a 12 or 64 character lowercase hexadecimal ID"
    snapshot_status >/dev/null
    [[ -d "${root}" && ! -L "${root}" && "$(realpath "${root}")" == "${root}" &&
       "$(stat -c %a "${root}")" == 700 ]] || fail "restore staging directory is unsafe: ${root}"
    [[ -z "$(find "${root}" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
        || fail "restore staging is not empty; inspect or remove the existing pending restore"
    metadata="$(query_snapshot_by_reference "${reference}")" \
        || fail "could not resolve Pi-Run snapshot: ${reference}"
    resolved="$(jq -er --arg reference "${reference}" '
        select(type == "array" and length == 1) | .[0] |
        select((.id | test("^[0-9a-f]{64}$")) and (.id | startswith($reference)) and
            (.tags | type == "array") and
            ([.tags[] | select(. == "pi-run")] | length == 1) and
            ([.tags[] | select(. == "scope=complete")] | length == 1) and
            ([.tags[] | select(startswith("request="))] | length == 1)) |
        [.id, "complete", ([.tags[] | select(startswith("request=")) | ltrimstr("request=")][0])] | @tsv
    ' <<< "${metadata}")" || fail "snapshot ID is unknown, ambiguous, or not a complete Pi-Run snapshot: ${reference}"
    IFS=$'\t' read -r snapshot_id _scope request_id <<< "${resolved}"
    [[ "${request_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "snapshot request tag is invalid"
    mkdir -m 0700 "${temporary}"
    SNAPSHOT_RESTORE_TMP="${temporary}"
    trap cleanup_snapshot_restore EXIT
    run_snapshot_restore "${snapshot_id}" "${temporary}" \
        || fail "could not restore snapshot into staging"
    validate_staged_restore "${temporary}" "${request_id}"
    staged_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    backend="$(jq -r '.backend' "${PI_RUN_HOME_RESOLVED}/snapshots/config.json")"
    jq -n --arg snapshotId "${snapshot_id}" --arg requestId "${request_id}" \
        --arg stagedAt "${staged_at}" --arg backend "${backend}" \
        '{schemaVersion:1,state:"validated",snapshotId:$snapshotId,requestId:$requestId,stagedAt:$stagedAt,sourceBackend:$backend}' \
        > "${temporary}/stage.json"
    chmod 0600 "${temporary}/stage.json"
    mv "${temporary}" "${pending}"
    SNAPSHOT_RESTORE_TMP=""
    trap - EXIT
    printf 'Restore staged: %s\nRequest: %s\nPath: %s\nLive Pi-Run data was not changed.\n' \
        "${snapshot_id}" "${request_id}" "${pending}"
}

recover_snapshot() {
    local reference="$1" resolved snapshot_id created machine scope request_id recovered_at backend
    local root="${PI_RUN_HOME_RESOLVED}/snapshots/recovered" destination temporary stale
    acquire_snapshot_operation_lock exclusive
    resolved="$(resolve_pi_run_snapshot_reference "${reference}")"
    IFS=$'\t' read -r snapshot_id created machine scope request_id <<< "${resolved}"
    [[ "${scope}" == complete ]] \
        || fail "snapshot is not a complete Pi-Run snapshot: ${reference}"

    if [[ ! -e "${root}" && ! -L "${root}" ]]; then
        mkdir -m 0700 "${root}"
    fi
    [[ -d "${root}" && ! -L "${root}" && "$(realpath "${root}")" == "${root}" &&
       "$(stat -c %a "${root}")" == 700 ]] \
        || fail "snapshot recovery directory is unsafe: ${root}"
    while IFS= read -r -d '' stale; do
        [[ "$(basename "${stale}")" =~ ^\.recover\.[0-9]+$ && -d "${stale}" && ! -L "${stale}" &&
           "$(realpath "${stale}")" == "${stale}" ]] \
            || fail "snapshot recovery staging is unsafe: ${stale}"
        rm -rf -- "${stale}"
    done < <(find "${root}" -mindepth 1 -maxdepth 1 -name '.recover.*' -print0)

    destination="${root}/${snapshot_id}"
    temporary="${root}/.recover.$$"
    [[ ! -e "${destination}" && ! -L "${destination}" ]] \
        || fail "snapshot recovery already exists: ${destination}"
    [[ ! -e "${temporary}" && ! -L "${temporary}" ]] \
        || fail "snapshot recovery staging path already exists: ${temporary}"
    mkdir -m 0700 "${temporary}"
    SNAPSHOT_RESTORE_TMP="${temporary}"
    trap cleanup_snapshot_restore EXIT
    run_snapshot_restore "${snapshot_id}" "${temporary}" \
        || fail "could not recover snapshot"
    validate_staged_restore "${temporary}" "${request_id}"
    chmod -R go-rwx "${temporary}/input"
    recovered_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    backend="$(jq -r '.backend' "${PI_RUN_HOME_RESOLVED}/snapshots/config.json")"
    jq -n --arg snapshotId "${snapshot_id}" --arg requestId "${request_id}" \
        --arg snapshotCreatedAt "${created}" --arg sourceMachine "${machine}" \
        --arg recoveredAt "${recovered_at}" --arg sourceBackend "${backend}" \
        '{schemaVersion:1,snapshotId:$snapshotId,requestId:$requestId,snapshotCreatedAt:$snapshotCreatedAt,sourceMachine:$sourceMachine,scope:"complete",recoveredAt:$recoveredAt,sourceBackend:$sourceBackend}' \
        > "${temporary}/input/recovery.json"
    chmod 0600 "${temporary}/input/recovery.json"
    mv "${temporary}/input" "${destination}"
    SNAPSHOT_RESTORE_TMP=""
    rmdir "${temporary}"
    trap - EXIT
    sync -f "${root}" || fail "snapshot was recovered but its directory could not be synchronized"
    printf 'Snapshot recovered: %s\nPath: %s\n' "${snapshot_id}" "${destination}"
    printf 'Recovered files are decrypted and may contain credentials or private conversation history.\n'
    printf 'Live Pi-Run data was not changed.\n'
}

validate_pending_restore_state() {
    local pending="$1" metadata resolved snapshot_id request_id staged_at backend
    [[ -d "${pending}" && ! -L "${pending}" && "$(realpath "${pending}")" == "${pending}" ]] \
        || fail "pending restore must be a non-symlink directory: ${pending}"
    validate_snapshot_file "${pending}/stage.json" "pending restore metadata"
    metadata="$(jq -er '
        select(
            .schemaVersion == 1 and .state == "validated" and
            (.snapshotId | type == "string") and (.snapshotId | test("^[0-9a-f]{64}$")) and
            (.requestId | type == "string") and
            (.requestId | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
            (.stagedAt | type == "string") and (.stagedAt | test("^[0-9T:+.-]+Z$")) and
            (.sourceBackend == "local" or .sourceBackend == "s3") and
            (keys | sort == ["requestId", "schemaVersion", "snapshotId", "sourceBackend", "stagedAt", "state"])
        ) | [.snapshotId, .requestId, .stagedAt, .sourceBackend] | @tsv
    ' "${pending}/stage.json")" || fail "pending restore metadata is invalid"
    IFS=$'\t' read -r snapshot_id request_id staged_at backend <<< "${metadata}"
    validate_staged_restore "${pending}" "${request_id}"
    resolved="${snapshot_id}"$'\t'"${request_id}"$'\t'"${staged_at}"$'\t'"${backend}"
    printf '%s\n' "${resolved}"
}

restore_staging_entry() {
    local root="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging" entry
    local -a entries
    [[ -d "${root}" && ! -L "${root}" && "$(realpath "${root}")" == "${root}" &&
       "$(stat -c %a "${root}")" == 700 ]] || fail "restore staging directory is unsafe: ${root}"
    mapfile -t entries < <(find "${root}" -mindepth 1 -maxdepth 1 -printf '%f\n')
    (( ${#entries[@]} <= 1 )) || fail "restore staging contains unexpected entries"
    (( ${#entries[@]} == 1 )) || return 2
    entry="${entries[0]}"
    [[ "${entry}" == pending || "${entry}" =~ ^\.cancelled\.[0-9a-f]{64}$ ]] \
        || fail "restore staging contains an unexpected entry: ${entry}"
    printf '%s/%s\n' "${root}" "${entry}"
}

restore_status() {
    local entry resolved snapshot_id request_id staged_at backend name status
    if entry="$(restore_staging_entry)"; then
        :
    else
        status=$?
        if (( status == 2 )); then
            printf 'Pending restore: none\n'
            return 0
        fi
        return "${status}"
    fi
    resolved="$(validate_pending_restore_state "${entry}")"
    IFS=$'\t' read -r snapshot_id request_id staged_at backend <<< "${resolved}"
    name="$(basename "${entry}")"
    if [[ "${name}" == pending ]]; then
        printf 'Pending restore: validated\n'
    else
        [[ "${name}" == ".cancelled.${snapshot_id}" ]] \
            || fail "interrupted restore cancellation metadata does not match its path"
        printf 'Pending restore: cancellation incomplete\n'
    fi
    printf 'Snapshot: %s\nRequest: %s\nSource backend: %s\nStaged: %s\nPath: %s\n' \
        "${snapshot_id}" "${request_id}" "${backend}" "${staged_at}" "${entry}"
}

cancel_staged_restore() {
    local reference="$1" entry resolved snapshot_id request_id staged_at backend cancelled name status
    [[ "${reference}" =~ ^([0-9a-f]{12}|[0-9a-f]{64})$ ]] \
        || fail "snapshot ID must be a 12 or 64 character lowercase hexadecimal ID"
    if entry="$(restore_staging_entry)"; then
        :
    else
        status=$?
        (( status != 2 )) || fail "there is no pending restore to cancel"
        return "${status}"
    fi
    name="$(basename "${entry}")"
    if [[ "${name}" =~ ^\.cancelled\.([0-9a-f]{64})$ ]]; then
        snapshot_id="${BASH_REMATCH[1]}"
        [[ "${snapshot_id}" == "${reference}"* ]] \
            || fail "interrupted restore cancellation does not match snapshot ID: ${reference}"
        rm -rf -- "${entry}"
        printf 'Cancelled staged restore: %s\nLive Pi-Run data was not changed.\n' "${snapshot_id}"
        return 0
    fi
    resolved="$(validate_pending_restore_state "${entry}")"
    IFS=$'\t' read -r snapshot_id request_id staged_at backend <<< "${resolved}"
    [[ "${snapshot_id}" == "${reference}"* ]] || fail "pending restore does not match snapshot ID: ${reference}"
    cancelled="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging/.cancelled.${snapshot_id}"
    [[ ! -e "${cancelled}" && ! -L "${cancelled}" ]] \
        || fail "restore cancellation path already exists: ${cancelled}"
    mv "${entry}" "${cancelled}"
    rm -rf -- "${cancelled}"
    printf 'Cancelled staged restore: %s\nLive Pi-Run data was not changed.\n' "${snapshot_id}"
}

sync_restore_filesystem() {
    sync -f "${PI_RUN_HOME_RESOLVED}" \
        || fail "could not durably synchronize restore transaction state"
}

recover_interrupted_restore() {
    local root="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging"
    local pending="${root}/pending" applying="${root}/applying" rollback="${root}/applying/rollback"
    local transaction="${root}/apply-transaction.json" state index live staged saved
    local -a keys=(home-config profiles skills shared workspaces snapshot-config)
    local -a sources=(config.json profiles skills shared workspaces snapshot-config.json)
    local -a targets=(
        "${PI_RUN_HOME_RESOLVED}/config.json"
        "${PI_RUN_HOME_RESOLVED}/profiles"
        "${PI_RUN_HOME_RESOLVED}/skills"
        "${PI_RUN_HOME_RESOLVED}/shared"
        "${PI_RUN_HOME_RESOLVED}/workspaces"
        "${PI_RUN_HOME_RESOLVED}/snapshots/config.json"
    )
    [[ -d "${root}" && ! -L "${root}" && "$(realpath "${root}")" == "${root}" ]] \
        || fail "cannot recover an unsafe restore staging directory"
    validate_snapshot_file "${transaction}" "restore transaction journal"
    state="$(jq -er '
        select(
            .schemaVersion == 1 and (.state == "applying" or .state == "committed") and
            (.restoreSnapshotId | type == "string") and (.restoreSnapshotId | test("^[0-9a-f]{64}$")) and
            (.restoreRequestId | type == "string") and
            (.restoreRequestId | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
            (.preRestoreSnapshotId | type == "string") and (.preRestoreSnapshotId | test("^[0-9a-f]{64}$")) and
            (.startedAt | type == "string") and
            (keys | sort == ["preRestoreSnapshotId", "restoreRequestId", "restoreSnapshotId", "schemaVersion", "startedAt", "state"])
        ) | .state
    ' "${transaction}")" || fail "restore transaction journal is invalid"
    if [[ "${state}" == committed ]]; then
        [[ ! -e "${pending}" && ! -L "${pending}" ]] \
            || fail "committed restore transaction conflicts with pending state"
        [[ ! -L "${applying}" ]] || fail "restore transaction directory is a symbolic link"
        [[ ! -e "${applying}" || -d "${applying}" ]] || fail "restore transaction path is unsafe"
        rm -rf -- "${applying}"
        rm -f -- "${transaction}"
        sync_restore_filesystem
        return 0
    fi
    if [[ -d "${pending}" && ! -L "${pending}" && ! -e "${applying}" && ! -L "${applying}" ]]; then
        rm -f -- "${transaction}"
        sync_restore_filesystem
        return 0
    fi
    [[ -d "${applying}" && ! -L "${applying}" && ! -e "${pending}" && ! -L "${pending}" ]] \
        || fail "restore transaction directories are inconsistent"
    if [[ -e "${rollback}" || -L "${rollback}" ]]; then
        [[ -d "${rollback}" && ! -L "${rollback}" ]] || fail "restore rollback path is unsafe"
        for (( index=${#keys[@]}-1; index>=0; index-- )); do
            live="${targets[index]}"
            staged="${applying}/input/${sources[index]}"
            saved="${rollback}/${keys[index]}"
            if [[ -e "${saved}" || -L "${saved}" ]]; then
                [[ ! -L "${saved}" ]] || fail "restore rollback entry is unsafe: ${saved}"
                if [[ -e "${live}" || -L "${live}" ]]; then
                    [[ ! -e "${staged}" && ! -L "${staged}" ]] \
                        || fail "restore rollback encountered duplicate staged content: ${staged}"
                    mv "${live}" "${staged}"
                fi
                mv "${saved}" "${live}"
            fi
        done
        rmdir "${rollback}"
    fi
    rm -f -- "${transaction}"
    mv "${applying}" "${pending}"
    sync_restore_filesystem
}

RESTORE_RECONNECT_TARGETS=()
RESTORE_RECONNECT_CURRENT=()
RESTORE_RECONNECT_PATHS=()
RESTORE_RECONNECT_NAMES=()
RESTORE_RECONNECT_COUNTS=()
RESTORE_RECONNECT_CONFIRMED=false
RESTORE_RECONNECT_DEFERRED=false

count_workspace_sessions_in_profiles() {
    local profiles="$1" id="$2" profile_dir session_dir file count=0
    local -a files
    for profile_dir in "${profiles}"/*; do
        [[ -d "${profile_dir}" ]] || continue
        session_dir="${profile_dir}/sessions/${id}"
        [[ -d "${session_dir}" && ! -L "${session_dir}" ]] || continue
        shopt -s nullglob
        files=("${session_dir}"/*.jsonl)
        shopt -u nullglob
        for file in "${files[@]}"; do
            [[ -f "${file}" && ! -L "${file}" ]] && count=$((count + 1))
        done
    done
    printf '%s\n' "${count}"
}

plan_restore_workspace_reconnections() {
    local pending="$1" machine live_registry staged_registry staged_profiles mapping
    local current_id path metadata name kind target_id session_count candidate_count
    local target_path mapped_target_path target_has_valid_path seen_index index
    local -a mappings targets raw_targets=() raw_current=() raw_paths=() raw_names=() raw_counts=()
    declare -A target_seen=()

    RESTORE_RECONNECT_TARGETS=()
    RESTORE_RECONNECT_CURRENT=()
    RESTORE_RECONNECT_PATHS=()
    RESTORE_RECONNECT_NAMES=()
    RESTORE_RECONNECT_COUNTS=()
    RESTORE_RECONNECT_CONFIRMED=false
    RESTORE_RECONNECT_DEFERRED=false
    machine="$(machine_file)"
    live_registry="${PI_RUN_HOME_RESOLVED}/workspaces/registry.json"
    staged_registry="${pending}/input/workspaces/registry.json"
    staged_profiles="${pending}/input/profiles"
    initialize_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    mapfile -t mappings < <(jq -r '.workspacePaths[] | [.workspaceId, .path] | @tsv' "${machine}")

    for mapping in "${mappings[@]}"; do
        IFS=$'\t' read -r current_id path <<< "${mapping}"
        [[ -n "${current_id}" && -n "${path}" && "${path}" != *$'\n'* &&
           -d "${path}" && ! -L "${path}" && "$(realpath "${path}")" == "${path}" ]] || continue
        workspace_has_session_state "${current_id}" && continue
        [[ "$(count_workspace_sessions_in_profiles "${staged_profiles}" "${current_id}")" == 0 ]] || continue
        metadata="$(jq -er --arg id "${current_id}" '
            [.workspaces[] | select(.id == $id)] |
            select(length == 1) | .[0] | [.name, .kind] | @tsv
        ' "${live_registry}" 2>/dev/null)" || continue
        IFS=$'\t' read -r name kind <<< "${metadata}"
        mapfile -t targets < <(jq -r --arg name "${name}" --arg kind "${kind}" --arg current "${current_id}" '
            .workspaces[] | select(.name == $name and .kind == $kind and .id != $current) | .id
        ' "${staged_registry}")
        candidate_count=0
        target_id=""
        session_count=0
        for target_path in "${targets[@]}"; do
            index="$(count_workspace_sessions_in_profiles "${staged_profiles}" "${target_path}")"
            (( index > 0 )) || continue
            target_has_valid_path=false
            while IFS= read -r mapped_target_path; do
                if [[ -d "${mapped_target_path}" && ! -L "${mapped_target_path}" &&
                      "$(realpath "${mapped_target_path}")" == "${mapped_target_path}" ]]; then
                    target_has_valid_path=true
                    break
                fi
            done < <(jq -r --arg id "${target_path}" \
                '.workspacePaths[] | select(.workspaceId == $id) | .path' "${machine}")
            [[ "${target_has_valid_path}" == false ]] || continue
            candidate_count=$((candidate_count + 1))
            target_id="${target_path}"
            session_count="${index}"
        done
        (( candidate_count == 1 )) || continue
        raw_targets+=("${target_id}")
        raw_current+=("${current_id}")
        raw_paths+=("${path}")
        raw_names+=("${name}")
        raw_counts+=("${session_count}")
        seen_index="${target_seen[${target_id}]:-}"
        if [[ -n "${seen_index}" ]]; then
            target_seen["${target_id}"]=ambiguous
        else
            target_seen["${target_id}"]="$((${#raw_targets[@]} - 1))"
        fi
    done

    for index in "${!raw_targets[@]}"; do
        [[ "${target_seen[${raw_targets[index]}]}" == "${index}" ]] || continue
        RESTORE_RECONNECT_TARGETS+=("${raw_targets[index]}")
        RESTORE_RECONNECT_CURRENT+=("${raw_current[index]}")
        RESTORE_RECONNECT_PATHS+=("${raw_paths[index]}")
        RESTORE_RECONNECT_NAMES+=("${raw_names[index]}")
        RESTORE_RECONNECT_COUNTS+=("${raw_counts[index]}")
    done
}

confirm_restore_workspace_reconnections() {
    local index response
    (( ${#RESTORE_RECONNECT_TARGETS[@]} > 0 )) || return 0
    if [[ ! -t 0 || ! -t 2 ]]; then
        RESTORE_RECONNECT_DEFERRED=true
        return 0
    fi
    printf 'Restore can reconnect local checkouts to restored sessions:\n' >&2
    for index in "${!RESTORE_RECONNECT_TARGETS[@]}"; do
        printf '  %s -> %s (%s session(s))\n' \
            "$(sanitize_display "${RESTORE_RECONNECT_PATHS[index]}")" \
            "$(sanitize_display "${RESTORE_RECONNECT_NAMES[index]}")" \
            "${RESTORE_RECONNECT_COUNTS[index]}" >&2
    done
    if ! read -r -p 'Reconnect these checkouts after restore? [Y/n]: ' response; then
        RESTORE_RECONNECT_DEFERRED=true
        return 0
    fi
    case "${response,,}" in
        ""|y|yes) RESTORE_RECONNECT_CONFIRMED=true ;;
        *) RESTORE_RECONNECT_DEFERRED=true ;;
    esac
}

restore_reconnection_was_deferred() {
    [[ "${RESTORE_RECONNECT_DEFERRED}" == true ]]
}

apply_restore_workspace_reconnections() {
    local index
    [[ "${RESTORE_RECONNECT_CONFIRMED}" == true ]] || return 0
    for index in "${!RESTORE_RECONNECT_TARGETS[@]}"; do
        reconnect_workspace_for_sessions \
            "${RESTORE_RECONNECT_TARGETS[index]}" \
            "${RESTORE_RECONNECT_PATHS[index]}" \
            "${RESTORE_RECONNECT_CURRENT[index]}"
    done
    printf 'Reconnected %s local checkout(s) to restored sessions.\n' \
        "${#RESTORE_RECONNECT_TARGETS[@]}"
}

RESTORE_ONE_SHOT_ACTIVE=false
RESTORE_APPLY_ACTIVE=false

cleanup_one_shot_restore_staging() {
    local root="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging" entry name resolved snapshot_id
    local cancelled
    local -a entries
    [[ -d "${root}" && ! -L "${root}" && "$(realpath "${root}")" == "${root}" &&
       "$(stat -c %a "${root}")" == 700 ]] || fail "restore staging directory is unsafe: ${root}"
    mapfile -t entries < <(find "${root}" -mindepth 1 -maxdepth 1 -printf '%f\n')
    (( ${#entries[@]} <= 1 )) || fail "restore staging contains unexpected entries"
    (( ${#entries[@]} == 1 )) || return 0
    name="${entries[0]}"
    entry="${root}/${name}"
    case "${name}" in
        pending)
            resolved="$(validate_pending_restore_state "${entry}")"
            IFS=$'\t' read -r snapshot_id _ <<< "${resolved}"
            cancelled="${root}/.cancelled.${snapshot_id}"
            [[ ! -e "${cancelled}" && ! -L "${cancelled}" ]] \
                || fail "restore cleanup path already exists: ${cancelled}"
            mv "${entry}" "${cancelled}"
            sync_restore_filesystem
            rm -rf -- "${cancelled}"
            ;;
        .cancelled.*)
            [[ "${name}" =~ ^\.cancelled\.[0-9a-f]{64}$ && -d "${entry}" && ! -L "${entry}" &&
               "$(realpath "${entry}")" == "${entry}" ]] \
                || fail "restore cleanup state is unsafe: ${entry}"
            rm -rf -- "${entry}"
            ;;
        .pending.*)
            [[ "${name}" =~ ^\.pending\.[0-9]+$ && -d "${entry}" && ! -L "${entry}" &&
               "$(realpath "${entry}")" == "${entry}" ]] \
                || fail "incomplete restore staging is unsafe: ${entry}"
            rm -rf -- "${entry}"
            ;;
        *) fail "restore staging contains an unexpected entry: ${entry}" ;;
    esac
    sync_restore_filesystem
}

cleanup_one_shot_restore() {
    local status=$?
    if [[ "${RESTORE_ONE_SHOT_ACTIVE}" == true ]]; then
        cleanup_one_shot_restore_staging
    fi
    return "${status}"
}

cleanup_restore_apply() {
    local status=$?
    if [[ "${RESTORE_APPLY_ACTIVE}" == true ]]; then
        recover_interrupted_restore
    fi
    if [[ "${RESTORE_ONE_SHOT_ACTIVE}" == true ]]; then
        cleanup_one_shot_restore_staging
    fi
    return "${status}"
}

apply_staged_restore() {
    local reference="$1" root="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging"
    local pending="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging/pending"
    local applying="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging/applying"
    local rollback="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging/applying/rollback"
    local transaction="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging/apply-transaction.json"
    local transaction_tmp="${PI_RUN_HOME_RESOLVED}/snapshots/restore-staging/.apply-transaction.tmp.$$"
    local resolved snapshot_id request_id staged_at backend pre_output pre_snapshot_id started_at
    local current_config staged_config index live staged saved home_device
    local -a keys=(home-config profiles skills shared workspaces snapshot-config)
    local -a sources=(config.json profiles skills shared workspaces snapshot-config.json)
    local -a targets=(
        "${PI_RUN_HOME_RESOLVED}/config.json"
        "${PI_RUN_HOME_RESOLVED}/profiles"
        "${PI_RUN_HOME_RESOLVED}/skills"
        "${PI_RUN_HOME_RESOLVED}/shared"
        "${PI_RUN_HOME_RESOLVED}/workspaces"
        "${PI_RUN_HOME_RESOLVED}/snapshots/config.json"
    )
    [[ "${HOME_LOCK_MODE}" == exclusive && "${HOME_LOCK_ACQUIRED}" == true ]] \
        || fail "restore application requires an exclusive Pi-Run home lock"
    [[ "${reference}" =~ ^([0-9a-f]{12}|[0-9a-f]{64})$ ]] \
        || fail "snapshot ID must be a 12 or 64 character lowercase hexadecimal ID"
    [[ "$(restore_staging_entry)" == "${pending}" ]] || fail "a validated pending restore is required"
    resolved="$(validate_pending_restore_state "${pending}")"
    IFS=$'\t' read -r snapshot_id request_id staged_at backend <<< "${resolved}"
    [[ "${snapshot_id}" == "${reference}"* ]] || fail "pending restore does not match snapshot ID: ${reference}"
    [[ ! -e "${applying}" && ! -L "${applying}" && ! -e "${transaction}" && ! -L "${transaction}" ]] \
        || fail "restore application state already exists"
    current_config="$(jq -S -c . "${PI_RUN_HOME_RESOLVED}/snapshots/config.json")" \
        || fail "active snapshot configuration is invalid"
    staged_config="$(jq -S -c . "${pending}/input/snapshot-config.json")" \
        || fail "staged snapshot configuration is invalid"
    [[ "${current_config}" == "${staged_config}" ]] \
        || fail "staged and active snapshot repository configurations do not match"
    home_device="$(stat -c %d "${PI_RUN_HOME_RESOLVED}")"
    for index in "${!keys[@]}"; do
        [[ "$(stat -c %d "${targets[index]}")" == "${home_device}" &&
           "$(stat -c %d "${pending}/input/${sources[index]}")" == "${home_device}" ]] \
            || fail "restore application requires live and staged paths on the Pi-Run home filesystem"
    done
    plan_restore_workspace_reconnections "${pending}"
    confirm_restore_workspace_reconnections

    pre_output="$(create_complete_snapshot pre-restore)"
    pre_snapshot_id="$(awk '$1 == "Snapshot" && $2 == "created:" && length($3) == 64 {print $3}' <<< "${pre_output}")"
    [[ "${pre_snapshot_id}" =~ ^[0-9a-f]{64}$ ]] \
        || fail "pre-restore snapshot did not return a valid snapshot ID"
    started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    jq -n --arg restoreSnapshotId "${snapshot_id}" --arg restoreRequestId "${request_id}" \
        --arg preRestoreSnapshotId "${pre_snapshot_id}" --arg startedAt "${started_at}" \
        '{schemaVersion:1,state:"applying",restoreSnapshotId:$restoreSnapshotId,restoreRequestId:$restoreRequestId,preRestoreSnapshotId:$preRestoreSnapshotId,startedAt:$startedAt}' \
        > "${transaction_tmp}"
    chmod 0600 "${transaction_tmp}"
    mv "${transaction_tmp}" "${transaction}"
    sync_restore_filesystem
    RESTORE_APPLY_ACTIVE=true
    trap cleanup_restore_apply EXIT
    mv "${pending}" "${applying}"
    mkdir -m 0700 "${rollback}"
    sync_restore_filesystem
    for index in "${!keys[@]}"; do
        live="${targets[index]}"
        staged="${applying}/input/${sources[index]}"
        saved="${rollback}/${keys[index]}"
        [[ ( -e "${live}" || -L "${live}" ) && ! -L "${live}" ]] \
            || fail "live restore target is missing or unsafe: ${live}"
        [[ ( -e "${staged}" || -L "${staged}" ) && ! -L "${staged}" ]] \
            || fail "staged restore source is missing or unsafe: ${staged}"
        mv "${live}" "${saved}"
        mv "${staged}" "${live}"
        sync_restore_filesystem
    done
    validate_complete_snapshot_sources
    snapshot_status >/dev/null
    jq '.state = "committed"' "${transaction}" > "${transaction}.tmp"
    chmod 0600 "${transaction}.tmp"
    mv "${transaction}.tmp" "${transaction}"
    sync_restore_filesystem
    rm -rf -- "${applying}"
    rm -f -- "${transaction}"
    sync_restore_filesystem
    RESTORE_APPLY_ACTIVE=false
    trap - EXIT
    printf 'Restore applied: %s\nPre-restore snapshot: %s\n' "${snapshot_id}" "${pre_snapshot_id}"
    apply_restore_workspace_reconnections
    if restore_reconnection_was_deferred; then
        printf 'Workspace reconnection was deferred; run pi-run resume to reconnect restored sessions.\n'
    fi
    printf 'Live Pi-Run data is ready for the next launch.\n'
}

confirm_snapshot_restore() {
    local snapshot_id="$1" response
    [[ -t 0 && -t 2 ]] \
        || fail "snapshot restore requires confirmation from an interactive terminal"
    cat >&2 <<EOF
This replaces the portable Pi-Run configuration, profiles, skills, shared data,
and workspace metadata with snapshot ${snapshot_id}.
A verified pre-restore snapshot and transactional rollback protect the current
state. Type the complete snapshot ID to continue.
EOF
    printf '> ' >&2
    IFS= read -r response || response=""
    [[ "${response}" == "${snapshot_id}" ]]
}

restore_snapshot() {
    local reference="$1" resolved snapshot_id created machine scope request_id
    [[ "${HOME_LOCK_MODE}" == exclusive && "${HOME_LOCK_ACQUIRED}" == true ]] \
        || fail "snapshot restore requires exclusive access to the Pi-Run home"
    resolved="$(resolve_pi_run_snapshot_reference "${reference}")"
    IFS=$'\t' read -r snapshot_id created machine scope request_id <<< "${resolved}"
    [[ "${scope}" == complete ]] \
        || fail "snapshot is not a complete Pi-Run snapshot: ${reference}"
    printf 'Snapshot to restore: %s\nCreated: %s\nMachine: %s\nScope: %s\n' \
        "${snapshot_id}" "${created}" "${machine}" "${scope}"
    if ! confirm_snapshot_restore "${snapshot_id}"; then
        printf 'Snapshot restore cancelled.\n'
        return 0
    fi

    cleanup_one_shot_restore_staging
    stage_snapshot_restore "${snapshot_id}" >/dev/null
    RESTORE_ONE_SHOT_ACTIVE=true
    trap cleanup_one_shot_restore EXIT
    apply_staged_restore "${snapshot_id}"
    RESTORE_ONE_SHOT_ACTIVE=false
    trap - EXIT
}

