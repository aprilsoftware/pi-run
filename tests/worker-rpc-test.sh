#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -m 0700 "${TMP}/home" "${TMP}/profile" "${TMP}/sessions"
printf 'Worker Role fixture.\n' > "${TMP}/role.txt"
# No inherited credentials/configuration. --offline disables Pi background network.
env -i PATH="${PATH}" HOME="${TMP}/home" PI_CODING_AGENT_DIR="${TMP}/profile" PI_OFFLINE=1 \
    node --input-type=module - "${ROOT}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { PassThrough, Writable } from 'node:stream';
import { mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [root, temp] = process.argv.slice(2);
const { runWorker, jsonLines } = await import(pathToFileURL(join(root, 'docker/worker-rpc.mjs')));
process.chdir(temp);
let sequence = 0;
async function fixture({ real = false, behavior, output, startupMs = 3000, abortMs = startupMs, shutdownMs = 500 } = {}) {
  const control = join(temp, `control-${++sequence}`); mkdirSync(control);
  const input = new PassThrough();
  const records = [], stdout = output ?? new PassThrough();
  if (!output) jsonLines(stdout, 32 * 1024 * 1024, r => records.push(r), reason => {
    if (reason !== 'stream error') assert.fail(reason); // Deliberate output-loss case below.
  });
  const sessionDir = join(temp, 'sessions');
  process.env.PI_RUN_WORKER_SESSION_DIR = sessionDir;
  process.env.FAKE_WORKER_SESSION_HOST = sessionDir;
  if (behavior) process.env.FAKE_WORKER_BEHAVIOR = behavior; else delete process.env.FAKE_WORKER_BEHAVIOR;
  const args = real ? ['--offline', '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes', '--no-tools',
    '--no-context-files', '--mode', 'rpc', '--tui-mode', 'regular', '--thinking', 'high',
    '--session-dir', sessionDir, '--append-system-prompt', join(temp, 'role.txt')] :
    [join(root, 'tests/fixtures/worker-peer.mjs')];
  const done = runWorker({ command: real ? 'pi' : process.execPath, args, control, input, output: stdout,
    role: join(temp, 'role.txt'), reference: 'worker-v1:11111111-1111-4111-8111-111111111111', sessionDir,
    startupMs, abortMs, shutdownMs, heartbeatMs: 30, outputTimeoutMs: 150 });
  const ack = setInterval(() => {
    if (existsSync(join(control, 'session.json'))) { writeFileSync(join(control, 'ack'), 'ready\n'); clearInterval(ack); }
  }, 10);
  let exitCode;
  done.finally(() => clearInterval(ack));
  done.then(code => { exitCode = code; });
  const wait = async predicate => {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      const item = records.find(predicate); if (item) return item;
      if (exitCode !== undefined) throw new Error(`protocol fixture exited ${exitCode}: ${JSON.stringify(records.at(-1))}`);
      await new Promise(r => setTimeout(r, 10));
    }
    throw new Error('protocol fixture timed out');
  };
  return { input, stdout, records, done, wait, send: r => input.write(`${JSON.stringify(r)}\n`) };
}
// LF framing across UTF-8 byte boundaries, CRLF, and Unicode separators.
{
  const stream = new PassThrough(), records = [];
  jsonLines(stream, 1000, r => records.push(r), assert.fail);
  const bytes = Buffer.from('{"type":"x","text":"é\u2028\u2029"}\r\n');
  for (const byte of bytes) stream.write(Buffer.from([byte]));
  stream.end(); assert.equal(records[0].text, 'é\u2028\u2029');
}
for (const payload of ['[]\n', '{}\n', '{"type":"x"}', Buffer.from([0xff, 10])]) {
  const f = await fixture(); await f.wait(r => r.type === 'pi_run_worker_ready');
  f.input.end(payload); assert.equal(await f.done, 74);
}
{
  const f = await fixture(); await f.wait(r => r.type === 'pi_run_worker_ready');
  f.input.write('x'.repeat(8 * 1024 * 1024 + 1)); assert.equal(await f.done, 74);
}
{
  const f = await fixture({ behavior: 'hang-start', startupMs: 100 });
  assert.equal(await f.done, 74);
  assert(!f.records.some(r => r.type === 'pi_run_worker_ready'));
}
{
  const f = await fixture({ behavior: 'hang-abort', abortMs: 100 });
  await f.wait(r => r.type === 'pi_run_worker_ready');
  f.send({ type: 'abort', id: 'abort' }); assert.equal(await f.done, 74);
}
{
  const f = await fixture(); await f.wait(r => r.type === 'pi_run_worker_ready');
  f.stdout.destroy(new Error('controller lost output')); assert.equal(await f.done, 74);
}
{
  const stalled = new Writable({ highWaterMark: 1, write(_chunk, _encoding, _callback) { /* Never drain. */ } });
  const f = await fixture({ output: stalled }); assert.equal(await f.done, 74);
}
{
  const f = await fixture({ behavior: 'delay-queue' });
  await f.wait(r => r.type === 'pi_run_worker_ready');
  f.send({ type: 'follow_up', message: 'delayed input handler', id: 'queued' });
  f.send({ type: 'abort', id: 'abort' });
  await f.wait(r => r.type === 'response' && r.id === 'abort');
  f.send({ type: 'get_state', id: 'state' });
  assert.equal((await f.wait(r => r.type === 'response' && r.id === 'state')).data.pendingMessageCount, 0);
  assert(!f.records.some(r => r.type === 'fixture_queue_ran'));
  f.send({ type: 'pi_run_shutdown' }); assert.equal(await f.done, 0);
}
{
  const f = await fixture({ behavior: 'slow-abort', abortMs: 200 });
  await f.wait(r => r.type === 'pi_run_worker_ready');
  f.send({ type: 'abort', id: 'first' });
  await f.wait(r => r.type === 'response' && r.id === 'first');
  await new Promise(r => setTimeout(r, 80));
  f.send({ type: 'abort', id: 'second' });
  assert.equal((await f.wait(r => r.type === 'response' && r.id === 'second')).success, true);
  f.send({ type: 'pi_run_shutdown' }); assert.equal(await f.done, 0);
}
// Installed Pi compatibility, not a live provider acceptance. Only state, queues,
// and abort are requested; no prompt, model call, extension, or credential load.
{
  const f = await fixture({ real: true, startupMs: 10000, shutdownMs: 1000 });
  const ready = await f.wait(r => r.type === 'pi_run_worker_ready');
  assert.match(ready.sessionId, /^[0-9a-f-]{36}$/);
  assert(!existsSync(ready.sessionFile), 'empty Pi conversation should remain unsaved');
  f.send({ type: 'follow_up', message: 'Never execute this queued fixture', id: 'queue' });
  await f.wait(r => r.type === 'response' && r.id === 'queue');
  f.send({ type: 'abort', id: 'abort' });
  assert.equal((await f.wait(r => r.type === 'response' && r.id === 'abort')).success, true);
  f.send({ type: 'get_state', id: 'state' });
  const state = await f.wait(r => r.type === 'response' && r.id === 'state');
  assert.equal(state.data.pendingMessageCount, 0); assert.equal(state.data.sessionId, ready.sessionId);
  f.send({ type: 'pi_run_shutdown', id: 'stop' }); assert.equal(await f.done, 0);
  assert(!f.records.some(r => r.type === 'agent_start'));
}
console.log('Worker framing, limits, disconnect/backpressure, deadlines and offline native-Pi RPC tests passed');
NODE
