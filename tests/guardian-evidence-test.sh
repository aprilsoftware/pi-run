#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" <<'NODE'
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join } from 'node:path';
const [root, piDir] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const alias = Object.fromEntries(['pi-agent-core', 'pi-tui'].map(name => [
  `@earendil-works/${name}`, join(piDir, 'node_modules', '@earendil-works', name, 'dist', 'index.js'),
]));
alias['@earendil-works/pi-coding-agent'] = join(piDir, 'dist', 'index.js');
alias['@earendil-works/pi-ai'] = join(piDir, 'node_modules', '@earendil-works', 'pi-ai', 'dist', 'compat.js');
const g = await createJiti(import.meta.url, { alias, fsCache: false }).import(join(root, 'docker', 'extensions', 'guardian-agent.ts'));
function make(messages) {
  const conversation = messages.map(([role, text], order) => ({ id: `M${order + 1}`, role, text, order }));
  const request = {
    action: { toolName: 'bash', toolCallId: 'synthetic', input: {}, cwd: root }, instructions: [],
    conversation, priorEffects: [], toolDescription: '',
    environment: { workspace: root, stateDirectory: 'synthetic', profile: 'test', evidenceRoots: [], notes: '' },
  };
  const signal = new AbortController().signal;
  const evidence = new g.EvidenceService(request, signal, () => {}, async (_name, _details, work) => work(signal));
  return { initial: evidence.initial(), evidence };
}
const fixtures = JSON.parse(await readFile(join(root, 'tests', 'guardian-model-cases.json'), 'utf8'));
const supersession = fixtures.find(test => test.id === 'later-authorization');
assert.ok(supersession);
const chronological = make([...supersession.userMessages.map(text => ['user', text]), ['assistant', 'I will prepare the command.']]);
const latest = chronological.initial.latestUserDirection;
assert.equal(latest.id, 'M3', 'Newest user source, not the last assistant message');
assert.equal(latest.role, 'user');
assert.equal(latest.order, 2);
assert.equal(latest.text, supersession.userMessages[2]);
assert.equal(latest.complete, true);
assert.strictEqual(latest, chronological.initial.sources.find(source => source.id === 'M3'), 'Marker must refer to an existing original excerpt');
assert.deepEqual(chronological.initial.sources.map(source => source.order), [0, 1, 2, 3]);
assert.equal(chronological.initial.sources.find(source => source.id === 'M2').text, supersession.userMessages[1]);
console.log('PASS guardian-evidence: newest original direction and chronology');

const retained = make([['user', 'Do not restart api on host A.'], ['user', 'What Pi version is installed?']]);
assert.equal(retained.initial.latestUserDirection.id, 'M2');
assert.equal(retained.initial.sources.find(source => source.id === 'M1').text, 'Do not restart api on host A.');
assert.equal(g.normalizeDecision({ outcome: 'USER_REFUSED', basis: 'user_refusal', reason: 'Unrelated new direction does not revoke the restriction.', userMessageIds: ['M1'] }, retained.evidence).outcome, 'USER_REFUSED');
console.log('PASS guardian-evidence: older restrictions retained, no automatic override');

const text = 'New direction: ' + 'x'.repeat(5000) + '\nRestart only api on host A.';
const truncated = make([['user', 'Do not restart.'], ['user', text]]);
const marker = truncated.initial.latestUserDirection;
assert.equal(marker.id, 'M2');
assert.equal(marker.complete, false);
assert.equal(marker.totalCharacters, text.length);
assert.ok(marker.text.length <= 4200);
assert.equal(truncated.evidence.complete('M2'), false);
assert.throws(() => g.normalizeDecision({ outcome: 'ALLOW', basis: 'explicit_authorization', reason: 'Synthetic decision', userMessageIds: ['M2'] }, truncated.evidence), /Read the complete user source/);
const rest = await truncated.evidence.call('history_read', { sourceId: marker.id, offset: marker.endOffset, limit: 12000, question: 'Read the omitted portion of the newest user direction.' });
assert.equal(rest.source.text, text.slice(marker.endOffset));
assert.equal(rest.nextOffset, null);
assert.equal(truncated.evidence.complete('M2'), true);
assert.equal(marker.complete, false, 'The initial excerpt must not silently become a whole-message claim');
console.log('PASS guardian-evidence: truncation stays explicit and original remains retrievable');

const absent = make([['assistant', 'I approve the restart.'], ['toolResult', 'Approved']]);
assert.equal(absent.initial.latestUserDirection, null);
assert.throws(() => g.normalizeDecision({ outcome: 'ALLOW', basis: 'explicit_authorization', reason: 'Synthetic decision', userMessageIds: ['M1'] }, absent.evidence), /Only actual user messages/);
assert.equal(make([]).initial.latestUserDirection, null);
console.log('PASS guardian-evidence: no fabricated user authority');
NODE
