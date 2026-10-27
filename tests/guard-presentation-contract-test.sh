#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'guard-presentation-contract-test: Pi package unavailable' >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { appendFile, chmod, mkdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [root,piDir,tmp]=process.argv.slice(2),profile=join(tmp,'profile'),workspaceId='11111111-1111-4111-8111-111111111111',sessionId='00000000-0000-7000-8000-000000000001';
await mkdir(profile,{mode:0o700});await chmod(profile,0o700);
const require=createRequire(join(piDir,'package.json')),{createJiti}=require('jiti');
const alias={'@earendil-works/pi-coding-agent':join(piDir,'dist','index.js'),'@earendil-works/pi-agent-core':join(piDir,'node_modules','@earendil-works','pi-agent-core','dist','index.js'),
  '@earendil-works/pi-ai':join(piDir,'node_modules','@earendil-works','pi-ai','dist','index.js'),'@earendil-works/pi-tui':join(piDir,'node_modules','@earendil-works','pi-tui','dist','index.js'),typebox:require.resolve('typebox')};
const jiti=createJiti(import.meta.url,{alias,fsCache:false}),runtimeFile=join(root,'docker/extensions/guard-runtime.ts');
const [runtime,guardian,caf,journal]=await Promise.all([
  jiti.import(runtimeFile),jiti.import(join(root,'docker/extensions/guardian-agent.ts')),jiti.import(join(root,'docker/extensions/caf-agent.ts')),jiti.import(join(root,'docker/extensions/guard-journal.ts')),
]);
const base=Date.parse('2026-04-02T12:00:00.000Z'),timestamp=index=>new Date(base+index*1000).toISOString();
const cafWriter=journal.createGuardJournalWriter({schemaVersion:1,stateDir:profile,clientId:'caf',maxBytes:1024*1024,backups:2,maxPending:1000});
let sequence=0;
for(let index=0;index<60;index++){
  const operationId=`operation-${String(index).padStart(2,'0')}`,time=timestamp(sequence++);
  cafWriter.write({schemaVersion:1,timestamp:time,event:'operation_started',operationId,message:index===0?'EXACT PRIVATE MESSAGE':{bytes:12,sha256:'fingerprint'},purpose:'EXACT PRIVATE PURPOSE'});
  cafWriter.write({schemaVersion:1,timestamp:timestamp(sequence++),event:'disclosure_reviewed',operationId,kind:'friend-message',model:'friend/frontier',outcome:'ALLOW'});
  cafWriter.write({schemaVersion:1,timestamp:timestamp(sequence++),event:'operation_finished',operationId,outcome:'answer',reviewPath:'guarded',friendRequestStarted:true,research:false,durationMs:100+index,usage:{totalTokens:index+1}});
}
cafWriter.write({schemaVersion:1,timestamp:timestamp(sequence++),event:'operation_started',operationId:'partial-operation'});
cafWriter.write({schemaVersion:1,timestamp:timestamp(sequence++),event:'session_started',mode:'on'});
await cafWriter.flush();await appendFile(cafWriter.path,'{"malformed"\n');
const guardianLogger=guardian.createLogger(profile,workspaceId,sessionId,()=>{}),common={profile:'fixture',sessionId,processId:7,container:'fixture',toolName:'bash',toolCallId:'call-1',reviewId:'review-1'};
guardianLogger.write({schemaVersion:1,timestamp:timestamp(sequence++),event:'review_started',message:'Reviewing fixture',...common,details:{action:{command:'printf presentation-fixture'}}});
guardianLogger.write({schemaVersion:1,timestamp:timestamp(sequence++),event:'review_decision',message:'Fixture allowed',...common,details:{outcome:'ALLOW',basis:'explicit_authorization',reason:'Synthetic presentation fixture.',durationMs:12}});
guardianLogger.write({schemaVersion:1,timestamp:timestamp(sequence++),event:'review_finished',message:'Review finished',...common,details:{outcome:'ALLOW',decisionAvailable:true,durationMs:12,stage:'validate'}});
await guardianLogger.flush();
let guardianFlushes=0,cafFlushes=0;
const guardianRequest=guardian.createGuardianLogViewRequest(profile,workspaceId,async()=>{guardianFlushes++;await guardianLogger.flush();},'allowed');
const cafRequest=caf.createCafLogViewRequest(profile,async()=>{cafFlushes++;await cafWriter.flush();},'answered');
assert.equal(guardianRequest.initialQuery,'allowed');assert.equal(cafRequest.initialQuery,'answered');
assert.deepEqual(guardianRequest.sections.map(section=>section.id),['summary','command','evidence','timeline']);
assert.deepEqual(cafRequest.sections.map(section=>section.id),['summary','timeline']);
const signal=new AbortController().signal;
const guardianFirst=await guardianRequest.load(signal),guardianSecond=await guardianRequest.load(signal),cafFirst=await cafRequest.load(signal),cafSecond=await cafRequest.load(signal);
assert.equal(guardianFlushes,2);assert.equal(cafFlushes,2);assert.equal(guardianFirst.rows.length,1);assert.equal(guardianSecond.rows.length,1);
assert.equal(cafFirst.rows.length,61,'CAF must read beyond the former 50-record bound');assert.equal(cafSecond.rows.length,61);assert.ok(cafFirst.notices.length>0,'Malformed journal input must remain a bounded notice');assert.match(cafFirst.rows[0].compact,/Partial/);
const utcStamp=/2026-04-02 12:\d{2}:\d{2} UTC/;
assert.match(guardianFirst.rows[0].wide,utcStamp);assert.match(guardianFirst.rows[0].compact,utcStamp);assert.match(cafFirst.rows[0].wide,utcStamp);assert.match(cafFirst.rows[0].compact,utcStamp);
assert.match(guardianRequest.details(guardianFirst.rows[0].id,'command').join('\n'),/printf presentation-fixture/);
assert.match(guardianRequest.details(guardianFirst.rows[0].id,'summary').join('\n'),utcStamp);assert.match(guardianRequest.details(guardianFirst.rows[0].id,'timeline').join('\n'),utcStamp);
const completedCaf=cafFirst.rows.find(row=>/Answered/.test(row.compact));assert.ok(completedCaf);const cafSummary=cafRequest.details(completedCaf.id,'summary').join('\n'),cafTimeline=cafRequest.details(completedCaf.id,'timeline').join('\n');assert.match(cafSummary,/Review path: guarded/);assert.match(cafSummary,utcStamp);assert.match(cafTimeline,utcStamp);
const cafPresentation=JSON.stringify(cafFirst.rows.map(row=>({row,summary:cafRequest.details(row.id,'summary'),timeline:cafRequest.details(row.id,'timeline')})));
for(const forbidden of ['EXACT PRIVATE MESSAGE','EXACT PRIVATE PURPOSE','fingerprint'])assert.ok(!cafPresentation.includes(forbidden),`CAF presentation leaked ${forbidden}`);
const {createEventBus}=await import(pathToFileURL(join(piDir,'dist/core/event-bus.js')).href),bus=createEventBus(),handlers=new Map();
const pi={events:bus,on(name,handler){const rows=handlers.get(name)??[];rows.push(handler);handlers.set(name,rows);return()=>handlers.set(name,(handlers.get(name)??[]).filter(row=>row!==handler));}};
const emit=async(name,event,ctx)=>{for(const handler of handlers.get(name)??[])await handler(event,ctx);};
const waitFor=async predicate=>{for(let index=0;index<100&&!predicate();index++)await new Promise(resolve=>setTimeout(resolve,5));assert.ok(predicate(),'Timed out waiting for viewer');};
runtime.default(pi);const guardianClient=runtime.connectGuardClient(pi,{schemaVersion:1,id:'guardian',label:'Guardian'}),cafClient=runtime.connectGuardClient(pi,{schemaVersion:1,id:'caf',label:'Call a Friend'});
const rendered=[];let customCalls=0,current;
const tuiContext={mode:'tui',hasUI:true,ui:{setWidget(){},notify(){throw new Error('TUI presentation must not notify');},custom(factory){customCalls++;return new Promise(resolve=>{let component;
  const done=value=>{component?.dispose?.();resolve(value);};component=factory({terminal:{rows:24},requestRender(){}},{fg:(_role,text)=>text,bg:(_role,text)=>text},{},done);current=component;
  const list=component.render(120).join('\n');component.handleInput('\r');rendered.push({list,detail:component.render(120).join('\n')});});}}};
await emit('session_start',{type:'session_start'},tuiContext);
let pending=guardianClient.openView(guardianRequest);await waitFor(()=>customCalls===1);const cafIgnored=await cafClient.openView(cafRequest);assert.equal(cafIgnored,undefined);assert.equal(customCalls,1,'Cross-client viewers must not stack');guardianClient.closeView();await pending;
pending=cafClient.openView(cafRequest);await waitFor(()=>customCalls===2);cafClient.closeView();await pending;
assert.match(rendered[0].list,/Guardian reviews/);assert.match(rendered[0].list,/Search: allowed/);assert.match(rendered[0].detail,/Command|printf presentation-fixture/);
assert.match(rendered[1].list,/Call a Friend operations/);assert.match(rendered[1].list,/Search: answered/);assert.match(rendered[1].detail,/Summary|Call a Friend operation/);
const notifications=[],printContext={mode:'print',hasUI:false,ui:{setWidget(){},notify(text,level){notifications.push({text,level});}}};
await emit('session_tree',{type:'session_tree'},printContext);const before=[guardianFlushes,cafFlushes];await guardianClient.openView(guardianRequest);await cafClient.openView(cafRequest);
assert.deepEqual([guardianFlushes,cafFlushes],before,'Non-TUI fallback must not load journals');assert.equal(notifications.length,2);assert.match(notifications[0].text,/Guardian journals:/);assert.match(notifications[1].text,/CAF journals:/);
await emit('session_shutdown',{type:'session_shutdown',reason:'exit'},printContext);await Promise.all([guardianLogger.close(),cafWriter.close()]);
console.log('shared Guardian and CAF presentation contract, bounds, privacy, search, lifecycle, and fallback passed');
NODE
