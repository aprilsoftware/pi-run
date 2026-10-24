#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'guard-runtime-registry-test: Pi package unavailable' >&2; exit 1; }
node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" <<'NODE'
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { join } from 'node:path';
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
    async shutdown(reason = 'reload') {
      for (const handler of [...(handlers.get('session_shutdown') ?? [])]) {
        await handler({ type: 'session_shutdown', reason }, {});
      }
    },
  };
}
function registration(id, label) {
  return { schemaVersion: 1, id, label };
}
function activity(state, detail, right) {
  return { schemaVersion: 1, state, ...(detail ? { detail } : {}), ...(right ? { right } : {}) };
}
async function discover(bus) {
  let service;
  bus.emit(module.GUARD_RUNTIME_DISCOVER, { schemaVersion: 1, accept(value) { service = value; } });
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
    { ...activity('valid'), right: 'bad\nright' }, { ...activity('valid'), extra: true }]) {
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
  guardian.setBaseline(activity('on'));
  assert.equal(service.activity(), undefined, 'A baseline must not acquire the activity lease');
  assert.deepEqual(component.render(80), ['<muted>guard · on</muted>']);
  let caf = module.connectGuardClient(harness(bus).pi, registration('caf', 'Call a Friend'));
  caf.setBaseline(activity('caf-ready'));
  assert.deepEqual(component.render(80), ['<muted>guard · caf ready</muted>']);
  caf.dispose();
  assert.deepEqual(component.render(80), ['<muted>guard · on</muted>'], 'Disposal restores the previous baseline');
  caf = module.connectGuardClient(harness(bus).pi, registration('caf', 'Call a Friend'));
  assert.throws(() => caf.setBaseline(activity('UPPER')), /Invalid Guard Runtime activity/);

  const first = await guardian.acquireActivity(activity('reviewing', 'command'));
  assert.deepEqual(component.render(80), ['<muted>guard · reviewing command</muted>']);
  guardian.setBaseline(activity('off'));
  assert.deepEqual(component.render(80), ['<muted>guard · reviewing command</muted>'],
    'A changed baseline stays hidden under active work');
  first.update(activity('researching', 'étude 2/4', 'friend-model · high'));
  assert.match(component.render(80)[0], /^<muted>guard · researching étude 2\/4\s+friend-model · high<\/muted>$/);
  const narrow = module.renderGuardStatus(first.snapshot(), 14);
  assert.ok(visibleWidth(narrow) <= 14);
  assert.ok(narrow.includes('…'));
  first.update(activity('asking-primary'));
  assert.deepEqual(component.render(80), ['<muted>guard · asking primary</muted>']);
  const nextActivity = caf.acquireActivity(activity('researching', '2/4'));
  first.end();
  const second = await nextActivity;
  assert.deepEqual(component.render(80), ['<muted>guard · researching 2/4</muted>']);
  second.end();
  assert.deepEqual(component.render(80), ['<muted>guard · off</muted>']);
  guardian.setBaseline(undefined);
  assert.deepEqual(component.render(80), ['<muted>guard · ready</muted>']);
  caf.setBaseline(activity('caf-ready'));
  assert.deepEqual(component.render(80), ['<muted>guard · caf ready</muted>']);
  assert.ok(tui.redraws >= 10, 'Every visible status transition requests a redraw');
  await runtime.shutdown();
  assert.equal(service.status(), undefined, 'Shutdown clears passive client status');
  assert.equal(widgets.size, 0, 'Shutdown removes the shared status widget');
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
