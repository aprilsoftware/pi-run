#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
    echo "snapshot-extension-test: $*" >&2
    exit 1
}

PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || fail "Pi package is unavailable"
REQUEST_DIR="${TMP}/extension-request"
mkdir -m 0700 "${REQUEST_DIR}"
TOKEN=11111111-1111-4111-8111-111111111111
PI_RUN_SNAPSHOT_REQUEST_DIR="${REQUEST_DIR}" PI_RUN_SNAPSHOT_TOKEN="${TOKEN}" \
node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" "${REQUEST_DIR}" "${TOKEN}" <<'NODE'
import assert from 'node:assert/strict';
import { chmod, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [root, piDir, requestDir, token] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const alias = Object.fromEntries(['pi-agent-core', 'pi-tui'].map(name => [
  `@earendil-works/${name}`, join(piDir, 'node_modules', '@earendil-works', name, 'dist', 'index.js'),
]));
alias['@earendil-works/pi-coding-agent'] = join(piDir, 'dist', 'index.js');
const extensionPath = join(root, 'docker', 'extensions', 'snapshot-agent.ts');
const module = await createJiti(import.meta.url, { alias, fsCache: false }).import(extensionPath);
const { loadExtensions } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'extensions', 'loader.js')).href);
const loaded = await loadExtensions([extensionPath], root);
assert.deepEqual(loaded.errors, []);
assert.equal(loaded.extensions.length, 1);
assert.ok(loaded.extensions[0].commands.has('snapshot'));
assert.equal(loaded.extensions[0].tools.size, 0);
const commands = new Map();
module.default({ registerCommand: (name, definition) => commands.set(name, definition) });
assert.equal(commands.size, 1);
assert.ok(commands.has('snapshot'));
const command = commands.get('snapshot');

const sessionId = '22222222-2222-4222-8222-222222222222';
const sessionDir = join(requestDir, '..', 'sessions');
const savedSessionFile = join(sessionDir, 'pirun.jsonl');
await mkdir(sessionDir);
await writeFile(savedSessionFile, '{}\n');
async function invoke(choice, confirmation = true, mode = 'tui', sessionFile = savedSessionFile) {
  const notices = [];
  let shutdowns = 0;
  await command.handler('', {
    mode,
    sessionManager: {
      getSessionFile: () => sessionFile,
      getSessionId: () => sessionId,
    },
    ui: {
      select: async () => choice,
      confirm: async () => confirmation,
      notify: (message, kind) => notices.push({ message, kind }),
    },
    shutdown: () => { shutdowns += 1; },
  });
  return { notices, shutdowns };
}

let result = await invoke('Status');
assert.equal(result.shutdowns, 1);
assert.deepEqual(JSON.parse(await readFile(join(requestDir, 'request.json'), 'utf8')), {
  schemaVersion: 3, token, action: 'status', resumeSessionId: sessionId,
  resumeSessionFile: 'pirun.jsonl',
});
assert.ok(result.notices.some(n => n.message.includes('reopen this session')));
assert.deepEqual(await readdir(requestDir), ['request.json']);
await rm(join(requestDir, 'request.json'));

result = await invoke('Create complete snapshot', false);
assert.equal(result.shutdowns, 0);
assert.deepEqual(await readdir(requestDir), []);
result = await invoke('Create complete snapshot', true);
assert.equal(result.shutdowns, 1);
assert.equal(JSON.parse(await readFile(join(requestDir, 'request.json'), 'utf8')).action, 'create');
await rm(join(requestDir, 'request.json'));

result = await invoke('Run full integrity check', true);
assert.equal(result.shutdowns, 1);
assert.equal(JSON.parse(await readFile(join(requestDir, 'request.json'), 'utf8')).action, 'check');
await rm(join(requestDir, 'request.json'));
result = await invoke('List snapshots');
assert.equal(JSON.parse(await readFile(join(requestDir, 'request.json'), 'utf8')).action, 'list');
await rm(join(requestDir, 'request.json'));
result = await invoke('Status', true, 'tui', join(sessionDir, 'not-yet-saved.jsonl'));
const unsavedSessionRequest = JSON.parse(await readFile(join(requestDir, 'request.json'), 'utf8'));
assert.equal(unsavedSessionRequest.resumeSessionId, null);
assert.equal(unsavedSessionRequest.resumeSessionFile, null);
assert.ok(result.notices.some(n => n.message.includes('restart with a fresh session')));
await rm(join(requestDir, 'request.json'));
result = await invoke('Status', true, 'tui', null);
const nonPersistentRequest = JSON.parse(await readFile(join(requestDir, 'request.json'), 'utf8'));
assert.equal(nonPersistentRequest.resumeSessionId, null);
assert.equal(nonPersistentRequest.resumeSessionFile, null);
assert.ok(result.notices.some(n => n.message.includes('restart with a fresh session')));
await rm(join(requestDir, 'request.json'));
const badSessionFile = join(sessionDir, 'bad\\name.jsonl');
await writeFile(badSessionFile, '{}\n');
result = await invoke('Status', true, 'tui', badSessionFile);
assert.equal(result.shutdowns, 0);
assert.ok(result.notices.some(n => n.kind === 'error'));
assert.deepEqual(await readdir(requestDir), []);
result = await invoke('Cancel');
assert.equal(result.shutdowns, 0);
result = await invoke('Status', true, 'json');
assert.equal(result.shutdowns, 0);
assert.ok(result.notices.some(n => n.kind === 'error'));

await chmod(requestDir, 0o700);
console.log('snapshot extension command tests passed');
NODE

mkdir -p "${TMP}/fake-bin" "${TMP}/workspace"
cat > "${TMP}/fake-bin/docker" <<'EOF'
#!/bin/sh
set -eu
[ "${1:-}" = run ] || exit 2
operation=
entrypoint=
request_dir=
token=
tagged=false
profile_dir=
session_dir=
restart_session=false
restart_session_path=
previous=
call="${DOCKER_LOG:?}.$$"
: > "${call}"
for argument in "$@"; do
    printf '%s\n' "${argument}" >> "${call}"
    case "${argument}" in
        init|snapshots|backup|check) operation=${argument} ;;
        type=bind,src=*,dst=/run/pi-run-snapshot) request_dir=${argument#type=bind,src=}; request_dir=${request_dir%,dst=/run/pi-run-snapshot} ;;
        type=bind,src=*,dst=/profile) profile_dir=${argument#type=bind,src=}; profile_dir=${profile_dir%,dst=/profile} ;;
        PI_RUN_SNAPSHOT_TOKEN=*) token=${argument#PI_RUN_SNAPSHOT_TOKEN=} ;;
        pi|restic) if [ "${previous}" = --entrypoint ]; then entrypoint=${argument}; fi ;;
    esac
    if [ "${previous}" = --tag ] && [ "${argument}" = pi-run ]; then tagged=true; fi
    if [ "${previous}" = --session-dir ]; then session_dir=${argument}; fi
    if [ "${previous}" = --session ]; then restart_session=true; restart_session_path=${argument}; fi
    previous=${argument}
done
printf '%s\n' '---' >> "${DOCKER_LOG}"
cat "${call}" >> "${DOCKER_LOG}"
if [ -z "${entrypoint}" ]; then
    printf '%s\n' '---' >> "${MAIN_LOG:?}"
    cat "${call}" >> "${MAIN_LOG}"
    rm -f "${call}"
    if [ "${restart_session}" = true ]; then
        flock -n -x "${SNAPSHOT_LOCK_PATH:?}" -c true \
            || { echo 'snapshot operation lock remained held during session restart' >&2; exit 91; }
        [ "${restart_session_path}" = "${session_dir}/pirun.jsonl" ] \
            || { echo 'snapshot reopened the wrong physical session file' >&2; exit 92; }
    fi
    resume_session_id=22222222-2222-4222-8222-222222222222
    host_session_dir=${profile_dir}${session_dir#/profile}
    mkdir -p "${host_session_dir}"
    printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/workspace"}\n' \
        "${resume_session_id}" > "${host_session_dir}/pirun.jsonl"
    printf '{"type":"session","version":3,"id":"%s","timestamp":"2026-01-02T00:00:00.000Z","cwd":"/workspace"}\n' \
        "${resume_session_id}" > "${host_session_dir}/pi-run.jsonl"
    printf '{"type":"session","version":3,"id":"other-session","timestamp":"2026-01-03T00:00:00.000Z","cwd":"/workspace"}\n' \
        > "${host_session_dir}/other.jsonl"
    request_emitted_file=${REQUEST_EMITTED_FILE:-${MAIN_LOG:?}.request-emitted.${PPID}}
    if [ -n "${REQUEST_ACTION:-}" ] && [ ! -e "${request_emitted_file}" ]; then
        : > "${request_emitted_file}"
        [ "${REQUEST_TOKEN_MODE:-valid}" = valid ] || token=00000000-0000-4000-8000-000000000000
        case "${REQUEST_SESSION_MODE:-valid}" in
            valid) request_session='"'${resume_session_id}'"'; request_file='"pirun.jsonl"' ;;
            none) request_session=null; request_file=null ;;
            missing) request_session='"'${resume_session_id}'"'; request_file='"missing.jsonl"' ;;
            mismatch) request_session='"'${resume_session_id}'"'; request_file='"other.jsonl"' ;;
            traversal) request_session='"'${resume_session_id}'"'; request_file='"../pirun.jsonl"' ;;
            symlink) request_session='"'${resume_session_id}'"'; request_file='"linked.jsonl"'; ln -sf pirun.jsonl "${host_session_dir}/linked.jsonl" ;;
            *) exit 3 ;;
        esac
        printf '{"schemaVersion":3,"token":"%s","action":"%s","resumeSessionId":%s,"resumeSessionFile":%s}\n' \
            "${token}" "${REQUEST_ACTION}" "${request_session}" "${request_file}" > "${request_dir}/request.json"
        chmod 0600 "${request_dir}/request.json"
    fi
    exit "${MAIN_DOCKER_STATUS:-0}"
fi
rm -f "${call}"
if [ "${entrypoint}" = pi ]; then printf '1.1.0\n'; exit 0; fi
case "${operation}" in
    snapshots) if [ "${tagged}" = true ]; then printf '[]\n'; else printf '[]\n'; fi ;;
    backup) printf '{"message_type":"summary","snapshot_id":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}\n' ;;
    check) printf '{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}\n' ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "${TMP}/fake-bin/docker"
export DOCKER_LOG="${TMP}/docker.log" MAIN_LOG="${TMP}/main.log"
HOME_DIR="${TMP}/Pi-Run"
PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" "${ROOT}/bin/pi-run" init >/dev/null
git init -q -b main "${TMP}/workspace"
git -C "${TMP}/workspace" config user.name fixture
git -C "${TMP}/workspace" config user.email fixture@pi-run.invalid
git -C "${TMP}/workspace" commit -q --allow-empty -m base
export SNAPSHOT_LOCK_PATH="${HOME_DIR}/snapshots"
auto_output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot auto status)"
[[ "${auto_output}" == 'Automatic snapshots on successful Pi exit: disabled' ]] \
    || fail "automatic snapshots were not disabled by default"
set +e
env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot auto enable >/dev/null 2>&1
auto_status=$?
set -e
[[ ${auto_status} -ne 0 ]] || fail "automatic snapshots were enabled without a configured repository"
printf '%s\n' '{"schemaVersion":1,"backend":"local","repository":"repository"}' > "${HOME_DIR}/snapshots/config.json"
printf 'password\n' > "${HOME_DIR}/snapshots/secrets"
chmod 0600 "${HOME_DIR}/snapshots/config.json" "${HOME_DIR}/snapshots/secrets"
mkdir "${HOME_DIR}/snapshots/repository"
printf repository > "${HOME_DIR}/snapshots/repository/config"

run_launch() {
    local request_emitted_file="${TMP}/request-emitted"
    rm -f "${request_emitted_file}"
    env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" DOCKER_LOG="${DOCKER_LOG}" MAIN_LOG="${MAIN_LOG}" \
        REQUEST_ACTION="${REQUEST_ACTION:-}" REQUEST_TOKEN_MODE="${REQUEST_TOKEN_MODE:-valid}" \
        REQUEST_SESSION_MODE="${REQUEST_SESSION_MODE:-valid}" REQUEST_EMITTED_FILE="${request_emitted_file}" \
        MAIN_DOCKER_STATUS="${MAIN_DOCKER_STATUS:-0}" "${ROOT}/bin/pi-run" "${TMP}/workspace"
}

: > "${DOCKER_LOG}"
: > "${MAIN_LOG}"
REQUEST_ACTION=status output="$(run_launch)"
[[ "${output}" == *'Snapshot status: ready'* ]] || fail "status request was not dispatched"
[[ "$(grep -Fxc -- '---' "${MAIN_LOG}")" == 2 ]] || fail "Pi was not launched exactly twice"
grep -Fx -- --session "${MAIN_LOG}" >/dev/null || fail "snapshot did not reopen an exact session"
grep -E '^/profile/sessions/[0-9a-f-]{36}/pirun\.jsonl$' "${MAIN_LOG}" >/dev/null \
    || fail "snapshot reopened the wrong physical session file"
grep -Fx -- /usr/local/lib/node_modules/snapshot-agent/snapshot-agent.ts "${MAIN_LOG}" >/dev/null \
    || fail "snapshot extension was not explicitly loaded"
grep -F 'dst=/run/pi-run-snapshot' "${MAIN_LOG}" >/dev/null || fail "request directory was not mounted"
if grep -F 'dst=/snapshots' "${MAIN_LOG}" >/dev/null; then fail "Pi container received snapshot repository access"; fi
[[ -z "$(find "${HOME_DIR}/snapshots/requests" -mindepth 1 -print -quit)" ]] || fail "status request was not cleaned"

REQUEST_ACTION=list output="$(run_launch)"
[[ "${output}" == *'No Pi-Run snapshots.'* ]] || fail "list request was not dispatched"
REQUEST_ACTION=status REQUEST_TOKEN_MODE=bad expect_status=0
set +e
run_launch >/dev/null 2>&1
expect_status=$?
set -e
[[ ${expect_status} -ne 0 ]] || fail "stale request token was accepted"
REQUEST_TOKEN_MODE=valid
[[ -z "$(find "${HOME_DIR}/snapshots/requests" -mindepth 1 -print -quit)" ]] || fail "invalid request was not cleaned"

for invalid_mode in missing mismatch traversal symlink; do
    : > "${MAIN_LOG}"
    REQUEST_ACTION=status REQUEST_SESSION_MODE="${invalid_mode}" expect_status=0
    set +e
    run_launch >/dev/null 2>&1
    expect_status=$?
    set -e
    [[ ${expect_status} -ne 0 ]] || fail "${invalid_mode} restart session was accepted"
    [[ "$(grep -Fxc -- '---' "${MAIN_LOG}")" == 1 ]] \
        || fail "${invalid_mode} restart session launched Pi again"
    [[ -z "$(find "${HOME_DIR}/snapshots/requests" -mindepth 1 -print -quit)" ]] \
        || fail "${invalid_mode} restart request was not cleaned"
done
find "${HOME_DIR}/profiles/default/sessions" -type l -name linked.jsonl -delete
REQUEST_SESSION_MODE=valid

: > "${MAIN_LOG}"
REQUEST_ACTION=status REQUEST_SESSION_MODE=none output="$(run_launch 2>&1)"
[[ "$(grep -Fxc -- '---' "${MAIN_LOG}")" == 2 ]] || fail "unsaved session did not restart fresh"
[[ "${output}" == *'Starting a fresh Pi session because the previous session had no saved transcript.'* ]] \
    || fail "fresh-session restart was not reported"
if grep -Fx -- --session "${MAIN_LOG}" >/dev/null; then fail "unsaved session was reopened by path"; fi
REQUEST_SESSION_MODE=valid

REQUEST_ACTION=create
: > "${MAIN_LOG}"
output="$(run_launch 2>&1)"
[[ "${output}" == *'Snapshot created: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'* ]] \
    || fail "create request was not dispatched without a second confirmation"
[[ "$(grep -Fxc -- '---' "${MAIN_LOG}")" == 2 ]] || fail "Pi did not reopen after snapshot creation"
REQUEST_ACTION=check
output="$(run_launch 2>&1)"
[[ "${output}" == *'Snapshot check: OK'* ]] \
    || fail "check request was not dispatched without a second confirmation"

REQUEST_ACTION=status MAIN_DOCKER_STATUS=42
set +e
run_launch >/dev/null 2>&1
status=$?
set -e
[[ ${status} -eq 42 ]] || fail "container failure status was not preserved"
MAIN_DOCKER_STATUS=130
set +e
run_launch >/dev/null 2>&1
status=$?
set -e
[[ ${status} -eq 130 ]] || fail "interrupted container status was not preserved"
MAIN_DOCKER_STATUS=0
[[ -z "$(find "${HOME_DIR}/snapshots/requests" -mindepth 1 -print -quit)" ]] || fail "failed container request was not cleaned"

auto_output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    DOCKER_LOG="${DOCKER_LOG}" "${ROOT}/bin/pi-run" snapshot auto enable)"
[[ "${auto_output}" == 'Automatic snapshots on successful Pi exit: enabled' ]] \
    || fail "automatic snapshot enable output is incorrect"
machine_file="$(find "${HOME_DIR}/machines" -maxdepth 1 -type f -name '*.json' -print -quit)"
jq -e '.schemaVersion == 1 and .snapshotAuto.onSessionExit==true' "${machine_file}" >/dev/null \
    || fail "automatic snapshot setting was not stored in schema-v1 machine metadata"
auto_output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot auto status)"
[[ "${auto_output}" == 'Automatic snapshots on successful Pi exit: enabled' ]] \
    || fail "automatic snapshot status failed after worktree metadata migration"

REQUEST_ACTION=""
REQUEST_SESSION_MODE=valid
: > "${DOCKER_LOG}"
auto_output="$(run_launch)"
[[ "${auto_output}" == *'Snapshot created: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'* ]] \
    || fail "successful Pi exit did not create an automatic snapshot"
backup_count="$(grep -Fxc -- backup "${DOCKER_LOG}" || true)"
[[ "${backup_count}" == 1 ]] || fail "successful Pi exit did not create exactly one automatic snapshot"
grep -Fx -- 'purpose=automatic' "${DOCKER_LOG}" >/dev/null \
    || fail "automatic snapshot purpose was not passed to Restic"

REQUEST_ACTION=status
: > "${DOCKER_LOG}"
run_launch >/dev/null
backup_count="$(grep -Fxc -- backup "${DOCKER_LOG}" || true)"
[[ "${backup_count}" == 1 ]] \
    || fail "intermediate snapshot request created an extra automatic snapshot"

REQUEST_SESSION_MODE=none
: > "${DOCKER_LOG}"
run_launch >/dev/null
backup_count="$(grep -Fxc -- backup "${DOCKER_LOG}" || true)"
[[ "${backup_count}" == 1 ]] \
    || fail "fresh Pi session exit did not create the configured automatic snapshot"
REQUEST_SESSION_MODE=valid

REQUEST_ACTION=""
MAIN_DOCKER_STATUS=42
: > "${DOCKER_LOG}"
set +e
run_launch >/dev/null 2>&1
status=$?
set -e
MAIN_DOCKER_STATUS=0
[[ ${status} -eq 42 ]] || fail "failed Pi run did not preserve its status with automatic snapshots enabled"
backup_count="$(grep -Fxc -- backup "${DOCKER_LOG}" || true)"
[[ "${backup_count}" == 0 ]] || fail "failed Pi run created an automatic snapshot"

auto_output="$(env PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${HOME_DIR}" \
    "${ROOT}/bin/pi-run" snapshot auto disable)"
[[ "${auto_output}" == 'Automatic snapshots on successful Pi exit: disabled' ]] \
    || fail "automatic snapshot disable output is incorrect"
: > "${DOCKER_LOG}"
run_launch >/dev/null
backup_count="$(grep -Fxc -- backup "${DOCKER_LOG}" || true)"
[[ "${backup_count}" == 0 ]] || fail "disabled automatic snapshots still created a backup"

echo "snapshot host bridge and automatic snapshot tests passed"
