// SPDX-License-Identifier: MIT

/** Guardian — Pi-native, evidence-led review.
 * Runtime: Node 22+, loaded by Pi's extension loader. No second SDK install.
 * Profile policy and preferences live under the profile's guardian directory.
 * The private reviewer uses Pi's Agent, not a second unrestricted coding session.
 * Review trigger: only acting-agent tool calls named exactly bash or run.
 * Other tools stay outside normal review; a dispute allows bounded reads and its justification handoff only.
 * Private evidence reads/searches remain available within a command review.
 * All reviewer filesystem tools are local, bounded, and read-only. This is not a sandbox.
 */
import type { ExtensionAPI, ExtensionContext, ToolCallEvent } from "@earendil-works/pi-coding-agent";
import type { Api, Model } from "@earendil-works/pi-ai";
import { Text } from "@earendil-works/pi-tui";
import { connectGuardClient, connectGuardReviewClient, type GuardActivityLeaseV1, type GuardActivityRequestV1,
  type GuardReviewDiagnosticSnapshotV1, type GuardReviewResultV1 } from "../guard/guard-runtime.ts";
import { createSessionGuardJournalWriter, guardJournalWorkspaceId } from "../guard/guard-journal.ts";
import { LOG_BACKUPS, MAX_LOG_BYTES, ReviewTimeoutError, ReviewTrace, abortable, actionPreview, createLogger, errorText, guardianDiagnosticReference, oneLine, reviewFailureSummary, toolResultDetails, validBudget, visible } from "./guardian-review-trace.ts";
export { ReviewTimeoutError, ReviewTrace, createLogger, reviewFailureSummary } from "./guardian-review-trace.ts";
import { LEVELS, ConversationStore, PiAgentReviewer, createPiReviewerBinding, decisionExplanation, freeze, plain, prepareReview, resolveProvider, reviewServices, textArg, validateReviewResult, within, type Decision, type GuardianConfig, type GuardianConfigPatch, type GuardianReviewer, type Json, type ReviewDecision, type ReviewerBinding, type ReviewerControl, type ReviewerFactory, type ReviewerHost, type ReviewRequest, type ReviewResult, type ReviewServices, type Stats, type Thinking } from "./guardian-reviewer.ts";
export { ConversationStore, EvidenceGap, PiAgentReviewer, createPiReviewerBinding, normalizeDecision, resolveInstructionReferences, validateReviewResult } from "./guardian-reviewer.ts";
export type { GuardianConfig, GuardianConfigPatch, GuardianReviewer, InstructionReference, PiReviewerOptions, ReviewDecision, ReviewMetrics, ReviewRequest, ReviewResult, ReviewServices, ReviewerBinding, ReviewerControl, ReviewerFactory, ReviewerHost, Thinking } from "./guardian-reviewer.ts";
import { createGuardianLogViewRequest } from "./guardian-log-viewer.ts";
export { createGuardianLogViewRequest, groupGuardianLogs, guardianLogDetail, parseGuardianLogChunks, readGuardianLogs,
  summarizeGuardianLog, GUARDIAN_LOG_TABS } from "./guardian-log-viewer.ts";
export type { GuardianLogEntry, GuardianLogReview, GuardianLogSnapshot, GuardianLogSummary, GuardianLogTab } from "./guardian-log-viewer.ts";
import { AgenticGuardReviewer, adoptLegacyGuardReviewerConfig, defaultGuardReviewerConfig, effectiveAgenticThinking, loadGuardReviewerConfig,
  registerAgenticGuardReviewDomain,
  type AgenticEvidenceDefinition, type AgenticGuardBackendContext, type AgenticGuardBackendRequest,
  type AgenticGuardReviewerSelection, type AgenticReviewDomain, type GuardReviewerConfig, type PiInfrastructure, type ProviderStream,
} from "../guard/guard-reviewer-agent.ts";
import { EVIDENCE_GUIDES, EvidenceBudgetError, EvidenceService, HistoryIndex, loadEvidenceInstruction, loadNestedEvidenceInstructions,
  type EvidenceLogLevel as LogLevel, type EvidenceOperation, type EvidenceRequest, type EvidenceStep, type LogSink,
  type ReviewInstruction, type ReviewMessage, type SourceExcerpt } from "../guard/guard-evidence.ts";
export { EvidenceBudgetError, EvidenceService, HistoryIndex } from "../guard/guard-evidence.ts";
export type { EvidenceOperation, LogSink, ReviewInstruction, ReviewMessage, SourceExcerpt } from "../guard/guard-evidence.ts";
export { loadPiInfrastructure } from "../guard/guard-reviewer-agent.ts";
export type { NativeAgentLike, PiInfrastructure, ProviderStream } from "../guard/guard-reviewer-agent.ts";
import { constants } from "node:fs";
import { open, realpath, mkdir, lstat, rename, unlink } from "node:fs/promises";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { randomUUID } from "node:crypto";

const PREPARATION_TIMEOUT_MS = 15_000;
const MAX_FILE_BYTES = 256 * 1024;
const MAX_CONTEXT_BYTES = 96 * 1024;
const JUSTIFICATION_TOOL="guardian_justify";
type GuardianJustification={position:"retract"|"narrow"|"contest";explanation:string;evidence?:string[]};
const JustificationSchema={type:"object",additionalProperties:false,required:["position","explanation"],properties:{
  position:{type:"string",enum:["retract","narrow","contest"]},
  explanation:{type:"string",minLength:1,maxLength:4000,pattern:"\\S"},
  evidence:{type:"array",maxItems:8,items:{type:"string",minLength:1,maxLength:500,pattern:"\\S"}},
}} as any;
type GuardianAssessment={status:"completed";outcome:ReviewDecision["outcome"];reason:string;basis?:ReviewDecision["basis"]}|{status:"unavailable";error:string};
type JustificationResolution="retracted"|"narrowed"|"accepted"|"human-required";
type JustificationDetails={schemaVersion:1;disputeId:string;guardianReason:string;justification:GuardianJustification;assessment?:GuardianAssessment;
  resolution:JustificationResolution;executed:false;humanRequired:boolean};
type ActionRef = { toolName: string; toolCallId: string; reviewId?: string };
type Trace = { emit: LogSink; disposition: "pending" | "released" | "withheld"; releasedAt?: number; basis?: string; decision?: Decision; stats?: Stats; reviewerId?: string };

function normalizedJustification(value:unknown):GuardianJustification|undefined{
  if(!value||typeof value!=="object"||Array.isArray(value))return;
  const raw=value as Record<string,unknown>,keys=Object.keys(raw);
  if(keys.some(k=>!["position","explanation","evidence"].includes(k))||
    !["retract","narrow","contest"].includes(String(raw.position))||typeof raw.explanation!=="string"||
    !raw.explanation.trim()||raw.explanation.length>4000)return;
  if(raw.evidence!==undefined&&(!Array.isArray(raw.evidence)||raw.evidence.length>8||
    raw.evidence.some(v=>typeof v!=="string"||!v.trim()||v.length>500)))return;
  return {position:raw.position as GuardianJustification["position"],explanation:raw.explanation,
    ...(raw.evidence===undefined?{}:{evidence:[...new Set(raw.evidence as string[])]})};
}
function normalizedDisputeAction(value:unknown):ReviewRequest["action"]|undefined{
  if(!value||typeof value!=="object"||Array.isArray(value))return;
  const raw=value as Record<string,unknown>;
  if(typeof raw.toolName!=="string"||!raw.toolName||raw.toolName.length>128||typeof raw.toolCallId!=="string"||
    !raw.toolCallId||raw.toolCallId.length>512||typeof raw.cwd!=="string"||!raw.cwd||raw.cwd.length>4096||
    !raw.input||typeof raw.input!=="object"||Array.isArray(raw.input))return;
  try{if(Buffer.byteLength(JSON.stringify(raw.input))>MAX_CONTEXT_BYTES)return;}
  catch{return;}
  return {toolName:raw.toolName,toolCallId:raw.toolCallId,input:structuredClone(raw.input as Json),cwd:raw.cwd};
}
function normalizedAssessment(value:unknown):GuardianAssessment|undefined{
  if(!value||typeof value!=="object"||Array.isArray(value))return;
  const raw=value as Record<string,unknown>;
  if(raw.status==="unavailable"&&typeof raw.error==="string"&&raw.error.length<=1000)return {status:"unavailable",error:raw.error};
  if(raw.status!=="completed"||!["ALLOW","ASK","USER_REFUSED"].includes(String(raw.outcome))||
    typeof raw.reason!=="string"||!raw.reason.trim()||raw.reason.length>2400)return;
  const bases=["standing_rules","explicit_authorization","covered_work","missing_authorization","uncertainty","user_refusal"];
  if(raw.basis!==undefined&&!bases.includes(String(raw.basis)))return;
  return {status:"completed",outcome:raw.outcome as ReviewDecision["outcome"],reason:raw.reason,
    ...(raw.basis===undefined?{}:{basis:raw.basis as ReviewDecision["basis"]})};
}
function clip(text: string, limit: number): string { if (text.length <= limit) return text; const mark = "\n[excerpt: original remains retrievable]\n"; const n = Math.max(0, Math.floor((limit-mark.length)/2)); return text.slice(0,n)+mark+text.slice(-n); }
async function readText(path: string, signal?: AbortSignal, maxBytes=MAX_FILE_BYTES): Promise<string> {
  signal?.throwIfAborted();
  const f=await open(path,constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);
  try {
    const st=await f.stat(); if(!st.isFile() || st.nlink !== 1 || st.size>maxBytes)throw new Error(`Not a regular file within ${maxBytes} bytes: ${path}`);
    const b=Buffer.alloc(maxBytes+1); let n=0;
    while(n<b.length){signal?.throwIfAborted();const r=await f.read(b,n,b.length-n,null);if(!r.bytesRead)break;n+=r.bytesRead;}
    if(n>maxBytes)throw new Error("File grew beyond read limit");
    const text=b.subarray(0,n).toString("utf8");if(text.includes("\0"))throw new Error("Binary file not supported");signal?.throwIfAborted();return text;
  } finally {await f.close();}
}

const GUARDIAN_CONFIG_BYTES = 16 * 1024;
export function defaultGuardianConfig(): GuardianConfig {
  return { schemaVersion: 2, model: null, thinking: null };
}
export function parseGuardianConfig(text: string): GuardianConfig {
  const value=plain(JSON.parse(text)),keys=Object.keys(value).sort().join(",");
  const current=value.schemaVersion===2&&keys==="model,schemaVersion,thinking";
  const legacy=value.schemaVersion===1&&keys==="mode,model,schemaVersion,thinking"&&["on","off"].includes(value.mode as string);
  if((!current&&!legacy)||
    !(value.model===null||(typeof value.model==="string"&&value.model.length<=512&&/^[^\s/]+\/[^\s]+$/.test(value.model)))||
    !(value.thinking===null||LEVELS.includes(value.thinking as Thinking)))throw new Error("Invalid Guardian configuration");
  return {schemaVersion:2,model:value.model as string|null,thinking:value.thinking as Thinking|null};
}
export async function loadGuardianConfig(stateDir: string): Promise<GuardianConfig> {
  const resolvedState=await realpath(stateDir),dir=join(stateDir,"guardian");
  if(await realpath(dir)!==join(resolvedState,"guardian"))throw new Error("Guardian configuration directory is redirected");
  return parseGuardianConfig(await readText(join(dir,"config.json"),undefined,GUARDIAN_CONFIG_BYTES));
}
export async function saveGuardianConfig(stateDir: string, config: GuardianConfig): Promise<void> {
  const validated=parseGuardianConfig(JSON.stringify(config));
  const resolvedState=await realpath(stateDir),dir=join(stateDir,"guardian"),path=join(dir,"config.json");
  await mkdir(dir,{recursive:true,mode:0o700});
  if(await realpath(dir)!==join(resolvedState,"guardian"))throw new Error("Guardian configuration directory is redirected");
  try{const st=await lstat(path);if(!st.isFile()||st.nlink!==1)throw new Error("Guardian configuration must be a single-link regular file");}
  catch(e){if((e as NodeJS.ErrnoException).code!=="ENOENT")throw e;}
  const temporary=join(dir,`.config.json.tmp.${randomUUID()}`);
  let file:Awaited<ReturnType<typeof open>>|undefined;
  try{
    file=await open(temporary,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);
    await file.writeFile(JSON.stringify(validated)+"\n","utf8");await file.sync();await file.chmod(0o600);await file.close();file=undefined;
    await rename(temporary,path);
  }catch(e){if(file)await file.close().catch(()=>{});await unlink(temporary).catch(()=>{});throw e;}
}

export type GuardianDefaultMode="on"|"off";
export interface GuardianModeConfig{schemaVersion:1;defaultMode:GuardianDefaultMode;}
export function parseGuardianModeConfig(value:string):GuardianModeConfig{const row=plain(JSON.parse(value));
  if(Object.keys(row).sort().join(",")!=="defaultMode,schemaVersion"||row.schemaVersion!==1||!['on','off'].includes(String(row.defaultMode)))throw new Error("Invalid Guardian mode configuration");
  return {schemaVersion:1,defaultMode:row.defaultMode as GuardianDefaultMode};}
async function guardianModeDirectory(stateDir:string,create:boolean):Promise<string>{
  const state=resolve(stateDir),stateStat=await lstat(state),resolvedState=await realpath(state),directory=join(state,"guardian");
  if(!stateStat.isDirectory()||stateStat.isSymbolicLink()||resolvedState!==state)throw new Error("Guardian state directory is redirected");
  if(create)await mkdir(directory,{recursive:true,mode:0o700});
  const stat=await lstat(directory);if(!stat.isDirectory()||stat.isSymbolicLink()||(stat.mode&0o777)!==0o700||
    (typeof process.getuid==="function"&&stat.uid!==process.getuid())||await realpath(directory)!==join(resolvedState,"guardian"))throw new Error("Guardian mode directory must be private, owned, and unredirected");
  return directory;
}
export async function loadGuardianModeConfig(stateDir:string):Promise<GuardianModeConfig>{
  let directory:string;try{directory=await guardianModeDirectory(stateDir,false);}catch(error){if((error as NodeJS.ErrnoException).code==="ENOENT")return {schemaVersion:1,defaultMode:"off"};throw error;}
  let file:Awaited<ReturnType<typeof open>>|undefined;try{file=await open(join(directory,"mode.json"),constants.O_RDONLY|constants.O_NOFOLLOW|constants.O_NONBLOCK);const stat=await file.stat();
    if(!stat.isFile()||stat.nlink!==1||(stat.mode&0o777)!==0o600||(typeof process.getuid==="function"&&stat.uid!==process.getuid())||stat.size>1024)throw new Error("Guardian mode configuration must be a private single-link regular file");
    const data=await file.readFile();if(data.length>1024||data.includes(0))throw new Error("Invalid Guardian mode configuration");return parseGuardianModeConfig(data.toString("utf8"));
  }catch(error){if((error as NodeJS.ErrnoException).code==="ENOENT")return {schemaVersion:1,defaultMode:"off"};throw error;}finally{await file?.close();}
}
export async function saveGuardianModeConfig(stateDir:string,value:GuardianModeConfig):Promise<void>{
  const config=parseGuardianModeConfig(JSON.stringify(value)),directory=await guardianModeDirectory(stateDir,true),path=join(directory,"mode.json");
  try{const stat=await lstat(path);if(!stat.isFile()||stat.isSymbolicLink()||stat.nlink!==1||(stat.mode&0o777)!==0o600||(typeof process.getuid==="function"&&stat.uid!==process.getuid()))throw new Error("Guardian mode configuration must be a private single-link regular file");}
  catch(error){if((error as NodeJS.ErrnoException).code!=="ENOENT")throw error;}
  const temporary=join(directory,`.mode.json.tmp.${randomUUID()}`);let file:Awaited<ReturnType<typeof open>>|undefined;
  try{file=await open(temporary,constants.O_WRONLY|constants.O_CREAT|constants.O_EXCL|constants.O_NOFOLLOW,0o600);await file.writeFile(JSON.stringify(config)+"\n");await file.sync();await file.close();file=undefined;await rename(temporary,path);}
  catch(error){await file?.close().catch(()=>{});await unlink(temporary).catch(()=>{});throw error;}
}

// ============================================================================
// 3. Shared input/evidence preparation and runtime contract validation.
// ============================================================================
// These are coordination instructions, not another approval gate. Runtime settings
// stay in the user interface rather than being advertised in the acting model's prompt.



// The source cache avoids reserializing thousands of unchanged Pi session entries.
// It never caches decisions. Branch membership comes from getBranch() each time.
const ACTOR_HANDOFF=`Follow the user's authorized task and development checkpoints. If Guardian challenges an invocation, that invocation did not execute. You may use only the bounded read-only file access Guardian permits to check your position. Do not retry, rewrite, split, or route around the action; do not use effectful tools. After inspection, call guardian_justify exactly once with whether you retract, narrow, or contest, a concise explanation, and any evidence references. Retraction withdraws the action; narrowing withdraws the original and subjects any replacement to normal review; a contest accepted by Guardian permits one exact retry. Continue automatically only when the guardian_justify result says the challenge is resolved. If disagreement remains, stop for human feedback. Historical tool errors and your previous refusals do not override later user instructions. Verify uncertain prior effects before repeating consequential operations.`;




/** Exactly which acting-agent tool names enter command review.
 * This is a scope boundary, not an executable allowlist or a safety decision.
 * Do not infer coverage from arguments, descriptions, or a shell-looking alias.
 */
export const GUARDED_COMMAND_TOOLS: readonly string[] = Object.freeze(["bash", "run"]);
export function isGuardedCommandTool(toolName: string): boolean {
  return GUARDED_COMMAND_TOOLS.includes(toolName);
}

const GUARDIAN_MODE_ENTRY="guardian-mode";
const GUARDIAN_DISPUTE_ENTRY="guardian-dispute";
const MAX_DISPUTE_READS=6;
type GuardianSessionMode="on"|"off";
type DisputePhase="investigating"|"awaiting-user";
type GuardianDispute={id:string;reason:string;phase:DisputePhase;reads:number;justification?:GuardianJustification;
  action?:ReviewRequest["action"];originalOutcome?:ReviewDecision["outcome"];assessment?:GuardianAssessment};
type GuardianRetryPermit={disputeId:string;action:ReviewRequest["action"];revision:number;sessionId:string;cwd:string};
function canonicalJson(value:unknown):string{
  if(Array.isArray(value))return `[${value.map(canonicalJson).join(",")}]`;
  if(value&&typeof value==="object"){const row=value as Record<string,unknown>;return `{${Object.keys(row).sort().map(key=>`${JSON.stringify(key)}:${canonicalJson(row[key])}`).join(",")}}`;}
  return JSON.stringify(value)??"null";
}
function actionCwd(ctx:ExtensionContext,input:Json):string{const supplied=input.cwd;return typeof supplied==="string"?resolve(ctx.cwd,supplied):ctx.cwd;}
function assessmentLabel(assessment:GuardianAssessment):string{
  if(assessment.status==="unavailable")return "Assessment unavailable";
  return assessment.outcome==="ALLOW"?"Concern resolved":assessment.outcome==="ASK"?"Concern remains":"User restriction remains";
}
function justificationPanel(details:JustificationDetails):string{
  const lines=[details.humanRequired?"Guardian dispute — awaiting human judgment":"Guardian challenge resolved","Nothing was executed.","",`Guardian concern: ${visible(details.guardianReason)}`,
    "",`Agent position: ${details.justification.position}`,visible(details.justification.explanation)];
  if(details.justification.evidence?.length)lines.push("","Evidence references:",...details.justification.evidence.map(v=>`- ${visible(v)}`));
  if(details.assessment)lines.push("",`Guardian assessment: ${assessmentLabel(details.assessment)}`,
    visible(details.assessment.status==="completed"?details.assessment.reason:details.assessment.error));
  const resolution=details.resolution==="retracted"?"The primary retracted the command. It remains cancelled and work may continue without human arbitration.":
    details.resolution==="narrowed"?"The primary withdrew the original command. Any narrower replacement receives normal Guardian review.":
    details.resolution==="accepted"?"Guardian accepted the position. The exact command may be proposed once more without another review; any change receives fresh review.":
    "The primary and Guardian have not agreed. Human judgment is required.";
  lines.push("",resolution);return lines.join("\n");
}
function restoredGuardianMode(ctx:ExtensionContext,profileDefault:GuardianDefaultMode):{mode:GuardianSessionMode;source:"profile-default"|"legacy-default"|"session"}{
  const entries=ctx.sessionManager.getEntries();let mode:GuardianSessionMode=entries.length?"off":profileDefault,source:"profile-default"|"legacy-default"|"session"=entries.length?"legacy-default":"profile-default";
  for(const entry of entries)if(entry.type==="custom"&&entry.customType===GUARDIAN_MODE_ENTRY){
    const candidate=(entry.data as {mode?:unknown}|undefined)?.mode;
    if(candidate==="on"||candidate==="off"){mode=candidate;source="session";}
  }
  return {mode,source};
}
function restoredGuardianDispute(ctx:ExtensionContext):GuardianDispute|undefined{
  let current:GuardianDispute|undefined;
  for(const entry of ctx.sessionManager.getBranch())if(entry.type==="custom"&&entry.customType===GUARDIAN_DISPUTE_ENTRY){
    const data=entry.data as Record<string,unknown>|undefined;
    if(data?.schemaVersion!==1||!['open','resolved'].includes(String(data.state)))continue;
    if(data.state==="resolved"){current=undefined;continue;}
    if(typeof data.id!=="string"||!data.id||data.id.length>128||typeof data.reason!=="string"||data.reason.length>4096||
      !['investigating','awaiting-user'].includes(String(data.phase))||typeof data.reads!=="number"||
      !Number.isSafeInteger(data.reads)||data.reads<0||data.reads>MAX_DISPUTE_READS)continue;
    const justification=data.justification===undefined?undefined:normalizedJustification(data.justification);
    const action=data.action===undefined?undefined:normalizedDisputeAction(data.action);
    const assessment=data.assessment===undefined?undefined:normalizedAssessment(data.assessment);
    if((data.justification!==undefined&&!justification)||(data.action!==undefined&&!action)||(data.assessment!==undefined&&!assessment)||
      (data.originalOutcome!==undefined&&!["ALLOW","ASK","USER_REFUSED"].includes(String(data.originalOutcome))))continue;
    current={id:data.id,reason:data.reason,phase:data.phase as DisputePhase,reads:data.reads,...(justification?{justification}:{}),
      ...(action?{action}:{}),...(data.originalOutcome?{originalOutcome:data.originalOutcome as ReviewDecision["outcome"]}:{}),...(assessment?{assessment}:{})};
  }
  return current;
}

export function createGuardianExtension(factory: ReviewerFactory = createPiReviewerBinding) {
  return function guardian(pi: ExtensionAPI) {
    const stateDir = resolve(process.env.PI_RUN_PROFILE_DIR || "/profile");
    const guardConnection = connectGuardClient(pi, { schemaVersion: 1, id: "guardian", label: "Guardian", reviewerControl: true });
    const guardReviewConnection = connectGuardReviewClient(pi, { schemaVersion: 1, id: "guardian", label: "Guardian",
      evidenceProfile: "guardian-command.v1", decisionContract: "guardian-decision.v1" });
    let revision = 0, statusOwner = 0, last: Stats | undefined;
    let dispute:GuardianDispute|undefined,retryPermit:GuardianRetryPermit|undefined;
    const store = new ConversationStore();
    let config:GuardReviewerConfig = defaultGuardReviewerConfig(), configNeedsWrite = true;
    let enabled = false,modeRecorded=false,defaultMode:GuardianDefaultMode="off",defaultModeError:string|undefined,displayState = "Off", displayDetail = ""; // Never inferred from model output.
    // Guard Runtime owns the dialog lifecycle; Guardian supplies only journal semantics.
    function closeLogViewer(): void { guardConnection.closeView(); }
    let logUI:ExtensionContext|undefined,logger:ReturnType<typeof createLogger>|undefined,journalError:string|undefined;
    const warnLog=(message:string)=>{if(logUI)logUI.ui.notify(visible(message),"warning");else console.error(visible(message));};
    const journalScope=(ctx:ExtensionContext)=>({workspaceId:guardJournalWorkspaceId(stateDir,ctx.sessionManager.getSessionDir()),sessionId:ctx.sessionManager.getSessionId()});
    async function selectLogger(ctx:ExtensionContext):Promise<void>{
      const scope=journalScope(ctx);if(logger?.workspaceId===scope.workspaceId&&logger.sessionId===scope.sessionId)return;
      await logger?.close();logger=createLogger(stateDir,scope.workspaceId,scope.sessionId,warnLog);journalError=undefined;
    }
    async function logsCommand(args:string,ctx:ExtensionContext):Promise<void>{
      pinSessionMode(ctx);
      try{const scope=journalScope(ctx),active=logger?.workspaceId===scope.workspaceId&&logger.sessionId===scope.sessionId?logger:undefined;
        await guardConnection.openView(createGuardianLogViewRequest(stateDir,scope.workspaceId,()=>active?.flush()??Promise.resolve(),args.trim().slice(0,300)));}
      catch(e){ctx.ui.notify(oneLine(`Cannot open guardian log: ${errorText(e)}`,240),"warning");}
    }
    let sequence = 0;
    function sink(ctx: ExtensionContext, action?: ActionRef): LogSink {
      logUI=ctx;let active:ReturnType<typeof createLogger>|undefined;
      try{const scope=journalScope(ctx);if(logger?.workspaceId===scope.workspaceId&&logger.sessionId===scope.sessionId)active=logger;}
      catch(error){journalError=errorText(error);}
      const common = { profile: process.env.PI_RUN_PROFILE || "default",
        sessionId: ctx.sessionManager.getSessionId(), processId: process.pid, container: process.env.HOSTNAME,
        toolName: action?.toolName, toolCallId: action?.toolCallId, reviewId: action?.reviewId, cwd: ctx.cwd };
      return (level,event,message,details)=>active?.write({timestamp:new Date().toISOString(),...common,sequence:++sequence,level,event,message,details});
    }
    // Only for correlating final reports. Bounded; never a permission cache.
    const traces = new Map<string, Trace>();
    const traceKey = (ctx: ExtensionContext, id: string) => JSON.stringify([ctx.sessionManager.getSessionId(), id]);
    const active = new Set<AbortController>();
    const invalidate = () => {
      closeLogViewer();retryPermit=undefined;
      revision++; for (const c of active) c.abort(new Error("Conversation/settings changed"));
      if (enabled && active.size && logUI) status(logUI,"Cancelled");
    };
    const block = (reason: string) => ({ block: true as const, reason });
    const tell = (ctx: ExtensionContext, message: string, kind: "info" | "warning" | "error" = "info") => ctx.ui.notify(visible(message), kind);
    function publishGuardMode(ctx:ExtensionContext):void{try{guardConnection.setReviewMode(enabled?"on":"off");}
      catch(error){tell(ctx,`Shared Guard mode is unavailable: ${oneLine(errorText(error),180)}`,"warning");}}
    async function applyReviewerSetting(ctx:ExtensionContext,setting:"model"|"thinking",value?:string){
      const result=await guardConnection.configureReviewer({schemaVersion:1,setting,...(value?{value}:{})});
      config={...result.settings.config};configNeedsWrite=result.settings.source!=="guard_file";
      if(result.status==="applied"){invalidate();configNeedsWrite=false;statusOwner++;last=undefined;refreshStatus(ctx);}
      return result;
    }
    async function updateConfig(ctx: ExtensionContext, patch: GuardianConfigPatch): Promise<void> {
      if(patch.model!==undefined)await applyReviewerSetting(ctx,"model",patch.model??"default");
      if(patch.thinking!==undefined)await applyReviewerSetting(ctx,"thinking",patch.thinking??"default");
    }

    const binding = factory({ pi, changed: invalidate, config:()=>config, updateConfig, tell, log: ctx => sink(ctx) });
    if (!binding || typeof binding.select !== "function") throw new Error("Reviewer factory must provide select(ctx)");
    const productionReviewer=factory===createPiReviewerBinding;
    const sharedReviewerControls:readonly ReviewerControl[]=productionReviewer?[{
      name:"guardian-model",label:"Guard reviewer model",description:"Persistent reviewer model selector",handler:async(args,ctx)=>{
        try{const value=args.trim(),result=await applyReviewerSetting(ctx,"model",value||undefined);if(result.status==="cancelled")return;
          if(result.status==="shown"){tell(ctx,`Model: ${result.settings.config.model??"not selected"}`);return;}
          const model=result.settings.config.model;sink(ctx)("INFO","model_changed","Shared Guard reviewer model preference changed",{model:model??"not_selected"});
          tell(ctx,`Guard reviewer model: ${model??"not selected"} (saved).`);
        }catch(error){tell(ctx,oneLine(errorText(error),200),"error");}
      }},{
      name:"guardian-thinking",label:"Guard reviewer thinking",description:"Persistent reviewer thinking selector",handler:async(args,ctx)=>{
        try{const value=args.trim().toLowerCase(),result=await applyReviewerSetting(ctx,"thinking",value||undefined);if(result.status==="cancelled")return;
          if(result.status==="shown"){tell(ctx,`Thinking: ${result.settings.config.thinking??"low"}`);return;}
          const requested=result.settings.config.thinking??"low",effective=result.settings.effectiveThinking;
          sink(ctx)("INFO","thinking_changed","Shared Guard reviewer thinking preference changed",{requested,effective,modelSelected:result.settings.modelAvailable});
          tell(ctx,`Guard reviewer thinking: ${effective} (saved${result.settings.modelAvailable?"":", model not selected"}).`);
        }catch(error){tell(ctx,oneLine(errorText(error),200),"error");}
      }}]:[];
    const reviewerControls=Object.freeze([...sharedReviewerControls,...(binding.controls??[])]);
    type PendingRuntimeReview={request:ReviewRequest;reviewer?:GuardianReviewer;reviewerId:string;startedAt:number;deadlineAt:number;stats:Stats;
      sessionId:string;cwd:string;claimed:boolean};
    const pendingRuntimeReviews=new Map<string,PendingRuntimeReview>();
    function reviewerDispatch(ctx:ExtensionContext):{reviewer?:GuardianReviewer;reviewerId:string;budget:{totalMs:number;slowMs:number}}{
      if(productionReviewer)return {reviewerId:"pi-agent",budget:{totalMs:270_000,slowMs:15_000}};
      const reviewer=binding.select(ctx);
      if(!reviewer||typeof reviewer.review!=="function"||typeof reviewer.id!=="string"||!reviewer.id.trim()||reviewer.id.length>128)
        throw new Error("Invalid reviewer implementation");
      return {reviewer,reviewerId:reviewer.id,budget:validBudget(reviewer.budget)};
    }
    const diagnosticLevel=(level:LogLevel):"INFO"|"INVESTIGATE"|"ERROR"|"CANCELLED"=>
      level==="INVESTIGATE"?"INVESTIGATE":level==="ERROR"?"ERROR":level==="CANCELLED"?"CANCELLED":"INFO";
    const wireCopy=<T,>(value:T):T=>JSON.parse(JSON.stringify(value)) as T;
    registerAgenticGuardReviewDomain(pi,"guardian","guardian-command.v1","guardian-decision.v1",{
      async review(backendRequest:Readonly<AgenticGuardBackendRequest>,backendContext:Readonly<AgenticGuardBackendContext>,sessionContext:ExtensionContext,
        selection:Readonly<AgenticGuardReviewerSelection>):Promise<unknown>{
        const action=plain(backendRequest.action),policy=plain(backendRequest.policy);
        if(Object.keys(action).sort().join(",")!=="requestId,schemaVersion"||action.schemaVersion!==1||
          typeof action.requestId!=="string"||!/^[0-9a-f-]{36}$/.test(action.requestId)||
          Object.keys(policy).sort().join(",")!=="schemaVersion"||policy.schemaVersion!==1)throw new Error("Invalid Guardian runtime review request");
        const pending=pendingRuntimeReviews.get(action.requestId);
        if(!pending||pending.claimed)throw new Error("Guardian runtime review request is unavailable");
        pending.claimed=true;
        if(sessionContext.sessionManager.getSessionId()!==pending.sessionId||sessionContext.cwd!==pending.cwd)
          throw new Error("Guardian runtime review context changed before dispatch");
        const emit:LogSink=(level,event,message,details)=>backendContext.report({schemaVersion:1,level:diagnosticLevel(level),event,message,
          ...(details===undefined?{}:{details:wireCopy(details)})});
        const reviewer=pending.reviewer??new PiAgentReviewer({model:selection.model,thinking:selection.thinking as Thinking,
          requestedThinking:selection.requestedThinking as Thinking,modelSource:selection.modelSource,thinkingSource:selection.thinkingSource,
          provider:(signal,step)=>resolveProvider(sessionContext,selection.model,signal,step)});
        if(reviewer.id!==pending.reviewerId)throw new Error("Guardian runtime reviewer identity changed before dispatch");
        const deadlineAt=pending.reviewer?pending.deadlineAt:pending.startedAt+selection.budget.totalMs,deadline=new AbortController();
        const reviewSignal=AbortSignal.any([backendContext.signal,deadline.signal]);
        const timer=setTimeout(()=>deadline.abort(new ReviewTimeoutError(`Review exceeded ${selection.budget.totalMs/1000} seconds`,"reviewer assessment")),Math.max(1,deadlineAt-Date.now()));
        const trace=new ReviewTrace(emit,reviewSignal,deadlineAt,stage=>{pending.stats.stage=stage;});
        let failure:unknown;
        try{
          const services=reviewServices(pending.request,reviewSignal,emit,pending.stats,trace);
          const raw=await trace.step("reviewer assessment",{reviewerId:pending.reviewerId},()=>reviewer.review(pending.request,services));
          reviewSignal.throwIfAborted();
          const result=validateReviewResult(raw,pending.request);
          if(result.metrics?.requests!==undefined)pending.stats.requests=result.metrics.requests;
          if(result.status==="incomplete")return {schemaVersion:1,status:"incomplete",error:result.error};
          return {schemaVersion:1,status:"completed",decision:wireCopy({schemaVersion:1,reviewerId:pending.reviewerId,reviewResult:result})};
        }catch(error){failure=error;throw error;}
        finally{clearTimeout(timer);deadline.abort(failure??new Error("Review finished"));trace.close(failure);}
      },
    });
    async function dispatchRuntimeReview(request:ReviewRequest,reviewer:GuardianReviewer|undefined,reviewerId:string,startedAt:number,deadlineAt:number,signal:AbortSignal,
      emit:LogSink,stats:Stats,ctx:ExtensionContext):Promise<ReviewResult>{
      const requestId=randomUUID(),pending:PendingRuntimeReview={request,...(reviewer?{reviewer}:{}),reviewerId,startedAt,deadlineAt,stats,
        sessionId:ctx.sessionManager.getSessionId(),cwd:ctx.cwd,claimed:false};
      pendingRuntimeReviews.set(requestId,pending);
      try{
        const raw:Readonly<GuardReviewResultV1>=await guardReviewConnection.review({schemaVersion:1,
          action:{schemaVersion:1,requestId},policy:{schemaVersion:1}}, {signal,report:(event:Readonly<GuardReviewDiagnosticSnapshotV1>)=>
            emit(event.level,event.event,event.message,event.details as Record<string,unknown>|undefined)});
        if(raw.status==="incomplete")return {status:"incomplete",error:raw.error};
        const envelope=plain(raw.decision);
        if(Object.keys(envelope).sort().join(",")!=="reviewResult,reviewerId,schemaVersion"||envelope.schemaVersion!==1||envelope.reviewerId!==reviewerId)
          throw new Error("Invalid Guardian runtime review envelope");
        return validateReviewResult(envelope.reviewResult,request);
      }finally{pendingRuntimeReviews.delete(requestId);}
    }
    function reviewerSummary(ctx: ExtensionContext): string {
      let description:readonly string[]=[];try{description=binding.describe?.(ctx)??[];}catch{return "reviewer unavailable";}
      const model=description.find(line=>line.startsWith("Model: "))?.slice(7)??"";
      const thinking=description.find(line=>line.startsWith("Thinking: "))?.slice(10)??"";
      const unavailable=model.endsWith(" (unavailable)"),full=unavailable?model.slice(0,-14):model,slash=full.indexOf("/");
      const name=slash>=0?full.slice(slash+1):full;
      return visible(unavailable?`${name} · unavailable`:[name,thinking].filter(Boolean).join(" · "));
    }
    function guardStatusValue(ctx:ExtensionContext,state:string,detail=""):GuardActivityRequestV1{
      const names:Record<string,string>={off:"off",on:"on",reviewing:"reviewing","still reviewing":"reviewing",
        dispute:"dispute",unavailable:"unavailable",cancelled:"on",allowed:"on","not executed":"on"};
      const normalized=names[state.trim().toLowerCase()]??state.trim().toLowerCase().replace(/\s+/g,"-");
      const right=reviewerSummary(ctx);
      return {schemaVersion:1,state:normalized,...(detail?{detail:`· ${detail}`} : {}),...(right?{right}:{})};
    }
    function status(ctx: ExtensionContext, state: string, detail = ""): void {
      displayState=state;displayDetail=detail;
      if(!guardConnection.connected())return;
      try{guardConnection.setBaseline(guardStatusValue(ctx,state,detail));}catch{/* Presentation cannot affect command review. */}
    }
    async function beginGuardActivity(ctx:ExtensionContext,state:string,detail="",signal?:AbortSignal):Promise<GuardActivityLeaseV1|undefined>{
      if(!guardConnection.connected())return undefined;
      try{return await guardConnection.acquireActivity(guardStatusValue(ctx,state,detail),signal);}catch{return undefined;}
    }
    function updateGuardActivity(lease:GuardActivityLeaseV1|undefined,ctx:ExtensionContext,state:string,detail=""):boolean{
      if(!lease?.active())return false;
      try{lease.update(guardStatusValue(ctx,state,detail));return true;}catch{return false;}
    }
    function refreshStatus(ctx: ExtensionContext): void {status(ctx,displayState,displayDetail);}
    function syncJustificationTool(ctx:ExtensionContext):void{
      try{
        const activeTools=pi.getActiveTools(),wanted=!!dispute&&dispute.phase==="investigating"&&!dispute.justification;
        const present=activeTools.includes(JUSTIFICATION_TOOL);
        if(wanted&&!present)pi.setActiveTools([...activeTools,JUSTIFICATION_TOOL]);
        if(!wanted&&present)pi.setActiveTools(activeTools.filter(name=>name!==JUSTIFICATION_TOOL));
      }catch(e){tell(ctx,`Guardian could not update its justification tool: ${oneLine(errorText(e),180)}`,"warning");}
    }
    function appendDispute(ctx:ExtensionContext,value:Record<string,unknown>):void{
      try{pi.appendEntry(GUARDIAN_DISPUTE_ENTRY,{schemaVersion:1,...value});}
      catch(e){tell(ctx,`Guardian dispute state could not be saved: ${oneLine(errorText(e),180)}`,"warning");
        sink(ctx)("ERROR","dispute_state_unavailable","Dispute remains enforced in memory but could not be saved",{error:errorText(e)});}
    }
    function updateDispute(ctx:ExtensionContext,phase:DisputePhase,reads=dispute?.reads??0):void{
      if(!dispute)return;
      dispute={...dispute,phase,reads};
      appendDispute(ctx,{state:"open",...dispute});syncJustificationTool(ctx);
      statusOwner++;status(ctx,"Dispute",phase==="awaiting-user"?"awaiting you":"investigating");
    }
    function resolveDispute(ctx:ExtensionContext,basis:string,authorizationGranted=false):void{
      const resolved=dispute;if(!resolved)return;
      dispute=undefined;appendDispute(ctx,{state:"resolved",id:resolved.id,basis});syncJustificationTool(ctx);statusOwner++;
      sink(ctx)("INFO","dispute_resolved","Guardian dispute latch cleared",{
        disputeId:resolved.id,basis,pendingInvocationReleased:false,authorizationGranted,
      });
      status(ctx,enabled?"On":"Off");
    }
    function openDispute(ctx:ExtensionContext,current:AbortController|undefined,reason:string,basis:string,emit:LogSink,event:ToolCallEvent,decision?:Decision):void{
      closeLogViewer();
      revision++;
      let cancelledReviews=0;
      for(const c of active)if(c!==current&&!c.signal.aborted){cancelledReviews++;c.abort(new Error("Guardian dispute opened"));}
      const cwd=actionCwd(ctx,event.input as Json);
      dispute={id:randomUUID(),reason:clip(reason,4096),phase:"investigating",reads:0,
        action:{toolName:event.toolName,toolCallId:event.toolCallId,input:structuredClone(event.input as Json),cwd},
        ...(decision?{originalOutcome:decision.outcome}:{})};
      appendDispute(ctx,{state:"open",...dispute});syncJustificationTool(ctx);statusOwner++;
      emit("BLOCK","dispute_opened","Invocation withheld; bounded inspection and one structured primary position are available",{
        disputeId:dispute.id,basis,reason:dispute.reason,maxReadCalls:MAX_DISPUTE_READS,cancelledReviews,
      });
      status(ctx,"Dispute","investigating");
      tell(ctx,`Guardian stopped this action; nothing was executed. ${oneLine(dispute.reason,320)} The agent may inspect files read-only and must submit its position to Guardian. You are needed only if they still disagree.`,"warning");
    }
    async function assessJustification(ctx:ExtensionContext,snapshot:GuardianDispute,justification:GuardianJustification,
      callerSignal:AbortSignal|undefined,toolCallId:string):Promise<GuardianAssessment>{
      const emit=sink(ctx,{toolName:JUSTIFICATION_TOOL,toolCallId,reviewId:`${snapshot.id}-assessment`});
      if(!snapshot.action){const error="Original blocked action is unavailable; Guardian cannot reassess the justification.";
        emit("ERROR","dispute_assessment_unavailable",error,{disputeId:snapshot.id});return {status:"unavailable",error};}
      const controller=new AbortController(),generation=revision,session=ctx.sessionManager.getSessionId(),cwd=ctx.cwd;
      const deadline=new AbortController(),signals=[controller.signal,deadline.signal,...(callerSignal?[callerSignal]:[])];
      const signal=AbortSignal.any(signals),stats:Stats={requests:null,durationMs:0,result:"assessment unavailable"},started=Date.now();
      let trace:ReviewTrace|undefined,timer:ReturnType<typeof setTimeout>|undefined,failure:unknown,timedOut=false;
      let guardActivity:GuardActivityLeaseV1|undefined;
      active.add(controller);statusOwner++;
      try{
        guardActivity=await beginGuardActivity(ctx,"Dispute","assessing",signal);signal.throwIfAborted();
        if(!guardActivity)status(ctx,"Dispute","assessing");
        emit("INFO","dispute_assessment_started","Guardian is reassessing the blocked action against the agent's structured position",{
          disputeId:snapshot.id,position:justification.position,originalOutcome:snapshot.originalOutcome??null,
        });
        emit("INFO","review_started","Reviewing a structured dispute justification",{reviewScope:"dispute_assessment",
          action:snapshot.action?actionPreview(snapshot.action.input as Json):{},disputeId:snapshot.id});
        const {reviewer,reviewerId,budget}=reviewerDispatch(ctx),deadlineAt=Date.now()+budget.totalMs;
        trace=new ReviewTrace(emit,signal,deadlineAt,stage=>{stats.stage=stage;});
        timer=setTimeout(()=>{timedOut=true;deadline.abort(new ReviewTimeoutError(`Dispute assessment exceeded ${budget.totalMs/1000} seconds`,trace?.stage()??"assessment"));},budget.totalMs);
        const event={type:"tool_call",toolName:snapshot.action.toolName,toolCallId:snapshot.action.toolCallId,
          input:{...structuredClone(snapshot.action.input),cwd:snapshot.action.cwd}} as ToolCallEvent;
        const base=await trace.step("prepare dispute assessment",{},child=>prepareReview(pi,ctx,event,stateDir,child,emit,store),PREPARATION_TIMEOUT_MS);
        const request=freeze({...base,action:snapshot.action,
          dispute:{guardianReason:snapshot.reason,...(snapshot.originalOutcome?{originalOutcome:snapshot.originalOutcome}:{}),justification}}) as ReviewRequest;
        const raw=await trace.step("review dispute justification",{reviewerId},
          ()=>dispatchRuntimeReview(request,reviewer,reviewerId,started,deadlineAt,signal,emit,stats,ctx));
        signal.throwIfAborted();
        const result=validateReviewResult(raw,request);if(result.status==="incomplete")throw new Error(result.error);
        if(generation!==revision||session!==ctx.sessionManager.getSessionId()||cwd!==ctx.cwd||dispute?.id!==snapshot.id||ctx.hasPendingMessages())
          throw new Error("Conversation or dispute changed before assessment completed");
        const decision=result.decision,assessment:GuardianAssessment={status:"completed",outcome:decision.outcome,
          reason:decisionExplanation(decision),...(decision.basis?{basis:decision.basis}:{})};
        stats.result=decision.outcome;stats.reason=assessment.reason;
        const level=decision.outcome==="ALLOW"?"ALLOW":decision.outcome==="ASK"?"ASK":"BLOCK";
        emit(level,"dispute_assessment_decision",assessment.reason,{disputeId:snapshot.id,outcome:decision.outcome,basis:decision.basis??null,
          userMessageIds:decision.userMessageIds??[],authorizationGranted:false,pendingInvocationReleased:false});
        emit(level,"review_decision",assessment.reason,{reviewerId,outcome:decision.outcome,reason:assessment.reason,basis:decision.basis??null,
          effects:decision.effects??null,instructionRefs:decision.instructionRefs??[],explanationSource:decision.reason?"reviewer":"extension_fallback",
          userMessageIds:decision.userMessageIds??[],decisionAvailable:true,assessment:true,authorizationGranted:false,pendingInvocationReleased:false});
        return assessment;
      }catch(e){failure=e;const error=timedOut?`Assessment timed out. ${guardianDiagnosticReference(logger?.path)}`:signal.aborted?"Assessment cancelled because the conversation or session changed.":reviewFailureSummary(errorText(e),logger?.path);
        emit(signal.aborted?"CANCELLED":"ERROR","dispute_assessment_unavailable","No completed assessment was applied",{disputeId:snapshot.id,error:errorText(e)});
        emit(signal.aborted?"CANCELLED":"ERROR","review_unavailable","No completed reviewer decision for this assessment",{
          error:errorText(e),failureKind:timedOut?"timeout":signal.aborted?"cancelled":"review_failure",stage:trace?.stage()??"assessment",decisionAvailable:false});
        return {status:"unavailable",error};
      }finally{
        if(timer)clearTimeout(timer);trace?.close(failure);deadline.abort(failure??new Error("Assessment finished"));controller.abort(failure??new Error("Assessment finished"));active.delete(controller);
        guardActivity?.end();guardActivity=undefined;stats.durationMs=Date.now()-started;
        emit("INFO","dispute_assessment_finished","Justification assessment finished without releasing the blocked invocation",{
          disputeId:snapshot.id,result:stats.result,durationMs:stats.durationMs,requests:stats.requests,pendingInvocationReleased:false,
        });
        emit("INFO","review_finished","Assessment finished; challenge resolution is applied separately",{outcome:stats.result==="assessment unavailable"?null:stats.result,
          decisionAvailable:stats.result!=="assessment unavailable",stage:stats.stage??null,durationMs:stats.durationMs,requests:stats.requests,timedOut});
        if(dispute?.id===snapshot.id){statusOwner++;status(ctx,"Dispute","awaiting you");}
      }
    }

    pi.registerTool({
      name:JUSTIFICATION_TOOL,label:"Guardian justification",exposure:"model-only",defaultActive:false,executionMode:"sequential",
      description:"Submit your final position in a Guardian challenge. Retraction or narrowing withdraws the original action; an accepted contest permits one exact retry; unresolved disagreement ends the turn for human judgment.",
      promptGuidelines:["When Guardian opens a dispute, optionally inspect files with the permitted reads, then call guardian_justify exactly once. Continue only if its result says the challenge is resolved; otherwise stop for human feedback."],
      parameters:JustificationSchema,
      async execute(toolCallId,params,signal,_onUpdate,toolCtx){
        signal?.throwIfAborted();
        const ctx=toolCtx as unknown as ExtensionContext,current=dispute,justification=normalizedJustification(params);
        if(!current||current.phase!=="investigating"||current.justification)throw new Error("No Guardian dispute is accepting a justification");
        if(!justification)throw new Error("Invalid Guardian justification");
        const snapshot={...current,justification};dispute=snapshot;updateDispute(ctx,"awaiting-user");
        const log=sink(ctx,{toolName:JUSTIFICATION_TOOL,toolCallId});
        log("INFO","dispute_justification_submitted","Agent position recorded; the original invocation remains cancelled",{
          disputeId:current.id,position:justification.position,evidence:justification.evidence??[],humanRequired:justification.position==="contest"?null:false,authorizationGranted:false,
        });
        if(justification.position!=="contest"){
          const resolution:JustificationResolution=justification.position==="retract"?"retracted":"narrowed";
          resolveDispute(ctx,justification.position==="retract"?"agent_retracted":"agent_narrowed");
          log("INFO","dispute_consensus","Primary withdrew the original action; no human arbitration required",{
            disputeId:current.id,resolution,authorizationGranted:false,pendingInvocationReleased:false,
          });
          const details:JustificationDetails={schemaVersion:1,disputeId:current.id,guardianReason:current.reason,justification,resolution,executed:false,humanRequired:false};
          return {content:[{type:"text",text:justificationPanel(details)}],details};
        }
        const assessment=await assessJustification(ctx,snapshot,justification,signal,toolCallId);
        let resolution:JustificationResolution="human-required",humanRequired=true;
        if(dispute?.id===current.id&&assessment.status==="completed"&&assessment.outcome==="ALLOW"&&current.action){
          retryPermit={disputeId:current.id,action:structuredClone(current.action),revision,sessionId:ctx.sessionManager.getSessionId(),cwd:ctx.cwd};
          resolution="accepted";humanRequired=false;resolveDispute(ctx,"agent_guardian_agreement",true);
          log("ALLOW","dispute_consensus","Guardian accepted the primary position; one exact retry is authorized",{
            disputeId:current.id,resolution,authorizationGranted:true,pendingInvocationReleased:false,
          });
        }else if(dispute?.id===current.id){dispute={...dispute,assessment};updateDispute(ctx,"awaiting-user");}
        const details:JustificationDetails={schemaVersion:1,disputeId:current.id,guardianReason:current.reason,justification,assessment,resolution,executed:false,humanRequired};
        return {content:[{type:"text",text:justificationPanel(details)}],details,...(humanRequired?{terminate:true}:{})};
      },
      renderCall(_args,theme){return new Text(theme.fg("toolTitle",theme.bold("Guardian · receiving agent position")),0,0);},
      renderResult(result,_options,theme){
        const details=result.details as JustificationDetails|undefined;
        const text=details?justificationPanel(details):result.content.filter(v=>v.type==="text").map(v=>v.text).join("\n");
        return new Text(theme.fg(details?"warning":"error",text),0,0);
      },
    });

    pi.on("session_start", async (_event, ctx) => {
      invalidate();dispute=undefined;store.clear();binding.reset?.();last=undefined;config=defaultGuardReviewerConfig();configNeedsWrite=true;
      try{await selectLogger(ctx);}catch(error){logger=undefined;journalError=errorText(error);tell(ctx,`Guardian logging unavailable: ${journalError}. Reviews and dispute enforcement are unchanged.`,"warning");}
      let configSource="default";
      try{config=await loadGuardReviewerConfig(stateDir);configNeedsWrite=false;configSource="guard_file";}
      catch(e){
        if((e as NodeJS.ErrnoException).code==="ENOENT"){
          try{const legacy=await loadGuardianConfig(stateDir);config=adoptLegacyGuardReviewerConfig(legacy);configSource=legacy.model?"legacy_explicit":"default";}
          catch(legacyError){if((legacyError as NodeJS.ErrnoException).code!=="ENOENT"){
            tell(ctx,`Legacy Guardian configuration unavailable; no Guard reviewer selected: ${errorText(legacyError)}`,"warning");
            sink(ctx)("ERROR","config_unavailable","Legacy Guardian configuration rejected; no reviewer selected",{error:errorText(legacyError)});
          }}
        }else{
          tell(ctx,`Shared Guard reviewer configuration unavailable; no reviewer selected: ${errorText(e)}`,"warning");
          sink(ctx)("ERROR","config_unavailable","Shared Guard reviewer configuration rejected; no reviewer selected",{error:errorText(e)});
          configSource="invalid_guard_config";
        }
      }
      try{defaultMode=(await loadGuardianModeConfig(stateDir)).defaultMode;defaultModeError=undefined;}
      catch(error){defaultMode="off";defaultModeError=errorText(error);tell(ctx,`Guardian new-session default unavailable; using Off: ${defaultModeError}`,"warning");}
      const restored=restoredGuardianMode(ctx,defaultMode);modeRecorded=restored.source==="session";
      enabled=restored.mode==="on";publishGuardMode(ctx);dispute=enabled?restoredGuardianDispute(ctx):undefined;syncJustificationTool(ctx);
      statusOwner++;status(ctx,dispute?"Dispute":enabled?"On":"Off",dispute?(dispute.phase==="awaiting-user"?"awaiting you":"investigating"):"");
      sink(ctx)("SESSION_START", "session_started", "Guardian ready; logs are diagnostic only", {
        logPath:logger?.path??"unavailable",maxBytes:MAX_LOG_BYTES,backups:LOG_BACKUPS,
        configPath:join(stateDir,"guard","config.json"),legacyConfigPath:join(stateDir,"guardian","config.json"),configSource,
        mode:restored.mode,modeSource:restored.source,newSessionDefault:defaultMode,defaultModeAvailable:!defaultModeError,model:config.model??"not_selected",thinking:config.thinking??"low",
        reviewScope: "command_execution", toolNames: [...GUARDED_COMMAND_TOOLS],
      });
    });
    pi.on("session_tree", (_e, ctx) => { invalidate();store.clear();const restored=restoredGuardianMode(ctx,defaultMode);
      if(restored.source==="session"){modeRecorded=true;enabled=restored.mode==="on";}
      publishGuardMode(ctx);dispute=enabled?restoredGuardianDispute(ctx):undefined;syncJustificationTool(ctx);statusOwner++;last=undefined;
      status(ctx,dispute?"Dispute":enabled?"On":"Off",dispute?(dispute.phase==="awaiting-user"?"awaiting you":"investigating"):""); });
    pi.on("model_select", (_e,ctx)=>refreshStatus(ctx));
    pi.on("thinking_level_select", (_e,ctx)=>refreshStatus(ctx));
    pi.on("session_shutdown", async (_event, ctx) => {
      invalidate();
      for (const t of traces.values()) if (t.disposition === "released") {
        t.emit("INFO", "result_not_observed", "Session stopped without a final tool report; execution outcome is unknown", {
          guardianAction: "released", reviewOutcome: t.decision?.outcome ?? null,
        });
      }
      traces.clear();
      sink(ctx)("INFO", "session_stopped", "Draining diagnostic logs; forced termination cannot guarantee delivery");
      // Bounded drain with a visible timeout; never hold authorization on disk I/O.
      let timer:ReturnType<typeof setTimeout>|undefined;const closing=logger;
      if(!closing)return;
      try{
        const drained=await Promise.race([closing.close().then(()=>true),new Promise<false>(resolve=>{timer=setTimeout(()=>resolve(false),1500);})]);
        if(!drained)console.error(`Guardian journal shutdown incomplete: ${closing.health().pending} record(s) pending at ${closing.path}`);
      }finally{if(timer)clearTimeout(timer);if(logger===closing)logger=undefined;}
    });
    pi.on("input", (event,ctx) => {
      // Real user feedback reopens normal review, but is not authority by mere presence.
      pinSessionMode(ctx);invalidate();
      if(event.source!=="extension"){
        if(dispute)resolveDispute(ctx,"user_input");else status(ctx,enabled?"On":"Off");
      }
      return { action: "continue" as const };
    });
    pi.on("agent_settled", (_event,ctx)=>{
      if(dispute&&dispute.phase!=="awaiting-user"){
        updateDispute(ctx,"awaiting-user");
        sink(ctx)("INFO","dispute_waiting_for_user","Agent turn settled; no further tools are permitted before human feedback",{disputeId:dispute.id});
      }
    });
    // Supply the profile and the enforced dispute handoff to the coding agent.
    pi.on("before_agent_start", async (event, ctx) => {
      let systemPrompt = event.systemPrompt;
      try {
        const text = await readText(join(stateDir, "AGENTS.md"));
        if (!systemPrompt.includes(text)) systemPrompt += `\n\nCURRENT DEV/OPS PROFILE:\n${text}`;
      } catch (e) { tell(ctx, `Guardian instructions unavailable: ${errorText(e)}`, "warning"); }
      // Keep the handoff explicit even if loading instructions failed; tool review still reports that error.
      if (!systemPrompt.includes(ACTOR_HANDOFF)) systemPrompt += `\n\n${ACTOR_HANDOFF}`;
      return { systemPrompt };
    });

    pi.on("tool_call", async (event, ctx) => {
      pinSessionMode(ctx);
      // Normal coverage remains bash/run. An open dispute is a separate stop state:
      // only a small number of direct native file reads may support the agent's explanation.
      if(dispute){
        const emit=sink(ctx,event);
        if(dispute.phase==="investigating"&&!dispute.justification&&event.toolName===JUSTIFICATION_TOOL)return undefined;
        if(dispute.phase==="investigating"&&event.toolName==="read"&&dispute.reads<MAX_DISPUTE_READS){
          const reads=dispute.reads+1;updateDispute(ctx,"investigating",reads);
          emit("INFO","dispute_read_allowed","Bounded read-only evidence call permitted during dispute",{
            disputeId:dispute.id,readCall:reads,maxReadCalls:MAX_DISPUTE_READS,action:actionPreview(event.input as Record<string,unknown>),
          });
          return undefined;
        }
        if(dispute.phase==="investigating"&&dispute.reads>=MAX_DISPUTE_READS)updateDispute(ctx,"awaiting-user");
        const reason=`Not executed: Guardian dispute ${JSON.stringify(dispute.id)} is ${dispute.phase==="awaiting-user"?"awaiting human feedback":"limited to native read-only file inspection"}. The original concern was: ${visible(dispute.reason)} ${dispute.phase==="awaiting-user"?"Stop for human feedback.":"Submit guardian_justify; do not retry through another tool."}`;
        emit("BLOCK","dispute_tool_withheld","Tool call withheld while a Guardian dispute is open",{
          disputeId:dispute.id,phase:dispute.phase,toolName:event.toolName,reason:dispute.reason,
        });
        return block(reason);
      }
      // Outside a dispute, excluded primitives do not load instructions, select a
      // reviewer, create a trace, alter status, or enter command review.
      if (!isGuardedCommandTool(event.toolName)) return undefined;

      const viewOwner = ++statusOwner, viewRevision = revision;
      const show = (state: string, detail = "") => {
        if (viewOwner === statusOwner && viewRevision === revision) status(ctx, enabled ? state : "Off", enabled ? detail : "");
      };
      const emit = sink(ctx, { ...event, reviewId: `${process.pid}-${Date.now()}-${sequence + 1}` });
      const trace: Trace = { emit, disposition: "pending" };
      if (traces.size >= 512) {
        const oldest = traces.keys().next().value!;
        traces.get(oldest)?.emit("INFO", "result_tracking_expired", "Diagnostic tracking limit reached; no execution outcome inferred");
        traces.delete(oldest);
      }
      traces.set(traceKey(ctx, event.toolCallId), trace);
      const withheld = (basis: string, reason: string) => {
        trace.disposition = "withheld"; trace.basis = basis;
        if (trace.stats) trace.stats.finalAction = `not released (${basis})`;
        emit(basis === "context_changed" ? "CANCELLED" : "BLOCK", "invocation_withheld", "Invocation not released by guardian", {
          basis, reason, reviewOutcome: trace.decision?.outcome ?? null, reviewReason: trace.decision?.reason ?? null,
        });
        show("On");
        return block(reason);
      };
      const released = (basis: string) => {
        trace.disposition = "released"; trace.basis = basis; trace.releasedAt = Date.now();
        if (trace.stats) trace.stats.finalAction = `released (${basis})`;
        show("On");
        emit("ALLOW", "invocation_released", "Invocation released by guardian; execution success is not yet known", {
          basis, reviewerId: trace.reviewerId ?? null, reviewOutcome: trace.decision?.outcome ?? null,
        });
      };
      if (!enabled) {
        trace.disposition = "released"; trace.basis = "guardian_off"; trace.releasedAt = Date.now();
        show("Off");
        emit("INFO", "review_skipped", "Guardian is off by user choice; no reviewer decision made", { action: actionPreview(event.input as Record<string, unknown>) });
        emit("INFO", "invocation_released", "Continuing without guardian review", { basis: "guardian_off", reviewOutcome: null });
        return;
      }
      let args: string;
      try { args = JSON.stringify(event.input); }
      catch {
        emit("ERROR", "invalid_tool_input", "Tool arguments are not valid JSON; action not executed");
        return withheld("invalid_arguments", "Not executed: tool arguments are not valid JSON");
      }
      if(retryPermit){
        const candidate=retryPermit;retryPermit=undefined;
        const exact=candidate.revision===revision&&candidate.sessionId===ctx.sessionManager.getSessionId()&&candidate.cwd===ctx.cwd&&
          !ctx.hasPendingMessages()&&candidate.action.toolName===event.toolName&&candidate.action.cwd===actionCwd(ctx,event.input as Json)&&
          canonicalJson(candidate.action.input)===canonicalJson(event.input);
        if(exact){
          emit("ALLOW","dispute_retry_released","Exact action released after primary and Guardian agreement",{disputeId:candidate.disputeId,authorizationGranted:true});
          released("dispute_consensus");return;
        }
        emit("INFO","dispute_retry_invalidated","Resolved-dispute retry did not match the exact authorized action; normal review applies",{
          disputeId:candidate.disputeId,authorizationGranted:false,
        });
      }
      const current = new AbortController(); active.add(current);
      const generation = revision, session = ctx.sessionManager.getSessionId(), leaf = ctx.sessionManager.getLeafId();
      const name = event.toolName, cwd = ctx.cwd;
      const callerSignal = (ctx as ExtensionContext & { signal?: AbortSignal }).signal;
      const signal = callerSignal ? AbortSignal.any([current.signal, callerSignal]) : current.signal;
      let guardActivity:GuardActivityLeaseV1|undefined;
      const unchanged = () => !signal.aborted && generation === revision && !ctx.hasPendingMessages() &&
        session === ctx.sessionManager.getSessionId() && cwd === ctx.cwd && event.toolName === name &&
        JSON.stringify(event.input) === args && (!leaf || ctx.sessionManager.getBranch().some(e => e.id === leaf));
      const stale = () => {
        emit("CANCELLED", "action_cancelled", "Conversation, settings or action changed; invocation not released");
        return withheld("context_changed", "Not executed: conversation, settings or action changed. Reassess after processing the latest user instructions.");
      };
      const stats: Stats = { requests: null, durationMs: 0, result: "review unavailable" };
      trace.stats = stats;
      const started = Date.now();
      try {
        if (!unchanged()) return stale();
        guardActivity=await beginGuardActivity(ctx,"Reviewing","",signal);
        if (!unchanged()) return stale();
        if(!guardActivity)show("Reviewing");
        emit("INFO", "review_started", "Reviewing proposed command", {
          reviewScope: "command_execution", action: actionPreview(event.input as Record<string, unknown>),
        });
        let found: Decision | undefined, failure: string | undefined;
        const deadline = new AbortController();
        const reviewSignal = AbortSignal.any([signal, deadline.signal]);
        let timer: ReturnType<typeof setTimeout> | undefined, pulse: ReturnType<typeof setInterval> | undefined;
        let runTrace: ReviewTrace | undefined, failureError: unknown;
        try {
          const {reviewer,reviewerId,budget}=reviewerDispatch(ctx);
          const deadlineAt = Date.now() + budget.totalMs;
          trace.reviewerId = reviewerId;
          runTrace = new ReviewTrace(emit, reviewSignal, deadlineAt, stage => { stats.stage = stage; });
          timer = setTimeout(() => {
            const pending = runTrace!.pending();
            emit("ERROR", "review_deadline", "Overall review limit reached; outstanding operations will be cancelled", {
              limitMs: budget.totalMs, stage: runTrace!.stage(), pending, decisionAvailable: false, requests: stats.requests,
            });
            deadline.abort(new ReviewTimeoutError(`Review exceeded ${budget.totalMs / 1000} seconds while ${runTrace!.stage()}; no completed review`, runTrace!.stage()));
          }, budget.totalMs);
          let lastProgress = started;
          pulse = setInterval(() => {
            if (reviewSignal.aborted) return;
            const elapsed = Date.now() - started, slow = elapsed >= budget.slowMs;
            if(!updateGuardActivity(guardActivity,ctx,"Reviewing",`${Math.floor(elapsed / 1000)}s`))show("Reviewing",`${Math.floor(elapsed / 1000)}s`);
            if (slow && Date.now() - lastProgress >= 15_000) {
              emit("INFO", "review_progress", "Review still pending; this is elapsed time, not a missing-authorization decision", {
                elapsedMs: elapsed, stage: runTrace!.stage(), pending: runTrace!.pending(), requests: stats.requests, remainingMs: Math.max(0, deadlineAt - Date.now()),
              }); lastProgress = Date.now();
            }
          }, 1000);
          emit("INFO", "reviewer_dispatched", "Selected reviewer implementation and bounded time budget", { reviewerId, ...budget });
          const request = await runTrace.step("prepare review", {}, child => prepareReview(pi, ctx, structuredClone(event), stateDir, child, emit, store), PREPARATION_TIMEOUT_MS);
          reviewSignal.throwIfAborted();
          const rawResult = await runTrace.step("shared review dispatch", { reviewerId },
            async () => dispatchRuntimeReview(request,reviewer,reviewerId,started,deadlineAt,reviewSignal,emit,stats,ctx));
          reviewSignal.throwIfAborted();
          const result = await runTrace.step("validate reviewer result", { reviewerId }, async () => validateReviewResult(rawResult, request));
          if (result.metrics?.requests !== undefined) stats.requests = result.metrics.requests;
          if (result.status === "incomplete") throw new Error(result.error);
          found = { ...result.decision, userMessageIds: [...(result.decision.userMessageIds ?? [])] };
          stats.result = found.outcome; stats.reason = decisionExplanation(found); trace.decision = found;
          emit(found.outcome === "USER_REFUSED" ? "BLOCK" : found.outcome, "review_decision", decisionExplanation(found), {
            reviewerId, outcome: found.outcome, reason: found.reason ?? null, reasonCode: found.reasonCode ?? null,
            basis: found.basis ?? null, effects: found.effects ?? null, instructionRefs: found.instructionRefs ?? [],
            explanationSource: found.reason ? "reviewer" : "extension_fallback", userMessageIds: found.userMessageIds, decisionAvailable: true,
            durationMs: Date.now() - started, requests: stats.requests,
          });
        } catch (e) {
          failureError = e;
          failure = errorText(e); stats.reason = failure; stats.timeout = e instanceof ReviewTimeoutError || /exceeded.*seconds|timed out|timeout/i.test(errorText(e));
          const stage = (e instanceof ReviewTimeoutError) && e.stage ? e.stage : runTrace?.stage() ?? "reviewer selection";
          stats.stage = stage;
          emit(signal.aborted ? "CANCELLED" : "ERROR", "review_unavailable", "No completed reviewer decision for this invocation", {
            error: failure, failureKind: stats.timeout ? "timeout" : signal.aborted ? "cancelled" : "review_failure",
            stage, pending: runTrace?.pending() ?? [], decisionAvailable: false, durationMs: Date.now() - started, requests: stats.requests,
          });
        } finally {
          if (timer) clearTimeout(timer); if (pulse) clearInterval(pulse);
          // Close all spans explicitly; late provider results cannot turn into approvals.
          runTrace?.close(failureError);
          deadline.abort(failureError ?? new Error("Review finished"));
          guardActivity?.end();guardActivity=undefined;stats.durationMs = Date.now() - started;
          if (viewOwner === statusOwner && generation === revision) {
            last = stats;
            show("On");
          }
          emit("INFO", "review_finished", "Assessment finished; release and any later human direction are separate", {
            outcome: found?.outcome ?? null, decisionAvailable: !!found, stage: stats.stage ?? null,
            durationMs: stats.durationMs, requests: stats.requests, timedOut: stats.timeout ?? false,
          });
        }
        if (!unchanged()) return stale();
        if (found?.outcome === "ALLOW") {
          released("reviewer_decision");
          return;
        }
        const basis=found?.outcome==="USER_REFUSED"?"existing_user_refusal":failure?"review_unavailable":"reviewer_dispute";
        const explanation=found?.outcome==="USER_REFUSED"
          ? `This review found a currently applicable user restriction. ${decisionExplanation(found)}`
          : failure?reviewFailureSummary(failure,logger?.path):decisionExplanation(found!);
        const stopped=withheld(basis,`Not executed: Guardian challenged this invocation. ${visible(explanation)} The invocation is cancelled. Use only permitted read-only inspection, then submit guardian_justify. Continue only if Guardian reports agreement.`);
        openDispute(ctx,current,explanation,basis,emit,event,found);
        return stopped;
      } catch (e) {
        // Never let a thrown hook error accidentally turn into permission.
        if (signal.aborted || !unchanged()) return stale();
        emit(signal.aborted ? "CANCELLED" : "ERROR", "review_interrupted", "Invocation not released", { error: errorText(e) });
        const reason=`Review interrupted; no decision released: ${errorText(e)}`;
        const stopped=withheld("review_interrupted",`Not executed: Guardian challenged this invocation. ${visible(reason)} Submit guardian_justify; continue only if Guardian reports agreement.`);
        openDispute(ctx,current,reason,"review_interrupted",emit,event);
        return stopped;
      } finally { guardActivity?.end();active.delete(current); }
    });

    // Pi emits this final event for thrown tool errors as well as normal returns.
    // It is AFTER tool_result hooks, so record one final result, not two partial reports.
    // A blocked invocation also has a final error result: don't call it an executed command.
    pi.on("tool_execution_end", (event, ctx) => {
      // Mirror the entry scope so excluded primitives cannot become orphan log
      // rows or appear to have been authorized merely because they succeeded.
      if (!isGuardedCommandTool(event.toolName)) return;

      try {
        const key = traceKey(ctx, event.toolCallId), trace = traces.get(key);
        const emit = trace?.emit ?? sink(ctx, event);
        const withheld = trace?.disposition === "withheld";
        const isError = event.isError === true;
        emit(withheld ? "BLOCK" : isError ? "ERROR" : "INFO", "tool_result",
          withheld ? "Pi returned a result for an invocation withheld by guardian; not an execution failure" :
          isError ? "Pi reported a tool error; completed effects must be verified before retrying" :
          "Pi reported tool success; this is not independent verification of remote effects", {
            reviewerId: trace?.reviewerId ?? null, source: "tool_execution_end", resultKind: withheld ? "not_executed_by_guardian" : isError ? "tool_error" : "tool_success",
            guardianAction: trace?.disposition ?? "not_observed", releaseBasis: trace?.basis ?? null,
            reviewOutcome: trace?.decision?.outcome ?? null, reviewReason: trace?.decision?.reason ?? null,
            userMessageIds: trace?.decision?.userMessageIds ?? [],
            sinceReleaseMs: trace?.releasedAt === undefined ? null : Math.max(0, Date.now() - trace.releasedAt),
            ...toolResultDetails(event.result, isError, event.toolName),
          });
        traces.delete(key);
      } catch (e) {
        // A diagnostic hook must not throw into the tool/agent execution path.
        sink(ctx, event)("ERROR", "result_logging_failed", "Could not format the tool report", { error: errorText(e) });
      }
    });

    function pinSessionMode(ctx:ExtensionContext):void{if(modeRecorded)return;try{pi.appendEntry(GUARDIAN_MODE_ENTRY,{mode:enabled?"on":"off"});modeRecorded=true;}
      catch(error){tell(ctx,`Guardian could not record this session's mode: ${errorText(error)}`,"warning");}}
    async function setMode(ctx: ExtensionContext, next: boolean): Promise<void> {
      try{
        const previous=enabled,interrupted=active.size;
        if(!next&&dispute)resolveDispute(ctx,"mode_off");
        if(previous!==next||!modeRecorded){pi.appendEntry(GUARDIAN_MODE_ENTRY,{mode:next?"on":"off"});modeRecorded=true;}
        if(previous!==next){invalidate();enabled=next;publishGuardMode(ctx);statusOwner++;last=undefined;
          sink(ctx)("INFO","mode_changed","User changed shared Guard review mode for this session",{
            previous:previous?"on":"off",mode:enabled?"on":"off",interruptedReviews:interrupted,pendingInvocationReleased:false,
          });
        }else publishGuardMode(ctx);
        status(ctx,enabled?"On":"Off");tell(ctx,`Guard review: ${enabled?"On":"Off"} (this session).`);
      }catch(e){tell(ctx,oneLine(`Guardian session mode was not changed: ${errorText(e)}`,240),"error");}
    }
    async function modeCommand(args: string, ctx: ExtensionContext): Promise<void> {
      let value = args.trim().toLowerCase();
      if (!value) {
        if (!ctx.hasUI) { tell(ctx, `Guard review: ${enabled ? "On" : "Off"}. /guardian-mode on|off`); return; }
        const choices = [
          { value: "on", label: `On — review commands and CAF disclosures${enabled ? " [current]" : ""}` },
          { value: "off", label: `Off — commands and enabled CAF use direct paths${!enabled ? " [current]" : ""}` },
        ];
        const contextRevision = revision, contextSession = ctx.sessionManager.getSessionId();
        const selected = await ctx.ui.select("Shared Guard review mode", choices.map(c => c.label));
        if (selected === undefined || revision !== contextRevision || ctx.sessionManager.getSessionId() !== contextSession) return;
        value = choices.find(c => c.label === selected)?.value ?? "";
      }
      if (!["on", "off"].includes(value)) { tell(ctx, "Usage: /guardian-mode on|off"); return; }
      await setMode(ctx, value === "on");
    }
    async function defaultModeCommand(args:string,ctx:ExtensionContext):Promise<void>{
      let value=args.trim().toLowerCase();
      if(!value){if(!ctx.hasUI){tell(ctx,`Guard review new-session default: ${defaultMode}. /guardian-default on|off`);return;}
        const choices=[`On — review commands and CAF disclosures${defaultMode==="on"?" [current]":""}`,`Off — use direct client paths${defaultMode==="off"?" [current]":""}`],selected=await ctx.ui.select("Guard review default for new sessions",choices);
        if(selected===undefined)return;value=selected.startsWith("On")?"on":"off";}
      if(!["on","off"].includes(value)){tell(ctx,"Usage: /guardian-default on|off");return;}
      try{pinSessionMode(ctx);await saveGuardianModeConfig(stateDir,{schemaVersion:1,defaultMode:value as GuardianDefaultMode});defaultMode=value as GuardianDefaultMode;defaultModeError=undefined;
        sink(ctx)("INFO","default_mode_changed","Guard review default for new sessions changed; current session is unchanged",{defaultMode,currentMode:enabled?"on":"off"});
        tell(ctx,`Guard review new-session default: ${defaultMode} (saved; current session remains ${enabled?"On":"Off"}).`);
      }catch(error){tell(ctx,`Guard review new-session default was not changed: ${errorText(error)}`,"error");}
    }
    async function resumeCommand(_args:string,ctx:ExtensionContext):Promise<void>{
      pinSessionMode(ctx);if(!dispute){tell(ctx,"Guardian: no dispute is open.");return;}
      invalidate();resolveDispute(ctx,"guardian_resume");
      tell(ctx,"Guardian dispute cleared. No action was authorized or replayed; future commands receive fresh review.");
    }
    function shortStatus(ctx: ExtensionContext): void {
      pinSessionMode(ctx);let description: readonly string[] = [];
      try { description = binding.describe?.(ctx) ?? []; } catch { /* Mode is usable even with no model. */ }
      const fields = description.filter(line => /^(Model|Thinking):/.test(line));
      const health=logger?.health();
      tell(ctx,[`Guard review · ${enabled?"On":"Off"} · Guardian bash/run · CAF ${enabled?"guarded":"direct"}${dispute?` · dispute ${dispute.phase}`:""}`,`New sessions: ${defaultMode}${defaultModeError?` — unavailable (${defaultModeError})`:""}`,...fields,
        `Log: ${logger?.path??`unavailable${journalError?` — ${journalError}`:""}`}${health?.lastError?" (unavailable)":""}`].join("\n"));
    }
    pi.registerCommand("guardian-mode", { description: "Turn shared Guard review on/off for this session", handler: modeCommand });
    pi.registerCommand("guardian-default", { description: "Set shared Guard review for genuinely new sessions", handler: defaultModeCommand });
    pi.registerCommand("guardian-resume", { description: "Clear the current dispute without authorizing an action", handler: resumeCommand });
    pi.registerCommand("guardian-log", { description: "Browse recorded guardian reviews (read-only)", handler: logsCommand });
    pi.registerCommand("guardian-status", { description: "Show Guard review status", handler: async (_args,ctx) => shortStatus(ctx) });
    pi.registerCommand("guardian", { description: "Guard menu: review mode, model, thinking, status and logs", handler: async (args, ctx) => {
      try {pinSessionMode(ctx);
        const value = args.trim().toLowerCase();
        if (["on", "off"].includes(value)) { await setMode(ctx, value === "on"); return; }
        if(value.startsWith("default ")){await defaultModeCommand(value.slice(8),ctx);return;}
        if (value === "log" || value === "logs") { await logsCommand("", ctx); return; }
        if (!value && !ctx.hasUI) { shortStatus(ctx); return; }
        if (value) { tell(ctx, "Usage: /guardian [on|off|default on|off|log]"); return; }
        // No status dump, trace counts or last-error wall of text. The first menu
        // item can always toggle reviewing, even if the selected model is invalid.
        const choices = [
          { id: enabled ? "mode-off" : "mode-on", label: `Current session — ${enabled?"On (turn Off)":"Off (turn On)"}` },
          {id:"guardian-default",label:`New sessions — ${defaultMode==="on"?"On":"Off"}`},
          ...(dispute?[{id:"guardian-resume",label:"Resume — clear dispute without authorization"}]:[]),
          ...reviewerControls.map(c => ({ id: c.name, label: c.label ?? c.name.replace(/^guardian-/, "") })),
          { id: "guardian-status", label: "Status" },
          { id: "guardian-log", label: "Logs" },
          { id: "close", label: "Close" },
        ];
        const contextRevision = revision, contextSession = ctx.sessionManager.getSessionId();
        const selected = await ctx.ui.select(`Guard review — ${enabled ? "On" : "Off"}`, choices.map(c => c.label));
        if (revision !== contextRevision || ctx.sessionManager.getSessionId() !== contextSession) return;
        const id = choices.find(c => c.label === selected)?.id;
        if (id === "mode-on" || id === "mode-off") { await setMode(ctx, id === "mode-on"); return; }
        if(id==="guardian-default"){await defaultModeCommand("",ctx);return;}
        if (id === "guardian-resume") { await resumeCommand("",ctx); return; }
        if (id === "guardian-status") { shortStatus(ctx); return; }
        if (id === "guardian-log") { await logsCommand("", ctx); return; }
        const control = reviewerControls.find(c => c.name === id);
        if (control) await control.handler("", ctx);
      } catch (e) { tell(ctx, oneLine(errorText(e), 200), "error"); }
    }});
    // Only the active implementation contributes settings. A specialized reviewer
    // can expose no settings at all; the execution gate remains identical.
    const commandNames = new Set(["guardian", "guardian-mode", "guardian-default", "guardian-resume", "guardian-log", "guardian-status"]);
    for (const control of reviewerControls) {
      if (!/^guardian-[a-z][a-z0-9-]*$/.test(control.name) || commandNames.has(control.name)) throw new Error("Invalid or duplicate reviewer control");
      commandNames.add(control.name);
      pi.registerCommand(control.name, { description: control.description, handler:async(args,ctx)=>{pinSessionMode(ctx);await control.handler(args,ctx);} });
    }
  };
}


export default createGuardianExtension(createPiReviewerBinding);
