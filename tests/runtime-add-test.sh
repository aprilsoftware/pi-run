#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "runtime-add-test: $*" >&2
    exit 1
}

expect_failure() {
    local status
    set +e
    "$@" >"${TMP}/failure.out" 2>&1
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "command unexpectedly succeeded: $*"
}

assert_no_staging() {
    local profile="$1"
    ! find "${profile}" -maxdepth 1 -name '.runtime-Dockerfile.tmp.*' -print -quit | grep -q . \
        || fail "runtime bundle operation left staging data: ${profile}"
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
: > "${DOCKER_CALLED:?}"
exit 99
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export PATH="${TMP}/fake-bin:${PATH}"
export DOCKER_CALLED="${TMP}/docker-called"

HOME_DIR="${TMP}/Pi Run"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create full >/dev/null
full_profile="${HOME_DIR}/profiles/full"
output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" --profile full runtime add all)"
[[ "${output}" == *'Added runtime bundle selection for full:'* &&
   "${output}" == *'No runtime image was built.'* ]] \
    || fail "runtime add all returned unexpected output"
cmp "${ROOT}/templates/runtime/full-development.Dockerfile" \
    "${full_profile}/runtime/Dockerfile" \
    || fail "runtime add all did not produce the maintained full-development definition"
full_inode="$(stat -c %i "${full_profile}/runtime/Dockerfile")"
full_hash="$(sha256sum "${full_profile}/runtime/Dockerfile" | awk '{print $1}')"
output="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" --profile full runtime add all)"
[[ "${output}" == *'(unchanged)'* &&
   "$(stat -c %i "${full_profile}/runtime/Dockerfile")" == "${full_inode}" &&
   "$(sha256sum "${full_profile}/runtime/Dockerfile" | awk '{print $1}')" == "${full_hash}" ]] \
    || fail "repeated runtime add all rewrote the Dockerfile"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create partial >/dev/null
partial_profile="${HOME_DIR}/profiles/partial"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    --profile partial runtime add java-development >/dev/null
awk '
    /^# END PI-RUN BUNDLE java-development$/ { print "# retained user edit" }
    { print }
' "${partial_profile}/runtime/Dockerfile" > "${TMP}/partial-edited"
mv "${TMP}/partial-edited" "${partial_profile}/runtime/Dockerfile"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" --profile partial runtime add all >/dev/null
grep -Fx '# retained user edit' "${partial_profile}/runtime/Dockerfile" >/dev/null \
    || fail "runtime add all replaced an existing edited bundle"
bundle_names="$(PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" runtime list | awk 'NR > 2 { print $1 }')"
while IFS= read -r bundle; do
    [[ "$(grep -Fxc "# BEGIN PI-RUN BUNDLE ${bundle}" \
        "${partial_profile}/runtime/Dockerfile")" == 1 ]] \
        || fail "partial runtime does not contain exactly one ${bundle} block"
done <<<"${bundle_names}"

cp "${partial_profile}/runtime/Dockerfile" "${TMP}/partial.before"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    --profile partial runtime add unknown-bundle
cmp "${TMP}/partial.before" "${partial_profile}/runtime/Dockerfile" \
    || fail "unknown runtime bundle changed the Dockerfile"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create malformed >/dev/null
malformed_profile="${HOME_DIR}/profiles/malformed"
printf '\n# BEGIN PI-RUN BUNDLE utility-belt\n' >> "${malformed_profile}/runtime/Dockerfile"
cp "${malformed_profile}/runtime/Dockerfile" "${TMP}/malformed.before"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    --profile malformed runtime add network-diagnostics
cmp "${TMP}/malformed.before" "${malformed_profile}/runtime/Dockerfile" \
    || fail "malformed marker refusal changed the Dockerfile"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create missing >/dev/null
missing_profile="${HOME_DIR}/profiles/missing"
rm -rf "${missing_profile}/runtime"
expect_failure env PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" \
    --profile missing runtime add utility-belt

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create locked >/dev/null
locked_profile="${HOME_DIR}/profiles/locked"
exec {profile_lock_fd}<"${locked_profile}"
flock -x "${profile_lock_fd}"
PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" --profile locked \
    runtime add utility-belt >"${TMP}/locked.out" &
add_pid=$!
sleep 0.1
kill -0 "${add_pid}" 2>/dev/null || fail "runtime add did not wait for the profile lock"
flock -u "${profile_lock_fd}"
wait "${add_pid}"
exec {profile_lock_fd}>&-

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create changed >/dev/null
changed_profile="${HOME_DIR}/profiles/changed"
real_sha256sum="$(command -v sha256sum)"
mkdir "${TMP}/race-bin"
cat > "${TMP}/race-bin/sha256sum" <<'EOF'
#!/bin/sh
set -eu
count=0
[ ! -f "${SHA_COUNT:?}" ] || count=$(cat "${SHA_COUNT}")
count=$((count + 1))
printf '%s\n' "${count}" > "${SHA_COUNT}"
if [ "${count}" -eq 2 ]; then
    printf '# concurrent user edit\n' >> "${RACE_DOCKERFILE:?}"
fi
exec "${REAL_SHA256SUM:?}" "$@"
EOF
chmod 0755 "${TMP}/race-bin/sha256sum"
expect_failure env PATH="${TMP}/race-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    SHA_COUNT="${TMP}/sha-count" REAL_SHA256SUM="${real_sha256sum}" \
    RACE_DOCKERFILE="${changed_profile}/runtime/Dockerfile" \
    "${ROOT}/bin/pi-run" --profile changed runtime add utility-belt
grep -Fx '# concurrent user edit' "${changed_profile}/runtime/Dockerfile" >/dev/null \
    || fail "concurrent edit fixture did not change the Dockerfile"
! grep -Fx '# BEGIN PI-RUN BUNDLE utility-belt' \
    "${changed_profile}/runtime/Dockerfile" >/dev/null \
    || fail "runtime add overwrote a concurrent Dockerfile change"
assert_no_staging "${changed_profile}"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" profile create failed-move >/dev/null
failed_profile="${HOME_DIR}/profiles/failed-move"
cp "${failed_profile}/runtime/Dockerfile" "${TMP}/failed-move.before"
mkdir "${TMP}/failed-move-bin"
printf '#!/bin/sh\nexit 12\n' > "${TMP}/failed-move-bin/mv"
chmod 0755 "${TMP}/failed-move-bin/mv"
expect_failure env PATH="${TMP}/failed-move-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" --profile failed-move runtime add utility-belt
cmp "${TMP}/failed-move.before" "${failed_profile}/runtime/Dockerfile" \
    || fail "failed activation changed the runtime Dockerfile"
assert_no_staging "${failed_profile}"
[[ ! -e "${DOCKER_CALLED}" ]] || fail "runtime add invoked Docker"

"${ROOT}/scripts/build-release" "${TMP}/release" >/dev/null
version="$(tr -d '\r\n' < "${ROOT}/VERSION")"
tar -xzf "${TMP}/release/pi-run-${version}.tar.gz" -C "${TMP}"
package="${TMP}/pi-run-${version}"
packaged_home="${TMP}/packaged-home"
PI_RUN_HOME="${packaged_home}" "${package}/bin/pi-run" init >/dev/null
PI_RUN_HOME="${packaged_home}" "${package}/bin/pi-run" runtime add all >/dev/null
cmp "${package}/templates/runtime/full-development.Dockerfile" \
    "${packaged_home}/profiles/default/runtime/Dockerfile" \
    || fail "packaged runtime add all differs from its maintained template"
cp "${packaged_home}/profiles/default/runtime/Dockerfile" "${TMP}/packaged.before"
printf '# malformed installed template\n' > \
    "${package}/templates/runtime/full-development.Dockerfile"
expect_failure env PI_RUN_HOME="${packaged_home}" "${package}/bin/pi-run" runtime add all
cmp "${TMP}/packaged.before" "${packaged_home}/profiles/default/runtime/Dockerfile" \
    || fail "unsafe installed bundle template changed the profile Dockerfile"

echo "runtime add tests passed"
