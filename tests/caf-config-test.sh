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
const alias={'@earendil-works/pi-coding-agent':join(piDir,'dist','index.js'),'@earendil-works/pi-tui':join(piDir,'node_modules','@earendil-works','pi-tui','dist','index.js'),typebox:require.resolve('typebox')};
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
const disclosureHistory=[{request:questions.request,response:questions.response}],continuationDisclosure={...disclosure,message:'Downtime is forbidden.',purpose:'Answer the pending question',history:disclosureHistory};
result=await caf.runCafDisclosureReview(continuationDisclosure,disclosurePolicy,allowReviewer,new AbortController().signal);assert.equal(result.released,true);assert.deepEqual(result.action,continuationDisclosure);assert.equal(Object.isFrozen(result.action.history),true);assert.equal(Object.isFrozen(result.action.history[0].response),true);
for(const malformedHistory of [[],[...disclosureHistory,...disclosureHistory,...disclosureHistory], [{...disclosureHistory[0],extra:true}]]){result=await caf.runCafDisclosureReview({...disclosure,history:malformedHistory},disclosurePolicy,allowReviewer,new AbortController().signal);assert.equal(result.released,false);}
const webAction={schemaVersion:1,kind:'web-search',query:'public API migration safety',purpose:'Find independent public evidence',destination:{tool:'web_search',provider:'brave'}};result=await caf.runCafWebSearchReview(webAction,disclosurePolicy,allowReviewer,new AbortController().signal);assert.equal(result.released,true);assert.deepEqual(result.action,webAction);for(const invalidWeb of [{...webAction,query:''},{...webAction,destination:{...webAction.destination,provider:'auto'}},{...webAction,destination:{tool:'fetch_content',provider:'brave'}}]){result=await caf.runCafWebSearchReview(invalidWeb,disclosurePolicy,allowReviewer,new AbortController().signal);assert.equal(result.released,false);}
for(const outcome of ['ASK','USER_REFUSED']){result=await caf.runCafDisclosureReview(disclosure,disclosurePolicy,{async review(){return {schemaVersion:1,outcome,reason:'Withheld.'};}},new AbortController().signal);assert.deepEqual(result,{released:false,outcome,reason:'Withheld.'});}
for(const reviewer of [undefined,{async review(){throw new Error('review failed');}},{async review(){return {outcome:'ALLOW'};}}]){
  result=await caf.runCafDisclosureReview(disclosure,disclosurePolicy,reviewer,new AbortController().signal);assert.equal(result.released,false);
}
const cancelled=new AbortController();cancelled.abort(new Error('cancelled fixture'));result=await caf.runCafDisclosureReview(disclosure,disclosurePolicy,allowReviewer,cancelled.signal);assert.equal(result.released,false);assert.match(result.reason,/cancelled fixture/);
result=await caf.runCafDisclosureReview(disclosure,disclosurePolicy,{review:()=>new Promise(()=>{})},new AbortController().signal,5);assert.equal(result.released,false);assert.match(result.reason,/timed out/);
result=await caf.runCafDisclosureReview({...disclosure,workspace:'/workspace'},disclosurePolicy,allowReviewer,new AbortController().signal);assert.equal(result.released,false);
result=await caf.runCafDisclosureReview(disclosure,{source:'profile',text:null},allowReviewer,new AbortController().signal);assert.equal(result.released,false);

const webProfile=join(tmp,'web-profile');await mkdir(webProfile,{mode:0o700});assert.equal(await caf.loadCafWebSearchProvider(webProfile),undefined);await writeFile(join(webProfile,'web-search.json'),JSON.stringify({searchProvider:'brave'}));assert.equal(await caf.loadCafWebSearchProvider(webProfile),'brave');await writeFile(join(webProfile,'web-search.json'),JSON.stringify({searchProvider:'auto'}));await assert.rejects(caf.loadCafWebSearchProvider(webProfile),/provider/);await rm(join(webProfile,'web-search.json'));await symlink(outside,join(webProfile,'web-search.json'));await assert.rejects(caf.loadCafWebSearchProvider(webProfile));
const commandProfile=join(tmp,'command-profile');await mkdir(commandProfile,{mode:0o700});await writeFile(join(commandProfile,'web-search.json'),JSON.stringify({searchProvider:'brave'}));process.env.PI_RUN_PROFILE_DIR=commandProfile;
const {createEventBus}=await import(pathToFileURL(join(piDir,'dist/core/event-bus.js')).href),bus=createEventBus();
const handlers=new Map(),commands=new Map(),tools=new Map(),notifications=[],appended=[],nestedSearchCalls=[];
let branch=[{type:'message',id:'current-user',message:{role:'user',content:[{type:'text',text:'You may ask the configured friend about this abstract API design.'}]}},
  {type:'message',id:'assistant-private',message:{role:'assistant',content:[{type:'text',text:'assistant-only private analysis'}]}},
  {type:'message',id:'tool-private',message:{role:'toolResult',content:[{type:'text',text:'private tool result'}]}},
  {type:'custom',customType:caf.CAF_ROUND_ENTRY,data:questions}];
const pi={events:bus,on(name,handler){const rows=handlers.get(name)??[];rows.push(handler);handlers.set(name,rows);return()=>handlers.set(name,(handlers.get(name)??[]).filter(row=>row!==handler));},
  registerCommand(name,command){commands.set(name,command);},registerTool(tool){tools.set(tool.name,tool);},appendEntry(customType,data){const entry={type:'custom',id:`appended-${appended.length+1}`,customType,data};appended.push(entry);branch.push(entry);}};
runtime.default(pi);caf.default(pi);assert.ok(commands.has('caf'));assert.ok(tools.has('call_friend'));
const available=[{provider:'friend',id:'frontier',reasoning:true},{provider:'local',id:'small'}],selections=[],providerCalls=[],friendCalls=[],modelSequence=[];
const reviewUsage={input:10,output:5,cacheRead:2,cacheWrite:1,totalTokens:18,cost:{input:0.1,output:0.2,cacheRead:0.01,cacheWrite:0.02,total:0.33}};
const friendUsage={input:20,output:10,cacheRead:3,cacheWrite:2,reasoning:4,totalTokens:35,cost:{input:0.2,output:0.4,cacheRead:0.02,cacheWrite:0.03,total:0.65}},searchUsage={input:1,output:2,cacheRead:0,cacheWrite:0,totalTokens:3,cost:{input:0.01,output:0.02,cacheRead:0,cacheWrite:0,total:0.03}};
let providerOutput=JSON.stringify({schemaVersion:1,outcome:'ALLOW',reason:'Explicitly authorized and abstract.'}),denySearch=false,friendAnswer='Independent public advice.',friendStopReason='stop',friendContent=()=>[{type:'text',text:friendAnswer}],friendResponses=[];
let nestedSearchResult={toolCall:{},isError:false,result:{content:[{type:'text',text:'bounded search'}],details:{},structuredContent:{responseId:'fixture',fetchId:null,queries:[{query:'CAF query fixture',answer:'Provider summary.',error:null,provider:'brave',results:[{title:'Public source',url:'https://example.com/source',snippet:'Public evidence.'}]}]},usage:searchUsage}};
const ctx={mode:'json',hasUI:false,model:available[1],cwd:'/private/workspace',modelRegistry:{getAvailable:()=>available,find:(provider,id)=>available.find(model=>model.provider===provider&&model.id===id),
  complete:async(model,request,options)=>{modelSequence.push('review');providerCalls.push({model,request,options});const action=JSON.parse(request.messages[0].content[0].text).disclosure,output=denySearch&&action.kind==='web-search'?JSON.stringify({schemaVersion:1,outcome:'ASK',reason:'Search destination is not authorized.'}):providerOutput;return {stopReason:'stop',content:[{type:'text',text:output}],usage:reviewUsage};},
  streamSimple:(model,request,options)=>{modelSequence.push('friend');friendCalls.push({model,request,options});const response=friendResponses.shift()??{stopReason:friendStopReason,content:friendContent()};return(async function*(){yield{type:'done',reason:response.stopReason,message:{role:'assistant',stopReason:response.stopReason,content:response.content,usage:friendUsage}};})();}},
  tools:[{name:'web_search'}],executeTool:async(name,args,options)=>{modelSequence.push('search');nestedSearchCalls.push({name,args,options});return nestedSearchResult;},
  ui:{notify:(text,level)=>notifications.push({text,level}),select:async()=>selections.shift()},sessionManager:{getSessionId:()=> 'session',getBranch:()=>branch,getEntries:()=>{throw new Error('CAF must use only the current branch');}}};
const dispatch=async(name,event)=>{for(const handler of handlers.get(name)??[])await handler(event,ctx);};
await dispatch('session_start',{type:'session_start',reason:'resume'});
await commands.get('caf').handler('status',ctx);assert.match(notifications.at(-1).text,/Guard Runtime: available/);assert.match(notifications.at(-1).text,/Disclosure policy: built-in only/);assert.match(notifications.at(-1).text,/Disclosure review: ready — primary model/);assert.match(notifications.at(-1).text,/Public web research: ready via brave/);assert.match(notifications.at(-1).text,/Conversation: 1 finalized round.*awaiting primary/);assert.match(notifications.at(-1).text,/Friend calls: unavailable/);assert.equal(providerCalls.length,0);assert.equal(friendCalls.length,0);assert.equal(nestedSearchCalls.length,0);
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
const callTool=tools.get('call_friend');assert.equal(callTool.exposure,'model-only');assert.equal(callTool.executionMode,'sequential');assert.deepEqual(callTool.annotations,{readOnlyHint:false,destructiveHint:false,idempotentHint:false,openWorldHint:true});
let guardService;bus.emit(runtime.GUARD_RUNTIME_DISCOVER,{schemaVersion:1,accept:value=>{guardService=value;}});const activities=[];guardService.subscribeActivity(value=>activities.push(value?.state));
const callArgs={message:'Evaluate this abstract public API shape.',purpose:'Independent design critique'};
branch=[{type:'message',id:'call-user',message:{role:'user',content:[{type:'text',text:'You may use Call a Friend for this abstract public API design.'}]}},
  {type:'message',id:'call-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-1',name:'call_friend',arguments:callArgs}]}}];
modelSequence.length=0;providerCalls.length=0;friendCalls.length=0;
let toolResult=await callTool.execute('friend-call-1',callArgs,new AbortController().signal,undefined,ctx);
assert.equal(toolResult.isError,undefined);assert.equal(toolResult.content[0].text,friendAnswer);assert.deepEqual(modelSequence,['review','friend']);assert.ok(activities.includes('reviewing-disclosure'));assert.ok(activities.includes('asking-friend'));assert.equal(guardService.activity(),undefined);assert.equal(appended.length,1);
assert.equal(providerCalls[0].model,available[1]);assert.equal(friendCalls[0].model,available[0]);assert.deepEqual(Object.keys(friendCalls[0].request).sort(),['messages','systemPrompt','tools']);assert.deepEqual(friendCalls[0].request.tools.map(tool=>tool.name),['caf_ask_primary','caf_web_search']);assert.match(friendCalls[0].request.systemPrompt,/separately reviewed consultation round/);assert.equal(friendCalls[0].options.toolChoice,'auto');assert.equal(friendCalls[0].options.reasoning,'high');
const friendPayload=JSON.parse(friendCalls[0].request.messages[0].content[0].text);assert.deepEqual(friendPayload,callArgs);assert.ok(!JSON.stringify(friendCalls[0].request).includes('You may use Call a Friend'));assert.ok(!JSON.stringify(friendCalls[0].request).includes('/private/workspace'));
assert.deepEqual(appended[0].data.request,callArgs);assert.deepEqual(appended[0].data.response,{kind:'answer',text:friendAnswer});assert.equal(appended[0].data.friend.model,'friend/frontier');assert.equal(appended[0].data.friend.thinking,'high');assert.equal(caf.restoreCafConversation(branch).length,1);
assert.equal(toolResult.usage.input,30);assert.equal(toolResult.usage.output,15);assert.equal(toolResult.usage.totalTokens,53);assert.equal(toolResult.usage.reasoning,4);assert.equal(toolResult.usage.cost.total,0.98);
await commands.get('caf').handler('status',ctx);assert.match(notifications.at(-1).text,/Conversation: 1 finalized round/);assert.match(notifications.at(-1).text,/Friend calls: ready/);
const callsBeforeAsk=friendCalls.length,entriesBeforeAsk=appended.length;providerOutput=JSON.stringify({schemaVersion:1,outcome:'ASK',reason:'The disclosure is not authorized.'});
branch.push({type:'message',id:'ask-user',message:{role:'user',content:[{type:'text',text:'Continue the private task.'}]}},{type:'message',id:'ask-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-ask',name:'call_friend',arguments:callArgs}]}});
toolResult=await callTool.execute('friend-call-ask',callArgs,new AbortController().signal,undefined,ctx);assert.equal(toolResult.isError,true);assert.equal(toolResult.usage.totalTokens,18);assert.equal(friendCalls.length,callsBeforeAsk);assert.equal(appended.length,entriesBeforeAsk);
providerOutput=JSON.stringify({schemaVersion:1,outcome:'ALLOW',reason:'Explicitly authorized and abstract.'});
branch.push({type:'message',id:'sibling-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-sibling',name:'call_friend',arguments:callArgs},{type:'toolCall',id:'other-call',name:'bash',arguments:{command:'true'}}]}});
const reviewsBeforeSibling=providerCalls.length;toolResult=await callTool.execute('friend-call-sibling',callArgs,new AbortController().signal,undefined,ctx);assert.equal(toolResult.isError,true);assert.equal(providerCalls.length,reviewsBeforeSibling);assert.equal(friendCalls.length,callsBeforeAsk);
friendAnswer='x'.repeat(65*1024);branch.push({type:'message',id:'failure-user',message:{role:'user',content:[{type:'text',text:'Use CAF for the abstract design.'}]}},{type:'message',id:'failure-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-failure',name:'call_friend',arguments:callArgs}]}});
toolResult=await callTool.execute('friend-call-failure',callArgs,new AbortController().signal,undefined,ctx);assert.equal(toolResult.isError,true);assert.equal(toolResult.details.friendRequestStarted,true);assert.equal(toolResult.usage.totalTokens,53);assert.equal(appended.length,entriesBeforeAsk);friendAnswer='Independent public advice.';
const questionArgs={message:'Assess the migration strategy.',purpose:'Identify a safe rollout'},questionItems=[{question:'Is downtime acceptable?',whyNeeded:'It determines whether an offline migration is viable.',canProceedWithoutAnswer:true}];
friendStopReason='toolUse';friendContent=()=>[{type:'text',text:'Prefer an online migration if availability is required.'},{type:'toolCall',id:'ask-primary-1',name:'caf_ask_primary',arguments:{questions:questionItems}}];
branch.push({type:'message',id:'question-user',message:{role:'user',content:[{type:'text',text:'You may ask the friend about this public migration design.'}]}},{type:'message',id:'question-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-question',name:'call_friend',arguments:questionArgs}]}});
const questionReviews=providerCalls.length,questionFriendCalls=friendCalls.length;toolResult=await callTool.execute('friend-call-question',questionArgs,new AbortController().signal,undefined,ctx);
assert.equal(toolResult.isError,undefined);assert.equal(toolResult.details.status,'questions');assert.equal(toolResult.details.round,1);assert.match(toolResult.content[0].text,/Is downtime acceptable/);assert.match(toolResult.content[0].text,/new standalone call_friend/);assert.equal(providerCalls.length,questionReviews+1);assert.equal(friendCalls.length,questionFriendCalls+1);assert.equal(appended.length,entriesBeforeAsk+1);
const questionRound=appended.at(-1).data;assert.deepEqual(questionRound.response,{kind:'questions',questions:questionItems,provisionalAnswer:'Prefer an online migration if availability is required.'});
const pendingBranch=branch;branch=[];await dispatch('session_tree',{type:'session_tree'});await commands.get('caf').handler('status',ctx);assert.match(notifications.at(-1).text,/Conversation: none/);branch=pendingBranch;await dispatch('session_tree',{type:'session_tree'});await commands.get('caf').handler('status',ctx);assert.match(notifications.at(-1).text,/awaiting primary/);
await commands.get('caf').handler('model local/small',ctx);branch.push({type:'message',id:'mismatch-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-mismatch',name:'call_friend',arguments:callArgs}]}});const reviewsBeforeMismatch=providerCalls.length,callsBeforeMismatch=friendCalls.length;toolResult=await callTool.execute('friend-call-mismatch',callArgs,new AbortController().signal,undefined,ctx);assert.equal(toolResult.details.status,'continuation-model-mismatch');assert.equal(providerCalls.length,reviewsBeforeMismatch);assert.equal(friendCalls.length,callsBeforeMismatch);await commands.get('caf').handler('model friend/frontier',ctx);
const continuationArgs={message:'Downtime is not acceptable.',purpose:'Answer the friend question and complete the rollout advice'};
friendStopReason='stop';friendAnswer='Use expand-and-contract with dual reads during backfill.';friendContent=()=>[{type:'text',text:friendAnswer}];
branch.push({type:'message',id:'continuation-user',message:{role:'user',content:[{type:'text',text:'You may answer the friend with the downtime constraint.'}]}},{type:'message',id:'continuation-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-continuation',name:'call_friend',arguments:continuationArgs}]}});
modelSequence.length=0;toolResult=await callTool.execute('friend-call-continuation',continuationArgs,new AbortController().signal,undefined,ctx);
assert.equal(toolResult.isError,undefined);assert.equal(toolResult.details.status,'answer');assert.equal(toolResult.details.round,2);assert.equal(toolResult.details.consultationId,questionRound.consultationId);assert.deepEqual(modelSequence,['review','friend']);assert.equal(appended.length,entriesBeforeAsk+2);await commands.get('caf').handler('status',ctx);assert.match(notifications.at(-1).text,/3 finalized round/);assert.doesNotMatch(notifications.at(-1).text,/awaiting primary/);
assert.match(providerCalls.at(-1).request.systemPrompt,/consultation history/);const continuationReview=JSON.parse(providerCalls.at(-1).request.messages[0].content[0].text).disclosure,continuationPayload=JSON.parse(friendCalls.at(-1).request.messages[0].content[0].text);
const expectedHistory=[{request:questionArgs,response:questionRound.response}];assert.deepEqual(continuationReview.history,expectedHistory);assert.deepEqual(continuationPayload,{...continuationArgs,history:expectedHistory});assert.ok(!JSON.stringify(continuationPayload).includes('You may answer the friend'));
const researchArgs={message:'Compare public migration guidance.',purpose:'Obtain source-linked independent advice'},researchQuery='CAF query fixture',researchPurpose='Find public migration evidence';
friendResponses.push({stopReason:'toolUse',content:[{type:'toolCall',id:'friend-search-1',name:'caf_web_search',arguments:{query:researchQuery,purpose:researchPurpose}}]},{stopReason:'stop',content:[{type:'text',text:'Use a staged public migration pattern and verify source [1].'}]});
branch.push({type:'message',id:'research-user',message:{role:'user',content:[{type:'text',text:'You may perform a public search for this abstract migration question.'}]}},{type:'message',id:'research-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-research',name:'call_friend',arguments:researchArgs}]}});
modelSequence.length=0;const searchesBefore=nestedSearchCalls.length,entriesBeforeResearch=appended.length;toolResult=await callTool.execute('friend-call-research',researchArgs,new AbortController().signal,undefined,ctx);
assert.equal(toolResult.isError,undefined);assert.equal(toolResult.details.research,true);assert.deepEqual(modelSequence,['review','friend','review','search','friend']);assert.equal(nestedSearchCalls.length,searchesBefore+1);assert.equal(appended.length,entriesBeforeResearch+1);assert.match(toolResult.content[0].text,/Search sources supplied/);assert.match(toolResult.content[0].text,/https:\/\/example.com\/source/);assert.equal(toolResult.usage.totalTokens,109);
const nested=nestedSearchCalls.at(-1);assert.equal(nested.name,'web_search');assert.deepEqual(nested.args,{query:researchQuery,provider:'brave',numResults:5,includeContent:false,workflow:'none'});assert.ok(nested.options.signal instanceof AbortSignal);
const searchDisclosure=JSON.parse(providerCalls.at(-1).request.messages[0].content[0].text).disclosure;assert.deepEqual(searchDisclosure,{schemaVersion:1,kind:'web-search',query:researchQuery,purpose:researchPurpose,destination:{tool:'web_search',provider:'brave'}});
const firstResearchCall=friendCalls.at(-2),finalResearchCall=friendCalls.at(-1);assert.deepEqual(firstResearchCall.request.tools.map(tool=>tool.name),['caf_ask_primary','caf_web_search']);assert.equal(finalResearchCall.request.tools,undefined);assert.equal(finalResearchCall.options.toolChoice,'none');
const finalResearchPayload=JSON.parse(finalResearchCall.request.messages[0].content[0].text);assert.deepEqual(finalResearchPayload.research,{kind:'web-search',query:researchQuery,purpose:researchPurpose,provider:'brave',answer:'Provider summary.',results:[{title:'Public source',url:'https://example.com/source',snippet:'Public evidence.'}]});assert.ok(!JSON.stringify(finalResearchPayload).includes('research-user'));
assert.deepEqual(appended.at(-1).data.research,finalResearchPayload.research);assert.equal(caf.restoreCafConversation(branch).at(-1).research.provider,'brave');assert.throws(()=>caf.normalizeCafWebSearchResult({...nestedSearchResult,result:{...nestedSearchResult.result,structuredContent:{...nestedSearchResult.result.structuredContent,queries:[{...nestedSearchResult.result.structuredContent.queries[0],answer:'x'.repeat(17*1024)}]}}},{...webAction,query:researchQuery,purpose:researchPurpose}),/answer/);
friendResponses.push({stopReason:'toolUse',content:[{type:'toolCall',id:'friend-search-denied',name:'caf_web_search',arguments:{query:'denied query',purpose:'denied purpose'}}]});denySearch=true;branch.push({type:'message',id:'denied-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-search-denied',name:'call_friend',arguments:researchArgs}]}});const deniedSearches=nestedSearchCalls.length,deniedEntries=appended.length;toolResult=await callTool.execute('friend-call-search-denied',researchArgs,new AbortController().signal,undefined,ctx);assert.equal(toolResult.details.status,'search-review-withheld');assert.equal(nestedSearchCalls.length,deniedSearches);assert.equal(appended.length,deniedEntries);denySearch=false;
const goodNestedSearchResult=nestedSearchResult;nestedSearchResult={...goodNestedSearchResult,result:{...goodNestedSearchResult.result,structuredContent:{...goodNestedSearchResult.result.structuredContent,queries:[{...goodNestedSearchResult.result.structuredContent.queries[0],query:'wrong query'}]}}};friendResponses.push({stopReason:'toolUse',content:[{type:'toolCall',id:'friend-search-malformed',name:'caf_web_search',arguments:{query:researchQuery,purpose:researchPurpose}}]});branch.push({type:'message',id:'malformed-search-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-search-malformed',name:'call_friend',arguments:researchArgs}]}});const malformedEntries=appended.length;toolResult=await callTool.execute('friend-call-search-malformed',researchArgs,new AbortController().signal,undefined,ctx);assert.equal(toolResult.isError,true);assert.equal(appended.length,malformedEntries);nestedSearchResult=goodNestedSearchResult;
friendResponses.push({stopReason:'toolUse',content:[{type:'toolCall',id:'friend-search-limit-1',name:'caf_web_search',arguments:{query:researchQuery,purpose:researchPurpose}}]},{stopReason:'toolUse',content:[{type:'toolCall',id:'friend-search-limit-2',name:'caf_web_search',arguments:{query:'second query',purpose:'not allowed'}}]});branch.push({type:'message',id:'search-limit-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-search-limit',name:'call_friend',arguments:researchArgs}]}});const oneSearchBefore=nestedSearchCalls.length,oneSearchEntries=appended.length;toolResult=await callTool.execute('friend-call-search-limit',researchArgs,new AbortController().signal,undefined,ctx);assert.equal(toolResult.isError,true);assert.equal(nestedSearchCalls.length,oneSearchBefore+1);assert.equal(appended.length,oneSearchEntries);
const limitId='22222222-2222-4222-8222-222222222222',limitRounds=[1,2,3].map(round=>({...questions,consultationId:limitId,round,request:{message:`round ${round}`,purpose:'limit fixture'}}));
branch=[...limitRounds.map(data=>({type:'custom',customType:caf.CAF_ROUND_ENTRY,data})),{type:'message',id:'limit-user',message:{role:'user',content:'Continue.'}},{type:'message',id:'limit-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-limit',name:'call_friend',arguments:callArgs}]}}];await dispatch('session_tree',{type:'session_tree'});
await commands.get('caf').handler('status',ctx);assert.match(notifications.at(-1).text,/round limit reached/);const reviewsBeforeLimit=providerCalls.length,callsBeforeLimit=friendCalls.length;toolResult=await callTool.execute('friend-call-limit',callArgs,new AbortController().signal,undefined,ctx);assert.equal(toolResult.isError,true);assert.equal(toolResult.details.status,'round-limit');assert.equal(providerCalls.length,reviewsBeforeLimit);assert.equal(friendCalls.length,callsBeforeLimit);
branch=[];await dispatch('session_tree',{type:'session_tree'});
friendStopReason='toolUse';for(const content of [
  [{type:'toolCall',id:'unknown',name:'web_search',arguments:{questions:questionItems}}],
  [{type:'toolCall',id:'one',name:'caf_ask_primary',arguments:{questions:questionItems}},{type:'toolCall',id:'two',name:'caf_ask_primary',arguments:{questions:questionItems}}],
  [{type:'toolCall',id:'malformed',name:'caf_ask_primary',arguments:{questions:questionItems,extra:true}}]
]){friendContent=()=>content;await assert.rejects(caf.callCafFriendModel(ctx,available[0],callArgs.message,callArgs.purpose,'high',new AbortController().signal),/(?:question|tool) request/i);}
friendStopReason='stop';friendAnswer='Independent public advice.';friendContent=()=>[{type:'text',text:friendAnswer}];
const hangingCtx={...ctx,modelRegistry:{...ctx.modelRegistry,streamSimple:(_model,_request,options)=>(async function*(){await new Promise((_,reject)=>options.signal.addEventListener('abort',()=>reject(options.signal.reason),{once:true}));})()}};
await assert.rejects(caf.callCafFriendModel(hangingCtx,available[0],callArgs.message,callArgs.purpose,'high',new AbortController().signal,5),/timed out/);
let friendStartedResolve,friendProviderSignal;const friendStarted=new Promise(resolve=>{friendStartedResolve=resolve;});
const cancellingCtx={...ctx,modelRegistry:{...ctx.modelRegistry,streamSimple:(_model,_request,options)=>(async function*(){friendProviderSignal=options.signal;friendStartedResolve();await new Promise((_,reject)=>options.signal.addEventListener('abort',()=>reject(options.signal.reason),{once:true}));})()}};
const friendCancellation=new AbortController(),pendingFriend=caf.callCafFriendModel(cancellingCtx,available[0],callArgs.message,callArgs.purpose,'high',friendCancellation.signal);await friendStarted;friendCancellation.abort(new Error('cancelled friend fixture'));await assert.rejects(pendingFriend,/cancelled friend fixture/);assert.equal(friendProviderSignal.aborted,true);
ctx.hasUI=true;selections.push('Thinking','default');await commands.get('caf').handler('',ctx);
assert.deepEqual(await caf.loadCafConfig(commandProfile),{...valid,thinking:null});
await dispatch('session_shutdown',{type:'session_shutdown',reason:'exit'});
branch=[{type:'message',id:'shutdown-user',message:{role:'user',content:[{type:'text',text:'Use CAF.'}]}},{type:'message',id:'shutdown-assistant',message:{role:'assistant',content:[{type:'toolCall',id:'friend-call-shutdown',name:'call_friend',arguments:callArgs}]}}];
const callsAfterShutdown=friendCalls.length;toolResult=await callTool.execute('friend-call-shutdown',callArgs,new AbortController().signal,undefined,ctx);assert.equal(toolResult.isError,true);assert.equal(toolResult.details.status,'guard-unavailable');assert.equal(friendCalls.length,callsAfterShutdown);

const dockerfile=await readFile(join(root,'docker/Dockerfile'),'utf8'),launcher=await readFile(join(root,'bin/pi-run'),'utf8');
const guardian='/usr/local/lib/node_modules/guardian-agent/guardian-agent.ts',cafPath='/usr/local/lib/node_modules/guardian-agent/caf-agent.ts';
assert.ok(dockerfile.includes('COPY extensions/caf-agent.ts /usr/local/lib/node_modules/guardian-agent/'));
assert.ok(launcher.includes(`--extension ${cafPath}`));assert.ok(launcher.indexOf(guardian)<launcher.indexOf(cafPath));
console.log('reviewed CAF dialogue, one-search research, destination isolation, limits, and safety tests passed');
NODE
