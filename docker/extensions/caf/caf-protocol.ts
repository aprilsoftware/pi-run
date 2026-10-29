// SPDX-License-Identifier: MIT

export const THINKING = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
export const POLICY_BYTES = 64 * 1024;
export const AUTHORIZATION_BYTES = 64 * 1024;
export const AUTHORIZATION_MESSAGES = 32;
export const RESEARCH_BYTES = 48 * 1024;
export const CAF_RESPONSE_BYTES = 64 * 1024;
export const CAF_MAX_ROUNDS = 256;
export const CAF_RESEARCH_STATE_BYTES = 512 * 1024;

export type CafThinking = typeof THINKING[number];
export interface CafConfig { schemaVersion: 1; model: string | null; thinking: CafThinking | null; }
export type CafPolicy={source:"profile"|"built-in";text:string|null};
export type CafDisclosureHistoryRound={request:{message:string;purpose:string};response:CafRound["response"];research?:readonly Readonly<CafResearch>[]};
export type CafDisclosureAction={schemaVersion:1;kind:"friend-message";message:string;purpose:string;destination:{model:string};history?:readonly Readonly<CafDisclosureHistoryRound>[]};
export type CafWebSearchAction={schemaVersion:1;kind:"web-search";query:string;purpose:string;destination:{tool:"web_search";provider:string}};
export type CafReviewAction=CafDisclosureAction|CafWebSearchAction;
export type CafDisclosureDecision={schemaVersion:1;outcome:"ALLOW"|"ASK"|"USER_REFUSED";reason:string};
export interface CafDisclosureReviewer{review(action:Readonly<CafReviewAction>,context:Readonly<{policy:Readonly<CafPolicy>;signal:AbortSignal}>):Promise<unknown>;}
export type CafReviewResult<T extends CafReviewAction>={released:true;action:Readonly<T>;decision:Readonly<CafDisclosureDecision>}|
  {released:false;outcome:CafDisclosureDecision["outcome"]|null;reason:string};
export type CafDisclosureResult=CafReviewResult<CafDisclosureAction>;
export type CafWebSearchReviewResult=CafReviewResult<CafWebSearchAction>;
export const CAF_ROUND_ENTRY="pi-run-caf-round";
export type CafResearch={kind:"web-search";query:string;purpose:string;provider:string;answer:string;results:{title:string;url:string;snippet:string}[]};
export type CafRound={schemaVersion:1;consultationId:string;round:number;
  request:{message:string;purpose:string};friend:{model:string;thinking:CafThinking|null};response:
  {kind:"answer";text:string}|{kind:"questions";questions:{question:string;whyNeeded:string;canProceedWithoutAnswer:boolean}[];provisionalAnswer:string|null};research?:readonly Readonly<CafResearch>[]};
export type BranchEntry={type:string;id?:string;customType?:string;data?:unknown;message?:unknown};
export type CafAuthorizationMessage={id:string;text:string};
export type CafAuthorizationSnapshot={complete:boolean;messages:readonly Readonly<CafAuthorizationMessage>[]};

export function object(value:unknown,label:string):Record<string,unknown>{if(!value||typeof value!=="object"||Array.isArray(value))throw new Error(`Invalid ${label}`);return value as Record<string,unknown>;}
export function exact(value:Record<string,unknown>,keys:string[],label:string):void{if(Object.keys(value).sort().join(",")!==[...keys].sort().join(","))throw new Error(`Invalid ${label}`);}
export function text(value:unknown,bytes:number,label:string):string{if(typeof value!=="string"||!value.trim()||value.includes("\0")||Buffer.byteLength(value,"utf8")>bytes)throw new Error(`Invalid ${label}`);return value;}
export function bounded(value:unknown,bytes:number,label:string):string{if(typeof value!=="string"||value.includes("\0")||Buffer.byteLength(value,"utf8")>bytes)throw new Error(`Invalid ${label}`);return value;}
export function freeze<T>(value:T):T{if(value&&typeof value==="object"&&!Object.isFrozen(value)){Object.freeze(value);for(const child of Object.values(value))freeze(child);}return value;}
export function provider(value:unknown,label:string):string{const parsed=text(value,64,label);if(!/^[a-z0-9][a-z0-9-]{0,63}$/.test(parsed)||["auto","all"].includes(parsed))throw new Error(`Invalid ${label}`);return parsed;}
export function publicUrl(value:unknown):string{const raw=text(value,2048,"CAF research URL");let parsed:URL;try{parsed=new URL(raw);}catch{throw new Error("Invalid CAF research URL");}
  if(!["http:","https:"].includes(parsed.protocol)||parsed.username||parsed.password||!parsed.hostname)throw new Error("Invalid CAF research URL");return parsed.href;}
export function parseCafResearch(input:unknown):CafResearch{
  const value=object(input,"CAF research");exact(value,["kind","query","purpose","provider","answer","results"],"CAF research");
  if(value.kind!=="web-search"||!Array.isArray(value.results)||value.results.length>5)throw new Error("Invalid CAF research");
  const results=value.results.map((item,index)=>{const row=object(item,`CAF research result ${index+1}`);exact(row,["title","url","snippet"],"CAF research result");
    return {title:text(row.title,1024,"CAF research title"),url:publicUrl(row.url),snippet:bounded(row.snippet,4096,"CAF research snippet")};});
  const result:CafResearch={kind:"web-search",query:text(value.query,2048,"CAF research query"),purpose:text(value.purpose,2048,"CAF research purpose"),provider:provider(value.provider,"CAF research provider"),
    answer:bounded(value.answer,16*1024,"CAF research answer"),results};
  if(!result.answer.trim()&&!result.results.length||Buffer.byteLength(JSON.stringify(result),"utf8")>RESEARCH_BYTES)throw new Error("Invalid or oversized CAF research");return result;
}
export function parseCafResearchState(input:unknown):readonly Readonly<CafResearch>[] {
  const values=Array.isArray(input)?input:[input];if(!values.length)throw new Error("Invalid CAF research state");
  const research=values.map(parseCafResearch);if(Buffer.byteLength(JSON.stringify(research),"utf8")>CAF_RESEARCH_STATE_BYTES)throw new Error("CAF research state exceeds the cumulative byte limit");return freeze(research);
}
export function parseCafResponse(input:unknown):CafRound["response"]{
  const response=object(input,"CAF response"),kind=response.kind;
  if(kind==="answer"){exact(response,["kind","text"],"CAF answer");return {kind,text:text(response.text,64*1024,"CAF answer")};}
  if(kind!=="questions")throw new Error("Invalid CAF response");
  exact(response,["kind","questions","provisionalAnswer"],"CAF questions");
  if(!Array.isArray(response.questions)||response.questions.length<1||
      !(response.provisionalAnswer===null||typeof response.provisionalAnswer==="string"))throw new Error("Invalid CAF questions");
  const questions=response.questions.map((item,index)=>{const question=object(item,`CAF question ${index+1}`);exact(question,["question","whyNeeded","canProceedWithoutAnswer"],"CAF question");
    if(typeof question.canProceedWithoutAnswer!=="boolean")throw new Error("Invalid CAF question");
    return {question:text(question.question,4096,"CAF question"),whyNeeded:text(question.whyNeeded,4096,"CAF question reason"),canProceedWithoutAnswer:question.canProceedWithoutAnswer};});
  const result={kind,questions,provisionalAnswer:response.provisionalAnswer===null?null:text(response.provisionalAnswer,32*1024,"CAF provisional answer")};
  if(Buffer.byteLength(JSON.stringify(result),"utf8")>CAF_RESPONSE_BYTES)throw new Error("CAF questions exceed the response byte limit");return result;
}
export function parseCafRound(input:unknown):CafRound{
  const value=object(input,"CAF round"),hasResearch=Object.hasOwn(value,"research");exact(value,["schemaVersion","consultationId","round","request","friend","response",...(hasResearch?["research"]:[])],"CAF round");
  if(value.schemaVersion!==1||typeof value.consultationId!=="string"||!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value.consultationId)||
      typeof value.round!=="number"||!Number.isSafeInteger(value.round)||value.round<1||value.round>CAF_MAX_ROUNDS)throw new Error("Invalid CAF round identity");
  const request=object(value.request,"CAF request");exact(request,["message","purpose"],"CAF request");
  const friend=object(value.friend,"CAF friend");exact(friend,["model","thinking"],"CAF friend");
  const model=text(friend.model,512,"CAF friend model");if(!/^[^\s/]+\/[^\s]+$/.test(model)||!(friend.thinking===null||THINKING.includes(friend.thinking as CafThinking)))throw new Error("Invalid CAF friend");
  const parsedResponse=parseCafResponse(value.response),research=hasResearch?parseCafResearchState(value.research):undefined;
  return freeze({schemaVersion:1,consultationId:value.consultationId,round:Number(value.round),
    request:{message:text(request.message,16*1024,"CAF message"),purpose:text(request.purpose,2048,"CAF purpose")},
    friend:{model,thinking:friend.thinking as CafThinking|null},response:parsedResponse,...(research?{research}:{})});
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
  const value=object(input,"CAF disclosure action"),hasHistory=Object.hasOwn(value,"history");
  exact(value,["schemaVersion","kind","message","purpose","destination",...(hasHistory?["history"]:[])],"CAF disclosure action");
  const destination=object(value.destination,"CAF destination");exact(destination,["model"],"CAF destination");
  const model=text(destination.model,512,"CAF destination model");
  if(value.schemaVersion!==1||value.kind!=="friend-message"||!/^[^\s/]+\/[^\s]+$/.test(model))throw new Error("Invalid CAF disclosure action");
  let history:Readonly<CafDisclosureHistoryRound>[]|undefined;
  if(hasHistory){if(!Array.isArray(value.history)||value.history.length<1||value.history.length>=CAF_MAX_ROUNDS)throw new Error("Invalid CAF disclosure history");let researchBytes=0;
    history=value.history.map((item,index)=>{const row=object(item,`CAF disclosure history ${index+1}`),hasResearch=Object.hasOwn(row,"research");exact(row,["request","response",...(hasResearch?["research"]:[])],"CAF disclosure history");
      const request=object(row.request,"CAF disclosure history request");exact(request,["message","purpose"],"CAF disclosure history request");const research=hasResearch?parseCafResearchState(row.research):undefined;
      if(research)researchBytes+=Buffer.byteLength(JSON.stringify(research),"utf8");if(researchBytes>CAF_RESEARCH_STATE_BYTES)throw new Error("CAF disclosure history research exceeds the cumulative byte limit");
      return freeze({request:{message:text(request.message,16*1024,"CAF disclosure history message"),purpose:text(request.purpose,2048,"CAF disclosure history purpose")},response:parseCafResponse(row.response),...(research?{research}:{})});});}
  return freeze({schemaVersion:1,kind:"friend-message",message:text(value.message,16*1024,"CAF disclosure message"),
    purpose:text(value.purpose,2048,"CAF disclosure purpose"),destination:{model},...(history?{history}:{})});
}
export function parseCafWebSearchAction(input:unknown):Readonly<CafWebSearchAction>{
  const value=object(input,"CAF web-search action");exact(value,["schemaVersion","kind","query","purpose","destination"],"CAF web-search action");
  const destination=object(value.destination,"CAF web-search destination");exact(destination,["tool","provider"],"CAF web-search destination");
  if(value.schemaVersion!==1||value.kind!=="web-search"||destination.tool!=="web_search")throw new Error("Invalid CAF web-search action");
  return freeze({schemaVersion:1,kind:"web-search",query:text(value.query,2048,"CAF web-search query"),purpose:text(value.purpose,2048,"CAF web-search purpose"),
    destination:{tool:"web_search",provider:provider(destination.provider,"CAF web-search provider")}});
}
export function parseCafDisclosureDecision(input:unknown):Readonly<CafDisclosureDecision>{
  const value=object(input,"CAF disclosure decision");exact(value,["schemaVersion","outcome","reason"],"CAF disclosure decision");
  if(value.schemaVersion!==1||!["ALLOW","ASK","USER_REFUSED"].includes(String(value.outcome)))throw new Error("Invalid CAF disclosure decision");
  return freeze({schemaVersion:1,outcome:value.outcome as CafDisclosureDecision["outcome"],reason:text(value.reason,2400,"CAF disclosure reason")});
}
export function message(error: unknown): string { return error instanceof Error ? error.message : String(error); }
async function runCafReview<T extends CafReviewAction>(input:unknown,parse:(value:unknown)=>Readonly<T>,policy:CafPolicy,reviewer:CafDisclosureReviewer|undefined,signal:AbortSignal,timeoutMs:number):Promise<CafReviewResult<T>>{
  let action:Readonly<T>,safePolicy:Readonly<CafPolicy>;
  try{action=parse(input);const validPolicy=policy?.source==="built-in"?policy.text===null:
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
export function runCafDisclosureReview(input:unknown,policy:CafPolicy,reviewer:CafDisclosureReviewer|undefined,signal:AbortSignal,timeoutMs=15_000):Promise<CafDisclosureResult>{
  return runCafReview(input,parseCafDisclosureAction,policy,reviewer,signal,timeoutMs);
}
export function runCafWebSearchReview(input:unknown,policy:CafPolicy,reviewer:CafDisclosureReviewer|undefined,signal:AbortSignal,timeoutMs=15_000):Promise<CafWebSearchReviewResult>{
  return runCafReview(input,parseCafWebSearchAction,policy,reviewer,signal,timeoutMs);
}
