#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"

node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" <<'NODE'
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [root, piDir] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const packagePath = name => join(piDir, 'node_modules', '@earendil-works', name, 'dist', 'index.js');
const alias = {
  '@earendil-works/pi-agent-core': packagePath('pi-agent-core'),
  '@earendil-works/pi-tui': packagePath('pi-tui'),
  '@earendil-works/pi-coding-agent': join(piDir, 'dist', 'index.js'),
  '@earendil-works/pi-ai': join(piDir, 'node_modules', '@earendil-works', 'pi-ai', 'dist', 'compat.js'),
};
const g = await createJiti(import.meta.url, { alias, fsCache: false }).import(join(root, 'docker', 'extensions', 'guardian-agent.ts'));
const core = await import(pathToFileURL(packagePath('pi-agent-core')).href);
const ai = await import(pathToFileURL(join(piDir, 'node_modules', '@earendil-works', 'pi-ai', 'dist', 'compat.js')).href);

const workspace = await mkdtemp(join(tmpdir(), 'guardian-reviewer-'));
const controller = new AbortController();
try {
  const files = [];
  for (let i = 1; i <= 4; i++) {
    const path = join(workspace, `evidence-${i}.txt`);
    await writeFile(path, `${String(i).repeat(14_000)}\n`);
    files.push(path);
  }

  const model = {
    id: 'synthetic-reviewer', provider: 'synthetic', api: 'openai-responses',
    reasoning: false, contextWindow: 128_000, maxTokens: 4096,
  };
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
  const streamed = message => {
    const stream = ai.createAssistantMessageEventStream();
    queueMicrotask(() => {
      stream.push({ type: 'start', partial: { ...message, content: [], stopReason: 'pending' } });
      stream.push({ type: 'done', reason: message.stopReason, message });
      stream.end(message);
    });
    return stream;
  };
  const assistant = (content, stopReason = 'toolUse') => ({
    role: 'assistant', content, api: model.api, provider: model.provider, model: model.id,
    usage, stopReason, timestamp: Date.now(),
  });

  let providerRequests = 0;
  const reviewer = new g.PiAgentReviewer({
    model, thinking: 'off', requestedThinking: 'off', modelSource: 'test', thinkingSource: 'test',
    infrastructure: async () => ({ Agent: core.Agent, ai }),
    provider: async () => ({
      model,
      stream: (_model, context) => {
        providerRequests++;
        if (providerRequests === 1) {
          return streamed(assistant(files.map((path, index) => ({
            type: 'toolCall', id: `read-${index + 1}`, name: 'guardian_file_read',
            arguments: { path, offset: 1, limit: 500, question: 'Inspect the bounded fixture before deciding.' },
          }))));
        }
        return streamed(assistant([{ type: 'toolCall', id: 'decision', name: 'guardian_decide', arguments: {
          outcome: 'ALLOW', basis: 'standing_rules', reason: 'Synthetic bounded test decision.',
          userMessageIds: [], instructionRefs: [],
        } }]));
      },
    }),
  });

  const request = {
    action: { toolName: 'bash', toolCallId: 'synthetic', input: { command: 'printf test' }, cwd: workspace },
    instructions: [], conversation: [{ id: 'U1', role: 'user', text: 'Run the bounded synthetic reviewer test.', order: 0 }],
    priorEffects: [], toolDescription: 'Execute a bash command.',
    environment: { workspace, stateDirectory: workspace, profile: 'test', evidenceRoots: [workspace], notes: 'Synthetic fixture.' },
  };
  const events = [], started = Date.now(), deadlineAt = started + reviewer.budget.totalMs;
  const emit = (level, event, message, details) => events.push({ level, event, message, details });
  const trace = new g.ReviewTrace(emit, controller.signal, deadlineAt);
  const step = (name, details, work, timeout) => trace.step(name, details, work, timeout);
  const evidence = new g.EvidenceService(request, controller.signal, emit, step);
  const services = { signal: controller.signal, deadlineAt, evidence, step,
    report: event => emit(event.level, event.event, event.message, event.details) };

  const result = g.validateReviewResult(await reviewer.review(request, services), request);
  trace.close();
  assert.equal(result.status, 'completed', JSON.stringify({ result, events }, null, 2));
  assert.equal(result.decision.outcome, 'ALLOW');
  assert.equal(providerRequests, 2);
  assert.ok(events.some(event => event.event === 'reviewer_function_finished' && event.details?.isError === true &&
    String(event.details?.error).includes('Evidence return budget reached')),
  'Expected an explicit bounded-evidence failure before the decision turn');
  const requests = events.filter(event => event.event === 'model_request');
  assert.equal(requests.length, 2);
  assert.equal(requests[1].details.finalDecisionOnly, true);
  assert.ok(requests.every(event => event.details.requestBytes <= 96 * 1024));
  console.log('PASS guardian-reviewer: evidence budget preserves a final decision-only request');

  async function assess(streamForRequest, deadlineMs = 1000) {
    const scenarioController = new AbortController();
    let scenarioRequests = 0;
    const scenarioReviewer = new g.PiAgentReviewer({
      model, thinking: 'off', requestedThinking: 'off', modelSource: 'test', thinkingSource: 'test',
      infrastructure: async () => ({ Agent: core.Agent, ai }),
      provider: async () => ({ model, stream: (_model, context, options) =>
        streamForRequest(++scenarioRequests, context, options) }),
    });
    const scenarioEvents = [], deadlineAt = Date.now() + deadlineMs;
    const scenarioEmit = (level, event, message, details) => scenarioEvents.push({ level, event, message, details });
    const scenarioTrace = new g.ReviewTrace(scenarioEmit, scenarioController.signal, deadlineAt);
    const scenarioStep = (name, details, work, timeout) => scenarioTrace.step(name, details, work, timeout);
    const scenarioEvidence = new g.EvidenceService(request, scenarioController.signal, scenarioEmit, scenarioStep);
    const scenarioServices = { signal: scenarioController.signal, deadlineAt, evidence: scenarioEvidence, step: scenarioStep,
      report: event => scenarioEmit(event.level, event.event, event.message, event.details) };
    try {
      return { result: g.validateReviewResult(await scenarioReviewer.review(request, scenarioServices), request),
        events: scenarioEvents, requests: scenarioRequests };
    } finally {
      scenarioTrace.close();
      scenarioController.abort(new Error('Scenario finished'));
    }
  }

  const corrected = await assess(round => round === 1
    ? streamed(assistant([{ type: 'toolCall', id: 'contradictory', name: 'guardian_decide', arguments: {
      outcome: 'ALLOW', basis: 'missing_authorization', reason: 'Contradictory synthetic decision.',
      userMessageIds: [], instructionRefs: [],
    } }]))
    : streamed(assistant([{ type: 'toolCall', id: 'corrected', name: 'guardian_decide', arguments: {
      outcome: 'ASK', basis: 'uncertainty', reason: 'Corrected synthetic decision.',
      userMessageIds: [], instructionRefs: [],
    } }])));
  assert.equal(corrected.result.status, 'completed');
  assert.equal(corrected.result.decision.outcome, 'ASK');
  assert.equal(corrected.requests, 2);
  assert.ok(corrected.events.some(event => event.event === 'decision_validation_failed' &&
    String(event.details?.error).includes('contradicts outcome')));
  console.log('PASS guardian-reviewer: contradictory decision is rejected and corrected');

  const interrupted = await assess(() => streamed({
    ...assistant([{ type: 'toolCall', id: 'partial-decision', name: 'guardian_decide', arguments: {
      outcome: 'ALLOW', basis: 'standing_rules', reason: 'Partial decision must not be accepted.',
      userMessageIds: [], instructionRefs: [],
    } }], 'error'), errorMessage: 'Synthetic provider stream interrupted',
  }));
  assert.equal(interrupted.result.status, 'incomplete');
  assert.match(interrupted.result.error, /Synthetic provider stream interrupted/);
  assert.ok(!interrupted.events.some(event => event.event === 'decision_validated'));
  assert.ok(!interrupted.events.some(event => event.event === 'reviewer_function_started' &&
    event.details?.functionName === 'guardian_decide'));
  console.log('PASS guardian-reviewer: interrupted partial decision cannot authorize');

  let lateTimer;
  const lateDecision = assistant([{ type: 'toolCall', id: 'late-decision', name: 'guardian_decide', arguments: {
    outcome: 'ALLOW', basis: 'standing_rules', reason: 'Late decision must not be accepted.',
    userMessageIds: [], instructionRefs: [],
  } }]);
  const timedOut = await assess((_round, _context, _options) => {
    const stream = ai.createAssistantMessageEventStream();
    stream.push({ type: 'start', partial: { ...lateDecision, content: [], stopReason: 'pending' } });
    lateTimer = setTimeout(() => {
      try {
        stream.push({ type: 'done', reason: lateDecision.stopReason, message: lateDecision });
        stream.end(lateDecision);
      } catch { /* Simulate a provider that completes after its caller stopped listening. */ }
    }, 100);
    return stream;
  }, 40);
  assert.equal(timedOut.result.status, 'incomplete');
  assert.match(timedOut.result.error, /exceeded|deadline|timed out|timeout/i);
  assert.ok(timedOut.events.some(event => ['step_failed', 'step_cancelled'].includes(event.event) &&
    event.details?.timedOut === true), JSON.stringify(timedOut.events, null, 2));
  await new Promise(resolve => setTimeout(resolve, 120));
  clearTimeout(lateTimer);
  assert.ok(!timedOut.events.some(event => event.event === 'decision_validated'));
  console.log('PASS guardian-reviewer: timed-out and late decisions cannot authorize');
} finally {
  controller.abort(new Error('Test finished'));
  await rm(workspace, { recursive: true, force: true });
}
NODE
