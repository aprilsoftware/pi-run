// SPDX-License-Identifier: MIT
import { join } from "node:path";
import type { GuardViewRequestV1 } from "../guard/guard-runtime.ts";
import { readWorkspaceGuardJournal } from "../guard/guard-journal.ts";
import { guardianLogText } from "./guardian-log-safety.ts";

type Json = Record<string, unknown>;

// Read-only log browser. No model, session writes, execution or approval capability.
// All grouping and presentation below use recorded facts, never new model judgments.
const VIEW_LINE_BYTES = 96 * 1024;
const VIEW_RECORDS = 30_000;
export interface GuardianLogEntry {
  value: Json;
  details: Json;
  file: string;
  line: number | null;
  order: number;
}
export interface GuardianLogReview {
  key: string;
  sessionId: string;
  container: string;
  profile: string;
  processId: string;
  reviewId: string;
  toolCallId: string;
  toolName: string;
  timestamp: string;
  events: GuardianLogEntry[];
  partial: boolean;
  sessionEnded: boolean;
  searchText: string;
}
export interface GuardianLogSnapshot {
  entries: GuardianLogEntry[];
  reviews: GuardianLogReview[];
  notices: string[];
  files: string[];
  loadedAt: string;
  malformed: number;
  duplicates: number;
  redacted: number;
}
const lvObject = (v: unknown): Json => v && typeof v === "object" && !Array.isArray(v) ? v as Json : {};
const lvString = (v: unknown, fallback = ""): string => typeof v === "string" ? v : fallback;
const lvNumber = (v: unknown): number | null => typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : null;
const lvEvent = (e: GuardianLogEntry): string => lvString(e.value.event);
const lvTime = (s: unknown): number => typeof s === "string" && Number.isFinite(Date.parse(s)) ? Date.parse(s) : 0;
function lvSafeText(s: string): string {
  // Apply to all incoming strings, including unknown fields and field names. Never
  // replay ANSI/OSC controls, hyperlinks, bidi overrides or backspaces from a log.
  return guardianLogText(s, VIEW_LINE_BYTES).replace(/\t/g, "    ").replace(/\r/g, "");
}
function lvSafeValue(v: unknown, depth = 0): unknown {
  if (typeof v === "string") return lvSafeText(v);
  if (v === null || typeof v === "boolean" || typeof v === "number") return v;
  if (depth >= 16) return "[display depth limit]";
  if (Array.isArray(v)) return v.map(x => lvSafeValue(x, depth + 1));
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([key, value]) => [lvSafeText(key),
    /password|passwd|passphrase|token|secret|api.?key|authorization|cookie|private.?key/i.test(key) && !/(?:Tokens$|^authorizationBasis$)/.test(key)
      ? "[REDACTED]" : lvSafeValue(value, depth + 1)]));
  return null;
}
function lvIdentity(e: GuardianLogEntry): string {
  return JSON.stringify([e.value.profile ?? "", e.value.sessionId ?? "", e.value.container ?? "", e.value.processId ?? ""]);
}
function lvWriter(e: GuardianLogEntry): string {
  return JSON.stringify([e.value.profile ?? "", e.value.container ?? "", e.value.processId ?? "", e.value.sessionId ?? ""]);
}
/** Public for fixture replay. Callers pass oldest retained file first. */
export function parseGuardianLogChunks(chunks: readonly { name: string; text: string; partialStart?: boolean }[], notices: string[] = []): GuardianLogSnapshot {
  const entries: GuardianLogEntry[] = [], seen = new Set<string>();
  let malformed = 0, duplicates = 0, redacted = 0, oversized = 0, unfinished = 0;
  for (const chunk of chunks) {
    const lines = chunk.text.split("\n");
    // A bounded tail may begin mid-record. Do not try to interpret that fragment.
    const from = chunk.partialStart ? 1 : 0;
    for (let n = from; n < lines.length; n++) {
      const raw = lines[n];
      if (!raw.trim()) continue;
      if (Buffer.byteLength(raw) > VIEW_LINE_BYTES) { oversized++; continue; }
      let value: Json;
      try {
        const parsed = JSON.parse(raw);
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || typeof parsed.event !== "string") throw new Error("Not a log event");
        value = parsed;
      } catch {
        if (n === lines.length - 1 && !chunk.text.endsWith("\n")) unfinished++; else malformed++;
        continue;
      }
      // Only deduplicate exact identified events, not similar messages or sequence
      // numbers reused after a process/session restart.
      if (typeof value.sequence === "number" && typeof value.timestamp === "string") {
        const identity = JSON.stringify(value);
        if (seen.has(identity)) { duplicates++; continue; }
        seen.add(identity);
      }
      const safe = lvObject(lvSafeValue(value));
      if (JSON.stringify(safe) !== JSON.stringify(value)) redacted++;
      entries.push({ value: safe, details: lvObject(safe.details), file: chunk.name, line: chunk.partialStart ? null : n + 1, order: entries.length });
    }
  }
  entries.sort((a,b)=>lvTime(a.value.timestamp)-lvTime(b.value.timestamp)||(()=>{
    const aj=lvObject(a.value.journal),bj=lvObject(b.value.journal),ar=lvString(aj.writerId),br=lvString(bj.writerId);
    return ar.localeCompare(br)||(lvNumber(aj.sequence)??0)-(lvNumber(bj.sequence)??0)||a.order-b.order;
  })());
  entries.forEach((entry,order)=>{entry.order=order;});
  const messages = [...notices];
  if (malformed) messages.push(`${malformed} malformed/non-event line(s) skipped.`);
  if (oversized) messages.push(`${oversized} oversized record(s) omitted from display.`);
  if (unfinished) messages.push(`${unfinished} incomplete trailing line(s); refresh after the writer finishes.`);
  if (duplicates) messages.push(`${duplicates} duplicate event(s) across retained files collapsed.`);
  if (redacted) messages.push(`${redacted} record(s) additionally redacted or terminal-sanitized for display.`);
  if (entries.length > VIEW_RECORDS) messages.push(`Only the newest ${VIEW_RECORDS} events are shown (display bound).`);
  const retained = entries.slice(-VIEW_RECORDS);
  const reviews = groupGuardianLogs(retained);
  return { entries: retained, reviews, notices: messages, files: chunks.map(c => c.name), loadedAt: new Date().toISOString(), malformed, duplicates, redacted };
}
/** Join by review ID plus writer/session identity. Old logs without review IDs use
 * tool ID within the observed process/session-start interval. Never join on sequence alone. */
export function groupGuardianLogs(entries: readonly GuardianLogEntry[]): GuardianLogReview[] {
  const groups = new Map<string, GuardianLogReview>(), epochs = new Map<string, string>();
  const latestCall = new Map<string, string>();
  for (const e of entries) {
    const kind = lvEvent(e), writer = lvWriter(e), identity = lvIdentity(e);
    if (kind === "session_started") {
      // Mark earlier open groups as historical without fabricating a final result.
      for (const g of groups.values()) if (lvIdentity(g.events[0]) === identity) g.sessionEnded = true;
      epochs.set(writer, lvString(e.value.timestamp, `start-${e.order}`));
      continue;
    }
    if (kind === "session_stopped") {
      for (const g of groups.values()) if (lvIdentity(g.events[0]) === identity) g.sessionEnded = true;
      continue;
    }
    const call = lvString(e.value.toolCallId, lvString(e.details.toolCallId));
    const review = lvString(e.value.reviewId);
    if (!call && !review) continue;
    const epoch = epochs.get(writer) ?? "retained-start-unknown";
    const callKey = JSON.stringify([identity, epoch, call]);
    let key: string;
    if (review) key = JSON.stringify([identity, "review", review]);
    else if (kind === "review_started" || kind === "review_skipped") key = JSON.stringify([identity, epoch, call, e.value.timestamp, e.order]);
    else key = latestCall.get(callKey) ?? JSON.stringify([identity, epoch, "partial", call]);
    let g = groups.get(key);
    if (!g) {
      g = { key, sessionId: lvString(e.value.sessionId), profile: lvString(e.value.profile), container: lvString(e.value.container),
        processId: String(e.value.processId ?? ""), reviewId: review, toolCallId: call,
        toolName: lvString(e.value.toolName, lvString(e.details.toolName)), timestamp: lvString(e.value.timestamp),
        events: [], partial: true, sessionEnded: false, searchText: "" };
      groups.set(key, g);
    }
    if (call) latestCall.set(callKey, key);
    if (!g.toolName) g.toolName = lvString(e.value.toolName, lvString(e.details.toolName));
    if (!g.toolCallId) g.toolCallId = call;
    g.events.push(e);
    if (kind === "review_started" || kind === "review_skipped") { g.partial = false; g.timestamp = lvString(e.value.timestamp, g.timestamp); }
  }
  for (const g of groups.values()) g.searchText = g.events.map(e => JSON.stringify(e.value)).join("\n").toLocaleLowerCase();
  const actualReview = (g:GuardianLogReview) => g.events.some(e => {
    const kind=lvEvent(e);
    return kind!=="review_skipped"&&(kind.startsWith("review_")||kind.startsWith("reviewer_")||kind.startsWith("model_request")||
      kind==="model_response"||kind.startsWith("step_")||kind.startsWith("evidence_")||kind==="context_selected"||kind.startsWith("instruction_")||kind==="review_context_prepared");
  });
  return [...groups.values()].filter(actualReview).sort((a, b) => lvTime(b.timestamp) - lvTime(a.timestamp) || b.events[0].order - a.events[0].order);
}
/** Snapshot bounded Guardian session journals for one workspace without writing or rotating them. */
export async function readGuardianLogs(stateDir:string,workspaceId:string,signal?:AbortSignal):Promise<GuardianLogSnapshot> {
  const journal=await readWorkspaceGuardJournal({schemaVersion:2,stateDir,workspaceId,kind:"guardian",maxRecords:VIEW_RECORDS},signal);
  const sources=new Map<string,string[]>(),chunks:{name:string;text:string}[]=[];
  for(const record of journal.records){const name=`logs/${workspaceId}/${record.source}`,lines=sources.get(name)??[];lines.push(JSON.stringify(record.value));sources.set(name,lines);}
  for(const [name,lines] of sources)chunks.push({name,text:lines.join("\n")+"\n"});
  return parseGuardianLogChunks(chunks,journal.notices.map(notice=>`Journal: ${notice}`));
}
function lvLast(g: GuardianLogReview, ...names: string[]): GuardianLogEntry | undefined {
  return [...g.events].reverse().find(e => names.includes(lvEvent(e)));
}
function lvStamp(timestamp: string): string {
  if (!lvTime(timestamp)) return "Time not recorded";
  const iso = new Date(timestamp).toISOString();
  return `${iso.slice(0, 10)} ${iso.slice(11, 19)} UTC`;
}
function lvDuration(ms: unknown): string { const n = lvNumber(ms); return n === null ? "—" : n < 1000 ? `${Math.round(n)} ms` : `${(n / 1000).toFixed(2)} s`; }
const lvBasis: Record<string, string> = { standing_rules: "Standing instructions", explicit_authorization: "Explicit user authorization", covered_work: "Supporting work within authorized scope", missing_authorization: "Missing authorization", uncertainty: "Material uncertainty", user_refusal: "Existing user restriction" };
export interface GuardianLogSummary {
  review: string; outcome: string | null; basis: string; reason: string; explanationSource: string;
  durationMs: number | null; confirmation: string; execution: string; guardianAction: string;
  releaseBasis: string; error: string; stage: string; usage: string; requests: number | null;
  action: Json; label: string; partial: boolean; reviewComplete: boolean; resultRecorded: boolean;
}
export function summarizeGuardianLog(g: GuardianLogReview): GuardianLogSummary {
  const decision = lvLast(g, "review_decision"), failure = lvLast(g, "review_unavailable");
  const finish = lvLast(g, "review_finished"), result = lvLast(g, "tool_result"), skipped = lvLast(g, "review_skipped");
  const disposition = lvLast(g, "invocation_released", "invocation_withheld");
  const answer = lvLast(g, "confirmation_answer"), asked = lvLast(g, "confirmation_requested"), disputeOpened=lvLast(g,"dispute_opened");
  const rd = result?.details ?? {}, dd = decision?.details ?? {};
  const outcomeValue = dd.outcome ?? (finish?.details.decisionAvailable === true ? finish.details.outcome : undefined) ?? rd.reviewOutcome;
  const outcome = typeof outcomeValue === "string" ? outcomeValue : null;
  const withheld = lvEvent(disposition ?? {value: {}, details: {}, file: "", line: null, order: 0}) === "invocation_withheld" || (!disposition && rd.guardianAction === "withheld");
  const releaseBasis = lvString(disposition?.details.basis, lvString(rd.releaseBasis));
  const reviewed = !!decision || finish?.details.decisionAvailable === true;
  const actionEvent = g.events.find(e => ["review_started", "review_skipped"].includes(lvEvent(e)));
  const action = lvObject(actionEvent?.details.action);
  const actionText = lvString(action.command) || lvString(action.path) || lvString(action.file_path) || lvString(action.filePath);
  const review = skipped || releaseBasis === "guardian_off" ? "Not reviewed" : failure ? "Unavailable" :
    outcome === "ALLOW" ? "Allowed" : outcome === "ASK" ? "Dispute" : outcome === "USER_REFUSED" ? "User restriction" :
    lvLast(g, "action_cancelled", "review_interrupted") ? "Cancelled" : finish ? "No valid decision" : "Not completed";
  let execution = "Result not recorded";
  if (withheld || rd.resultKind === "not_executed_by_guardian") execution = "Not executed — withheld";
  else if (result) execution = rd.isError === true || rd.resultKind === "tool_error" ? "Error reported by Pi" :
    rd.isError === false || rd.resultKind === "tool_success" ? "Success reported by Pi" : "Result recorded; status unavailable";
  else if (lvLast(g, "result_not_observed", "result_tracking_expired")) execution = "Outcome not observed";
  const guardianAction = withheld ? "Withheld" : disposition || rd.guardianAction === "released" ? "Released" : "Release not recorded";
  let confirmation = "Not recorded";
  if (answer) confirmation = answer.details.answer === "approved" || answer.value.level === "HUMAN_APPROVED" ? "Approved once" : "Declined or dismissed";
  else if (asked) confirmation = "Requested; answer not recorded";
  else if(disputeOpened)confirmation="Not used — dispute opened";
  else if (!g.partial && (reviewed || skipped) && (outcome === "ALLOW" || skipped)) confirmation = "Not requested in this trace";
  const responses = g.events.filter(e => lvEvent(e) === "model_response");
  const statuses = responses.map(e => lvString(e.details.usageStatus));
  const usage = !responses.length ? "Not recorded" : statuses.every(s => s === "reported_zero_unverified") ? "Unverified — provider returned zeros" :
    statuses.every(s => s === "reported_by_sdk") ? "Reported by SDK (per-request values in timeline)" : "Partial or unavailable (see timeline)";
  return { review, outcome, basis: lvBasis[lvString(dd.basis)] ?? lvString(dd.basis, "Not supplied"),
    reason: lvString(dd.reason, decision ? lvString(decision.value.message) : lvString(rd.reviewReason, "No accepted decision explanation recorded.")),
    explanationSource: lvString(dd.explanationSource, decision || rd.reviewReason ? "reviewer" : "not recorded"),
    durationMs: lvNumber(finish?.details.durationMs) ?? lvNumber(dd.durationMs) ?? lvNumber(failure?.details.durationMs),
    confirmation, execution, guardianAction, releaseBasis,
    error: lvString(failure?.details.error) || lvString(rd.errorExcerpt),
    stage: lvString(failure?.details.stage, lvString(finish?.details.stage)), usage,
    requests: lvNumber(finish?.details.requests) ?? lvNumber(dd.requests) ?? lvNumber(failure?.details.requests),
    action, label: `${g.toolName || "Tool"}${actionText ? ` · ${actionText.replace(/\s+/g, " ")}` : " · arguments not retained"}`,
    partial: g.partial, reviewComplete: reviewed || !!failure || !!finish || !!skipped, resultRecorded: !!result };
}
export type GuardianLogTab = "Summary" | "Command" | "Evidence" | "Timeline";
export const GUARDIAN_LOG_TABS: readonly GuardianLogTab[] = ["Summary", "Command", "Evidence", "Timeline"];
function lvPretty(v: unknown): string { return JSON.stringify(v, null, 2) ?? "Not recorded"; }
export function guardianLogDetail(g: GuardianLogReview, tab: GuardianLogTab): string[] {
  const s = summarizeGuardianLog(g), lines: string[] = [];
  const pair = (key: string, value: unknown) => lines.push(`${key.padEnd(15)} ${value ?? "Not recorded"}`);
  if (tab === "Summary") {
    pair("Time", lvStamp(g.timestamp)); pair("Review", s.review); pair("Basis", s.basis);
    pair("Review time", lvDuration(s.durationMs)); pair("Confirmation", s.confirmation); pair("Guardian", s.guardianAction);
    if (s.releaseBasis === "human_without_review") lines.push("               User bypassed an incomplete review; not an AI approval.");
    if (s.releaseBasis === "guardian_off") lines.push("               Guardian was off; no AI approval was made.");
    pair("Tool result", s.execution);
    if (s.partial) lines.push("Partial trace: beginning not retained; missing events are not reconstructed.");
    if (!s.reviewComplete) lines.push(g.sessionEnded ? "Session ended without a completed review record." : "Review not completed in this snapshot; it may be in progress or truncated.");
    if (s.review === "Unavailable") {
      pair("Cause", s.error || "Not recorded"); pair("Stage", s.stage || "Not recorded");
      pair("Model response", lvLast(g, "model_response") ? "Received; no accepted decision" : "Not recorded");
      const candidate = [...g.events].reverse().find(e => lvEvent(e) === "reviewer_function_received" && e.details.functionName === "guardian_decide");
      const proposed = lvObject(candidate?.details.arguments).outcome;
      if (typeof proposed === "string" && ["ALLOW", "ASK", "USER_REFUSED"].includes(proposed)) pair("Returned value", `${proposed} — not accepted`);
    }
    lines.push("", "Why — recorded reviewer explanation", s.reason);
    if (s.explanationSource === "extension_fallback") lines.push("[Extension-generated fallback wording; no model explanation supplied.]");
    const d = lvLast(g, "review_decision")?.details ?? {};
    if (d.effects) lines.push("", "Effects — reviewer description", lvString(d.effects));
    const ids = Array.isArray(d.userMessageIds) ? d.userMessageIds : lvLast(g, "tool_result")?.details.userMessageIds;
    if (Array.isArray(ids) && ids.length) lines.push("", `User references: ${ids.filter(x => typeof x === "string").join(", ")}`, "Open Evidence for recorded excerpts; prose message numbers are not navigation IDs.");
    if (s.error && s.review !== "Unavailable") lines.push("", "Recorded error excerpt", s.error);
    const result = lvLast(g, "tool_result");
    if (result) {
      pair("Exit code", typeof result.details.exitCode === "number" ? `${result.details.exitCode} (${lvString(result.details.exitCodeSource, "source not recorded")})` : "Not recorded");
      if (result.details.outputOmitted === true) lines.push("Successful/full tool output omitted from the log.");
    }
    lines.push("", "Release is not proof of execution success. A Pi tool report is not independent verification of remote effects.");
    const model = lvLast(g, "reviewer_selected");
    if (model) { lines.push(""); pair("Model", model.details.model); pair("Thinking", model.details.thinking); }
    pair("Token usage", s.usage);
  } else if (tab === "Command") {
    pair("Tool", g.toolName); pair("Working dir", lvString(g.events[0]?.value.cwd));
    lines.push("", "Recorded arguments (redacted preview, not guaranteed complete)");
    if (typeof s.action.command === "string") {
      lines.push(s.action.command);
      const rest = Object.fromEntries(Object.entries(s.action).filter(([k]) => k !== "command"));
      if (Object.keys(rest).length) lines.push("", "Options", lvPretty(rest));
    } else lines.push(Object.keys(s.action).length ? lvPretty(s.action) : "Arguments not retained.");
    lines.push("", "This window cannot run or approve commands. Original argument fields or suffixes may have been omitted by the logger.");
  } else if (tab === "Evidence") {
    const d = lvLast(g, "review_decision")?.details ?? {}, cited = new Set((Array.isArray(d.userMessageIds) ? d.userMessageIds : []).filter(x => typeof x === "string") as string[]);
    const sources = new Map<string, Json>();
    for (const e of g.events) {
      const arrays = [e.details.sources, e.details.messages];
      if (lvEvent(e) === "decision_evidence") arrays.push([e.details]);
      for (const a of arrays) if (Array.isArray(a)) for (const v of a) {
        const r = lvObject(v), id = lvString(r.id, lvString(r.sourceId));
        if (id && (typeof r.role === "string" || typeof r.excerpt === "string")) sources.set(id, {...sources.get(id), ...r});
      }
    }
    lines.push("Cited user messages (recorded excerpts only)");
    if (!cited.size) lines.push("No user reference retained in the accepted decision.");
    for (const id of cited) {
      const source = sources.get(id);
      lines.push("", `${id}${source ? ` · ${lvString(source.role, "role not recorded")}` : ""}`);
      lines.push(typeof source?.excerpt === "string" ? source.excerpt : "Excerpt not retained. The viewer does not fetch the conversation.");
      if (source && (source.complete === false || source.excerptIsWholeMessage === false || (lvNumber(source.characters) ?? 0) > lvString(source.excerpt).length)) lines.push("[Excerpt may be partial; not the full original message.]");
    }
    lines.push("", "Instruction references");
    const refs = g.events.filter(e => lvEvent(e) === "instruction_reference_resolved");
    if (refs.length) for (const e of refs) {
      lines.push(`${lvString(e.details.sourceId)} · ${lvString(e.details.path, "path not recorded")}`);
      if (e.details.section) lines.push(`  Locator: ${lvString(e.details.section)} (${e.details.sectionVerified === true ? "recorded as verified" : "reviewer-supplied; not verified"})`);
    } else if (Array.isArray(d.instructionRefs) && d.instructionRefs.length) lines.push(lvPretty(d.instructionRefs), "Source mapping not retained in this trace.");
    else lines.push("No instruction citations retained.");
    const loaded = g.events.filter(e => lvEvent(e) === "instruction_loaded");
    if (loaded.length) { lines.push("", "Instruction files loaded (not necessarily cited)"); for (const e of loaded) lines.push(`${lvString(e.details.path)} · ${lvString(e.details.scope)} · ${e.details.characters ?? "?"} characters`); }
    lines.push("", "Evidence operations / files actually inspected");
    const evidence = g.events.filter(e => ["file_evidence", "file_read_complete", "file_inspection_failed", "file_search_result", "history_search_result", "evidence_requested", "evidence_returned", "inspection_finished"].includes(lvEvent(e)) ||
      (lvEvent(e) === "reviewer_function_received" && e.details.functionName !== "guardian_decide"));
    if (!evidence.length) lines.push("No separate evidence operation retained. A path in a command is not proof of a guardian file read.");
    for (const e of evidence) lines.push(`${lvStamp(lvString(e.value.timestamp))} ${lvEvent(e)}`, lvPretty(e.details));
    lines.push("", `Context sources retained: ${sources.size}. Source identity does not establish that the reviewer interpreted it correctly.`);
  } else if (tab === "Timeline") {
    lines.push("Times UTC · durations overlap/nest; they are not added together.", "");
    const paired = new Map<unknown, GuardianLogEntry>(), functions = new Map<unknown, GuardianLogEntry>();
    const startIds = new Set(g.events.filter(e => lvEvent(e) === "step_started").map(e => e.details.stepId));
    const functionStarts = new Set(g.events.filter(e => lvEvent(e) === "reviewer_function_started").map(e => e.details.functionCallId));
    for (const e of g.events) {
      if (/^step_(finished|failed|cancelled)$/.test(lvEvent(e))) paired.set(e.details.stepId, e);
      if (lvEvent(e) === "reviewer_function_finished") functions.set(e.details.functionCallId, e);
    }
    for (const e of g.events) {
      const kind = lvEvent(e), t = lvStamp(lvString(e.value.timestamp));
      if (kind === "step_started") {
        const end = paired.get(e.details.stepId);
        lines.push(`${t}  ${lvString(e.details.operation, lvString(e.value.message))} · ${end ? `${lvEvent(end).slice(5)} · ${lvDuration(end.details.durationMs)}` : "no terminal event retained"}`);
        if (e.details.requestedPath || e.details.path) lines.push(`          ${e.details.requestedPath ?? e.details.path}`);
        if (end?.details.error) lines.push(`          ${end.details.error}`);
      } else if (kind.startsWith("step_") && paired.get(e.details.stepId) === e && startIds.has(e.details.stepId)) continue;
      else if (kind === "reviewer_function_started") {
        const end = functions.get(e.details.functionCallId);
        const duration = end ? Math.max(0, lvTime(end.value.timestamp) - lvTime(e.value.timestamp)) : null;
        lines.push(`${t}  ${lvString(e.details.functionName, "Private function")} · ${end ? `${end.details.isError === true ? "failed" : "finished"} · ${lvDuration(duration)}` : "no terminal event retained"}`);
        lines.push(`          Call ${lvString(e.details.functionCallId)}`);
        if (end?.details.error) lines.push(`          ${end.details.error}`);
      } else if (kind === "reviewer_function_finished" && functionStarts.has(e.details.functionCallId)) continue;
      else {
        lines.push(`${t}  ${kind} · ${lvString(e.value.message)}`);
        // Raw metadata is expanded only for meaningful model/evidence/decision events.
        if (["model_request", "model_response", "reviewer_function_received", "reviewer_validation_failed", "review_unavailable", "review_decision", "confirmation_answer", "tool_result", "history_search_result", "file_evidence"].includes(kind)) lines.push(lvPretty(e.details));
      }
    }
  }
  lines.push("", `Session: ${g.sessionId || "not recorded"}`, `Container: ${g.container || "not recorded"} · process ${g.processId || "?"}`,
    `Review: ${g.reviewId || "legacy — no review ID"}`, `Tool call: ${g.toolCallId || "not recorded"}`);
  return lines.flatMap(line => lvSafeText(line).split("\n"));
}

async function flushGuardianLogView(flush:()=>Promise<void>,signal:AbortSignal):Promise<void>{
  signal.throwIfAborted();let timer:ReturnType<typeof setTimeout>|undefined,rejectAbort:(reason?:unknown)=>void=()=>{};
  const task=flush(),abort=()=>rejectAbort(signal.reason);task.catch(()=>{});
  try{await Promise.race([task,new Promise<void>(resolve=>{timer=setTimeout(resolve,500);}),new Promise<never>((_resolve,reject)=>{rejectAbort=reject;signal.addEventListener("abort",abort,{once:true});if(signal.aborted)abort();})]);signal.throwIfAborted();}
  finally{if(timer)clearTimeout(timer);signal.removeEventListener("abort",abort);}
}
export function createGuardianLogViewRequest(stateDir:string,workspaceId:string,flush:()=>Promise<void>,initialQuery=""):GuardViewRequestV1{
  let snapshot:GuardianLogSnapshot|undefined;
  return {
    schemaVersion:1,
    title:"Guardian reviews · current workspace · UTC",
    compactTitle:"Guardian reviews",
    wideHeader:"  UTC date/time             Decision        Duration  Reviewed command",
    initialQuery:lvSafeText(initialQuery).replace(/[\r\n\t]/g," ").slice(0,300),
    fallbackText:`Guardian journals: ${join(stateDir,"logs",workspaceId)} (viewer requires Pi's terminal UI).`,
    unavailableText:"Guardian log viewer needs Pi's custom terminal UI.",
    emptyText:"No Guardian reviews retained. Commands skipped while Guardian was Off are hidden.",
    noMatchesText:"No reviews match this search.",
    missingSelectionText:"Selected review is no longer retained.",
    incompleteNoticeText:"review list may be incomplete",
    sections:GUARDIAN_LOG_TABS.map(label=>({id:label.toLowerCase(),label})),
    async load(signal){
      await flushGuardianLogView(flush,signal);snapshot=await readGuardianLogs(stateDir,workspaceId,signal);
      return {schemaVersion:1,loadedAt:snapshot.loadedAt,notices:snapshot.notices,rows:snapshot.reviews.map(review=>{
        const summary=summarizeGuardianLog(review),suffix=review.partial?" [partial]":"";
        return {id:review.key,searchText:review.searchText,
          wide:`${lvStamp(review.timestamp)}  ${summary.review.padEnd(15)} ${lvDuration(summary.durationMs).padStart(8)}  ${summary.label}${suffix}`,
          compact:`${lvStamp(review.timestamp)} ${summary.review} · ${summary.label}${suffix}`};
      })};
    },
    details(rowId,sectionId){
      const review=snapshot?.reviews.find(candidate=>candidate.key===rowId);
      const tab=GUARDIAN_LOG_TABS.find(candidate=>candidate.toLowerCase()===sectionId);
      return review&&tab?guardianLogDetail(review,tab):["Selected review no longer retained. Esc returns to the list."];
    },
  };
}
