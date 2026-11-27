// SPDX-License-Identifier: MIT
// Container-only Pi RPC transport. No host runtime dependency or model calls here.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, renameSync, existsSync, lstatSync } from 'node:fs';
import { basename } from 'node:path';

export const allowedCommands = new Set([
  'prompt', 'steer', 'follow_up', 'abort', 'clear_queue', 'abort_retry',
  'get_state', 'get_messages', 'get_session_stats', 'get_entries', 'get_tree',
  'get_last_assistant_text', 'get_available_models', 'get_available_thinking_levels',
  'set_session_name', 'compact',
]);
const dialogMethods = new Set(['select', 'confirm', 'input', 'editor']);
const MAX_INPUT = 8 * 1024 * 1024;
const MAX_OUTPUT = 32 * 1024 * 1024;

// Split only on LF. Fatal UTF-8 decoding rejects corrupted/partial characters.
export function jsonLines(stream, maximum, onRecord, onFailure, onEnd) {
  let buffer = Buffer.alloc(0);
  stream.on('data', chunk => {
    buffer = Buffer.concat([buffer, Buffer.from(chunk)]);
    let newline;
    while ((newline = buffer.indexOf(10)) !== -1) {
      const line = buffer.subarray(0, newline);
      buffer = buffer.subarray(newline + 1);
      if (line.length > maximum) { onFailure('record exceeds byte limit'); return; }
      try {
        const record = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line));
        if (!record || Array.isArray(record) || typeof record !== 'object' || typeof record.type !== 'string') {
          throw new Error('expected typed JSON object');
        }
        onRecord(record);
      } catch { onFailure('invalid JSONL record'); return; }
    }
    if (buffer.length > maximum) onFailure('record exceeds byte limit');
  });
  stream.on('end', () => {
    if (buffer.length) onFailure('unterminated JSONL record');
    onEnd?.();
  });
  stream.on('error', () => onFailure('stream error'));
}

export function runWorker({
  args = process.argv.slice(2), command = 'pi',
  control = '/run/pi-run-worker', role = '/run/pi-run-role.txt',
  reference = process.env.PI_RUN_WORKER_REFERENCE,
  sessionDir = process.env.PI_RUN_WORKER_SESSION_DIR,
  expectedId = process.env.PI_RUN_WORKER_SESSION_ID || '',
  input = process.stdin, output = process.stdout,
  startupMs = 30000, abortMs = startupMs, shutdownMs = 10000, heartbeatMs = 5000, outputTimeoutMs = 30000,
} = {}) {
  const roleStat = lstatSync(role);
  if (!roleStat.isFile() || roleStat.size < 1 || roleStat.size > 262144) throw new Error('invalid Role file');
  const roleBytes = readFileSync(role);
  if (!roleBytes.length || roleBytes.length > 262144 || roleBytes.includes(0)) throw new Error('invalid Role file');
  new TextDecoder('utf-8', { fatal: true }).decode(roleBytes);
  if (!/^worker-v1:[0-9a-f-]{36}$/.test(reference || '') || !sessionDir) throw new Error('missing Worker binding');
  const child = spawn(command, args, { stdio: ['pipe', 'pipe', 'inherit'], detached: true });
  const pending = new Map(), dialogs = new Map(), clientIds = new Set();
  let ready = false, stopping = false, finished = false, aborting = false;
  let selected, stopCode = 1, stopReason = 'unexpected_exit', sequence = 0;
  let pressureTimer, inputPressureTimer, killTimer, startupTimer, heartbeat, ackTimer;
  const prefix = `pi-run:${randomUUID()}:`;

  const done = new Promise(resolve => {
    function send(record) {
      if (finished || output.destroyed) return;
      const bytes = `${JSON.stringify(record)}\n`;
      if (Buffer.byteLength(bytes) > MAX_OUTPUT) { stop('output_limit', 74); return; }
      if (!output.write(bytes) && !pressureTimer) {
        child.stdout.pause(); input.pause();
        pressureTimer = setTimeout(() => stop('output_stalled', 74), outputTimeoutMs);
      }
    }
    function respond(record, error) {
      send({ type: 'response', ...(typeof record.id === 'string' ? { id: record.id } : {}),
        command: record.type, success: false, error });
    }
    function toPi(record) {
      if (child.stdin.destroyed || child.stdin.writableEnded) return false;
      if (!child.stdin.write(`${JSON.stringify(record)}\n`)) {
        input.pause();
        inputPressureTimer ??= setTimeout(() => stop('pi_input_stalled', 74), outputTimeoutMs);
      }
      return true;
    }
    function request(type, fields = {}, client) {
      const id = `${prefix}${++sequence}`;
      return new Promise((resolveRequest, rejectRequest) => {
        const timer = client ? undefined : setTimeout(() => {
          pending.delete(id); rejectRequest(new Error(`${type} timed out`));
        }, startupMs);
        pending.set(id, { client, resolveRequest, rejectRequest, timer });
        if (!toPi({ ...fields, type, id })) {
          clearTimeout(timer); pending.delete(id); rejectRequest(new Error('Pi input closed'));
        }
      });
    }
    function cancelDialogs() {
      for (const id of dialogs.keys()) toPi({ type: 'extension_ui_response', id, cancelled: true });
      dialogs.clear();
    }
    function stop(reason, code) {
      if (stopping || finished) return;
      stopping = true; ready = false; stopReason = reason; stopCode = code;
      input.pause();
      clearTimeout(startupTimer); clearInterval(ackTimer); clearInterval(heartbeat);
      cancelDialogs();
      // Write in order, then EOF: native abort alone would run queued messages.
      toPi({ type: 'clear_queue', id: `${prefix}stop-clear` });
      toPi({ type: 'abort', id: `${prefix}stop-abort` });
      child.stdin.end();
      killTimer = setTimeout(() => {
        try { process.kill(-child.pid, 'SIGKILL'); } catch { /* Already gone. */ }
        // A detached descendant may retain stdout even after Pi dies. Do not
        // wait forever for close; ending the adapter ends its whole container.
        child.stdout.destroy(); child.stdin.destroy();
        finish(74, 'SIGKILL');
      }, shutdownMs);
      // The parent host also removes the entire labelled container, covering tools
      // that intentionally created another process group.
    }
    function checkBinding(state) {
      if (typeof state?.sessionId !== 'string' || !/^[0-9a-f-]{36}$/.test(state.sessionId) ||
          typeof state.sessionFile !== 'string' ||
          state.sessionFile !== `${sessionDir}/${basename(state.sessionFile)}` ||
          !/^[A-Za-z0-9_-]+\.jsonl$/.test(basename(state.sessionFile)) ||
          (expectedId && state.sessionId !== expectedId) ||
          (selected && (state.sessionId !== selected.sessionId || state.sessionFile !== selected.sessionFile))) {
        throw new Error('Pi session binding changed');
      }
    }
    function handlePi(record) {
      if (record.type === 'response') {
        const item = pending.get(record.id);
        if (!item) return; // Adapter shutdown responses, never controller IDs.
        pending.delete(record.id); clearTimeout(item.timer);
        if (item.client) {
          if (record.command === 'get_state' && record.success) {
            try { checkBinding(record.data); } catch { stop('binding_changed', 74); return; }
          }
          clientIds.delete(item.client.id);
          const response = { ...record };
          if (item.client.id === undefined) delete response.id; else response.id = item.client.id;
          send(response);
        }
        record.success ? item.resolveRequest(record.data) : item.rejectRequest(new Error('Pi command failed'));
        return;
      }
      if (record.type === 'extension_ui_request' && dialogMethods.has(record.method)) {
        if (dialogs.size >= 128 || typeof record.id !== 'string') { stop('dialog_limit', 74); return; }
        dialogs.set(record.id, record);
        if (Number.isFinite(record.timeout) && record.timeout >= 0) {
          const expiry = setTimeout(() => {
            if (dialogs.get(record.id) === record) dialogs.delete(record.id);
          }, Math.min(record.timeout, 2147483647));
          expiry.unref();
        }
      }
      send(record);
      if (record.type === 'agent_settled' && ready && !stopping) {
        request('get_state').then(checkBinding).catch(() => stop('binding_changed', 74));
      }
    }
    function handleController(record) {
      if (stopping) return;
      if (record.type === 'pi_run_shutdown') {
        if (record.id !== undefined && (typeof record.id !== 'string' || record.id.length > 256 || clientIds.has(record.id))) {
          respond(record, 'invalid or outstanding duplicate request ID'); return;
        }
        send({ type: 'response', command: record.type, id: record.id, success: true });
        stop('requested', 0); return;
      }
      if (record.type === 'extension_ui_response') {
        const dialog = dialogs.get(record.id);
        if (!dialog) { respond(record, 'unknown or expired interaction'); return; }
        const cancelled = record.cancelled === true;
        if (!cancelled && (dialog.method === 'confirm' ? typeof record.confirmed !== 'boolean' :
          typeof record.value !== 'string' || (dialog.method === 'select' && !dialog.options?.includes(record.value)))) {
          respond(record, 'invalid interaction response'); return;
        }
        dialogs.delete(record.id);
        toPi({ type: record.type, id: record.id, ...(cancelled ? { cancelled: true } :
          dialog.method === 'confirm' ? { confirmed: record.confirmed } : { value: record.value }) });
        return;
      }
      if (!ready) { respond(record, 'Worker is not ready'); return; }
      if (!allowedCommands.has(record.type)) { respond(record, 'operation is not supported by Worker protocol v1'); return; }
      if (record.id !== undefined && (typeof record.id !== 'string' || record.id.length > 256 || clientIds.has(record.id))) {
        respond(record, 'invalid or outstanding duplicate request ID'); return;
      }
      if (pending.size >= 128) { respond(record, 'too many outstanding requests'); return; }
      if (['prompt', 'steer', 'follow_up'].includes(record.type)) {
        if (aborting || typeof record.message !== 'string' || record.message.trimStart().startsWith('/')) {
          respond(record, aborting ? 'abort is still pending' : 'expected message text; slash commands are not supported'); return;
        }
      }
      if (record.id !== undefined) clientIds.add(record.id);
      if (record.type === 'abort') {
        if (aborting) { clientIds.delete(record.id); respond(record, 'abort is already pending'); return; }
        aborting = true; cancelDialogs();
        // Earlier prompts can still be inside asynchronous extension input
        // handlers. Let their acceptance finish before clearing their queues.
        const accepted = new Promise(resolveAccepted => {
          const poll = setInterval(() => {
            if (stopping || ![...pending.values()].some(p =>
              ['prompt', 'steer', 'follow_up'].includes(p.client?.type))) {
              clearInterval(poll); resolveAccepted();
            }
          }, 10);
          poll.unref();
        });
        accepted.then(() => {
          if (stopping) throw new Error('Worker stopping');
          return request('clear_queue');
        }).then(() => request('abort', {}, record))
          .then(() => { aborting = false; })
          .catch(() => stop('abort_failed', 74))
          .finally(() => clearTimeout(deadline));
        // A hung abort cannot leave an apparently usable Worker indefinitely.
        const deadline = setTimeout(() => { if (aborting) stop('abort_timeout', 74); }, abortMs);
        deadline.unref();
      } else {
        request(record.type, record, record).catch(() => { /* Forwarded native error. */ });
      }
    }
    jsonLines(child.stdout, MAX_OUTPUT, handlePi, () => stop('invalid_pi_output', 74));
    jsonLines(input, MAX_INPUT, handleController, reason => {
      respond({ type: 'parse' }, reason); stop('invalid_input', 74);
    }, () => stop('connection_lost', 74));
    child.stdin.on('error', () => stop('pi_input_lost', 74));
    child.stdin.on('drain', () => {
      clearTimeout(inputPressureTimer); inputPressureTimer = undefined;
      if (!pressureTimer && !stopping) input.resume();
    });
    output.on('drain', () => {
      clearTimeout(pressureTimer); pressureTimer = undefined;
      child.stdout.resume();
      if (!inputPressureTimer && !stopping) input.resume();
    });
    output.on('error', () => stop('connection_lost', 74));
    const onTerm = () => stop('signal', 143), onInt = () => stop('signal', 130);
    process.on('SIGTERM', onTerm); process.on('SIGHUP', onTerm); process.on('SIGINT', onInt);
    function finish(code, signal) {
      if (finished) return;
      const exitCode = stopping ? (stopCode || (code === 0 && !signal ? 0 : 74)) : (code || 74);
      send({ type: 'pi_run_worker_exit', schemaVersion: 1, scope: 'pi', reference, reason: stopReason, exitCode });
      finished = true;
      for (const timer of [pressureTimer, inputPressureTimer, killTimer, startupTimer]) clearTimeout(timer);
      clearInterval(ackTimer); clearInterval(heartbeat);
      for (const item of pending.values()) { clearTimeout(item.timer); item.rejectRequest(new Error('Pi exited')); }
      pending.clear();
      process.off('SIGTERM', onTerm); process.off('SIGHUP', onTerm); process.off('SIGINT', onInt);
      input.destroy();
      resolve(exitCode);
    }
    child.on('error', () => { stopReason = 'spawn_failed'; finish(74); });
    child.on('close', finish);
    startupTimer = setTimeout(() => stop('startup_timeout', 74), startupMs * 2);
    request('get_state').then(state => {
      if (stopping || finished) return;
      checkBinding(state);
      selected = { sessionId: state.sessionId, sessionFile: state.sessionFile };
      writeFileSync(`${control}/session.tmp`, JSON.stringify(selected), { mode: 0o600, flag: 'wx' });
      renameSync(`${control}/session.tmp`, `${control}/session.json`);
      ackTimer = setInterval(() => {
        if (!existsSync(`${control}/ack`) || stopping) return;
        clearInterval(ackTimer); clearTimeout(startupTimer);
        ready = true;
        send({ type: 'pi_run_worker_ready', schemaVersion: 1, reference, ...selected,
          commands: [...allowedCommands, 'extension_ui_response', 'pi_run_shutdown'] });
        heartbeat = setInterval(() => send({ type: 'pi_run_worker_heartbeat', schemaVersion: 1 }), heartbeatMs);
      }, 25);
    }).catch(() => stop('startup_failed', 74));
  });
  return done;
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  try {
    process.exitCode = await runWorker();
    // stdout can be disconnected or stalled; do not wait forever to flush exit facts.
    const deadline = setTimeout(() => process.exit(process.exitCode || 74), 1000);
    process.stdout.end(() => { clearTimeout(deadline); process.exit(process.exitCode); });
  } catch (error) {
    console.error(`pi-run Worker: ${error.message}`);
    process.exitCode = 74;
  }
}
