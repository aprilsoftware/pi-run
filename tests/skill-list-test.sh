#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "skill-list-test: $*" >&2
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

HOME_DIR="${TMP}/Pi-Run"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null

write_skill() {
    local directory="$1" name="$2"
    mkdir -p "${directory}"
    cat > "${directory}/SKILL.md" <<EOF
---
name: ${name}
description: Test skill used to verify aligned skill-list output.
---

# ${name}
EOF
}

write_skill "${HOME_DIR}/profiles/default/skills/custom-profile-skill" custom-profile-skill
write_skill "${HOME_DIR}/skills/shared-library-skill" shared-library-skill

PROFILE_CONFIG="${HOME_DIR}/profiles/default/profile.json"
set_filter() {
    local expression="$1"
    jq "${expression}" "${PROFILE_CONFIG}" > "${PROFILE_CONFIG}.tmp"
    mv "${PROFILE_CONFIG}.tmp" "${PROFILE_CONFIG}"
}

assert_skill_row() {
    local content="$1" type="$2" name="$3" status="$4"
    awk -v type="${type}" -v name="${name}" -v status="${status}" \
        '$1 == type && $2 == name && $3 == status { found=1 } END { exit !found }' \
        <<< "${content}" || fail "missing skill row: ${type} ${name} ${status}"
}

output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" skill list)"
[[ "${output}" != *$'\t'* ]] || fail "skill list still contains tab separators"
header="$(sed -n '1p' <<< "${output}")"
name_column="$(awk 'NR==1 {print index($0,"NAME")}' <<< "${header}")"
status_column="$(awk 'NR==1 {print index($0,"STATUS")}' <<< "${header}")"
[[ "${name_column}" -gt 1 && "${status_column}" -gt "${name_column}" ]] \
    || fail "skill list headers are missing or unordered"
while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    [[ "${row:$((name_column - 1)):1}" != ' ' &&
       "${row:$((status_column - 1)):1}" != ' ' ]] \
        || fail "skill columns are not aligned with their headers: ${row}"
done < <(sed -n '2,$p' <<< "${output}")
assert_skill_row "${output}" core pi-run active
assert_skill_row "${output}" core profile-management active
assert_skill_row "${output}" profile custom-profile-skill active
assert_skill_row "${output}" global shared-library-skill active

for command in \
    'import source' \
    'add default shared-library-skill' \
    'remove default shared-library-skill' \
    'templates' \
    'install shared-library-skill'; do
    read -r -a arguments <<< "${command}"
    expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" skill "${arguments[@]}"
done

WORKSPACE="${TMP}/workspace"
DOCKER_LOG="${TMP}/docker.log"
mkdir "${WORKSPACE}" "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
: > "${DOCKER_LOG:?}"
for argument in "$@"; do printf '%s\n' "${argument}" >> "${DOCKER_LOG}"; done
EOF
chmod 0755 "${TMP}/fake-bin/docker"
run_workspace() {
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" DOCKER_LOG="${DOCKER_LOG}" \
        "${ROOT}/bin/pi-run" "${WORKSPACE}" >/dev/null 2>&1
}

run_workspace
grep -Fx -- '/profile/skills/custom-profile-skill' "${DOCKER_LOG}" >/dev/null \
    || fail "profile-local skill was not passed to Pi"
grep -Fx -- '/skills/shared-library-skill' "${DOCKER_LOG}" >/dev/null \
    || fail "global skill was not passed to Pi"
grep -Fx -- \
    "type=bind,src=${HOME_DIR}/skills/shared-library-skill,dst=/skills/shared-library-skill,readonly" \
    "${DOCKER_LOG}" >/dev/null || fail "global skill was not mounted read-only"

set_filter '.skills = []'
output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" skill list)"
assert_skill_row "${output}" profile custom-profile-skill active
assert_skill_row "${output}" global shared-library-skill filtered
run_workspace
if grep -Fx -- '/skills/shared-library-skill' "${DOCKER_LOG}" >/dev/null; then
    fail "empty skill filter loaded a global skill"
fi
grep -Fx -- '/profile/skills/custom-profile-skill' "${DOCKER_LOG}" >/dev/null \
    || fail "empty global filter disabled a profile-local skill"

set_filter '.skills = ["shared-library-skill"]'
output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" skill list)"
assert_skill_row "${output}" global shared-library-skill active
run_workspace
grep -Fx -- '/skills/shared-library-skill' "${DOCKER_LOG}" >/dev/null \
    || fail "selected global skill was not loaded"

for expression in \
    '.skills = ["missing-skill"]' \
    '.skills = ["shared-library-skill", "shared-library-skill"]' \
    '.skills = ["pi-run"]' \
    '.skills = "shared-library-skill"'; do
    set_filter "${expression}"
    expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" skill list
done

set_filter '.skills = ["shared-library-skill"]'
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create unrestricted --from default >/dev/null
jq -e '.skills == null' "${HOME_DIR}/profiles/unrestricted/profile.json" >/dev/null \
    || fail "new profile did not default its global skill filter to null"
output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" --profile unrestricted skill list)"
assert_skill_row "${output}" global shared-library-skill active

set_filter 'del(.skills)'
output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" skill list)"
assert_skill_row "${output}" global shared-library-skill active

write_skill "${HOME_DIR}/profiles/default/skills/shared-library-skill" shared-library-skill
set_filter '.skills = []'
output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" skill list)"
assert_skill_row "${output}" profile shared-library-skill active
assert_skill_row "${output}" global shared-library-skill filtered
set_filter '.skills = null'
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" skill list

echo "skill filtering and global/profile loading tests passed"
