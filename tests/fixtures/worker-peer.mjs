// SPDX-License-Identifier: MIT
// Deterministic Pi RPC peer: never loads credentials, tools, or a provider.
import { randomUUID } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { jsonLines } from '../../docker/worker-rpc.mjs';
const args = process.argv.slice(2);
const directory = process.env.PI_RUN_WORKER_SESSION_DIR;
const actualDir = process.env.FAKE_WORKER_SESSION_HOST;
const resumed = args.includes('--session');
const id = resumed ? process.env.PI_RUN_WORKER_SESSION_ID : randomUUID();
const file = resumed ? args[args.indexOf('--session') + 1] : `${directory}/2026-11-26T00-00-00-000Z_${id}.jsonl`;
let queued = [], running = false, prompts = 0;
const send = record => process.stdout.write(`${JSON.stringify(record)}\n`);
const response = (r, data) => send({ type: 'response', command: r.type, id: r.id, success: true, ...(data ? { data } : {}) });
const settled = () => { running = false; send({ type: 'agent_settled' }); };
if (process.env.FAKE_WORKER_BEHAVIOR === 'bad-output') console.log('not JSON');
jsonLines(process.stdin, 8 * 1024 * 1024, r => {
  if (process.env.FAKE_WORKER_TRACE) appendFileSync(process.env.FAKE_WORKER_TRACE, `${JSON.stringify(r)}\n`);
  if (r.type === 'get_state') {
    if (process.env.FAKE_WORKER_BEHAVIOR === 'hang-start') return;
    response(r, { sessionId: id, sessionFile: file, isStreaming: running, messageCount: prompts, pendingMessageCount: queued.length });
  } else if (r.type === 'prompt') {
    const actualFile = join(actualDir, basename(file));
    if (!existsSync(actualFile)) writeFileSync(actualFile, `${JSON.stringify({ type: 'session', version: 3, id, cwd: '/workspace', timestamp: new Date().toISOString() })}\n`, { mode: 0o600, flag: 'wx' });
    appendFileSync(actualFile, `${JSON.stringify({ type: 'message', message: { role: 'user', content: r.message } })}\n`);
    prompts++; running = true; response(r, { disposition: 'started' }); send({ type: 'agent_start' });
    if (r.message === 'question') send({ type: 'extension_ui_request', method: 'confirm', id: 'dialog-1', title: 'Approve?' });
    else if (r.message !== 'wait') { send({ type: 'message_end', message: { role: 'assistant', content: r.message } }); settled(); }
  } else if (r.type === 'extension_ui_response') {
    send({ type: 'fixture_interaction', confirmed: r.confirmed === true, cancelled: r.cancelled === true }); settled();
  } else if (r.type === 'follow_up' || r.type === 'steer') {
    const accept = () => { queued.push(r.message); response(r, { disposition: 'queued' }); };
    if (process.env.FAKE_WORKER_BEHAVIOR === 'delay-queue') setTimeout(accept, 80); else accept();
  } else if (r.type === 'clear_queue') {
    response(r, { steering: [], followUp: queued }); queued = [];
  } else if (r.type === 'abort') {
    if (process.env.FAKE_WORKER_BEHAVIOR === 'hang-abort') return;
    if (queued.length) send({ type: 'fixture_queue_ran', queued });
    if (process.env.FAKE_WORKER_BEHAVIOR === 'slow-abort') setTimeout(() => { settled(); response(r); }, 80);
    else { settled(); response(r); }
  } else if (r.type === 'get_messages') {
    const actualFile = join(actualDir, basename(file));
    response(r, { messages: existsSync(actualFile) ? readFileSync(actualFile, 'utf8') : '' });
  } else response(r);
}, () => process.exit(2), () => {
  if (process.env.FAKE_WORKER_BEHAVIOR === 'hang-exit') setInterval(() => {}, 1000);
});
