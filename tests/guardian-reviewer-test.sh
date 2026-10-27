#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"

node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" <<'NODE'
import assert from 'node:assert/strict';
import { chmod, link, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
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
const jiti = createJiti(import.meta.url, { alias, fsCache: false });
const g = await jiti.import(join(root, 'docker', 'extensions', 'guardian', 'guardian-agent.ts'));
const shared = await jiti.import(join(root, 'docker', 'extensions', 'guard', 'guard-reviewer-agent.ts'));
const dockerfile = await readFile(join(root, 'docker', 'Dockerfile'), 'utf8');
assert.ok(dockerfile.includes('COPY extensions/guard/guard-reviewer-agent.ts /usr/local/lib/node_modules/pi-run-extensions/guard/'));
const core = await import(pathToFileURL(packagePath('pi-agent-core')).href);
const ai = await import(pathToFileURL(join(piDir, 'node_modules', '@earendil-works', 'pi-ai', 'dist', 'compat.js')).href);
const {createEventBus}=await import(pathToFileURL(join(piDir,'dist/core/event-bus.js')).href);
const commands=new Set(),commandPi={events:createEventBus(),on:()=>()=>{},registerCommand:name=>commands.add(name),registerTool(){},getActiveTools:()=>[],setActiveTools(){}};
g.default(commandPi);assert.ok(commands.has('guardian-model'));assert.ok(commands.has('guardian-thinking'));assert.ok(!commands.has('guard-model'));assert.ok(!commands.has('guard-thinking'));

const workspace = await mkdtemp(join(tmpdir(), 'guardian-reviewer-'));
const controller = new AbortController();
try {
  assert.deepEqual(shared.defaultGuardReviewerConfig(),{schemaVersion:1,model:null,thinking:null});
  const explicit={schemaVersion:1,model:'trusted/reviewer',thinking:'high'};
  assert.deepEqual(shared.parseGuardReviewerConfig(JSON.stringify(explicit)),explicit);
  assert.deepEqual(shared.adoptLegacyGuardReviewerConfig({model:'trusted/reviewer',thinking:'low'}),{schemaVersion:1,model:'trusted/reviewer',thinking:'low'});
  assert.deepEqual(shared.adoptLegacyGuardReviewerConfig({model:null,thinking:'high'}),shared.defaultGuardReviewerConfig(),
    'A legacy null model must not become a conversation-model fallback');
  for(const value of [null,{},[],{...explicit,schemaVersion:2},{...explicit,model:'invalid'},{...explicit,thinking:'extreme'},{...explicit,extra:true}])
    assert.throws(()=>shared.parseGuardReviewerConfig(JSON.stringify(value)),/Invalid Guard reviewer configuration/);
  const profile=join(workspace,'profile');await mkdir(profile,{mode:0o700});
  await assert.rejects(shared.loadGuardReviewerConfig(profile),error=>error?.code==='ENOENT');
  await shared.saveGuardReviewerConfig(profile,explicit);
  assert.equal((await stat(join(profile,'guard'))).mode&0o777,0o700);assert.equal((await stat(join(profile,'guard','config.json'))).mode&0o777,0o600);
  assert.deepEqual(await shared.loadGuardReviewerConfig(profile),explicit);
  assert.equal(await readFile(join(profile,'guard','config.json'),'utf8'),JSON.stringify(explicit)+'\n');
  const hardlink=join(profile,'guard','config-copy.json');await link(join(profile,'guard','config.json'),hardlink);
  await assert.rejects(shared.loadGuardReviewerConfig(profile),/single-link regular file/);await rm(hardlink);
  const redirected=join(workspace,'redirected-profile'),target=join(workspace,'redirect-target');
  await mkdir(redirected,{mode:0o700});await mkdir(target,{mode:0o700});await symlink(target,join(redirected,'guard'));
  await assert.rejects(shared.saveGuardReviewerConfig(redirected,explicit),/must not be redirected/);
  await chmod(join(profile,'guard'),0o755);await assert.rejects(shared.loadGuardReviewerConfig(profile),/must be private/);await chmod(join(profile,'guard'),0o700);
  const unselectedBinding=g.createPiReviewerBinding({pi:{getThinkingLevel:()=> 'high'},config:()=>shared.defaultGuardReviewerConfig(),
    changed(){},async updateConfig(){},tell(){},log:()=>()=>{}});
  assert.equal(unselectedBinding.controls,undefined,'Shared reviewer controls must not be implemented by the Guardian reviewer binding');
  assert.throws(()=>unselectedBinding.select({modelRegistry:{find(){throw new Error('must not resolve a conversation fallback');}}}),/model is not selected/);
  const backendHandlers=new Map(),backendPi={on:(name,handler)=>{backendHandlers.set(name,handler);return()=>backendHandlers.delete(name);}};
  const previousProfile=process.env.PI_RUN_PROFILE_DIR;process.env.PI_RUN_PROFILE_DIR=profile;
  const backend=shared.createAgenticGuardReviewBackend(backendPi);
  if(previousProfile===undefined)delete process.env.PI_RUN_PROFILE_DIR;else process.env.PI_RUN_PROFILE_DIR=previousProfile;
  const configuredModel={id:'reviewer',provider:'trusted',api:'openai-responses',reasoning:false,contextWindow:128_000,maxTokens:4096};
  const resolutions=[];backendHandlers.get('session_start')({}, {modelRegistry:{find:(provider,id)=>{resolutions.push(`${provider}/${id}`);return provider==='trusted'&&id==='reviewer'?configuredModel:undefined;}}});
  let backendSelection;
  shared.registerAgenticGuardReviewDomain(backendPi,'guardian','guardian-command.v1','guardian-decision.v1',{async review(_request,_context,_session,selection){backendSelection=selection;return {schemaVersion:1,status:'completed',decision:{outcome:'ALLOW'}};}});
  const backendResult=await backend.review({schemaVersion:1,client:{schemaVersion:1,id:'guardian',label:'Guardian',evidenceProfile:'guardian-command.v1',decisionContract:'guardian-decision.v1'},action:{},policy:{}},
    {signal:new AbortController().signal,report(){}});
  assert.equal(backendResult.status,'completed');assert.deepEqual(resolutions,['trusted/reviewer']);assert.equal(backendSelection.model,configuredModel);
  assert.equal(backendSelection.requestedThinking,'high');assert.equal(backendSelection.thinking,'off');assert.equal(backendSelection.modelSource,'guard_file');
  assert.equal(backendSelection.thinkingSource,'guard_config');assert.equal(backendSelection.budget.totalMs,180_000);
  console.log('PASS guardian-reviewer: private shared config, backend-owned resolution, explicit legacy adoption, and no implicit model fallback');

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
  assert.ok(reviewer instanceof shared.AgenticGuardReviewer, 'Guardian must use the extracted agentic review harness');

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

  async function assess(streamForRequest, deadlineMs = 1000, scenarioRequest = request) {
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
    const scenarioEvidence = new g.EvidenceService(scenarioRequest, scenarioController.signal, scenarioEmit, scenarioStep);
    const scenarioServices = { signal: scenarioController.signal, deadlineAt, evidence: scenarioEvidence, step: scenarioStep,
      report: event => scenarioEmit(event.level, event.event, event.message, event.details) };
    try {
      return { result: g.validateReviewResult(await scenarioReviewer.review(scenarioRequest, scenarioServices), scenarioRequest),
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

  const citationRequest = {
    ...request,
    conversation: [
      { id: 'U-LARGE', role: 'user', text: `${'log output '.repeat(3000)}\nPlease investigate this status.`, order: 0 },
      { id: 'A-PROPOSAL', role: 'assistant', text: 'I propose a bounded read-only source search.', order: 1 },
      { id: 'U-APPROVAL', role: 'user', text: 'I approve it.', order: 2 },
    ],
  };
  const citationCorrected = await assess((round, context) => {
    const guidance = context.messages.filter(message => message.role === 'system' &&
      typeof message.content === 'string' && message.content.includes('Harness evidence status')).at(-1)?.content ?? '';
    assert.match(guidance, /U-APPROVAL/, `Missing complete-source guidance in round ${round}`);
    assert.doesNotMatch(guidance, /U-LARGE/, `Incomplete source was advertised as citable in round ${round}`);
    if (round === 1) return streamed(assistant([{ type: 'toolCall', id: 'tail', name: 'guardian_history_read', arguments: {
      sourceId: 'U-LARGE', offset: 28_000, limit: 2_000, question: 'Read the request at the end of the large user paste.',
    } }]));
    if (round === 2) return streamed(assistant([{ type: 'toolCall', id: 'changes', name: 'guardian_user_changes', arguments: {
      afterId: 'U-APPROVAL', question: 'Check for a later user restriction.',
    } }]));
    if (round === 3) return streamed(assistant([{ type: 'toolCall', id: 'incomplete-citation', name: 'guardian_decide', arguments: {
      outcome: 'ALLOW', basis: 'explicit_authorization', reason: 'Synthetic decision with an incomplete extra citation.',
      userMessageIds: ['U-LARGE', 'U-APPROVAL'], instructionRefs: [],
    } }]));
    return streamed(assistant([{ type: 'toolCall', id: 'citation-corrected', name: 'guardian_decide', arguments: {
      outcome: 'ALLOW', basis: 'explicit_authorization', reason: 'The complete approval covers the proposed bounded search.',
      userMessageIds: ['U-APPROVAL'], instructionRefs: [],
    } }]));
  }, 1000, citationRequest);
  assert.equal(citationCorrected.result.status, 'completed');
  assert.equal(citationCorrected.result.decision.outcome, 'ALLOW');
  assert.deepEqual(citationCorrected.result.decision.userMessageIds, ['U-APPROVAL']);
  assert.equal(citationCorrected.requests, 4);
  assert.ok(citationCorrected.events.some(event => event.event === 'decision_validation_failed' &&
    String(event.details?.error).includes('Currently citable complete user source IDs: U-APPROVAL')));
  assert.equal(citationCorrected.events.filter(event => event.event === 'model_request').at(-1)?.details?.finalDecisionOnly, true);
  console.log('PASS guardian-reviewer: final correction identifies and uses only complete user sources');

  const chronologyConversation = [
    { id: 'U-OLD', role: 'user', text: 'Earlier diagnostic request that is not needed for the current action.', order: 0 },
    ...Array.from({ length: 30 }, (_, index) => ({
      id: `U-MID-${index + 1}`, role: 'user', text: `Intervening user direction ${index + 1}.`, order: index + 1,
    })),
    { id: 'A-CURRENT', role: 'assistant', text: 'I propose the current bounded read-only diagnostic.', order: 31 },
    { id: 'U-CURRENT', role: 'user', text: 'Run that current diagnostic.', order: 32 },
  ];
  const chronologyRequest = { ...request, conversation: chronologyConversation };
  const chronologyCorrected = await assess((round, context) => {
    const guidance = context.messages.filter(message => message.role === 'system' &&
      typeof message.content === 'string' && message.content.includes('Harness evidence status')).at(-1)?.content ?? '';
    assert.match(guidance, /U-CURRENT/, `Missing current decision-ready source in round ${round}`);
    assert.doesNotMatch(guidance, /U-OLD/, `Old source with unread later directions was advertised as decision-ready in round ${round}`);
    if (round === 1) return streamed(assistant([{ type: 'toolCall', id: 'old-source', name: 'guardian_history_read', arguments: {
      sourceId: 'U-OLD', question: 'Read the earlier user source before deciding.',
    } }]));
    if (round === 2) return streamed(assistant([{ type: 'toolCall', id: 'stale-citation', name: 'guardian_decide', arguments: {
      outcome: 'ALLOW', basis: 'explicit_authorization', reason: 'Synthetic decision with an unnecessary old citation.',
      userMessageIds: ['U-OLD', 'U-CURRENT'], instructionRefs: [],
    } }]));
    if (round === 3) return streamed(assistant([{ type: 'toolCall', id: 'partial-chronology', name: 'guardian_user_changes', arguments: {
      afterId: 'U-OLD', question: 'Check later user directions after the old source.',
    } }]));
    return streamed(assistant([{ type: 'toolCall', id: 'chronology-corrected', name: 'guardian_decide', arguments: {
      outcome: 'ALLOW', basis: 'explicit_authorization', reason: 'The complete current request directly covers the diagnostic.',
      userMessageIds: ['U-CURRENT'], instructionRefs: [],
    } }]));
  }, 1000, chronologyRequest);
  assert.equal(chronologyCorrected.result.status, 'completed');
  assert.equal(chronologyCorrected.result.decision.outcome, 'ALLOW');
  assert.deepEqual(chronologyCorrected.result.decision.userMessageIds, ['U-CURRENT']);
  assert.equal(chronologyCorrected.requests, 4);
  assert.ok(chronologyCorrected.events.some(event => event.event === 'decision_validation_failed' &&
    String(event.details?.error).includes('Currently decision-ready user source IDs:') &&
    String(event.details?.error).includes('U-CURRENT')));
  assert.equal(chronologyCorrected.events.filter(event => event.event === 'model_request').at(-1)?.details?.finalDecisionOnly, true);
  console.log('PASS guardian-reviewer: final correction omits stale complete citations with unread chronology');

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
