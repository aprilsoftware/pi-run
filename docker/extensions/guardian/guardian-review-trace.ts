// SPDX-License-Identifier: MIT
import { createWorkspaceGuardJournalWriter } from "../guard/guard-journal.ts";
import { guardianLogText, guardianLogValue } from "./guardian-log-safety.ts";
import type { EvidenceLogLevel as LogLevel, LogSink } from "../guard/guard-evidence.ts";

export function errorText(e: unknown): string { return e instanceof Error ? e.message : String(e); }
async function abortable<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) { void work.catch(()=>{}); signal.throwIfAborted(); }
  let cancel!: () => void;
  try { return await Promise.race([work,new Promise<never>((_,reject)=>{cancel=()=>reject(signal.reason ?? new Error("Cancelled"));signal.addEventListener("abort",cancel,{once:true});if(signal.aborted)cancel();})]); }
  finally { signal.removeEventListener("abort",cancel); }
}
const DEFAULT_REVIEW_BUDGET = { totalMs: 210_000, slowMs: 15_000 };
export const MAX_LOG_BYTES = 1024 * 1024;
export const LOG_BACKUPS = 2;
export type { LogLevel };

export function actionPreview(input: Record<string, unknown>): Record<string, unknown> {
  // Deliberately exclude edited file bodies, patches, environment values and all
  // arbitrary custom-tool fields. A bounded shell command/path is useful for diagnosis.
  const preview: Record<string, unknown> = {};
  for (const key of ["command", "path", "file_path", "filePath", "cwd", "timeout", "offset", "limit", "mode"]) {
    if (typeof input[key] === "string" || typeof input[key] === "number") preview[key] = input[key];
  }
  return preview;
}

function record(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" ? value as Record<string, unknown> : {};
}
export function toolResultDetails(value: unknown, isError: boolean, toolName: string): Record<string, unknown> {
  const result = record(value), details = record(result.details);
  let exitCode: number | null = null, exitCodeSource: string | null = null;
  for (const [name, candidate] of [["details.exitCode", details.exitCode], ["result.exitCode", result.exitCode]] as const) {
    if (typeof candidate === "number" && Number.isInteger(candidate)) { exitCode = candidate; exitCodeSource = name; break; }
  }
  let errorExcerpt: string | null = null, errorSource: string | null = null;
  if (isError) {
    const message = (v: unknown) => typeof v === "string" ? v : typeof record(v).message === "string" ? record(v).message as string : "";
    let raw = "";
    for (const [source, candidate] of [["details.error", details.error], ["result.error", result.error],
      ["details.stderr", details.stderr], ["result.stderr", result.stderr]] as const) {
      raw = message(candidate);
      if (raw.trim()) { errorSource = source; break; }
    }
    if (!raw.trim() && (value instanceof Error || typeof value === "string")) {
      raw = message(value); errorSource = "result";
    }
    if (!raw.trim() && Array.isArray(result.content)) {
      const texts = result.content.filter(c => record(c).type === "text" && typeof record(c).text === "string")
        .map(c => record(c).text as string);
      // Never process an unbounded body just for logging. Do not cut a secret
      // halfway through before redaction: oversized error bodies are omitted.
      if (texts.reduce((n, text) => n + text.length + 1, 0) <= 256 * 1024) raw = texts.join("\n");
      else { errorExcerpt = "[Error text exceeds diagnostic size limit; inspect the tool result in Pi.]"; errorSource = "omitted_oversize"; }
      if (raw.trim()) errorSource = "tool_text";
    }
    if (raw.length > 256 * 1024) {
      errorExcerpt = "[Error text exceeds diagnostic size limit; inspect the tool result in Pi.]"; errorSource = "omitted_oversize";
    } else if (raw.trim()) {
      errorExcerpt = guardianLogText(raw, 2200, true);
      // Older built-in bash supplies this exact final line rather than structured
      // exit metadata. Label its origin; arbitrary custom-tool text is not parsed.
      const match = toolName === "bash" ? raw.match(/(?:^|\n)Command exited with code (-?\d+)\s*$/) : null;
      if (exitCode === null && match && Number.isSafeInteger(Number(match[1]))) {
        exitCode = Number(match[1]); exitCodeSource = "bash_error_text";
      }
    }
  }
  return { isError, exitCode, exitCodeSource, errorExcerpt, errorSource,
    errorDetailStatus: !isError ? "not_applicable" : errorSource === "omitted_oversize" ? "omitted_size_limit" :
      errorExcerpt ? "available_excerpt" : "not_supplied_by_tool",
    outputOmitted: !isError || !errorExcerpt || errorSource === "omitted_oversize" };
}

export function createLogger(stateDir:string,workspaceId:string,sessionId:string,warn:(message:string)=>void,
  limits:{maxBytes?:number;backups?:number}={}) {
  const writer=createWorkspaceGuardJournalWriter({schemaVersion:2,stateDir,workspaceId,sessionId,kind:"guardian",
    maxBytes:limits.maxBytes??MAX_LOG_BYTES,backups:limits.backups??LOG_BACKUPS},message=>{
    try{warn(`${message.replace(/^Guard journal unavailable:/,"Guardian logging unavailable:")}. Reviews and dispute enforcement are unchanged. See /guardian for log status.`);}
    catch{/* UI errors must not affect the review. */}
  });
  return {
    workspaceId,sessionId,path:writer.path,
    status:()=>{const health=writer.health();return health.lastError?`unavailable; ${health.dropped} record(s) not written: ${health.lastError}`:
      `${health.written?"enabled":"waiting for first write"}${health.dropped?`; ${health.dropped} earlier record(s) not written`:""}${health.pending?`; ${health.pending} pending`:""}`;},
    health:writer.health,
    write(entry:Record<string,unknown>){
      try{const safe=guardianLogValue(entry);writer.write(safe&&typeof safe==="object"&&!Array.isArray(safe)?safe as Record<string,unknown>:undefined as never);}
      catch{writer.write(undefined as never);}
    },
    flush:writer.flush,close:writer.close,
  };
}

// Every trace step is diagnostic. No result here can authorize an action.
type OpenStep = { id: number; name: string; started: number; details: Record<string, unknown> };
export class ReviewTimeoutError extends Error {
  readonly stage?: string;
  constructor(message: string, stage?: string) { super(message); this.name = "ReviewTimeoutError"; this.stage = stage; }
}
export class ReviewTrace {
  private nextId = 0;
  private open = new Map<number, OpenStep>();
  private closed = false;
  private lastStage = "preparing review";
  constructor(privateEmit: LogSink, signal: AbortSignal, deadlineAt: number, update?: (stage: string) => void) {
    this.emit = privateEmit; this.signal = signal; this.deadlineAt = deadlineAt; this.update = update;
  }
  private readonly emit: LogSink;
  readonly signal: AbortSignal;
  readonly deadlineAt: number;
  private readonly update?: (stage: string) => void;
  stage(): string { return [...this.open.values()].at(-1)?.name ?? this.lastStage; }
  pending(): Record<string, unknown>[] {
    return [...this.open.values()].map(s => ({ stepId: s.id, operation: s.name, elapsedMs: Date.now() - s.started }));
  }
  private finish(s: OpenStep, outcome: "finished" | "failed" | "cancelled", error?: unknown) {
    if (!this.open.delete(s.id)) return;
    this.lastStage = s.name;
    this.emit(outcome === "failed" ? "ERROR" : outcome === "cancelled" ? "CANCELLED" : "INFO", `step_${outcome}`,
      `${s.name}: ${outcome}`, { stepId: s.id, operation: s.name, durationMs: Date.now() - s.started,
        ...(error === undefined ? {} : { error: errorText(error), timedOut: error instanceof ReviewTimeoutError }) });
    this.update?.(this.stage());
  }
  async step<T>(name: string, details: Record<string, unknown>, work: (signal: AbortSignal) => Promise<T>, timeoutMs?: number): Promise<T> {
    this.signal.throwIfAborted();
    if (this.closed) throw new Error("Review trace is closed");
    if (Date.now() >= this.deadlineAt) throw new ReviewTimeoutError(`Review deadline already reached before ${name}`, name);
    const s: OpenStep = { id: ++this.nextId, name, details, started: Date.now() };
    const abort = new AbortController();
    const signal = AbortSignal.any([this.signal, abort.signal]);
    const available = Math.max(1, this.deadlineAt - Date.now());
    const limit = Math.min(available, timeoutMs ?? available);
    this.open.set(s.id, s);
    this.emit("INFO", "step_started", `${name}: started`, { stepId: s.id, operation: name, limitMs: limit, ...details });
    this.update?.(name);
    const timer = setTimeout(() => abort.abort(new ReviewTimeoutError(`${name} exceeded ${(limit / 1000).toFixed(1)} seconds; no completed decision from this operation`, name)), limit);
    try {
      const value = await abortable(Promise.resolve().then(() => { signal.throwIfAborted(); return work(signal); }), signal);
      signal.throwIfAborted();
      if (this.closed) throw new Error("Review trace closed before step completion");
      if (Date.now() - s.started >= limit) throw new ReviewTimeoutError(`${name} completed after its ${limit / 1000}-second limit; result discarded`, name);
      this.finish(s, "finished"); return value;
    } catch (e) { this.finish(s, signal.aborted ? "cancelled" : "failed", e); throw e; }
    finally { clearTimeout(timer); abort.abort(new Error("Step finished")); }
  }
  close(error?: unknown) {
    if (this.closed) return;
    this.closed = true;
    for (const step of [...this.open.values()].reverse()) this.finish(step, "cancelled", error ?? new Error("Review closed"));
  }
}
export function validBudget(raw?: { totalMs: number; slowMs: number }): { totalMs: number; slowMs: number } {
  const b = raw ?? DEFAULT_REVIEW_BUDGET;
  if (![b.totalMs, b.slowMs].every(n => Number.isSafeInteger(n) && n > 0) || b.totalMs > 600_000 || b.slowMs > b.totalMs) {
    throw new Error("Invalid reviewer time budget (maximum 600 seconds)");
  }
  return b;
}

// Keep prompts short without concealing a destructive suffix or other arguments.
export function visible(text: string): string { return text.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, c => `\\u${c.charCodeAt(0).toString(16).padStart(4,"0")}`); }
export function oneLine(text: string, limit: number): string {
  const clean = visible(text).replace(/\s+/g, " ").trim();
  return clean.length > limit ? clean.slice(0, limit - 1) + "…" : clean;
}
export function guardianDiagnosticReference(journalPath?:string):string{
  return journalPath?`Diagnostic journal: ${journalPath}.`:"Guardian diagnostics are unavailable.";
}
export function reviewFailureSummary(error:string,journalPath?:string):string{
  const detail=guardianDiagnosticReference(journalPath);
  if(/timed? out|timeout|exceeded.*seconds/i.test(error))return `Review timed out. ${detail}`;
  if(/reviewer response|decision|userMessageIds|instructionRefs|list argument/i.test(error))return `Reviewer response was invalid. ${detail}`;
  return `Review could not complete. ${detail}`;
}
