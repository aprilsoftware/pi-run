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

const readState = join(tmp, 'read-profile'); await mkdir(readState, { mode: 0o700 });
const first = create({ schemaVersion: 1, stateDir: readState, clientId: 'guardian' });
const second = create({ schemaVersion: 1, stateDir: readState, clientId: 'guardian' });
first.write({ event: 'first-late', timestamp: '2026-01-01T00:00:03.000Z' });
first.write({ event: 'first-early', timestamp: '2026-01-01T00:00:01.000Z' });
first.write({ event: 'first-tie', timestamp: '2026-01-01T00:00:02.000Z' });
second.write({ event: 'second-tie-2', timestamp: '2026-01-01T00:00:02.000Z' });
second.write({ event: 'second-tie-1', timestamp: '2026-01-01T00:00:02.000Z' });
await Promise.all([first.flush(), second.flush()]);
const legacy = join(readState, 'logs', 'guardian', 'legacy'); await mkdir(legacy, { mode: 0o700 });
await writeFile(join(legacy, 'events.jsonl.1'), JSON.stringify({ event: 'legacy-old', timestamp: '2026-01-01T00:00:00.000Z' }) + '\n', { mode: 0o600 });
await writeFile(join(legacy, 'events.jsonl'), JSON.stringify({ event: 'legacy-new', timestamp: '2026-01-01T00:00:04.000Z' }) +
  '\nnot-json\n{"event":"unfinished"', { mode: 0o600 });
await writeFile(join(legacy, 'unexpected.txt'), 'ignored\n', { mode: 0o600 });
const outsideFile = join(tmp, 'outside-journal'); await writeFile(outsideFile, '{}\n', { mode: 0o600 });
await symlink(outsideFile, join(readState, 'logs', 'guardian', 'runs', '11111111-1111-4111-8111-111111111111.jsonl'));
const rotatedSnapshot = await module.readGuardJournal({ schemaVersion: 1, stateDir: state, clientId: 'rotation' });
assert.equal(rotatedSnapshot.files.length, 3);
assert.deepEqual(rotatedSnapshot.records.map(record => record.sequence),
  [...rotatedSnapshot.records.map(record => record.sequence)].sort((a, b) => a - b));
assert.equal(rotatedSnapshot.records.at(-1).value.index, 30);
const snapshot = await module.readGuardJournal({ schemaVersion: 1, stateDir: readState, clientId: 'guardian' });
const expectedTies = [[first.runId, 3, 'first-tie'], [second.runId, 1, 'second-tie-2'], [second.runId, 2, 'second-tie-1']]
  .sort((a, b) => a[0].localeCompare(b[0]) || a[1] - b[1]);
assert.deepEqual(snapshot.records.map(record => record.value.event),
  ['legacy-old', 'first-early', ...expectedTies.map(row => row[2]), 'first-late', 'legacy-new']);
assert.equal(snapshot.malformed, 1); assert.equal(snapshot.unstable, 0); assert.equal(snapshot.files.length, 4);
assert.ok(snapshot.notices.some(notice => notice.includes('incomplete trailing record')));
assert.ok(snapshot.notices.some(notice => notice.includes('unexpected entry omitted')));
assert.ok(snapshot.notices.some(notice => notice.includes('unsafe file')));
const tied = snapshot.records.filter(record => record.timestamp === '2026-01-01T00:00:02.000Z');
assert.deepEqual(tied.map(record => [record.runId, record.sequence]), expectedTies.map(row => row.slice(0, 2)));
const bounded = await module.readGuardJournal({ schemaVersion: 1, stateDir: readState, clientId: 'guardian', maxRecords: 2 });
assert.deepEqual(bounded.records.map(record => record.value.event), ['first-late', 'legacy-new']);
assert.ok(bounded.notices.some(notice => notice.includes('record limit')));
const oneFile = await module.readGuardJournal({ schemaVersion: 1, stateDir: readState, clientId: 'guardian', maxFiles: 1 });
assert.equal(oneFile.files.length, 1); assert.ok(oneFile.notices.some(notice => notice.includes('file limit')));
const byteBound = await module.readGuardJournal({ schemaVersion: 1, stateDir: readState, clientId: 'guardian',
  maxFileBytes: 64, maxTotalBytes: 64 });
assert.ok(byteBound.notices.some(notice => notice.includes('byte')));
const cancelled = new AbortController(); cancelled.abort(new Error('synthetic cancellation'));
await assert.rejects(module.readGuardJournal({ schemaVersion: 1, stateDir: readState, clientId: 'guardian' }, cancelled.signal), /synthetic cancellation/);
const badReadState = join(tmp, 'bad-read-profile'), badClient = join(badReadState, 'logs', 'guardian');
await mkdir(badClient, { recursive: true, mode: 0o700 }); await symlink(outside, join(badClient, 'runs'));
const unsafeRead = await module.readGuardJournal({ schemaVersion: 1, stateDir: badReadState, clientId: 'guardian' });
assert.deepEqual(unsafeRead.records, []); assert.ok(unsafeRead.notices.some(notice => notice.includes('Unsafe Guard journal directory')));

const loaded = await createJiti(import.meta.url, { fsCache: false }).import(file);
assert.equal(typeof loaded.createGuardJournalWriter, 'function');
assert.equal(typeof loaded.readGuardJournal, 'function');
assert.ok((await readFile(join(root, 'docker', 'Dockerfile'), 'utf8')).includes(
  'COPY extensions/guard-journal.ts /usr/local/lib/node_modules/guardian-agent/'));
console.log(`guard journal concurrent writers, rotation, identity, private modes, and unsafe-path tests passed (${basename(file)})`);
NODE
