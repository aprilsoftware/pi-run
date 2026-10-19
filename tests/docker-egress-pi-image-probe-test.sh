#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="${ROOT}/experiments/docker-egress/pi-image-probe.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "docker-egress-pi-image-probe-test: $*" >&2
    exit 1
}

mkdir -p "${TMP}/fake-bin"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
case "$1" in
    build)
        [[ "${TEST_BUILD_FAIL:-0}" == 0 ]]
        ;;
    run)
        workspace=
        profile=
        for arg in "$@"; do
            case "$arg" in
                type=bind,src=*,dst=/workspace) workspace="${arg#*src=}"; workspace="${workspace%,dst=*}" ;;
                type=bind,src=*,dst=/profile) profile="${arg#*src=}"; profile="${profile%,dst=*}" ;;
            esac
        done
        if [[ -n "$workspace" ]]; then
            printf '%s\n' "$(dirname "$workspace")" > "${STATE_PATH_FILE:?}"
            printf 'fake pi version\n' > "${workspace}/pi-version.txt"
            printf '%s:%s\n' "$(id -u)" "$(id -g)" > "${workspace}/runtime-identity"
            touch "${workspace}/entrypoint-ready"
            printf 'profile writable\n' > "${profile}/profile-marker"
            mkdir -p "${profile}/sessions/pi-egress-probe"
            printf 'session writable\n' > "${profile}/sessions/pi-egress-probe/session-marker"
        fi
        echo fake-container-id
        ;;
    exec)
        case "$*" in
            *example.org*|*1.1.1.1*) exit 1 ;;
            *example.com*) [[ ! -e "${SIDECAR_KILLED:?}" ]] ;;
            *) exit 0 ;;
        esac
        ;;
    inspect) echo true ;;
    kill) : > "${SIDECAR_KILLED:?}" ;;
    rm|logs) ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"

export DOCKER_LOG="${TMP}/docker.log"
export SIDECAR_KILLED="${TMP}/sidecar-killed"
export STATE_PATH_FILE="${TMP}/state-path"
output="$(PATH="${TMP}/fake-bin:${PATH}" "$PROBE" --execute)"
[[ "$output" == *'docker-egress-pi-image-probe: PASS'* ]] || fail "successful probe did not pass"
grep -F 'build -t pi-run:egress-pi-test' "$DOCKER_LOG" >/dev/null \
    || fail "current Pi-Run image was not built"
grep -F 'build --target sidecar' "$DOCKER_LOG" >/dev/null \
    || fail "sidecar image was not built"
grep -F -- '--network container:pirun-pi-egress-' "$DOCKER_LOG" >/dev/null \
    || fail "Pi-Run image did not share the sidecar namespace"
grep -F -- '--entrypoint /usr/local/bin/entrypoint.sh' "$DOCKER_LOG" >/dev/null \
    || fail "Pi-Run entrypoint was not used"
for capability in CHOWN SETUID SETGID DAC_READ_SEARCH; do
    grep -F -- "--cap-add ${capability}" "$DOCKER_LOG" >/dev/null \
        || fail "Pi-Run image lacked ${capability}"
done
grep -F -- '--cap-drop ALL' "$DOCKER_LOG" >/dev/null || fail "capabilities were not dropped"
grep -F 'dst=/workspace' "$DOCKER_LOG" >/dev/null || fail "workspace was not mounted"
grep -F 'dst=/profile' "$DOCKER_LOG" >/dev/null || fail "selected profile was not mounted"
grep -F -- '-e NODE_USE_ENV_PROXY=1' "$DOCKER_LOG" >/dev/null \
    || fail "Node environment proxy support was not exercised"
grep -F 'node --input-type=module -e' "$DOCKER_LOG" >/dev/null \
    || fail "Node fetch was not exercised"
for contract in 'pi --version' "/profile/sessions/\${PI_RUN_PROBE_SESSION_ID}" \
    'test ! -e /policy' 'CapEff:' 'expect_blocked "unlisted hostname"' \
    'expect_blocked "direct public IP"'; do
    grep -F "$contract" "$PROBE" >/dev/null || fail "missing runtime check: ${contract}"
done
grep -F 'kill pirun-pi-egress-' "$DOCKER_LOG" >/dev/null || fail "fail-closed behavior was not tested"
grep -F 'rm -f pirun-pi-workload-' "$DOCKER_LOG" >/dev/null || fail "containers were not cleaned up"
[[ ! -e "$(< "$STATE_PATH_FILE")" ]] || fail "temporary state was not cleaned up"
if grep -F -- '--network host' "$DOCKER_LOG" >/dev/null; then
    fail "probe used host networking"
fi

: > "$DOCKER_LOG"
rm -f "$SIDECAR_KILLED"
set +e
PATH="${TMP}/fake-bin:${PATH}" TEST_BUILD_FAIL=1 "$PROBE" --execute >/dev/null 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail "probe accepted a failed image build"
grep -F 'rm -f pirun-pi-workload-' "$DOCKER_LOG" >/dev/null \
    || fail "failed probe did not attempt cleanup"

set +e
"$PROBE" >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 2 ]] || fail "probe ran without explicit execution approval"

echo "Docker egress Pi image probe test passed"
