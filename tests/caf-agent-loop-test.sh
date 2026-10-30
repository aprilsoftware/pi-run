#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'caf-agent-loop-test: Pi package unavailable' >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [root, piDir, temp] = process.argv.slice(2);
const profile = join(temp, 'profile'), workspace = join(temp, 'workspace');
await mkdir(join(profile, 'caf'), { recursive: true, mode: 0o700 });
await mkdir(workspace, { mode: 0o700 });
await writeFile(join(profile, 'caf', 'mode.json'), JSON.stringify({ schemaVersion: 1, defaultMode: 'off' }) + '\n', { mode: 0o600 });
await writeFile(join(profile, 'caf', 'config.json'), JSON.stringify({ schemaVersion: 1, model: 'synthetic/friend', thinking: null }) + '\n', { mode: 0o600 });
await writeFile(join(profile, 'caf', 'caf.md'), '# Synthetic CAF policy\nAllow only explicit fictional tests.\n', { mode: 0o600 });
process.env.PI_RUN_PROFILE_DIR = profile;
process.env.PI_CODING_AGENT_DIR = profile;

const { createAgentSession } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'sdk.js')).href);
const { DefaultResourceLoader } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'resource-loader.js')).href);
const { SessionManager } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'session-manager.js')).href);
const { SettingsManager } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'settings-manager.js')).href);
const ai = await import(pathToFileURL(join(piDir, 'node_modules', '@earendil-works', 'pi-ai', 'dist', 'index.js')).href);
const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const model = { id: 'primary', name: 'Synthetic Primary', provider: 'synthetic', api: 'caf-loop-test',
  baseUrl: 'https://synthetic.invalid', reasoning: false, input: ['text'], cost: usage.cost,
  contextWindow: 128000, maxTokens: 4096 };
const requests = [];
const activeToolNames = messages => {
  const tools = new Map();
  for (const message of messages) if (message.role === 'system') {
    for (const tool of message.toolsRemoved ?? []) tools.delete(tool.name);
    for (const tool of message.toolsAdded ?? []) tools.set(tool.name, tool);
  }
  return [...tools.keys()].sort();
};
const streamed = message => {
  const stream = ai.createAssistantMessageEventStream();
  queueMicrotask(() => {
    stream.push({ type: 'start', partial: { ...message, content: [], stopReason: 'pending' } });
    stream.push({ type: 'done', reason: message.stopReason, message });
    stream.end(message);
  });
  return stream;
};
const assistant = (content, stopReason) => ({ role: 'assistant', content, stopReason,
  api: model.api, provider: model.provider, model: model.id, usage, timestamp: Date.now() });
const providerExtension = pi => {
  pi.registerProvider('synthetic', {
    name: 'Synthetic CAF loop provider', baseUrl: model.baseUrl, apiKey: 'synthetic-test-key', api: model.api,
    models: [{ id: model.id, name: model.name, reasoning: false, input: ['text'], cost: model.cost,
      contextWindow: model.contextWindow, maxTokens: model.maxTokens }],
    streamSimple: (_selected, context) => {
      const tools = activeToolNames(context.messages), toolResults = context.messages.filter(message => message.role === 'toolResult');
      requests.push({ tools, toolResults: toolResults.length });
      if (requests.length === 1) {
        assert.deepEqual(tools, ['call_friend']);
        assert.equal(toolResults.length, 0);
        return streamed(assistant([{ type: 'toolCall', id: 'caf-loop-call', name: 'call_friend', arguments: {
          message: 'Assess a fictional abstract reliability statement.', purpose: 'Synthetic failure-workflow test',
        } }], 'toolUse'));
      }
      assert.equal(requests.length, 2, 'The primary must receive exactly one explain-only follow-up');
      assert.deepEqual(tools, [], 'No tool may be model-visible during the explain-only follow-up');
      assert.equal(toolResults.length, 1);
      assert.equal(toolResults[0].toolName, 'call_friend');
      assert.equal(toolResults[0].details?.friendRequestStarted, false);
      assert.equal(toolResults[0].details?.retryAllowed, false);
      assert.equal(toolResults[0].details?.explainOnly, true);
      assert.match(toolResults[0].content[0].text, /Nothing was sent to the friend/);
      return streamed(assistant([{ type: 'text', text: 'Call a Friend is disabled for this session, so nothing was sent. Enable CAF before trying again.' }], 'stop'));
    },
  });
};
const settings = SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } });
const loader = new DefaultResourceLoader({ cwd: workspace, agentDir: profile, settingsManager: settings,
  additionalExtensionPaths: [join(root, 'docker', 'extensions', 'guard', 'guard-runtime.ts'), join(root, 'docker', 'extensions', 'caf', 'caf-agent.ts')],
  extensionFactories: [{ name: 'synthetic-caf-loop-provider', factory: providerExtension }] });
await loader.reload();
const { session, extensionsResult } = await createAgentSession({ cwd: workspace, agentDir: profile, model,
  thinkingLevel: 'off', resourceLoader: loader, sessionManager: SessionManager.inMemory(workspace), settingsManager: settings,
  tools: ['call_friend'], sessionStartEvent: { type: 'session_start', reason: 'new' } });
assert.deepEqual(extensionsResult.errors, []);
const events = [];
const unsubscribe = session.subscribe(event => events.push(event));
try {
  assert.deepEqual(session.getActiveToolNames(), ['call_friend']);
  await session.prompt('Run the fictional CAF failure-workflow test.');
  assert.equal(requests.length, 2);
  assert.equal(events.filter(event => event.type === 'tool_execution_start' && event.toolName === 'call_friend').length, 1);
  assert.ok(events.some(event => event.type === 'agent_settled' && event.aborted === false));
  assert.match(session.getLastAssistantText(), /nothing was sent/i);
  assert.deepEqual(session.getActiveToolNames(), ['call_friend'], 'The original tool set must return only after settlement');
} finally {
  unsubscribe();
  session.dispose();
}
console.log('native Pi agent loop explains CAF failure once, hides tools, and restores them after settlement');
NODE
