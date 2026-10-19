#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
REPOSITORY="${TMP}/repository"

fail() {
    echo "worktree-preference-test: $*" >&2
    exit 1
}

run_worktree() {
    local directory="$1"
    shift
    (cd "${directory}" && PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree "$@")
}

expect_failure() {
    local status
    set +e
    "$@" >/dev/null 2>&1
    status=$?
    set -e
    [[ ${status} -ne 0 ]] || fail "command unexpectedly succeeded: $*"
}

repository_state() {
    local repository="$1"
    printf '%s\n' "$(git -C "${repository}" rev-parse HEAD)"
    git -C "${repository}" show-ref | LC_ALL=C sort
    git -C "${repository}" status --porcelain=v1
    sha256sum "${repository}/.git/index"
}

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
git init -q -b main "${REPOSITORY}"
git -C "${REPOSITORY}" config user.name fixture
git -C "${REPOSITORY}" config user.email fixture@pi-run.invalid
git -C "${REPOSITORY}" remote add origin https://example.invalid/shared.git
printf 'base\n' > "${REPOSITORY}/base.txt"
git -C "${REPOSITORY}" add base.txt
git -C "${REPOSITORY}" commit -qm base
state_before="$(repository_state "${REPOSITORY}")"

status_output="$(run_worktree "${REPOSITORY}" status)"
[[ "${status_output}" == *'Repository: repository'* &&
   "${status_output}" == *'Repository ID: -'* &&
   "${status_output}" == *'Worktree mode: disabled (not registered)'* &&
   "${status_output}" == *"Primary checkout: ${REPOSITORY}"* ]] \
    || fail "unregistered status output is incomplete"
machine="$(find "${HOME_DIR}/machines" -maxdepth 1 -type f -name '*.json' -print -quit)"
[[ -f "${machine}" && "$(jq -r '.schemaVersion' "${machine}")" == 2 ]] \
    || fail "worktree status did not prepare schema-v2 machine metadata"
[[ ! -e "${HOME_DIR}/worktrees" ]] || fail "status created a managed worktree root"

output="$(run_worktree "${REPOSITORY}" enable)"
[[ "${output}" == *'Worktree mode: enabled'* &&
   "${output}" == *'Preference updated; existing workspaces and sessions are unchanged.'* ]] \
    || fail "enable output is incomplete"
repository_id="$(jq -r '.repositories[0].id' "${machine}")"
created_at="$(jq -r '.repositories[0].createdAt' "${machine}")"
[[ "${repository_id}" =~ ^[0-9a-f-]{36}$ &&
   "$(jq -r '.repositories | length' "${machine}")" == 1 ]] \
    || fail "enable did not register exactly one repository"
jq -e --arg common "${REPOSITORY}/.git" --arg primary "${REPOSITORY}" '
    .repositories[0].commonGitDir == $common and
    .repositories[0].primaryPath == $primary and
    .repositories[0].enabled == true and
    .repositories[0].managedWorkspaces == []
' "${machine}" >/dev/null || fail "registered repository metadata is incorrect"
[[ ! -e "${HOME_DIR}/worktrees" ]] || fail "enable created a managed worktree root"
[[ "$(repository_state "${REPOSITORY}")" == "${state_before}" ]] \
    || fail "preference commands changed Git state"

inode="$(stat -c %i "${machine}")"
output="$(run_worktree "${REPOSITORY}" enable)"
[[ "${output}" == *'Preference unchanged.'* && "$(stat -c %i "${machine}")" == "${inode}" ]] \
    || fail "repeated enable was not idempotent"
mkdir "${REPOSITORY}/subdirectory"
status_output="$(run_worktree "${REPOSITORY}/subdirectory" status)"
[[ "${status_output}" == *"Repository ID: ${repository_id}"* &&
   "${status_output}" == *'Worktree mode: enabled'* ]] \
    || fail "subdirectory did not resolve the registered repository"

LINKED="${TMP}/linked-worktree"
git -C "${REPOSITORY}" worktree add -q -b linked-test "${LINKED}" main
status_output="$(run_worktree "${LINKED}" status)"
[[ "${status_output}" == *"Repository ID: ${repository_id}"* &&
   "${status_output}" == *"Primary checkout: ${REPOSITORY}"* ]] \
    || fail "linked worktree did not resolve its primary repository"
run_worktree "${LINKED}" disable >/dev/null
[[ "$(jq -r '.repositories[0].enabled' "${machine}")" == false ]] \
    || fail "disable did not update the repository preference"
inode="$(stat -c %i "${machine}")"
output="$(run_worktree "${REPOSITORY}" disable)"
[[ "${output}" == *'Preference unchanged.'* && "$(stat -c %i "${machine}")" == "${inode}" ]] \
    || fail "repeated disable was not idempotent"
run_worktree "${REPOSITORY}" enable >/dev/null
[[ "$(jq -r '.repositories[0].id' "${machine}")" == "${repository_id}" &&
   "$(jq -r '.repositories[0].createdAt' "${machine}")" == "${created_at}" ]] \
    || fail "re-enable replaced repository identity"

CLONE="${TMP}/clone"
git clone -q "${REPOSITORY}" "${CLONE}"
git -C "${CLONE}" remote set-url origin https://example.invalid/shared.git
run_worktree "${CLONE}" enable >/dev/null
[[ "$(jq -r '.repositories | length' "${machine}")" == 2 &&
   "$(jq -r '.repositories[1].id' "${machine}")" != "${repository_id}" ]] \
    || fail "a separate clone reused repository identity"

mkdir "${TMP}/not-git"
expect_failure run_worktree "${TMP}/not-git" status
git init -q --bare "${TMP}/bare.git"
expect_failure run_worktree "${TMP}/bare.git" status
mkdir "${TMP}/separate" "${TMP}/separate-git"
rmdir "${TMP}/separate-git"
git init -q --separate-git-dir="${TMP}/separate-git" "${TMP}/separate"
expect_failure run_worktree "${TMP}/separate" status
git init -q "${TMP}/linked-git"
mv "${TMP}/linked-git/.git" "${TMP}/linked-git-metadata"
ln -s ../linked-git-metadata "${TMP}/linked-git/.git"
expect_failure run_worktree "${TMP}/linked-git" status

before="$(sha256sum "${machine}")"
jq '.repositories += [(.repositories[0] | .id="44444444-4444-4444-8444-444444444444")]' \
    "${machine}" > "${machine}.tmp"
mv "${machine}.tmp" "${machine}"
chmod 0600 "${machine}"
malformed="$(sha256sum "${machine}")"
expect_failure run_worktree "${REPOSITORY}" enable
[[ "$(sha256sum "${machine}")" == "${malformed}" && "${before}" != "${malformed}" ]] \
    || fail "conflicting metadata was changed after rejection"

expect_failure run_worktree "${REPOSITORY}" invalid

echo "Worktree preference tests passed"
