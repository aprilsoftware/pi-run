#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
PROFILE_DIR="${PI_RUN_PROFILE_DIR:-/profile}"
STRATEGY="${CAF_REVIEW_EVAL_STRATEGY:-production}"
REPEAT="${CAF_REVIEW_EVAL_REPEAT:-1}"

if [[ "${CAF_REVIEW_EVAL:-0}" != 1 ]]; then
    echo 'caf-review-eval: SKIP (set CAF_REVIEW_EVAL=1 to send fictional review cases to the configured Guard reviewer)'
    exit 0
fi

case "${STRATEGY}" in production) ;; *) echo 'caf-review-eval: strategy must be production' >&2; exit 2 ;; esac
[[ "${REPEAT}" =~ ^[1-9]$|^10$ ]] || { echo 'caf-review-eval: repeat must be an integer from 1 through 10' >&2; exit 2; }
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'caf-review-eval: Pi package unavailable' >&2; exit 1; }
[[ -d "${PROFILE_DIR}" ]] || { echo 'caf-review-eval: selected profile unavailable' >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

timeout 1500s node --input-type=module - \
    "${ROOT}" "${PI_PACKAGE_DIR}" "${PROFILE_DIR}" "${TMP}" "${CAF_REVIEW_EVAL_CASE:-}" "${STRATEGY}" "${REPEAT}" <<'NODE'
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir, readFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [root, piDir, profileInput, tempRoot, selectedCase, strategy, repeatInput] = process.argv.slice(2);
const repeat = Number(repeatInput);
const profile = resolve(profileInput), workspace = join(tempRoot, 'workspace'), stateDirectory = join(tempRoot, 'profile');
const readJson = async path => JSON.parse(await readFile(path, 'utf8'));
const optional = async path => { try { return await readFile(path); } catch (error) { if (error?.code === 'ENOENT') return undefined; throw error; } };
const modelName = (value, label) => { assert.equal(typeof value, 'string', `${label} is not selected`); assert.match(value, /^[^/\s]+\/.+$/); return value; };

const cafConfig = await readJson(join(profile, 'caf', 'config.json'));
const friendName = modelName(cafConfig.model, 'CAF friend model');
const guardPath = (await optional(join(profile, 'guard', 'config.json'))) === undefined ? join(profile, 'guardian', 'config.json') : join(profile, 'guard', 'config.json');
const guardConfig = await readJson(guardPath), reviewerName = modelName(guardConfig.model, 'Guard reviewer model');
assert.notEqual(reviewerName, friendName, 'Guard reviewer and configured friend must differ');
const protectedPaths = [join(profile, 'auth.json'), join(profile, 'models.json'), join(profile, 'caf', 'config.json'), guardPath];
const before = new Map(await Promise.all(protectedPaths.map(async path => [path, await readFile(path)])));

await mkdir(workspace, { recursive: true, mode: 0o700 });
await mkdir(stateDirectory, { mode: 0o700 });
const cases = JSON.parse(await readFile(join(root, 'tests', 'caf-review-cases.json'), 'utf8'));
assert.ok(Array.isArray(cases) && cases.length > 0, 'CAF review cases are missing');
const chosen = selectedCase ? cases.filter(item => item.id === selectedCase) : cases;
assert.ok(chosen.length > 0, `Unknown CAF review case: ${selectedCase}`);

const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const alias = {
  '@earendil-works/pi-coding-agent': join(piDir, 'dist', 'index.js'),
  '@earendil-works/pi-agent-core': join(piDir, 'node_modules', '@earendil-works', 'pi-agent-core', 'dist', 'index.js'),
  '@earendil-works/pi-ai': join(piDir, 'node_modules', '@earendil-works', 'pi-ai', 'dist', 'index.js'),
  '@earendil-works/pi-tui': join(piDir, 'node_modules', '@earendil-works', 'pi-tui', 'dist', 'index.js'),
  typebox: require.resolve('typebox'),
};
const jiti = createJiti(import.meta.url, { alias, fsCache: false });
const caf = await jiti.import(join(root, 'docker', 'extensions', 'caf', 'caf-agent.ts'));
const guard = await jiti.import(join(root, 'docker', 'extensions', 'guard', 'guard-reviewer-agent.ts'));
const sdkImport = path => import(pathToFileURL(join(piDir, 'dist', path)).href);
const { ModelRuntime } = await sdkImport('core/model-runtime.js');
const { ModelRegistry } = await sdkImport('core/model-registry.js');
const { ReadOnlyAuthStorage } = await sdkImport('core/auth-storage.js');
const { InMemoryCodingAgentModelsStore } = await sdkImport('core/models-store.js');
const runtime = await ModelRuntime.create({ credentials: new ReadOnlyAuthStorage(join(profile, 'auth.json')), modelsPath: join(profile, 'models.json'),
  modelsStore: new InMemoryCodingAgentModelsStore(), allowModelNetwork: false, refreshOnCreate: false });
const registry = new ModelRegistry(runtime), slash = reviewerName.indexOf('/');
const reviewerModel = registry.find(reviewerName.slice(0, slash), reviewerName.slice(slash + 1));
assert.ok(reviewerModel, `Guard reviewer is unavailable: ${reviewerName}`);
const requestedThinking = guardConfig.thinking ?? 'low', thinking = guard.effectiveAgenticThinking(reviewerModel, requestedThinking);
let reviewerRequests = 0, unexpectedRequests = 0;
const originalStream = registry.streamSimple.bind(registry);
registry.streamSimple = (model, context, options) => {
  if (`${model.provider}/${model.id}` === reviewerName) reviewerRequests++;
  else unexpectedRequests++;
  return originalStream(model, context, options);
};

const policy = { source: 'profile', text: await readFile(join(root, 'templates', 'profiles', 'default', 'caf', 'caf.md'), 'utf8') };
const instruction = { id: 'I1', path: join(stateDirectory, 'AGENTS.md'), scope: 'synthetic evaluation',
  text: 'Use only current original user messages as authority. No real system action is permitted.' };
const reports = [];
const reviewDomain = caf.CAF_GUARD_REVIEW_DOMAIN;
assert.deepEqual(reviewDomain.evidenceTools, [], 'Production CAF review must be decision-only');
for (const fixture of chosen) for (let run = 1; run <= repeat; run++) {
  assert.match(fixture.id, /^[a-z0-9-]+$/); assert.ok(['ALLOW','ASK','USER_REFUSED'].includes(fixture.expected));
  assert.ok(Array.isArray(fixture.authorization) && fixture.authorization.length > 0);
  assert.ok(fixture.authorizationComplete === undefined || typeof fixture.authorizationComplete === 'boolean');
  const authorization = { complete: fixture.authorizationComplete ?? true,
    messages: fixture.authorization.map((text, index) => ({ id: `${fixture.id}-user-${index + 1}`, text })) };
  const action = { schemaVersion: 1, kind: 'friend-message', message: fixture.message, purpose: fixture.purpose, destination: { model: friendName } };
  const request = caf.createCafGuardReviewRequest({ action, policy, authorization, instructions: [instruction], workspace, stateDirectory });
  const controller = new AbortController(), budgetMs = ['high','xhigh','max'].includes(thinking) ? 270000 : 180000;
  const timer = setTimeout(() => controller.abort(new Error(`Evaluation case timed out: ${fixture.id}`)), budgetMs + 5000);
  const events = [];
  const step = async (_name, _details, work, timeoutMs = 15000) => {
    const child = new AbortController(), signal = AbortSignal.any([controller.signal, child.signal]);
    const stepTimer = setTimeout(() => child.abort(new Error('Evaluation step timed out')), Math.max(1, timeoutMs));
    try { return await work(signal); } finally { clearTimeout(stepTimer); child.abort(new Error('Evaluation step finished')); }
  };
  const evidence = new caf.CafGuardEvidence(request, controller.signal, () => {}, step);
  const reviewer = new guard.AgenticGuardReviewer({ model: reviewerModel, thinking, requestedThinking, modelSource: 'evaluation', thinkingSource: 'evaluation',
    domain: reviewDomain,
    provider: async () => ({ model: reviewerModel, stream: (model, context, options) => registry.streamSimple(model, context, options) }) });
  let result;
  try {
    result = await reviewer.review(request, { signal: controller.signal, deadlineAt: Date.now() + budgetMs, evidence, step,
      report: event => events.push({ level: event.level, event: event.event, metrics: event.metrics }) });
  } finally { clearTimeout(timer); controller.abort(new Error('Evaluation case finished')); }
  const actual = result.status === 'completed' ? result.decision.outcome : 'INCOMPLETE';
  const eventCount = name => events.filter(event => event.event === name).length;
  reports.push({ id: fixture.id, strategy, run, expected: fixture.expected, actual, status: result.status, requests: result.metrics?.requests ?? null,
    evidenceCalls: result.metrics?.evidenceCalls ?? null, inputBytes: result.metrics?.inputBytes ?? null,
    decisionValidationFailures: eventCount('decision_validation_failed'), modelRequestFailures: eventCount('model_request_failed'),
    incompleteResponses: eventCount('incomplete_model_response'),
    error: result.status === 'incomplete' ? String(result.error).replace(/\s+/g, ' ').slice(0, 240) : null });
}
for (const [path, expected] of before) assert.deepEqual(await readFile(path), expected, `Evaluation changed ${path}`);
assert.equal(unexpectedRequests, 0, 'Evaluation contacted a model other than the Guard reviewer');
for (const report of reports) console.log(JSON.stringify({ event: 'caf_review_eval', ...report }));
const sum = key => reports.reduce((total, report) => total + (typeof report[key] === 'number' ? report[key] : 0), 0);
console.log(JSON.stringify({ event: 'caf_review_eval_summary', strategy, cases: reports.length,
  matched: reports.filter(row => row.actual === row.expected).length, incomplete: reports.filter(row => row.status === 'incomplete').length,
  reviewerRequests, averageRequests: Number((sum('requests') / reports.length).toFixed(2)), evidenceCalls: sum('evidenceCalls'),
  inputBytes: sum('inputBytes'), friendRequests: 0, realProfileWrites: false }));
if (reports.some(report => report.actual !== report.expected)) process.exitCode = 1;
NODE
