#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'caf-config-test: Pi package unavailable' >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { chmod, link, lstat, mkdir, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [root,piDir,tmp]=process.argv.slice(2),require=createRequire(join(piDir,'package.json')),{createJiti}=require('jiti');
const alias={'@earendil-works/pi-coding-agent':join(piDir,'dist','index.js'),'@earendil-works/pi-tui':join(piDir,'node_modules','@earendil-works','pi-tui','dist','index.js')};
const jiti=createJiti(import.meta.url,{alias,fsCache:false});
const cafFile=join(root,'docker/extensions/caf-agent.ts'),runtimeFile=join(root,'docker/extensions/guard-runtime.ts');
const caf=await jiti.import(cafFile),runtime=await jiti.import(runtimeFile);
const valid={schemaVersion:1,model:'friend/frontier',thinking:'high'};
assert.deepEqual(caf.defaultCafConfig(),{schemaVersion:1,model:null,thinking:null});
assert.deepEqual(caf.parseCafConfig(JSON.stringify(valid)),valid);
for(const value of [null,{},[valid],{...valid,schemaVersion:2},{...valid,model:'invalid'},{...valid,thinking:'extreme'},{...valid,extra:true}])
  assert.throws(()=>caf.parseCafConfig(JSON.stringify(value)),/CAF configuration|JSON/);
const consultationId='11111111-1111-4111-8111-111111111111';
const questions={schemaVersion:1,consultationId,round:1,request:{message:'Please assess the public design.',purpose:'Independent design review'},
  friend:{model:'friend/frontier',thinking:'high'},response:{kind:'questions',questions:[{question:'Which constraint matters most?',whyNeeded:'It changes the recommendation.',canProceedWithoutAnswer:true}],provisionalAnswer:'Prefer the narrower design.'}};
const answer={schemaVersion:1,consultationId,round:2,request:{message:'Minimize disclosure.',purpose:'Answer the follow-up'},
  friend:{model:'friend/frontier',thinking:'high'},response:{kind:'answer',text:'Use the narrow interface.'}};
assert.deepEqual(caf.parseCafRound(answer),answer);
assert.deepEqual(caf.restoreCafConversation([{type:'message'},{type:'custom',customType:caf.CAF_ROUND_ENTRY,data:questions},{type:'custom',customType:caf.CAF_ROUND_ENTRY,data:answer}]),[questions,answer]);
for(const value of [{...answer,extra:true},{...answer,round:4},{...answer,request:{...answer.request,message:'é'.repeat(9000)}},
  {...questions,response:{...questions.response,questions:[...questions.response.questions,...questions.response.questions,...questions.response.questions,...questions.response.questions]}}])
  assert.throws(()=>caf.parseCafRound(value),/CAF/);
assert.throws(()=>caf.restoreCafConversation([{type:'custom',customType:caf.CAF_ROUND_ENTRY,data:answer}]),/consultation sequence/);
assert.throws(()=>caf.restoreCafConversation([{type:'custom',customType:caf.CAF_ROUND_ENTRY,data:{...questions,extra:true}}]),/CAF round/);
const profile=join(tmp,'profile');await mkdir(profile,{mode:0o700});
assert.deepEqual(await caf.loadCafConfig(profile),caf.defaultCafConfig());
await caf.saveCafConfig(profile,valid);
const path=join(profile,'caf','config.json');
assert.deepEqual(await caf.loadCafConfig(profile),valid);
assert.equal((await lstat(join(profile,'caf'))).mode&0o777,0o700);assert.equal((await lstat(path)).mode&0o777,0o600);
const firstInode=(await lstat(path)).ino;await caf.saveCafConfig(profile,{...valid,thinking:null});
assert.notEqual((await lstat(path)).ino,firstInode);assert.ok(!(await readdir(join(profile,'caf'))).some(name=>name.startsWith('.config.json.tmp.')));
await chmod(path,0o644);await assert.rejects(caf.loadCafConfig(profile),/private single-link/);await chmod(path,0o600);
const outside=join(tmp,'outside');await writeFile(outside,'outside\n',{mode:0o600});await rm(path);await symlink(outside,path);
await assert.rejects(caf.saveCafConfig(profile,valid),/private single-link/);assert.equal(await readFile(outside,'utf8'),'outside\n');await rm(path);
await link(outside,path);await assert.rejects(caf.saveCafConfig(profile,valid),/private single-link/);
const redirected=join(tmp,'redirected');await mkdir(redirected,{mode:0o700});await symlink(join(profile,'caf'),join(redirected,'caf'));
await assert.rejects(caf.loadCafConfig(redirected),/private, owned, and unredirected/);

const commandProfile=join(tmp,'command-profile');await mkdir(commandProfile,{mode:0o700});process.env.PI_RUN_PROFILE_DIR=commandProfile;
const {createEventBus}=await import(pathToFileURL(join(piDir,'dist/core/event-bus.js')).href),bus=createEventBus();
const handlers=new Map(),commands=new Map(),notifications=[];
const pi={events:bus,on(name,handler){const rows=handlers.get(name)??[];rows.push(handler);handlers.set(name,rows);return()=>handlers.set(name,(handlers.get(name)??[]).filter(row=>row!==handler));},registerCommand(name,command){commands.set(name,command);}};
runtime.default(pi);caf.default(pi);assert.ok(commands.has('caf'));
const available=[{provider:'friend',id:'frontier'},{provider:'local',id:'small'}],selections=[];
let branch=[{type:'custom',customType:caf.CAF_ROUND_ENTRY,data:questions}];
const ctx={mode:'json',hasUI:false,modelRegistry:{getAvailable:()=>available,find:(provider,id)=>available.find(model=>model.provider===provider&&model.id===id)},
  ui:{notify:(text,level)=>notifications.push({text,level}),select:async()=>selections.shift()},sessionManager:{getSessionId:()=> 'session',getBranch:()=>branch}};
const dispatch=async(name,event)=>{for(const handler of handlers.get(name)??[])await handler(event,ctx);};
await dispatch('session_start',{type:'session_start',reason:'resume'});
await commands.get('caf').handler('status',ctx);assert.match(notifications.at(-1).text,/Guard Runtime: available/);assert.match(notifications.at(-1).text,/Conversation: 1 completed round/);assert.match(notifications.at(-1).text,/Friend calls: not enabled/);
branch=[];await dispatch('session_tree',{type:'session_tree'});await commands.get('caf').handler('status',ctx);assert.match(notifications.at(-1).text,/Conversation: none on this branch/);
branch=[{type:'custom',customType:caf.CAF_ROUND_ENTRY,data:{...questions,extra:true}}];await dispatch('session_tree',{type:'session_tree'});await commands.get('caf').handler('status',ctx);assert.match(notifications.at(-1).text,/Conversation: unavailable/);
branch=[];await dispatch('session_tree',{type:'session_tree'});
await assert.rejects(lstat(join(commandProfile,'caf')),error=>error.code==='ENOENT');
await commands.get('caf').handler('model friend/frontier',ctx);await commands.get('caf').handler('thinking high',ctx);
assert.deepEqual(await caf.loadCafConfig(commandProfile),valid);
await commands.get('caf').handler('model missing/model',ctx);assert.match(notifications.at(-1).text,/unavailable/);assert.deepEqual(await caf.loadCafConfig(commandProfile),valid);
ctx.hasUI=true;selections.push('Thinking','default');await commands.get('caf').handler('',ctx);
assert.deepEqual(await caf.loadCafConfig(commandProfile),{...valid,thinking:null});
await dispatch('session_shutdown',{type:'session_shutdown',reason:'exit'});

const dockerfile=await readFile(join(root,'docker/Dockerfile'),'utf8'),launcher=await readFile(join(root,'bin/pi-run'),'utf8');
const guardian='/usr/local/lib/node_modules/guardian-agent/guardian-agent.ts',cafPath='/usr/local/lib/node_modules/guardian-agent/caf-agent.ts';
assert.ok(dockerfile.includes('COPY extensions/caf-agent.ts /usr/local/lib/node_modules/guardian-agent/'));
assert.ok(launcher.includes(`--extension ${cafPath}`));assert.ok(launcher.indexOf(guardian)<launcher.indexOf(cafPath));
console.log('CAF configuration, branch-local conversation state, Guard Runtime registration, path safety, and packaging tests passed');
NODE
