#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "guardian-log-migration-test: $*" >&2; exit 1; }
make_profile() {
    local home="$1" name="$2" profile
    profile="${home}/profiles/${name}"
    mkdir -p "${profile}/guardian" "${profile}/credentials" "${profile}/sessions" "${profile}/skills"
    jq --arg name "${name}" '.name = $name' "${ROOT}/templates/profiles/default/profile.json" > "${profile}/profile.json"
    cp "${ROOT}/templates/profiles/default/AGENTS.md" "${profile}/AGENTS.md"
    cp "${ROOT}/templates/profiles/default/guardian/guardian.md" "${profile}/guardian/guardian.md"
    chmod 0700 "${home}" "${home}/profiles" "${profile}" "${profile}/guardian" "${profile}/credentials" "${profile}/sessions" "${profile}/skills"
    chmod 0600 "${profile}/profile.json" "${profile}/AGENTS.md" "${profile}/guardian/guardian.md"
}
make_home() {
    local home="$1"; shift
    mkdir -p "${home}/profiles"; chmod 0700 "${home}" "${home}/profiles"
    local name; for name in "$@"; do make_profile "${home}" "${name}"; done
}
run_migration() { PI_RUN_HOME="$1" "${ROOT}/bin/pi-run" migrate guardian-logs; }
expect_failure() {
    local home="$1" expected="$2" output status
    set +e; output="$(run_migration "${home}" 2>&1)"; status=$?; set -e
    [[ ${status} -ne 0 ]] || fail "migration unexpectedly succeeded: ${home}"
    [[ "${output}" == *"${expected}"* ]] || fail "missing failure text '${expected}': ${output}"
}
write_log() { printf '%s\n' "$2" > "$1"; chmod 0600 "$1"; }

BASIC="${TMP}/basic"; make_home "${BASIC}" default second
write_log "${BASIC}/profiles/default/guardian/guardian.log" default-current
write_log "${BASIC}/profiles/default/guardian/guardian.log.1" default-one
write_log "${BASIC}/profiles/second/guardian/guardian.log.2" second-two
before_config="$(sha256sum "${BASIC}/profiles/default/profile.json")"
before_policy="$(sha256sum "${BASIC}/profiles/default/guardian/guardian.md")"
output="$(run_migration "${BASIC}")"
[[ "${output}" == *"2 profile(s), 3 source file(s) moved"* ]] || fail "wrong migration summary: ${output}"
for source in guardian.log guardian.log.1 guardian.log.2; do
    [[ ! -e "${BASIC}/profiles/default/guardian/${source}" ]] || fail "default source remained: ${source}"
done
[[ ! -e "${BASIC}/profiles/second/guardian/guardian.log.2" ]] || fail "second profile source remained"
[[ "$(cat "${BASIC}/profiles/default/logs/guardian/legacy/events.jsonl")" == default-current ]] || fail "current log content changed"
[[ "$(cat "${BASIC}/profiles/default/logs/guardian/legacy/events.jsonl.1")" == default-one ]] || fail "backup content changed"
[[ "$(cat "${BASIC}/profiles/second/logs/guardian/legacy/events.jsonl.2")" == second-two ]] || fail "second profile content changed"
[[ "$(stat -c %a "${BASIC}/profiles/default/logs/guardian/legacy")" == 700 ]] || fail "legacy directory mode changed"
[[ "$(stat -c %a "${BASIC}/profiles/default/logs/guardian/legacy/events.jsonl")" == 600 ]] || fail "legacy file mode changed"
[[ "$(sha256sum "${BASIC}/profiles/default/profile.json")" == "${before_config}" ]] || fail "profile config changed"
[[ "$(sha256sum "${BASIC}/profiles/default/guardian/guardian.md")" == "${before_policy}" ]] || fail "Guardian policy changed"
output="$(run_migration "${BASIC}")"
[[ "${output}" == *"0 profile(s), 0 source file(s) moved"* ]] || fail "idempotent migration changed state"

PARTIAL="${TMP}/partial"; make_home "${PARTIAL}" default
mkdir -p "${PARTIAL}/profiles/default/logs/guardian/.legacy-migration"
chmod 0700 "${PARTIAL}/profiles/default/logs" "${PARTIAL}/profiles/default/logs/guardian" "${PARTIAL}/profiles/default/logs/guardian/.legacy-migration"
write_log "${PARTIAL}/profiles/default/logs/guardian/.legacy-migration/events.jsonl" staged-current
write_log "${PARTIAL}/profiles/default/guardian/guardian.log.1" remaining-one
output="$(run_migration "${PARTIAL}")"
[[ "${output}" == *"1 profile(s), 1 source file(s) moved"* ]] || fail "partial migration did not resume"
[[ "$(cat "${PARTIAL}/profiles/default/logs/guardian/legacy/events.jsonl")" == staged-current ]] || fail "staged content changed"
[[ "$(cat "${PARTIAL}/profiles/default/logs/guardian/legacy/events.jsonl.1")" == remaining-one ]] || fail "remaining content changed"

COLLISION="${TMP}/collision"; make_home "${COLLISION}" default
write_log "${COLLISION}/profiles/default/guardian/guardian.log" source-content
mkdir -p "${COLLISION}/profiles/default/logs/guardian/legacy"; chmod 0700 "${COLLISION}/profiles/default/logs" "${COLLISION}/profiles/default/logs/guardian" "${COLLISION}/profiles/default/logs/guardian/legacy"
write_log "${COLLISION}/profiles/default/logs/guardian/legacy/events.jsonl" destination-content
expect_failure "${COLLISION}" "destination collides"
[[ "$(cat "${COLLISION}/profiles/default/guardian/guardian.log")" == source-content ]] || fail "collision changed source"
[[ "$(cat "${COLLISION}/profiles/default/logs/guardian/legacy/events.jsonl")" == destination-content ]] || fail "collision changed destination"

for kind in symlink hardlink mode staging; do
    home="${TMP}/${kind}"; make_home "${home}" default; source="${home}/profiles/default/guardian/guardian.log"
    case "${kind}" in
        symlink) write_log "${home}/outside" outside; ln -s "${home}/outside" "${source}"; expected="file is unsafe" ;;
        hardlink) write_log "${home}/outside" outside; ln "${home}/outside" "${source}"; expected="file is unsafe" ;;
        mode) write_log "${source}" mode; chmod 0644 "${source}"; expected="must be private" ;;
        staging) mkdir -p "${home}/profiles/default/logs/guardian/.legacy-migration"; chmod 0700 "${home}/profiles/default/logs" "${home}/profiles/default/logs/guardian" "${home}/profiles/default/logs/guardian/.legacy-migration"; write_log "${home}/profiles/default/logs/guardian/.legacy-migration/unexpected" bad; expected="unexpected Guardian log migration staging" ;;
    esac
    expect_failure "${home}" "${expected}"
done

LOCKED="${TMP}/locked"; make_home "${LOCKED}" default
write_log "${LOCKED}/profiles/default/guardian/guardian.log" locked
exec 9<"${LOCKED}"; flock -s 9
expect_failure "${LOCKED}" "requires exclusive access"
[[ "$(cat "${LOCKED}/profiles/default/guardian/guardian.log")" == locked ]] || fail "lock refusal changed source"
flock -u 9; exec 9<&-

echo "explicit Guardian legacy log migration tests passed"
