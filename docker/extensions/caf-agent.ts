// SPDX-License-Identifier: MIT
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { constants } from "node:fs";
import { lstat, mkdir, open, realpath, rename, unlink } from "node:fs/promises";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { connectGuardClient } from "./guard-runtime.ts";

const THINKING = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
const CONFIG_BYTES = 16 * 1024;
export type CafThinking = typeof THINKING[number];
export interface CafConfig { schemaVersion: 1; model: string | null; thinking: CafThinking | null; }
export const CAF_ROUND_ENTRY="pi-run-caf-round";
export type CafRound={schemaVersion:1;consultationId:string;round:number;
  request:{message:string;purpose:string};friend:{model:string;thinking:CafThinking};response:
  {kind:"answer";text:string}|{kind:"questions";questions:{question:string;whyNeeded:string;canProceedWithoutAnswer:boolean}[];provisionalAnswer:string|null}};
type BranchEntry={type:string;customType?:string;data?:unknown};

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
  const model=text(friend.model,512,"CAF friend model");if(!/^[^\s/]+\/[^\s]+$/.test(model)||!THINKING.includes(friend.thinking as CafThinking))throw new Error("Invalid CAF friend");
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
    friend:{model,thinking:friend.thinking as CafThinking},response:parsedResponse});
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
    throw new Error("CAF configuration directory must be private, owned, and unredirected");
  return dir;
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
  let config=defaultCafConfig(),configError:string|undefined,conversation:readonly CafRound[]=[],conversationError:string|undefined;
  const tell=(ctx:ExtensionContext,text:string,level:"info"|"warning"|"error"="info")=>ctx.ui.notify(text,level);
  const restore=(ctx:ExtensionContext,announce=false)=>{try{conversation=restoreCafConversation(ctx.sessionManager.getBranch());conversationError=undefined;}
    catch(error){conversation=[];conversationError=message(error);if(announce)tell(ctx,`CAF conversation unavailable: ${conversationError}`,"warning");}};
  const persist=async(ctx:ExtensionContext,next:CafConfig)=>{try{config=await saveCafConfig(stateDir,next);configError=undefined;return true;}
    catch(error){tell(ctx,`CAF configuration was not changed: ${message(error)}`,"error");return false;}};
  const status=(ctx:ExtensionContext)=>tell(ctx,["Call a Friend · not enabled",`Guard Runtime: ${guard.connected()?"available":"unavailable"}`,
    `Friend model: ${config.model??"unconfigured"}`,`Thinking: ${config.thinking??"default"}`,
    `Conversation: ${conversationError?`unavailable — ${conversationError}`:conversation.length?`${conversation.length} completed round(s) on this branch`:"none on this branch"}`,
    configError?`Configuration error: ${configError}`:"Friend calls: not enabled in this version"].join("\n"),configError||conversationError?"warning":"info");
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
    catch(error){config=defaultCafConfig();configError=message(error);tell(ctx,`CAF configuration unavailable: ${configError}`,"warning");}restore(ctx,true);});
  pi.on("session_tree",(_event,ctx)=>restore(ctx,true));
  pi.registerCommand("caf",{description:"Configure Call a Friend (friend calls are not enabled yet)",handler:async(args,ctx)=>{
    const [action="",...rest]=args.trim().split(/\s+/),value=rest.join(" ");
    if(action==="status"){status(ctx);return;}if(action==="model"){await setModel(value,ctx);return;}if(action==="thinking"){await setThinking(value,ctx);return;}
    if(action){tell(ctx,"Usage: /caf [status|model <provider/model>|thinking <level>]","error");return;}
    if(!ctx.hasUI){status(ctx);return;}
    const selected=await ctx.ui.select("Call a Friend",["Status","Model","Thinking","Close"]);
    if(selected==="Status")status(ctx);else if(selected==="Model")await setModel("",ctx);else if(selected==="Thinking")await setThinking("",ctx);
  }});
}
