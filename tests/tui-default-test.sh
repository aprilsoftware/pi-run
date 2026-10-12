#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "tui-default-test: $*" >&2
    exit 1
}

assert_tui_pair() {
    local expected="$1"
    awk -v expected="${expected}" '
        previous == "--tui-mode" && $0 == expected { found = 1 }
        { previous = $0 }
        END { exit(found ? 0 : 1) }
    ' "${DOCKER_LOG}" || fail "missing --tui-mode ${expected}"
}

assert_no_tui_argument() {
    if grep -Eq '^--tui-mode($|=)' "${DOCKER_LOG}"; then
        fail "launcher supplied an unexpected TUI mode"
    fi
}

launch() {
    PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
        "${ROOT}/bin/pi-run" "${WORKSPACE}" "$@" >/dev/null 2>&1
}

HOME_DIR="${TMP}/Pi Run"
WORKSPACE="${TMP}/workspace"
mkdir -p "${WORKSPACE}" "${TMP}/fake-bin"

PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null

cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
: > "${DOCKER_LOG:?}"
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${DOCKER_LOG}"
done
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log"

# With no Pi or settings override, Pi-Run supplies its container-friendly default.
launch
assert_tui_pair regular
[[ "$(grep -Fxc -- '--tui-mode' "${DOCKER_LOG}")" -eq 1 ]] \
    || fail "default TUI mode was supplied more than once"

# Forwarded Pi arguments remain authoritative in either supported syntax.
launch --tui-mode fullscreen
assert_tui_pair fullscreen
[[ "$(grep -Fxc -- '--tui-mode' "${DOCKER_LOG}")" -eq 1 ]] \
    || fail "explicit TUI mode was duplicated"

launch --tui-mode=fullscreen
grep -Fx -- '--tui-mode=fullscreen' "${DOCKER_LOG}" >/dev/null \
    || fail "equals-form TUI mode was not forwarded"
[[ "$(grep -Ec '^--tui-mode($|=)' "${DOCKER_LOG}")" -eq 1 ]] \
    || fail "equals-form TUI mode was duplicated"

# A profile preference saved by Pi suppresses the launcher default.
printf '%s\n' '{"tuiMode":"fullscreen"}' > "${HOME_DIR}/profiles/default/settings.json"
launch
assert_no_tui_argument

# Project settings are also left for Pi to resolve.
rm "${HOME_DIR}/profiles/default/settings.json"
mkdir -p "${WORKSPACE}/.pi"
printf '%s\n' '{"tuiMode":"fullscreen"}' > "${WORKSPACE}/.pi/settings.json"
launch
assert_no_tui_argument

# Unrelated settings do not opt out of Pi-Run's default.
printf '%s\n' '{"theme":"system"}' > "${WORKSPACE}/.pi/settings.json"
launch
assert_tui_pair regular

echo "TUI default tests passed"
