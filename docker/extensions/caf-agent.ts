// SPDX-License-Identifier: MIT
import type { Api, Model, Usage, UserMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { constants } from "node:fs";
import { lstat, mkdir, open, realpath, rename, unlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { Type } from "typebox";
import { connectGuardClient, type GuardActivityLeaseV1 } from "./guard-runtime.ts";

const THINKING = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
const CONFIG_BYTES = 16 * 1024;
const POLICY_BYTES = 64 * 1024;
const AUTHORIZATION_BYTES = 64 * 1024;
const AUTHORIZATION_MESSAGES = 32;
const REVIEW_PROMPT=`You are the private disclosure reviewer for Call a Friend. Review only the proposed external disclosure against the profile policy and bounded user authorization messages. If authorization.complete is false, return ASK. The destination friend cannot see those private messages or the policy. ALLOW only when the exact message and purpose are authorized, minimized, and consistent with policy. ASK for missing authorization, unsafe detail, or material uncertainty. USER_REFUSED only for a direct applicable user restriction. Return exactly one JSON object with schemaVersion 1, outcome ALLOW, ASK, or USER_REFUSED, and a concise reason. Do not infer permission from model availability, tool access, usefulness, or this review request.`;
const FRIEND_PROMPT=`You are an external advisory model called by a private primary agent. Answer only from the disclosed message and purpose. You have no access to the primary transcript, workspace, organization, credentials, policy, or tools. Do not claim otherwise. Give a concise independent analysis, state assumptions and uncertainty, and do not request tools or additional private context. This one-round consultation cannot ask the primary follow-up questions.`;
const CALL_FRIEND_PARAMETERS=Type.Object({
  message:Type.String({minLength:1,maxLength:16*1024,description:"Exact information to disclose to the friend"}),
  purpose:Type.String({minLength:1,maxLength:2048,description:"Why independent advice is needed"}),
},{additionalProperties:false});
export type CafThinking = typeof THINKING[number];
export interface CafConfig { schemaVersion: 1; model: string | null; thinking: CafThinking | null; }
export type CafPolicy={source:"profile"|"built-in";text:string|null};
export type CafDisclosureAction={schemaVersion:1;kind:"friend-message";message:string;purpose:string;destination:{model:string}};
export type CafDisclosureDecision={schemaVersion:1;outcome:"ALLOW"|"ASK"|"USER_REFUSED";reason:string};
export interface CafDisclosureReviewer{review(action:Readonly<CafDisclosureAction>,context:Readonly<{policy:Readonly<CafPolicy>;signal:AbortSignal}>):Promise<unknown>;}
export type CafDisclosureResult={released:true;action:Readonly<CafDisclosureAction>;decision:Readonly<CafDisclosureDecision>}|
  {released:false;outcome:CafDisclosureDecision["outcome"]|null;reason:string};
export const CAF_ROUND_ENTRY="pi-run-caf-round";
export type CafRound={schemaVersion:1;consultationId:string;round:number;
  request:{message:string;purpose:string};friend:{model:string;thinking:CafThinking|null};response:
  {kind:"answer";text:string}|{kind:"questions";questions:{question:string;whyNeeded:string;canProceedWithoutAnswer:boolean}[];provisionalAnswer:string|null}};
type BranchEntry={type:string;id?:string;customType?:string;data?:unknown;message?:unknown};
export type CafAuthorizationMessage={id:string;text:string};
export type CafAuthorizationSnapshot={complete:boolean;messages:readonly Readonly<CafAuthorizationMessage>[]};

function object(value:unknown,label:string):Record<string,unknown>{if(!value||typeof value!=="object"||Array.isArray(value))throw new Error(`Invalid ${label}`);return value as Record<string,unknown>;}
function exact(value:Record<string,unknown>,keys:string[],label:string):void{if(Object.keys(value).sort().join(",")!==[...keys].sort().join(","))throw new Error(`Invalid ${label}`);}
function text(value:unknown,bytes:number,label:string):string{if(typeof value!=="string"||!value.trim()||value.includes("\0")||Buffer.byteLength(value,"utf8")>bytes)throw new Error(`Invalid ${label}`);return value;}
function freeze<T>(value:T):T{if(value&&typeof value==="object"&&!Object.isFrozen(value)){Object.freeze(value);for(const child of Object.values(value))freeze(child);}return value;}
export function parseCafRound(input:unknown):CafRound{
  const value=object(input,"CAF round");exact(value,["schemaVersion","consultationId","round","request","friend","response"],"CAF round");
  if(value.schemaVersion!==1||typeof value.consultationId!=="string"||!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value.consultationId)||
      typeof value.round!=="number"||!Number.isSafeInteger(value.round)||value.round<1||value.round>3)throw new Error("Invalid CAF round identity");
  const request=object(value.request,"CAF request");exact(request,["message","purpose"],"CAF request");
  const friend=object(value.friend,"CAF friend");exact(friend,["model","thinking"],"CAF friend");
  const model=text(friend.model,512,"CAF friend model");if(!/^[^\s/]+\/[^\s]+$/.test(model)||!(friend.thinking===null||THINKING.includes(friend.thinking as CafThinking)))throw new Error("Invalid CAF friend");
  const response=object(value.response,"CAF response"),kind=response.kind;
  let parsedResponse:CafRound["response"];
  if(kind==="answer"){
    exact(response,["kind","text"],"CAF answer");parsedResponse={kind,text:text(response.text,64*1024,"CAF answer")};
  }else if(kind==="questions"){
    exact(response,["kind","questions","provisionalAnswer"],"CAF questions");
    if(!Array.isArray(response.questions)||response.questions.length<1||response.questions.length>3||
        !(response.provisionalAnswer===null||typeof response.provisionalAnswer==="string"))throw new Error("Invalid CAF questions");
    const questions=response.questions.map((item,index)=>{const question=object(item,`CAF question ${index+1}`);exact(question,["question","whyNeeded","canProceedWithoutAnswer"],"CAF question");
      if(typeof question.canProceedWithoutAnswer!=="boolean")throw new Error("Invalid CAF question");
      return {question:text(question.question,4096,"CAF question"),whyNeeded:text(question.whyNeeded,4096,"CAF question reason"),canProceedWithoutAnswer:question.canProceedWithoutAnswer};});
    parsedResponse={kind,questions,provisionalAnswer:response.provisionalAnswer===null?null:text(response.provisionalAnswer,32*1024,"CAF provisional answer")};
  }else throw new Error("Invalid CAF response");
  return freeze({schemaVersion:1,consultationId:value.consultationId,round:Number(value.round),
    request:{message:text(request.message,16*1024,"CAF message"),purpose:text(request.purpose,2048,"CAF purpose")},
    friend:{model,thinking:friend.thinking as CafThinking|null},response:parsedResponse});
}
export function restoreCafConversation(entries:readonly BranchEntry[]):readonly CafRound[]{
  const rounds:CafRound[]=[],seen=new Set<string>();let active:string|undefined,lastRound=0;
  for(const entry of entries){if(entry.type!=="custom"||entry.customType!==CAF_ROUND_ENTRY)continue;
    if(rounds.length>=256)throw new Error("CAF conversation exceeds 256 completed rounds");
    const round=parseCafRound(entry.data);
    if(round.round===1){if(active||seen.has(round.consultationId))throw new Error("Invalid CAF consultation sequence");active=round.consultationId;lastRound=1;seen.add(round.consultationId);}
    else if(round.consultationId!==active||round.round!==lastRound+1)throw new Error("Invalid CAF consultation sequence");
    else lastRound=round.round;
    rounds.push(round);if(round.response.kind==="answer")active=undefined;
  }
  return Object.freeze(rounds);
}
export function collectCafAuthorizationMessages(entries:readonly BranchEntry[]):Readonly<CafAuthorizationSnapshot> {
  const candidates:CafAuthorizationMessage[]=[];let complete=true;
  for(const entry of entries){
    if(entry.type!=="message")continue;const value=entry.message;
    if(!value||typeof value!=="object"||Array.isArray(value)||(value as {role?:unknown}).role!=="user")continue;
    if(typeof entry.id!=="string"||!entry.id||entry.id.length>512){complete=false;continue;}
    const content=(value as {content?:unknown}).content;let body="";
    if(typeof content==="string")body=content;
    else if(Array.isArray(content)){const parts:string[]=[];for(const part of content){
      if(part&&typeof part==="object"&&(part as {type?:unknown}).type==="text"&&typeof (part as {text?:unknown}).text==="string")parts.push((part as {text:string}).text);
      else complete=false;}body=parts.join("\n");}
    else complete=false;
    if(!body.trim()||body.includes("\0")||Buffer.byteLength(body,"utf8")>16*1024){complete=false;continue;}
    candidates.push({id:entry.id,text:body});
  }
  const selected:CafAuthorizationMessage[]=[],ids=new Set<string>();let bytes=0;
  for(let index=candidates.length-1;index>=0;index--){const item=candidates[index],size=Buffer.byteLength(item.id,"utf8")+Buffer.byteLength(item.text,"utf8");
    if(ids.has(item.id)||selected.length>=AUTHORIZATION_MESSAGES||bytes+size>AUTHORIZATION_BYTES){complete=false;continue;}
    ids.add(item.id);bytes+=size;selected.push(freeze({...item}));}
  return freeze({complete,messages:Object.freeze(selected.reverse())});
}
export function parseCafDisclosureAction(input:unknown):Readonly<CafDisclosureAction>{
  const value=object(input,"CAF disclosure action");exact(value,["schemaVersion","kind","message","purpose","destination"],"CAF disclosure action");
  const destination=object(value.destination,"CAF destination");exact(destination,["model"],"CAF destination");
  const model=text(destination.model,512,"CAF destination model");
  if(value.schemaVersion!==1||value.kind!=="friend-message"||!/^[^\s/]+\/[^\s]+$/.test(model))throw new Error("Invalid CAF disclosure action");
  return freeze({schemaVersion:1,kind:"friend-message",message:text(value.message,16*1024,"CAF disclosure message"),
    purpose:text(value.purpose,2048,"CAF disclosure purpose"),destination:{model}});
}
export function parseCafDisclosureDecision(input:unknown):Readonly<CafDisclosureDecision>{
  const value=object(input,"CAF disclosure decision");exact(value,["schemaVersion","outcome","reason"],"CAF disclosure decision");
  if(value.schemaVersion!==1||!["ALLOW","ASK","USER_REFUSED"].includes(String(value.outcome)))throw new Error("Invalid CAF disclosure decision");
  return freeze({schemaVersion:1,outcome:value.outcome as CafDisclosureDecision["outcome"],reason:text(value.reason,2400,"CAF disclosure reason")});
}
export async function runCafDisclosureReview(input:unknown,policy:CafPolicy,reviewer:CafDisclosureReviewer|undefined,signal:AbortSignal,timeoutMs=15_000):Promise<CafDisclosureResult>{
  let action:Readonly<CafDisclosureAction>,safePolicy:Readonly<CafPolicy>;
  try{action=parseCafDisclosureAction(input);const validPolicy=policy?.source==="built-in"?policy.text===null:
      policy?.source==="profile"&&typeof policy.text==="string"&&!!policy.text.trim()&&Buffer.byteLength(policy.text,"utf8")<=POLICY_BYTES;
    if(!validPolicy)throw new Error("Invalid CAF policy");safePolicy=freeze({source:policy.source,text:policy.text});
    if(!Number.isSafeInteger(timeoutMs)||timeoutMs<1||timeoutMs>60_000)throw new Error("Invalid CAF review timeout");}
  catch(error){return {released:false,outcome:null,reason:message(error)};}
  if(signal.aborted)return {released:false,outcome:null,reason:message(signal.reason??new Error("CAF disclosure review cancelled"))};
  if(!reviewer)return {released:false,outcome:null,reason:"CAF disclosure reviewer unavailable"};
  const controller=new AbortController(),abort=()=>controller.abort(signal.reason??new Error("CAF disclosure review cancelled"));
  signal.addEventListener("abort",abort,{once:true});if(signal.aborted)abort();
  const timer=setTimeout(()=>controller.abort(new Error("CAF disclosure review timed out")),timeoutMs);
  try{
    const context=Object.freeze({policy:safePolicy,signal:controller.signal});
    const work=Promise.resolve().then(()=>reviewer.review(action,context));work.catch(()=>{});
    const raw=await Promise.race([work,new Promise<never>((_,reject)=>{const stop=()=>reject(controller.signal.reason);controller.signal.addEventListener("abort",stop,{once:true});if(controller.signal.aborted)stop();})]);
    const decision=parseCafDisclosureDecision(raw);
    return decision.outcome==="ALLOW"?{released:true,action,decision}:{released:false,outcome:decision.outcome,reason:decision.reason};
  }catch(error){return {released:false,outcome:null,reason:message(error)||"CAF disclosure review unavailable"};}
  finally{clearTimeout(timer);signal.removeEventListener("abort",abort);controller.abort();}
}
export function primaryCafReviewerAvailable(ctx:ExtensionContext):boolean{
  return !!ctx.model&&typeof ctx.modelRegistry.complete==="function";
}
export function createPrimaryCafDisclosureReviewer(ctx:ExtensionContext,onUsage?:(usage:Usage)=>void):CafDisclosureReviewer{
  if(!primaryCafReviewerAvailable(ctx))throw new Error("Primary CAF disclosure reviewer unavailable");
  return Object.freeze({async review(action:Readonly<CafDisclosureAction>,context:Readonly<{policy:Readonly<CafPolicy>;signal:AbortSignal}>):Promise<unknown>{
    const authorization=collectCafAuthorizationMessages(ctx.sessionManager.getBranch() as BranchEntry[]);
    const payload=JSON.stringify({disclosure:action,policy:context.policy,authorization});
    const request:UserMessage={role:"user",content:[{type:"text",text:payload}],timestamp:Date.now()};
    const response=await ctx.modelRegistry.complete(ctx.model!,{systemPrompt:REVIEW_PROMPT,messages:[request]},{signal:context.signal});
    onUsage?.(response.usage);if(response.stopReason!=="stop")throw new Error(`CAF disclosure reviewer ended with ${response.stopReason}`);
    const output=response.content.map(part=>part.type==="text"?part.text:"").filter(Boolean).join("\n");
    if(!output.trim()||Buffer.byteLength(output,"utf8")>16*1024)throw new Error("CAF disclosure reviewer returned invalid output");
    const decision=parseCafDisclosureDecision(JSON.parse(output));
    return !authorization.complete&&decision.outcome==="ALLOW"
      ? {schemaVersion:1,outcome:"ASK",reason:"Authorization evidence exceeded the private review bounds."}:decision;
  }});
}
export function runPrimaryCafDisclosureReview(input:unknown,policy:CafPolicy,ctx:ExtensionContext,signal:AbortSignal,timeoutMs=15_000,onUsage?:(usage:Usage)=>void):Promise<CafDisclosureResult>{
  let reviewer:CafDisclosureReviewer|undefined;try{reviewer=createPrimaryCafDisclosureReviewer(ctx,onUsage);}catch{/* Gate records unavailability. */}
  return runCafDisclosureReview(input,policy,reviewer,signal,timeoutMs);
}
export type CafFriendAnswer={text:string;usage:Usage};
class CafFriendCallError extends Error{constructor(message:string,readonly usage?:Usage){super(message);this.name="CafFriendCallError";}}
export async function callCafFriendModel(ctx:ExtensionContext,model:Model<Api>,messageValue:string,purposeValue:string,thinking:CafThinking|null,signal:AbortSignal,timeoutMs=120_000):Promise<CafFriendAnswer>{
  const messageText=text(messageValue,16*1024,"CAF friend message"),purpose=text(purposeValue,2048,"CAF friend purpose");
  if(!Number.isSafeInteger(timeoutMs)||timeoutMs<1||timeoutMs>300_000)throw new Error("Invalid CAF friend timeout");
  const controller=new AbortController(),abort=()=>controller.abort(signal.reason??new Error("CAF friend call cancelled"));
  signal.addEventListener("abort",abort,{once:true});if(signal.aborted)abort();
  const timer=setTimeout(()=>controller.abort(new Error("CAF friend call timed out")),timeoutMs);
  try{
    const request:UserMessage={role:"user",content:[{type:"text",text:JSON.stringify({message:messageText,purpose})}],timestamp:Date.now()};
    const stream=ctx.modelRegistry.streamSimple(model,{systemPrompt:FRIEND_PROMPT,messages:[request]},
      {signal:controller.signal,toolChoice:"none",maxTokens:8192,...(model.reasoning&&thinking?{reasoning:thinking}:{})});
    let final:any;const work=(async()=>{for await(const event of stream)if(event.type==="done")final=event.message;})();work.catch(()=>{});
    await Promise.race([work,new Promise<never>((_,reject)=>{const stop=()=>reject(controller.signal.reason);controller.signal.addEventListener("abort",stop,{once:true});if(controller.signal.aborted)stop();})]);
    if(!final||final.stopReason!=="stop")throw new CafFriendCallError(`CAF friend response ended with ${final?.stopReason??"no completed message"}`,final?.usage);
    const answer=final.content.map((part:any)=>part.type==="text"?part.text:"").filter(Boolean).join("\n");
    if(!answer.trim()||answer.includes("\0")||Buffer.byteLength(answer,"utf8")>64*1024)throw new CafFriendCallError("CAF friend returned an invalid or oversized answer",final.usage);
    return {text:answer,usage:final.usage as Usage};
  }finally{clearTimeout(timer);signal.removeEventListener("abort",abort);controller.abort();}
}
function combinedUsage(...values:(Usage|undefined)[]):Usage|undefined{
  const rows=values.filter((value):value is Usage=>!!value);if(!rows.length)return;
  const sum=(read:(value:Usage)=>number)=>rows.reduce((total,value)=>total+read(value),0),optional=(read:(value:Usage)=>number|undefined)=>rows.some(value=>read(value)!==undefined)?rows.reduce((total,value)=>total+(read(value)??0),0):undefined;
  return {input:sum(value=>value.input),output:sum(value=>value.output),cacheRead:sum(value=>value.cacheRead),cacheWrite:sum(value=>value.cacheWrite),
    ...(optional(value=>value.cacheWrite1h)===undefined?{}:{cacheWrite1h:optional(value=>value.cacheWrite1h)}),
    ...(optional(value=>value.reasoning)===undefined?{}:{reasoning:optional(value=>value.reasoning)}),totalTokens:sum(value=>value.totalTokens),
    cost:{input:sum(value=>value.cost.input),output:sum(value=>value.cost.output),cacheRead:sum(value=>value.cost.cacheRead),cacheWrite:sum(value=>value.cost.cacheWrite),total:sum(value=>value.cost.total)}};
}
function standaloneCall(ctx:ExtensionContext,toolCallId:string):boolean{
  for(const entry of [...ctx.sessionManager.getBranch()].reverse())if(entry.type==="message"&&entry.message.role==="assistant"&&Array.isArray(entry.message.content)){
    const calls=entry.message.content.filter((part:any)=>part.type==="toolCall");if(calls.some((call:any)=>call.id===toolCallId))return calls.length===1&&calls[0].name==="call_friend";
  }
  return false;
}

function message(error: unknown): string { return error instanceof Error ? error.message : String(error); }
function owned(uid: number): boolean { return typeof process.getuid !== "function" || uid === process.getuid(); }
export function defaultCafConfig(): CafConfig { return { schemaVersion: 1, model: null, thinking: null }; }
export function parseCafConfig(text: string): CafConfig {
  const parsed=JSON.parse(text) as unknown;
  if(!parsed||typeof parsed!=="object"||Array.isArray(parsed))throw new Error("Invalid CAF configuration");
  const value=parsed as Record<string,unknown>,keys=Object.keys(value).sort().join(",");
  if(keys!=="model,schemaVersion,thinking"||value.schemaVersion!==1||
      !(value.model===null||(typeof value.model==="string"&&value.model.length<=512&&/^[^\s/]+\/[^\s]+$/.test(value.model)))||
      !(value.thinking===null||THINKING.includes(value.thinking as CafThinking)))throw new Error("Invalid CAF configuration");
  return {schemaVersion:1,model:value.model as string|null,thinking:value.thinking as CafThinking|null};
}
async function cafDirectory(stateDir:string,create:boolean):Promise<string|undefined>{
  const state=resolve(stateDir),stateStat=await lstat(state),resolvedState=await realpath(state),dir=join(state,"caf");
  if(!stateStat.isDirectory()||stateStat.isSymbolicLink()||resolvedState!==state)throw new Error("CAF state directory is redirected");
  if(create)await mkdir(dir,{recursive:true,mode:0o700});
  let stat;
  try{stat=await lstat(dir);}catch(error){if(!create&&(error as NodeJS.ErrnoException).code==="ENOENT")return;throw error;}
  if(!stat.isDirectory()||stat.isSymbolicLink()||!owned(stat.uid)||(stat.mode&0o777)!==0o700||await realpath(dir)!==join(resolvedState,"caf"))
    throw new Error("CAF directory must be private, owned, and unredirected");
  return dir;
}
export async function loadCafPolicy(stateDir:string):Promise<Readonly<CafPolicy>>{
  const dir=await cafDirectory(stateDir,false);if(!dir)return freeze({source:"built-in",text:null});
  const path=join(dir,"caf.md");let file:Awaited<ReturnType<typeof open>>|undefined;
  try{
    file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);const stat=await file.stat();
    if(!stat.isFile()||stat.nlink!==1||!owned(stat.uid)||(stat.mode&0o777)!==0o600||stat.size>POLICY_BYTES)
      throw new Error("CAF policy must be a private single-link regular file");
    const data=await file.readFile();if(data.length>POLICY_BYTES||data.includes(0))throw new Error("CAF policy is invalid or too large");
    const policy=new TextDecoder("utf-8",{fatal:true}).decode(data);if(!policy.trim())throw new Error("CAF policy is empty");
    return freeze({source:"profile",text:policy});
  }catch(error){if((error as NodeJS.ErrnoException).code==="ENOENT")return freeze({source:"built-in",text:null});throw error;}
  finally{await file?.close();}
}
export async function loadCafConfig(stateDir:string):Promise<CafConfig>{
  const dir=await cafDirectory(stateDir,false);if(!dir)return defaultCafConfig();
  const path=join(dir,"config.json");let file:Awaited<ReturnType<typeof open>>|undefined;
  try{
    file=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);
    const stat=await file.stat();
    if(!stat.isFile()||stat.nlink!==1||!owned(stat.uid)||(stat.mode&0o777)!==0o600||stat.size>CONFIG_BYTES)
      throw new Error("CAF configuration must be a private single-link regular file");
    const data=await file.readFile();if(data.length>CONFIG_BYTES||data.includes(0))throw new Error("CAF configuration is invalid or too large");
    return parseCafConfig(data.toString("utf8"));
  }catch(error){if((error as NodeJS.ErrnoException).code==="ENOENT")return defaultCafConfig();throw error;}
  finally{await file?.close();}
}
export async function saveCafConfig(stateDir:string,value:CafConfig):Promise<CafConfig>{
  const config=parseCafConfig(JSON.stringify(value)),dir=(await cafDirectory(stateDir,true))!,path=join(dir,"config.json");
  try{const stat=await lstat(path);if(!stat.isFile()||stat.isSymbolicLink()||stat.nlink!==1||!owned(stat.uid)||(stat.mode&0o777)!==0o600)
    throw new Error("CAF configuration must be a private single-link regular file");}
  catch(error){if((error as NodeJS.ErrnoException).code!=="ENOENT")throw error;}
  const temporary=join(dir,`.config.json.tmp.${randomUUID()}`);let file:Awaited<ReturnType<typeof open>>|undefined;
  try{
    file=await open(temporary,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
    await file.writeFile(JSON.stringify(config)+"\n");await file.sync();await file.close();file=undefined;await rename(temporary,path);return config;
  }catch(error){await file?.close().catch(()=>{});await unlink(temporary).catch(()=>{});throw error;}
}

export default function cafAgent(pi:ExtensionAPI){
  const stateDir=resolve(process.env.PI_RUN_PROFILE_DIR||"/profile");
  const guard=connectGuardClient(pi,{schemaVersion:1,id:"caf",label:"Call a Friend"});
  let config=defaultCafConfig(),configError:string|undefined,policy:Readonly<CafPolicy>=freeze({source:"built-in",text:null}),policyError:string|undefined;
  let conversation:readonly CafRound[]=[],conversationError:string|undefined;
  const tell=(ctx:ExtensionContext,text:string,level:"info"|"warning"|"error"="info")=>ctx.ui.notify(text,level);
  const friendModel=(ctx:ExtensionContext)=>{const slash=config.model?.indexOf("/")??-1;return slash>0?ctx.modelRegistry.find(config.model!.slice(0,slash),config.model!.slice(slash+1)):undefined;};
  const conversationPending=()=>conversation.at(-1)?.response.kind==="questions";
  const restore=(ctx:ExtensionContext,announce=false)=>{try{conversation=restoreCafConversation(ctx.sessionManager.getBranch());conversationError=undefined;}
    catch(error){conversation=[];conversationError=message(error);if(announce)tell(ctx,`CAF conversation unavailable: ${conversationError}`,"warning");}};
  const persist=async(ctx:ExtensionContext,next:CafConfig)=>{try{config=await saveCafConfig(stateDir,next);configError=undefined;return true;}
    catch(error){tell(ctx,`CAF configuration was not changed: ${message(error)}`,"error");return false;}};
  const status=(ctx:ExtensionContext)=>tell(ctx,["Call a Friend",`Guard Runtime: ${guard.connected()?"available":"unavailable"}`,
    `Friend model: ${config.model??"unconfigured"}`,`Thinking: ${config.thinking??"default"}`,
    `Disclosure policy: ${policyError?`unavailable — ${policyError}`:policy.source==="profile"?"profile":"built-in only"}`,
    `Disclosure review: ${primaryCafReviewerAvailable(ctx)?"ready — primary model":"unavailable"}`,
    `Conversation: ${conversationError?`unavailable — ${conversationError}`:conversation.length?`${conversation.length} completed round(s) on this branch`:"none on this branch"}`,
    configError?`Configuration error: ${configError}`:`Friend calls: ${guard.connected()&&primaryCafReviewerAvailable(ctx)&&!!friendModel(ctx)&&!policyError&&!conversationError&&!conversationPending()?"ready":"unavailable"}`].join("\n"),configError||policyError||conversationError?"warning":"info");
  const setModel=async(value:string,ctx:ExtensionContext)=>{
    if(!value){
      if(!ctx.hasUI){tell(ctx,"Usage: /caf model <provider/model>");return;}
      const choices=ctx.modelRegistry.getAvailable().map(model=>`${model.provider}/${model.id}`).sort();
      const selected=await ctx.ui.select("CAF friend model",choices);if(selected===undefined)return;value=selected;
    }
    const slash=value.indexOf("/");
    if(slash<1||!ctx.modelRegistry.find(value.slice(0,slash),value.slice(slash+1))){tell(ctx,"CAF model is unavailable.","error");return;}
    if(await persist(ctx,{...config,model:value}))tell(ctx,`CAF friend model: ${value} (saved).`);
  };
  const setThinking=async(value:string,ctx:ExtensionContext)=>{
    value=value.toLowerCase();
    if(!value){
      if(!ctx.hasUI){tell(ctx,"Usage: /caf thinking <default|off|minimal|low|medium|high|xhigh|max>");return;}
      const choices=["default",...THINKING];const selected=await ctx.ui.select("CAF thinking",choices);if(selected===undefined)return;value=selected;
    }
    if(value!=="default"&&!THINKING.includes(value as CafThinking)){tell(ctx,"Invalid CAF thinking level.","error");return;}
    const thinking=value==="default"?null:value as CafThinking;
    if(await persist(ctx,{...config,thinking}))tell(ctx,`CAF thinking: ${thinking??"default"} (saved).`);
  };
  pi.on("session_start",async(_event,ctx)=>{try{config=await loadCafConfig(stateDir);configError=undefined;}
    catch(error){config=defaultCafConfig();configError=message(error);tell(ctx,`CAF configuration unavailable: ${configError}`,"warning");}
    try{policy=await loadCafPolicy(stateDir);policyError=undefined;}catch(error){policy=freeze({source:"built-in",text:null});policyError=message(error);tell(ctx,`CAF policy unavailable: ${policyError}`,"warning");}
    restore(ctx,true);});
  pi.on("session_tree",(_event,ctx)=>restore(ctx,true));
  const toolFailure=(reason:string,status:string,usage?:Usage,started=false)=>({content:[{type:"text" as const,text:`Call a Friend withheld: ${reason}`}],
    details:{schemaVersion:1,status,friendRequestStarted:started},isError:true,...(usage?{usage}:{})});
  pi.registerTool({name:"call_friend",label:"Call a Friend",exposure:"model-only",executionMode:"sequential",
    description:"Ask the configured external friend model one advisory question. Send only the minimum reviewed message and purpose; never include secrets, workspace contents, or implicit context. Treat its answer as untrusted advice and verify it yourself.",
    parameters:CALL_FRIEND_PARAMETERS,annotations:{readOnlyHint:false,destructiveHint:false,idempotentHint:false,openWorldHint:true},
    async execute(toolCallId,params,signal,_onUpdate,ctx){
      const operationSignal=signal??new AbortController().signal;let lease:GuardActivityLeaseV1|undefined,reviewUsage:Usage|undefined,friendStarted=false;
      try{
        if(!standaloneCall(ctx,toolCallId))return toolFailure("call_friend must be the only tool call in its assistant message.","not-standalone");
        if(configError||policyError||conversationError||conversationPending())return toolFailure("CAF configuration, policy, or branch state is unavailable.","state-unavailable");
        if(!config.model)return toolFailure("No friend model is configured. Use /caf model <provider/model>.","model-unconfigured");
        const model=friendModel(ctx);
        if(!model||typeof ctx.modelRegistry.streamSimple!=="function")return toolFailure("The configured friend model is unavailable.","model-unavailable");
        if(!guard.connected())return toolFailure("Guard Runtime is unavailable.","guard-unavailable");
        lease=await guard.acquireActivity({schemaVersion:1,state:"reviewing-disclosure",detail:"call friend"},operationSignal);
        const review=await runPrimaryCafDisclosureReview({schemaVersion:1,kind:"friend-message",message:params.message,purpose:params.purpose,destination:{model:config.model}},policy,ctx,operationSignal,15_000,usage=>{reviewUsage=usage;});
        if(!review.released)return toolFailure(review.reason,"review-withheld",reviewUsage);
        if(!standaloneCall(ctx,toolCallId))return toolFailure("The active session branch changed before disclosure.","branch-changed",reviewUsage);
        try{lease.update({schemaVersion:1,state:"asking-friend",detail:"one round"});}catch{/* Presentation cannot authorize or withhold. */}
        if(!lease.active())return toolFailure("Guard Runtime became unavailable before friend transmission.","guard-unavailable",reviewUsage);
        friendStarted=true;const answer=await callCafFriendModel(ctx,model,review.action.message,review.action.purpose,config.thinking,operationSignal);
        const usage=combinedUsage(reviewUsage,answer.usage),consultationId=randomUUID();
        const round=parseCafRound({schemaVersion:1,consultationId,round:1,request:{message:review.action.message,purpose:review.action.purpose},
          friend:{model:config.model,thinking:config.thinking},response:{kind:"answer",text:answer.text}});
        try{pi.appendEntry(CAF_ROUND_ENTRY,round);conversation=Object.freeze([...conversation,round]);}
        catch(error){return toolFailure(`The friend answered, but the finalized round could not be retained (${message(error)}). Do not retry automatically.`,"persistence-failed",usage,true);}
        return {content:[{type:"text" as const,text:answer.text}],details:{schemaVersion:1,status:"answered",consultationId,round:1,model:config.model},...(usage?{usage}:{})};
      }catch(error){const reason=message(error),usage=combinedUsage(reviewUsage,error instanceof CafFriendCallError?error.usage:undefined);return toolFailure(friendStarted?`${reason} The friend request may have reached its provider; do not retry automatically.`:reason,
        friendStarted?"friend-unavailable":"review-unavailable",usage,friendStarted);}
      finally{lease?.end();}
    }});
  pi.registerCommand("caf",{description:"Configure Call a Friend",handler:async(args,ctx)=>{
    const [action="",...rest]=args.trim().split(/\s+/),value=rest.join(" ");
    if(action==="status"){status(ctx);return;}if(action==="model"){await setModel(value,ctx);return;}if(action==="thinking"){await setThinking(value,ctx);return;}
    if(action){tell(ctx,"Usage: /caf [status|model <provider/model>|thinking <level>]","error");return;}
    if(!ctx.hasUI){status(ctx);return;}
    const selected=await ctx.ui.select("Call a Friend",["Status","Model","Thinking","Close"]);
    if(selected==="Status")status(ctx);else if(selected==="Model")await setModel("",ctx);else if(selected==="Thinking")await setThinking("",ctx);
  }});
}
