#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="${ROOT}/experiments/docker-git-worktree/probe.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "docker-git-worktree-probe-test: $*" >&2
    exit 1
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s ' "$@" >> "${DOCKER_LOG:?}"
printf '\n' >> "${DOCKER_LOG}"
case "${1:-}" in
    image)
        [[ "${2:-}" == inspect && "${TEST_IMAGE_FAIL:-0}" == 0 ]]
        ;;
    run)
        shift
        detached=false
        common=false
        worktree=
        branch=
        file=
        while (( $# > 0 )); do
            case "$1" in
                -d) detached=true; shift ;;
                --mount)
                    value="$2"
                    case "$value" in
                        type=bind,src=*,dst=/workspace)
                            worktree="${value#*src=}"
                            worktree="${worktree%,dst=*}"
                            ;;
                        type=bind,src=*,dst=/run/pi-run-git/common) common=true ;;
                    esac
                    shift 2
                    ;;
                --env)
                    case "$2" in
                        PI_RUN_PROBE_BRANCH=*) branch="${2#*=}" ;;
                        PI_RUN_PROBE_FILE=*) file="${2#*=}" ;;
                    esac
                    shift 2
                    ;;
                *) shift ;;
            esac
        done
        [[ -n "$worktree" ]] || exit 2
        if [[ -n "${STATE_PATH_FILE:-}" && ! -e "${STATE_PATH_FILE}" ]]; then
            dirname "$worktree" > "${STATE_PATH_FILE}"
        fi
        if [[ "$common" != true ]]; then
            echo 'fatal: not a git repository: unavailable linked Git directory' >&2
            exit 128
        fi
        if [[ "$detached" == true ]]; then
            echo fake-container-id
            exit 0
        fi
        [[ -n "$branch" && -n "$file" ]] || exit 2
        printf '%s\n' "$branch" > "${worktree}/${file}"
        git -C "$worktree" add "$file"
        git -C "$worktree" commit -qm "probe ${branch}"
        ;;
    inspect)
        echo true
        ;;
    rm) ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

export DOCKER_LOG="${TMP}/docker.log"
export STATE_PATH_FILE="${TMP}/state-path"
output="$(PATH="${TMP}/fake-bin:${PATH}" "$PROBE" --execute)"
[[ "$output" == *'PASS blocked: linked worktree without common Git metadata'* ]] \
    || fail "probe did not prove the baseline failure"
[[ "$output" == *'PASS: independent worktree files, indexes, branches, and shared refs'* ]] \
    || fail "probe did not prove worktree independence"
[[ "$output" == *'PASS: concurrent worktree status containers'* ]] \
    || fail "probe did not exercise concurrent containers"
[[ "$output" == *'docker-git-worktree-probe: PASS'* ]] \
    || fail "successful probe did not pass"

for option in '--pull never' '--network none' '--cap-drop ALL' \
    '--security-opt no-new-privileges=true' '--read-only' '--user' '--workdir /workspace'; do
    grep -F -- "$option" "$DOCKER_LOG" >/dev/null \
        || fail "probe omitted Docker isolation option: ${option}"
done
grep -F 'dst=/run/pi-run-git/common' "$DOCKER_LOG" >/dev/null \
    || fail "common Git metadata was not mounted"
grep -F 'dst=/workspace/.git,readonly' "$DOCKER_LOG" >/dev/null \
    || fail "generated .git pointer was not mounted read-only"
[[ "$(grep -c '^run -d ' "$DOCKER_LOG")" -eq 2 ]] \
    || fail "probe did not start two concurrent status containers"
grep -F 'rm -f pirun-worktree-a-' "$DOCKER_LOG" >/dev/null \
    || fail "probe did not clean up containers"
if grep -E '(^| )(--network host|pull |build |/var/run/docker.sock|/run/docker.sock)' "$DOCKER_LOG" >/dev/null; then
    fail "probe used a forbidden Docker operation or mount"
fi
for contract in \
    'gitdir: /run/pi-run-git/common/worktrees/%s' \
    'linked worktree unexpectedly worked without common Git metadata' \
    'test ! -e /workspace/primary-untracked' \
    'managed-worktree commit changed the primary branch'; do
    grep -F "$contract" "$PROBE" >/dev/null || fail "missing probe contract: ${contract}"
done
[[ -s "$STATE_PATH_FILE" && ! -e "$(< "$STATE_PATH_FILE")" ]] \
    || fail "temporary Git state was not cleaned up"

: > "$DOCKER_LOG"
set +e
PATH="${TMP}/fake-bin:${PATH}" TEST_IMAGE_FAIL=1 "$PROBE" --execute >/dev/null 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail "probe accepted an unavailable runtime image"
grep -F 'image inspect ghcr.io/aprilsoftware/pi-run:' "$DOCKER_LOG" >/dev/null \
    || fail "probe did not inspect the local version-matched image"

set +e
"$PROBE" >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 2 ]] || fail "probe ran without explicit execution approval"

echo "Docker Git-worktree probe test passed"
