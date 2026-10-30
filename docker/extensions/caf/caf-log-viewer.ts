// SPDX-License-Identifier: MIT
import { createHash } from "node:crypto";
import { join } from "node:path";
import type { GuardViewRequestV1 } from "../guard/guard-runtime.ts";
import { readWorkspaceGuardJournal, type WorkspaceGuardJournalRecord } from "../guard/guard-journal.ts";

const CAF_LOG_VIEW_RECORDS = 30_000;
export interface CafLogOperation{
  key:string;operationId:string;sessionId:string;timestamp:string;events:readonly Readonly<WorkspaceGuardJournalRecord>[];partial:boolean;searchText:string;
}
type CafLogSummary={outcome:string;destination:string;kind:string;reviewPath:string;friendStarted:boolean|null;research:boolean|null;durationMs:number|null;totalTokens:number|null};
export function cafViewText(value:unknown,maximum=160):string|undefined{
  if(typeof value!=="string"&&typeof value!=="number"&&typeof value!=="boolean")return;
  return String(value).replace(/[\u0000-\u001f\u007f]/g," ").trim().slice(0,maximum)||undefined;
}
function cafNumber(value:unknown):number|null{return typeof value==="number"&&Number.isFinite(value)&&value>=0?value:null;}
function cafEvent(value:Record<string,unknown>):string{return cafViewText(value.event,96)??"unknown-event";}
function cafEventUsage(value:Record<string,unknown>):Record<string,unknown>{return value.usage&&typeof value.usage==="object"&&!Array.isArray(value.usage)?value.usage as Record<string,unknown>:{};}
function cafLogLine(value:Record<string,unknown>,recordedTimestamp?:string|null):string{
  const timestamp=cafLogStamp(recordedTimestamp),event=cafEvent(value),usage=cafEventUsage(value),fields:string[]=[];
  for(const [key,item] of [["outcome",value.outcome],["kind",value.kind],["model",value.model],["provider",value.provider],["results",value.results],
    ["answerBytes",value.answerBytes],["durationMs",value.durationMs],["reviewPath",value.reviewPath],["friendRequestStarted",value.friendRequestStarted],
    ["research",value.research],["round",value.round],["guardEvent",value.guardEvent],["level",value.level],["totalTokens",usage.totalTokens]] as [string,unknown][]){
    const safe=cafViewText(item);if(safe!==undefined)fields.push(`${key}=${safe}`);
  }
  return `${timestamp} ${event}${fields.length?` · ${fields.join(" · ")}`:""}`;
}
function cafOperationSummary(operation:CafLogOperation):CafLogSummary{
  const values=operation.events.map(record=>record.value),finished=[...values].reverse().find(value=>cafEvent(value)==="operation_finished");
  const last=(key:string)=>{for(let index=values.length-1;index>=0;index--){const value=cafViewText(values[index][key]);if(value!==undefined)return value;}return "";};
  const usage=finished?cafEventUsage(finished):{},outcome=finished?cafViewText(finished.outcome,96)??"unknown":"partial";
  const model=last("model"),provider=last("provider"),kind=last("kind");
  return {outcome,destination:model||provider||"destination unavailable",kind,reviewPath:finished?cafViewText(finished.reviewPath,96)??"unknown":"unknown",
    friendStarted:finished&&typeof finished.friendRequestStarted==="boolean"?finished.friendRequestStarted:null,
    research:finished&&typeof finished.research==="boolean"?finished.research:null,durationMs:finished?cafNumber(finished.durationMs):null,totalTokens:cafNumber(usage.totalTokens)};
}
function cafOutcomeLabel(value:string):string{
  if(value==="answer")return "Answered";if(value==="questions")return "Questions";if(value==="partial")return "Partial";
  return value.split("-").map(part=>part?part[0].toUpperCase()+part.slice(1):part).join(" ");
}
function cafLogStamp(value:string|null|undefined):string{const time=Date.parse(value??"");if(!Number.isFinite(time))return "Time not recorded";const iso=new Date(time).toISOString();return `${iso.slice(0,10)} ${iso.slice(11,19)} UTC`;}
function cafLogDuration(value:number|null):string{if(value===null)return "—";if(value<1000)return `${Math.round(value)} ms`;if(value<60_000)return `${(value/1000).toFixed(1)} s`;return `${(value/60_000).toFixed(1)} min`;}
export function groupCafLogRecords(records:readonly Readonly<WorkspaceGuardJournalRecord>[]):CafLogOperation[]{
  const grouped=new Map<string,{operationId:string;sessionId:string;events:Readonly<WorkspaceGuardJournalRecord>[]}>();
  for(const record of records){const rawOperationId=record.value.operationId;if(typeof rawOperationId!=="string"||!rawOperationId.trim()||rawOperationId.length>128||/[\u0000-\u001f\u007f]/.test(rawOperationId))continue;
    const operationId=rawOperationId.trim(),sessionId=cafViewText(record.sessionId,128)??"unknown-session",identity=JSON.stringify([sessionId,operationId]);
    let group=grouped.get(identity);if(!group){group={operationId,sessionId,events:[]};grouped.set(identity,group);}group.events.push(record);}
  return [...grouped.entries()].map(([identity,group])=>{
    const events=[...group.events].sort((left,right)=>(Date.parse(left.timestamp??"")||0)-(Date.parse(right.timestamp??"")||0)||(left.sequence??0)-(right.sequence??0));
    const started=events.find(record=>cafEvent(record.value)==="operation_started"),finished=[...events].reverse().find(record=>cafEvent(record.value)==="operation_finished");
    const timestamp=started?.timestamp??events[0]?.timestamp??new Date(0).toISOString(),partial=!started||!finished;
    const shell:CafLogOperation={key:createHash("sha256").update(identity).digest("hex"),operationId:group.operationId,sessionId:group.sessionId,timestamp,
      events:Object.freeze(events),partial,searchText:""};
    const summary=cafOperationSummary(shell),search=[summary.outcome,cafOutcomeLabel(summary.outcome),summary.destination,summary.kind,summary.reviewPath,
      ...events.map(record=>cafLogLine(record.value,record.timestamp)),group.operationId].join(" ").toLocaleLowerCase();
    return Object.freeze({...shell,searchText:search});
  }).sort((left,right)=>(Date.parse(right.timestamp)||0)-(Date.parse(left.timestamp)||0)||right.key.localeCompare(left.key));
}
export function cafLogDetail(operation:CafLogOperation,sectionId:string):readonly string[]{
  if(sectionId==="timeline")return ["Times UTC · recorded diagnostics only; journal order is preserved.","",...operation.events.map(record=>cafLogLine(record.value,record.timestamp)),"",`Operation: ${operation.operationId}`,`Session: ${operation.sessionId}`];
  const summary=cafOperationSummary(operation),lines=["Call a Friend operation","",`Time: ${cafLogStamp(operation.timestamp)}`,`Outcome: ${cafOutcomeLabel(summary.outcome)}`,
    `Destination: ${summary.destination}`,`Response kind: ${summary.kind||"not recorded"}`,`Review path: ${summary.reviewPath}`,
    `Friend request started: ${summary.friendStarted===null?"not recorded":summary.friendStarted?"yes":"no"}`,
    `Public research: ${summary.research===null?"not recorded":summary.research?"yes":"no"}`,`Duration: ${cafLogDuration(summary.durationMs)}`,
    `Total tokens: ${summary.totalTokens??"not recorded"}`,`Journal state: ${operation.partial?"partial":"complete"}`,"",`Operation: ${operation.operationId}`,`Session: ${operation.sessionId}`];
  return lines;
}
async function flushCafLogView(flush:()=>Promise<void>,signal:AbortSignal):Promise<void>{
  signal.throwIfAborted();let timer:ReturnType<typeof setTimeout>|undefined;const task=flush();task.catch(()=>{});
  let rejectAbort:(reason?:unknown)=>void=()=>{};const abort=()=>rejectAbort(signal.reason);
  try{await Promise.race([task,new Promise<void>(resolve=>{timer=setTimeout(resolve,500);}),new Promise<never>((_resolve,reject)=>{rejectAbort=reject;signal.addEventListener("abort",abort,{once:true});if(signal.aborted)abort();})]);signal.throwIfAborted();}
  finally{if(timer)clearTimeout(timer);signal.removeEventListener("abort",abort);}
}
export function createCafLogViewRequest(stateDir:string,workspaceId:string,flush:()=>Promise<void>,initialQuery=""):GuardViewRequestV1{
  let operations:readonly CafLogOperation[]=[];
  return {schemaVersion:1,title:"Call a Friend operations · current workspace · UTC",compactTitle:"Call a Friend operations",
    wideHeader:"  UTC date/time             Outcome          Duration  Destination",initialQuery:cafViewText(initialQuery,300)??"",
    fallbackText:`CAF journal: ${join(stateDir,"logs",workspaceId,"caf.jsonl")} (viewer requires Pi's terminal UI).`,
    unavailableText:"CAF log viewer needs Pi's custom terminal UI.",emptyText:"No Call a Friend operations in this workspace.",noMatchesText:"No CAF operations match this search.",
    missingSelectionText:"Selected CAF operation is no longer available.",incompleteNoticeText:"operation list may be incomplete",
    sections:[{id:"summary",label:"Summary"},{id:"timeline",label:"Timeline"}],
    async load(signal){await flushCafLogView(flush,signal);const snapshot=await readWorkspaceGuardJournal({schemaVersion:2,stateDir,workspaceId,kind:"caf",maxRecords:CAF_LOG_VIEW_RECORDS},signal);
      operations=groupCafLogRecords(snapshot.records);return {schemaVersion:1,loadedAt:snapshot.loadedAt,notices:snapshot.notices,rows:operations.map(operation=>{const summary=cafOperationSummary(operation),suffix=operation.partial?" [partial]":"";
        return {id:operation.key,searchText:operation.searchText,wide:`${cafLogStamp(operation.timestamp)}  ${cafOutcomeLabel(summary.outcome).padEnd(16)} ${cafLogDuration(summary.durationMs).padStart(8)}  ${summary.destination}${suffix}`,
          compact:`${cafLogStamp(operation.timestamp)} ${cafOutcomeLabel(summary.outcome)} · ${summary.destination}${suffix}`};})};},
    details(rowId,sectionId){const operation=operations.find(candidate=>candidate.key===rowId);return operation?cafLogDetail(operation,sectionId):["Selected CAF operation no longer retained. Esc returns to the list."];},
  };
}
