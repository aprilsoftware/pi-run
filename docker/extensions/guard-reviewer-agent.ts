// SPDX-License-Identifier: MIT
import type { Api, Model } from "@earendil-works/pi-ai";

export type AgenticThinking = "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | "max";
export type AgenticJson = Record<string, unknown>;
export interface AgenticReviewMetrics { requests?: number; evidenceCalls?: number; inputBytes?: number; }
export type AgenticReviewResult<Decision> =
  | { status: "completed"; decision: Decision; metrics?: AgenticReviewMetrics }
  | { status: "incomplete"; error: string; metrics?: AgenticReviewMetrics };
export interface NativeAgentLike {
  state: { messages: any[]; tools?: any[]; error?: string; errorMessage?: string };
  prompt(message: any): Promise<void>;
  abort(): void;
  followUp(message: any): void;
  subscribe(fn: (event: any) => void): (() => void);
}
export interface PiInfrastructure {
  Agent: new (options: any) => NativeAgentLike;
  ai: { createAssistantMessageEventStream(): any; streamSimple?: (...args: any[]) => any; completeSimple?: (...args: any[]) => Promise<any> };
}
export async function loadPiInfrastructure(): Promise<PiInfrastructure> {
  const [core, ai] = await Promise.all([import("@earendil-works/pi-agent-core"), import("@earendil-works/pi-ai")]);
  if (typeof core.Agent !== "function" || typeof ai.createAssistantMessageEventStream !== "function") {
    throw new Error("This Pi installation does not expose Agent + createAssistantMessageEventStream");
  }
  return { Agent: core.Agent as unknown as PiInfrastructure["Agent"], ai: ai as unknown as PiInfrastructure["ai"] };
}
export type ProviderStream = (model: Model<Api>, context: any, options: any) => any;
export interface AgenticEvidenceDefinition<Evidence> {
  name: string;
  label?: string;
  description: string;
  parameters: unknown;
  execute(evidence: Evidence, args: AgenticJson): Promise<unknown>;
}
export interface AgenticReviewDomain<Request, Evidence, Decision> {
  id: string;
  systemPrompt(request: Request): string;
  evidenceTools: readonly AgenticEvidenceDefinition<Evidence>[];
  decisionTool: { name: string; label: string; description: string; parameters: unknown };
  initialPrompt(request: Request, evidence: Evidence): unknown;
  prepareContext(context: any, evidence: Evidence, state: { final: boolean; evidenceToolNames: readonly string[] }): void;
  requestDetails?(evidence: Evidence): AgenticJson;
  normalizeDecision(value: unknown, evidence: Evidence): Decision;
  decisionDetails(decision: Decision): AgenticJson;
  isEvidenceBudgetError(error: unknown): boolean;
}
export interface AgenticReviewServices<Evidence> {
  readonly signal: AbortSignal;
  readonly deadlineAt: number;
  readonly evidence: Evidence;
  step<T>(name: string, details: AgenticJson, work: (signal: AbortSignal) => Promise<T>, timeoutMs?: number): Promise<T>;
  report(event: { level: "INFO" | "INVESTIGATE" | "ERROR"; event: string; message: string; details?: AgenticJson; metrics?: AgenticReviewMetrics }): void;
}
export interface AgenticReviewerOptions<Request, Evidence, Decision> {
  model: Model<Api>;
  thinking: AgenticThinking;
  requestedThinking: AgenticThinking;
  modelSource: string;
  thinkingSource: string;
  domain: AgenticReviewDomain<Request, Evidence, Decision>;
  infrastructure?: () => Promise<PiInfrastructure>;
  provider(signal: AbortSignal, step: AgenticReviewServices<Evidence>["step"]): Promise<{ stream: ProviderStream; model: Model<Api>; options?: AgenticJson }>;
}

const MAX_CONTEXT_BYTES = 96 * 1024;
const MAX_CUMULATIVE_BYTES = 320 * 1024;
const MAX_MODEL_REQUESTS = 4;
const MAX_EVIDENCE_CALLS = 10;
type ReviewerPhase = "investigating" | "decision-only" | "completed" | "closed";

function errorText(value: unknown): string { return value instanceof Error ? value.message : String(value); }
function clip(text: string, limit: number): string {
  if (text.length <= limit) return text;
  const mark = "\n[excerpt: original remains retrievable]\n", size = Math.max(0, Math.floor((limit - mark.length) / 2));
  return text.slice(0, size) + mark + text.slice(-size);
}
function toolResultText(message: any): string {
  const content = message?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.map((part: any) => part?.type === "text" && typeof part.text === "string" ? part.text : "").filter(Boolean).join("\n");
}
async function abortable<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) { void work.catch(() => {}); signal.throwIfAborted(); }
  let cancel!: () => void;
  try {
    return await Promise.race([work, new Promise<never>((_, reject) => {
      cancel = () => reject(signal.reason ?? new Error("Cancelled"));
      signal.addEventListener("abort", cancel, { once: true }); if (signal.aborted) cancel();
    })]);
  } finally { signal.removeEventListener("abort", cancel); }
}
function usageDetails(usage: unknown): AgenticJson {
  const value = usage && typeof usage === "object" && !Array.isArray(usage) ? usage as Record<string, unknown> : {};
  const count = (name: string) => typeof value[name] === "number" && Number.isFinite(value[name]) && (value[name] as number) >= 0 ? value[name] as number : null;
  const values = { inputTokens: count("input"), outputTokens: count("output"), cacheReadTokens: count("cacheRead"), cacheWriteTokens: count("cacheWrite") };
  const supplied = Object.values(values).filter((number): number is number => number !== null);
  return { ...values, usageStatus: !supplied.length ? "not_reported" : supplied.every(number => number === 0) ? "reported_zero_unverified" : "reported_by_sdk" };
}
function extractDecisionJson(message: any): unknown {
  const text = (message.content ?? []).filter((part: any) => part.type === "text").map((part: any) => part.text).join("").trim();
  const fenced = text.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/i); return JSON.parse(fenced ? fenced[1] : text);
}
function emptyReply(model: Model<Api>, stopReason = "stop", errorMessage?: string): any {
  return { role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id, timestamp: Date.now(), stopReason, errorMessage,
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
}

export class AgenticGuardReviewer<Request, Evidence, Decision> {
  readonly id: string;
  readonly budget: { totalMs: number; slowMs: number };
  constructor(readonly options: AgenticReviewerOptions<Request, Evidence, Decision>) {
    this.id = options.domain.id;
    this.budget = { totalMs: ["high", "xhigh", "max"].includes(options.thinking) ? 270_000 : 180_000, slowMs: 15_000 };
  }
  async review(request: Request, services: AgenticReviewServices<Evidence>): Promise<AgenticReviewResult<Decision>> {
    const metrics: Required<AgenticReviewMetrics> = { requests: 0, evidenceCalls: 0, inputBytes: 0 };
    const options = this.options, domain = options.domain, evidence = services.evidence;
    let agent: NativeAgentLike | undefined, completed: Decision | undefined;
    let lastError = "Reviewer did not supply a decision", corrections = 0, latestCalls: any[] = [];
    let phase: ReviewerPhase = "investigating";
    const emit = (level: "INFO" | "INVESTIGATE" | "ERROR", event: string, message: string, details?: AgenticJson) =>
      services.report({ level, event, message, details, metrics });
    const onAbort = () => agent?.abort(); services.signal.addEventListener("abort", onAbort, { once: true });
    try {
      const infrastructure = await services.step("load Pi reviewer infrastructure", {},
        () => (options.infrastructure ?? loadPiInfrastructure)(), 15000);
      services.signal.throwIfAborted();
      emit("INFO", "reviewer_selected", "Private Pi Agent, fresh review transcript", {
        model: `${options.model.provider}/${options.model.id}`, thinking: options.thinking,
        requestedThinking: options.requestedThinking, modelSource: options.modelSource, thinkingSource: options.thinkingSource,
      });
      const definitions = domain.evidenceTools;
      const executeEvidence = (definition: AgenticEvidenceDefinition<Evidence>) => async (_id: string, args: AgenticJson, signal?: AbortSignal) => {
        services.signal.throwIfAborted(); signal?.throwIfAborted();
        if (phase === "completed" || phase === "closed") throw new Error("Review has finished");
        if (phase === "decision-only") throw new Error("Final request is decision-only; no new inspection is available");
        if (++metrics.evidenceCalls > MAX_EVIDENCE_CALLS) throw new Error("Evidence call budget exhausted; decide from available evidence");
        try {
          const value = await definition.execute(evidence, args);
          return { content: [{ type: "text", text: JSON.stringify(value) }], details: { evidence: true } };
        } catch (cause) {
          if (domain.isEvidenceBudgetError(cause)) phase = "decision-only";
          throw cause;
        }
      };
      const accept = (raw: unknown) => {
        const decision = domain.normalizeDecision(raw, evidence); services.signal.throwIfAborted();
        if (phase === "completed" || phase === "closed") throw new Error("Review closed");
        emit("INFO", "decision_validated", "Source identities validated; semantic judgment remains the reviewer's", domain.decisionDetails(decision));
        completed = decision; phase = "completed";
      };
      const decisionTool = { ...domain.decisionTool,
        execute: async (_id: string, args: AgenticJson, signal?: AbortSignal) => {
          services.signal.throwIfAborted(); signal?.throwIfAborted();
          if (latestCalls.length !== 1) throw new Error("A final decision must not be mixed with investigation calls");
          try { accept(args); }
          catch (cause) { lastError = errorText(cause); emit("ERROR", "decision_validation_failed", "Decision not accepted", { error: lastError }); throw cause; }
          return { content: [{ type: "text", text: "Decision accepted. Review complete." }], details: { completed: true }, terminate: true };
        } };
      const tools = [...definitions.map(definition => ({ name: definition.name, label: definition.label ?? definition.name,
        description: definition.description, parameters: definition.parameters, execute: executeEvidence(definition) })), decisionTool];
      const streamFn = (_model: any, context: any, providerOptions: any) => {
        const output = infrastructure.ai.createAssistantMessageEventStream();
        if (phase === "completed" || phase === "closed" || services.signal.aborted) {
          const done = phase === "completed", reply = emptyReply(options.model, done ? "stop" : "aborted");
          if (done) output.push({ type: "start", partial: reply });
          output.push(done ? { type: "done", reason: "stop", message: reply } : { type: "error", reason: "aborted", error: reply }); output.end(reply); return output;
        }
        void (async () => {
          let ended = false;
          try {
            if (metrics.requests >= MAX_MODEL_REQUESTS) throw new Error("Reviewer request budget exhausted");
            const round = ++metrics.requests, remaining = services.deadlineAt - Date.now();
            const final = phase === "decision-only" || round === MAX_MODEL_REQUESTS || metrics.evidenceCalls >= MAX_EVIDENCE_CALLS || remaining < 75_000;
            if (final) phase = "decision-only";
            const send = JSON.parse(JSON.stringify(context));
            if (send.tools && final) send.tools = send.tools.filter((tool: any) => tool.name === domain.decisionTool.name);
            domain.prepareContext(send, evidence, { final, evidenceToolNames: definitions.map(definition => definition.name) });
            const bytes = Buffer.byteLength(JSON.stringify(send)); metrics.inputBytes += bytes;
            if (bytes > MAX_CONTEXT_BYTES || metrics.inputBytes > MAX_CUMULATIVE_BYTES) throw new Error("Review context budget exhausted; no authority silently omitted");
            emit("INFO", "model_request", "Pi reviewer request started", { round, requestBytes: bytes, cumulativeBytes: metrics.inputBytes,
              finalDecisionOnly: final, remainingMs: remaining, ...(domain.requestDetails?.(evidence) ?? {}) });
            const requestLimit = Math.min(["high", "xhigh", "max"].includes(options.thinking) ? 120_000 : 60_000, Math.max(1, remaining));
            const response = await services.step(`model request ${round}`, { round, requestBytes: bytes }, async signal => {
              const provider = await options.provider(signal, services.step); signal.throwIfAborted();
              const caps: Record<AgenticThinking, number> = { off: 1536, minimal: 3072, low: 4096, medium: 12288, high: 24576, xhigh: 32768, max: 32768 };
              const source = await provider.stream(provider.model, send, { ...providerOptions, ...provider.options, signal,
                reasoning: options.thinking === "off" ? undefined : options.thinking, maxTokens: Math.min(caps[options.thinking], options.model.maxTokens), maxRetries: 0 });
              const iterator = source[Symbol.asyncIterator](); let count = 0, lastProgress = 0;
              try {
                for (;;) {
                  const next = await abortable(Promise.resolve(iterator.next()), signal); if (next.done) break; signal.throwIfAborted();
                  const event = next.value; count++;
                  if (count === 1 || Date.now() - lastProgress > 10000) {
                    lastProgress = Date.now(); emit("INFO", "model_progress", "Stream activity; content not logged", { round, eventType: event.type, events: count });
                  }
                  if (event.type !== "done" && event.type !== "error") output.push(event);
                }
                const message = await abortable(Promise.resolve(source.result()), signal); signal.throwIfAborted(); return message;
              } finally { if (signal.aborted) try { void Promise.resolve(iterator.return?.()).catch(() => {}); } catch {} }
            }, requestLimit);
            services.signal.throwIfAborted();
            emit("INFO", "model_response", "Pi reviewer response received", { round, stopReason: response.stopReason,
              ...usageDetails(response.usage), responseTypes: (response.content ?? []).map((block: any) => block.type) });
            if (response.stopReason === "error" || response.stopReason === "aborted") output.push({ type: "error", reason: response.stopReason, error: response });
            else output.push({ type: "done", reason: response.stopReason, message: response });
            output.end(response); ended = true;
          } catch (cause) {
            lastError = errorText(cause); emit("ERROR", "model_request_failed", "Request did not produce a usable response", { error: lastError, decisionAvailable: false });
            const reply = emptyReply(options.model, services.signal.aborted ? "aborted" : "error", lastError);
            output.push({ type: "error", reason: reply.stopReason, error: reply }); output.end(reply); ended = true;
          } finally {
            if (!ended) { const reply = emptyReply(options.model, "error", "Stream closed unexpectedly"); output.push({ type: "error", reason: "error", error: reply }); output.end(reply); }
          }
        })(); return output;
      };
      agent = new infrastructure.Agent({ initialState: { model: options.model, thinkingLevel: options.thinking,
        systemPrompt: domain.systemPrompt(request), tools, messages: [] }, streamFn, toolExecution: "sequential",
        transformContext: async (messages: any[]) => messages,
        beforeToolCall: async (call: any) => {
          if (phase === "completed" || phase === "closed" || services.signal.aborted) return { block: true, reason: "Review finished or cancelled" };
          const calls = call.assistantMessage?.content?.filter((block: any) => block.type === "toolCall") ?? [];
          if (calls.some((block: any) => block.name === domain.decisionTool.name) && calls.length !== 1) return { block: true, reason: "Return a final decision alone, not with evidence calls" };
          return undefined;
        }, finishTurn: () => phase === "completed" ? { action: "end" } : undefined });
      const unsubscribe = agent.subscribe((event: any) => {
        if (phase === "closed") return;
        if (event.type === "message_end" && event.message?.role === "assistant") {
          const message = event.message; latestCalls = (message.content ?? []).filter((block: any) => block.type === "toolCall");
          if (!["toolUse", "stop", "error", "aborted"].includes(message.stopReason)) {
            lastError = `Reviewer response ended with ${String(message.stopReason)}; no complete decision accepted`;
            phase = "closed"; emit("ERROR", "incomplete_model_response", "Truncated/deferred response cannot authorize execution", { stopReason: message.stopReason });
          }
          for (const call of latestCalls) emit("INFO", "reviewer_function_received", "Native Pi private tool call", { functionName: call.name, functionCallId: call.id, arguments: call.arguments });
          if (phase !== "completed" && !latestCalls.length && message.stopReason === "stop") {
            try { accept(extractDecisionJson(message)); }
            catch (cause) {
              lastError = errorText(cause); emit("ERROR", "decision_validation_failed", "Final JSON not accepted", { error: lastError });
              if (++corrections <= 1 && metrics.requests < MAX_MODEL_REQUESTS) agent?.followUp({ role: "user", timestamp: Date.now(),
                content: `Harness validation error (not user authority): ${lastError}. Correct the decision or retrieve the missing evidence. No new permission is granted.` });
            }
          } else if (message.stopReason === "error" || message.stopReason === "aborted") lastError = message.errorMessage || lastError;
        }
        if (event.type === "tool_execution_start") emit("INVESTIGATE", "reviewer_function_started", "Private function started",
          { functionName: event.toolName, functionCallId: event.toolCallId, arguments: event.args });
        if (event.type === "tool_execution_end") emit(event.isError ? "ERROR" : "INFO", "reviewer_function_finished", "Private function completed",
          { functionName: event.toolName, functionCallId: event.toolCallId, isError: event.isError,
            error: event.isError ? clip(toolResultText({ content: event.result?.content }), 800) : undefined, contentsLogged: false });
      });
      try {
        await abortable(agent.prompt({ role: "user", timestamp: Date.now(), content: JSON.stringify(domain.initialPrompt(request, evidence)) }), services.signal);
        services.signal.throwIfAborted();
        if (!completed) throw new Error(agent.state.errorMessage || agent.state.error || lastError);
        return { status: "completed", decision: completed, metrics };
      } finally { unsubscribe(); }
    } catch (cause) {
      return { status: "incomplete", error: clip(errorText(cause), 4000), metrics };
    } finally {
      phase = "closed"; services.signal.removeEventListener("abort", onAbort); agent?.abort();
    }
  }
}
