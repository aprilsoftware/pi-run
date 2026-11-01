#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
PROFILE_DIR="${PI_RUN_PROFILE_DIR:-/profile}"

if [[ "${CAF_FAILURE_LIVE_TESTS:-0}" != 1 ]]; then
    echo 'caf-failure-live-test: SKIP (set CAF_FAILURE_LIVE_TESTS=1 to contact the configured primary provider once)'
    exit 0
fi
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'caf-failure-live-test: Pi package unavailable' >&2; exit 1; }
[[ -d "${PROFILE_DIR}" ]] || { echo 'caf-failure-live-test: selected profile unavailable' >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

timeout 300s node --input-type=module - \
    "${ROOT}" "${PI_PACKAGE_DIR}" "${PROFILE_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [root, piDir, realProfileInput, tempRoot] = process.argv.slice(2);
const realProfile = resolve(realProfileInput), profile = join(tempRoot, 'profile'), workspace = join(tempRoot, 'workspace');
const readJson = async path => JSON.parse(await readFile(path, 'utf8'));
const settingsJson = await readJson(join(realProfile, 'settings.json'));
assert.equal(typeof settingsJson.defaultProvider, 'string', 'Configured primary provider is unavailable');
assert.equal(typeof settingsJson.defaultModel, 'string', 'Configured primary model is unavailable');
const primaryName = `${settingsJson.defaultProvider}/${settingsJson.defaultModel}`;
const protectedPaths = [join(realProfile, 'auth.json'), join(realProfile, 'models.json'), join(realProfile, 'settings.json')];
const before = new Map(await Promise.all(protectedPaths.map(async path => [path, await readFile(path)])));

await mkdir(join(profile, 'caf'), { recursive: true, mode: 0o700 });
await mkdir(workspace, { mode: 0o700 });
await writeFile(join(profile, 'AGENTS.md'), '# Synthetic CAF failure acceptance\nOnly fictional local failure handling is authorized. No friend contact is permitted.\n', { mode: 0o600 });
await writeFile(join(profile, 'caf', 'mode.json'), JSON.stringify({ schemaVersion: 1, defaultMode: 'on' }) + '\n', { mode: 0o600 });
await writeFile(join(profile, 'caf', 'config.json'), JSON.stringify({ schemaVersion: 1, model: null, thinking: null }) + '\n', { mode: 0o600 });
await writeFile(join(profile, 'caf', 'caf.md'), '# Synthetic CAF policy\nNo external friend disclosure is permitted.\n', { mode: 0o600 });
await writeFile(join(workspace, 'AGENTS.md'), '# Synthetic workspace\nNo command or workspace action is permitted.\n', { mode: 0o600 });
process.env.PI_RUN_PROFILE_DIR = profile;
process.env.PI_CODING_AGENT_DIR = profile;

const sdkImport = path => import(pathToFileURL(join(piDir, 'dist', path)).href);
const { createAgentSession } = await sdkImport('core/sdk.js');
const { DefaultResourceLoader } = await sdkImport('core/resource-loader.js');
const { SessionManager } = await sdkImport('core/session-manager.js');
const { SettingsManager } = await sdkImport('core/settings-manager.js');
const { ModelRuntime } = await sdkImport('core/model-runtime.js');
const { ReadOnlyAuthStorage } = await sdkImport('core/auth-storage.js');
const { InMemoryCodingAgentModelsStore } = await sdkImport('core/models-store.js');
const ai = await import(pathToFileURL(join(piDir, 'node_modules', '@earendil-works', 'pi-ai', 'dist', 'index.js')).href);
const modelRuntime = await ModelRuntime.create({
  credentials: new ReadOnlyAuthStorage(join(realProfile, 'auth.json')),
  modelsPath: join(realProfile, 'models.json'),
  modelsStore: new InMemoryCodingAgentModelsStore(),
  allowModelNetwork: false,
  refreshOnCreate: false,
});
const primaryModel = modelRuntime.getModel(settingsJson.defaultProvider, settingsJson.defaultModel);
assert.ok(primaryModel, `Configured primary model is unavailable: ${primaryName}`);
assert.equal(primaryModel.api, 'openai-completions', 'Live CAF failure acceptance requires an OpenAI-completions primary model');

const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const fixtureModel = { id: 'caf-failure-primary', name: 'Synthetic CAF failure primary', provider: 'caf-failure-fixture', api: 'openai-completions',
  baseUrl: 'https://synthetic.invalid', reasoning: false, input: ['text'], cost: usage.cost, contextWindow: 128000, maxTokens: 4096 };
const streamed = message => {
  const stream = ai.createAssistantMessageEventStream();
  queueMicrotask(() => {
    stream.push({ type: 'start', partial: { ...message, content: [], stopReason: 'pending' } });
    stream.push({ type: 'done', reason: message.stopReason, message });
    stream.end(message);
  });
  return stream;
};
const assistant = (content, stopReason) => ({ role: 'assistant', content, stopReason, api: fixtureModel.api,
  provider: fixtureModel.provider, model: fixtureModel.id, usage, timestamp: Date.now() });
let fixtureRequests = 0, primaryRequests = 0, settlementPayload;
const providerFixture = pi => {
  pi.registerProvider(fixtureModel.provider, {
    name: 'Synthetic CAF failure provider', baseUrl: fixtureModel.baseUrl, apiKey: 'synthetic-test-key', api: fixtureModel.api,
    models: [{ id: fixtureModel.id, name: fixtureModel.name, reasoning: false, input: ['text'], cost: fixtureModel.cost,
      contextWindow: fixtureModel.contextWindow, maxTokens: fixtureModel.maxTokens }],
    streamSimple: async (_selected, context, options) => {
      fixtureRequests++;
      if (fixtureRequests === 1) {
        const payload = { messages: context.messages, tools: [{ name: 'call_friend' }, { name: 'caf_failure_fixture' }] };
        await options?.onPayload?.(payload);
        return streamed(assistant([
          { type: 'toolCall', id: 'caf-failure-call', name: 'call_friend', arguments: {
            message: 'Assess a fictional local failure.', purpose: 'Synthetic failure-settlement acceptance',
          } },
          { type: 'toolCall', id: 'caf-failure-sibling', name: 'caf_failure_fixture', arguments: {} },
        ], 'toolUse'));
      }
      assert.equal(fixtureRequests, 2, 'The failure path must make exactly one settlement request');
      primaryRequests++;
      const capturePayload = async payload => {
        const transformed = await options?.onPayload?.(payload) ?? payload;
        settlementPayload = transformed;
        return transformed;
      };
      return modelRuntime.streamSimple(primaryModel, context, { ...options, onPayload: capturePayload, maxRetries: 0 });
    },
  });
  pi.registerTool({ name: 'caf_failure_fixture', label: 'CAF failure fixture', description: 'Return one inert synthetic result.',
    parameters: { type: 'object', properties: {}, additionalProperties: false }, async execute() {
      return { content: [{ type: 'text', text: 'Synthetic sibling completed.' }], details: undefined };
    } });
};

const settings = SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } });
const loader = new DefaultResourceLoader({ cwd: workspace, agentDir: profile, settingsManager: settings,
  additionalExtensionPaths: [join(root, 'docker', 'extensions', 'guard', 'guard-runtime.ts'), join(root, 'docker', 'extensions', 'caf', 'caf-agent.ts')],
  extensionFactories: [{ name: 'caf-failure-live-fixture', factory: providerFixture }] });
await loader.reload();
const { session, extensionsResult } = await createAgentSession({ cwd: workspace, agentDir: profile, modelRuntime, model: fixtureModel,
  thinkingLevel: 'off', resourceLoader: loader, sessionManager: SessionManager.inMemory(workspace), settingsManager: settings,
  tools: ['call_friend', 'caf_failure_fixture'], sessionStartEvent: { type: 'session_start', reason: 'new' } });
assert.deepEqual(extensionsResult.errors, []);
const events = [], unsubscribe = session.subscribe(event => events.push(event));
try {
  await session.prompt('Run the fictional local CAF failure-settlement acceptance.');
  assert.equal(fixtureRequests, 2);
  assert.equal(primaryRequests, 1);
  assert.ok(settlementPayload && typeof settlementPayload === 'object');
  assert.equal(Object.hasOwn(settlementPayload, 'tools'), false, 'Live settlement payload retained an empty tools field');
  assert.equal(events.filter(event => event.type === 'tool_execution_start' && event.toolName === 'call_friend').length, 1);
  const result = session.messages.findLast(message => message.role === 'toolResult' && message.toolName === 'call_friend');
  assert.equal(result?.details?.friendRequestStarted, false);
  assert.equal(result?.details?.retryAllowed, false);
  assert.equal(result?.details?.explainOnly, true);
  const finalAssistant = session.messages.findLast(message => message.role === 'assistant');
  assert.ok(finalAssistant, 'Primary provider returned no final assistant message');
  assert.notEqual(finalAssistant.stopReason, 'error', `Primary settlement failed: ${finalAssistant.errorMessage ?? 'unknown provider error'}`);
  const fallback = session.messages.find(message => message.role === 'custom' && message.customType === 'pi-run-caf-failure');
  assert.equal(fallback?.display, true, 'CAF did not persist a displayed failure fallback');
  assert.match(fallback?.content, /Nothing was sent to the friend/);
  assert.deepEqual(session.getActiveToolNames().sort(), ['caf_failure_fixture', 'call_friend']);
  assert.ok(events.some(event => event.type === 'agent_settled' && event.aborted === false));
} finally {
  unsubscribe();
  session.dispose();
}
for (const [path, expected] of before) assert.deepEqual(await readFile(path), expected, `Live acceptance changed ${path}`);
console.log(JSON.stringify({ event: 'caf_failure_live_result', primaryModel: primaryName, primaryRequests, friendRequests: 0,
  reviewerRequests: 0, searchRequests: 0, realProfileWrites: false, toolsRestored: true }));
NODE
