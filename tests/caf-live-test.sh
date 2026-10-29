#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
PROFILE_DIR="${PI_RUN_PROFILE_DIR:-/profile}"

if [[ "${CAF_LIVE_TESTS:-0}" != 1 ]]; then
    echo 'caf-live-test: SKIP (set CAF_LIVE_TESTS=1 and CAF_LIVE_TEST_MODE=guarded|guarded-dialogue|unreviewed to contact configured providers)'
    exit 0
fi

case "${CAF_LIVE_TEST_MODE:-}" in
    guarded|guarded-dialogue|unreviewed) ;;
    *) echo 'caf-live-test: CAF_LIVE_TEST_MODE must be guarded, guarded-dialogue, or unreviewed' >&2; exit 2 ;;
esac
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'caf-live-test: Pi package unavailable' >&2; exit 1; }
[[ -d "${PROFILE_DIR}" ]] || { echo 'caf-live-test: selected profile unavailable' >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

timeout 900s node --input-type=module - \
    "${ROOT}" "${PI_PACKAGE_DIR}" "${PROFILE_DIR}" "${TMP}" "${CAF_LIVE_TEST_MODE}" <<'NODE'
import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [root, piDir, realProfileInput, tempRoot, mode] = process.argv.slice(2);
const guarded = mode !== 'unreviewed', dialogue = mode === 'guarded-dialogue';
const realProfile = resolve(realProfileInput), profile = join(tempRoot, 'profile'), workspace = join(tempRoot, 'workspace');
const readJson = async path => JSON.parse(await readFile(path, 'utf8'));
const optionalText = async path => { try { return await readFile(path, 'utf8'); } catch (error) { if (error?.code === 'ENOENT') return undefined; throw error; } };
const modelName = (value, label) => {
  assert.equal(typeof value, 'string', `${label} is not selected`);
  assert.match(value, /^[^/\s]+\/.+$/, `${label} is invalid`);
  return value;
};
const safeThinking = value => value === null || ['off','minimal','low','medium','high','xhigh','max'].includes(value);

const cafConfig = await readJson(join(realProfile, 'caf', 'config.json'));
assert.equal(cafConfig.schemaVersion, 1, 'CAF configuration schema is unsupported');
const friendName = modelName(cafConfig.model, 'CAF friend model');
assert.ok(safeThinking(cafConfig.thinking), 'CAF friend thinking is invalid');
let guardText = await optionalText(join(realProfile, 'guard', 'config.json'));
if (guardText === undefined) guardText = await readFile(join(realProfile, 'guardian', 'config.json'), 'utf8');
const sourceGuard = JSON.parse(guardText);
assert.equal(sourceGuard.schemaVersion, 1, 'Guard configuration schema is unsupported');
const reviewerName = modelName(sourceGuard.model, 'Guard reviewer model');
assert.ok(safeThinking(sourceGuard.thinking), 'Guard reviewer thinking is invalid');
if (guarded) assert.notEqual(reviewerName, friendName, 'Guard reviewer and friend must differ in guarded mode');

const protectedPaths = [join(realProfile, 'auth.json'), join(realProfile, 'models.json'), join(realProfile, 'caf', 'config.json'),
  ...(await optionalText(join(realProfile, 'guard', 'config.json')) === undefined ? [join(realProfile, 'guardian', 'config.json')] : [join(realProfile, 'guard', 'config.json')])];
const before = new Map(await Promise.all(protectedPaths.map(async path => [path, await readFile(path)])));

await mkdir(join(profile, 'guard'), { recursive: true, mode: 0o700 });
await mkdir(join(profile, 'caf'), { mode: 0o700 });
await mkdir(workspace, { mode: 0o700 });
await writeFile(join(profile, 'AGENTS.md'), '# Synthetic CAF candidate\nOnly the fixed fictional public API consultation and its fictional compatibility constraint are authorized.\n', { mode: 0o600 });
await writeFile(join(profile, 'guard', 'config.json'), JSON.stringify({ schemaVersion: 1, model: reviewerName, thinking: sourceGuard.thinking ?? null }) + '\n', { mode: 0o600 });
await writeFile(join(profile, 'caf', 'config.json'), JSON.stringify({ schemaVersion: 1, model: friendName, thinking: cafConfig.thinking ?? null }) + '\n', { mode: 0o600 });
await writeFile(join(profile, 'caf', 'caf.md'), '# Synthetic CAF policy\nAllow only the fixed fictional public API consultation and its fictional compatibility constraint.\n', { mode: 0o600 });
await writeFile(join(workspace, 'AGENTS.md'), '# Synthetic workspace\nNo real system or repository action is permitted.\n', { mode: 0o600 });
const modeFixture = join(tempRoot, 'guard-mode-fixture.ts');
await writeFile(modeFixture, `export default function(pi){let runtime;pi.events.on("pi-run:guard-runtime:v1:available",value=>{runtime=value;});pi.events.emit("pi-run:guard-runtime:v1:discover",{schemaVersion:1,accept(value){runtime=value;}});pi.on("session_start",()=>runtime.setReviewMode(${JSON.stringify(guarded ? 'on' : 'off')}));}\n`);

process.env.PI_RUN_PROFILE_DIR = profile;
process.env.PI_CODING_AGENT_DIR = profile;
const sdkImport = path => import(pathToFileURL(join(piDir, 'dist', path)).href);
const { loadExtensions } = await sdkImport('core/extensions/loader.js');
const { ExtensionRunner } = await sdkImport('core/extensions/runner.js');
const { SessionManager } = await sdkImport('core/session-manager.js');
const { ModelRuntime } = await sdkImport('core/model-runtime.js');
const { ModelRegistry } = await sdkImport('core/model-registry.js');
const { ReadOnlyAuthStorage } = await sdkImport('core/auth-storage.js');
const { InMemoryCodingAgentModelsStore } = await sdkImport('core/models-store.js');
const runtime = await ModelRuntime.create({
  credentials: new ReadOnlyAuthStorage(join(realProfile, 'auth.json')),
  modelsPath: join(realProfile, 'models.json'),
  modelsStore: new InMemoryCodingAgentModelsStore(),
  allowModelNetwork: false,
  refreshOnCreate: false,
});
const registry = new ModelRegistry(runtime), split = name => [name.slice(0, name.indexOf('/')), name.slice(name.indexOf('/') + 1)];
const reviewerDefinition = registry.find(...split(reviewerName)), friendModel = registry.find(...split(friendName));
assert.ok(reviewerDefinition, `Guard reviewer is unavailable: ${reviewerName}`);
assert.ok(friendModel, `CAF friend is unavailable: ${friendName}`);
const calls = { reviewer: 0, friend: 0, other: 0 };
const originalStream = registry.streamSimple.bind(registry);
registry.streamSimple = (model, context, options) => {
  const name = `${model.provider}/${model.id}`;
  if (name === reviewerName) calls.reviewer++;
  else if (name === friendName) calls.friend++;
  else calls.other++;
  return originalStream(model, context, options);
};

const runtimeFile = join(root, 'docker', 'extensions', 'guard', 'guard-runtime.ts'), cafFile = join(root, 'docker', 'extensions', 'caf', 'caf-agent.ts');
const loaded = await loadExtensions([runtimeFile, modeFixture, cafFile], workspace);
assert.deepEqual(loaded.errors, []);assert.equal(loaded.extensions.length, 3);
const session = SessionManager.inMemory(workspace), runner = new ExtensionRunner(loaded.extensions, loaded.runtime, workspace, session, registry);
const activeTools = ['call_friend'];
runner.bindCore({
  getActiveTools: () => activeTools,
  setActiveTools() {},
  appendEntry: (type, data) => session.appendCustomEntry(type, data),
  sendMessage() {}, sendUserMessage() {},
},{
  getModel: () => friendModel,
  getScopedModels: () => [],
  isIdle: () => true,
  isProjectTrusted: () => true,
  getSignal: () => undefined,
  abort() {}, hasPendingMessages: () => false, shutdown() {}, getContextUsage: () => undefined, compact() {}, getSystemPrompt: () => '',
  getCallableTools: () => [],
  executeTool: async () => { throw new Error('CAF live candidate does not permit nested tools'); },
});
runner.setUIContext({ notify() {}, setStatus() {}, setWidget() {}, select: async () => undefined, confirm: async () => false,
  input: async () => undefined, theme: { fg: (_role, text) => text } }, 'json');

const message = dialogue
  ? 'Review this fictional API migration. A final compatibility recommendation depends on whether existing fictional clients require the original array response or accept an envelope, and that fact is intentionally omitted. Before giving final advice, use caf_ask_primary to ask which response shape existing clients require. Do not assume.'
  : 'Review this fictional public API design: GET /widgets returns an array of public widget names and no private data. Suggest one concise compatibility improvement.';
const purpose = dialogue ? 'Obtain clarification-driven advice about a fictional public API migration' : 'Obtain independent advice about a fictional public API';
const toolCallId = 'caf-live-candidate';
const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const authorization = dialogue
  ? 'You may send exactly the fictional public API migration question in the next call to the configured friend. If it asks which response shape existing clients require, disclose only that fictional clients require the original array response and continue the consultation.'
  : 'You may send exactly the fictional public API question in the next call to the configured friend. Do not disclose anything else.';
session.appendMessage({ role: 'user', content: authorization, timestamp: Date.now() });
session.appendMessage({ role: 'assistant', api: friendModel.api, provider: friendModel.provider, model: friendModel.id, stopReason: 'toolUse', timestamp: Date.now(), usage,
  content: [{ type: 'toolCall', id: toolCallId, name: 'call_friend', arguments: { message, purpose } }] });

let result, firstResult;
try {
  await runner.emit({ type: 'session_start', reason: 'startup' });
  const caf = loaded.extensions[2], commandContext = runner.createCommandContext(), callFriend = caf.tools.get('call_friend').definition;
  await caf.commands.get('caf-mode').handler('on', commandContext);
  let controller = new AbortController();
  result = await callFriend.execute(toolCallId, { message, purpose }, controller.signal, undefined, runner.createToolContext(toolCallId, controller.signal));
  assert.equal(result.isError, undefined, result.content?.map(item => item.text).join(' ') || 'CAF candidate failed');
  if (dialogue) {
    firstResult = result;assert.equal(firstResult.details?.status, 'questions', 'CAF did not request the required fictional clarification');assert.equal(firstResult.details?.round, 1);
    const continuation = { message: 'Existing fictional clients require the original array response.', purpose: 'Answer the CAF clarification and obtain the final fictional compatibility recommendation' };
    const continuationId = 'caf-live-continuation';
    session.appendMessage({ role: 'toolResult', toolCallId, toolName: 'call_friend', content: firstResult.content, details: firstResult.details, isError: false, timestamp: Date.now() });
    session.appendMessage({ role: 'assistant', api: friendModel.api, provider: friendModel.provider, model: friendModel.id, stopReason: 'toolUse', timestamp: Date.now(), usage,
      content: [{ type: 'toolCall', id: continuationId, name: 'call_friend', arguments: continuation }] });
    controller = new AbortController();result = await callFriend.execute(continuationId, continuation, controller.signal, undefined, runner.createToolContext(continuationId, controller.signal));
    assert.equal(result.isError, undefined, result.content?.map(item => item.text).join(' ') || 'CAF continuation failed');assert.equal(result.details?.status, 'answer');assert.equal(result.details?.round, 2);assert.equal(result.details?.consultationId, firstResult.details?.consultationId);
  } else assert.ok(['answer','questions'].includes(result.details?.status), 'CAF returned an unexpected status');
  assert.equal(calls.friend, dialogue ? 2 : 1, `CAF candidate must make exactly ${dialogue ? 'two' : 'one'} friend request(s)`);
  assert.equal(calls.other, 0, 'CAF candidate contacted an unexpected model');
  if (guarded) assert.ok(calls.reviewer >= (dialogue ? 2 : 1), 'Guarded CAF candidate made too few reviewer requests');
  else assert.equal(calls.reviewer, 0, 'Unreviewed CAF candidate contacted the reviewer');
} finally {
  await runner.emit({ type: 'session_shutdown', reason: 'exit' });
}
for (const [path, expected] of before) assert.deepEqual(await readFile(path), expected, `Live candidate changed ${path}`);
const report = { event: 'caf_live_result', mode, status: result.details.status, consultationRounds: dialogue ? 2 : 1, reviewerModel: reviewerName, friendModel: friendName,
  reviewerRequests: calls.reviewer, friendRequests: calls.friend, otherModelRequests: calls.other, searchRequests: 0,
  realProfileWrites: false, commandExecution: false };
assert.deepEqual(Object.keys(report), ['event','mode','status','consultationRounds','reviewerModel','friendModel','reviewerRequests','friendRequests',
  'otherModelRequests','searchRequests','realProfileWrites','commandExecution']);
assert.equal(typeof report.reviewerModel, 'string');assert.equal(typeof report.friendModel, 'string');
console.log(JSON.stringify(report));
NODE
