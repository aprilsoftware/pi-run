// SPDX-License-Identifier: MIT
// Runs inside an offline utility container on the host test; no Docker socket.
// The same exercise is also used by the isolated installed-Pi regression.
import assert from 'node:assert/strict';
import { createReadStream, createWriteStream, existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const text = message => typeof message.content === 'string' ? message.content :
  (message.content ?? []).filter(b => b.type === 'text').map(b => b.text).join('');
const conversation = messages => messages.filter(m => ['user', 'assistant'].includes(m.role));

export async function exerciseWorker(input, output, { phase, previous, onReady = async () => {}, timeoutMs = 90000 }) {
  const records = [];
  let buffer = '', ended = false, failure, sequence = 0;
  const decoder = new TextDecoder('utf-8', { fatal: true });
  const deadline = Date.now() + timeoutMs;
  input.on('data', chunk => {
    try {
      buffer += decoder.decode(chunk, { stream: true });
      if (Buffer.byteLength(buffer) > 32 * 1024 * 1024) throw new Error('Oversized Worker record');
      while (buffer.includes('\n')) {
        const at = buffer.indexOf('\n'), line = buffer.slice(0, at); buffer = buffer.slice(at + 1);
        const record = JSON.parse(line);
        assert.equal(typeof record?.type, 'string');
        if (record.type === 'extension_ui_request' && ['confirm', 'select', 'input', 'editor'].includes(record.method)) {
          throw new Error('Unexpected interaction; this test never supplies approval');
        }
        if (record.type === 'tool_execution_start') throw new Error('The fixture must not invoke agent tools');
        if (record.type === 'message_end' && record.message?.stopReason === 'error') {
          throw new Error(`Pi reported a provider error: ${record.message.errorMessage}`);
        }
        if (records.length >= 4000) throw new Error('Excessive Worker events');
        records.push(record);
      }
    } catch (error) { failure = error; }
  });
  input.on('end', () => {
    try { buffer += decoder.decode(); if (buffer) throw new Error('Unterminated Worker record'); }
    catch (error) { failure = error; }
    ended = true;
  });
  input.on('error', error => { failure = error; });
  output.on('error', error => { failure = error; });
  async function wait(predicate, start = 0, allowEnd = false) {
    while (Date.now() < deadline) {
      if (failure) throw failure;
      const found = records.slice(start).find(predicate);
      if (found) return found;
      if (ended) { if (allowEnd) return; throw new Error('Worker exited before expected event'); }
      await delay(10);
    }
    throw new Error(`Worker round-trip deadline exceeded (${phase})`);
  }
  async function request(type, fields = {}) {
    const id = `${phase}-${++sequence}`, start = records.length;
    output.write(`${JSON.stringify({ type, id, ...fields })}\n`);
    const response = await wait(r => r.type === 'response' && r.id === id, start);
    assert.equal(response.command, type); assert.equal(response.success, true, response.error);
    return response.data;
  }
  function assertReport(reply, prompt, users, priorReplies) {
    assert.deepEqual(JSON.parse(reply), { fixture: 'worker-roundtrip', prompt,
      users: users.map(u => `worker-fixture:${u}`), priorReplies, role: true, baseline: true });
  }
  async function turn(prompt, users, priorReplies) {
    const start = records.length;
    const accepted = await request('prompt', { message: `worker-fixture:${prompt}` });
    assert.equal(accepted.disposition, 'started');
    await wait(r => r.type === 'agent_settled', start);
    const reply = await request('get_last_assistant_text');
    assertReport(reply.text, prompt, users, priorReplies);
  }

  const ready = await wait(r => r.type === 'pi_run_worker_ready');
  assert.match(ready.reference, /^worker-v1:[0-9a-f-]{36}$/);
  assert.match(ready.sessionId, /^[0-9a-f-]{36}$/);
  const identity = { reference: ready.reference, sessionId: ready.sessionId, sessionFile: ready.sessionFile };
  if (phase === 'resume') assert.deepEqual(identity, previous.identity);
  await onReady(identity);
  const initial = await request('get_state');
  assert.equal(initial.sessionId, ready.sessionId); assert.equal(initial.sessionFile, ready.sessionFile);
  assert.equal(initial.model.provider, 'worker-fixture'); assert.equal(initial.model.id, 'worker-fixture-model');
  assert.equal(initial.isStreaming, false); assert.equal(initial.pendingMessageCount, 0);

  if (phase === 'launch') {
    await turn('first', ['first'], []);
    await turn('second', ['first', 'second'], ['first']);
    const start = records.length;
    await request('prompt', { message: 'worker-fixture:block' });
    await wait(r => r.type === 'message_update' &&
      r.assistantMessageEvent?.delta === 'worker-fixture:block-open', start);
    assert.equal((await request('get_state')).isStreaming, true);
    await request('follow_up', { message: 'worker-fixture:queued-follow-up' });
    await request('steer', { message: 'worker-fixture:queued-steer' });
    assert.equal((await request('get_state')).pendingMessageCount, 2);
    await request('abort');
    await wait(r => r.type === 'agent_settled', start);
    assert(records.slice(start).some(r => r.type === 'message_end' && r.message?.stopReason === 'aborted'),
      'Pi must report an actually aborted assistant turn');
    const idle = await request('get_state');
    assert.equal(idle.isStreaming, false); assert.equal(idle.pendingMessageCount, 0);
    await turn('after-abort', ['first', 'second', 'block', 'after-abort'], ['first', 'second']);
  } else {
    assert.equal(phase, 'resume');
    const restored = conversation((await request('get_messages')).messages);
    assert.deepEqual(restored, previous.messages, 'exact stored conversation must be restored before prompting');
    await turn('resumed', ['first', 'second', 'block', 'after-abort', 'resumed'], ['first', 'second', 'after-abort']);
  }
  const messages = conversation((await request('get_messages')).messages);
  assert.deepEqual(messages.filter(m => m.role === 'user').map(text),
    (phase === 'launch' ? ['first', 'second', 'block', 'after-abort'] : ['first', 'second', 'block', 'after-abort', 'resumed'])
      .map(value => `worker-fixture:${value}`));
  const stopStart = records.length;
  await request('pi_run_shutdown');
  const stopped = await wait(r => r.type === 'pi_run_worker_exit', stopStart);
  assert.equal(stopped.reason, 'requested'); assert.equal(stopped.exitCode, 0);
  await wait(() => false, 0, true); // Require transport EOF, not just the exit record.
  output.end();
  return { identity, messages };
}

function atomicJson(path, value) {
  writeFileSync(`${path}.tmp`, JSON.stringify(value), { mode: 0o600 });
  renameSync(`${path}.tmp`, path);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [directory, phase] = process.argv.slice(2);
  const input = createReadStream(join(directory, 'from-worker'));
  const output = createWriteStream(join(directory, 'to-worker'));
  try {
    const previous = phase === 'resume' ? JSON.parse(readFileSync(join(directory, 'previous.json'))) : undefined;
    const result = await exerciseWorker(input, output, { phase, previous, onReady: async identity => {
      atomicJson(join(directory, 'ready.json'), identity);
      const deadline = Date.now() + 30000;
      while (!existsSync(join(directory, 'provider-ready'))) {
        if (Date.now() > deadline) throw new Error('Host did not start the offline provider');
        await delay(20);
      }
    } });
    atomicJson(join(directory, 'result.json'), result);
    console.log(`Worker ${phase} conversation assertions passed`);
  } catch (error) {
    console.error(error.stack); process.exitCode = 1;
  } finally {
    input.destroy(); output.destroy();
  }
}
