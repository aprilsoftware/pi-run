#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin" "${TMP}/source" "${TMP}/direct"
printf '#!/usr/bin/env bash\nexec node %q "$@"\n' "${ROOT}/tests/fixtures/worker-docker.mjs" > "${TMP}/bin/docker"
chmod 0755 "${TMP}/bin/docker"
export PATH="${TMP}/bin:${PATH}" TEST_ROOT="${ROOT}" TEST_TMP="${TMP}"
export PI_RUN_HOME="${TMP}/home" FAKE_DOCKER_LOG="${TMP}/docker.jsonl" FAKE_WORKER_TRACE="${TMP}/peer.jsonl"
"${ROOT}/bin/pi-run" init >/dev/null
printf 'You are a careful reviewer. Preserve the baseline.\n' > "${TMP}/role.txt"
git -C "${TMP}/source" init -q -b main
git -C "${TMP}/source" -c user.name=fixture -c user.email=fixture@example.invalid commit --allow-empty -qm base
node --input-type=module <<'NODE'
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, appendFileSync, readdirSync, existsSync, renameSync, symlinkSync, unlinkSync, rmSync } from 'node:fs';
import { join } from 'node:path';
const root = process.env.TEST_ROOT, temp = process.env.TEST_TMP, home = process.env.PI_RUN_HOME;
const cli = join(root, 'bin/pi-run'), role = join(temp, 'role.txt');
const run = (...args) => execFileSync(cli, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const failed = (...args) => assert.throws(() => run(...args));
const a = JSON.parse(run('worktree', 'create', 'first', join(temp, 'source'), '--json'));
const b = JSON.parse(run('worktree', 'create', 'second', join(temp, 'source'), '--json'));
assert.equal(a.schemaVersion, 1); assert.notEqual(a.workspaceId, b.workspaceId);
assert(!readFileSync(process.env.FAKE_DOCKER_LOG, 'utf8').includes('worker-rpc.mjs'));
failed('worktree', 'create', 'first', join(temp, 'source'), '--json');
let sequence = 0;
const children = new Set();
function start(args, env = {}) {
  const child = spawn(cli, args, { env: { ...process.env, ...env }, stdio: ['pipe', 'pipe', 'pipe'] });
  children.add(child);
  const records = []; let buffer = '', stderr = '', exited = false, exitCode;
  child.stderr.on('data', d => { stderr += d; });
  child.stdout.on('data', d => {
    buffer += d;
    while (buffer.includes('\n')) {
      const at = buffer.indexOf('\n'), line = buffer.slice(0, at); buffer = buffer.slice(at + 1);
      records.push(JSON.parse(line)); // Any diagnostic contamination fails the test.
    }
  });
  const watchdog = setTimeout(() => { console.error(`Worker deadline: ${stderr}`); child.kill('SIGTERM'); }, 90000);
  const exit = new Promise(resolve => child.on('exit', code => { clearTimeout(watchdog); exited = true; exitCode = code; children.delete(child); resolve(code); }));
  async function wait(predicate) {
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
      const result = records.find(predicate); if (result) return result;
      if (exited) throw new Error(`Worker exited ${exitCode}: ${stderr}`);
      await new Promise(r => setTimeout(r, 20));
    }
    throw new Error(`timed out: ${stderr}`);
  }
  const send = r => child.stdin.write(`${JSON.stringify(r)}\n`);
  async function request(type, fields = {}) {
    const id = `test-${++sequence}`; send({ type, ...fields, id });
    return wait(r => r.type === 'response' && r.id === id);
  }
  return { child, records, exit, wait, send, request, get stderr() { return stderr; } };
}
async function stop(w) { await w.request('pi_run_shutdown'); assert.equal(await w.exit, 0, w.stderr); }
try {
  const w = start(['worker', 'launch', a.path, '--role-file', role]);
  const ready = await w.wait(r => r.type === 'pi_run_worker_ready');
  const ref = ready.reference;
  assert.match(ref, /^worker-v1:/);
  w.send({ type: 'pi_run_shutdown', id: 42 });
  assert.equal((await w.wait(r => r.type === 'response' && r.command === 'pi_run_shutdown')).success, false);
  let info = JSON.parse(run('worker', 'inspect', ref, '--json'));
  assert.equal(info.transcriptSaved, false); assert.equal(info.configurationChanged, false);
  failed('worker', 'launch', a.path, '--role-file', role);
  const other = start(['worker', 'launch', b.path, '--role-file', role]);
  await other.wait(r => r.type === 'pi_run_worker_ready');
  await stop(other);
  for (const type of ['new_session', 'switch_session', 'fork', 'clone', 'set_model', 'bash', 'set_auto_retry']) {
    assert.equal((await w.request(type)).success, false);
  }
  assert.equal((await w.request('prompt', { message: '/guardian-mode off' })).success, false);
  for (const message of ['one', 'two\u2028still one record\u2029!']) {
    assert.equal((await w.request('prompt', { message })).success, true);
    await w.wait(r => r.type === 'message_end' && r.message.content === message);
  }
  await w.request('prompt', { message: 'question' });
  await w.wait(r => r.type === 'extension_ui_request' && r.id === 'dialog-1');
  assert(!w.records.some(r => r.type === 'fixture_interaction'));
  w.send({ type: 'extension_ui_response', id: 'dialog-1', cancelled: true });
  const interaction = await w.wait(r => r.type === 'fixture_interaction');
  assert.equal(interaction.cancelled, true); assert.equal(interaction.confirmed, false);
  await w.request('prompt', { message: 'wait' });
  await w.request('follow_up', { message: 'must not run after abort' });
  await w.request('steer', { message: 'must also not run' });
  assert.equal((await w.request('abort')).success, true);
  assert(!w.records.some(r => r.type === 'fixture_queue_ran'));
  await w.request('prompt', { message: 'after abort' });
  await w.wait(r => r.type === 'message_end' && r.message.content === 'after abort');
  info = JSON.parse(run('worker', 'inspect', ref, '--json'));
  assert.equal(info.transcriptSaved, true); assert.equal(info.resumable, true);
  await stop(w);
  assert.equal(readdirSync(join(home, 'worktrees/.launch-locks')).length, 0);
  const resumed = start(['worker', 'resume', ref]);
  const again = await resumed.wait(r => r.type === 'pi_run_worker_ready');
  assert.equal(again.sessionId, ready.sessionId); assert.equal(again.sessionFile, ready.sessionFile);
  assert((await resumed.request('get_messages')).data.messages.includes('after abort'));
  await stop(resumed);
  writeFileSync(join(a.path, 'ordinary-source.txt'), 'source edits are not drift\n');
  assert.equal(JSON.parse(run('worker', 'inspect', ref, '--json')).configurationChanged, false);
  const settings = join(home, 'profiles/default/settings.json');
  writeFileSync(settings, '{"defaultModel":"different"}\n');
  assert.equal(JSON.parse(run('worker', 'inspect', ref, '--json')).configurationChanged, true);
  failed('worker', 'resume', ref); unlinkSync(settings);
  assert.throws(() => execFileSync(cli, ['worker', 'resume', ref], {
    env: { ...process.env, FAKE_WORKER_RUNTIME_ID: `sha256:${'d'.repeat(64)}` }, stdio: ['ignore', 'pipe', 'pipe'],
  }), /execution|runtime|Command failed/);
  const boundRole = join(home, 'worker-sessions', ref.split(':')[1], 'role.txt');
  failed('worker', 'launch', join(home, 'worker-sessions', ref.split(':')[1]), '--role-file', role);
  failed('worker', 'launch', home, '--role-file', role);
  appendFileSync(boundRole, 'changed'); failed('worker', 'inspect', ref, '--json');
  writeFileSync(boundRole, readFileSync(role));
  renameSync(boundRole, `${boundRole}.saved`); symlinkSync(`${boundRole}.saved`, boundRole);
  failed('worker', 'resume', ref); unlinkSync(boundRole); renameSync(`${boundRole}.saved`, boundRole);
  const eof = start(['worker', 'resume', ref]); await eof.wait(r => r.type === 'pi_run_worker_ready');
  eof.child.stdin.end(); assert.equal(await eof.exit, 74);
  assert.equal(readdirSync(join(home, 'worktrees/.launch-locks')).length, 0);
  const hang = start(['worker', 'resume', ref], { FAKE_WORKER_BEHAVIOR: 'hang-exit' });
  await hang.wait(r => r.type === 'pi_run_worker_ready'); hang.child.stdin.end();
  assert.equal(await hang.exit, 74);
  const malformed = start(['worker', 'resume', ref]); await malformed.wait(r => r.type === 'pi_run_worker_ready');
  malformed.child.stdin.write('not json\n'); assert.equal(await malformed.exit, 74);
  const early = start(['worker', 'resume', ref], { FAKE_WORKER_BEHAVIOR: 'bad-output' });
  assert.equal(await early.exit, 74);
  const empty = start(['worker', 'launch', join(temp, 'direct'), '--role-file', role]);
  const emptyReady = await empty.wait(r => r.type === 'pi_run_worker_ready'); await stop(empty);
  failed('worker', 'resume', emptyReady.reference);
  const moved = start(['worker', 'launch', join(temp, 'direct'), '--role-file', role]);
  const movedReady = await moved.wait(r => r.type === 'pi_run_worker_ready');
  await moved.request('prompt', { message: 'save before relocation' }); await stop(moved);
  const movedInfo = JSON.parse(run('worker', 'inspect', movedReady.reference, '--json'));
  renameSync(join(temp, 'direct'), join(temp, 'relocated'));
  assert.equal(JSON.parse(run('worker', 'inspect', movedReady.reference, '--json')).workspaceAvailable, false);
  failed('worker', 'resume', movedReady.reference);
  run('workspace', 'link', movedInfo.workspaceId, join(temp, 'relocated'));
  const reconnected = start(['worker', 'resume', movedReady.reference]);
  assert.equal((await reconnected.wait(r => r.type === 'pi_run_worker_ready')).sessionId, movedReady.sessionId);
  await stop(reconnected);
  const profileFile = join(home, 'profiles/default/profile.json');
  const originalProfile = readFileSync(profileFile, 'utf8');
  for (const mode of ['offline', 'restricted']) {
    const profile = JSON.parse(originalProfile);
    profile.network = mode === 'offline' ? { mode } : { mode, allow: [{ cidr: '192.0.2.1/32', tcpPorts: [443] }] };
    writeFileSync(profileFile, JSON.stringify(profile));
    const network = start(['worker', 'launch', b.path, '--role-file', role]);
    await network.wait(r => r.type === 'pi_run_worker_ready'); await stop(network);
  }
  writeFileSync(profileFile, originalProfile);
  const lostCleanup = start(['worker', 'launch', b.path, '--role-file', role], { FAKE_DOCKER_UNAVAILABLE: '1' });
  await lostCleanup.wait(r => r.type === 'pi_run_worker_ready');
  await lostCleanup.request('pi_run_shutdown'); assert.equal(await lostCleanup.exit, 1);
  const lock = join(home, 'worktrees/.launch-locks', b.workspaceId);
  assert(existsSync(join(lock, 'owner.json')));
  failed('worktree', 'open', 'second', join(temp, 'source'), '--version');
  // Fixture peer has exited and no real daemon was used. Remove only this test's lock.
  rmSync(lock, { recursive: true });
  const calls = readFileSync(process.env.FAKE_DOCKER_LOG, 'utf8').trim().split('\n').map(JSON.parse);
  assert(calls.some(a => a.includes('container:') || a.some(v => v.startsWith('container:pi-egress-'))));
  assert(calls.some(a => a[0] === 'rm' && a.includes('c'.repeat(64))));
  const launches = calls.filter(a => a.includes('/usr/local/lib/pi-run/worker-rpc.mjs'));
  assert(launches.length > 5);
  for (const args of launches) {
    assert(args.includes('-i')); assert(!args.includes('-it')); assert(args.includes('--init'));
    assert(args.includes('--pull')); assert(args.includes('never'));
    assert(args.includes('--append-system-prompt')); assert(!args.includes('--system-prompt'));
    assert(args.some(a => a.endsWith('dst=/run/pi-run-role.txt,readonly')));
    assert(!args.some(a => a.includes('binding.json') || a.includes('docker.sock')));
    for (const extension of ['guardian/guardian-agent.ts', 'caf/caf-agent.ts', 'knowledge/knowledge-agent.ts']) {
      assert(args.some(a => a.endsWith(extension)));
    }
  }
  // Failed-cleanup staging is intentionally retained in production. This test
  // used only fake containers; remove its recorded scratch paths after peer exit.
  for (const args of launches) {
    const channel = args.find(a => a.endsWith('dst=/run/pi-run-worker'));
    const source = channel.match(/^type=bind,src=(\/tmp\/pi-run-worker\.[^/]+)\/channel,dst=/)[1];
    rmSync(source, { recursive: true, force: true });
  }
  console.log('Worker creation, launch, RPC, abort, interaction, binding, drift, resume, networking and cleanup tests passed');
} finally {
  for (const child of children) child.kill('SIGTERM');
}
NODE
