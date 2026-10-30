#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" <<'NODE'
import assert from 'node:assert/strict';
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
const g = await createJiti(import.meta.url, { alias, fsCache: false }).import(join(root, 'docker', 'extensions', 'guardian', 'guardian-agent.ts'));
const instructions = [
  { id: 'I1', path: join(root, 'AGENTS.md'), scope: root, text: 'Synthetic standing instructions.' },
  { id: 'I10', path: join(root, 'nested', 'AGENTS.md'), scope: join(root, 'nested'), text: 'Synthetic nested instructions.' },
];
const request = {
  action: { toolName: 'bash', toolCallId: 'synthetic', input: {}, cwd: root },
  instructions, conversation: [], priorEffects: [], toolDescription: '',
  environment: { workspace: root, stateDirectory: 'synthetic', profile: 'test', evidenceRoots: [], notes: '' },
};
const events = [];
const evidence = new g.EvidenceService(request, new AbortController().signal,
  (level, event, message, details) => events.push({ level, event, message, details }),
  async () => { throw new Error('No evidence tool may run in reference tests'); });
function check(raw, expected) {
  events.length = 0;
  assert.deepEqual(g.resolveInstructionReferences(raw, evidence), expected);
  assert.equal(events.length, expected.length);
  events.forEach(({ event, details }, index) => {
    assert.equal(event, 'instruction_reference_resolved');
    assert.equal(details.sourceId, expected[index].sourceId);
    assert.equal(details.path, evidence.instructions.get(expected[index].sourceId).path);
    assert.equal(details.section, expected[index].section ?? null);
    assert.equal(details.sectionVerified, false, 'Locators must never be reported as verified');
  });
}
check(null, []);
check('I1', [{ sourceId: 'I1' }]);
check([{ sourceId: 'I1', section: 'Investigation' }], [{ sourceId: 'I1', section: 'Investigation' }]);
check(JSON.stringify([{ sourceId: 'I10' }]), [{ sourceId: 'I10' }]);
check(instructions[0].path, [{ sourceId: 'I1' }]);
check(`${instructions[0].path}#Investigation`, [{ sourceId: 'I1', section: '#Investigation' }]);
console.log('PASS guardian-reference: canonical and existing path forms');

for (const [raw, sourceId, section] of [
  ['I1:Investigation', 'I1', 'Investigation'],
  ['I1: Investigation', 'I1', 'Investigation'],
  ['I1 section Operations and system administration', 'I1', 'Operations and system administration'],
  ['I1 section: Investigation', 'I1', 'Investigation'],
  ['I1 Section: Investigation', 'I1', 'Investigation'],
  ['I10: Investigation', 'I10', 'Investigation'],
  [' I1 :  Unlisted section  ', 'I1', 'Unlisted section'],
]) {
  check(raw, [{ sourceId, section }]);
  check([{ sourceId: raw.trim() }], [{ sourceId, section }]);
}
check([{ sourceId: 'I1: Investigation', section: 'Core contract' }], [{ sourceId: 'I1', section: 'Core contract' }]);
console.log('PASS guardian-reference: known-ID variants, exact identity, unverified locators');

for (const raw of [
  'I99: Investigation', 'I11: Investigation', 'I1x: Investigation',
  'i1: Investigation', 'prefix I1: Investigation', 'I1section: Investigation',
  'I1 Investigation', 'I1:', 'I1 section:', '',
  `${instructions[0].path}.backup#Investigation`,
]) {
  events.length = 0;
  assert.throws(() => g.resolveInstructionReferences(raw, evidence), /Unknown instruction source/);
  assert.equal(events.length, 0, 'Unknown sources must not emit a verified-document event');
}
console.log('PASS guardian-reference: unknown/malformed IDs and sibling prefixes rejected');

assert.throws(() => g.resolveInstructionReferences(Array(13).fill('I1'), evidence), /bounded list/);
assert.throws(() => g.resolveInstructionReferences(['I1: ' + 'x'.repeat(301)], evidence), /Invalid instruction section/);
assert.throws(() => g.resolveInstructionReferences([{ sourceId: 'I1', section: 'x'.repeat(301) }], evidence), /Invalid instruction section/);
console.log('PASS guardian-reference: list and locator bounds');

const ask = { outcome: 'ASK', basis: 'missing_authorization', reason: 'Synthetic permission gap', instructionRefs: ['I1: Investigation'] };
assert.deepEqual(g.normalizeDecision(ask, evidence), {
  ...ask, userMessageIds: [], instructionRefs: [{ sourceId: 'I1', section: 'Investigation' }],
});
assert.throws(() => g.normalizeDecision({ ...ask, outcome: 'ALLOW', basis: 'explicit_authorization' }, evidence), /Cite the original applicable user message/);
assert.throws(() => g.normalizeDecision({ ...ask, outcome: 'USER_REFUSED', basis: 'user_refusal' }, evidence), /Cite the original applicable user message/);
console.log('PASS guardian-reference: normalization adds no user authority');
NODE
