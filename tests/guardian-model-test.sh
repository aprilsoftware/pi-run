#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# SDK discovery and credentials are unnecessary for the default offline check.
if [[ "${GUARDIAN_LIVE_TESTS:-}" == 1 ]]; then
    export PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
fi

node --input-type=module - "${ROOT}" <<'NODE'
import assert from 'node:assert/strict';
import { copyFile, mkdir, readFile, mkdtemp, rm } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const cases = JSON.parse(await readFile(join(root, 'tests', 'guardian-model-cases.json'), 'utf8'));
assert.ok(Array.isArray(cases) && cases.length === 21, 'Expected twenty-one model-judgment fixtures');
const ids = new Set();
for (const test of cases) {
  assert.ok(test && typeof test === 'object' && !Array.isArray(test));
  assert.ok(Object.keys(test).every(k => ['id', 'description', 'expected', 'userMessages', 'messages', 'command', 'notes'].includes(k)));
  assert.match(test.id, /^[a-z]+(?:-[a-z]+)*$/);
  assert.ok(!ids.has(test.id), `Duplicate fixture: ${test.id}`); ids.add(test.id);
  assert.ok(['ALLOW', 'ASK', 'USER_REFUSED'].includes(test.expected));
  for (const key of ['description', 'command']) assert.ok(typeof test[key] === 'string' && test[key].trim() && test[key].length <= 4096);
  assert.equal(Number(Array.isArray(test.userMessages)) + Number(Array.isArray(test.messages)), 1,
    `${test.id} must define exactly one message fixture format`);
  const messages = test.messages ?? test.userMessages.map(text => ({ role: 'user', text }));
  assert.ok(messages.length >= 1 && messages.length <= 20);
  assert.ok(messages.some(message => message.role === 'user'));
  assert.ok(messages.every(message => message && typeof message === 'object' && !Array.isArray(message) &&
    Object.keys(message).every(key => ['role', 'text'].includes(key)) &&
    ['user', 'assistant'].includes(message.role) && typeof message.text === 'string' &&
    message.text.trim() && message.text.length <= 8192));
  assert.ok(test.notes === undefined || (typeof test.notes === 'string' && test.notes.length <= 4096));
}
console.log('PASS guardian-model: twenty-one fixture definitions');
function fixtureConversation(test) {
  const messages = test.messages ?? test.userMessages.map(text => ({ role: 'user', text }));
  let users = 0, assistants = 0;
  return messages.map(({ role, text }, order) => ({
    id: role === 'user' ? `U${++users}` : `A${++assistants}`, role, text, order,
  }));
}
function makeRequest(test, { workspace, profile, instructions }) {
  return {
    action: { toolName: 'bash', toolCallId: 'synthetic-neutral-action', input: { command: test.command, timeout: 30 }, cwd: workspace },
    instructions: structuredClone(instructions), priorEffects: [],
    conversation: fixtureConversation(test),
    toolDescription: 'Execute a bash command in the current working directory; optionally specify a timeout in seconds.',
    environment: { workspace, stateDirectory: profile, profile: process.env.PI_RUN_PROFILE || 'default', evidenceRoots: [workspace],
      notes: '/workspace and /profile are persistent host-backed resources. Host networking means localhost may reach the Docker host. Supplied access is not unlimited authority.' + (test.notes ? ' ' + test.notes : '') },
  };
}
// Exercise the live constructor without SDK discovery, credentials, or filesystem tools.
const offlineContext = { workspace: '/synthetic-workspace', profile: '/synthetic-profile', instructions: [] };
for (const test of cases) {
  const request = makeRequest(test, offlineContext);
  assert.equal(request.action.toolCallId, 'synthetic-neutral-action');
  assert.deepEqual(request.action.input, { command: test.command, timeout: 30 });
  assert.deepEqual(request.conversation, fixtureConversation(test));
  assert.ok(![request.action.toolCallId, ...request.conversation.map(row => row.id)].some(id => id.includes(test.id)));
  assert.equal(Object.hasOwn(request, 'expected'), false);
  assert.equal(Object.hasOwn(request, 'description'), false);
  assert.equal(Object.hasOwn(request, 'case'), false);
}
console.log('PASS guardian-model: neutral source/action IDs; commands, messages, roles, and ordering preserved');
if (process.env.GUARDIAN_LIVE_TESTS !== '1') {
  console.log('SKIP live reviews: explicitly set GUARDIAN_LIVE_TESTS=1 to call the configured provider');
  process.exit(0);
}
const requestedCaseIds = (process.env.GUARDIAN_TEST_CASES || '').split(',').map(value => value.trim()).filter(Boolean);
assert.equal(new Set(requestedCaseIds).size, requestedCaseIds.length, 'Duplicate requested case');
const selectedCases = requestedCaseIds.length ? cases.filter(test => requestedCaseIds.includes(test.id)) : cases;
assert.equal(selectedCases.length, requestedCaseIds.length || cases.length, 'Requested model case is unavailable');
const repetitions = Number(process.env.GUARDIAN_TEST_REPETITIONS || 1);
assert.ok(Number.isSafeInteger(repetitions) && repetitions >= 1 && repetitions <= 10, 'Repetitions must be an integer from 1 to 10');
const runs = Array.from({ length: repetitions }, (_, index) =>
  selectedCases.map(test => ({ test, repetition: index + 1 }))).flat();
const piDir = resolve(process.env.PI_PACKAGE_DIR);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const alias = Object.fromEntries(['pi-agent-core', 'pi-tui'].map(name => [
  `@earendil-works/${name}`, join(piDir, 'node_modules', '@earendil-works', name, 'dist', 'index.js'),
]));
alias['@earendil-works/pi-coding-agent'] = join(piDir, 'dist', 'index.js');
alias['@earendil-works/pi-ai'] = join(piDir, 'node_modules', '@earendil-works', 'pi-ai', 'dist', 'compat.js');
const g = await createJiti(import.meta.url, { alias, fsCache: false }).import(join(root, 'docker', 'extensions', 'guardian-agent.ts'));
const safe = value => g.parseGuardianLogChunks([{ name: 'memory', text: JSON.stringify({ event: 'model_test', details: value }) + '\n' }]).entries[0].details;
const sdkImport = path => import(pathToFileURL(join(piDir, 'dist', path)).href);
const { ModelRuntime, ModelRegistry } = await sdkImport('index.js');
const { ReadOnlyAuthStorage } = await sdkImport('core/auth-storage.js');
const { InMemoryCodingAgentModelsStore } = await sdkImport('core/models-store.js');
const profile = resolve(process.env.PI_RUN_PROFILE_DIR || '/profile');
const configPath = join(profile, 'guardian', 'config.json');
const originalConfig = await readFile(configPath, 'utf8');
const config = await g.loadGuardianConfig(profile);
assert.ok(config.model && config.thinking, 'Save explicit /guardian-model and /guardian-thinking preferences before live tests');
const requestedModels = (process.env.GUARDIAN_TEST_MODELS || config.model).split(',').map(value => value.trim()).filter(Boolean);
const requestedThinking = process.env.GUARDIAN_TEST_THINKING || config.thinking;
assert.ok(requestedModels.length >= 1 && requestedModels.length <= 4, 'Specify between one and four reviewer models');
const instructions = [
  { id: 'I1', path: join(profile, 'AGENTS.md'), scope: 'profile', text: await readFile(join(profile, 'AGENTS.md'), 'utf8') },
  { id: 'I2', path: join(profile, 'guardian', 'guardian.md'), scope: 'reviewer', text: await readFile(join(profile, 'guardian', 'guardian.md'), 'utf8') },
];
const runtime = await ModelRuntime.create({
  credentials: new ReadOnlyAuthStorage(join(profile, 'auth.json')), modelsPath: join(profile, 'models.json'),
  modelsStore: new InMemoryCodingAgentModelsStore(), allowModelNetwork: false, refreshOnCreate: false,
});
const registry = new ModelRegistry(runtime);
const selected = requestedModels.map(name => {
  const split = name.indexOf('/');
  assert.ok(split > 0 && split < name.length - 1, `Invalid reviewer model name: ${name}`);
  const model = registry.find(name.slice(0, split), name.slice(split + 1));
  assert.ok(model, `Reviewer model is unavailable: ${name}`);
  return { name, model };
});
console.log(JSON.stringify(safe({ event: 'suite_started', models: requestedModels, thinking: requestedThinking,
  cases: selectedCases.map(test => test.id), repetitions, reviewsPerModel: runs.length,
  commandExecution: false, credentials: 'read-only', catalogNetwork: false, modeIgnored: true })));
const workspace = await mkdtemp(join(tmpdir(), 'guardian-model-'));
await mkdir(join(workspace, 'tests'));
await Promise.all(['guardian-model-test.sh', 'guardian-model-cases.json'].map(name =>
  copyFile(join(root, 'tests', name), join(workspace, 'tests', name))));
const results = [];
try {
  for (const { name: modelName, model } of selected) {
    const testConfig = { ...config, model: modelName, thinking: requestedThinking };
    const binding = g.createPiReviewerBinding({
      pi: { getThinkingLevel: () => requestedThinking }, config: () => testConfig, changed() {}, tell() {}, log: () => () => {},
      async updateConfig() { throw new Error('Model tests cannot change preferences'); },
    });
    console.log(JSON.stringify({ event: 'model_started', model: modelName, thinking: requestedThinking }));
    for (const { test, repetition } of runs) {
      const request = makeRequest(test, { workspace, profile, instructions });
      const reviewer = binding.select({ modelRegistry: registry, model });
      assert.equal(reviewer.options.thinking, requestedThinking, `Thinking level is unsupported by ${modelName}`);
      const controller = new AbortController(), events = [], started = Date.now();
      const deadlineAt = started + reviewer.budget.totalMs;
      const emit = (level, event, message, details) => events.push({ level, event, details });
      const trace = new g.ReviewTrace(emit, controller.signal, deadlineAt);
      const step = (name, details, work, timeout) => trace.step(name, details, work, timeout);
      const evidence = new g.EvidenceService(request, controller.signal, emit, step);
      const services = { signal: controller.signal, deadlineAt, evidence, step, report: e => emit(e.level, e.event, e.message, e.details) };
      const timer = setTimeout(() => controller.abort(new Error('Model test review deadline reached')), reviewer.budget.totalMs);
      console.log(JSON.stringify({ event: 'case_started', model: modelName, case: test.id, repetition }));
      let result;
      try { result = g.validateReviewResult(await reviewer.review(request, services), request); }
      catch (e) { result = { status: 'incomplete', error: String(e.message ?? e) }; }
      finally { clearTimeout(timer); trace.close(); controller.abort(new Error('Assessment finished')); }
      const passed = result.status === 'completed' && result.decision.outcome === test.expected;
      const row = { event: 'case_result', model: modelName, case: test.id, repetition, status: passed ? 'PASS' : 'FAIL', expected: test.expected,
        reviewStatus: result.status, actual: result.decision?.outcome ?? null, basis: result.decision?.basis,
        reason: result.decision?.reason, userMessageIds: result.decision?.userMessageIds,
        seconds: Number(((Date.now() - started) / 1000).toFixed(3)),
        requests: result.metrics?.requests ?? events.filter(e => e.event === 'model_request').length,
        evidenceCalls: result.metrics?.evidenceCalls ?? 0,
        validationErrors: events.filter(e => e.event === 'decision_validation_failed').map(e => e.details?.error),
        error: result.error };
      results.push(row);
      console.log(JSON.stringify(safe(row)));
    }
    const modelResults = results.filter(row => row.model === modelName), failed = modelResults.filter(row => row.status === 'FAIL').length;
    console.log(JSON.stringify(safe({ event: 'model_finished', model: modelName, passed: modelResults.length - failed, failed,
      averageSeconds: modelResults.reduce((sum, row) => sum + row.seconds, 0) / modelResults.length })));
  }
  assert.equal(await readFile(configPath, 'utf8'), originalConfig, 'Saved Guardian configuration changed during tests');
} finally { await rm(workspace, { recursive: true, force: true }); }
const failed = results.filter(row => row.status === 'FAIL').length;
console.log(JSON.stringify(safe({ event: 'suite_finished', passed: results.length - failed, failed,
  averageSeconds: results.reduce((sum, row) => sum + row.seconds, 0) / results.length, settingsUnchanged: true })));
if (failed) process.exitCode = 1;
NODE
