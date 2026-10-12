#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "session-reconnect-test: $*" >&2
    exit 1
}

expect_failure() {
    local status
    set +e
    "$@" >/dev/null 2>&1
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "command unexpectedly succeeded: $*"
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' '---' >> "${DOCKER_LOG:?}"
printf '%s\n' "$@" >> "${DOCKER_LOG}"
EOF
chmod 0755 "${TMP}/fake-bin/docker"

run_tty() {
    local input="$1" command="" argument
    shift
    for argument in "$@"; do
        printf -v command '%s%q ' "${command}" "${argument}"
    done
    printf '%b' "${input}" | script -qefc "${command}" /dev/null
}

initialize_case() {
    local name="$1" home workspace
    home="${TMP}/${name}-home"
    workspace="${TMP}/${name}/pi-run"
    mkdir -p "${workspace}"
    env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" DOCKER_LOG="${TMP}/${name}.log" \
        "${ROOT}/bin/pi-run" init >/dev/null
    : > "${TMP}/${name}.log"
    env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" DOCKER_LOG="${TMP}/${name}.log" \
        "${ROOT}/bin/pi-run" "${workspace}" >/dev/null 2>&1
    printf '%s\t%s\n' "${home}" "${workspace}"
}

add_restored_workspace() {
    local home="$1" id="$2" name="$3" profile="${4:-default}"
    local registry="${home}/workspaces/registry.json" session_dir
    jq --arg id "${id}" --arg name "${name}" \
        '.workspaces += [{id:$id,name:$name,kind:"git",createdAt:"2026-10-10T12:00:00Z"}]' \
        "${registry}" > "${registry}.tmp"
    mv "${registry}.tmp" "${registry}"
    chmod 0600 "${registry}"
    session_dir="${home}/profiles/${profile}/sessions/${id}"
    mkdir -p "${session_dir}"
    printf '%s\n' \
        '{"type":"session","id":"11111111-1111-4111-8111-111111111111","timestamp":"2026-10-10T12:00:00Z","cwd":"/workspace","version":3}' \
        > "${session_dir}/restored.jsonl"
}

machine_file_for() {
    find "$1/machines" -maxdepth 1 -type f -name '*.json' -print -quit
}

mapped_id() {
    local home="$1" path="$2"
    jq -r --arg path "${path}" '.workspacePaths[] | select(.path == $path) | .workspaceId' \
        "$(machine_file_for "${home}")"
}

RESTORED_ID=11111111-1111-4111-8111-111111111111
IFS=$'\t' read -r home workspace < <(initialize_case direct)
current_id="$(mapped_id "${home}" "${workspace}")"
add_restored_workspace "${home}" "${RESTORED_ID}" pi-run
output="$(run_tty '\n' env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
    DOCKER_LOG="${TMP}/direct.log" "${ROOT}/bin/pi-run" "${workspace}" -r)"
[[ "${output}" == *'Restored sessions are available for this project:'* &&
   "${output}" == *'Checkout reconnected to 1 restored session(s).'* ]] \
    || fail "direct resume did not guide restored-session reconnection"
[[ "$(mapped_id "${home}" "${workspace}")" == "${RESTORED_ID}" ]] \
    || fail "direct resume did not reconnect the checkout"
jq -e --arg id "${current_id}" '[.workspaces[] | select(.id == $id)] | length == 0' \
    "${home}/workspaces/registry.json" >/dev/null || fail "empty placeholder workspace was retained"
grep -Fx -- "/profile/sessions/${RESTORED_ID}" "${TMP}/direct.log" >/dev/null \
    || fail "Pi was not launched with the restored session directory"
grep -Fx -- '-r' "${TMP}/direct.log" >/dev/null || fail "Pi resume argument was not preserved"
[[ -f "${home}/profiles/default/sessions/${RESTORED_ID}/restored.jsonl" ]] \
    || fail "restored session was modified"

workspace_output="$(PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" workspace list)"
workspace_header="$(sed -n '1p' <<< "${workspace_output}")"
workspace_row="$(grep -F "${RESTORED_ID}" <<< "${workspace_output}")"
name_column="$(awk 'NR==1 {print index($0,"NAME")}' <<< "${workspace_header}")"
path_column="$(awk 'NR==1 {print index($0,"PATH")}' <<< "${workspace_header}")"
[[ "${workspace_row:$((name_column - 1)):6}" == pi-run &&
   "${workspace_row:$((path_column - 1))}" == "${workspace}" ]] \
    || fail "workspace list headers are not aligned with data"

session_output="$(PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" session list)"
session_header="$(sed -n '1p' <<< "${session_output}")"
session_row="$(grep -F "${RESTORED_ID}" <<< "${session_output}")"
for column in PROFILE 'WORKSPACE ID' NAME SESSIONS STATUS PATH; do
    column_position="$(awk -v label="${column}" 'NR==1 {print index($0,label)}' <<< "${session_header}")"
    [[ "${column_position}" != 0 ]] || fail "session list header is missing: ${column}"
done
name_column="$(awk 'NR==1 {print index($0,"NAME")}' <<< "${session_header}")"
status_column="$(awk 'NR==1 {print index($0,"STATUS")}' <<< "${session_header}")"
path_column="$(awk 'NR==1 {print index($0,"PATH")}' <<< "${session_header}")"
[[ "${session_row:$((name_column - 1)):6}" == pi-run &&
   "${session_row:$((status_column - 1)):9}" == available &&
   "${session_row:$((path_column - 1))}" == "${workspace}" ]] \
    || fail "session list headers are not aligned with data"

PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" profile create review --from default >/dev/null
NAMED_SESSION_ID=88888888-8888-4888-8888-888888888888
REVIEW_SESSION_ID=99999999-9999-4999-8999-999999999999
IMPORTED_SESSION_ID=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
named_session="${home}/profiles/default/sessions/${RESTORED_ID}/named.jsonl"
printf '%s\n' \
    "{\"type\":\"session\",\"id\":\"${NAMED_SESSION_ID}\",\"timestamp\":\"2026-10-10T13:00:00Z\",\"cwd\":\"/workspace\",\"version\":3}" \
    '{"type":"session_info","id":"entry001","parentId":null,"timestamp":"2026-10-10T13:01:00Z","name":"Earlier name"}' \
    '{"type":"session_info","id":"entry002","parentId":"entry001","timestamp":"2026-10-10T13:02:00Z","name":"Latest\tname"}' \
    > "${named_session}"
mkdir -p "${home}/profiles/review/sessions/${RESTORED_ID}"
printf '%s\n' \
    "{\"type\":\"session\",\"id\":\"${REVIEW_SESSION_ID}\",\"timestamp\":\"2026-10-10T14:00:00Z\",\"cwd\":\"/workspace\",\"version\":3}" \
    > "${home}/profiles/review/sessions/${RESTORED_ID}/review.jsonl"
printf '%s\n' \
    "{\"type\":\"session\",\"id\":\"${IMPORTED_SESSION_ID}\",\"timestamp\":\"2026-10-10T15:00:00Z\",\"cwd\":\"/workspace\",\"version\":3}" \
    > "${home}/profiles/default/sessions/${RESTORED_ID}/import-one.jsonl"
printf '%s\n' \
    "{\"type\":\"session\",\"id\":\"${IMPORTED_SESSION_ID}\",\"timestamp\":\"2026-10-10T16:00:00Z\",\"cwd\":\"/workspace\",\"version\":3}" \
    > "${home}/profiles/default/sessions/${RESTORED_ID}/import-two.jsonl"

individual_output="$(PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" session list "${RESTORED_ID^^}")"
individual_header="$(sed -n '1p' <<< "${individual_output}")"
for column in PROFILE 'SESSION ID' CREATED NAME FILE; do
    column_position="$(awk -v label="${column}" 'NR==1 {print index($0,label)}' <<< "${individual_header}")"
    [[ "${column_position}" != 0 ]] || fail "individual session list header is missing: ${column}"
done
named_row="$(grep -F "${NAMED_SESSION_ID}" <<< "${individual_output}")"
review_row="$(grep -F "${REVIEW_SESSION_ID}" <<< "${individual_output}")"
unnamed_row="$(grep -F '11111111-1111-4111-8111-111111111111' <<< "${individual_output}")"
session_column="$(awk 'NR==1 {print index($0,"SESSION ID")}' <<< "${individual_header}")"
created_column="$(awk 'NR==1 {print index($0,"CREATED")}' <<< "${individual_header}")"
name_column="$(awk 'NR==1 {print index($0,"NAME")}' <<< "${individual_header}")"
file_column="$(awk 'NR==1 {print index($0,"  FILE") + 2}' <<< "${individual_header}")"
[[ "${named_row:0:7}" == default &&
   "${named_row:$((session_column - 1)):36}" == "${NAMED_SESSION_ID}" &&
   "${named_row:$((created_column - 1)):20}" == '2026-10-10T13:00:00Z' &&
   "${named_row:$((name_column - 1)):11}" == 'Latest name' &&
   "${named_row:$((file_column - 1))}" == named.jsonl ]] \
    || fail "named individual session row is incorrect or misaligned"
[[ "${review_row:0:6}" == review && "${review_row:$((name_column - 1)):1}" == '-' &&
   "${review_row:$((file_column - 1))}" == review.jsonl ]] \
    || fail "cross-profile individual session row is incorrect"
[[ "${unnamed_row:$((name_column - 1)):1}" == '-' ]] || fail "unnamed session did not display a dash"
[[ "$(grep -Fc "${IMPORTED_SESSION_ID}" <<< "${individual_output}")" == 2 &&
   "${individual_output}" == *import-one.jsonl* && "${individual_output}" == *import-two.jsonl* ]] \
    || fail "imported sessions sharing an ID were not listed as separate files"

empty_output="$(PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" session list 00000000-0000-4000-8000-000000000000)"
[[ "$(wc -l <<< "${empty_output}")" == 1 ]] || fail "empty workspace session list contained data rows"
expect_failure env PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" session list invalid
printf '%s\n' '{not-json' >> "${named_session}"
expect_failure env PI_RUN_HOME="${home}" "${ROOT}/bin/pi-run" session list "${RESTORED_ID}"
sed -i '$d' "${named_session}"

RESUME_ID=22222222-2222-4222-8222-222222222222
IFS=$'\t' read -r home workspace < <(initialize_case resume)
current_id="$(mapped_id "${home}" "${workspace}")"
add_restored_workspace "${home}" "${RESUME_ID}" pi-run
expect_failure env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
    DOCKER_LOG="${TMP}/resume.log" "${ROOT}/bin/pi-run" resume default "${RESUME_ID}"
[[ "$(mapped_id "${home}" "${workspace}")" == "${current_id}" ]] \
    || fail "non-interactive resume changed the workspace mapping"
output="$(run_tty "${workspace}\n\n" env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
    DOCKER_LOG="${TMP}/resume.log" "${ROOT}/bin/pi-run" resume default "${RESUME_ID}")"
[[ "${output}" == *'but no checkout is linked on this machine.'* &&
   "${output}" == *'Checkout reconnected to 1 restored session(s).'* ]] \
    || fail "resume command did not guide checkout reconnection"
[[ "$(mapped_id "${home}" "${workspace}")" == "${RESUME_ID}" ]] \
    || fail "resume command did not reconnect the checkout"
grep -Fx -- '--resume' "${TMP}/resume.log" >/dev/null || fail "guided resume did not launch Pi"

DECLINED_ID=33333333-3333-4333-8333-333333333333
IFS=$'\t' read -r home workspace < <(initialize_case declined)
current_id="$(mapped_id "${home}" "${workspace}")"
add_restored_workspace "${home}" "${DECLINED_ID}" pi-run
run_tty 'n\n' env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
    DOCKER_LOG="${TMP}/declined.log" "${ROOT}/bin/pi-run" "${workspace}" -r >/dev/null
[[ "$(mapped_id "${home}" "${workspace}")" == "${current_id}" ]] \
    || fail "declined reconnection changed the workspace mapping"
[[ -f "${home}/profiles/default/sessions/${DECLINED_ID}/restored.jsonl" ]] \
    || fail "declined reconnection changed restored sessions"

MULTIPLE_A=66666666-6666-4666-8666-666666666666
MULTIPLE_B=77777777-7777-4777-8777-777777777777
IFS=$'\t' read -r home workspace < <(initialize_case multiple)
add_restored_workspace "${home}" "${MULTIPLE_A}" pi-run
add_restored_workspace "${home}" "${MULTIPLE_B}" pi-run
output="$(run_tty '2\ny\n' env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
    DOCKER_LOG="${TMP}/multiple.log" "${ROOT}/bin/pi-run" "${workspace}" -r)"
[[ "${output}" == *'1) pi-run'* && "${output}" == *'2) pi-run'* ]] \
    || fail "multiple restored candidates were not presented"
[[ "$(mapped_id "${home}" "${workspace}")" == "${MULTIPLE_B}" ]] \
    || fail "selected restored candidate was not reconnected"
[[ -f "${home}/profiles/default/sessions/${MULTIPLE_A}/restored.jsonl" &&
   -f "${home}/profiles/default/sessions/${MULTIPLE_B}/restored.jsonl" ]] \
    || fail "multiple-candidate selection changed restored sessions"

CONFLICT_ID=44444444-4444-4444-8444-444444444444
IFS=$'\t' read -r home workspace < <(initialize_case conflict)
current_id="$(mapped_id "${home}" "${workspace}")"
add_restored_workspace "${home}" "${CONFLICT_ID}" pi-run
mkdir -p "${home}/profiles/default/sessions/${current_id}"
printf '%s\n' \
    '{"type":"session","id":"55555555-5555-4555-8555-555555555555","timestamp":"2026-10-10T12:00:00Z","cwd":"/workspace","version":3}' \
    > "${home}/profiles/default/sessions/${current_id}/current.jsonl"
expect_failure run_tty "${workspace}\n" env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${home}" \
    DOCKER_LOG="${TMP}/conflict.log" "${ROOT}/bin/pi-run" resume default "${CONFLICT_ID}"
[[ "$(mapped_id "${home}" "${workspace}")" == "${current_id}" ]] \
    || fail "session conflict changed the workspace mapping"
[[ -f "${home}/profiles/default/sessions/${current_id}/current.jsonl" &&
   -f "${home}/profiles/default/sessions/${CONFLICT_ID}/restored.jsonl" ]] \
    || fail "session conflict changed session files"

echo "guided session reconnection tests passed"
