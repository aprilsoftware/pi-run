#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'guard-journal-test: Pi package unavailable' >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { chmod, link, mkdir, readFile, readdir, stat, symlink, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { basename, dirname, join } from 'node:path';
const [root, piDir, tmp] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const file = join(root, 'docker', 'extensions', 'guard-journal.ts');
const module = await createJiti(import.meta.url, { fsCache: false }).import(file);
const create = module.createGuardJournalWriter;
const mode = async path => (await stat(path)).mode & 0o777;
const entries = async path => (await readFile(path, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);

for (const options of [null, {}, { schemaVersion: 1, stateDir: tmp, clientId: '../bad' },
  { schemaVersion: 1, stateDir: tmp, clientId: 'guardian', backups: 9 },
  { schemaVersion: 1, stateDir: tmp, clientId: 'guardian', maxBytes: 10 }]) {
  assert.throws(() => create(options), /Invalid Guard journal/);
}

const state = join(tmp, 'profile');
await mkdir(state, { mode: 0o700 });
const writers = Array.from({ length: 8 }, (_, index) => create({ schemaVersion: 1, stateDir: state,
  clientId: index % 2 ? 'caf' : 'guardian', maxBytes: 64 * 1024 }));
assert.equal(new Set(writers.map(writer => writer.runId)).size, writers.length);
assert.equal(new Set(writers.map(writer => writer.path)).size, writers.length);
for (let sequence = 1; sequence <= 40; sequence++) {
  for (const writer of writers) writer.write({ event: 'concurrent', sourceSequence: sequence, journal: 'cannot override identity' });
}
await Promise.all(writers.map(writer => writer.flush()));
for (const writer of writers) {
  const rows = await entries(writer.path);
  assert.equal(rows.length, 40);
  assert.deepEqual(rows.map(row => row.journal.sequence), Array.from({ length: 40 }, (_, index) => index + 1));
  assert.ok(rows.every(row => row.journal.schemaVersion === 1 && row.journal.clientId === writer.clientId &&
    row.journal.runId === writer.runId && row.journal.processId === process.pid));
  assert.deepEqual(writer.health(), { pending: 0, dropped: 0, written: 40, lastError: null });
  assert.equal(await mode(writer.path), 0o600);
}
for (const directory of [join(state, 'logs'), join(state, 'logs', 'guardian'), join(state, 'logs', 'guardian', 'runs'),
  join(state, 'logs', 'caf'), join(state, 'logs', 'caf', 'runs')]) assert.equal(await mode(directory), 0o700);
assert.ok(!(await readdir(state, { recursive: true })).some(name => String(name).includes('.guardian-log.lock')));

const rotating = create({ schemaVersion: 1, stateDir: state, clientId: 'rotation', maxBytes: 512, backups: 2 });
for (let index = 1; index <= 30; index++) rotating.write({ event: 'rotation', index, payload: 'x'.repeat(90) });
await rotating.flush();
const rotationPaths = [`${rotating.path}.2`, `${rotating.path}.1`, rotating.path];
const rotationRows = (await Promise.all(rotationPaths.map(entries))).flat();
assert.ok(rotationRows.length > 0 && rotationRows.length < 30);
assert.deepEqual(rotationRows.map(row => row.journal.sequence), [...rotationRows.map(row => row.journal.sequence)].sort((a, b) => a - b));
assert.equal(rotationRows.at(-1).index, 30);
for (const path of rotationPaths) { assert.ok((await stat(path)).size <= 512); assert.equal(await mode(path), 0o600); }

const collision = create({ schemaVersion: 1, stateDir: state, clientId: 'collision' });
await mkdir(dirname(collision.path), { recursive: true, mode: 0o700 });
await writeFile(collision.path, 'occupied\n', { mode: 0o600 });
collision.write({ event: 'must-not-overwrite' }); await collision.flush();
assert.equal(await readFile(collision.path, 'utf8'), 'occupied\n');
assert.equal(collision.health().dropped, 1);

const linked = create({ schemaVersion: 1, stateDir: state, clientId: 'linked' });
linked.write({ event: 'first' }); await linked.flush();
await link(linked.path, `${linked.path}.extra`);
linked.write({ event: 'refused' }); await linked.flush();
assert.equal(linked.health().dropped, 1);
const isolated = create({ schemaVersion: 1, stateDir: state, clientId: 'linked' });
isolated.write({ event: 'independent' }); await isolated.flush();
assert.deepEqual(isolated.health(), { pending: 0, dropped: 0, written: 1, lastError: null });

const unsafeState = join(tmp, 'unsafe-profile'), outside = join(tmp, 'outside');
await mkdir(unsafeState, { mode: 0o700 }); await mkdir(outside, { mode: 0o700 });
await symlink(outside, join(unsafeState, 'logs'));
const warnings = [], unsafe = create({ schemaVersion: 1, stateDir: unsafeState, clientId: 'guardian' }, message => warnings.push(message));
unsafe.write({ event: 'refused' }); await unsafe.flush();
assert.equal(unsafe.health().dropped, 1); assert.equal(warnings.length, 1); assert.deepEqual(await readdir(outside), []);
const permissiveState = join(tmp, 'permissive-profile'), permissiveLogs = join(permissiveState, 'logs');
await mkdir(permissiveLogs, { recursive: true, mode: 0o700 }); await chmod(permissiveLogs, 0o755);
const permissive = create({ schemaVersion: 1, stateDir: permissiveState, clientId: 'guardian' });
permissive.write({ event: 'refused' }); await permissive.flush();
assert.equal(permissive.health().dropped, 1); assert.deepEqual(await readdir(permissiveLogs), []);

const loaded = await createJiti(import.meta.url, { fsCache: false }).import(file);
assert.equal(typeof loaded.createGuardJournalWriter, 'function');
assert.ok((await readFile(join(root, 'docker', 'Dockerfile'), 'utf8')).includes(
  'COPY extensions/guard-journal.ts /usr/local/lib/node_modules/guardian-agent/'));
console.log(`guard journal concurrent writers, rotation, identity, private modes, and unsafe-path tests passed (${basename(file)})`);
NODE
