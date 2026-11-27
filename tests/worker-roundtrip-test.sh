#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Local compatibility test, NOT host Docker acceptance. Node/Pi run here only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in node pi timeout mkfifo; do command -v "${command}" >/dev/null; done
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
mkdir -m 0700 "${TMP}/home" "${TMP}/profile" "${TMP}/sessions"
env -i PATH="${PATH}" HOME="${TMP}/home" PI_CODING_AGENT_DIR="${TMP}/profile" PI_OFFLINE=1 PI_TELEMETRY=0 \
    timeout --kill-after=15s 120s node --input-type=module - "${ROOT}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { spawn, execFileSync } from 'node:child_process';
import { createReadStream, createWriteStream, mkdirSync, readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [root, temp] = process.argv.slice(2), fixtures = join(root, 'tests/fixtures');
const { runWorker } = await import(pathToFileURL(join(root, 'docker/worker-rpc.mjs')));
const { startMockProvider, ROLE, BASELINE } = await import(pathToFileURL(join(fixtures, 'worker-roundtrip-provider.mjs')));
process.chdir(temp);
const trace = join(temp, 'provider.jsonl');
const server = await startMockProvider({ port: 0, trace });
const models = JSON.parse(readFileSync(join(fixtures, 'worker-roundtrip-models.json')));
models.providers['worker-fixture'].baseUrl = `http://127.0.0.1:${server.address().port}/v1`;
writeFileSync(join(temp, 'profile/models.json'), JSON.stringify(models));
writeFileSync(join(temp, 'profile/settings.json'), readFileSync(join(fixtures, 'worker-roundtrip-settings.json')));
writeFileSync(join(temp, 'baseline.txt'), BASELINE);
writeFileSync(join(temp, 'bound-role.txt'), ROLE);
const sessionDir = join(temp, 'sessions');
const reference = 'worker-v1:11111111-1111-4111-8111-111111111111';
async function run(phase, previous) {
  const control = join(temp, phase); mkdirSync(control);
  const input = new PassThrough(), output = new PassThrough();
  execFileSync('mkfifo', [join(control, 'to-worker'), join(control, 'from-worker')]);
  if (previous) writeFileSync(join(control, 'previous.json'), JSON.stringify(previous));
  const fromController = createReadStream(join(control, 'to-worker'));
  const toController = createWriteStream(join(control, 'from-worker'));
  fromController.pipe(input); output.pipe(toController);
  const args = ['--offline', '--no-extensions', '--no-skills', '--no-prompt-templates', '--no-themes', '--no-tools',
    '--no-context-files', '--mode', 'rpc', '--session-dir', sessionDir,
    '--append-system-prompt', join(temp, 'baseline.txt'), '--append-system-prompt', join(temp, 'bound-role.txt')];
  if (previous) args.push('--session', previous.identity.sessionFile);
  // Stand in only for the host binding handshake; Pi and the Worker adapter are real.
  const ack = setInterval(() => {
    if (existsSync(join(control, 'session.json'))) writeFileSync(join(control, 'ack'), 'ready\n');
    if (existsSync(join(control, 'ready.json'))) writeFileSync(join(control, 'provider-ready'), 'ready\n');
  }, 10);
  const done = runWorker({ command: 'pi', args, input, output, control, reference, sessionDir,
    expectedId: previous?.identity.sessionId ?? '', role: join(temp, 'bound-role.txt'), startupMs: 15000 });
  done.then(() => output.end());
  const client = spawn(process.execPath, [join(fixtures, 'worker-roundtrip-client.mjs'), control, phase],
    { stdio: ['ignore', 'inherit', 'inherit'] });
  const exited = new Promise((accept, reject) => { client.once('error', reject); client.once('exit', accept); });
  try {
    assert.equal(await exited, 0, 'FIFO controller must complete successfully');
    assert.equal(await done, 0);
    return JSON.parse(readFileSync(join(control, 'result.json')));
  } finally {
    clearInterval(ack); input.end();
    if (client.exitCode === null) client.kill('SIGTERM');
    await done;
    fromController.destroy(); toController.destroy();
  }
}
try {
  const first = await run('launch');
  assert(existsSync(first.identity.sessionFile));
  const header = JSON.parse(readFileSync(first.identity.sessionFile, 'utf8').split('\n')[0]);
  assert.equal(header.id, first.identity.sessionId);
  await run('resume', first);
  assert.equal(readdirSync(sessionDir).filter(f => f.endsWith('.jsonl')).length, 1);
  const events = readFileSync(trace, 'utf8').trim().split('\n').map(JSON.parse);
  assert.deepEqual(events.filter(e => e.type === 'request').map(e => e.prompt), ['first', 'second', 'block', 'after-abort', 'resumed']);
  assert.equal(events.filter(e => e.type === 'cancelled' && e.prompt === 'block').length, 1);
  assert(!events.some(e => e.type === 'error'));
  // Prove the provider rejects missing/changed Role and baseline instead of
  // blindly echoing a successful assertion report to the controller.
  const valid = { model: 'worker-fixture-model', stream: true, messages: [
    { role: 'system', content: `${BASELINE}\n${ROLE}` }, { role: 'user', content: 'worker-fixture:first' }] };
  for (const change of [
    body => { body.messages[0].content = BASELINE; },
    body => { body.messages[0].content = ROLE; },
    body => { body.messages[0].content += '\nWORKER_ROUNDTRIP_ROLE_CHANGED'; },
    body => { body.messages[1].content = 'unexpected input'; },
    body => { body.model = 'not-the-fixture'; },
  ]) {
    const body = structuredClone(valid); change(body);
    const response = await fetch(models.providers['worker-fixture'].baseUrl + '/chat/completions', {
      method: 'POST', headers: { 'content-type': 'application/json', authorization: 'Bearer worker-fixture-not-a-credential' },
      body: JSON.stringify(body), signal: AbortSignal.timeout(2000),
    });
    assert.equal(response.status, 400); await response.json();
  }
  console.log('worker-roundtrip-test: PASS (real installed Pi/adapter, FIFO controller, mock HTTP streaming, abort, exact resume and five negative provider checks; no Docker or live provider)');
} finally {
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
NODE
