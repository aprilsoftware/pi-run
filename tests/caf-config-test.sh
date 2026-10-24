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
const manyUsers=Array.from({length:40},(_,index)=>({type:'message',id:`user-${index}`,message:{role:'user',content:[{type:'text',text:`authorization ${index}`} ]}}));
const boundedAuthorization=caf.collectCafAuthorizationMessages([...manyUsers,{type:'message',id:'oversized',message:{role:'user',content:'x'.repeat(17*1024)}},{type:'message',id:'assistant',message:{role:'assistant',content:[{type:'text',text:'not user authority'}]}}]);
assert.equal(boundedAuthorization.complete,false);assert.equal(boundedAuthorization.messages.length,32);assert.equal(boundedAuthorization.messages[0].id,'user-8');assert.equal(boundedAuthorization.messages.at(-1).id,'user-39');assert.equal(Object.isFrozen(boundedAuthorization),true);
assert.equal(caf.collectCafAuthorizationMessages([{type:'message',id:'image-user',message:{role:'user',content:[{type:'image',data:'omitted'}]}}]).complete,false);
const profile=join(tmp,'profile');await mkdir(profile,{mode:0o700});
assert.deepEqual(await caf.loadCafConfig(profile),caf.defaultCafConfig());
await caf.saveCafConfig(profile,valid);
const path=join(profile,'caf','config.json');
assert.deepEqual(await caf.loadCafConfig(profile),valid);
assert.equal((await lstat(join(profile,'caf'))).mode&0o777,0o700);assert.equal((await lstat(path)).mode&0o777,0o600);
const firstInode=(await lstat(path)).ino;await caf.saveCafConfig(profile,{...valid,thinking:null});
assert.notEqual((await lstat(path)).ino,firstInode);assert.ok(!(await readdir(join(profile,'caf'))).some(name=>name.startsWith('.config.json.tmp.')));
assert.deepEqual(await caf.loadCafPolicy(profile),{source:'built-in',text:null});
const policyPath=join(profile,'caf','caf.md'),policyText='# Private CAF policy\nDo not disclose internal names.\n';await writeFile(policyPath,policyText,{mode:0o600});
assert.deepEqual(await caf.loadCafPolicy(profile),{source:'profile',text:policyText});
await chmod(policyPath,0o644);await assert.rejects(caf.loadCafPolicy(profile),/private single-link/);await chmod(policyPath,0o600);
await writeFile(policyPath,Buffer.alloc(64*1024+1,120));await assert.rejects(caf.loadCafPolicy(profile),/private single-link|too large/);
await writeFile(policyPath,Buffer.from([0xff]));await assert.rejects(caf.loadCafPolicy(profile));
const policyOutside=join(tmp,'outside-policy');await writeFile(policyOutside,policyText,{mode:0o600});await rm(policyPath);await link(policyOutside,policyPath);await assert.rejects(caf.loadCafPolicy(profile),/private single-link/);
await rm(policyPath);await symlink(policyOutside,policyPath);await assert.rejects(caf.loadCafPolicy(profile));await rm(policyPath);await writeFile(policyPath,policyText,{mode:0o600});
await chmod(path,0o644);await assert.rejects(caf.loadCafConfig(profile),/private single-link/);await chmod(path,0o600);
const outside=join(tmp,'outside');await writeFile(outside,'outside\n',{mode:0o600});await rm(path);await symlink(outside,path);
await assert.rejects(caf.saveCafConfig(profile,valid),/private single-link/);assert.equal(await readFile(outside,'utf8'),'outside\n');await rm(path);
await link(outside,path);await assert.rejects(caf.saveCafConfig(profile,valid),/private single-link/);
const redirected=join(tmp,'redirected');await mkdir(redirected,{mode:0o700});await symlink(join(profile,'caf'),join(redirected,'caf'));
await assert.rejects(caf.loadCafConfig(redirected),/private, owned, and unredirected/);await assert.rejects(caf.loadCafPolicy(redirected),/private, owned, and unredirected/);

const disclosure={schemaVersion:1,kind:'friend-message',message:'Review this abstract public interface.',purpose:'Independent API critique',destination:{model:'friend/frontier'}};
const disclosurePolicy={source:'profile',text:policyText};let reviewed;
const allowReviewer={async review(action,context){reviewed={action,context};return {schemaVersion:1,outcome:'ALLOW',reason:'The abstract payload follows policy.'};}};
let result=await caf.runCafDisclosureReview(disclosure,disclosurePolicy,allowReviewer,new AbortController().signal);
assert.equal(result.released,true);assert.deepEqual(result.action,disclosure);assert.deepEqual(reviewed.context.policy,disclosurePolicy);assert.equal(Object.isFrozen(reviewed.action),true);assert.equal(Object.isFrozen(reviewed.context.policy),true);
assert.deepEqual(Object.keys(reviewed.action).sort(),['destination','kind','message','purpose','schemaVersion']);assert.deepEqual(Object.keys(reviewed.context).sort(),['policy','signal']);
assert.equal(Object.isFrozen(result.decision),true);assert.throws(()=>{reviewed.action.message='changed';},TypeError);assert.equal(result.action.message,disclosure.message);
for(const outcome of ['ASK','USER_REFUSED']){result=await caf.runCafDisclosureReview(disclosure,disclosurePolicy,{async review(){return {schemaVersion:1,outcome,reason:'Withheld.'};}},new AbortController().signal);assert.deepEqual(result,{released:false,outcome,reason:'Withheld.'});}
for(const reviewer of [undefined,{async review(){throw new Error('review failed');}},{async review(){return {outcome:'ALLOW'};}}]){
  result=await caf.runCafDisclosureReview(disclosure,disclosurePolicy,reviewer,new AbortController().signal);assert.equal(result.released,false);
}
const cancelled=new AbortController();cancelled.abort(new Error('cancelled fixture'));result=await caf.runCafDisclosureReview(disclosure,disclosurePolicy,allowReviewer,cancelled.signal);assert.equal(result.released,false);assert.match(result.reason,/cancelled fixture/);
result=await caf.runCafDisclosureReview(disclosure,disclosurePolicy,{review:()=>new Promise(()=>{})},new AbortController().signal,5);assert.equal(result.released,false);assert.match(result.reason,/timed out/);
result=await caf.runCafDisclosureReview({...disclosure,workspace:'/workspace'},disclosurePolicy,allowReviewer,new AbortController().signal);assert.equal(result.released,false);
result=await caf.runCafDisclosureReview(disclosure,{source:'profile',text:null},allowReviewer,new AbortController().signal);assert.equal(result.released,false);

const commandProfile=join(tmp,'command-profile');await mkdir(commandProfile,{mode:0o700});process.env.PI_RUN_PROFILE_DIR=commandProfile;
const {createEventBus}=await import(pathToFileURL(join(piDir,'dist/core/event-bus.js')).href),bus=createEventBus();
const handlers=new Map(),commands=new Map(),notifications=[];
const pi={events:bus,on(name,handler){const rows=handlers.get(name)??[];rows.push(handler);handlers.set(name,rows);return()=>handlers.set(name,(handlers.get(name)??[]).filter(row=>row!==handler));},registerCommand(name,command){commands.set(name,command);}};
runtime.default(pi);caf.default(pi);assert.ok(commands.has('caf'));
const available=[{provider:'friend',id:'frontier'},{provider:'local',id:'small'}],selections=[],providerCalls=[];let providerOutput=JSON.stringify({schemaVersion:1,outcome:'ALLOW',reason:'Explicitly authorized and abstract.'});
let branch=[{type:'message',id:'current-user',message:{role:'user',content:[{type:'text',text:'You may ask the configured friend about this abstract API design.'}]}},
  {type:'message',id:'assistant-private',message:{role:'assistant',content:[{type:'text',text:'assistant-only private analysis'}]}},
  {type:'message',id:'tool-private',message:{role:'toolResult',content:[{type:'text',text:'private tool result'}]}},
  {type:'custom',customType:caf.CAF_ROUND_ENTRY,data:questions}];
const ctx={mode:'json',hasUI:false,model:available[1],cwd:'/private/workspace',modelRegistry:{getAvailable:()=>available,find:(provider,id)=>available.find(model=>model.provider===provider&&model.id===id),
  complete:async(model,request,options)=>{providerCalls.push({model,request,options});return {stopReason:'stop',content:[{type:'text',text:providerOutput}]};}},
  ui:{notify:(text,level)=>notifications.push({text,level}),select:async()=>selections.shift()},sessionManager:{getSessionId:()=> 'session',getBranch:()=>branch,getEntries:()=>{throw new Error('CAF must use only the current branch');}}};
const dispatch=async(name,event)=>{for(const handler of handlers.get(name)??[])await handler(event,ctx);};
await dispatch('session_start',{type:'session_start',reason:'resume'});
await commands.get('caf').handler('status',ctx);assert.match(notifications.at(-1).text,/Guard Runtime: available/);assert.match(notifications.at(-1).text,/Disclosure policy: built-in only/);assert.match(notifications.at(-1).text,/Disclosure review: ready — primary model/);assert.match(notifications.at(-1).text,/Conversation: 1 completed round/);assert.match(notifications.at(-1).text,/Friend calls: not enabled/);assert.equal(providerCalls.length,0);
result=await caf.runPrimaryCafDisclosureReview(disclosure,{source:'built-in',text:null},ctx,new AbortController().signal);
assert.equal(result.released,true);assert.equal(providerCalls.length,1);assert.equal(providerCalls[0].model,available[1]);assert.ok(providerCalls[0].options.signal instanceof AbortSignal);assert.deepEqual(Object.keys(providerCalls[0].request).sort(),['messages','systemPrompt']);
const privateReviewPayload=JSON.parse(providerCalls[0].request.messages[0].content[0].text);
assert.deepEqual(privateReviewPayload.disclosure,disclosure);assert.deepEqual(privateReviewPayload.policy,{source:'built-in',text:null});assert.deepEqual(privateReviewPayload.authorization,{complete:true,messages:[{id:'current-user',text:'You may ask the configured friend about this abstract API design.'}]});
assert.ok(!JSON.stringify(privateReviewPayload).includes('assistant-only private analysis'));assert.ok(!JSON.stringify(privateReviewPayload).includes('private tool result'));assert.ok(!JSON.stringify(privateReviewPayload).includes('/private/workspace'));
const completeBranch=branch;branch=manyUsers;result=await caf.runPrimaryCafDisclosureReview(disclosure,{source:'built-in',text:null},ctx,new AbortController().signal);assert.equal(result.released,false);assert.equal(result.outcome,'ASK');branch=completeBranch;
providerOutput='not-json';result=await caf.runPrimaryCafDisclosureReview(disclosure,{source:'built-in',text:null},ctx,new AbortController().signal);assert.equal(result.released,false);providerOutput=JSON.stringify({schemaVersion:1,outcome:'ALLOW',reason:'Explicitly authorized and abstract.'});
let enteredResolve,observedProviderSignal;const entered=new Promise(resolve=>{enteredResolve=resolve;});
const cancelCtx={...ctx,modelRegistry:{...ctx.modelRegistry,complete:async(_model,_request,options)=>{observedProviderSignal=options.signal;enteredResolve();return new Promise((_,reject)=>options.signal.addEventListener('abort',()=>reject(options.signal.reason),{once:true}));}}};
const primaryCancellation=new AbortController(),pendingReview=caf.runPrimaryCafDisclosureReview(disclosure,{source:'built-in',text:null},cancelCtx,primaryCancellation.signal);await entered;primaryCancellation.abort(new Error('cancelled primary reviewer'));result=await pendingReview;assert.equal(result.released,false);assert.equal(observedProviderSignal.aborted,true);
result=await caf.runPrimaryCafDisclosureReview(disclosure,{source:'built-in',text:null},{...ctx,model:null},new AbortController().signal);assert.equal(result.released,false);
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
console.log('CAF primary disclosure reviewer, gate, configuration, branch state, path safety, and packaging tests passed');
NODE
