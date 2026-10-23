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
const alias = { '@earendil-works/pi-coding-agent': join(piDir, 'dist', 'index.js') };
const file = join(root, 'experiments', 'guard-runtime', 'index.ts');
const module = await createJiti(import.meta.url, { alias, fsCache: false }).import(file);
const { createEventBus } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'event-bus.js')).href);
const { loadExtensions } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'extensions', 'loader.js')).href);
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
console.log('guard runtime registry experiment passed');
NODE
