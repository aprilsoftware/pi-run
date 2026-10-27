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
import { appendFile, chmod, link, mkdir, readFile, readdir, rmdir, stat, symlink, unlink, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { basename, dirname, join } from 'node:path';
const [root, piDir, tmp] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const file = join(root, 'docker', 'extensions', 'guard-journal.ts');
const module = await createJiti(import.meta.url, { fsCache: false }).import(file);
const create = module.createGuardJournalWriter;
const mode = async path => (await stat(path)).mode & 0o777;
const exists = async path => stat(path).then(() => true, error => error.code === 'ENOENT' ? false : Promise.reject(error));
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

const retentionState = join(tmp, 'retention-profile'); await mkdir(retentionState, { mode: 0o700 });
const retained = Array.from({ length: 4 }, () => create({ schemaVersion: 1, stateDir: retentionState, clientId: 'guardian' }));
for (let index = 0; index < retained.length; index++) {
  retained[index].write({ event: 'retention', index, payload: 'r'.repeat(300) }); await retained[index].flush();
  if (index < 3) { await retained[index].close(); await new Promise(resolve => setTimeout(resolve, 5)); }
}
const sizes = await Promise.all(retained.map(writer => stat(writer.path).then(value => value.size)));
const byteRetention = await module.maintainGuardJournalRetention({ schemaVersion: 1, stateDir: retentionState,
  clientId: 'guardian', maxBytes: sizes.reduce((sum, size) => sum + size, 0) - sizes[0], maxRuns: 10 });
assert.equal(byteRetention.status, 'completed'); assert.equal(byteRetention.removedRuns, 1); assert.equal(byteRetention.targetMet, true);
assert.equal(await exists(retained[0].path), false); assert.equal(await exists(`${retained[0].path}.complete`), false);
assert.equal(await exists(retained[3].path), true); assert.equal(await exists(`${retained[3].path}.complete`), false);
const runRetention = await module.maintainGuardJournalRetention({ schemaVersion: 1, stateDir: retentionState,
  clientId: 'guardian', maxBytes: 1024 * 1024, maxRuns: 2 });
assert.equal(runRetention.removedRuns, 1); assert.equal(runRetention.runsAfter, 2); assert.equal(await exists(retained[1].path), false);
await Promise.all([retained[3].close(), retained[3].close()]);
assert.equal(await exists(`${retained[3].path}.complete`), true);
retained[3].write({ event: 'closed-writer-refuses' }); assert.equal(retained[3].health().dropped, 1);
const duringLock = create({ schemaVersion: 1, stateDir: retentionState, clientId: 'guardian' });
const retentionLock = join(retentionState, 'logs', 'guardian', '.retention.lock'); await mkdir(retentionLock, { mode: 0o700 });
duringLock.write({ event: 'write-during-retention-contention' });
const [busy] = await Promise.all([module.maintainGuardJournalRetention({ schemaVersion: 1, stateDir: retentionState,
  clientId: 'guardian', maxBytes: 1024, maxRuns: 1 }), duringLock.flush()]);
assert.equal(busy.status, 'busy'); assert.equal(await exists(retained[2].path), true);
assert.deepEqual(duringLock.health(), { pending: 0, dropped: 0, written: 1, lastError: null });
await rmdir(retentionLock);
const interrupted = create({ schemaVersion: 1, stateDir: retentionState, clientId: 'interrupted' });
interrupted.write({ event: 'interrupted-cleanup' }); await interrupted.close(); await unlink(interrupted.path);
const recovered = await module.maintainGuardJournalRetention({ schemaVersion: 1, stateDir: retentionState,
  clientId: 'interrupted', maxBytes: 1024, maxRuns: 1 });
assert.equal(recovered.status, 'completed'); assert.equal(await exists(`${interrupted.path}.complete`), false);
const unsafeRetention = create({ schemaVersion: 1, stateDir: retentionState, clientId: 'unsafe-retention' });
unsafeRetention.write({ event: 'unsafe', payload: 'u'.repeat(400) }); await unsafeRetention.close();
await link(unsafeRetention.path, `${unsafeRetention.path}.extra`);
const unsafeResult = await module.maintainGuardJournalRetention({ schemaVersion: 1, stateDir: retentionState,
  clientId: 'unsafe-retention', maxBytes: 256, maxRuns: 1 });
assert.equal(unsafeResult.status, 'completed'); assert.equal(unsafeResult.targetMet, false); assert.equal(unsafeResult.skippedUnsafe, 1);
assert.equal(await exists(unsafeRetention.path), true);

const readState = join(tmp, 'read-profile'); await mkdir(readState, { mode: 0o700 });
const first = create({ schemaVersion: 1, stateDir: readState, clientId: 'guardian' });
const second = create({ schemaVersion: 1, stateDir: readState, clientId: 'guardian' });
const newest = create({ schemaVersion: 1, stateDir: readState, clientId: 'guardian' });
first.write({ event: 'first-late', timestamp: '2026-01-01T00:00:03.000Z' });
first.write({ event: 'first-early', timestamp: '2026-01-01T00:00:01.000Z' });
first.write({ event: 'first-tie', timestamp: '2026-01-01T00:00:02.000Z' });
second.write({ event: 'second-tie-2', timestamp: '2026-01-01T00:00:02.000Z' });
second.write({ event: 'second-tie-1', timestamp: '2026-01-01T00:00:02.000Z' });
newest.write({ event: 'newest', timestamp: '2026-01-01T00:00:04.000Z' });
await Promise.all([first.flush(), second.flush(), newest.flush()]);
await appendFile(newest.path, 'not-json\n{"event":"unfinished"');
await writeFile(join(readState, 'logs', 'guardian', 'runs', 'unexpected.txt'), 'ignored\n', { mode: 0o600 });
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
  ['first-early', ...expectedTies.map(row => row[2]), 'first-late', 'newest']);
assert.equal(snapshot.malformed, 1); assert.equal(snapshot.unstable, 0); assert.equal(snapshot.files.length, 3);
assert.ok(snapshot.notices.some(notice => notice.includes('incomplete trailing record')));
assert.ok(snapshot.notices.some(notice => notice.includes('unexpected entry omitted')));
assert.ok(snapshot.notices.some(notice => notice.includes('unsafe file')));
const tied = snapshot.records.filter(record => record.timestamp === '2026-01-01T00:00:02.000Z');
assert.deepEqual(tied.map(record => [record.runId, record.sequence]), expectedTies.map(row => row.slice(0, 2)));
const bounded = await module.readGuardJournal({ schemaVersion: 1, stateDir: readState, clientId: 'guardian', maxRecords: 2 });
assert.deepEqual(bounded.records.map(record => record.value.event), ['first-late', 'newest']);
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

const workspaceA='11111111-1111-4111-8111-111111111111',workspaceB='22222222-2222-4222-8222-222222222222';
const sessionA='00000000-0000-7000-8000-000000000001',sessionB='00000000-0000-7000-8000-000000000002';
const scopedState=join(tmp,'workspace-session-profile');await mkdir(scopedState,{mode:0o700});
for(const options of [null,{},
  {schemaVersion:2,stateDir:scopedState,workspaceId:'../bad',sessionId:sessionA,kind:'guardian'},
  {schemaVersion:2,stateDir:scopedState,workspaceId:workspaceA,sessionId:'bad',kind:'guardian'},
  {schemaVersion:2,stateDir:scopedState,workspaceId:workspaceA,sessionId:sessionA,kind:'other'}])
  assert.throws(()=>module.createSessionGuardJournalWriter(options),/Invalid Guard journal/);
const scopedA=module.createSessionGuardJournalWriter({schemaVersion:2,stateDir:scopedState,workspaceId:workspaceA,sessionId:sessionA,kind:'guardian'});
scopedA.write({event:'session-a-first',timestamp:'2026-05-01T10:00:01.000Z'});await scopedA.close();
assert.equal(scopedA.path,join(scopedState,'logs',workspaceA,sessionA,'guardian.jsonl'));
assert.equal(await exists(`${scopedA.path}.complete`),false);
const resumedA=module.createSessionGuardJournalWriter({schemaVersion:2,stateDir:scopedState,workspaceId:workspaceA,sessionId:sessionA,kind:'guardian'});
assert.equal(resumedA.path,scopedA.path);resumedA.write({event:'session-a-resumed',timestamp:'2026-05-01T10:00:03.000Z'});await resumedA.close();
const scopedRows=await entries(scopedA.path);assert.deepEqual(scopedRows.map(row=>row.event),['session-a-first','session-a-resumed']);
assert.ok(scopedRows.every(row=>row.journal.schemaVersion===2&&row.journal.kind==='guardian'&&row.journal.workspaceId===workspaceA&&row.journal.sessionId===sessionA));
const scopedB=module.createSessionGuardJournalWriter({schemaVersion:2,stateDir:scopedState,workspaceId:workspaceA,sessionId:sessionB,kind:'guardian'});
scopedB.write({event:'session-b',timestamp:'2026-05-01T10:00:02.000Z'});await scopedB.close();
const scopedCaf=module.createSessionGuardJournalWriter({schemaVersion:2,stateDir:scopedState,workspaceId:workspaceA,sessionId:sessionA,kind:'caf'});
scopedCaf.write({event:'caf-only',timestamp:'2026-05-01T10:00:04.000Z'});await scopedCaf.close();
const otherWorkspace=module.createSessionGuardJournalWriter({schemaVersion:2,stateDir:scopedState,workspaceId:workspaceB,sessionId:sessionA,kind:'guardian'});
otherWorkspace.write({event:'other-workspace',timestamp:'2026-05-01T10:00:05.000Z'});await otherWorkspace.close();
const scopedSnapshot=await module.readWorkspaceGuardJournal({schemaVersion:2,stateDir:scopedState,workspaceId:workspaceA,kind:'guardian'});
assert.deepEqual(scopedSnapshot.records.map(record=>record.value.event),['session-a-first','session-b','session-a-resumed']);
assert.deepEqual(new Set(scopedSnapshot.records.map(record=>record.sessionId)),new Set([sessionA,sessionB]));
assert.ok(!JSON.stringify(scopedSnapshot.records).includes('caf-only'));assert.ok(!JSON.stringify(scopedSnapshot.records).includes('other-workspace'));
const cafSnapshot=await module.readWorkspaceGuardJournal({schemaVersion:2,stateDir:scopedState,workspaceId:workspaceA,kind:'caf'});
assert.deepEqual(cafSnapshot.records.map(record=>record.value.event),['caf-only']);
for(const directory of [join(scopedState,'logs'),join(scopedState,'logs',workspaceA),join(scopedState,'logs',workspaceA,sessionA)])assert.equal(await mode(directory),0o700);
for(const path of [scopedA.path,scopedB.path,scopedCaf.path])assert.equal(await mode(path),0o600);
const scopedRotating=module.createSessionGuardJournalWriter({schemaVersion:2,stateDir:scopedState,workspaceId:workspaceA,
  sessionId:'00000000-0000-7000-8000-000000000003',kind:'guardian',maxBytes:512,backups:2});
for(let index=1;index<=30;index++)scopedRotating.write({event:'scoped-rotation',index,payload:'x'.repeat(90),timestamp:`2026-05-01T10:01:${String(index).padStart(2,'0')}.000Z`});
await scopedRotating.close();
for(const path of [`${scopedRotating.path}.2`,`${scopedRotating.path}.1`,scopedRotating.path]){assert.ok(await exists(path));assert.ok((await stat(path)).size<=512);}
assert.equal(await exists(`${scopedRotating.path}.complete`),false);
const legacy=module.createGuardJournalWriter({schemaVersion:1,stateDir:scopedState,clientId:'guardian'});legacy.write({event:'legacy-v09',timestamp:'2026-05-01T09:00:00.000Z'});await legacy.close();
const withoutLegacy=await module.readWorkspaceGuardJournal({schemaVersion:2,stateDir:scopedState,workspaceId:workspaceA,kind:'guardian'});
assert.ok(!JSON.stringify(withoutLegacy.records).includes('legacy-v09'));
const unsafeScopedState=join(tmp,'unsafe-workspace-session'),unsafeScopedLogs=join(unsafeScopedState,'logs'),unsafeScopedWorkspace=join(unsafeScopedLogs,workspaceA);
await mkdir(unsafeScopedWorkspace,{recursive:true,mode:0o700});await chmod(unsafeScopedState,0o700);await chmod(unsafeScopedLogs,0o700);await chmod(unsafeScopedWorkspace,0o700);
await symlink(outside,join(unsafeScopedWorkspace,sessionA));const scopedWarnings=[];
const unsafeScoped=module.createSessionGuardJournalWriter({schemaVersion:2,stateDir:unsafeScopedState,workspaceId:workspaceA,sessionId:sessionA,kind:'guardian'},message=>scopedWarnings.push(message));
unsafeScoped.write({event:'refused'});await unsafeScoped.flush();assert.equal(unsafeScoped.health().dropped,1);assert.equal(scopedWarnings.length,1);
const unsafeScopedRead=await module.readWorkspaceGuardJournal({schemaVersion:2,stateDir:unsafeScopedState,workspaceId:workspaceA,kind:'guardian'});
assert.deepEqual(unsafeScopedRead.records,[]);assert.ok(unsafeScopedRead.notices.some(notice=>notice.includes('unsafe session directory')));

const loaded = await createJiti(import.meta.url, { fsCache: false }).import(file);
assert.equal(typeof loaded.createGuardJournalWriter, 'function');
assert.equal(typeof loaded.readGuardJournal, 'function');
assert.equal(typeof loaded.createSessionGuardJournalWriter,'function');
assert.equal(typeof loaded.readWorkspaceGuardJournal,'function');
assert.ok((await readFile(join(root, 'docker', 'Dockerfile'), 'utf8')).includes(
  'COPY extensions/guard-journal.ts /usr/local/lib/node_modules/guardian-agent/'));
console.log(`guard journal writers, merged reading, retention, private modes, and unsafe-path tests passed (${basename(file)})`);
NODE
