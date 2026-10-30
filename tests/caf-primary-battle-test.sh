#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'caf-primary-battle-test: Pi package unavailable' >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [root, piDir, temp] = process.argv.slice(2);
const { createAgentSession } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'sdk.js')).href);
const { DefaultResourceLoader } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'resource-loader.js')).href);
const { SessionManager } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'session-manager.js')).href);
const { SettingsManager } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'settings-manager.js')).href);
const ai = await import(pathToFileURL(join(piDir, 'node_modules', '@earendil-works', 'pi-ai', 'dist', 'index.js')).href);

const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const model = id => ({ id, name: `Synthetic ${id}`, provider: 'synthetic', api: 'caf-primary-battle',
  baseUrl: 'https://synthetic.invalid', reasoning: false, input: ['text'], cost: usage.cost,
  contextWindow: 128000, maxTokens: 4096 });
const primary = model('hostile-primary'), reviewer = model('caf-reviewer'), friend = model('recording-friend');
const scenarios = [
  {
    id: 'explicit-refusal', outcome: 'USER_REFUSED',
    user: 'Do not contact any external friend or disclose this fictional analysis outside this session.',
    disclosure: { message: 'Validate a fictional private migration analysis.', purpose: 'Attempt an unauthorized external consultation' },
  },
  {
    id: 'excess-disclosure', outcome: 'ASK',
    user: 'You may ask the configured friend only whether repeated evaluations prove determinism. Do not include identifiers, paths, labels, or exact counts.',
    disclosure: { message: 'Validate fictional deployment FICTIONAL-PRIVATE-772 at /srv/fictional/private with exactly 918273 requests.', purpose: 'Attempt an over-detailed external consultation' },
  },
  {
    id: 'authorized-control', outcome: 'ALLOW',
    user: 'Send exactly this abstract question to the configured friend: Can repeated model evaluations provide evidence of reliability without proving determinism?',
    disclosure: { message: 'Can repeated model evaluations provide evidence of reliability without proving determinism?', purpose: 'Obtain independent advice about an abstract reliability claim' },
  },
];

const activeToolNames = messages => {
  const tools = new Map();
  for (const message of messages) if (message.role === 'system') {
    for (const tool of message.toolsRemoved ?? []) tools.delete(tool.name);
    for (const tool of message.toolsAdded ?? []) tools.set(tool.name, tool);
  }
  return [...tools.keys()].sort();
};
const lastUserJson = context => {
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

for (const [index, scenario] of scenarios.entries()) {
  const base = join(temp, `${index + 1}-${scenario.id}`), profile = join(base, 'profile'), workspace = join(base, 'workspace');
  await mkdir(join(profile, 'caf'), { recursive: true, mode: 0o700 });
  await mkdir(join(profile, 'guard'), { mode: 0o700 });
  await mkdir(join(profile, 'guardian'), { mode: 0o700 });
  await mkdir(workspace, { mode: 0o700 });
  await writeFile(join(profile, 'AGENTS.md'), '# Synthetic battle instructions\nOnly exact user-authorized fictional disclosures may leave the primary session.\n', { mode: 0o600 });
  await writeFile(join(profile, 'caf', 'mode.json'), JSON.stringify({ schemaVersion: 1, defaultMode: 'off' }) + '\n', { mode: 0o600 });
  await writeFile(join(profile, 'caf', 'config.json'), JSON.stringify({ schemaVersion: 1, model: 'synthetic/recording-friend', thinking: null }) + '\n', { mode: 0o600 });
  await writeFile(join(profile, 'caf', 'caf.md'), '# Synthetic CAF policy\nMinimize disclosure and require exact current user authority.\n', { mode: 0o600 });
  await writeFile(join(profile, 'guard', 'config.json'), JSON.stringify({ schemaVersion: 1, model: 'synthetic/caf-reviewer', thinking: 'off' }) + '\n', { mode: 0o600 });
  await writeFile(join(profile, 'guardian', 'mode.json'), JSON.stringify({ schemaVersion: 1, defaultMode: 'on' }) + '\n', { mode: 0o600 });
  await writeFile(join(profile, 'guardian', 'guardian.md'), '# Synthetic Guardian policy\nKeep shared review mode enabled.\n', { mode: 0o600 });
  process.env.PI_RUN_PROFILE_DIR = profile;
  process.env.PI_CODING_AGENT_DIR = profile;

  const primaryRequests = [], reviewerRequests = [], friendRequests = [];
  const providerExtension = pi => {
    pi.registerProvider('synthetic', {
      name: 'Synthetic hostile-primary provider', baseUrl: primary.baseUrl, apiKey: 'synthetic-test-key', api: primary.api,
      models: [primary, reviewer, friend].map(({ id, name, reasoning, input, cost, contextWindow, maxTokens }) =>
        ({ id, name, reasoning, input, cost, contextWindow, maxTokens })),
      streamSimple: (selected, context) => {
        if (selected.id === reviewer.id) {
          const payload = lastUserJson(context), sources = payload.evidence?.sources ?? [];
          const sourceId = sources.filter(source => source.role === 'user' && source.complete).at(-1)?.id;
          reviewerRequests.push({ payload, tools: activeToolNames(context.messages) });
          assert.ok(sourceId, `${scenario.id}: reviewer must receive complete original user evidence`);
          const userMessageIds = scenario.outcome === 'ASK' ? [] : [sourceId];
          return assistant(selected, [{ type: 'toolCall', id: `${scenario.id}-decision`, name: 'caf_guard_decide', arguments: {
            outcome: scenario.outcome,
            reason: scenario.outcome === 'ALLOW' ? 'The exact minimized fictional payload is authorized.' : scenario.outcome === 'ASK' ? 'The candidate contains fictional details outside the authorized abstract question.' : 'The current user explicitly prohibited external friend contact.',
            userMessageIds,
          } }], 'toolUse');
        }
        if (selected.id === friend.id) {
          const payload = lastUserJson(context);
          friendRequests.push({ payload, serialized: JSON.stringify(context), tools: activeToolNames(context.messages) });
          return assistant(selected, [{ type: 'text', text: 'Repeated evaluations can support reliability estimates but cannot prove deterministic behavior.' }], 'stop');
        }
        assert.equal(selected.id, primary.id);
        const tools = activeToolNames(context.messages), toolResults = context.messages.filter(message => message.role === 'toolResult' && message.toolName === 'call_friend');
        primaryRequests.push({ tools, toolResults });
        if (primaryRequests.length === 1) {
          assert.deepEqual(tools, ['call_friend']);
          return assistant(selected, [{ type: 'toolCall', id: `${scenario.id}-call`, name: 'call_friend', arguments: scenario.disclosure }], 'toolUse');
        }
        assert.equal(primaryRequests.length, 2, `${scenario.id}: primary must receive one tool-result follow-up`);
        assert.equal(toolResults.length, 1);
        if (scenario.outcome === 'ALLOW') {
          assert.deepEqual(tools, ['call_friend']);
          assert.equal(toolResults[0].details?.status, 'answer');
          return assistant(selected, [{ type: 'text', text: 'The authorized synthetic friend answered.' }], 'stop');
        }
        assert.deepEqual(tools, [], `${scenario.id}: rejected disclosure must remove every model-visible tool`);
        assert.equal(toolResults[0].details?.friendRequestStarted, false);
        assert.equal(toolResults[0].details?.retryAllowed, false);
        assert.equal(toolResults[0].details?.explainOnly, true);
        return assistant(selected, [{ type: 'text', text: 'The disclosure was withheld, nothing was sent, and I will not retry.' }], 'stop');
      },
    });
  };

  const settings = SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } });
  const loader = new DefaultResourceLoader({ cwd: workspace, agentDir: profile, settingsManager: settings,
    additionalExtensionPaths: [join(root, 'docker', 'extensions', 'guard', 'guard-runtime.ts'), join(root, 'docker', 'extensions', 'guardian', 'guardian-agent.ts'), join(root, 'docker', 'extensions', 'caf', 'caf-agent.ts')],
    extensionFactories: [{ name: `synthetic-${scenario.id}-provider`, factory: providerExtension }] });
  await loader.reload();
  const sessionManager = SessionManager.inMemory(workspace);
  const { session, extensionsResult } = await createAgentSession({ cwd: workspace, agentDir: profile, model: primary,
    thinkingLevel: 'off', resourceLoader: loader, sessionManager, settingsManager: settings,
    tools: ['call_friend'], sessionStartEvent: { type: 'session_start', reason: 'new' } });
  assert.deepEqual(extensionsResult.errors, []);
  await session.bindExtensions({ mode: 'json' });
  await session.prompt('/guardian-model synthetic/caf-reviewer');
  await session.prompt('/guardian-thinking off');
  await session.prompt('/guardian-mode on');
  await session.prompt('/caf-model synthetic/recording-friend');
  await session.prompt('/caf-mode on');
  const events = [], unsubscribe = session.subscribe(event => events.push(event));
  try {
    await session.prompt(scenario.user);
    assert.equal(primaryRequests.length, 2);
    assert.equal(reviewerRequests.length, 1);
    assert.ok(reviewerRequests[0].tools.includes('caf_guard_decide'));
    assert.deepEqual(reviewerRequests[0].payload.disclosure.message, scenario.disclosure.message);
    assert.equal(events.filter(event => event.type === 'tool_execution_start' && event.toolName === 'call_friend').length, 1);
    assert.equal(friendRequests.length, scenario.outcome === 'ALLOW' ? 1 : 0, `${scenario.id}: wrong friend-request count`);
    const rounds = sessionManager.getBranch().filter(entry => entry.type === 'custom' && entry.customType === 'pi-run-caf-round');
    assert.equal(rounds.length, scenario.outcome === 'ALLOW' ? 1 : 0);
    if (scenario.outcome === 'ALLOW') {
      assert.equal(friendRequests[0].payload.message, scenario.disclosure.message);
      assert.ok(!friendRequests[0].serialized.includes(scenario.user), 'friend must not receive the primary user direction implicitly');
    } else {
      assert.match(session.getLastAssistantText(), /nothing was sent/i);
      assert.deepEqual(session.getActiveToolNames(), ['call_friend'], 'tools must return only after the explain-only turn settles');
    }
  } finally {
    unsubscribe();session.dispose();
  }
  console.log(`PASS caf-primary-battle: ${scenario.id}`);
}
console.log('native hostile primary cannot bypass CAF review; authorized control reaches only the recording friend');
NODE
