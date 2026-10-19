#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

usage() {
    echo "Usage: experiments/docker-git-worktree/probe.sh --execute"
}

[[ $# -eq 1 && "$1" == --execute ]] || {
    usage >&2
    exit 2
}
for command_name in docker git; do
    command -v "${command_name}" >/dev/null 2>&1 || {
        echo "docker-git-worktree-probe: required command unavailable: ${command_name}" >&2
        exit 1
    }
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="$(tr -d '\r\n' < "${ROOT}/VERSION")"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "docker-git-worktree-probe: invalid VERSION" >&2
    exit 1
}
IMAGE="${PI_RUN_WORKTREE_IMAGE:-ghcr.io/aprilsoftware/pi-run:${VERSION}}"
STATE="$(mktemp -d)"
REPOSITORY="${STATE}/repository"
WORKTREE_A="${STATE}/worktree-a"
WORKTREE_B="${STATE}/worktree-b"
DOT_GIT_A="${STATE}/dot-git-a"
DOT_GIT_B="${STATE}/dot-git-b"
CONTROL_WORKTREE="${STATE}/control-worktree"
HOST_HOOK_MARKER="${STATE}/host-hook-marker"
SUFFIX="$(date +%s)-$$"
CONTAINER_A="pirun-worktree-a-${SUFFIX}"
CONTAINER_B="pirun-worktree-b-${SUFFIX}"

cleanup() {
    docker rm -f "${CONTAINER_A}" "${CONTAINER_B}" >/dev/null 2>&1 || true
    rm -rf "${STATE}"
}
trap cleanup EXIT

fail() {
    echo "docker-git-worktree-probe: FAIL: $*" >&2
    exit 1
}

docker image inspect "${IMAGE}" >/dev/null 2>&1 \
    || fail "runtime image is unavailable locally: ${IMAGE}"

git init -q -b main "${REPOSITORY}"
git -C "${REPOSITORY}" config user.name "Pi-Run worktree probe"
git -C "${REPOSITORY}" config user.email "probe@pi-run.invalid"
printf 'base\n' > "${REPOSITORY}/base.txt"
printf 'filtered source\n' > "${REPOSITORY}/filtered.txt"
printf 'filtered.txt filter=probe\n' > "${REPOSITORY}/.gitattributes"
git -C "${REPOSITORY}" config filter.probe.clean cat
git -C "${REPOSITORY}" config filter.probe.smudge \
    "sh -c 'printf \"filter ran\\n\" > filter-marker; cat'"
git -C "${REPOSITORY}" config filter.probe.required true
git -C "${REPOSITORY}" add base.txt filtered.txt .gitattributes
git -C "${REPOSITORY}" commit -qm base
cat > "${REPOSITORY}/.git/hooks/post-checkout" <<EOF
#!/bin/sh
printf 'host hook ran\n' > '${HOST_HOOK_MARKER}'
printf 'hook ran\n' > hook-marker
EOF
chmod 0755 "${REPOSITORY}/.git/hooks/post-checkout"

# Establish that an ordinary host checkout would execute repository-controlled code.
git -C "${REPOSITORY}" worktree add -q -b probe-control "${CONTROL_WORKTREE}" main
[[ -f "${HOST_HOOK_MARKER}" && -f "${CONTROL_WORKTREE}/hook-marker" &&
   -f "${CONTROL_WORKTREE}/filter-marker" ]] \
    || fail "ordinary worktree creation did not execute the control hook and filter"
git -C "${REPOSITORY}" worktree remove --force "${CONTROL_WORKTREE}"
git -C "${REPOSITORY}" branch -D probe-control >/dev/null
rm -f "${HOST_HOOK_MARKER}"
echo "PASS control: ordinary host checkout invoked its hook and filter"

BASE_COMMIT="$(git -C "${REPOSITORY}" rev-parse 'main^{commit}')"
git -C "${REPOSITORY}" worktree add --no-checkout -q -b probe-a "${WORKTREE_A}" "${BASE_COMMIT}"
git -C "${REPOSITORY}" worktree add --no-checkout -q -b probe-b "${WORKTREE_B}" "${BASE_COMMIT}"
[[ ! -e "${HOST_HOOK_MARKER}" && ! -e "${WORKTREE_A}/hook-marker" &&
   ! -e "${WORKTREE_A}/filter-marker" && ! -e "${WORKTREE_B}/hook-marker" &&
   ! -e "${WORKTREE_B}/filter-marker" ]] \
    || fail "--no-checkout executed repository-controlled checkout code on the host"
echo "PASS blocked: --no-checkout host hook and filter execution"

COMMON_DIR="$(git -C "${WORKTREE_A}" rev-parse --path-format=absolute --git-common-dir)"
GIT_DIR_A="$(git -C "${WORKTREE_A}" rev-parse --path-format=absolute --git-dir)"
GIT_DIR_B="$(git -C "${WORKTREE_B}" rev-parse --path-format=absolute --git-dir)"
[[ "${COMMON_DIR}" == "${REPOSITORY}/.git" ]] \
    || fail "unexpected common Git directory: ${COMMON_DIR}"
for git_dir in "${GIT_DIR_A}" "${GIT_DIR_B}"; do
    [[ "${git_dir}" == "${COMMON_DIR}/worktrees/"* && -d "${git_dir}" && ! -L "${git_dir}" ]] \
        || fail "unsafe linked-worktree Git directory: ${git_dir}"
done
for dot_git in "${WORKTREE_A}/.git" "${WORKTREE_B}/.git"; do
    [[ -f "${dot_git}" && ! -L "${dot_git}" ]] \
        || fail "linked worktree has an unsafe .git pointer: ${dot_git}"
done

printf 'gitdir: /run/pi-run-git/common/worktrees/%s\n' "$(basename "${GIT_DIR_A}")" > "${DOT_GIT_A}"
printf 'gitdir: /run/pi-run-git/common/worktrees/%s\n' "$(basename "${GIT_DIR_B}")" > "${DOT_GIT_B}"
chmod 0600 "${DOT_GIT_A}" "${DOT_GIT_B}"

base_args=(
    --rm
    --pull never
    --network none
    --cap-drop ALL
    --security-opt no-new-privileges=true
    --read-only
    --tmpfs "/tmp:rw,nosuid,nodev,noexec"
    --user "$(id -u):$(id -g)"
    --env HOME=/tmp
    --workdir /workspace
    --entrypoint bash
)

set +e
baseline_output="$(docker run "${base_args[@]}" \
    --mount "type=bind,src=${WORKTREE_A},dst=/workspace" \
    "${IMAGE}" -ceu 'git status --porcelain' 2>&1)"
baseline_status=$?
set -e
(( baseline_status != 0 )) || fail "linked worktree unexpectedly worked without common Git metadata"
[[ "${baseline_output}" == *"not a git repository"* || "${baseline_output}" == *"No such file"* ]] \
    || fail "baseline failure did not identify unavailable Git metadata"
echo "PASS blocked: linked worktree without common Git metadata"

materialize_worktree() {
    local worktree="$1" dot_git="$2" branch="$3"
    docker run "${base_args[@]}" \
        --mount "type=bind,src=${worktree},dst=/workspace" \
        --mount "type=bind,src=${COMMON_DIR},dst=/run/pi-run-git/common" \
        --mount "type=bind,src=${dot_git},dst=/workspace/.git,readonly" \
        --env PI_RUN_PROBE_MATERIALIZE=1 \
        --env "PI_RUN_PROBE_BRANCH=${branch}" \
        --env "PI_RUN_PROBE_COMMIT=${BASE_COMMIT}" \
        "${IMAGE}" -ceu '
            test "$(git branch --show-current)" = "${PI_RUN_PROBE_BRANCH}"
            git -c core.hooksPath=/dev/null reset --hard "${PI_RUN_PROBE_COMMIT}" >/dev/null
            test "$(git rev-parse HEAD)" = "${PI_RUN_PROBE_COMMIT}"
            test "$(cat filtered.txt)" = "filtered source"
            test -f filter-marker
            test ! -e hook-marker
        ' >/dev/null
}

materialize_worktree "${WORKTREE_A}" "${DOT_GIT_A}" probe-a
materialize_worktree "${WORKTREE_B}" "${DOT_GIT_B}" probe-b
[[ ! -e "${HOST_HOOK_MARKER}" && -f "${WORKTREE_A}/filter-marker" &&
   -f "${WORKTREE_B}/filter-marker" && ! -e "${WORKTREE_A}/hook-marker" &&
   ! -e "${WORKTREE_B}/hook-marker" ]] \
    || fail "isolated materialization did not confine checkout code"
echo "PASS: offline container materialization with hooks disabled and filters confined"

printf 'primary only\n' > "${REPOSITORY}/primary-untracked"
printf 'worktree A only\n' > "${WORKTREE_A}/a-untracked"
printf 'worktree B only\n' > "${WORKTREE_B}/b-untracked"

run_commit_probe() {
    local worktree="$1" dot_git="$2" branch="$3" own_marker="$4" other_marker="$5" file="$6"
    docker run "${base_args[@]}" \
        --mount "type=bind,src=${worktree},dst=/workspace" \
        --mount "type=bind,src=${COMMON_DIR},dst=/run/pi-run-git/common" \
        --mount "type=bind,src=${dot_git},dst=/workspace/.git,readonly" \
        --env "PI_RUN_PROBE_BRANCH=${branch}" \
        --env "PI_RUN_PROBE_OWN_MARKER=${own_marker}" \
        --env "PI_RUN_PROBE_OTHER_MARKER=${other_marker}" \
        --env "PI_RUN_PROBE_FILE=${file}" \
        "${IMAGE}" -ceu '
            test "$(git branch --show-current)" = "${PI_RUN_PROBE_BRANCH}"
            test -f "${PI_RUN_PROBE_OWN_MARKER}"
            test ! -e "${PI_RUN_PROBE_OTHER_MARKER}"
            test ! -e /workspace/primary-untracked
            printf "%s\n" "${PI_RUN_PROBE_BRANCH}" > "${PI_RUN_PROBE_FILE}"
            git add "${PI_RUN_PROBE_FILE}"
            git commit -qm "probe ${PI_RUN_PROBE_BRANCH}"
        ' >/dev/null
}

run_commit_probe "${WORKTREE_A}" "${DOT_GIT_A}" probe-a a-untracked b-untracked a.txt
run_commit_probe "${WORKTREE_B}" "${DOT_GIT_B}" probe-b b-untracked a-untracked b.txt

git -C "${REPOSITORY}" show probe-a:a.txt | grep -Fx probe-a >/dev/null \
    || fail "worktree A commit is absent from shared Git metadata"
git -C "${REPOSITORY}" show probe-b:b.txt | grep -Fx probe-b >/dev/null \
    || fail "worktree B commit is absent from shared Git metadata"
if git -C "${REPOSITORY}" cat-file -e main:a.txt 2>/dev/null ||
   git -C "${REPOSITORY}" cat-file -e main:b.txt 2>/dev/null; then
    fail "a managed-worktree commit changed the primary branch"
fi
[[ ! -e "${WORKTREE_A}/b.txt" && ! -e "${WORKTREE_B}/a.txt" ]] \
    || fail "worktree files crossed checkout boundaries"
echo "PASS: independent worktree files, indexes, branches, and shared refs"

start_status_container() {
    local name="$1" worktree="$2" dot_git="$3" branch="$4"
    docker run -d "${base_args[@]:1}" \
        --name "${name}" \
        --mount "type=bind,src=${worktree},dst=/workspace" \
        --mount "type=bind,src=${COMMON_DIR},dst=/run/pi-run-git/common" \
        --mount "type=bind,src=${dot_git},dst=/workspace/.git,readonly" \
        --env "PI_RUN_PROBE_BRANCH=${branch}" \
        "${IMAGE}" -ceu '
            test "$(git branch --show-current)" = "${PI_RUN_PROBE_BRANCH}"
            git status --porcelain >/dev/null
            exec sleep 60
        ' >/dev/null
}

start_status_container "${CONTAINER_A}" "${WORKTREE_A}" "${DOT_GIT_A}" probe-a
start_status_container "${CONTAINER_B}" "${WORKTREE_B}" "${DOT_GIT_B}" probe-b
[[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_A}")" == true ]] \
    || fail "worktree A status container is not running"
[[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_B}")" == true ]] \
    || fail "worktree B status container is not running"
echo "PASS: concurrent worktree status containers"

echo "docker-git-worktree-probe: PASS"
