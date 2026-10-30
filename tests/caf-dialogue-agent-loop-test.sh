#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'caf-dialogue-agent-loop-test: Pi package unavailable' >&2; exit 1; }

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
await mkdir(join(profile, 'guard'), { mode: 0o700 });
await mkdir(join(profile, 'guardian'), { mode: 0o700 });
await mkdir(workspace, { mode: 0o700 });
await writeFile(join(profile, 'AGENTS.md'), '# Synthetic instructions\nOnly fictional test information may leave the primary session.\n', { mode: 0o600 });
await writeFile(join(profile, 'caf', 'mode.json'), JSON.stringify({ schemaVersion: 1, defaultMode: 'off' }) + '\n', { mode: 0o600 });
await writeFile(join(profile, 'caf', 'config.json'), JSON.stringify({ schemaVersion: 1, model: 'synthetic/friend', thinking: null }) + '\n', { mode: 0o600 });
await writeFile(join(profile, 'caf', 'caf.md'), '# Synthetic CAF policy\nAllow explicitly authorized fictional disclosures only.\n', { mode: 0o600 });
await writeFile(join(profile, 'guard', 'config.json'), JSON.stringify({ schemaVersion: 1, model: 'synthetic/reviewer', thinking: 'off' }) + '\n', { mode: 0o600 });
await writeFile(join(profile, 'guardian', 'mode.json'), JSON.stringify({ schemaVersion: 1, defaultMode: 'on' }) + '\n', { mode: 0o600 });
await writeFile(join(profile, 'guardian', 'guardian.md'), '# Synthetic Guardian policy\nReview protected commands independently.\n', { mode: 0o600 });
process.env.PI_RUN_PROFILE_DIR = profile;
process.env.PI_CODING_AGENT_DIR = profile;

const { createAgentSession } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'sdk.js')).href);
const { DefaultResourceLoader } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'resource-loader.js')).href);
const { SessionManager } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'session-manager.js')).href);
const { SettingsManager } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'settings-manager.js')).href);
const ai = await import(pathToFileURL(join(piDir, 'node_modules', '@earendil-works', 'pi-ai', 'dist', 'index.js')).href);
const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const model = id => ({ id, name: `Synthetic ${id}`, provider: 'synthetic', api: 'caf-dialogue-test',
  baseUrl: 'https://synthetic.invalid', reasoning: false, input: ['text'], cost: usage.cost, contextWindow: 128000, maxTokens: 4096 });
const primary = model('primary'), reviewer = model('reviewer'), friend = model('friend');
const primaryRequests = [], reviewerRequests = [], friendRequests = [];
const activeToolNames = messages => {
  const tools = new Map();
  for (const message of messages) if (message.role === 'system') {
    for (const tool of message.toolsRemoved ?? []) tools.delete(tool.name);
    for (const tool of message.toolsAdded ?? []) tools.set(tool.name, tool);
  }
  return [...tools.keys()];
};
const userJson = context => {
  const message = context.messages.findLast(item => item.role === 'user');
  const text = typeof message?.content === 'string' ? message.content : message?.content?.find(part => part.type === 'text')?.text;
  return JSON.parse(text);
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
const assistant = (selected, content, stopReason) => streamed({ role: 'assistant', content, stopReason,
  api: selected.api, provider: selected.provider, model: selected.id, usage, timestamp: Date.now() });
const providerExtension = pi => {
  pi.registerProvider('synthetic', {
    name: 'Synthetic CAF dialogue provider', baseUrl: primary.baseUrl, apiKey: 'synthetic-test-key', api: primary.api,
    models: [primary, reviewer, friend].map(({ id, name, reasoning, input, cost, contextWindow, maxTokens }) =>
      ({ id, name, reasoning, input, cost, contextWindow, maxTokens })),
    streamSimple: (selected, context) => {
      if (selected.id === 'reviewer') {
        const payload = userJson(context), sources = payload.evidence?.sources ?? [];
        const sourceId = sources.filter(source => source.role === 'user').at(-1)?.id;
        reviewerRequests.push({ payload, tools: activeToolNames(context.messages) });
        assert.ok(sourceId, 'reviewer must receive complete original user evidence');
        return assistant(selected, [{ type: 'toolCall', id: `review-${reviewerRequests.length}`, name: 'caf_guard_decide', arguments: {
          outcome: 'ALLOW', reason: 'The fictional multi-round consultation is explicitly authorized.', userMessageIds: [sourceId],
        } }], 'toolUse');
      }
      if (selected.id === 'friend') {
        const payload = userJson(context);
        friendRequests.push({ payload, tools: activeToolNames(context.messages), serialized: JSON.stringify(context) });
        if (friendRequests.length === 1) {
          assert.equal(payload.history, undefined);
          const questions = ['Is downtime permitted?','Must old and new schemas coexist?','Can deployment be staged?','Is rollback required?'].map(question =>
            ({ question, whyNeeded: 'It materially affects the fictional migration advice.', canProceedWithoutAnswer: false }));
          return assistant(selected, [{ type: 'toolCall', id: 'friend-question', name: 'caf_ask_primary', arguments: { questions } }], 'toolUse');
        }
        assert.equal(friendRequests.length, 2, 'consultation should use exactly two friend rounds');
        assert.equal(payload.message, 'Downtime is prohibited in this fictional migration.');
        assert.equal(payload.history.length, 1);
        assert.equal(payload.history[0].response.kind, 'questions');
        return assistant(selected, [{ type: 'text', text: 'Use a fictional expand-and-contract migration because downtime is prohibited.' }], 'stop');
      }
      assert.equal(selected.id, 'primary');
      const toolResults = context.messages.filter(message => message.role === 'toolResult' && message.toolName === 'call_friend');
      primaryRequests.push({ tools: activeToolNames(context.messages), toolResults });
      assert.deepEqual(activeToolNames(context.messages), ['call_friend']);
      if (primaryRequests.length === 1) return assistant(selected, [{ type: 'toolCall', id: 'primary-caf-1', name: 'call_friend', arguments: {
        message: 'Assess a fictional migration that must avoid downtime.', purpose: 'Obtain independent fictional architecture advice',
      } }], 'toolUse');
      if (primaryRequests.length === 2) {
        assert.equal(toolResults.length, 1);assert.equal(toolResults[0].details?.status, 'questions');
        assert.match(toolResults[0].content[0].text, /Is downtime permitted/);assert.match(toolResults[0].content[0].text, /Is rollback required/);
        return assistant(selected, [{ type: 'toolCall', id: 'primary-caf-2', name: 'call_friend', arguments: {
          message: 'Downtime is prohibited in this fictional migration.', purpose: 'Answer the CAF agent clarification',
        } }], 'toolUse');
      }
      assert.equal(primaryRequests.length, 3);assert.equal(toolResults.length, 2);assert.equal(toolResults.at(-1).details?.status, 'answer');
      return assistant(selected, [{ type: 'text', text: `CAF advised: ${toolResults.at(-1).content[0].text}` }], 'stop');
    },
  });
};
const settings = SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } });
const loader = new DefaultResourceLoader({ cwd: workspace, agentDir: profile, settingsManager: settings,
  additionalExtensionPaths: [join(root, 'docker', 'extensions', 'guard', 'guard-runtime.ts'), join(root, 'docker', 'extensions', 'guardian', 'guardian-agent.ts'), join(root, 'docker', 'extensions', 'caf', 'caf-agent.ts')],
  extensionFactories: [{ name: 'synthetic-caf-dialogue-provider', factory: providerExtension }] });
await loader.reload();
const sessionManager = SessionManager.inMemory(workspace);
const { session, extensionsResult } = await createAgentSession({ cwd: workspace, agentDir: profile, model: primary,
  thinkingLevel: 'off', resourceLoader: loader, sessionManager, settingsManager: settings,
  tools: ['call_friend'], sessionStartEvent: { type: 'session_start', reason: 'new' } });
assert.deepEqual(extensionsResult.errors, []);
await session.bindExtensions({ mode: 'json' });
await session.prompt('/guardian-model synthetic/reviewer');
await session.prompt('/guardian-thinking off');
await session.prompt('/guardian-mode on');
await session.prompt('/caf-model synthetic/friend');
await session.prompt('/caf-mode on');
const events = [], unsubscribe = session.subscribe(event => events.push(event));
const initialDirection = 'Consult the configured CAF agent about this fictional migration. If it asks, disclose that downtime is prohibited and continue the consultation automatically until it answers.';
try {
  await session.prompt(initialDirection);
  assert.equal(primaryRequests.length, 3);assert.equal(reviewerRequests.length, 2);assert.equal(friendRequests.length, 2);
  assert.equal(events.filter(event => event.type === 'tool_execution_start' && event.toolName === 'call_friend').length, 2);
  assert.ok(reviewerRequests.every(request => request.tools.includes('caf_history_search') && request.tools.includes('caf_guard_decide')));
  assert.equal(reviewerRequests[1].payload.disclosure.history.length, 1);
  assert.equal(reviewerRequests[1].payload.disclosure.message, 'Downtime is prohibited in this fictional migration.');
  assert.ok(friendRequests.every(request => !request.serialized.includes(initialDirection)), 'CAF agent must not receive the primary user direction implicitly');
  const rounds = sessionManager.getBranch().filter(entry => entry.type === 'custom' && entry.customType === 'pi-run-caf-round');
  assert.equal(rounds.length, 2);assert.equal(rounds[0].data.response.kind, 'questions');assert.equal(rounds[1].data.response.kind, 'answer');
  assert.equal(sessionManager.getBranch().filter(entry => entry.type === 'message' && entry.message.role === 'user').length, 1, 'no second user turn should be required');
  assert.match(session.getLastAssistantText(), /expand-and-contract/);
} finally {
  unsubscribe();session.dispose();
}
console.log('native primary, CAF reviewer, and CAF agent complete a guarded clarification loop without a second user turn');
NODE
