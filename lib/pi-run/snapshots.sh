# SPDX-License-Identifier: MIT
# shellcheck shell=bash

validate_snapshot_root() {
    local root="${PI_RUN_HOME_RESOLVED}/snapshots"
    [[ -d "${root}" && ! -L "${root}" && "$(realpath "${root}")" == "${root}" ]] \
        || fail "snapshot path must be a non-symlink directory: ${root}"
    [[ "$(stat -c %a "${root}")" == 700 ]] \
        || fail "snapshot directory permissions must be 700: ${root}"
}

validate_snapshot_file() {
    local path="$1" label="$2" mode
    [[ -f "${path}" && ! -L "${path}" && "$(realpath "${path}")" == "${path}" ]] \
        || fail "${label} must be a regular non-symlink file: ${path}"
    [[ "$(stat -c %h "${path}")" == 1 ]] \
        || fail "${label} must not be hard-linked: ${path}"
    mode="$(stat -c %a "${path}")"
    [[ "${mode}" == 600 ]] || fail "${label} permissions must be 600: ${path}"
}

SNAPSHOT_OPERATION_LOCK_MODE=""
SNAPSHOT_OPERATION_LOCK_FD=""

acquire_snapshot_operation_lock() {
    local requested_mode="$1" root="${PI_RUN_HOME_RESOLVED}/snapshots"
    [[ "${requested_mode}" == shared || "${requested_mode}" == exclusive ]] \
        || fail "invalid snapshot operation lock mode: ${requested_mode}"
    validate_snapshot_root
    if [[ -n "${SNAPSHOT_OPERATION_LOCK_FD}" ]]; then
        if [[ "${SNAPSHOT_OPERATION_LOCK_MODE}" == shared && "${requested_mode}" == exclusive ]]; then
            fail "snapshot operation cannot upgrade its repository lock"
        fi
        return 0
    fi
    exec {SNAPSHOT_OPERATION_LOCK_FD}<"${root}" \
        || fail "could not open snapshot repository lifecycle lock"
    if [[ "${requested_mode}" == exclusive ]]; then
        if ! flock -n -x "${SNAPSHOT_OPERATION_LOCK_FD}"; then
            exec {SNAPSHOT_OPERATION_LOCK_FD}<&-
            SNAPSHOT_OPERATION_LOCK_FD=""
            fail "snapshot repository is in use by another operation"
        fi
    elif ! flock -n -s "${SNAPSHOT_OPERATION_LOCK_FD}"; then
        exec {SNAPSHOT_OPERATION_LOCK_FD}<&-
        SNAPSHOT_OPERATION_LOCK_FD=""
        fail "snapshot repository is being modified by another operation"
    fi
    SNAPSHOT_OPERATION_LOCK_MODE="${requested_mode}"
}

release_snapshot_operation_lock() {
    [[ -n "${SNAPSHOT_OPERATION_LOCK_FD}" ]] || return 0
    flock -u "${SNAPSHOT_OPERATION_LOCK_FD}" \
        || fail "could not release snapshot repository lifecycle lock"
    exec {SNAPSHOT_OPERATION_LOCK_FD}<&-
    SNAPSHOT_OPERATION_LOCK_FD=""
    SNAPSHOT_OPERATION_LOCK_MODE=""
}

run_snapshot_restic() {
    local access="$1" repository="$2" password_file="$3" mount_spec
    shift 3
    mount_spec="type=bind,src=${PI_RUN_HOME_RESOLVED}/snapshots,dst=/snapshots"
    [[ "${access}" != readonly ]] || mount_spec+=",readonly"
    docker run --rm \
        --network none \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
        --user "$(id -u):$(id -g)" \
        --mount "${mount_spec}" \
        --env "RESTIC_REPOSITORY=${repository}" \
        --env "RESTIC_PASSWORD_FILE=${password_file}" \
        --env RESTIC_CACHE_DIR=/tmp/restic-cache \
        --entrypoint restic \
        "${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}" "$@"
}

validate_s3_settings() {
    local endpoint="$1" bucket="$2" prefix="$3" region="$4" port
    [[ "${endpoint}" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ &&
       "${endpoint}" != *".."* && "${endpoint}" != *".-"* && "${endpoint}" != *"-."* ]] \
        || fail "invalid HTTPS S3 endpoint: ${endpoint}"
    if [[ "${endpoint}" =~ :([0-9]+)$ ]]; then
        port=$((10#${BASH_REMATCH[1]}))
        (( port >= 1 && port <= 65535 )) || fail "invalid S3 endpoint port: ${endpoint}"
    fi
    [[ "${bucket}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ &&
       "${bucket}" != *".."* && "${bucket}" != *".-"* && "${bucket}" != *"-."* ]] \
        || fail "invalid S3 bucket: ${bucket}"
    if (( ${#prefix} > 256 )) ||
       [[ ! "${prefix}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ||
          "/${prefix}/" == */../* || "/${prefix}/" == */./* ]]; then
        fail "invalid S3 prefix: ${prefix}"
    fi
    [[ "${region}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || fail "invalid S3 region: ${region}"
}

S3_RESTIC_TIMEOUT_SECONDS=""

run_s3_restic() {
    local repository="$1" password_file="$2" credentials_file="$3" region="$4"
    local -a runner=(docker)
    shift 4
    [[ -f "${CA_BUNDLE}" ]] || fail "CA bundle does not exist: ${CA_BUNDLE}"
    if [[ -n "${S3_RESTIC_TIMEOUT_SECONDS}" ]]; then
        command -v timeout >/dev/null 2>&1 || fail "timeout is required for S3 snapshot configuration"
        runner=(timeout --foreground --signal=TERM --kill-after=10s "${S3_RESTIC_TIMEOUT_SECONDS}s" docker)
    fi
    "${runner[@]}" run --rm \
        --network bridge \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
        --user "$(id -u):$(id -g)" \
        --mount "type=bind,src=${password_file},dst=/secret,readonly" \
        --mount "type=bind,src=${credentials_file},dst=/s3-credentials,readonly" \
        --mount "type=bind,src=${CA_BUNDLE},dst=/etc/ssl/certs/ca-certificates.crt,readonly" \
        --env "RESTIC_REPOSITORY=${repository}" \
        --env RESTIC_PASSWORD_FILE=/secret \
        --env AWS_SHARED_CREDENTIALS_FILE=/s3-credentials \
        --env AWS_PROFILE=default \
        --env "AWS_DEFAULT_REGION=${region}" \
        --env SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
        --env RESTIC_CACHE_DIR=/tmp/restic-cache \
        --entrypoint restic \
        "${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}" \
        -o "s3.region=${region}" -o s3.bucket-lookup=path "$@"
}

SNAPSHOT_LAUNCH_REQUEST_DIR=""
SNAPSHOT_LAUNCH_REQUEST_TOKEN=""
SNAPSHOT_LAUNCH_RESTART_SESSION_ID=""
SNAPSHOT_LAUNCH_RESTART_SESSION_FILE=""
SNAPSHOT_LAUNCH_REQUEST_HANDLED=false

cleanup_snapshot_launch_request() {
    if [[ -n "${SNAPSHOT_LAUNCH_REQUEST_DIR}" ]]; then
        rm -rf -- "${SNAPSHOT_LAUNCH_REQUEST_DIR}"
        SNAPSHOT_LAUNCH_REQUEST_DIR=""
    fi
}

prepare_snapshot_launch_request() {
    local root="${PI_RUN_HOME_RESOLVED}/snapshots/requests"
    [[ -d "${root}" && ! -L "${root}" && "$(realpath "${root}")" == "${root}" &&
       "$(stat -c %a "${root}")" == 700 ]] || fail "snapshot request directory is unsafe: ${root}"
    SNAPSHOT_LAUNCH_REQUEST_TOKEN="$(new_workspace_id)"
    SNAPSHOT_LAUNCH_REQUEST_DIR="${root}/${SNAPSHOT_LAUNCH_REQUEST_TOKEN}"
    [[ ! -e "${SNAPSHOT_LAUNCH_REQUEST_DIR}" && ! -L "${SNAPSHOT_LAUNCH_REQUEST_DIR}" ]] \
        || fail "snapshot launch request path already exists"
    mkdir -m 0700 "${SNAPSHOT_LAUNCH_REQUEST_DIR}"
}

validate_snapshot_restart_session() {
    local requested_id="$1" requested_file="$2" session_file session_id session_cwd
    [[ -d "${SESSION_DIR_HOST}" && ! -L "${SESSION_DIR_HOST}" ]] \
        || fail "snapshot restart session directory is unsafe: ${SESSION_DIR_HOST}"
    [[ ${#requested_file} -le 255 && "${requested_file}" =~ ^[[:print:]]+\.jsonl$ &&
       "${requested_file}" != */* && "${requested_file}" != *\\* ]] \
        || fail "snapshot restart session filename is invalid"
    session_file="${SESSION_DIR_HOST}/${requested_file}"
    validate_session_file "${session_file}"
    [[ "$(realpath "${session_file}")" == "${session_file}" ]] \
        || fail "snapshot restart session escapes its directory: ${requested_file}"
    IFS=$'\t' read -r session_id session_cwd < <(
        head -n 1 "${session_file}" | jq -er '[.id, .cwd] | @tsv'
    ) || fail "could not read Pi session identity: ${session_file}"
    [[ "${session_id}" == "${requested_id}" ]] \
        || fail "snapshot restart session ID does not match file: ${requested_file}"
    [[ "${session_cwd}" == /workspace ]] \
        || fail "snapshot restart session has an unexpected working directory: ${requested_id}"
}

process_snapshot_launch_request() {
    local request action token entry_count resume_session_id resume_session_file
    SNAPSHOT_LAUNCH_RESTART_SESSION_ID=""
    SNAPSHOT_LAUNCH_RESTART_SESSION_FILE=""
    SNAPSHOT_LAUNCH_REQUEST_HANDLED=false
    request="${SNAPSHOT_LAUNCH_REQUEST_DIR}/request.json"
    entry_count="$(find "${SNAPSHOT_LAUNCH_REQUEST_DIR}" -mindepth 1 -maxdepth 1 -printf '.' | wc -c)"
    if (( entry_count == 0 )); then
        return 0
    fi
    (( entry_count == 1 )) || fail "snapshot request directory contains unexpected entries"
    # shellcheck disable=SC2034 # Consumed by bin/pi-run after this sourced function returns.
    SNAPSHOT_LAUNCH_REQUEST_HANDLED=true
    validate_snapshot_file "${request}" "snapshot launch request"
    (( $(stat -c %s "${request}") <= 4096 )) || fail "snapshot launch request is too large"
    token="${SNAPSHOT_LAUNCH_REQUEST_TOKEN}"
    jq -e --arg token "${token}" '
        .schemaVersion == 3 and .token == $token and
        (.action == "status" or .action == "list" or .action == "create" or .action == "check") and
        ((.resumeSessionId == null and .resumeSessionFile == null) or
            ((.resumeSessionId | type == "string") and
             (.resumeSessionId | test("^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$")) and
             (.resumeSessionFile | type == "string") and
             (.resumeSessionFile | length > 0 and length <= 255) and
             (.resumeSessionFile | endswith(".jsonl")) and
             (.resumeSessionFile | test("^[\\x20-\\x7e]+$")) and
             (.resumeSessionFile | contains("/") | not) and
             (.resumeSessionFile | contains("\\\\") | not))) and
        (keys | sort == ["action", "resumeSessionFile", "resumeSessionId", "schemaVersion", "token"])
    ' "${request}" >/dev/null || fail "snapshot launch request is invalid or stale"
    action="$(jq -r '.action' "${request}")"
    resume_session_id="$(jq -r '.resumeSessionId // empty' "${request}")"
    resume_session_file="$(jq -r '.resumeSessionFile // empty' "${request}")"
    rm -f -- "${request}"
    if [[ -n "${resume_session_id}" ]]; then
        validate_snapshot_restart_session "${resume_session_id}" "${resume_session_file}"
        # shellcheck disable=SC2034 # Consumed by bin/pi-run after this sourced function returns.
        SNAPSHOT_LAUNCH_RESTART_SESSION_ID="${resume_session_id}"
        # shellcheck disable=SC2034 # Consumed by bin/pi-run after this sourced function returns.
        SNAPSHOT_LAUNCH_RESTART_SESSION_FILE="${resume_session_file}"
    fi
    case "${action}" in
        status) snapshot_status ;;
        list) list_snapshots ;;
        create) create_complete_snapshot ;;
        check) check_snapshot_repository ;;
    esac
}

snapshot_configuration_cancelled() {
    printf 'Snapshot configuration cancelled.\n'
}

read_snapshot_prompt() {
    local prompt="$1" destination="$2" value
    printf '%s' "${prompt}" >&2
    IFS= read -r value || return 1
    printf -v "${destination}" '%s' "${value}"
}

confirm_snapshot_configuration() {
    local response
    read_snapshot_prompt 'Configure this snapshot repository? [y/N]: ' response || return 1
    [[ "${response,,}" == y || "${response,,}" == yes ]]
}

require_unconfigured_snapshot_repository() {
    local root="${PI_RUN_HOME_RESOLVED}/snapshots" path stale
    validate_snapshot_root
    for path in config.json secrets repository s3-credentials; do
        [[ ! -e "${root}/${path}" && ! -L "${root}/${path}" ]] \
            || fail "snapshot configuration already exists or is incomplete; run: pi-run snapshot status"
    done
    stale="$(find "${root}" -mindepth 1 -maxdepth 1 \
        \( -name '.config.json.tmp.*' -o -name '.secrets.tmp.*' -o -name '.repository.tmp.*' -o -name '.s3-credentials.tmp.*' \) \
        -print -quit)"
    [[ -z "${stale}" ]] || fail "snapshot staging state already exists: ${stale}"
}

snapshot_repository_has_state() {
    local root="${PI_RUN_HOME_RESOLVED}/snapshots" path
    for path in config.json secrets repository s3-credentials; do
        [[ ! -e "${root}/${path}" && ! -L "${root}/${path}" ]] || return 0
    done
    return 1
}

confirm_snapshot_menu_action() {
    local prompt="$1" response
    read_snapshot_prompt "${prompt} [y/N]: " response || return 1
    [[ "${response,,}" == y || "${response,,}" == yes ]]
}

interactive_snapshot_menu() {
    local selection
    validate_snapshot_root
    if ! snapshot_repository_has_state; then
        cat >&2 <<'EOF'
Snapshots are not configured.

  1) Configure snapshot storage
  q) Cancel
EOF
        while true; do
            read_snapshot_prompt 'Selection [1/q]: ' selection || {
                printf 'Snapshot menu cancelled.\n'
                return 0
            }
            case "${selection,,}" in
                1|configure)
                    interactive_snapshot_configuration
                    return 0
                    ;;
                q|quit|cancel)
                    printf 'Snapshot menu cancelled.\n'
                    return 0
                    ;;
                *) printf 'Enter 1 to configure snapshots or q to cancel.\n' >&2 ;;
            esac
        done
    fi

    cat >&2 <<'EOF'
Snapshot management:

  1) Show status
  2) Create a complete snapshot
  3) List snapshots
  4) Run full integrity check
  q) Cancel
EOF
    while true; do
        read_snapshot_prompt 'Selection [1/2/3/4/q]: ' selection || {
            printf 'Snapshot menu cancelled.\n'
            return 0
        }
        case "${selection,,}" in
            1|status)
                snapshot_status
                return 0
                ;;
            2|create)
                printf 'A complete encrypted snapshot of portable Pi-Run state will be created.\n' >&2
                if confirm_snapshot_menu_action 'Create the snapshot?'; then
                    create_complete_snapshot
                else
                    printf 'Snapshot creation cancelled.\n'
                fi
                return 0
                ;;
            3|list)
                list_snapshots
                return 0
                ;;
            4|check)
                printf 'A full integrity check reads every stored data pack.\n' >&2
                printf 'For S3 this downloads all stored data and may incur provider charges.\n' >&2
                if confirm_snapshot_menu_action 'Run the full integrity check?'; then
                    check_snapshot_repository
                else
                    printf 'Snapshot check cancelled.\n'
                fi
                return 0
                ;;
            q|quit|cancel)
                printf 'Snapshot menu cancelled.\n'
                return 0
                ;;
            *) printf 'Enter 1, 2, 3, 4, or q to cancel.\n' >&2 ;;
        esac
    done
}

interactive_snapshot_configuration() {
    local selection endpoint bucket prefix region repository_mode mode_label
    acquire_snapshot_operation_lock exclusive
    require_unconfigured_snapshot_repository
    cat >&2 <<'EOF'
Choose snapshot storage:

  1) Local — encrypted repository under the Pi-Run home
     Simple, but it does not protect against loss of this disk.

  2) S3/Ceph — encrypted repository in remote object storage
     Requires an existing bucket and S3 credentials.

  q) Cancel
EOF
    while true; do
        read_snapshot_prompt 'Selection [1/2/q]: ' selection || {
            snapshot_configuration_cancelled
            return 0
        }
        case "${selection,,}" in
            1|local)
                printf '\nLocal repository: %s/snapshots/repository\n' "${PI_RUN_HOME_RESOLVED}" >&2
                printf 'Warning: this repository alone does not protect against loss of the local disk.\n' >&2
                if confirm_snapshot_configuration; then
                    configure_snapshot_repository
                else
                    snapshot_configuration_cancelled
                fi
                return 0
                ;;
            2|s3|ceph)
                break
                ;;
            q|quit|cancel)
                snapshot_configuration_cancelled
                return 0
                ;;
            *) printf 'Enter 1 for local storage, 2 for S3/Ceph, or q to cancel.\n' >&2 ;;
        esac
    done

    while true; do
        read_snapshot_prompt 'HTTPS S3 API endpoint (not a web-console URL; example https://s3.example.com): ' endpoint || {
            snapshot_configuration_cancelled
            return 0
        }
        if (validate_s3_settings "${endpoint}" valid-bucket valid/prefix us-east-1) >/dev/null 2>&1; then
            break
        fi
        printf 'Enter an HTTPS endpoint containing only a host and optional port, with no path.\n' >&2
    done
    while true; do
        read_snapshot_prompt 'Existing S3 bucket name: ' bucket || {
            snapshot_configuration_cancelled
            return 0
        }
        if (validate_s3_settings "${endpoint}" "${bucket}" valid/prefix us-east-1) >/dev/null 2>&1; then
            break
        fi
        printf 'Enter a valid lowercase S3 bucket name, for example pi-run-backups.\n' >&2
    done
    while true; do
        read_snapshot_prompt 'Unique repository prefix (no leading slash; example users/alice/pi-run): ' prefix || {
            snapshot_configuration_cancelled
            return 0
        }
        if (validate_s3_settings "${endpoint}" "${bucket}" "${prefix}" us-east-1) >/dev/null 2>&1; then
            break
        fi
        printf 'Use slash-separated letters, numbers, dots, underscores, or hyphens; do not use . or .. segments.\n' >&2
    done
    while true; do
        read_snapshot_prompt 'S3 region [us-east-1]: ' region || {
            snapshot_configuration_cancelled
            return 0
        }
        region="${region:-us-east-1}"
        if (validate_s3_settings "${endpoint}" "${bucket}" "${prefix}" "${region}") >/dev/null 2>&1; then
            break
        fi
        printf 'Enter a lowercase S3 region such as us-east-1 or eu-west-1.\n' >&2
    done

    cat >&2 <<'EOF'

Repository operation:

  1) Create a new encrypted repository
  2) Connect to an existing encrypted repository
EOF
    while true; do
        read_snapshot_prompt 'Selection [1/2]: ' selection || {
            snapshot_configuration_cancelled
            return 0
        }
        case "${selection,,}" in
            1|create|new)
                repository_mode=create
                mode_label='create new'
                break
                ;;
            2|connect|existing)
                repository_mode=connect
                mode_label='connect existing'
                break
                ;;
            *) printf 'Enter 1 to create a new repository or 2 to connect to an existing repository.\n' >&2 ;;
        esac
    done

    printf '\nS3 snapshot repository:\n  Operation: %s\n  Endpoint:  %s\n  Bucket:    %s\n  Prefix:    %s\n  Region:    %s\n' \
        "${mode_label}" "${endpoint}" "${bucket}" "${prefix}" "${region}" >&2
    if ! confirm_snapshot_configuration; then
        snapshot_configuration_cancelled
        return 0
    fi
    configure_s3_snapshot_repository "${endpoint}" "${bucket}" "${prefix}" "${region}" "${repository_mode}"
}

SNAPSHOT_CONFIG_STAGING=""
SNAPSHOT_SECRETS_STAGING=""
SNAPSHOT_REPOSITORY_STAGING=""
SNAPSHOT_S3_CREDENTIALS_STAGING=""

cleanup_snapshot_staging() {
    local path
    S3_RESTIC_TIMEOUT_SECONDS=""
    for path in \
        "${SNAPSHOT_CONFIG_STAGING}" \
        "${SNAPSHOT_SECRETS_STAGING}" \
        "${SNAPSHOT_REPOSITORY_STAGING}" \
        "${SNAPSHOT_S3_CREDENTIALS_STAGING}"; do
        [[ -z "${path}" ]] || rm -rf -- "${path}"
    done
}

configure_snapshot_repository() {
    local root="${PI_RUN_HOME_RESOLVED}/snapshots"
    acquire_snapshot_operation_lock exclusive
    local config="${root}/config.json" secrets="${root}/secrets" repository="${root}/repository"
    local s3_credentials="${root}/s3-credentials"
    local suffix="$$"
    local config_tmp="${root}/.config.json.tmp.${suffix}"
    local secrets_tmp="${root}/.secrets.tmp.${suffix}" repository_tmp="${root}/.repository.tmp.${suffix}"
    local path stale
    validate_snapshot_root
    stale="$(find "${root}" -mindepth 1 -maxdepth 1 \
        \( -name '.config.json.tmp.*' -o -name '.secrets.tmp.*' -o -name '.repository.tmp.*' -o -name '.s3-credentials.tmp.*' \) \
        -print -quit)"
    [[ -z "${stale}" ]] || fail "snapshot staging state already exists: ${stale}"
    for path in "${config}" "${secrets}" "${repository}" "${s3_credentials}"; do
        [[ ! -e "${path}" && ! -L "${path}" ]] \
            || fail "snapshot configuration already exists or is incomplete: ${path}"
    done
    for path in "${config_tmp}" "${secrets_tmp}" "${repository_tmp}"; do
        [[ ! -e "${path}" && ! -L "${path}" ]] \
            || fail "snapshot staging path already exists: ${path}"
    done

    SNAPSHOT_CONFIG_STAGING="${config_tmp}"
    SNAPSHOT_SECRETS_STAGING="${secrets_tmp}"
    SNAPSHOT_REPOSITORY_STAGING="${repository_tmp}"
    trap cleanup_snapshot_staging EXIT
    printf '%s%s\n' "$(new_workspace_id)" "$(new_workspace_id)" > "${secrets_tmp}"
    chmod 0600 "${secrets_tmp}"
    printf '%s\n' '{"schemaVersion":1,"backend":"local","repository":"repository"}' > "${config_tmp}"
    chmod 0600 "${config_tmp}"

    run_snapshot_restic readwrite \
        "/snapshots/$(basename "${repository_tmp}")" \
        "/snapshots/$(basename "${secrets_tmp}")" init
    [[ -d "${repository_tmp}" && ! -L "${repository_tmp}" && -f "${repository_tmp}/config" ]] \
        || fail "Restic did not create the expected local repository"

    mv "${secrets_tmp}" "${secrets}"
    mv "${repository_tmp}" "${repository}"
    mv "${config_tmp}" "${config}"
    trap - EXIT
    SNAPSHOT_CONFIG_STAGING=""
    SNAPSHOT_SECRETS_STAGING=""
    SNAPSHOT_REPOSITORY_STAGING=""
    printf 'Snapshot repository configured: %s\n' "${repository}"
    printf 'Back up the private recovery secret separately: %s\n' "${secrets}"
}

configure_s3_snapshot_repository() {
    local endpoint="$1" bucket="$2" prefix="$3" region="$4" repository_mode="$5"
    acquire_snapshot_operation_lock exclusive
    local access_key secret_key restic_password operation_status
    local root="${PI_RUN_HOME_RESOLVED}/snapshots" suffix="$$" path stale repository
    local config="${root}/config.json" secrets="${root}/secrets" credentials="${root}/s3-credentials"
    local config_tmp="${root}/.config.json.tmp.${suffix}" secrets_tmp="${root}/.secrets.tmp.${suffix}"
    local credentials_tmp="${root}/.s3-credentials.tmp.${suffix}"
    validate_snapshot_root
    validate_s3_settings "${endpoint}" "${bucket}" "${prefix}" "${region}"
    [[ "${repository_mode}" == create || "${repository_mode}" == connect ]] \
        || fail "invalid S3 repository operation"
    stale="$(find "${root}" -mindepth 1 -maxdepth 1 \
        \( -name '.config.json.tmp.*' -o -name '.secrets.tmp.*' -o -name '.repository.tmp.*' -o -name '.s3-credentials.tmp.*' \) \
        -print -quit)"
    [[ -z "${stale}" ]] || fail "snapshot staging state already exists: ${stale}"
    for path in "${config}" "${secrets}" "${credentials}" "${root}/repository"; do
        [[ ! -e "${path}" && ! -L "${path}" ]] \
            || fail "snapshot configuration already exists or is incomplete: ${path}"
    done
    while true; do
        read_snapshot_prompt 'S3 access key: ' access_key || {
            snapshot_configuration_cancelled
            return 0
        }
        [[ "${access_key}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] && break
        printf 'The access key must contain 1-128 letters, numbers, dots, underscores, or hyphens.\n' >&2
    done
    while true; do
        printf 'S3 secret key: ' >&2
        if ! IFS= read -rs secret_key; then
            printf '\n' >&2
            snapshot_configuration_cancelled
            return 0
        fi
        printf '\n' >&2
        [[ "${secret_key}" =~ ^[A-Za-z0-9/+_.=-]{1,256}$ ]] && break
        printf 'The secret key contains unsupported characters or has an invalid length.\n' >&2
    done
    if [[ "${repository_mode}" == connect ]]; then
        while true; do
            printf 'Existing Restic recovery password: ' >&2
            if ! IFS= read -rs restic_password; then
                printf '\n' >&2
                snapshot_configuration_cancelled
                return 0
            fi
            printf '\n' >&2
            (( ${#restic_password} >= 1 && ${#restic_password} <= 1024 )) && break
            printf 'The Restic recovery password must contain 1-1024 characters.\n' >&2
        done
    else
        restic_password="$(new_workspace_id)$(new_workspace_id)"
    fi

    SNAPSHOT_CONFIG_STAGING="${config_tmp}"
    SNAPSHOT_SECRETS_STAGING="${secrets_tmp}"
    SNAPSHOT_S3_CREDENTIALS_STAGING="${credentials_tmp}"
    trap cleanup_snapshot_staging EXIT
    printf '%s\n' "${restic_password}" > "${secrets_tmp}"
    printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
        "${access_key}" "${secret_key}" > "${credentials_tmp}"
    chmod 0600 "${secrets_tmp}" "${credentials_tmp}"
    jq -n --arg endpoint "${endpoint}" --arg bucket "${bucket}" \
        --arg prefix "${prefix}" --arg region "${region}" \
        '{schemaVersion:1,backend:"s3",endpoint:$endpoint,bucket:$bucket,prefix:$prefix,region:$region,bucketLookup:"path"}' \
        > "${config_tmp}"
    chmod 0600 "${config_tmp}"
    repository="s3:${endpoint}/${bucket}/${prefix}"
    S3_RESTIC_TIMEOUT_SECONDS=90

    if [[ "${repository_mode}" == create ]]; then
        printf 'Creating encrypted S3 repository...\n' >&2
        if run_s3_restic "${repository}" "${secrets_tmp}" "${credentials_tmp}" "${region}" init; then
            :
        else
            operation_status=$?
            (( operation_status != 124 )) \
                || fail "S3 repository creation timed out after ${S3_RESTIC_TIMEOUT_SECONDS} seconds"
            printf 'Initialization returned a failure; checking whether the repository was created...\n' >&2
            run_s3_restic "${repository}" "${secrets_tmp}" "${credentials_tmp}" "${region}" \
                --no-lock snapshots --json >/dev/null \
                || fail "could not create the S3 repository; verify TLS trust, credentials, bucket access, and that the prefix is unused"
        fi
        printf 'Verifying encrypted S3 repository...\n' >&2
    else
        printf 'Opening and verifying existing encrypted S3 repository...\n' >&2
    fi
    if run_s3_restic "${repository}" "${secrets_tmp}" "${credentials_tmp}" "${region}" \
        --no-lock snapshots --json >/dev/null; then
        :
    else
        operation_status=$?
        (( operation_status != 124 )) \
            || fail "S3 repository verification timed out after ${S3_RESTIC_TIMEOUT_SECONDS} seconds"
        fail "could not open the S3 repository; verify TLS trust, credentials, prefix, and Restic recovery password"
    fi
    S3_RESTIC_TIMEOUT_SECONDS=""

    mv "${secrets_tmp}" "${secrets}"
    mv "${credentials_tmp}" "${credentials}"
    mv "${config_tmp}" "${config}"
    trap - EXIT
    SNAPSHOT_CONFIG_STAGING=""
    SNAPSHOT_SECRETS_STAGING=""
    SNAPSHOT_S3_CREDENTIALS_STAGING=""
    access_key=""
    secret_key=""
    restic_password=""
    printf 'Snapshot repository configured: %s/%s/%s\n' "${endpoint}" "${bucket}" "${prefix}"
    printf 'Back up both private recovery files separately: %s and %s\n' "${secrets}" "${credentials}"
}

snapshot_status() {
    local root="${PI_RUN_HOME_RESOLVED}/snapshots" backend endpoint bucket prefix region remote
    local config="${root}/config.json" secrets="${root}/secrets" repository="${root}/repository"
    local credentials="${root}/s3-credentials"
    local -a credential_lines
    acquire_snapshot_operation_lock shared
    if [[ ! -e "${config}" && ! -L "${config}" &&
          ! -e "${secrets}" && ! -L "${secrets}" &&
          ! -e "${repository}" && ! -L "${repository}" &&
          ! -e "${credentials}" && ! -L "${credentials}" ]]; then
        printf 'Snapshot status: unconfigured\n'
        return 0
    fi
    validate_snapshot_file "${config}" "snapshot configuration"
    validate_snapshot_file "${secrets}" "snapshot secret"
    [[ -s "${secrets}" ]] || fail "snapshot secret is empty: ${secrets}"
    backend="$(jq -er '.backend | select(type == "string")' "${config}")" \
        || fail "invalid snapshot configuration: ${config}"
    if [[ "${backend}" == local ]]; then
        [[ ! -e "${credentials}" && ! -L "${credentials}" ]] \
            || fail "local snapshot configuration contains unexpected S3 credentials"
        jq -e '
            .schemaVersion == 1 and .backend == "local" and .repository == "repository" and
            (keys | sort == ["backend", "repository", "schemaVersion"])
        ' "${config}" >/dev/null || fail "invalid snapshot configuration: ${config}"
        [[ -d "${repository}" && ! -L "${repository}" && "$(realpath "${repository}")" == "${repository}" ]] \
            || fail "snapshot repository must be a non-symlink directory: ${repository}"
        run_snapshot_restic readonly /snapshots/repository /snapshots/secrets \
            --no-lock snapshots --json >/dev/null \
            || fail "could not open the local snapshot repository"
        printf 'Snapshot backend: local\nSnapshot repository: %s\nSnapshot status: ready\n' "${repository}"
        return 0
    fi
    [[ "${backend}" == s3 && ! -e "${repository}" && ! -L "${repository}" ]] \
        || fail "invalid or incomplete S3 snapshot configuration"
    validate_snapshot_file "${credentials}" "S3 credentials"
    mapfile -t credential_lines < "${credentials}"
    if (( ${#credential_lines[@]} != 3 )) ||
       [[ "${credential_lines[0]:-}" != '[default]' ||
          ! "${credential_lines[1]:-}" =~ ^aws_access_key_id\ =\ [A-Za-z0-9._-]{1,128}$ ||
          ! "${credential_lines[2]:-}" =~ ^aws_secret_access_key\ =\ [A-Za-z0-9/+_.=-]{1,256}$ ]]; then
        fail "invalid S3 credentials file: ${credentials}"
    fi
    jq -e '
        .schemaVersion == 1 and .backend == "s3" and .bucketLookup == "path" and
        (.endpoint | type == "string") and (.bucket | type == "string") and
        (.prefix | type == "string") and (.region | type == "string") and
        (keys | sort == ["backend", "bucket", "bucketLookup", "endpoint", "prefix", "region", "schemaVersion"])
    ' "${config}" >/dev/null || fail "invalid snapshot configuration: ${config}"
    IFS=$'\t' read -r endpoint bucket prefix region < <(
        jq -r '[.endpoint, .bucket, .prefix, .region] | @tsv' "${config}")
    validate_s3_settings "${endpoint}" "${bucket}" "${prefix}" "${region}"
    remote="s3:${endpoint}/${bucket}/${prefix}"
    run_s3_restic "${remote}" "${secrets}" "${credentials}" "${region}" \
        --no-lock snapshots --json >/dev/null || fail "could not open the S3 snapshot repository"
    printf 'Snapshot backend: s3\nSnapshot endpoint: %s\nSnapshot bucket: %s\nSnapshot prefix: %s\nSnapshot status: ready\n' \
        "${endpoint}" "${bucket}" "${prefix}"
}

snapshot_auto_on_exit_enabled() {
    local machine
    machine="$(machine_file)"
    if [[ ! -e "${machine}" && ! -L "${machine}" ]]; then
        printf 'false\n'
        return 0
    fi
    [[ -f "${machine}" && ! -L "${machine}" && "$(realpath "${machine}")" == "${machine}" &&
       "$(stat -c %a "${machine}")" == 600 ]] \
        || fail "machine configuration is unsafe: ${machine}"
    validate_workspace_metadata "${machine}"
    jq -e '
        ((.snapshotAuto // {}) | type == "object") and
        ((.snapshotAuto.onSessionExit // false) | type == "boolean")
    ' "${machine}" >/dev/null || fail "machine automatic snapshot configuration is invalid: ${machine}"
    jq -r '.snapshotAuto.onSessionExit // false' "${machine}"
}

set_snapshot_auto_on_exit() {
    local enabled="$1" machine
    [[ "${enabled}" == true || "${enabled}" == false ]] \
        || fail "invalid automatic snapshot setting"
    machine="$(machine_file)"
    acquire_workspace_lock
    initialize_machine_file "${machine}"
    validate_workspace_metadata "${machine}"
    jq -e '
        ((.snapshotAuto // {}) | type == "object") and
        ((.snapshotAuto.onSessionExit // false) | type == "boolean")
    ' "${machine}" >/dev/null || fail "machine automatic snapshot configuration is invalid: ${machine}"
    # shellcheck disable=SC2016 # $enabled is a jq variable.
    update_json "${machine}" --argjson enabled "${enabled}" \
        '.snapshotAuto = ((.snapshotAuto // {}) + {onSessionExit:$enabled})'
    release_workspace_lock
}

snapshot_auto_status() {
    local state=disabled
    [[ "$(snapshot_auto_on_exit_enabled)" != true ]] || state=enabled
    printf 'Automatic snapshots on successful Pi exit: %s\n' "${state}"
}

snapshot_auto_enable() {
    local backend config="${PI_RUN_HOME_RESOLVED}/snapshots/config.json"
    [[ -f "${config}" && ! -L "${config}" ]] \
        || fail "snapshot repository is not configured; run: pi-run snapshot configure"
    snapshot_status >/dev/null
    backend="$(jq -r '.backend' "${config}")"
    set_snapshot_auto_on_exit true
    printf 'Automatic snapshots on successful Pi exit: enabled\n'
    if [[ "${backend}" == s3 ]]; then
        printf 'Each successful Pi exit can use remote storage, bandwidth, and provider operations.\n'
    fi
}

snapshot_auto_disable() {
    set_snapshot_auto_on_exit false
    printf 'Automatic snapshots on successful Pi exit: disabled\n'
}

create_automatic_snapshot_on_exit() {
    local output
    [[ "$(snapshot_auto_on_exit_enabled)" == true ]] || return 0
    printf 'Creating automatic snapshot after successful Pi exit...\n' >&2
    if ! output="$(create_complete_snapshot automatic)"; then
        fail "automatic snapshot on exit failed; it was not retried"
    fi
    printf '%s\n' "${output}"
}

require_local_snapshot_backend() {
    local backend
    backend="$(jq -er '.backend | select(type == "string")' \
        "${PI_RUN_HOME_RESOLVED}/snapshots/config.json" 2>/dev/null)" \
        || fail "snapshot repository is not configured"
    [[ "${backend}" != s3 ]] || fail "this snapshot operation is not implemented for S3 repositories"
    [[ "${backend}" == local ]] || fail "invalid snapshot backend"
}

validate_complete_snapshot_sources() {
    local home="${PI_RUN_HOME_RESOLVED}" path unsafe profile_dir profile_name
    validate_snapshot_file "${home}/config.json" "home configuration"
    validate_snapshot_file "${home}/snapshots/config.json" "snapshot configuration"
    for path in profiles skills shared workspaces; do
        path="${home}/${path}"
        [[ -d "${path}" && ! -L "${path}" && "$(realpath "${path}")" == "${path}" ]] \
            || fail "snapshot source must be a non-symlink directory: ${path}"
        unsafe="$(find "${path}" -xdev -mindepth 1 ! -type f ! -type d -print -quit)"
        [[ -z "${unsafe}" ]] || fail "snapshot source contains a link or special file: ${unsafe}"
        unsafe="$(find "${path}" -xdev -type f -links +1 -print -quit)"
        [[ -z "${unsafe}" ]] || fail "snapshot source contains a hard-linked file: ${unsafe}"
    done
    for profile_dir in "${home}/profiles"/*; do
        [[ -d "${profile_dir}" ]] || continue
        profile_name="$(basename "${profile_dir}")"
        validate_profile_name "${profile_name}"
        validate_profile_config "${profile_dir}" "${profile_name}"
        validate_profile_definition_files "${profile_dir}"
        validate_profile_skills_directory "${profile_dir}"
    done
    read_home_default_profile >/dev/null \
        || fail "home configuration is missing, invalid, or unsafe: ${home}/config.json"
    jq -e '
        .schemaVersion == 1 and (.workspaces | type == "array") and
        all(.workspaces[];
            (.id | type == "string") and (.name | type == "string") and
            (.kind == "git" or .kind == "directory") and (.createdAt | type == "string"))
    ' "${home}/workspaces/registry.json" >/dev/null \
        || fail "invalid workspace registry: ${home}/workspaces/registry.json"
}

query_snapshot_pi_version() {
    local version
    version="$(docker run --rm \
        --network none \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
        --user "$(id -u):$(id -g)" \
        --env HOME=/tmp \
        --entrypoint pi \
        "${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}" --version)"
    version="${version//$'\r'/}"
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9._-]+)?$ ]] \
        || fail "runtime image returned an invalid Pi version"
    printf '%s\n' "${version}"
}

run_complete_snapshot_backup() {
    local manifest="$1"
    local home="${PI_RUN_HOME_RESOLVED}" root="${PI_RUN_HOME_RESOLVED}/snapshots"
    local request_id="$2" purpose="$3"
    docker run --rm \
        --network none \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
        --tmpfs /input:rw,noexec,nosuid,nodev,size=1m \
        --user "$(id -u):$(id -g)" \
        --mount "type=bind,src=${root}/repository,dst=/repository" \
        --mount "type=bind,src=${root}/secrets,dst=/secret,readonly" \
        --mount "type=bind,src=${home}/config.json,dst=/input/config.json,readonly" \
        --mount "type=bind,src=${home}/profiles,dst=/input/profiles,readonly" \
        --mount "type=bind,src=${home}/skills,dst=/input/skills,readonly" \
        --mount "type=bind,src=${home}/shared,dst=/input/shared,readonly" \
        --mount "type=bind,src=${home}/workspaces,dst=/input/workspaces,readonly" \
        --mount "type=bind,src=${root}/config.json,dst=/input/snapshot-config.json,readonly" \
        --mount "type=bind,src=${manifest},dst=/input/snapshot-manifest.json,readonly" \
        --env RESTIC_REPOSITORY=/repository \
        --env RESTIC_PASSWORD_FILE=/secret \
        --env RESTIC_CACHE_DIR=/tmp/restic-cache \
        --entrypoint restic \
        "${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}" backup --json --one-file-system \
        --host "$(machine_id)" --tag pi-run --tag scope=complete --tag "request=${request_id}" \
        --tag "purpose=${purpose}" \
        /input/config.json /input/profiles /input/skills /input/shared /input/workspaces \
        /input/snapshot-config.json /input/snapshot-manifest.json
}

s3_snapshot_connection() {
    jq -r '["s3:" + .endpoint + "/" + .bucket + "/" + .prefix, .region] | @tsv' \
        "${PI_RUN_HOME_RESOLVED}/snapshots/config.json"
}

run_complete_s3_snapshot_backup() {
    local manifest="$1" request_id="$2" purpose="$3" repository region
    local home="${PI_RUN_HOME_RESOLVED}" root="${PI_RUN_HOME_RESOLVED}/snapshots"
    IFS=$'\t' read -r repository region < <(s3_snapshot_connection)
    docker run --rm \
        --network bridge \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m \
        --tmpfs /input:rw,noexec,nosuid,nodev,size=1m \
        --user "$(id -u):$(id -g)" \
        --mount "type=bind,src=${root}/secrets,dst=/secret,readonly" \
        --mount "type=bind,src=${root}/s3-credentials,dst=/s3-credentials,readonly" \
        --mount "type=bind,src=${CA_BUNDLE},dst=${CA_BUNDLE},readonly" \
        --mount "type=bind,src=${home}/config.json,dst=/input/config.json,readonly" \
        --mount "type=bind,src=${home}/profiles,dst=/input/profiles,readonly" \
        --mount "type=bind,src=${home}/skills,dst=/input/skills,readonly" \
        --mount "type=bind,src=${home}/shared,dst=/input/shared,readonly" \
        --mount "type=bind,src=${home}/workspaces,dst=/input/workspaces,readonly" \
        --mount "type=bind,src=${root}/config.json,dst=/input/snapshot-config.json,readonly" \
        --mount "type=bind,src=${manifest},dst=/input/snapshot-manifest.json,readonly" \
        --env "RESTIC_REPOSITORY=${repository}" \
        --env RESTIC_PASSWORD_FILE=/secret \
        --env AWS_SHARED_CREDENTIALS_FILE=/s3-credentials \
        --env AWS_PROFILE=default \
        --env "AWS_DEFAULT_REGION=${region}" \
        --env "SSL_CERT_FILE=${CA_BUNDLE}" \
        --entrypoint restic \
        "${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}" \
        -o "s3.region=${region}" -o s3.bucket-lookup=path -o s3.connections=2 \
        --no-cache --pack-size 16 backup --json --one-file-system \
        --host "$(machine_id)" --tag pi-run --tag scope=complete --tag "request=${request_id}" \
        --tag "purpose=${purpose}" \
        /input/config.json /input/profiles /input/skills /input/shared /input/workspaces \
        /input/snapshot-config.json /input/snapshot-manifest.json
}

verify_s3_created_snapshot() {
    local snapshot_id="$1" request_id="$2" purpose="$3" repository region metadata
    local root="${PI_RUN_HOME_RESOLVED}/snapshots"
    IFS=$'\t' read -r repository region < <(s3_snapshot_connection)
    metadata="$(run_s3_restic "${repository}" "${root}/secrets" "${root}/s3-credentials" "${region}" \
        --no-lock snapshots --json "${snapshot_id}")" \
        || fail "could not verify S3 snapshot ${snapshot_id} for request ${request_id}"
    jq -e --arg id "${snapshot_id}" --arg request "request=${request_id}" \
        --arg purpose "purpose=${purpose}" '
        type == "array" and length == 1 and .[0].id == $id and
        (.[0].tags | type == "array") and
        ([.[0].tags[] | select(. == "pi-run")] | length == 1) and
        ([.[0].tags[] | select(. == "scope=complete")] | length == 1) and
        ([.[0].tags[] | select(. == $request)] | length == 1) and
        ([.[0].tags[] | select(. == $purpose)] | length == 1)
    ' <<< "${metadata}" >/dev/null \
        || fail "S3 snapshot metadata does not match request ${request_id}"
}

SNAPSHOT_PENDING_MANIFEST=""
SNAPSHOT_PENDING_OUTPUT=""

cleanup_snapshot_create() {
    [[ -z "${SNAPSHOT_PENDING_MANIFEST}" ]] || rm -f -- "${SNAPSHOT_PENDING_MANIFEST}"
    [[ -z "${SNAPSHOT_PENDING_OUTPUT}" ]] || rm -f -- "${SNAPSHOT_PENDING_OUTPUT}"
}

create_complete_snapshot() {
    local purpose="${1:-manual}"
    local root="${PI_RUN_HOME_RESOLVED}/snapshots" request_id created_at pi_version image backend
    local manifest output snapshot_id metadata="${PI_RUN_HOME_RESOLVED}/snapshots/metadata"
    [[ "${purpose}" == manual || "${purpose}" == automatic || "${purpose}" == pre-restore ]] \
        || fail "invalid snapshot purpose: ${purpose}"
    acquire_snapshot_operation_lock exclusive
    snapshot_status >/dev/null
    backend="$(jq -r '.backend' "${root}/config.json")"
    validate_complete_snapshot_sources
    [[ -d "${metadata}" && ! -L "${metadata}" && "$(realpath "${metadata}")" == "${metadata}" ]] \
        || fail "snapshot metadata path must be a non-symlink directory: ${metadata}"
    [[ "$(stat -c %a "${metadata}")" == 700 ]] \
        || fail "snapshot metadata directory permissions must be 700: ${metadata}"
    request_id="$(new_workspace_id)"
    created_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    pi_version="$(query_snapshot_pi_version)"
    image="${PI_RUN_IMAGE:-${DEFAULT_IMAGE}}"
    manifest="${root}/metadata/${request_id}.json"
    output="${root}/metadata/.backup-output.tmp.$$"
    [[ ! -e "${manifest}" && ! -L "${manifest}" && ! -e "${output}" && ! -L "${output}" ]] \
        || fail "snapshot metadata path already exists"
    SNAPSHOT_PENDING_MANIFEST="${manifest}"
    SNAPSHOT_PENDING_OUTPUT="${output}"
    trap cleanup_snapshot_create EXIT
    jq -n \
        --arg requestId "${request_id}" \
        --arg createdAt "${created_at}" \
        --arg purpose "${purpose}" \
        --arg piRunVersion "${PI_RUN_VERSION}" \
        --arg runtimeImage "${image}" \
        --arg piVersion "${pi_version}" \
        '{
            schemaVersion: 1,
            requestId: $requestId,
            createdAt: $createdAt,
            scope: "complete",
            purpose: $purpose,
            piRunVersion: $piRunVersion,
            runtimeImage: $runtimeImage,
            piVersion: $piVersion,
            homeConfigurationSchemaVersion: 1,
            profileSchemaVersion: 1,
            workspaceRegistrySchemaVersion: 1,
            snapshotConfigurationSchemaVersion: 1,
            includedPaths: ["config.json", "profiles", "skills", "shared", "workspaces", "snapshots/config.json", "snapshots/metadata/\($requestId).json"],
            excludedPaths: ["machines", "snapshots/secrets", "snapshots/s3-credentials", "snapshots/repository", "snapshots/restore-staging", "other snapshots/metadata entries", "temporary locks", "workspace source trees"]
        }' > "${manifest}"
    chmod 0600 "${manifest}"

    if [[ "${backend}" == local ]]; then
        run_complete_snapshot_backup "${manifest}" "${request_id}" "${purpose}" > "${output}"
    elif ! run_complete_s3_snapshot_backup "${manifest}" "${request_id}" "${purpose}" > "${output}"; then
        fail "S3 snapshot backup failed for request ${request_id}; the remote outcome may be uncertain"
    fi
    snapshot_id="$(jq -ser '
        [.[] | select(.message_type == "summary" and
            (.snapshot_id | type == "string") and
            (.snapshot_id | test("^[0-9a-f]{64}$")))] |
        if length == 1 then .[0].snapshot_id else empty end
    ' "${output}")" || fail "Restic did not report exactly one valid snapshot ID for request ${request_id}"
    [[ -n "${snapshot_id}" ]] || fail "Restic did not report exactly one valid snapshot ID for request ${request_id}"
    if [[ "${backend}" == s3 ]]; then
        verify_s3_created_snapshot "${snapshot_id}" "${request_id}" "${purpose}"
    fi
    SNAPSHOT_PENDING_MANIFEST=""
    rm -f "${output}"
    SNAPSHOT_PENDING_OUTPUT=""
    trap - EXIT
    printf 'Snapshot created: %s\nManifest: %s\n' "${snapshot_id}" "${manifest}"
}

query_pi_run_snapshots() {
    local backend repository region root="${PI_RUN_HOME_RESOLVED}/snapshots"
    backend="$(jq -r '.backend' "${root}/config.json")"
    if [[ "${backend}" == local ]]; then
        run_snapshot_restic readonly /snapshots/repository /snapshots/secrets \
            --no-lock snapshots --json --tag pi-run
    else
        IFS=$'\t' read -r repository region < <(s3_snapshot_connection)
        run_s3_restic "${repository}" "${root}/secrets" "${root}/s3-credentials" "${region}" \
            --no-lock snapshots --json --tag pi-run
    fi
}

list_snapshots() {
    local snapshots rows
    acquire_snapshot_operation_lock shared
    snapshot_status >/dev/null
    snapshots="$(query_pi_run_snapshots)" || fail "could not list Pi-Run snapshots"
    jq -e '
        def tag_values($prefix):
            [.tags[] | select(startswith($prefix)) | ltrimstr($prefix)];
        type == "array" and all(.[];
            (.id | type == "string") and (.id | test("^[0-9a-f]{64}$")) and
            (.time | type == "string") and (.time | test("^[0-9T:.+-]+Z$")) and
            ((.hostname == null) or (.hostname == "pi-run") or
                ((.hostname | type == "string") and (.hostname | test("^[0-9a-f]{16}$")))) and
            (.tags | type == "array") and all(.tags[]; type == "string") and
            ([.tags[] | select(. == "pi-run")] | length == 1) and
            ((tag_values("scope=")) as $scope |
                ($scope | length == 1) and ($scope[0] | test("^[a-z][a-z0-9-]*$"))) and
            ((tag_values("request=")) as $request |
                ($request | length == 1) and
                ($request[0] | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))) and
            ((tag_values("purpose=")) as $purpose |
                ($purpose | length <= 1) and
                all($purpose[]; . == "manual" or . == "automatic" or . == "pre-restore"))
        )
    ' <<< "${snapshots}" >/dev/null || fail "Restic returned invalid snapshot metadata"
    [[ "$(jq 'length' <<< "${snapshots}")" != 0 ]] || {
        printf 'No Pi-Run snapshots.\n'
        return 0
    }
    rows="$(jq -r '
        def tag_value($prefix):
            [.tags[] | select(startswith($prefix)) | ltrimstr($prefix)][0];
        sort_by(.time) | reverse[] |
        (if (.hostname // "pi-run") | test("^[0-9a-f]{16}$") then .hostname else "-" end) as $machine |
        ([.tags[] | select(startswith("purpose=")) | ltrimstr("purpose=")][0] // "-") as $purpose |
        [.id[0:12], .time, $machine, tag_value("scope="), $purpose] | @tsv
    ' <<< "${snapshots}")"
    printf '%-12s  %-30s  %-16s  %-8s  %s\n' ID CREATED MACHINE SCOPE PURPOSE
    while IFS=$'\t' read -r snapshot_id created machine scope purpose; do
        printf '%-12s  %-30s  %-16s  %-8s  %s\n' \
            "${snapshot_id}" "${created}" "${machine}" "${scope}" "${purpose}"
    done <<< "${rows}"
}

check_snapshot_repository() {
    local result repository region backend suggest_prune root="${PI_RUN_HOME_RESOLVED}/snapshots"
    acquire_snapshot_operation_lock exclusive
    snapshot_status >/dev/null
    backend="$(jq -r '.backend' "${root}/config.json")"
    if [[ "${backend}" == local ]]; then
        repository="${root}/repository"
        result="$(run_snapshot_restic readonly /snapshots/repository /snapshots/secrets \
            --no-lock check --read-data --json)" \
            || fail "Restic repository integrity check failed"
    else
        IFS=$'\t' read -r repository region < <(s3_snapshot_connection)
        result="$(run_s3_restic "${repository}" "${root}/secrets" "${root}/s3-credentials" "${region}" \
            --no-lock check --read-data --json)" \
            || fail "Restic repository integrity check failed"
    fi
    jq -se '
        (length == 1) and (.[0].message_type == "summary") and
        (.[0].num_errors | type == "number") and
        ((.[0].broken_packs == null) or
            ((.[0].broken_packs | type == "array") and all(.[0].broken_packs[]; type == "string"))) and
        (.[0].suggest_repair_index | type == "boolean") and
        (.[0].suggest_prune | type == "boolean")
    ' <<< "${result}" >/dev/null \
        || fail "Restic returned an invalid integrity summary"
    jq -se '
        (.[0].num_errors == 0) and
        ((.[0].broken_packs == null) or (.[0].broken_packs | length == 0)) and
        (.[0].suggest_repair_index == false)
    ' <<< "${result}" >/dev/null \
        || fail "Restic reported repository integrity errors"
    suggest_prune="$(jq -sr '.[0].suggest_prune' <<< "${result}")"
    printf 'Snapshot check: OK\nRepository: %s\nData verification: complete\n' "${repository}"
    if [[ "${suggest_prune}" == true ]]; then
        printf '%s\n' 'Advisory: Restic found unused repository data, which can follow an interrupted backup.'
        printf '%s\n' 'Snapshot check does not delete or prune repository data.'
    fi
}

SNAPSHOT_SHOW_TMP=""

cleanup_snapshot_show() {
    [[ -z "${SNAPSHOT_SHOW_TMP}" ]] || rm -f -- "${SNAPSHOT_SHOW_TMP}"
}

query_snapshot_by_reference() {
    local reference="$1" backend repository region root="${PI_RUN_HOME_RESOLVED}/snapshots"
    backend="$(jq -r '.backend' "${root}/config.json")"
    if [[ "${backend}" == local ]]; then
        run_snapshot_restic readonly /snapshots/repository /snapshots/secrets \
            --no-lock snapshots --json "${reference}"
    else
        IFS=$'\t' read -r repository region < <(s3_snapshot_connection)
        run_s3_restic "${repository}" "${root}/secrets" "${root}/s3-credentials" "${region}" \
            --no-lock snapshots --json "${reference}"
    fi
}

dump_snapshot_manifest() {
    local snapshot_id="$1" backend repository region root="${PI_RUN_HOME_RESOLVED}/snapshots"
    backend="$(jq -r '.backend' "${root}/config.json")"
    if [[ "${backend}" == local ]]; then
        run_snapshot_restic readonly /snapshots/repository /snapshots/secrets \
            --no-lock dump "${snapshot_id}" /input/snapshot-manifest.json
    else
        IFS=$'\t' read -r repository region < <(s3_snapshot_connection)
        run_s3_restic "${repository}" "${root}/secrets" "${root}/s3-credentials" "${region}" \
            --no-lock dump "${snapshot_id}" /input/snapshot-manifest.json
    fi
}

resolve_pi_run_snapshot_reference() {
    local reference="$1" metadata resolved snapshot_id created machine scope request_id
    [[ "${reference}" =~ ^([0-9a-f]{12}|[0-9a-f]{64})$ ]] \
        || fail "snapshot ID must be a 12 or 64 character lowercase hexadecimal ID"
    snapshot_status >/dev/null
    metadata="$(query_snapshot_by_reference "${reference}")" \
        || fail "could not resolve Pi-Run snapshot: ${reference}"
    jq -e '
        type == "array" and length == 1 and
        (.[0].id | type == "string") and (.[0].id | test("^[0-9a-f]{64}$")) and
        (.[0].time | type == "string") and (.[0].time | test("^[0-9T:.+-]+Z$")) and
        ((.[0].hostname == null) or (.[0].hostname == "pi-run") or
            ((.[0].hostname | type == "string") and (.[0].hostname | test("^[0-9a-f]{16}$")))) and
        (.[0].tags | type == "array") and all(.[0].tags[]; type == "string") and
        ([.[0].tags[] | select(. == "pi-run")] | length == 1) and
        ([.[0].tags[] | select(startswith("scope="))] | length == 1) and
        ([.[0].tags[] | select(startswith("request="))] | length == 1) and
        ([.[0].tags[] | select(startswith("purpose="))] | length <= 1) and
        all(.[0].tags[] | select(startswith("purpose="));
            . == "purpose=manual" or . == "purpose=automatic" or . == "purpose=pre-restore")
    ' <<< "${metadata}" >/dev/null \
        || fail "snapshot ID is unknown, ambiguous, or not a Pi-Run snapshot: ${reference}"
    resolved="$(jq -r '
        def tag_value($prefix):
            [.tags[] | select(startswith($prefix)) | ltrimstr($prefix)][0];
        .[0] |
        (if (.hostname // "pi-run") | test("^[0-9a-f]{16}$") then .hostname else "-" end) as $machine |
        [.id, .time, $machine, tag_value("scope="), tag_value("request=")] | @tsv
    ' <<< "${metadata}")"
    IFS=$'\t' read -r snapshot_id created machine scope request_id <<< "${resolved}"
    [[ "${snapshot_id}" == "${reference}"* && "${scope}" =~ ^[a-z][a-z0-9-]*$ &&
       "${request_id}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
        || fail "snapshot metadata does not match the requested Pi-Run snapshot"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${snapshot_id}" "${created}" "${machine}" "${scope}" "${request_id}"
}

load_validated_snapshot_manifest() {
    local snapshot_id="$1" request_id="$2" scope="$3" manifest_size
    SNAPSHOT_SHOW_TMP="$(mktemp)"
    trap cleanup_snapshot_show EXIT
    dump_snapshot_manifest "${snapshot_id}" > "${SNAPSHOT_SHOW_TMP}" \
        || fail "could not read the embedded snapshot manifest"
    manifest_size="$(stat -c %s "${SNAPSHOT_SHOW_TMP}")"
    (( manifest_size <= 262144 )) || fail "embedded snapshot manifest is too large"
    jq -e --arg request "${request_id}" --arg scope "${scope}" '
        .schemaVersion == 1 and .requestId == $request and .scope == $scope and
        ((.purpose == null) or (.purpose == "manual") or (.purpose == "automatic") or (.purpose == "pre-restore")) and
        (.createdAt | type == "string") and (.createdAt | test("^[0-9T:+.-]+Z$")) and
        (.piRunVersion | type == "string") and (.piRunVersion | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
        (.piVersion | type == "string") and (.piVersion | test("^[0-9]+\\.[0-9]+\\.[0-9]+([+-][A-Za-z0-9._-]+)?$")) and
        (.runtimeImage | type == "string") and (.runtimeImage | test("^[A-Za-z0-9][A-Za-z0-9._/:@+-]*$")) and
        .homeConfigurationSchemaVersion == 1 and .profileSchemaVersion == 1 and
        .workspaceRegistrySchemaVersion == 1 and .snapshotConfigurationSchemaVersion == 1 and
        (.includedPaths | type == "array") and all(.includedPaths[];
            (type == "string") and test("^[\\x20-\\x7e]+$")) and
        (.excludedPaths | type == "array") and all(.excludedPaths[];
            (type == "string") and test("^[\\x20-\\x7e]+$")) and
        (.includedPaths | index("profiles")) and
        (.excludedPaths | index("snapshots/secrets")) and
        (.excludedPaths | index("snapshots/repository"))
    ' "${SNAPSHOT_SHOW_TMP}" >/dev/null || fail "embedded snapshot manifest is invalid or mismatched"
}

cleanup_loaded_snapshot_manifest() {
    rm -f "${SNAPSHOT_SHOW_TMP}"
    SNAPSHOT_SHOW_TMP=""
    trap - EXIT
}

show_snapshot() {
    local reference="$1" resolved snapshot_id created scope request_id purpose
    acquire_snapshot_operation_lock shared
    resolved="$(resolve_pi_run_snapshot_reference "${reference}")"
    IFS=$'\t' read -r snapshot_id created _ scope request_id <<< "${resolved}"
    load_validated_snapshot_manifest "${snapshot_id}" "${request_id}" "${scope}"
    purpose="$(jq -r '.purpose // "-"' "${SNAPSHOT_SHOW_TMP}")"

    printf 'Snapshot: %s\nCreated: %s\nScope: %s\nPurpose: %s\nRequest: %s\n' \
        "${snapshot_id}" "${created}" "${scope}" "${purpose}" "${request_id}"
    jq -r '
        "Pi-Run: \(.piRunVersion)",
        "Pi: \(.piVersion)",
        "Runtime image: \(.runtimeImage)",
        "Schemas: home=\(.homeConfigurationSchemaVersion) profile=\(.profileSchemaVersion) workspace=\(.workspaceRegistrySchemaVersion) snapshot=\(.snapshotConfigurationSchemaVersion)",
        "Included:", (.includedPaths[] | "  - \(.)"),
        "Excluded:", (.excludedPaths[] | "  - \(.)")
    ' "${SNAPSHOT_SHOW_TMP}"
    cleanup_loaded_snapshot_manifest
}

confirm_snapshot_delete() {
    local snapshot_id="$1" response
    [[ -r /dev/tty && -w /dev/tty ]] \
        || fail "snapshot deletion requires confirmation from an interactive terminal"
    cat > /dev/tty <<EOF
This permanently deletes the snapshot and prunes all repository data that is
not referenced by any remaining snapshot. Pruning may use substantial storage,
bandwidth, and provider operations. It cannot be undone by Pi-Run.
Type the complete snapshot ID to continue: ${snapshot_id}
EOF
    printf '> ' > /dev/tty
    IFS= read -r response < /dev/tty || response=""
    [[ "${response}" == "${snapshot_id}" ]]
}

run_snapshot_delete_prune() {
    local snapshot_id="$1" backend repository region root="${PI_RUN_HOME_RESOLVED}/snapshots"
    backend="$(jq -r '.backend' "${root}/config.json")"
    if [[ "${backend}" == local ]]; then
        run_snapshot_restic readwrite /snapshots/repository /snapshots/secrets \
            --no-cache forget "${snapshot_id}" --prune
    else
        IFS=$'\t' read -r repository region < <(s3_snapshot_connection)
        run_s3_restic "${repository}" "${root}/secrets" "${root}/s3-credentials" "${region}" \
            -o s3.connections=2 --no-cache forget "${snapshot_id}" --prune
    fi
}

verify_snapshot_delete_prune() {
    local snapshot_id="$1" remaining result backend repository region
    local root="${PI_RUN_HOME_RESOLVED}/snapshots"
    remaining="$(query_pi_run_snapshots)" \
        || fail "snapshot was deleted and pruned, but its absence could not be verified"
    jq -e --arg id "${snapshot_id}" '
        type == "array" and all(.[];
            (.id | type == "string") and (.id | test("^[0-9a-f]{64}$")) and .id != $id and
            (.tags | type == "array") and
            ([.tags[] | select(. == "pi-run")] | length == 1))
    ' <<< "${remaining}" >/dev/null \
        || fail "snapshot deletion verification returned invalid or conflicting metadata"

    backend="$(jq -r '.backend' "${root}/config.json")"
    if [[ "${backend}" == local ]]; then
        repository="${root}/repository"
        result="$(run_snapshot_restic readonly /snapshots/repository /snapshots/secrets \
            --no-cache check --json)" \
            || fail "snapshot was deleted and pruned, but structural repository verification failed"
    else
        IFS=$'\t' read -r repository region < <(s3_snapshot_connection)
        result="$(run_s3_restic "${repository}" "${root}/secrets" "${root}/s3-credentials" "${region}" \
            --no-cache check --json)" \
            || fail "snapshot was deleted and pruned, but structural repository verification failed"
    fi
    jq -se '
        (length == 1) and (.[0].message_type == "summary") and
        (.[0].num_errors == 0) and
        ((.[0].broken_packs == null) or
            ((.[0].broken_packs | type == "array") and (.[0].broken_packs | length == 0))) and
        (.[0].suggest_repair_index == false) and
        (.[0].suggest_prune | type == "boolean")
    ' <<< "${result}" >/dev/null \
        || fail "snapshot was deleted and pruned, but Restic reported structural integrity errors"
    printf 'Repository structural check: OK\nRepository: %s\n' "${repository}"
}

delete_snapshot() {
    local reference="$1" resolved snapshot_id created machine scope request_id
    [[ "${HOME_LOCK_ACQUIRED}" == true ]] \
        || fail "snapshot deletion requires a Pi-Run home lifecycle lock"
    acquire_snapshot_operation_lock exclusive
    resolved="$(resolve_pi_run_snapshot_reference "${reference}")"
    IFS=$'\t' read -r snapshot_id created machine scope request_id <<< "${resolved}"
    load_validated_snapshot_manifest "${snapshot_id}" "${request_id}" "${scope}"
    cleanup_loaded_snapshot_manifest
    printf 'Snapshot to delete: %s\nCreated: %s\nMachine: %s\nScope: %s\n' \
        "${snapshot_id}" "${created}" "${machine}" "${scope}"
    if ! confirm_snapshot_delete "${snapshot_id}"; then
        printf 'Snapshot deletion cancelled.\n'
        return 0
    fi
    if ! run_snapshot_delete_prune "${snapshot_id}"; then
        fail "snapshot deletion and prune failed; the outcome may be partial or uncertain; do not retry automatically"
    fi
    verify_snapshot_delete_prune "${snapshot_id}"
    printf 'Snapshot deleted and repository pruned: %s\n' "${snapshot_id}"
}

run_snapshot_diff() {
    local baseline="$1" latest="$2" backend repository region root="${PI_RUN_HOME_RESOLVED}/snapshots"
    backend="$(jq -r '.backend' "${root}/config.json")"
    if [[ "${backend}" == local ]]; then
        run_snapshot_restic readonly /snapshots/repository /snapshots/secrets \
            --no-lock diff --json --metadata "${baseline}" "${latest}"
    else
        IFS=$'\t' read -r repository region < <(s3_snapshot_connection)
        run_s3_restic "${repository}" "${root}/secrets" "${root}/s3-credentials" "${region}" \
            --no-lock diff --json --metadata "${baseline}" "${latest}"
    fi
}

diff_snapshots() {
    local reference="$1" metadata resolved baseline latest result changes statistics
    acquire_snapshot_operation_lock shared
    [[ "${reference}" =~ ^([0-9a-f]{12}|[0-9a-f]{64})$ ]] \
        || fail "snapshot ID must be a 12 or 64 character lowercase hexadecimal ID"
    snapshot_status >/dev/null
    metadata="$(query_pi_run_snapshots)" \
        || fail "could not list Pi-Run snapshots"
    jq -e '
        def tag_values($prefix):
            [.tags[] | select(startswith($prefix)) | ltrimstr($prefix)];
        type == "array" and length > 0 and all(.[];
            (.id | type == "string") and (.id | test("^[0-9a-f]{64}$")) and
            (.time | type == "string") and (.time | test("^[0-9T:.+-]+Z$")) and
            (.tags | type == "array") and all(.tags[]; type == "string") and
            ([.tags[] | select(. == "pi-run")] | length == 1) and
            ((tag_values("scope=")) | length == 1) and
            ((tag_values("request=")) | length == 1) and
            ((tag_values("purpose=")) as $purpose |
                ($purpose | length <= 1) and
                all($purpose[]; . == "manual" or . == "automatic" or . == "pre-restore"))
        )
    ' <<< "${metadata}" >/dev/null || fail "Restic returned invalid Pi-Run snapshot metadata"
    resolved="$(jq -r --arg reference "${reference}" '
        [.[] | select(.id | startswith($reference))] as $matches |
        if ($matches | length) == 1 then
            [$matches[0].id, (sort_by(.time, .id) | last | .id)] | @tsv
        else empty end
    ' <<< "${metadata}")"
    [[ -n "${resolved}" ]] || fail "snapshot ID is unknown or ambiguous: ${reference}"
    IFS=$'\t' read -r baseline latest <<< "${resolved}"
    if [[ "${baseline}" == "${latest}" ]]; then
        printf 'Baseline: %s\nLatest: %s\nNo differences: selected snapshot is already latest.\n' \
            "${baseline}" "${latest}"
        return 0
    fi

    result="$(run_snapshot_diff "${baseline}" "${latest}")" \
        || fail "could not compare Pi-Run snapshots"
    jq -se --arg baseline "${baseline}" --arg latest "${latest}" '
        def count_fields_valid:
            type == "object" and
            all([.files, .dirs, .others, .data_blobs, .tree_blobs, .bytes][];
                (type == "number") and . >= 0);
        ([.[] | select(.message_type == "statistics")] | length == 1) and
        all(.[];
            if .message_type == "change" then
                (.path | type == "string") and (.path | startswith("/input")) and
                (.path | explode | all(. >= 32 and . != 127)) and
                (.modifier | type == "string") and (.modifier | test("^[A-Z+-]+$"))
            elif .message_type == "statistics" then
                .source_snapshot == $baseline and .target_snapshot == $latest and
                (.changed_files | type == "number") and .changed_files >= 0 and
                (.added | count_fields_valid) and (.removed | count_fields_valid)
            else false end)
    ' <<< "${result}" >/dev/null || fail "Restic returned invalid or mismatched diff output"
    changes="$(jq -sr '
        .[] | select(.message_type == "change") | [.modifier, .path] | @tsv
    ' <<< "${result}")"
    statistics="$(jq -sr '
        .[] | select(.message_type == "statistics") |
        "Changed files: \(.changed_files)\nAdded: \(.added.files) files, \(.added.dirs) dirs, \(.added.bytes) bytes\nRemoved: \(.removed.files) files, \(.removed.dirs) dirs, \(.removed.bytes) bytes"
    ' <<< "${result}")"
    printf 'Baseline: %s\nLatest: %s\nChanges:\n' "${baseline}" "${latest}"
    if [[ -z "${changes}" ]]; then
        printf '  none\n'
    else
        while IFS=$'\t' read -r modifier path; do
            printf '  %-4s %s\n' "${modifier}" "${path}"
        done <<< "${changes}"
    fi
    printf '%s\n' "${statistics}"
}

