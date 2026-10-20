#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
HOME_DIR="${TMP}/Pi Run"
REPOSITORY="${TMP}/repository"
NON_GIT="${TMP}/ordinary directory"
DOCKER_LOG="${TMP}/docker.log"
COUNT_FILE="${TMP}/count"
CAPTURE_PREFIX="${TMP}/launch"

fail() {
    echo "worktree-default-test: $*" >&2
    exit 1
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "${DOCKER_LOG:?}"
printf '\n' >> "${DOCKER_LOG}"
case "${1:-}" in
    image)
        [[ "${2:-}" == inspect ]]
        ;;
    run)
        shift
        materialize=false
        workspace=
        common=
        pointer=
        base=
        previous=
        for argument in "$@"; do
            if [[ "${previous}" == --entrypoint && "${argument}" == bash ]]; then
                materialize=true
            elif [[ "${previous}" == --mount ]]; then
                case "${argument}" in
                    type=bind,src=*,dst=/workspace)
                        workspace="${argument#*src=}"
                        workspace="${workspace%,dst=*}"
                        ;;
                    type=bind,src=*,dst=/run/pi-run-git/common)
                        common="${argument#*src=}"
                        common="${common%,dst=*}"
                        ;;
                    type=bind,src=*,dst=/workspace/.git,readonly)
                        pointer="${argument#*src=}"
                        pointer="${pointer%,dst=*}"
                        ;;
                esac
            elif [[ "${previous}" == --env && "${argument}" == PI_RUN_WORKTREE_BASE=* ]]; then
                base="${argument#*=}"
            fi
            previous="${argument}"
        done
        [[ -n "${workspace}" ]] || exit 2
        if [[ "${materialize}" == true ]]; then
            [[ -n "${base}" ]] || exit 2
            git -C "${workspace}" -c core.hooksPath=/dev/null reset --hard "${base}" >/dev/null
            exit 0
        fi
        count=0
        [[ ! -f "${COUNT_FILE:?}" ]] || count="$(< "${COUNT_FILE}")"
        count=$((count + 1))
        printf '%s\n' "${count}" > "${COUNT_FILE}"
        if [[ -n "${pointer}" ]]; then
            [[ -f "${pointer}" && -n "${common}" ]] || exit 3
            home="${workspace%%/worktrees/*}"
            id="${workspace##*/}"
            [[ -f "${home}/worktrees/.launch-locks/${id}/owner.json" ]] || exit 4
        fi
        {
            printf 'workspace=%s\ncommon=%s\npointer=%s\n' "${workspace}" "${common}" "${pointer}"
            printf 'args='
            printf '%q ' "$@"
            printf '\n'
        } > "${CAPTURE_PREFIX:?}.${count}"
        ;;
    rm) ;;
    *) exit 2 ;;
esac
FAKE_DOCKER
chmod 0755 "${TMP}/fake-bin/docker"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
git init -q -b main "${REPOSITORY}"
git -C "${REPOSITORY}" config user.name fixture
git -C "${REPOSITORY}" config user.email fixture@pi-run.invalid
printf 'base\n' > "${REPOSITORY}/base.txt"
git -C "${REPOSITORY}" add base.txt
git -C "${REPOSITORY}" commit -qm base
mkdir "${NON_GIT}"
MACHINE="${HOME_DIR}/machines/$("${ROOT}/bin/pi-run" machine-id).json"
REGISTRY="${HOME_DIR}/workspaces/registry.json"

run_pi() {
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        PI_RUN_IMAGE=ghcr.io/aprilsoftware/pi-run:0.0.0-test \
        DOCKER_LOG="${DOCKER_LOG}" COUNT_FILE="${COUNT_FILE}" CAPTURE_PREFIX="${CAPTURE_PREFIX}" \
        "${ROOT}/bin/pi-run" "$@"
}

run_pi "${REPOSITORY}" --version >/dev/null 2>"${TMP}/unregistered.err"
grep -F "workspace=${REPOSITORY}" "${CAPTURE_PREFIX}.1" >/dev/null \
    || fail "unregistered repository did not preserve direct launch behavior"
[[ "$(jq -r '.schemaVersion' "${MACHINE}")" == 1 ]] \
    || fail "ordinary direct launch migrated schema-v1 machine metadata"
DIRECT_ID="$(jq -r --arg path "${REPOSITORY}" '.workspacePaths[] | select(.path == $path) | .workspaceId' "${MACHINE}")"

(
    cd "${REPOSITORY}"
    PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree enable >/dev/null
)
REPOSITORY_ID="$(jq -r '.repositories[0].id' "${MACHINE}")"
run_pi "${REPOSITORY}" --version >/dev/null 2>"${TMP}/enabled.err"
grep -F "workspace=${REPOSITORY}" "${CAPTURE_PREFIX}.2" >/dev/null \
    || fail "enabled repository preference changed an ordinary direct launch"
[[ "$(jq -r '.repositories[0].managedWorkspaces | length' "${MACHINE}")" == 0 ]] \
    || fail "enabled repository preference created an implicit managed workspace"
[[ "$(jq -r '.repositories[0].enabled' "${MACHINE}")" == true ]] \
    || fail "ordinary direct launch changed the transitional repository preference"

DIRECT_SESSION_DIR="${HOME_DIR}/profiles/default/sessions/${DIRECT_ID}"
mkdir -p "${DIRECT_SESSION_DIR}"
printf '{"type":"session","id":"direct","timestamp":"2026-10-20T12:00:00Z","cwd":"/workspace","version":1}\n' \
    > "${DIRECT_SESSION_DIR}/direct.jsonl"
run_pi "${REPOSITORY}" -c >/dev/null 2>"${TMP}/direct-continue.err"
grep -F "workspace=${REPOSITORY}" "${CAPTURE_PREFIX}.3" >/dev/null \
    || fail "enabled repository preference redirected direct continuation"
grep -F -- '-c' "${CAPTURE_PREFIX}.3" >/dev/null || fail "direct continuation did not preserve -c"
run_pi "${REPOSITORY}" -r >/dev/null 2>"${TMP}/direct-resume.err"
grep -F "workspace=${REPOSITORY}" "${CAPTURE_PREFIX}.4" >/dev/null \
    || fail "enabled repository preference redirected direct resume"

run_pi --worktree "${REPOSITORY}" --version >/dev/null 2>"${TMP}/explicit-enabled.err"
MANAGED_ID="$(jq -r '.repositories[0].managedWorkspaces[0].workspaceId' "${MACHINE}")"
MANAGED_PATH="${HOME_DIR}/worktrees/${REPOSITORY_ID}/${MANAGED_ID}"
grep -F "workspace=${MANAGED_PATH}" "${CAPTURE_PREFIX}.5" >/dev/null \
    || fail "explicit --worktree did not create a managed workspace"

SESSION_DIR="${HOME_DIR}/profiles/default/sessions/${MANAGED_ID}"
mkdir -p "${SESSION_DIR}"
printf '{"type":"session","id":"managed","timestamp":"2026-10-20T12:00:00Z","cwd":"/workspace","version":1}\n' \
    > "${SESSION_DIR}/managed.jsonl"
run_pi --worktree "${REPOSITORY}" -c >/dev/null 2>"${TMP}/managed-continue.err"
grep -F "workspace=${MANAGED_PATH}" "${CAPTURE_PREFIX}.6" >/dev/null \
    || fail "explicit --worktree continuation did not reopen the managed workspace"
grep -F -- '-c' "${CAPTURE_PREFIX}.6" >/dev/null || fail "managed continuation did not preserve -c"

run_pi --no-worktree "${REPOSITORY}" --version >/dev/null 2>"${TMP}/no-worktree.err"
grep -F "workspace=${REPOSITORY}" "${CAPTURE_PREFIX}.7" >/dev/null \
    || fail "--no-worktree did not preserve direct launch behavior"
grep -Fx 'common=' "${CAPTURE_PREFIX}.7" >/dev/null \
    || fail "--no-worktree unexpectedly used managed Git mounts"

(
    cd "${REPOSITORY}"
    PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree disable >/dev/null
)
run_pi --worktree "${REPOSITORY}" --version >/dev/null 2>"${TMP}/explicit-disabled.err"
[[ "$(jq -r '.repositories[0].managedWorkspaces | length' "${MACHINE}")" == 2 ]] \
    || fail "explicit --worktree depended on the transitional repository preference"
[[ "$(jq -r '.repositories[0].enabled' "${MACHINE}")" == false ]] \
    || fail "explicit --worktree changed the transitional repository preference"
run_pi "${REPOSITORY}" --version >/dev/null 2>"${TMP}/disabled.err"
grep -F "workspace=${REPOSITORY}" "${CAPTURE_PREFIX}.9" >/dev/null \
    || fail "ordinary launch stopped using the direct checkout"

(
    cd "${REPOSITORY}"
    PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" worktree enable >/dev/null
)
metadata_before="$(sha256sum "${MACHINE}" "${REGISTRY}")"
git_before="$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)"
docker_before="$(wc -l < "${DOCKER_LOG}")"
if run_pi --worktree --no-worktree "${REPOSITORY}" >/dev/null 2>"${TMP}/conflict.err"; then
    fail "conflicting worktree overrides were accepted"
fi
grep -F 'cannot be used together' "${TMP}/conflict.err" >/dev/null \
    || fail "conflicting-override diagnostic was unclear"
[[ "$(sha256sum "${MACHINE}" "${REGISTRY}")" == "${metadata_before}" &&
   "$(git -C "${REPOSITORY}" worktree list --porcelain | sha256sum)" == "${git_before}" &&
   "$(wc -l < "${DOCKER_LOG}")" == "${docker_before}" ]] \
    || fail "conflicting overrides changed metadata, Git, or Docker state"

run_pi "${NON_GIT}" --version >/dev/null 2>"${TMP}/non-git.err"
grep -F "workspace=${NON_GIT}" "${CAPTURE_PREFIX}.10" >/dev/null \
    || fail "non-Git directory did not remain a direct workspace"

echo "Worktree repository default tests passed"
