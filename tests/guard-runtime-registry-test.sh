#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'guard-runtime-registry-test: Pi package unavailable' >&2; exit 1; }
node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" <<'NODE'
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

const [root, piDir] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const tuiPath = join(piDir, 'node_modules', '@earendil-works', 'pi-tui', 'dist', 'index.js');
const alias = {
  '@earendil-works/pi-coding-agent': join(piDir, 'dist', 'index.js'),
  '@earendil-works/pi-tui': tuiPath,
};
const file = join(root, 'docker', 'extensions', 'guard-runtime.ts');
const module = await createJiti(import.meta.url, { alias, fsCache: false }).import(file);
const [runtimeSource,guardianSource,cafSource,dockerfile]=await Promise.all([
  readFile(file,'utf8'),readFile(join(root,'docker','extensions','guardian-agent.ts'),'utf8'),readFile(join(root,'docker','extensions','caf-agent.ts'),'utf8'),readFile(join(root,'docker','Dockerfile'),'utf8'),
]);
assert.match(runtimeSource,/from "\.\/guard-viewer\.ts"/,'Only Guard Runtime may own the private viewer');
assert.doesNotMatch(guardianSource,/\.ui\.custom\b|openGuardView|from "\.\/guard-viewer\.ts"/,'Guardian must supply semantics through the runtime contract');
assert.match(dockerfile,/COPY extensions\/guard-viewer\.ts \/usr\/local\/lib\/node_modules\/guardian-agent\//);
assert.match(guardianSource,/name:"guardian-model"/);assert.match(guardianSource,/name:"guardian-thinking"/);assert.match(guardianSource,/guardConnection\.configureReviewer/);
assert.doesNotMatch(guardianSource,/saveGuardReviewerConfig/,'Guardian commands must persist reviewer settings through Guard Runtime');
assert.doesNotMatch(runtimeSource,/registerCommand\(["']guard-(?:model|thinking)["']/,'Guard Runtime must not register reviewer commands');
assert.doesNotMatch(guardianSource,/registerCommand\(["']guard-(?:model|thinking)["']/,'Guardian commands must keep their canonical names');
assert.doesNotMatch(cafSource,/configureReviewer\b|registerCommand\(["']caf-(?:reviewer|guard)/,'CAF must not expose reviewer configuration controls');
const { createEventBus } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'event-bus.js')).href);
const { loadExtensions } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'extensions', 'loader.js')).href);
const { visibleWidth } = await import(pathToFileURL(tuiPath).href);
const tick = () => new Promise(resolve => setImmediate(resolve));
function harness(bus) {
  const handlers = new Map();
  const pi = {
    events: bus,
    on(name, handler) {
      const values = handlers.get(name) ?? [];
      values.push(handler); handlers.set(name, values);
      return () => {
        const current = handlers.get(name) ?? [];
        handlers.set(name, current.filter(value => value !== handler));
      };
    },
  };
  return {
    pi,
    async start(ctx) {
      for (const handler of [...(handlers.get('session_start') ?? [])]) {
        await handler({ type: 'session_start', reason: 'startup' }, ctx);
      }
    },
    async tree(ctx) {
      for (const handler of [...(handlers.get('session_tree') ?? [])]) {
        await handler({ type: 'session_tree' }, ctx);
      }
    },
    async shutdown(reason = 'reload') {
      for (const handler of [...(handlers.get('session_shutdown') ?? [])]) {
        await handler({ type: 'session_shutdown', reason }, {});
      }
    },
  };
}
function registration(id, label, reviewerControl = false) {
  return { schemaVersion: 1, id, label, ...(reviewerControl ? { reviewerControl: true } : {}) };
}
function reviewRegistration(id, label, evidenceProfile = `${id}-evidence.v1`, decisionContract = `${id}-decision.v1`) {
  return { schemaVersion: 1, id, label, evidenceProfile, decisionContract };
}
function reviewRequest(name) {
  return { schemaVersion: 1, action: { kind: 'fixture', name }, policy: { source: 'fixture' } };
}
function activity(state, detail, right, surface) {
  return { schemaVersion: 1, state, ...(detail ? { detail } : {}), ...(right ? { right } : {}), ...(surface ? { surface } : {}) };
}
async function discover(bus) {
  let service;
  bus.emit(module.GUARD_RUNTIME_DISCOVER, { schemaVersion: 1, accept(value) { service = value; } });
  await tick();
  return service;
}
async function discoverReview(bus) {
  let service;
  bus.emit(module.GUARD_REVIEW_RUNTIME_DISCOVER, { schemaVersion: 1, accept(value) { service = value; } });
  await tick();
  return service;
}
const loaderBus = createEventBus();
const loaded = await loadExtensions([file], root, loaderBus);
assert.deepEqual(loaded.errors, []);
assert.equal(loaded.extensions.length, 1);
const loadedService = await discover(loaderBus);
assert.equal(loadedService.kind, module.GUARD_RUNTIME_KIND);
assert.equal(loadedService.schemaVersion, 1);
assert.equal(typeof loadedService.status, 'function');
assert.equal(typeof loadedService.subscribeStatus, 'function');
assert.equal(loadedService.reviewMode(), 'unknown');
assert.equal(typeof loadedService.setReviewMode, 'function');
assert.equal(typeof loadedService.subscribeReviewMode, 'function');
const loadedReviewService = await discoverReview(loaderBus);
assert.equal(loadedReviewService.kind, module.GUARD_REVIEW_RUNTIME_KIND);
assert.equal(loadedReviewService.schemaVersion, 1);
assert.equal(typeof loadedReviewService.registerClient, 'function');
{
  const profile=await mkdtemp(join(tmpdir(),'guard-runtime-controls-')),previousProfile=process.env.PI_RUN_PROFILE_DIR;
  try{
    process.env.PI_RUN_PROFILE_DIR=profile;await mkdir(join(profile,'guardian'),{mode:0o700});
    await writeFile(join(profile,'guardian','config.json'),JSON.stringify({schemaVersion:2,model:'trusted/reviewer',thinking:'low'})+'\n',{mode:0o600});
    const reviewerModel={provider:'trusted',id:'reviewer',api:'openai-responses',reasoning:false,contextWindow:128000,maxTokens:4096};
    const context={mode:'json',hasUI:false,modelRegistry:{getAvailable:()=>[reviewerModel],find:(provider,id)=>provider==='trusted'&&id==='reviewer'?reviewerModel:undefined},ui:{}};
    const bus=createEventBus(),runtime=harness(bus),guardianHarness=harness(bus),cafHarness=harness(bus);
    module.createGuardRuntimeExtension()(runtime.pi);
    const guardian=module.connectGuardClient(guardianHarness.pi,registration('guardian','Guardian',true));
    const caf=module.connectGuardClient(cafHarness.pi,registration('caf','Call a Friend'));
    await tick();await runtime.start(context);
    let settings=await guardian.reviewerSettings();assert.deepEqual(settings.config,{schemaVersion:1,model:'trusted/reviewer',thinking:'low'});assert.equal(settings.source,'legacy_explicit');assert.equal(settings.modelAvailable,true);assert.equal(settings.effectiveThinking,'off');assert.equal(Object.isFrozen(settings),true);assert.equal(Object.isFrozen(settings.config),true);
    let result=await guardian.configureReviewer({schemaVersion:1,setting:'model'});assert.equal(result.status,'shown');assert.equal(result.settings.source,'legacy_explicit');
    result=await guardian.configureReviewer({schemaVersion:1,setting:'model',value:'trusted/reviewer'});assert.equal(result.status,'applied');assert.equal(result.settings.source,'guard_file');
    assert.deepEqual(JSON.parse(await readFile(join(profile,'guard','config.json'),'utf8')),{schemaVersion:1,model:'trusted/reviewer',thinking:'low'});
    settings=await caf.reviewerSettings();assert.deepEqual(settings.config,result.settings.config,'registered clients must observe the same Runtime-owned reviewer settings');
    await assert.rejects(caf.configureReviewer({schemaVersion:1,setting:'model',value:'trusted/reviewer'}),/unavailable for this client/,'CAF must not mutate reviewer configuration');
    await writeFile(join(profile,'guard','config.json'),'{invalid json\n',{mode:0o600});result=await guardian.configureReviewer({schemaVersion:1,setting:'model',value:'trusted/reviewer'});
    assert.deepEqual(result.settings.config,{schemaVersion:1,model:'trusted/reviewer',thinking:null},'An explicit Guardian control must repair a malformed but safely replaceable configuration');
    await assert.rejects(guardian.configureReviewer({schemaVersion:1,setting:'model',value:'missing/model'}),/Unknown model/);
    await assert.rejects(guardian.configureReviewer({schemaVersion:1,setting:'thinking',value:'high'}),/not supported/);
    const selections=[];const uiContext={...context,hasUI:true,ui:{select:async(title,choices)=>{selections.push({title,choices});return choices.find(choice=>choice.startsWith('Off'))}}};
    await runtime.tree(uiContext);result=await guardian.configureReviewer({schemaVersion:1,setting:'thinking'});assert.equal(result.status,'applied');assert.equal(result.settings.config.thinking,'off');assert.deepEqual(selections.map(item=>item.title),['Guardian thinking']);
    await assert.rejects(guardian.configureReviewer({schemaVersion:1,setting:'thinking',value:' high'}),/Invalid Guard reviewer control request/);
    await runtime.shutdown();await assert.rejects(guardian.reviewerSettings(),/unavailable/);
  }finally{if(previousProfile===undefined)delete process.env.PI_RUN_PROFILE_DIR;else process.env.PI_RUN_PROFILE_DIR=previousProfile;await rm(profile,{recursive:true,force:true});}
}
{
  const bus = createEventBus(), client = harness(bus), runtime = harness(bus);
  let connected = 0;
  const connection = module.connectGuardClient(client.pi, registration('guardian', 'Guardian'), {
    connected() { connected++; },
  });
  assert.equal(connection.connected(), false);
  module.default(runtime.pi);
  await tick();
  assert.equal(connection.connected(), true);
  assert.equal(connected, 1);
  assert.deepEqual(connection.runtime().clients(), [registration('guardian', 'Guardian')]);
}
{
  const bus = createEventBus(), runtime = harness(bus);
  module.default(runtime.pi);
  const guardianHarness = harness(bus), cafHarness = harness(bus);
  const guardian = module.connectGuardClient(guardianHarness.pi, registration('guardian', 'Guardian'));
  const caf = module.connectGuardClient(cafHarness.pi, registration('caf', 'Call a Friend'));
  await tick();
  assert.equal(guardian.connected(), true);
  assert.equal(caf.connected(), true);
  const service = guardian.runtime();
  assert.equal(service, caf.runtime());
  assert.deepEqual(service.clients(), [registration('caf', 'Call a Friend'), registration('guardian', 'Guardian')]);
  let duplicateError;
  const duplicate = module.connectGuardClient(harness(bus).pi, registration('guardian', 'Other Guardian'), {
    error(value) { duplicateError = value; },
  });
  await tick();
  assert.equal(duplicate.connected(), false);
  assert.match(duplicateError.message, /already registered/);
  duplicate.dispose();
  await runtime.shutdown();
  await guardianHarness.shutdown();
  await cafHarness.shutdown();
  assert.equal(service.clients().length, 0);
  assert.equal(guardian.connected(), false);
  assert.equal(caf.connected(), false);
  const replacement = harness(bus);
  module.default(replacement.pi);
  const next = module.connectGuardClient(harness(bus).pi, registration('guardian', 'Guardian'));
  await tick();
  assert.equal(next.connected(), true);
  assert.notEqual(next.runtime(), service);
  assert.deepEqual(next.runtime().clients(), [registration('guardian', 'Guardian')]);
}
{
  const bus = createEventBus(), runtime = harness(bus);
  module.default(runtime.pi);
  const service = await discover(bus);
  const invalid = [null, {}, { schemaVersion: 2, id: 'caf', label: 'CAF' },
    { schemaVersion: 1, id: 'CAF', label: 'CAF' }, { schemaVersion: 1, id: 'caf', label: ' CAF' },
    { schemaVersion: 1, id: 'caf', label: 'CAF', extra: true }];
  for (const value of invalid) assert.throws(() => service.registerClient(value), /Invalid Guard Runtime client registration/);
}
{
  const missingBus = createEventBus();
  const missing = module.connectGuardClient(harness(missingBus).pi, registration('caf', 'Call a Friend'));
  await tick();
  assert.equal(missing.connected(), false);
  assert.equal(missing.runtime(), undefined);
  const incompatibleBus = createEventBus();
  const incompatible = module.connectGuardClient(harness(incompatibleBus).pi, registration('caf', 'Call a Friend'));
  incompatibleBus.emit(module.GUARD_RUNTIME_AVAILABLE, {
    kind: module.GUARD_RUNTIME_KIND, schemaVersion: 2,
    registerClient() { throw new Error('must not be called'); }, clients() { return []; },
  });
  await tick();
  assert.equal(incompatible.connected(), false);
}
{
  const bus = createEventBus(), runtime = harness(bus), clientHarness = harness(bus);
  const connection = module.connectGuardReviewClient(clientHarness.pi,
    reviewRegistration('caf', 'Call a Friend', 'caf-disclosure.v1', 'caf-decision.v1'));
  assert.equal(connection.connected(), false);
  module.default(runtime.pi); await tick();
  assert.equal(connection.connected(), true);
  const modeService = await discover(bus);modeService.setReviewMode('on');
  const service = connection.runtime();
  assert.deepEqual(service.clients(), [reviewRegistration('caf', 'Call a Friend', 'caf-disclosure.v1', 'caf-decision.v1')]);
  assert.equal(Object.isFrozen(service.clients()[0]), true);
  const unavailable = await connection.review(reviewRequest('unavailable'));
  assert.equal(unavailable.status, 'incomplete');
  assert.match(unavailable.error, /backend is unavailable/);
  let duplicateError;
  const duplicate = module.connectGuardReviewClient(harness(bus).pi,
    reviewRegistration('caf', 'Duplicate', 'caf-disclosure.v1', 'caf-decision.v1'),
    { error(value) { duplicateError = value; } });
  await tick(); assert.equal(duplicate.connected(), false); assert.match(duplicateError.message, /already registered/); duplicate.dispose();
  for (const value of [null, {}, {...reviewRegistration('bad', 'Bad'), schemaVersion: 2},
    {...reviewRegistration('bad', 'Bad'), evidenceProfile: 'unversioned'},
    {...reviewRegistration('bad', 'Bad'), decisionContract: 'UPPER.v1'},
    {...reviewRegistration('bad', 'Bad'), extra: true}]) {
    assert.throws(() => service.registerClient(value), /Invalid Guard review client registration/);
  }
  connection.dispose(); assert.equal(service.clients().length, 0);
}
{
  const calls = []; let releaseFirst, hangStarted, lateReport;
  const reviewer = { async review(request, context) {
    assert.equal(Object.isFrozen(context),true);const signal = context.signal; calls.push(request.action.name);
    if (request.action.name === 'bad-diagnostic') try { context.report({schemaVersion:1,level:'INFO',event:'UPPER',message:'invalid'}); } catch { /* Runtime must still fail closed if the backend catches this. */ }
    if (request.action.name === 'too-many-diagnostics') for (let index=0;index<257;index++) context.report({schemaVersion:1,level:'INFO',event:'fixture_event',message:`event ${index}`});
    if (request.action.name === 'large-diagnostic') context.report({schemaVersion:1,level:'INFO',event:'fixture_event',message:'large',details:{text:'x'.repeat(17*1024)}});
    if (request.action.name === 'too-many-diagnostic-bytes') for (let index=0;index<18;index++) context.report({schemaVersion:1,level:'INFO',event:'fixture_event',message:`large event ${index}`,details:{text:'x'.repeat(15*1024)}});
    if (request.action.name === 'late-diagnostic') lateReport = context.report;
    context.report({schemaVersion:1,level:'INFO',event:'fixture_started',message:'Fixture review started.',details:{name:request.action.name}});
    assert.equal(Object.isFrozen(request), true); assert.equal(Object.isFrozen(request.client), true);
    assert.equal(Object.isFrozen(request.action), true); assert.equal(Object.isFrozen(request.policy), true);
    assert.throws(() => { request.action.name = 'changed'; }, TypeError);
    if (request.action.name === 'first') return new Promise((resolve, reject) => {
      releaseFirst = () => resolve({schemaVersion:1,status:'completed',decision:{outcome:'ALLOW',name:request.action.name}});
      signal.addEventListener('abort', () => reject(signal.reason), {once:true});
    });
    if (request.action.name === 'hang') return new Promise((_, reject) => {
      hangStarted = true; signal.addEventListener('abort', () => reject(signal.reason), {once:true});
    });
    if (request.action.name === 'throw') throw new Error('fixture backend failed');
    if (request.action.name === 'invalid') return {schemaVersion:1,status:'completed',decision:null};
    return {schemaVersion:1,status:'completed',decision:{outcome:'ALLOW',name:request.action.name}};
  }};
  const bus = createEventBus(), runtime = harness(bus), guardianHarness = harness(bus), cafHarness = harness(bus);
  module.createGuardRuntimeExtension({reviewer})(runtime.pi);
  const modeService=await discover(bus),modeChanges=[];modeService.subscribeReviewMode(mode=>modeChanges.push(mode));assert.deepEqual(modeChanges,['unknown']);
  const disabled=module.connectGuardReviewClient(harness(bus).pi,reviewRegistration('disabled','Disabled'));
  const disabledResult=await disabled.review(reviewRequest('must-not-run'));assert.equal(disabledResult.status,'incomplete');assert.match(disabledResult.error,/unknown/);assert.deepEqual(calls,[]);disabled.dispose();
  modeService.setReviewMode('on');assert.deepEqual(modeChanges,['unknown','on']);assert.throws(()=>modeService.setReviewMode('invalid'),/Invalid Guard review mode/);
  const guardian = module.connectGuardReviewClient(guardianHarness.pi,
    reviewRegistration('guardian', 'Guardian', 'guardian-command.v1', 'guardian-decision.v1'));
  const caf = module.connectGuardReviewClient(cafHarness.pi,
    reviewRegistration('caf', 'Call a Friend', 'caf-disclosure.v1', 'caf-decision.v1'));
  const guardianEvents=[],cafEvents=[];
  await tick(); assert.equal(guardian.runtime(), caf.runtime());

  const mutable = reviewRequest('first'), first = guardian.review(mutable,{report:event=>{assert.equal(Object.isFrozen(event),true);assert.equal(Object.isFrozen(event.details),true);guardianEvents.push(event);}}); mutable.action.name = 'mutated-after-submit';
  await tick(); assert.deepEqual(calls, ['first']);
  const cancelledController = new AbortController(), cancelled = caf.review(reviewRequest('cancelled'), {signal:cancelledController.signal,report:event=>cafEvents.push(event)});
  const second = caf.review(reviewRequest('second'),{report:event=>cafEvents.push(event)}); cancelledController.abort(new Error('queued fixture cancelled'));
  const cancelledResult = await cancelled; assert.equal(cancelledResult.status, 'incomplete'); assert.match(cancelledResult.error, /queued fixture cancelled/);
  assert.deepEqual(calls, ['first']); releaseFirst();
  const firstResult = await first, secondResult = await second;
  assert.equal(firstResult.status, 'completed'); assert.equal(firstResult.decision.name, 'first'); assert.equal(Object.isFrozen(firstResult.decision), true);
  assert.equal(secondResult.status, 'completed'); assert.deepEqual(calls, ['first', 'second']);
  assert.deepEqual(guardianEvents.map(event=>event.clientId),['guardian']);assert.deepEqual(cafEvents.map(event=>event.clientId),['caf']);
  assert.ok(guardianEvents[0].sequence<cafEvents[0].sequence);assert.equal(guardianEvents[0].details.name,'first');
  assert.equal(cafEvents.some(event=>event.details?.name==='cancelled'),false,'A cancelled queued review must not report diagnostics');

  const callbackSafe=await caf.review(reviewRequest('callback-safe'),{report(){throw new Error('presentation failure');}});assert.equal(callbackSafe.status,'completed');
  const badDiagnostic=await caf.review(reviewRequest('bad-diagnostic'));assert.equal(badDiagnostic.status,'incomplete');assert.match(badDiagnostic.error,/diagnostic/);
  const tooMany=await caf.review(reviewRequest('too-many-diagnostics'));assert.equal(tooMany.status,'incomplete');assert.match(tooMany.error,/count exceeded/);
  const large=await caf.review(reviewRequest('large-diagnostic'));assert.equal(large.status,'incomplete');assert.match(large.error,/details exceeds 16 KiB/);
  const tooManyBytes=await caf.review(reviewRequest('too-many-diagnostic-bytes'));assert.equal(tooManyBytes.status,'incomplete');assert.match(tooManyBytes.error,/diagnostics exceed 256 KiB/);
  const late=await caf.review(reviewRequest('late-diagnostic'));assert.equal(late.status,'completed');assert.throws(()=>lateReport({schemaVersion:1,level:'INFO',event:'late',message:'too late'}),/no longer active/);
  await assert.rejects(caf.review(reviewRequest('bad-options'),{extra:true}),/Invalid Guard review options/);

  const invalid = await caf.review(reviewRequest('invalid')); assert.equal(invalid.status, 'incomplete'); assert.match(invalid.error, /invalid Guard review result/i);
  const failed = await caf.review(reviewRequest('throw')); assert.equal(failed.status, 'incomplete'); assert.match(failed.error, /fixture backend failed/);
  await assert.rejects(caf.review({...reviewRequest('extra'), extra:true}), /Invalid Guard review request/);
  const cyclic = reviewRequest('cyclic'); cyclic.action.self = cyclic.action;
  await assert.rejects(caf.review(cyclic), /plain JSON|structural bounds/);
  await assert.rejects(caf.review({schemaVersion:1,action:{text:'x'.repeat(129*1024)},policy:{}}), /128 KiB/);

  const activeController = new AbortController(), hanging = guardian.review(reviewRequest('hang'), {signal:activeController.signal});
  await tick(); assert.equal(hangStarted, true); activeController.abort(new Error('active fixture cancelled'));
  const hangingResult = await hanging; assert.equal(hangingResult.status, 'incomplete'); assert.match(hangingResult.error, /active fixture cancelled/);

  hangStarted=false;const modeCancelled=caf.review(reviewRequest('hang'));await tick();assert.equal(hangStarted,true);modeService.setReviewMode('off');
  const modeCancelledResult=await modeCancelled;assert.equal(modeCancelledResult.status,'incomplete');assert.match(modeCancelledResult.error,/Guard review is off/);assert.deepEqual(modeChanges,['unknown','on','off']);
  const offResult=await caf.review(reviewRequest('must-not-run-off'));assert.equal(offResult.status,'incomplete');assert.match(offResult.error,/Guard review is off/);assert.equal(calls.includes('must-not-run-off'),false);modeService.setReviewMode('on');
  hangStarted = false; const stopped = caf.review(reviewRequest('hang')); await tick(); assert.equal(hangStarted, true);
  await runtime.shutdown(); const stoppedResult = await stopped; assert.equal(stoppedResult.status, 'incomplete'); assert.match(stoppedResult.error, /stopped/);
  assert.equal(guardian.connected(), false); assert.equal(caf.connected(), false);
}
{
  const bus = createEventBus(), runtime = harness(bus), guardianHarness = harness(bus), cafHarness = harness(bus);
  module.default(runtime.pi);
  const guardian = module.connectGuardClient(guardianHarness.pi, registration('guardian', 'Guardian'));
  const caf = module.connectGuardClient(cafHarness.pi, registration('caf', 'Call a Friend'));
  await tick();
  const service = guardian.runtime(), changes = [];
  const stop = service.subscribeActivity(value => changes.push(value));
  service.subscribeActivity(() => { throw new Error('presentation failure'); });
  assert.equal(changes.at(-1), undefined);

  const first = await guardian.acquireActivity(activity('reviewing', 'command'));
  assert.equal(first.active(), true);
  assert.equal(Object.isFrozen(first.snapshot()), true);
  assert.deepEqual(service.activity(), first.snapshot());
  let cafReady = false;
  const cafPending = caf.acquireActivity(activity('researching', '1/4')).then(lease => { cafReady = true; return lease; });
  await tick();
  assert.equal(cafReady, false, 'CAF must wait for the Guardian activity');
  first.update(activity('reviewing', '12s'));
  assert.equal(service.activity().detail, '12s');
  const finalFirst = first.snapshot();
  first.end();
  const cafLease = await cafPending;
  assert.equal(cafReady, true);
  assert.equal(first.active(), false);
  assert.deepEqual(first.snapshot(), finalFirst, 'Ended leases retain their final immutable snapshot');
  assert.throws(() => first.update(activity('reviewing')), /not active/);
  assert.equal(service.activity().clientId, 'caf');

  const order = [];
  const guardianPending = guardian.acquireActivity(activity('reviewing')).then(lease => { order.push('guardian'); return lease; });
  const secondCafPending = caf.acquireActivity(activity('asking-primary')).then(lease => { order.push('caf'); return lease; });
  cafLease.end();
  const secondGuardian = await guardianPending;
  assert.deepEqual(order, ['guardian']);
  secondGuardian.end();
  const secondCaf = await secondCafPending;
  assert.deepEqual(order, ['guardian', 'caf'], 'Queued activities must remain FIFO');

  const cancelled = new AbortController();
  const cancelledPending = guardian.acquireActivity(activity('reviewing'), cancelled.signal);
  const cancellation = assert.rejects(cancelledPending, /no longer needed/);
  cancelled.abort(new Error('no longer needed'));
  await cancellation;
  secondCaf.end();
  assert.equal(service.activity(), undefined);

  const heldByGuardian = await guardian.acquireActivity(activity('reviewing'));
  const afterDispose = caf.acquireActivity(activity('researching'));
  guardian.dispose();
  const heldByCaf = await afterDispose;
  assert.equal(heldByGuardian.active(), false);
  assert.equal(service.activity().clientId, 'caf');
  for (const invalid of [null, {}, activity('UPPER'), { ...activity('valid'), detail: ' bad' },
    { ...activity('valid'), right: 'bad\nright' }, { ...activity('valid'), surface:'other' }, { ...activity('valid'), extra: true }]) {
    await assert.rejects(caf.acquireActivity(invalid), /Invalid Guard Runtime activity/);
  }
  const transient = module.connectGuardClient(harness(bus).pi, registration('transient', 'Transient'));
  const disposedPending = transient.acquireActivity(activity('waiting'));
  const disposed = assert.rejects(disposedPending, /disposed/);
  transient.dispose();
  await disposed;

  const observer = module.connectGuardClient(harness(bus).pi, registration('observer', 'Observer'));
  const stoppedPending = observer.acquireActivity(activity('waiting'));
  const stopped = assert.rejects(stoppedPending, /stopped/);
  await runtime.shutdown();
  await stopped;
  assert.equal(heldByCaf.active(), false);
  assert.equal(service.activity(), undefined);
  assert.equal(caf.connected(), false);
  assert.equal(changes.at(-1), undefined);
  stop();
}
{
  const busA = createEventBus(), busB = createEventBus();
  module.default(harness(busA).pi); module.default(harness(busB).pi);
  const a = module.connectGuardClient(harness(busA).pi, registration('guardian', 'Guardian'));
  const b = module.connectGuardClient(harness(busB).pi, registration('guardian', 'Guardian'));
  const [leaseA, leaseB] = await Promise.all([
    a.acquireActivity(activity('reviewing')), b.acquireActivity(activity('reviewing')),
  ]);
  assert.equal(leaseA.active(), true);
  assert.equal(leaseB.active(), true, 'Separate runtimes must not share an activity lock');
  leaseA.end(); leaseB.end();
}
{
  const bus = createEventBus(), runtime = harness(bus), clientHarness = harness(bus);
  module.default(runtime.pi);
  const widgets = new Map(), tui = { redraws: 0, requestRender() { this.redraws++; } };
  const theme = { fg: (color, text) => `<${color}>${text}</${color}>` };
  const ctx = { mode: 'tui', hasUI: true, ui: {
    setWidget(key, value, options) {
      assert.deepEqual(options, { placement: 'belowEditor' });
      if (value) widgets.set(key, value); else widgets.delete(key);
    },
  } };
  await runtime.start(ctx);
  assert.equal(widgets.size, 1);
  const component = widgets.get('guard-runtime')(tui, theme);
  assert.deepEqual(component.render(80), ['<muted>guard · ready</muted>']);
  const guardian = module.connectGuardClient(clientHarness.pi, registration('guardian', 'Guardian'));
  const service = guardian.runtime();
  guardian.setBaseline(activity('on',undefined,'reviewer-model · low'));
  assert.equal(service.activity(), undefined, 'A baseline must not acquire the activity lease');
  assert.match(component.render(80)[0],/^<muted>guard · on\s+reviewer-model · low<\/muted>$/);
  let caf = module.connectGuardClient(harness(bus).pi, registration('caf', 'Call a Friend'));
  caf.setBaseline(activity('on',undefined,'friend-model · high'));
  let rendered=component.render(80);assert.equal(rendered.length,2);assert.match(rendered[0],/^<muted>guard · on\s+reviewer-model · low<\/muted>$/);assert.match(rendered[1],/^<muted>caf · on\s+friend-model · high<\/muted>$/);
  caf.dispose();
  assert.equal(component.render(80).length,1,'Disposal removes only the disposed client row');
  caf = module.connectGuardClient(harness(bus).pi, registration('caf', 'Call a Friend'));caf.setBaseline(activity('on',undefined,'friend-model · high'));
  assert.throws(() => caf.setBaseline(activity('UPPER')), /Invalid Guard Runtime activity/);

  const first = await guardian.acquireActivity(activity('reviewing', 'command'));
  rendered=component.render(80);assert.equal(rendered.length,2);assert.match(rendered[0],/^<muted>guard · reviewing command\s+reviewer-model · low<\/muted>$/);assert.match(rendered[1],/^<muted>caf · on\s+friend-model · high<\/muted>$/);
  guardian.setBaseline(activity('off',undefined,'reviewer-model · low'));
  assert.match(component.render(80)[0],/guard · reviewing command/,'A changed baseline stays hidden under active work');
  first.update(activity('researching', 'étude 2/4'));
  assert.match(component.render(80)[0], /^<muted>guard · researching étude 2\/4\s+reviewer-model · low<\/muted>$/);
  const narrow = module.renderGuardStatusRows([{id:'guardian',activity:first.snapshot()},{id:'caf',activity:{...first.snapshot(),clientId:'caf',state:'on',right:'friend-model · high'}}],14);
  assert.equal(narrow.length,2);assert.ok(narrow.every(line=>visibleWidth(line)<=14&&line.includes('…')));
  const nextActivity = caf.acquireActivity(activity('reviewing-disclosure','call friend',undefined,'guard'));
  first.end();
  const second = await nextActivity;
  rendered=component.render(80);assert.match(rendered[0],/^<muted>guard · reviewing disclosure call friend\s+reviewer-model · low<\/muted>$/);assert.match(rendered[1],/^<muted>caf · on\s+friend-model · high<\/muted>$/);
  second.update(activity('asking-friend',undefined,undefined,'client'));rendered=component.render(80);assert.match(rendered[0],/^<muted>guard · off\s+reviewer-model · low<\/muted>$/);assert.match(rendered[1],/^<muted>caf · asking friend\s+friend-model · high<\/muted>$/);
  second.update(activity('searching-the-web',undefined,undefined,'client'));rendered=component.render(80);assert.match(rendered[1],/^<muted>caf · searching the web\s+friend-model · high<\/muted>$/);
  second.update(activity('friend-reviewing-search-results',undefined,undefined,'client'));rendered=component.render(80);assert.match(rendered[1],/^<muted>caf · friend reviewing search results\s+friend-model · high<\/muted>$/);
  second.end();rendered=component.render(80);assert.match(rendered[0],/guard · off/);assert.match(rendered[1],/caf · on/);
  guardian.setBaseline(undefined);rendered=component.render(80);assert.equal(rendered.length,1);assert.match(rendered[0],/^<muted>caf · on\s+friend-model · high<\/muted>$/);
  caf.setBaseline(undefined);assert.deepEqual(component.render(80),['<muted>guard · ready</muted>']);
  assert.ok(tui.redraws >= 10, 'Every visible status transition requests a redraw');
  await runtime.shutdown();
  assert.equal(service.status(), undefined, 'Shutdown clears passive client status');
  assert.equal(widgets.size, 0, 'Shutdown removes the shared status widget');
}
{
  const bus=createEventBus(),runtime=harness(bus),guardianHarness=harness(bus),cafHarness=harness(bus);
  module.default(runtime.pi);
  let component,finish,customCalls=0,loads=0,details=0;
  const tui={terminal:{rows:24},requestRender(){}};
  const theme={fg:(_role,text)=>text,bg:(_role,text)=>text};
  const ctx={mode:'tui',hasUI:true,ui:{setWidget(){},custom(factory){customCalls++;return new Promise(resolve=>{
    finish=value=>{component?.dispose?.();resolve(value);};component=factory(tui,theme,{},finish);component.focused=true;
  });},notify(){throw new Error('TUI viewer must not use notify');}}};
  await runtime.start(ctx);
  const guardian=module.connectGuardClient(guardianHarness.pi,registration('guardian','Guardian'));
  const caf=module.connectGuardClient(cafHarness.pi,registration('caf','Call a Friend'));
  const request={schemaVersion:1,title:'Fixture activity · UTC',compactTitle:'Fixture activity',wideHeader:'  Time  Outcome',fallbackText:'fixture journals',
    unavailableText:'Fixture viewer unavailable.',emptyText:'Nothing retained.',noMatchesText:'No matches.',
    missingSelectionText:'Selected fixture is no longer retained.',incompleteNoticeText:'fixture view may be incomplete',
    sections:[{id:'summary',label:'Summary'},{id:'timeline',label:'Timeline'}],
    async load(){loads++;return {schemaVersion:1,loadedAt:'2026-04-01T12:00:00.000Z',notices:[],rows:[
      {id:'one',wide:'12:00:00  ALLOW  first fixture',compact:'12:00 ALLOW · first fixture',searchText:'allow first fixture'},
      {id:'two',wide:'12:01:00  ASK    second fixture',compact:'12:01 ASK · second fixture',searchText:'ask second fixture'},
    ]};},details(rowId,sectionId){details++;return [`${sectionId} for ${rowId}`,'bounded detail'];}};
  let firstSettled=false;const first=guardian.openView(request).finally(()=>{firstSettled=true;});await tick();
  assert.equal(customCalls,1);assert.equal(loads,1);assert.match(component.render(100).join('\n'),/Fixture activity · UTC/);
  assert.match(component.render(100).join('\n'),/Time  Outcome/);
  component.handleInput('/');for(const character of 'second')component.handleInput(character);component.handleInput('\r');
  assert.doesNotMatch(component.render(100).join('\n'),/first fixture/);assert.match(component.render(100).join('\n'),/second fixture/);
  component.handleInput('r');await tick();assert.equal(loads,2);component.handleInput('\r');
  assert.match(component.render(100).join('\n'),/summary for two/);assert.equal(details,1);
  component.handleInput('\t');assert.match(component.render(100).join('\n'),/timeline for two/);
  assert.equal(details,2);assert.match(component.render(10)[0],/Fixture/);assert.ok(visibleWidth(component.render(10)[0])<=10);
  await caf.openView({...request,title:'Must not stack'});assert.equal(customCalls,1,'Only one Guard-owned viewer may be active');
  caf.closeView();await tick();assert.equal(firstSettled,false,'A client cannot close another client\'s viewer');
  guardian.closeView();await first;assert.equal(firstSettled,true);
  const second=guardian.openView(request);await tick();assert.equal(customCalls,2);await runtime.tree(ctx);await second;
  assert.equal(component.render(100).length,0,'Changing the session tree closes and disposes the viewer');
  const third=guardian.openView(request);await tick();assert.equal(customCalls,3);guardian.dispose();await third;
  assert.equal(component.render(100).length,0,'Disposing the owner closes and disposes its viewer');
  for(const invalid of [{...request,schemaVersion:2},{...request,sections:[]},{...request,title:'bad\ncontrol'}]){
    await assert.rejects(caf.openView(invalid),/Invalid Guard view/);
  }
  await runtime.shutdown();
}
{
  const bus=createEventBus(),runtime=harness(bus),clientHarness=harness(bus),messages=[];
  module.default(runtime.pi);await runtime.start({mode:'print',hasUI:false,ui:{notify(message,kind){messages.push([message,kind]);}}});
  const client=module.connectGuardClient(clientHarness.pi,registration('guardian','Guardian'));
  await client.openView({schemaVersion:1,title:'Print fixture',compactTitle:'Print fixture',fallbackText:'fixture journals path',unavailableText:'unavailable',
    emptyText:'empty',noMatchesText:'none',missingSelectionText:'missing',incompleteNoticeText:'incomplete',
    sections:[{id:'summary',label:'Summary'}],async load(){throw new Error('non-TUI must not read the journal');},details(){return [];}});
  assert.deepEqual(messages,[['fixture journals path','info']]);
  await runtime.shutdown();
}
{
  for (const mode of ['print', 'json', 'rpc']) {
    const bus = createEventBus(), runtime = harness(bus);
    module.default(runtime.pi);
    let widgetCalls = 0;
    await runtime.start({ mode, hasUI: mode === 'rpc', ui: { setWidget() { widgetCalls++; } } });
    assert.equal(widgetCalls, 0, `${mode} mode must not install a terminal widget`);
    await runtime.shutdown();
  }
}
console.log('guard runtime registry, activity lease, and status experiment passed');
NODE
