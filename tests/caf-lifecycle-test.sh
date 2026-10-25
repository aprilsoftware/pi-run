#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'caf-lifecycle-test: Pi package unavailable' >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { chmod, mkdir, readdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [root,piDir,tmp]=process.argv.slice(2),profile=join(tmp,'profile');
await mkdir(join(profile,'caf'),{recursive:true,mode:0o700});await chmod(profile,0o700);await chmod(join(profile,'caf'),0o700);
await writeFile(join(profile,'caf','caf.md'),'# CAF policy\nAllow only user-authorized abstract public design questions.\n',{mode:0o600});
await writeFile(join(profile,'caf','config.json'),JSON.stringify({schemaVersion:1,model:'friend/frontier',thinking:'high'})+'\n',{mode:0o600});
await writeFile(join(profile,'web-search.json'),JSON.stringify({searchProvider:'brave'})+'\n',{mode:0o600});
process.env.PI_RUN_PROFILE_DIR=profile;process.env.PI_CODING_AGENT_DIR=profile;
const {loadExtensions}=await import(pathToFileURL(join(piDir,'dist/core/extensions/loader.js')).href);
const {ExtensionRunner}=await import(pathToFileURL(join(piDir,'dist/core/extensions/runner.js')).href);
const {SessionManager}=await import(pathToFileURL(join(piDir,'dist/core/session-manager.js')).href);
const journal=await import(pathToFileURL(join(root,'docker/extensions/guard-journal.ts')).href);
const runtimeFile=join(root,'docker/extensions/guard-runtime.ts'),cafFile=join(root,'docker/extensions/caf-agent.ts');
const usage={input:3,output:2,cacheRead:0,cacheWrite:0,totalTokens:5,cost:{input:0.03,output:0.04,cacheRead:0,cacheWrite:0,total:0.07}};
const primary={provider:'local',id:'primary',api:'openai-completions'},friend={provider:'friend',id:'frontier',api:'openai-completions',reasoning:true};
const question={question:'Is downtime acceptable?',whyNeeded:'It determines the migration pattern.',canProceedWithoutAnswer:false};
const friendResponses=[
  {stopReason:'toolUse',content:[{type:'toolCall',id:'ask-1',name:'caf_ask_primary',arguments:{questions:[question]}}]},
  {stopReason:'stop',content:[{type:'text',text:'Use expand-and-contract because downtime is forbidden.'}]},
  {stopReason:'toolUse',content:[{type:'toolCall',id:'search-1',name:'caf_web_search',arguments:{query:'public expand contract migration guidance',purpose:'Find independent public evidence'}}]},
  {stopReason:'stop',content:[{type:'text',text:'Public guidance supports staged migration [1].'}]},
];
const reviews=[],friendCalls=[],nestedCalls=[],notifications=[],statuses=new Map();let hangReview=false,reviewEnteredResolve,hangSearch=false,searchEnteredResolve;
const registry={getAvailable:()=>[primary,friend],find:(provider,id)=>[primary,friend].find(model=>model.provider===provider&&model.id===id),
  complete:async(model,request,options)=>{reviews.push({model,request,options});if(hangReview){reviewEnteredResolve(options.signal);return new Promise((_,reject)=>options.signal.addEventListener('abort',()=>reject(options.signal.reason),{once:true}));}return{role:'assistant',api:model.api,provider:model.provider,model:model.id,stopReason:'stop',timestamp:Date.now(),usage,content:[{type:'text',text:JSON.stringify({schemaVersion:1,outcome:'ALLOW',reason:'The exact abstract disclosure is user-authorized.'})}]};},
  streamSimple:(model,request,options)=>{friendCalls.push({model,request,options});const response=friendResponses.shift();assert.ok(response,'unexpected friend request');return(async function*(){if(response.hang){response.enter(options.signal);await new Promise((_,reject)=>options.signal.addEventListener('abort',()=>reject(options.signal.reason),{once:true}));return;}yield{type:'done',reason:response.stopReason,message:{role:'assistant',api:model.api,provider:model.provider,model:model.id,stopReason:response.stopReason,timestamp:Date.now(),usage,content:response.content}};})();}};
const session=SessionManager.inMemory(root),activeTools=['call_friend','web_search'];
const assistantUsage={...usage};
function appendCall(id,args,userText){session.appendMessage({role:'user',content:userText,timestamp:Date.now()});session.appendMessage({role:'assistant',api:primary.api,provider:primary.provider,model:primary.id,
  stopReason:'toolUse',timestamp:Date.now(),usage:assistantUsage,content:[{type:'toolCall',id,name:'call_friend',arguments:args}]});}
async function createRunner(){
  const loaded=await loadExtensions([runtimeFile,cafFile],root);assert.deepEqual(loaded.errors,[]);assert.equal(loaded.extensions.length,2);
  const runner=new ExtensionRunner(loaded.extensions,loaded.runtime,root,session,registry);
  runner.bindCore({getActiveTools:()=>activeTools,setActiveTools:names=>{activeTools.splice(0,activeTools.length,...names);},appendEntry:(type,data)=>session.appendCustomEntry(type,data),sendMessage(){},sendUserMessage(){}},{
    getModel:()=>primary,getScopedModels:()=>[],isIdle:()=>true,isProjectTrusted:()=>true,getSignal:()=>undefined,abort(){},hasPendingMessages:()=>false,shutdown(){},getContextUsage:()=>undefined,compact(){},getSystemPrompt:()=>'',
    getCallableTools:()=>[{name:'web_search',description:'Fake canonical web search',parameters:{type:'object'},execute:async()=>({content:[],details:{}})}],
    executeTool:async(callerId,name,args,options)=>{assert.equal(name,'web_search');nestedCalls.push({callerId,name,args,options});if(hangSearch){searchEnteredResolve(options.signal);return new Promise((_,reject)=>options.signal.addEventListener('abort',()=>reject(options.signal.reason),{once:true}));}return{toolCall:{type:'toolCall',id:`${callerId}/1`,name,arguments:args},isError:false,result:{isError:false,content:[{type:'text',text:'bounded fake search'}],details:{},usage,
      structuredContent:{responseId:'fake',fetchId:null,queries:[{query:args.query,answer:'Public provider summary.',error:null,provider:'brave',results:[{title:'Migration guide',url:'https://example.com/migration',snippet:'Use staged schema evolution.'}]}]}}};},
  });
  runner.setUIContext({notify:(text,level)=>notifications.push({text,level}),setStatus:(key,value)=>statuses.set(key,value),setWidget(){},select:async()=>undefined,confirm:async()=>false,input:async()=>undefined,theme:{fg:(_role,text)=>text}},'json');
  await runner.emit({type:'session_start',reason:'startup'});return{loaded,runner,caf:loaded.extensions[1]};
}
const first=await createRunner(),callTool=first.caf.tools.get('call_friend').definition;
assert.equal(callTool.exposure,'model-only');assert.equal(callTool.executionMode,'sequential');assert.equal(first.runner.getToolDefinition('call_friend'),callTool);
const firstArgs={message:'Assess an abstract migration design.',purpose:'Independent architecture review'};appendCall('call-question',firstArgs,'You may consult the configured friend about this abstract migration design.');
let result=await callTool.execute('call-question',firstArgs,new AbortController().signal,undefined,first.runner.createToolContext('call-question',undefined));
assert.equal(result.details.status,'questions');assert.match(result.content[0].text,/Is downtime acceptable/);const questionLeaf=session.getLeafId();
const continuationArgs={message:'Downtime is forbidden.',purpose:'Answer the friend question'};appendCall('call-continuation',continuationArgs,'You may disclose that downtime is forbidden.');
result=await callTool.execute('call-continuation',continuationArgs,new AbortController().signal,undefined,first.runner.createToolContext('call-continuation',undefined));
assert.equal(result.details.status,'answer');assert.equal(result.details.round,2);const answerLeaf=session.getLeafId();
session.branch(questionLeaf);await first.runner.emit({type:'session_tree'});await first.caf.commands.get('caf').handler('status',first.runner.createCommandContext());assert.match(notifications.at(-1).text,/awaiting primary/);
session.branch(answerLeaf);await first.runner.emit({type:'session_tree'});await first.caf.commands.get('caf').handler('status',first.runner.createCommandContext());assert.doesNotMatch(notifications.at(-1).text,/awaiting primary/);
const researchArgs={message:'Compare public staged migration guidance.',purpose:'Find source-linked independent advice'};appendCall('call-research',researchArgs,'You may use one public search for this abstract migration question.');
result=await callTool.execute('call-research',researchArgs,new AbortController().signal,undefined,first.runner.createToolContext('call-research',undefined));
assert.equal(result.details.research,true);assert.match(result.content[0].text,/https:\/\/example.com\/migration/);assert.equal(nestedCalls.length,1);assert.deepEqual(nestedCalls[0].args,{query:'public expand contract migration guidance',provider:'brave',numResults:5,includeContent:false,workflow:'none'});
assert.equal(friendCalls.length,4);assert.equal(reviews.length,4);assert.deepEqual(JSON.parse(reviews.at(-1).request.messages[0].content[0].text).disclosure.destination,{tool:'web_search',provider:'brave'});
const rounds=session.getBranch().filter(entry=>entry.type==='custom'&&entry.customType==='pi-run-caf-round');assert.equal(rounds.length,3);assert.equal(rounds.at(-1).data.research.provider,'brave');
const modelContext=JSON.stringify(session.buildSessionContext().messages);assert.ok(!modelContext.includes('Public provider summary.'));assert.ok(!modelContext.includes('Use staged schema evolution.'));assert.ok(!modelContext.includes('Public guidance supports staged migration'));
let entered=new Promise(resolve=>{reviewEnteredResolve=resolve;});hangReview=true;appendCall('call-cancel-review',firstArgs,'Cancel the review fixture.');let controller=new AbortController(),pending=callTool.execute('call-cancel-review',firstArgs,controller.signal,undefined,first.runner.createToolContext('call-cancel-review',controller.signal)),providerSignal=await entered;controller.abort(new Error('cancel review'));result=await pending;assert.equal(result.isError,true);assert.equal(providerSignal.aborted,true);hangReview=false;
entered=new Promise(resolve=>{friendResponses.push({hang:true,enter:resolve});});appendCall('call-cancel-friend',firstArgs,'Cancel the friend fixture.');controller=new AbortController();pending=callTool.execute('call-cancel-friend',firstArgs,controller.signal,undefined,first.runner.createToolContext('call-cancel-friend',controller.signal));providerSignal=await entered;controller.abort(new Error('cancel friend'));result=await pending;assert.equal(result.isError,true);assert.equal(providerSignal.aborted,true);
entered=new Promise(resolve=>{searchEnteredResolve=resolve;});hangSearch=true;friendResponses.push({stopReason:'toolUse',content:[{type:'toolCall',id:'search-cancel',name:'caf_web_search',arguments:{query:'cancelled public query',purpose:'Cancellation fixture'}}]});appendCall('call-cancel-search',researchArgs,'Cancel the search fixture.');controller=new AbortController();pending=callTool.execute('call-cancel-search',researchArgs,controller.signal,undefined,first.runner.createToolContext('call-cancel-search',controller.signal));providerSignal=await entered;controller.abort(new Error('cancel search'));result=await pending;assert.equal(result.isError,true);assert.equal(providerSignal.aborted,true);hangSearch=false;
assert.equal(session.getBranch().filter(entry=>entry.type==='custom'&&entry.customType==='pi-run-caf-round').length,3);
await first.caf.commands.get('caf-log').handler('',first.runner.createCommandContext());assert.match(notifications.at(-1).text,/operation_finished/);
await first.runner.emit({type:'session_shutdown',reason:'exit'});const firstSnapshot=await journal.readGuardJournal({schemaVersion:1,stateDir:profile,clientId:'caf',maxRecords:500});assert.ok(firstSnapshot.records.some(record=>record.value.event==='search_completed'));
const journalText=JSON.stringify(firstSnapshot.records.map(record=>record.value));assert.ok(firstSnapshot.records.filter(record=>record.value.event==='operation_finished'&&record.value.outcome==='cancelled').length>=3);for(const secret of [firstArgs.message,continuationArgs.message,researchArgs.message,'public expand contract migration guidance','cancelled public query','Public provider summary.','Use staged schema evolution.'])assert.ok(!journalText.includes(secret));
const completedBefore=(await readdir(join(profile,'logs','caf','runs'))).filter(name=>name.endsWith('.complete'));assert.equal(completedBefore.length,1);
const resumed=await createRunner();await resumed.caf.commands.get('caf').handler('status',resumed.runner.createCommandContext());assert.match(notifications.at(-1).text,/3 finalized round/);
await resumed.runner.emit({type:'session_shutdown',reason:'exit'});const files=await readdir(join(profile,'logs','caf','runs')),completed=files.filter(name=>name.endsWith('.complete'));assert.equal(completed.length,2);assert.equal(new Set(completed.map(name=>name.split('.')[0])).size,2);
assert.equal(friendResponses.length,0);console.log('native Pi CAF lifecycle, branching, nested search, context isolation, resume, and journals passed');
NODE
