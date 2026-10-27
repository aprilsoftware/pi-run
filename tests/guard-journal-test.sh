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
import { appendFile, chmod, link, mkdir, readFile, readdir, stat, symlink, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { basename, dirname, join } from 'node:path';
const [root, piDir, tmp] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const file = join(root, 'docker', 'extensions', 'guard', 'guard-journal.ts');
const journal = await createJiti(import.meta.url, { fsCache: false }).import(file);
const mode = async path => (await stat(path)).mode & 0o777;
const exists = async path => stat(path).then(() => true, error => error.code === 'ENOENT' ? false : Promise.reject(error));
const entries = async path => (await readFile(path, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);
const workspaceA='11111111-1111-4111-8111-111111111111',workspaceB='22222222-2222-4222-8222-222222222222';
const sessionA='00000000-0000-7000-8000-000000000001',sessionB='00000000-0000-7000-8000-000000000002',sessionC='00000000-0000-7000-8000-000000000003';

const state=join(tmp,'profile');await mkdir(state,{mode:0o700});
const selectedSessionDir=join(state,'sessions',workspaceA);await mkdir(selectedSessionDir,{recursive:true,mode:0o700});
assert.equal(journal.guardJournalWorkspaceId(state,selectedSessionDir),workspaceA);
for(const sessionDir of [join(state,'sessions','bad'),join(tmp,workspaceA)])assert.throws(()=>journal.guardJournalWorkspaceId(state,sessionDir),/Guard journal/);
for(const options of [null,{},
  {schemaVersion:2,stateDir:state,workspaceId:'../bad',sessionId:sessionA,kind:'guardian'},
  {schemaVersion:2,stateDir:state,workspaceId:workspaceA,sessionId:'bad',kind:'guardian'},
  {schemaVersion:2,stateDir:state,workspaceId:workspaceA,sessionId:sessionA,kind:'other'},
  {schemaVersion:2,stateDir:state,workspaceId:workspaceA,sessionId:sessionA,kind:'guardian',backups:9},
  {schemaVersion:2,stateDir:state,workspaceId:workspaceA,sessionId:sessionA,kind:'guardian',maxBytes:10}])
  assert.throws(()=>journal.createSessionGuardJournalWriter(options),/Invalid Guard journal/);

const first=journal.createSessionGuardJournalWriter({schemaVersion:2,stateDir:state,workspaceId:workspaceA,sessionId:sessionA,kind:'guardian'});
first.write({event:'session-a-first',timestamp:'2026-05-01T10:00:01.000Z'});await first.close();
assert.equal(first.path,join(state,'logs',workspaceA,sessionA,'guardian.jsonl'));assert.equal(await mode(first.path),0o600);
assert.deepEqual(first.health(),{pending:0,dropped:0,written:1,lastError:null});assert.equal(await exists(`${first.path}.complete`),false);
const resumed=journal.createSessionGuardJournalWriter({schemaVersion:2,stateDir:state,workspaceId:workspaceA,sessionId:sessionA,kind:'guardian'});
assert.equal(resumed.path,first.path);resumed.write({event:'session-a-resumed',timestamp:'2026-05-01T10:00:03.000Z'});await resumed.close();
resumed.write({event:'closed-writer-refuses'});assert.equal(resumed.health().dropped,1);
const sessionRows=await entries(first.path);assert.deepEqual(sessionRows.map(row=>row.event),['session-a-first','session-a-resumed']);
assert.ok(sessionRows.every(row=>row.journal.schemaVersion===2&&row.journal.kind==='guardian'&&row.journal.workspaceId===workspaceA&&row.journal.sessionId===sessionA));

const second=journal.createSessionGuardJournalWriter({schemaVersion:2,stateDir:state,workspaceId:workspaceA,sessionId:sessionB,kind:'guardian'});
second.write({event:'session-b',timestamp:'2026-05-01T10:00:02.000Z'});await second.close();
const caf=journal.createSessionGuardJournalWriter({schemaVersion:2,stateDir:state,workspaceId:workspaceA,sessionId:sessionA,kind:'caf'});
caf.write({event:'caf-only',timestamp:'2026-05-01T10:00:04.000Z'});await caf.close();
const other=journal.createSessionGuardJournalWriter({schemaVersion:2,stateDir:state,workspaceId:workspaceB,sessionId:sessionA,kind:'guardian'});
other.write({event:'other-workspace',timestamp:'2026-05-01T10:00:05.000Z'});await other.close();
let snapshot=await journal.readWorkspaceGuardJournal({schemaVersion:2,stateDir:state,workspaceId:workspaceA,kind:'guardian'});
assert.deepEqual(snapshot.records.map(record=>record.value.event),['session-a-first','session-b','session-a-resumed']);
assert.deepEqual(new Set(snapshot.records.map(record=>record.sessionId)),new Set([sessionA,sessionB]));
assert.ok(!JSON.stringify(snapshot.records).includes('caf-only'));assert.ok(!JSON.stringify(snapshot.records).includes('other-workspace'));
const cafSnapshot=await journal.readWorkspaceGuardJournal({schemaVersion:2,stateDir:state,workspaceId:workspaceA,kind:'caf'});
assert.deepEqual(cafSnapshot.records.map(record=>record.value.event),['caf-only']);
for(const directory of [join(state,'logs'),join(state,'logs',workspaceA),join(state,'logs',workspaceA,sessionA)])assert.equal(await mode(directory),0o700);

const rotating=journal.createSessionGuardJournalWriter({schemaVersion:2,stateDir:state,workspaceId:workspaceA,sessionId:sessionC,kind:'guardian',maxBytes:512,backups:2});
for(let index=1;index<=30;index++)rotating.write({event:'rotation',index,payload:'x'.repeat(90),timestamp:`2026-05-01T10:01:${String(index).padStart(2,'0')}.000Z`});
await rotating.close();const rotationPaths=[`${rotating.path}.2`,`${rotating.path}.1`,rotating.path];
for(const path of rotationPaths){assert.ok(await exists(path));assert.ok((await stat(path)).size<=512);assert.equal(await mode(path),0o600);}
const rotationRows=(await Promise.all(rotationPaths.map(entries))).flat();assert.ok(rotationRows.length>0&&rotationRows.length<30);assert.equal(rotationRows.at(-1).index,30);
assert.equal(await exists(`${rotating.path}.complete`),false);

const readState=join(tmp,'read-profile');await mkdir(readState,{mode:0o700});
const readWriters=[sessionA,sessionB].map(sessionId=>journal.createSessionGuardJournalWriter({schemaVersion:2,stateDir:readState,workspaceId:workspaceA,sessionId,kind:'guardian'}));
readWriters[0].write({event:'late',timestamp:'2026-06-01T00:00:03.000Z'});readWriters[0].write({event:'early',timestamp:'2026-06-01T00:00:01.000Z'});
readWriters[1].write({event:'middle',timestamp:'2026-06-01T00:00:02.000Z'});await Promise.all(readWriters.map(writer=>writer.close()));
await appendFile(readWriters[1].path,'not-json\n{"event":"unfinished"');
await writeFile(join(dirname(readWriters[0].path),'unexpected.txt'),'ignored\n',{mode:0o600});
snapshot=await journal.readWorkspaceGuardJournal({schemaVersion:2,stateDir:readState,workspaceId:workspaceA,kind:'guardian'});
assert.deepEqual(snapshot.records.map(record=>record.value.event),['early','middle','late']);assert.equal(snapshot.malformed,1);
assert.ok(snapshot.notices.some(notice=>notice.includes('incomplete trailing record')));assert.ok(snapshot.notices.some(notice=>notice.includes('unexpected entry omitted')));
const bounded=await journal.readWorkspaceGuardJournal({schemaVersion:2,stateDir:readState,workspaceId:workspaceA,kind:'guardian',maxRecords:2});
assert.deepEqual(bounded.records.map(record=>record.value.event),['middle','late']);assert.ok(bounded.notices.some(notice=>notice.includes('record limit')));
const oneFile=await journal.readWorkspaceGuardJournal({schemaVersion:2,stateDir:readState,workspaceId:workspaceA,kind:'guardian',maxFiles:1});
assert.equal(oneFile.files.length,1);assert.ok(oneFile.notices.some(notice=>notice.includes('file limit')));
const byteBound=await journal.readWorkspaceGuardJournal({schemaVersion:2,stateDir:readState,workspaceId:workspaceA,kind:'guardian',maxFileBytes:64,maxTotalBytes:64});
assert.ok(byteBound.notices.some(notice=>notice.includes('byte')));
const cancelled=new AbortController();cancelled.abort(new Error('synthetic cancellation'));
await assert.rejects(journal.readWorkspaceGuardJournal({schemaVersion:2,stateDir:readState,workspaceId:workspaceA,kind:'guardian'},cancelled.signal),/synthetic cancellation/);

const linkedState=join(tmp,'linked-profile');await mkdir(linkedState,{mode:0o700});
const linked=journal.createSessionGuardJournalWriter({schemaVersion:2,stateDir:linkedState,workspaceId:workspaceA,sessionId:sessionA,kind:'guardian'});
linked.write({event:'first'});await linked.flush();await link(linked.path,`${linked.path}.extra`);linked.write({event:'refused'});await linked.flush();assert.equal(linked.health().dropped,1);
const linkedRead=await journal.readWorkspaceGuardJournal({schemaVersion:2,stateDir:linkedState,workspaceId:workspaceA,kind:'guardian'});
assert.deepEqual(linkedRead.records,[]);assert.ok(linkedRead.notices.some(notice=>notice.includes('unsafe file')));
const unsafeState=join(tmp,'unsafe-profile'),outside=join(tmp,'outside');await mkdir(unsafeState,{mode:0o700});await mkdir(outside,{mode:0o700});await symlink(outside,join(unsafeState,'logs'));
const warnings=[],unsafe=journal.createSessionGuardJournalWriter({schemaVersion:2,stateDir:unsafeState,workspaceId:workspaceA,sessionId:sessionA,kind:'guardian'},message=>warnings.push(message));
unsafe.write({event:'refused'});await unsafe.flush();assert.equal(unsafe.health().dropped,1);assert.equal(warnings.length,1);assert.deepEqual(await readdir(outside),[]);
const permissiveState=join(tmp,'permissive-profile'),permissiveLogs=join(permissiveState,'logs');await mkdir(permissiveLogs,{recursive:true,mode:0o700});await chmod(permissiveLogs,0o755);
const permissive=journal.createSessionGuardJournalWriter({schemaVersion:2,stateDir:permissiveState,workspaceId:workspaceA,sessionId:sessionA,kind:'guardian'});
permissive.write({event:'refused'});await permissive.flush();assert.equal(permissive.health().dropped,1);assert.deepEqual(await readdir(permissiveLogs),[]);

const legacyRuns=join(state,'logs','guardian','runs'),legacyPath=join(legacyRuns,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jsonl');
await mkdir(legacyRuns,{recursive:true,mode:0o700});await writeFile(legacyPath,'{"event":"legacy-v09"}\n',{mode:0o600});
const withoutLegacy=await journal.readWorkspaceGuardJournal({schemaVersion:2,stateDir:state,workspaceId:workspaceA,kind:'guardian'});
assert.ok(!JSON.stringify(withoutLegacy.records).includes('legacy-v09'));assert.equal(await exists(legacyPath),true);
assert.equal(journal.createGuardJournalWriter,undefined);assert.equal(journal.readGuardJournal,undefined);assert.equal(journal.maintainGuardJournalRetention,undefined);
assert.equal(typeof journal.createSessionGuardJournalWriter,'function');assert.equal(typeof journal.readWorkspaceGuardJournal,'function');
assert.ok((await readFile(join(root,'docker','Dockerfile'),'utf8')).includes('COPY extensions/guard/guard-journal.ts /usr/local/lib/node_modules/pi-run-extensions/guard/'));
console.log(`workspace session journal writing, reading, rotation, isolation, bounds, and safety tests passed (${basename(file)})`);
NODE
