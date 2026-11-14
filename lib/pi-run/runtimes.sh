# SPDX-License-Identifier: MIT
# shellcheck shell=bash

RUNTIME_CONTEXT_MAX_ENTRIES=4096
RUNTIME_CONTEXT_MAX_BYTES=536870912
RUNTIME_BUILD_CONTRACT=1
RUNTIME_LABEL_CONTRACT=io.aprilsoftware.pi-run.runtime.contract
RUNTIME_LABEL_CORE_ID=io.aprilsoftware.pi-run.runtime.core-id
RUNTIME_LABEL_CONTEXT=io.aprilsoftware.pi-run.runtime.context-sha256
RUNTIME_LABEL_SOURCE=io.aprilsoftware.pi-run.runtime.source-sha256
RUNTIME_LABEL_ARCHITECTURE=io.aprilsoftware.pi-run.runtime.architecture

runtime_catalog_entries() {
    printf '%s\t%s\t%s\t%s\n' \
        group all 'utility-belt,network-diagnostics,python-development,operations,native-development,java-development,rust-development,headless-gui,flutter-development,database-clients,kubernetes' 'Every maintained optional runtime capability' \
        bundle database-clients - 'PostgreSQL, Redis, MySQL, and SQLite clients' \
        bundle flutter-development - 'Flutter and Dart development SDKs' \
        bundle headless-gui - 'Headless Linux GUI, graphics, audio, and XKB support' \
        bundle java-development - 'OpenJDK and Maven development tools' \
        bundle kubernetes - 'kubectl, Helm, Kustomize, and yq' \
        bundle native-development - 'C, C++, Clang, CMake, Ninja, and debugger tools' \
        bundle network-diagnostics - 'DNS, routing, connectivity, and tracing tools' \
        bundle operations - 'Ansible and operations tooling' \
        bundle python-development - 'Python, headers, pip, venv, and pipx' \
        bundle rust-development - 'Rustup, Cargo, Rustfmt, and Clippy' \
        bundle utility-belt - 'Shell, archive, XML, inspection, and utility tools'
}

list_runtime_catalog() {
    local type name members description extra member
    local name_width=4 type_width=4 bundle_count=0 all_member_count=-1
    local -a rows=() groups=() group_members=()
    local -A known_types=() seen_members=()

    while IFS=$'\t' read -r type name members description extra; do
        [[ -n "${type}" && -n "${name}" && -n "${members}" && -n "${description}" && -z "${extra}" ]] \
            || fail "installed runtime catalog is invalid"
        case "${type}" in
            bundle)
                [[ "${members}" == - ]] || fail "installed runtime catalog is invalid"
                (( bundle_count += 1 ))
                ;;
            group)
                [[ "${members}" != - ]] || fail "installed runtime catalog is invalid"
                groups+=("${name}"$'\t'"${members}")
                ;;
            *) fail "installed runtime catalog is invalid" ;;
        esac
        [[ "${name}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] \
            || fail "installed runtime catalog is invalid"
        [[ -z "${known_types[${name}]:-}" ]] \
            || fail "installed runtime catalog is invalid"
        known_types["${name}"]="${type}"
        rows+=("${name}"$'\t'"${type}"$'\t'"${description}")
        (( ${#name} > name_width )) && name_width=${#name}
        (( ${#type} > type_width )) && type_width=${#type}
    done < <(runtime_catalog_entries)

    (( ${#rows[@]} > 0 )) || fail "installed runtime catalog is empty"
    for members in "${groups[@]}"; do
        IFS=$'\t' read -r name members <<<"${members}"
        IFS=, read -r -a group_members <<<"${members}"
        (( ${#group_members[@]} > 0 )) || fail "installed runtime catalog is invalid"
        seen_members=()
        for member in "${group_members[@]}"; do
            [[ "${member}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] \
                || fail "installed runtime catalog is invalid"
            [[ "${known_types[${member}]:-}" == bundle && -z "${seen_members[${member}]:-}" ]] \
                || fail "installed runtime catalog is invalid"
            seen_members["${member}"]=1
        done
        [[ "${name}" != all ]] || all_member_count=${#group_members[@]}
    done
    [[ "${known_types[all]:-}" == group && ${all_member_count} -eq ${bundle_count} ]] \
        || fail "installed runtime catalog is invalid"

    printf '%-*s  %-*s  %s\n' "${name_width}" NAME "${type_width}" TYPE DESCRIPTION
    for member in "${rows[@]}"; do
        IFS=$'\t' read -r name type description <<<"${member}"
        printf '%-*s  %-*s  %s\n' "${name_width}" "${name}" "${type_width}" "${type}" "${description}"
    done
}

runtime_all_bundle_names() {
    local type name members description
    while IFS=$'\t' read -r type name members description; do
        if [[ "${type}" == group && "${name}" == all ]]; then
            tr ',' '\n' <<<"${members}"
            return 0
        fi
    done < <(runtime_catalog_entries)
    return 1
}

runtime_bundle_exists() {
    local requested="$1" type name members description
    while IFS=$'\t' read -r type name members description; do
        [[ "${type}" == bundle && "${name}" == "${requested}" ]] && return 0
    done < <(runtime_catalog_entries)
    return 1
}

validate_runtime_bundle_template() {
    local base="${RUNTIME_TEMPLATE_ROOT}/Dockerfile"
    local full="${RUNTIME_TEMPLATE_ROOT}/full-development.Dockerfile"
    local base_size expected begins ends known_csv
    base_size="$(stat -c %s "${base}")" || return 1
    (( $(stat -c %s "${full}") > base_size )) || return 1
    cmp -n "${base_size}" "${base}" "${full}" >/dev/null || return 1
    expected="$(runtime_all_bundle_names)" || return 1
    begins="$(sed -n 's/^# BEGIN PI-RUN BUNDLE //p' "${full}")"
    ends="$(sed -n 's/^# END PI-RUN BUNDLE //p' "${full}")"
    [[ -n "${expected}" && "${begins}" == "${expected}" && "${ends}" == "${expected}" ]] \
        || return 1
    known_csv="$(paste -sd, <<<"${expected}")"
    awk -v known_csv="${known_csv}" '
        BEGIN {
            count = split(known_csv, names, ",")
            for (i = 1; i <= count; i++) known[names[i]] = 1
        }
        /^# BEGIN PI-RUN BUNDLE / {
            name = substr($0, 23)
            if (!(name in known) || inside != "" || seen[name]++) exit 1
            inside = name
            instructions = 0
            next
        }
        /^# END PI-RUN BUNDLE / {
            name = substr($0, 21)
            if (inside != name || instructions == 0) exit 1
            inside = ""
            next
        }
        inside != "" && /^(ARG|COPY|ENV|RUN|USER) / { instructions = 1 }
        END { if (inside != "") exit 1 }
    ' "${full}"
}

validate_runtime_templates() {
    local template_root="${RUNTIME_TEMPLATE_ROOT}"
    local name path
    [[ -d "${template_root}" && ! -L "${template_root}" ]] \
        || fail "installed runtime templates are missing or unsafe: ${template_root}"
    [[ "$(realpath "${template_root}")" == "${template_root}" ]] \
        || fail "installed runtime templates escape the installation: ${template_root}"
    for name in Dockerfile .dockerignore; do
        path="${template_root}/${name}"
        [[ -f "${path}" && ! -L "${path}" && "$(stat -c %h "${path}")" == 1 ]] \
            || fail "installed runtime template is missing or unsafe: ${path}"
        [[ "$(realpath "${path}")" == "${path}" ]] \
            || fail "installed runtime template escapes the installation: ${path}"
    done
}

validate_runtime_bundle_templates() {
    local full="${RUNTIME_TEMPLATE_ROOT}/full-development.Dockerfile"
    validate_runtime_templates
    [[ -f "${full}" && ! -L "${full}" && "$(stat -c %h "${full}")" == 1 ]] \
        || fail "installed full-development runtime template is missing or unsafe: ${full}"
    [[ "$(realpath "${full}")" == "${full}" ]] \
        || fail "installed full-development runtime template escapes the installation: ${full}"
    validate_runtime_bundle_template \
        || fail "installed full-development runtime template is invalid"
}

validate_profile_runtime_context() {
    local runtime_dir="$1"
    local inventory type path link_count entry_count=0 byte_count=0 file_size valid=true
    [[ -d "${runtime_dir}" && ! -L "${runtime_dir}" ]] || return 1
    [[ "$(realpath "${runtime_dir}")" == "${runtime_dir}" ]] || return 1
    for path in "${runtime_dir}/Dockerfile" "${runtime_dir}/.dockerignore"; do
        [[ -f "${path}" && ! -L "${path}" && "$(stat -c %h "${path}")" == 1 ]] \
            || return 1
        [[ "$(realpath "${path}")" == "${path}" ]] || return 1
    done

    inventory="$(mktemp "${TMPDIR:-/tmp}/pi-run-runtime-context.XXXXXX")" || return 1
    if ! find -P "${runtime_dir}" -mindepth 1 -printf '%y\0%p\0' > "${inventory}"; then
        rm -f "${inventory}"
        return 1
    fi
    while IFS= read -r -d '' type && IFS= read -r -d '' path; do
        (( entry_count += 1 ))
        if (( entry_count > RUNTIME_CONTEXT_MAX_ENTRIES )); then
            valid=false
            break
        fi
        case "${type}" in
            d|l) ;;
            f)
                link_count="$(stat -c %h "${path}")" || {
                    valid=false
                    break
                }
                [[ "${link_count}" == 1 ]] || {
                    valid=false
                    break
                }
                file_size="$(stat -c %s "${path}")" || {
                    valid=false
                    break
                }
                if (( file_size > RUNTIME_CONTEXT_MAX_BYTES - byte_count )); then
                    valid=false
                    break
                fi
                (( byte_count += file_size ))
                ;;
            *)
                valid=false
                break
                ;;
        esac
    done < "${inventory}"
    rm -f "${inventory}"
    [[ "${valid}" == true ]] || return 1
    RUNTIME_CONTEXT_BYTE_COUNT=${byte_count}
}

runtime_architecture() {
    local machine
    machine="$(uname -m)"
    case "${machine}" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) printf '%s\n' "${machine}" ;;
    esac
}

runtime_context_hash_stream() {
    local runtime_dir="$1" inventory="$2" path mode size
    cd "${runtime_dir}" || return 1
    printf 'pi-run-runtime-context-v1\0'
    while IFS= read -r -d '' path; do
        mode="$(stat -c %a -- "./${path}")" || return 1
        if [[ -L "./${path}" ]]; then
            printf 'l\0%s\0%s\0' "${path}" "${mode}"
            readlink -z -- "./${path}" || return 1
        elif [[ -d "./${path}" ]]; then
            printf 'd\0%s\0%s\0' "${path}" "${mode}"
        elif [[ -f "./${path}" ]]; then
            size="$(stat -c %s -- "./${path}")" || return 1
            printf 'f\0%s\0%s\0%s\0' "${path}" "${mode}" "${size}"
            cat -- "./${path}" || return 1
            printf '\0'
        else
            return 1
        fi
    done < "${inventory}"
}

runtime_context_sha256_once() {
    local runtime_dir="$1" inventory result
    inventory="$(mktemp "${TMPDIR:-/tmp}/pi-run-runtime-hash.XXXXXX")" || return 1
    if ! find -P "${runtime_dir}" -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z > "${inventory}"; then
        rm -f "${inventory}"
        return 1
    fi
    if ! result="$(runtime_context_hash_stream "${runtime_dir}" "${inventory}" | sha256sum)"; then
        rm -f "${inventory}"
        return 1
    fi
    rm -f "${inventory}"
    result="${result%% *}"
    [[ "${result}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "${result}"
}

stable_runtime_context_sha256() {
    local runtime_dir="$1" first second
    validate_profile_runtime_context "${runtime_dir}" || return 1
    first="$(runtime_context_sha256_once "${runtime_dir}")" || return 1
    validate_profile_runtime_context "${runtime_dir}" || return 1
    second="$(runtime_context_sha256_once "${runtime_dir}")" || return 1
    [[ "${first}" == "${second}" ]] || return 1
    printf '%s\n' "${first}"
}

runtime_source_sha256() {
    local context_sha="$1" core_id="$2" architecture="$3" result
    result="$(printf 'pi-run-runtime-source-v1\0%s\0%s\0%s\0%s\0' \
        "${RUNTIME_BUILD_CONTRACT}" "${architecture}" "${core_id}" "${context_sha}" | sha256sum)"
    result="${result%% *}"
    [[ "${result}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "${result}"
}

runtime_profile_image_tag() {
    local profile_identity="$1" profile_sha
    profile_sha="$(printf '%s' "${profile_identity}" | sha256sum)"
    profile_sha="${profile_sha%% *}"
    printf 'pi-run-profile:%s\n' "${profile_sha:0:24}"
}

show_profile_runtime_status() {
    local profile_dir runtime_dir dockerfile context_sha architecture core_ref prepared_tag
    local core_json core_id core_arch source_sha prepared_json prepared_id prepared_arch
    local label_contract label_core label_context label_source label_arch profile_lock_fd

    profile_dir="$(resolve_profile_directory)"
    exec {profile_lock_fd}<"${profile_dir}" \
        || fail "could not open profile directory for locking: ${profile_dir}"
    flock -s "${profile_lock_fd}" \
        || fail "could not lock profile directory: ${profile_dir}"
    validate_profile_config "${profile_dir}" "${PROFILE}"
    validate_profile_definition_files "${profile_dir}"
    runtime_dir="${profile_dir}/runtime"
    context_sha="$(stable_runtime_context_sha256 "${runtime_dir}")" \
        || fail "profile runtime context changed during inspection or is invalid: ${runtime_dir}"
    dockerfile="${runtime_dir}/Dockerfile"
    architecture="$(runtime_architecture)"
    core_ref="${PI_RUN_CORE_IMAGE:-${DEFAULT_CORE_IMAGE}}"
    [[ -n "${core_ref}" ]] || fail "core runtime image reference must not be empty"
    prepared_tag="$(runtime_profile_image_tag "${profile_dir}")"

    printf 'Profile: %s\n' "${PROFILE}"
    printf 'Runtime Dockerfile: %s\n' "${dockerfile}"
    printf 'Context SHA-256: %s\n' "${context_sha}"
    printf 'Build contract: %s\n' "${RUNTIME_BUILD_CONTRACT}"
    printf 'Architecture: %s\n' "${architecture}"
    printf 'Core image: %s\n' "${core_ref}"
    printf 'Prepared tag: %s\n' "${prepared_tag}"

    if ! command -v docker >/dev/null 2>&1; then
        printf 'Core state: unavailable (Docker command not found)\n'
        printf 'Source identity: unavailable\n'
        printf 'Prepared state: unavailable\n'
        exec {profile_lock_fd}>&-
        return 0
    fi
    if ! docker info >/dev/null 2>&1; then
        printf 'Core state: unavailable (Docker daemon unavailable)\n'
        printf 'Source identity: unavailable\n'
        printf 'Prepared state: unavailable\n'
        exec {profile_lock_fd}>&-
        return 0
    fi
    if ! core_json="$(docker image inspect "${core_ref}" 2>/dev/null)"; then
        printf 'Core state: missing\n'
        printf 'Source identity: unavailable\n'
        printf 'Prepared state: unavailable\n'
        exec {profile_lock_fd}>&-
        return 0
    fi
    core_id="$(jq -er '.[0].Id | select(type == "string")' <<<"${core_json}")" \
        || fail "Docker returned an invalid core image identity: ${core_ref}"
    core_arch="$(jq -er '.[0].Architecture | select(type == "string")' <<<"${core_json}")" \
        || fail "Docker returned an invalid core image architecture: ${core_ref}"
    [[ "${core_id}" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || fail "Docker returned an invalid core image identity: ${core_ref}"
    if [[ "${core_arch}" != "${architecture}" ]]; then
        printf 'Core state: incompatible architecture (%s)\n' "${core_arch}"
        printf 'Core identity: %s\n' "${core_id}"
        printf 'Source identity: unavailable\n'
        printf 'Prepared state: unavailable\n'
        exec {profile_lock_fd}>&-
        return 0
    fi

    source_sha="$(runtime_source_sha256 "${context_sha}" "${core_id}" "${architecture}")" \
        || fail "could not calculate runtime source identity"
    printf 'Core state: ready\n'
    printf 'Core identity: %s\n' "${core_id}"
    printf 'Source identity: %s\n' "${source_sha}"
    if ! prepared_json="$(docker image inspect "${prepared_tag}" 2>/dev/null)"; then
        printf 'Prepared state: missing\n'
        exec {profile_lock_fd}>&-
        return 0
    fi
    prepared_id="$(jq -er '.[0].Id | select(type == "string")' <<<"${prepared_json}")" \
        || fail "Docker returned an invalid prepared image identity: ${prepared_tag}"
    prepared_arch="$(jq -er '.[0].Architecture | select(type == "string")' <<<"${prepared_json}")" \
        || fail "Docker returned an invalid prepared image architecture: ${prepared_tag}"
    [[ "${prepared_id}" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || fail "Docker returned an invalid prepared image identity: ${prepared_tag}"
    label_contract="$(jq -r --arg key "${RUNTIME_LABEL_CONTRACT}" '.[0].Config.Labels[$key] // ""' \
        <<<"${prepared_json}")"
    label_core="$(jq -r --arg key "${RUNTIME_LABEL_CORE_ID}" '.[0].Config.Labels[$key] // ""' \
        <<<"${prepared_json}")"
    label_context="$(jq -r --arg key "${RUNTIME_LABEL_CONTEXT}" '.[0].Config.Labels[$key] // ""' \
        <<<"${prepared_json}")"
    label_source="$(jq -r --arg key "${RUNTIME_LABEL_SOURCE}" '.[0].Config.Labels[$key] // ""' \
        <<<"${prepared_json}")"
    label_arch="$(jq -r --arg key "${RUNTIME_LABEL_ARCHITECTURE}" '.[0].Config.Labels[$key] // ""' \
        <<<"${prepared_json}")"
    printf 'Prepared identity: %s\n' "${prepared_id}"
    if [[ "${prepared_arch}" == "${architecture}" &&
       "${label_contract}" == "${RUNTIME_BUILD_CONTRACT}" &&
       "${label_core}" == "${core_id}" &&
       "${label_context}" == "${context_sha}" &&
       "${label_source}" == "${source_sha}" &&
       "${label_arch}" == "${architecture}" ]]; then
        printf 'Prepared state: matching\n'
    else
        printf 'Prepared state: stale\n'
    fi
    exec {profile_lock_fd}>&-
}

select_profile_runtime_image() {
    local profile_dir runtime_dir context_sha architecture core_ref prepared_tag
    local core_json core_id core_arch source_sha prepared_json prepared_id prepared_arch
    local label_contract label_core label_context label_source label_arch profile_lock_fd
    local rebuild_command

    profile_dir="$(resolve_profile_directory)"
    exec {profile_lock_fd}<"${profile_dir}" \
        || fail "could not open profile directory for locking: ${profile_dir}"
    flock -s "${profile_lock_fd}" \
        || fail "could not lock profile directory: ${profile_dir}"
    validate_profile_config "${profile_dir}" "${PROFILE}"
    validate_profile_definition_files "${profile_dir}"
    runtime_dir="${profile_dir}/runtime"
    context_sha="$(stable_runtime_context_sha256 "${runtime_dir}")" \
        || fail "profile runtime context changed during launch inspection or is invalid: ${runtime_dir}"
    architecture="$(runtime_architecture)"
    core_ref="${PI_RUN_CORE_IMAGE:-${DEFAULT_CORE_IMAGE}}"
    [[ -n "${core_ref}" ]] || fail "core runtime image reference must not be empty"
    prepared_tag="$(runtime_profile_image_tag "${profile_dir}")"
    rebuild_command="pi-run --profile ${PROFILE} runtime build"

    command -v docker >/dev/null 2>&1 \
        || fail "Docker command is unavailable; run: ${rebuild_command}"
    core_json="$(docker image inspect "${core_ref}" 2>/dev/null)" \
        || fail "core runtime image is unavailable locally: ${core_ref}; run: ${rebuild_command}"
    core_id="$(jq -er '.[0].Id | select(type == "string")' <<<"${core_json}")" \
        || fail "Docker returned an invalid core image identity: ${core_ref}; run: ${rebuild_command}"
    core_arch="$(jq -er '.[0].Architecture | select(type == "string")' <<<"${core_json}")" \
        || fail "Docker returned an invalid core image architecture: ${core_ref}; run: ${rebuild_command}"
    [[ "${core_id}" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || fail "Docker returned an invalid core image identity: ${core_ref}; run: ${rebuild_command}"
    [[ "${core_arch}" == "${architecture}" ]] \
        || fail "core runtime image architecture is ${core_arch}, expected ${architecture}; run: ${rebuild_command}"
    source_sha="$(runtime_source_sha256 "${context_sha}" "${core_id}" "${architecture}")" \
        || fail "could not calculate runtime source identity"

    prepared_json="$(docker image inspect "${prepared_tag}" 2>/dev/null)" \
        || fail "prepared profile runtime is missing: ${prepared_tag}; run: ${rebuild_command}"
    prepared_id="$(jq -er '.[0].Id | select(type == "string")' <<<"${prepared_json}")" \
        || fail "prepared profile runtime has an invalid image identity: ${prepared_tag}; run: ${rebuild_command}"
    prepared_arch="$(jq -er '.[0].Architecture | select(type == "string")' <<<"${prepared_json}")" \
        || fail "prepared profile runtime has an invalid architecture: ${prepared_tag}; run: ${rebuild_command}"
    [[ "${prepared_id}" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || fail "prepared profile runtime has an invalid image identity: ${prepared_tag}; run: ${rebuild_command}"
    label_contract="$(jq -r --arg key "${RUNTIME_LABEL_CONTRACT}" '.[0].Config.Labels[$key] // ""' \
        <<<"${prepared_json}")"
    label_core="$(jq -r --arg key "${RUNTIME_LABEL_CORE_ID}" '.[0].Config.Labels[$key] // ""' \
        <<<"${prepared_json}")"
    label_context="$(jq -r --arg key "${RUNTIME_LABEL_CONTEXT}" '.[0].Config.Labels[$key] // ""' \
        <<<"${prepared_json}")"
    label_source="$(jq -r --arg key "${RUNTIME_LABEL_SOURCE}" '.[0].Config.Labels[$key] // ""' \
        <<<"${prepared_json}")"
    label_arch="$(jq -r --arg key "${RUNTIME_LABEL_ARCHITECTURE}" '.[0].Config.Labels[$key] // ""' \
        <<<"${prepared_json}")"
    [[ "${prepared_arch}" == "${architecture}" &&
       "${label_contract}" == "${RUNTIME_BUILD_CONTRACT}" &&
       "${label_core}" == "${core_id}" &&
       "${label_context}" == "${context_sha}" &&
       "${label_source}" == "${source_sha}" &&
       "${label_arch}" == "${architecture}" ]] \
        || fail "prepared profile runtime is stale or incompatible: ${prepared_tag}; run: ${rebuild_command}"
    exec {profile_lock_fd}>&-
    printf '%s\n' "${prepared_tag}"
}

new_runtime_stage_id() {
    local id=""
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        id="$(< /proc/sys/kernel/random/uuid)"
    elif command -v uuidgen >/dev/null 2>&1; then
        id="$(uuidgen)"
    fi
    [[ "${id}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        || return 1
    printf '%s\n' "${id,,}"
}

build_profile_runtime() {
    local profile_dir runtime_dir context_sha post_context architecture core_ref prepared_tag
    local core_json core_id core_arch current_core_json current_core_id stage_id stage_tag frozen_core_tag
    local frozen_json frozen_id frozen_arch source_sha built_json built_id built_arch
    local label_contract label_core label_context label_source label_arch profile_lock_fd

    profile_dir="$(resolve_profile_directory)"
    exec {profile_lock_fd}<"${profile_dir}" \
        || fail "could not open profile directory for locking: ${profile_dir}"
    flock -x "${profile_lock_fd}" \
        || fail "could not lock profile directory: ${profile_dir}"
    validate_profile_config "${profile_dir}" "${PROFILE}"
    validate_profile_definition_files "${profile_dir}"
    runtime_dir="${profile_dir}/runtime"
    context_sha="$(stable_runtime_context_sha256 "${runtime_dir}")" \
        || fail "profile runtime context changed during inspection or is invalid: ${runtime_dir}"
    architecture="$(runtime_architecture)"
    core_ref="${PI_RUN_CORE_IMAGE:-${DEFAULT_CORE_IMAGE}}"
    [[ -n "${core_ref}" ]] || fail "core runtime image reference must not be empty"
    prepared_tag="$(runtime_profile_image_tag "${profile_dir}")"

    command -v docker >/dev/null 2>&1 || fail "Docker command is unavailable"
    docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable"
    core_json="$(docker image inspect "${core_ref}" 2>/dev/null)" \
        || fail "core runtime image is unavailable locally: ${core_ref}"
    core_id="$(jq -er '.[0].Id | select(type == "string")' <<<"${core_json}")" \
        || fail "Docker returned an invalid core image identity: ${core_ref}"
    core_arch="$(jq -er '.[0].Architecture | select(type == "string")' <<<"${core_json}")" \
        || fail "Docker returned an invalid core image architecture: ${core_ref}"
    [[ "${core_id}" =~ ^sha256:[0-9a-f]{64}$ ]] \
        || fail "Docker returned an invalid core image identity: ${core_ref}"
    [[ "${core_arch}" == "${architecture}" ]] \
        || fail "core runtime image architecture is ${core_arch}, expected ${architecture}"
    source_sha="$(runtime_source_sha256 "${context_sha}" "${core_id}" "${architecture}")" \
        || fail "could not calculate runtime source identity"
    stage_id="$(new_runtime_stage_id)" || fail "could not generate a runtime build ID"
    stage_tag="pi-run-runtime-stage:${stage_id}"
    frozen_core_tag="pi-run-core-stage:${stage_id}"

    (
        trap 'docker image rm -f "${stage_tag}" >/dev/null 2>&1 || true
              docker image rm -f "${frozen_core_tag}" >/dev/null 2>&1 || true' EXIT

        docker image tag "${core_id}" "${frozen_core_tag}" \
            || fail "could not create a temporary exact core image reference"
        frozen_json="$(docker image inspect "${frozen_core_tag}" 2>/dev/null)" \
            || fail "could not inspect the temporary core image reference"
        frozen_id="$(jq -er '.[0].Id | select(type == "string")' <<<"${frozen_json}")" \
            || fail "temporary core image reference has an invalid identity"
        frozen_arch="$(jq -er '.[0].Architecture | select(type == "string")' <<<"${frozen_json}")" \
            || fail "temporary core image reference has an invalid architecture"
        [[ "${frozen_id}" == "${core_id}" && "${frozen_arch}" == "${architecture}" ]] \
            || fail "temporary core image reference does not match the selected core image"

        docker build --pull=false \
            --build-arg "PI_RUN_BASE_IMAGE=${frozen_core_tag}" \
            --label "${RUNTIME_LABEL_CONTRACT}=${RUNTIME_BUILD_CONTRACT}" \
            --label "${RUNTIME_LABEL_CORE_ID}=${core_id}" \
            --label "${RUNTIME_LABEL_CONTEXT}=${context_sha}" \
            --label "${RUNTIME_LABEL_SOURCE}=${source_sha}" \
            --label "${RUNTIME_LABEL_ARCHITECTURE}=${architecture}" \
            --tag "${stage_tag}" "${runtime_dir}" \
            || fail "profile runtime image build failed"

        post_context="$(stable_runtime_context_sha256 "${runtime_dir}")" \
            || fail "profile runtime context changed during the build or is invalid"
        [[ "${post_context}" == "${context_sha}" ]] \
            || fail "profile runtime context changed during the build"
        current_core_json="$(docker image inspect "${core_ref}" 2>/dev/null)" \
            || fail "selected core runtime image changed during the build"
        current_core_id="$(jq -er '.[0].Id | select(type == "string")' <<<"${current_core_json}")" \
            || fail "selected core runtime image changed during the build"
        [[ "${current_core_id}" == "${core_id}" ]] \
            || fail "selected core runtime image changed during the build"

        built_json="$(docker image inspect "${stage_tag}" 2>/dev/null)" \
            || fail "could not inspect the built profile runtime image"
        built_id="$(jq -er '.[0].Id | select(type == "string")' <<<"${built_json}")" \
            || fail "built profile runtime image has an invalid identity"
        built_arch="$(jq -er '.[0].Architecture | select(type == "string")' <<<"${built_json}")" \
            || fail "built profile runtime image has an invalid architecture"
        [[ "${built_id}" =~ ^sha256:[0-9a-f]{64}$ && "${built_arch}" == "${architecture}" ]] \
            || fail "built profile runtime image has an incompatible identity or architecture"
        label_contract="$(jq -r --arg key "${RUNTIME_LABEL_CONTRACT}" '.[0].Config.Labels[$key] // ""' \
            <<<"${built_json}")"
        label_core="$(jq -r --arg key "${RUNTIME_LABEL_CORE_ID}" '.[0].Config.Labels[$key] // ""' \
            <<<"${built_json}")"
        label_context="$(jq -r --arg key "${RUNTIME_LABEL_CONTEXT}" '.[0].Config.Labels[$key] // ""' \
            <<<"${built_json}")"
        label_source="$(jq -r --arg key "${RUNTIME_LABEL_SOURCE}" '.[0].Config.Labels[$key] // ""' \
            <<<"${built_json}")"
        label_arch="$(jq -r --arg key "${RUNTIME_LABEL_ARCHITECTURE}" '.[0].Config.Labels[$key] // ""' \
            <<<"${built_json}")"
        [[ "${label_contract}" == "${RUNTIME_BUILD_CONTRACT}" &&
           "${label_core}" == "${core_id}" &&
           "${label_context}" == "${context_sha}" &&
           "${label_source}" == "${source_sha}" &&
           "${label_arch}" == "${architecture}" ]] \
            || fail "built profile runtime image is missing its exact identity labels"

        docker image tag "${stage_tag}" "${prepared_tag}" \
            || fail "could not activate the built profile runtime image"
        printf 'Built profile runtime: %s\n' "${prepared_tag}"
        printf 'Image identity: %s\n' "${built_id}"
        printf 'Source identity: %s\n' "${source_sha}"
    )
    exec {profile_lock_fd}>&-
}

validate_optional_profile_runtime() {
    local runtime_dir="${1}/runtime"
    if [[ -e "${runtime_dir}" || -L "${runtime_dir}" ]]; then
        validate_profile_runtime_context "${runtime_dir}" \
            || fail "profile runtime context is invalid, unsafe, or too large: ${runtime_dir}"
    fi
}

materialize_base_runtime() {
    local runtime_dir="$1"
    [[ ! -e "${runtime_dir}" && ! -L "${runtime_dir}" ]] \
        || fail "profile runtime target already exists: ${runtime_dir}"
    validate_runtime_templates
    mkdir -m 0700 "${runtime_dir}"
    install -m 0600 "${RUNTIME_TEMPLATE_ROOT}/Dockerfile" "${runtime_dir}/Dockerfile"
    install -m 0600 "${RUNTIME_TEMPLATE_ROOT}/.dockerignore" "${runtime_dir}/.dockerignore"
}

materialize_profile_runtime() {
    local source_profile="$1" target_profile="$2"
    local source_runtime="${source_profile}/runtime" target_runtime="${target_profile}/runtime"
    [[ ! -e "${target_runtime}" && ! -L "${target_runtime}" ]] \
        || fail "profile runtime target already exists: ${target_runtime}"
    if [[ -e "${source_runtime}" || -L "${source_runtime}" ]]; then
        validate_profile_runtime_context "${source_runtime}" \
            || fail "profile runtime context is invalid, unsafe, or too large: ${source_runtime}"
        mkdir -m 0700 "${target_runtime}"
        cp -a -- "${source_runtime}/." "${target_runtime}/"
        chmod 0700 "${target_runtime}"
    else
        materialize_base_runtime "${target_runtime}"
    fi
    validate_profile_runtime_context "${target_runtime}" \
        || fail "materialized profile runtime is invalid or unsafe: ${target_runtime}"
}

validate_profile_runtime_markers() {
    local dockerfile="$1" expected known_csv
    expected="$(runtime_all_bundle_names)" || return 1
    known_csv="$(paste -sd, <<<"${expected}")"
    awk -v known_csv="${known_csv}" '
        BEGIN {
            count = split(known_csv, names, ",")
            for (i = 1; i <= count; i++) known[names[i]] = 1
        }
        /^# BEGIN PI-RUN BUNDLE / {
            name = substr($0, 23)
            if (!(name in known) || inside != "" || seen[name]++) exit 1
            inside = name
            next
        }
        /^# END PI-RUN BUNDLE / {
            name = substr($0, 21)
            if (inside != name) exit 1
            inside = ""
            next
        }
        END { if (inside != "") exit 1 }
    ' "${dockerfile}"
}

append_runtime_bundle_block() {
    local bundle="$1" destination="$2"
    local template="${RUNTIME_TEMPLATE_ROOT}/full-development.Dockerfile"
    awk -v begin="# BEGIN PI-RUN BUNDLE ${bundle}" \
        -v end="# END PI-RUN BUNDLE ${bundle}" '
        $0 == begin { found = 1 }
        found { print }
        $0 == end { complete = 1; exit }
        END { if (!complete) exit 1 }
    ' "${template}" >> "${destination}"
}

add_profile_runtime_bundle() {
    local requested_name="$1" profile_dir runtime_dir dockerfile staging
    local original_hash original_inode current_hash current_inode old_size new_size projected_bytes
    local profile_lock_fd joined index
    local -a requested=() missing=()
    local -A present=()

    if [[ "${requested_name}" == all ]]; then
        mapfile -t requested < <(runtime_all_bundle_names)
    elif runtime_bundle_exists "${requested_name}"; then
        requested=("${requested_name}")
    else
        fail "unknown runtime bundle or group: ${requested_name}"
    fi
    (( ${#requested[@]} > 0 )) || fail "runtime bundle selection is empty: ${requested_name}"

    profile_dir="$(resolve_profile_directory)"
    exec {profile_lock_fd}<"${profile_dir}" \
        || fail "could not open profile directory for locking: ${profile_dir}"
    flock -x "${profile_lock_fd}" \
        || fail "could not lock profile directory: ${profile_dir}"
    validate_profile_config "${profile_dir}" "${PROFILE}"
    validate_profile_definition_files "${profile_dir}"
    runtime_dir="${profile_dir}/runtime"
    validate_profile_runtime_context "${runtime_dir}" \
        || fail "profile runtime context is missing, invalid, unsafe, or too large: ${runtime_dir}"
    validate_runtime_bundle_templates
    dockerfile="${runtime_dir}/Dockerfile"
    validate_profile_runtime_markers "${dockerfile}" \
        || fail "profile runtime Dockerfile has malformed bundle markers: ${dockerfile}"

    while IFS= read -r joined; do
        [[ -n "${joined}" ]] && present["${joined}"]=1
    done < <(sed -n 's/^# BEGIN PI-RUN BUNDLE //p' "${dockerfile}")
    for joined in "${requested[@]}"; do
        [[ -n "${present[${joined}]:-}" ]] || missing+=("${joined}")
    done
    if (( ${#missing[@]} == 0 )); then
        joined="$(IFS=,; printf '%s' "${requested[*]}")"
        printf 'Runtime bundle selection for %s is already present: %s (unchanged)\n' \
            "${PROFILE}" "${joined}"
        printf 'No runtime image was built.\n'
        exec {profile_lock_fd}>&-
        return 0
    fi

    original_hash="$(sha256sum "${dockerfile}" | awk '{print $1}')"
    original_inode="$(stat -c %i "${dockerfile}")"
    old_size="$(stat -c %s "${dockerfile}")"
    staging="${profile_dir}/.runtime-Dockerfile.tmp.$$"
    [[ ! -e "${staging}" && ! -L "${staging}" ]] \
        || fail "runtime Dockerfile staging path already exists: ${staging}"
    trap 'rm -f -- "${staging:-}"' EXIT
    if ! cp -p -- "${dockerfile}" "${staging}"; then
        fail "could not stage runtime Dockerfile: ${dockerfile}"
    fi
    printf '\n' >> "${staging}"
    for ((index = 0; index < ${#missing[@]}; index += 1)); do
        append_runtime_bundle_block "${missing[index]}" "${staging}" \
            || fail "could not read installed runtime bundle: ${missing[index]}"
        if (( index + 1 < ${#missing[@]} )); then
            printf '\n' >> "${staging}"
        fi
    done
    validate_profile_runtime_markers "${staging}" \
        || fail "staged runtime Dockerfile has malformed bundle markers"
    new_size="$(stat -c %s "${staging}")"
    projected_bytes=$((RUNTIME_CONTEXT_BYTE_COUNT - old_size + new_size))
    (( projected_bytes <= RUNTIME_CONTEXT_MAX_BYTES )) \
        || fail "runtime bundle addition would exceed the profile runtime size limit"

    current_hash="$(sha256sum "${dockerfile}" | awk '{print $1}')"
    current_inode="$(stat -c %i "${dockerfile}")"
    [[ "${current_hash}" == "${original_hash}" && "${current_inode}" == "${original_inode}" ]] \
        || fail "profile runtime Dockerfile changed while bundle addition was staged"
    if ! mv -T -- "${staging}" "${dockerfile}"; then
        fail "could not activate the staged runtime Dockerfile: ${dockerfile}"
    fi
    trap - EXIT
    exec {profile_lock_fd}>&-

    joined="$(IFS=,; printf '%s' "${missing[*]}")"
    printf 'Added runtime bundle selection for %s: %s\n' "${PROFILE}" "${joined}"
    printf 'Runtime Dockerfile: %s\n' "${dockerfile}"
    printf 'No runtime image was built.\n'
}

initialize_profile_runtime() {
    local profile_dir runtime_dir staging profile_lock_fd
    profile_dir="$(resolve_profile_directory)"
    exec {profile_lock_fd}<"${profile_dir}" \
        || fail "could not open profile directory for locking: ${profile_dir}"
    flock -x "${profile_lock_fd}" \
        || fail "could not lock profile directory: ${profile_dir}"
    validate_profile_config "${profile_dir}" "${PROFILE}"
    validate_profile_definition_files "${profile_dir}"

    runtime_dir="${profile_dir}/runtime"
    [[ ! -e "${runtime_dir}" && ! -L "${runtime_dir}" ]] \
        || fail "profile runtime already exists: ${runtime_dir}"
    validate_runtime_templates

    staging="${profile_dir}/.runtime.tmp.$$"
    [[ ! -e "${staging}" && ! -L "${staging}" ]] \
        || fail "profile runtime staging path already exists: ${staging}"
    if ! mkdir -m 0700 "${staging}"; then
        rm -rf -- "${staging}"
        fail "could not stage profile runtime: ${staging}"
    fi
    if ! install -m 0600 "${RUNTIME_TEMPLATE_ROOT}/Dockerfile" "${staging}/Dockerfile" \
        || ! install -m 0600 "${RUNTIME_TEMPLATE_ROOT}/.dockerignore" "${staging}/.dockerignore"; then
        rm -rf -- "${staging}"
        fail "could not stage profile runtime files: ${staging}"
    fi
    if ! mv -T --no-clobber -- "${staging}" "${runtime_dir}" \
        || [[ -e "${staging}" || -L "${staging}" ]]; then
        rm -rf -- "${staging}"
        fail "could not activate profile runtime: ${runtime_dir}"
    fi
    exec {profile_lock_fd}>&-

    printf 'Initialized runtime for %s: %s\n' "${PROFILE}" "${runtime_dir}/Dockerfile"
    printf 'No runtime image was built.\n'
}
