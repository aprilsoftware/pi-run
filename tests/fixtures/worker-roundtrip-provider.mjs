// SPDX-License-Identifier: MIT
// Test-only OpenAI-compatible SSE endpoint. Never contacts a real provider.
import { createServer } from 'node:http';
import { appendFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const ROLE = 'WORKER_ROUNDTRIP_ROLE_ORIGINAL';
export const BASELINE = 'WORKER_ROUNDTRIP_BASELINE';
const prompts = new Set(['first', 'second', 'block', 'after-abort', 'resumed', 'queued-steer', 'queued-follow-up']);
const text = content => typeof content === 'string' ? content :
  Array.isArray(content) ? content.filter(b => b.type === 'text').map(b => b.text).join('\n') : '';

export async function startMockProvider({ port = 18888, trace, ready } = {}) {
  if (!trace) throw new Error('A disposable trace file is required');
  mkdirSync(dirname(trace), { recursive: true, mode: 0o700 });
  const record = value => appendFileSync(trace, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  let sequence = 0;
  const server = createServer(async (request, response) => {
    try {
      if (request.method !== 'POST' || request.url !== '/v1/chat/completions') throw new Error('Unexpected endpoint');
      if (request.headers.authorization !== 'Bearer worker-fixture-not-a-credential') throw new Error('Unexpected fixture authentication');
      let bytes = 0;
      const chunks = [];
      for await (const chunk of request) {
        bytes += chunk.length;
        if (bytes > 2 * 1024 * 1024) throw new Error('Oversized request');
        chunks.push(chunk);
      }
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (body.model !== 'worker-fixture-model' || body.stream !== true || !Array.isArray(body.messages)) {
        throw new Error('Unexpected model or request format');
      }
      const system = body.messages.filter(m => ['system', 'developer'].includes(m.role)).map(m => text(m.content)).join('\n');
      if (!system.includes(BASELINE) || !system.includes(ROLE) || system.includes('WORKER_ROUNDTRIP_ROLE_CHANGED')) {
        throw new Error('Baseline or immutable Role missing/changed');
      }
      const users = body.messages.filter(m => m.role === 'user').map(m => text(m.content));
      if (!users.length || users.some(value => !value.startsWith('worker-fixture:') || !prompts.has(value.slice(15)))) {
        throw new Error('Unexpected user input');
      }
      const prompt = users.at(-1).slice(15);
      const priorReplies = body.messages.filter(m => m.role === 'assistant').flatMap(m => {
        try { const reply = JSON.parse(text(m.content)); return reply.fixture === 'worker-roundtrip' ? [reply.prompt] : []; }
        catch { return []; } // Partial aborted assistant turns are not completed replies.
      });
      const report = { fixture: 'worker-roundtrip', prompt, users, priorReplies, role: true, baseline: true };
      record({ type: 'request', ...report }); // Only known fixture text; never headers or raw system prompts.
      const id = `chatcmpl-worker-fixture-${++sequence}`;
      response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      const event = (delta, finish_reason = null) => response.write(`data: ${JSON.stringify({
        id, object: 'chat.completion.chunk', created: 1, model: body.model,
        choices: [{ index: 0, delta, finish_reason }],
      })}\n\n`);
      event({ role: 'assistant', content: '' });
      if (prompt === 'block') {
        event({ content: 'worker-fixture:block-open' });
        // Remain genuinely in flight until Pi cancels the HTTP stream.
        const heartbeat = setInterval(() => response.write(': waiting for abort\n\n'), 1000);
        response.once('close', () => {
          clearInterval(heartbeat);
          record({ type: 'cancelled', prompt });
        });
      } else {
        event({ content: JSON.stringify(report) });
        event({}, 'stop');
        response.write(`data: ${JSON.stringify({ id, object: 'chat.completion.chunk', created: 1,
          model: body.model, choices: [], usage: { prompt_tokens: 64, completion_tokens: 32, total_tokens: 96 } })}\n\n`);
        response.end('data: [DONE]\n\n');
      }
    } catch (error) {
      record({ type: 'error', error: error.message });
      if (!response.headersSent) response.writeHead(400, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ error: { message: 'Offline fixture rejected request', type: 'fixture_error' } }));
    }
  });
  server.requestTimeout = 10000;
  await new Promise((accept, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', accept);
  });
  if (ready) writeFileSync(ready, JSON.stringify({ port: server.address().port }), { mode: 0o600 });
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  await startMockProvider({ trace: process.argv[2], ready: '/tmp/worker-roundtrip-provider-ready.json' });
}
