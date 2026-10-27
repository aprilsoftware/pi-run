// SPDX-License-Identifier: MIT
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import { createAgenticGuardReviewBackend, defaultGuardReviewerConfig, effectiveAgenticThinking, GUARD_REVIEWER_THINKING_LEVELS, resolveGuardReviewerConfig,
  saveGuardReviewerConfig, supportedAgenticThinking, type AgenticThinking, type GuardReviewerConfig,
  type ResolvedGuardReviewerConfig } from "./guard-reviewer-agent.ts";
import { openGuardView, validateGuardViewRequest, type GuardViewRequestV1 } from "./guard-viewer.ts";
export type { GuardViewRequestV1, GuardViewRowV1, GuardViewSectionV1, GuardViewSnapshotV1 } from "./guard-viewer.ts";

export const GUARD_RUNTIME_KIND = "pi-run.guard-runtime";
export const GUARD_RUNTIME_VERSION = 1 as const;
export const GUARD_RUNTIME_AVAILABLE = "pi-run:guard-runtime:v1:available";
export const GUARD_RUNTIME_DISCOVER = "pi-run:guard-runtime:v1:discover";
export const GUARD_REVIEW_RUNTIME_KIND = "pi-run.guard-review-runtime";
export const GUARD_REVIEW_RUNTIME_VERSION = 1 as const;
export const GUARD_REVIEW_RUNTIME_AVAILABLE = "pi-run:guard-review-runtime:v1:available";
export const GUARD_REVIEW_RUNTIME_DISCOVER = "pi-run:guard-review-runtime:v1:discover";

export interface GuardClientRegistrationV1 { schemaVersion: 1; id: string; label: string; reviewerControl?: true; }
export interface GuardReviewClientRegistrationV1 extends GuardClientRegistrationV1 {
  evidenceProfile: string;
  decisionContract: string;
}
export interface GuardReviewRequestV1 { schemaVersion: 1; action: unknown; policy: unknown; }
export interface GuardReviewDiagnosticV1 { schemaVersion: 1; level: "INFO" | "INVESTIGATE" | "ERROR" | "CANCELLED"; event: string; message: string; details?: unknown; }
export interface GuardReviewDiagnosticSnapshotV1 extends GuardReviewDiagnosticV1 { clientId: string; sequence: number; }
export interface GuardReviewOptionsV1 { signal?: AbortSignal; report?(event: Readonly<GuardReviewDiagnosticSnapshotV1>): void; }
export type GuardReviewResultV1 =
  | { schemaVersion: 1; status: "completed"; decision: Readonly<Record<string, unknown>> }
  | { schemaVersion: 1; status: "incomplete"; error: string };
export interface GuardReviewBackendRequestV1 extends GuardReviewRequestV1 {
  client: Readonly<GuardReviewClientRegistrationV1>;
}
export interface GuardReviewBackendContextV1 {
  readonly signal: AbortSignal;
  report(event: GuardReviewDiagnosticV1): void;
}
export interface GuardReviewBackendV1 {
  review(request: Readonly<GuardReviewBackendRequestV1>, context: Readonly<GuardReviewBackendContextV1>): Promise<unknown>;
}
export interface GuardReviewClientHandleV1 {
  readonly id: string;
  active(): boolean;
  review(request: GuardReviewRequestV1, options?: GuardReviewOptionsV1): Promise<Readonly<GuardReviewResultV1>>;
  dispose(): void;
}
export interface GuardReviewRuntimeV1 {
  readonly kind: typeof GUARD_REVIEW_RUNTIME_KIND;
  readonly schemaVersion: typeof GUARD_REVIEW_RUNTIME_VERSION;
  registerClient(registration: GuardReviewClientRegistrationV1): GuardReviewClientHandleV1;
  clients(): readonly Readonly<GuardReviewClientRegistrationV1>[];
}
export interface GuardReviewClientConnectionV1 {
  connected(): boolean;
  runtime(): GuardReviewRuntimeV1 | undefined;
  review(request: GuardReviewRequestV1, options?: GuardReviewOptionsV1): Promise<Readonly<GuardReviewResultV1>>;
  dispose(): void;
}
export interface GuardRuntimeOptions { reviewer?: GuardReviewBackendV1; }
export type GuardReviewModeV1 = "unknown" | "on" | "off";
export interface GuardActivityRequestV1 { schemaVersion: 1; state: string; detail?: string; right?: string; surface?: "guard" | "client"; }
export interface GuardReviewerSettingsV1 {
  schemaVersion: 1;
  config: Readonly<GuardReviewerConfig>;
  source: ResolvedGuardReviewerConfig["source"];
  modelAvailable: boolean;
  effectiveThinking: AgenticThinking;
}
export interface GuardReviewerControlRequestV1 { schemaVersion: 1; setting: "model" | "thinking"; value?: string; }
export interface GuardReviewerControlResultV1 { schemaVersion: 1; status: "shown" | "applied" | "cancelled"; settings: Readonly<GuardReviewerSettingsV1>; }
export interface GuardActivitySnapshotV1 extends GuardActivityRequestV1 { clientId: string; sequence: number; }
export interface GuardActivityLeaseV1 {
  readonly clientId: string;
  active(): boolean;
  snapshot(): Readonly<GuardActivitySnapshotV1>;
  update(activity: GuardActivityRequestV1): void;
  end(): void;
}
export interface GuardClientHandleV1 {
  readonly id: string;
  active(): boolean;
  setBaseline(activity: GuardActivityRequestV1 | undefined): void;
  acquireActivity(activity: GuardActivityRequestV1, signal?: AbortSignal): Promise<GuardActivityLeaseV1>;
  openView?(request: GuardViewRequestV1): Promise<void>;
  closeView?(): void;
  reviewerSettings?(): Promise<Readonly<GuardReviewerSettingsV1>>;
  configureReviewer?(request: GuardReviewerControlRequestV1): Promise<Readonly<GuardReviewerControlResultV1>>;
  dispose(): void;
}
export interface GuardRuntimeV1 {
  readonly kind: typeof GUARD_RUNTIME_KIND;
  readonly schemaVersion: typeof GUARD_RUNTIME_VERSION;
  registerClient(registration: GuardClientRegistrationV1): GuardClientHandleV1;
  clients(): readonly Readonly<GuardClientRegistrationV1>[];
  activity(): Readonly<GuardActivitySnapshotV1> | undefined;
  status(): Readonly<GuardActivitySnapshotV1> | undefined;
  subscribeActivity(listener: (activity: Readonly<GuardActivitySnapshotV1> | undefined) => void): () => void;
  subscribeStatus(listener: (status: Readonly<GuardActivitySnapshotV1> | undefined) => void): () => void;
  reviewMode(): GuardReviewModeV1;
  setReviewMode(mode: Exclude<GuardReviewModeV1, "unknown">): void;
  subscribeReviewMode(listener: (mode: GuardReviewModeV1) => void): () => void;
}
export interface GuardClientConnectionV1 {
  connected(): boolean;
  runtime(): GuardRuntimeV1 | undefined;
  reviewMode(): GuardReviewModeV1;
  setReviewMode(mode: Exclude<GuardReviewModeV1, "unknown">): void;
  subscribeReviewMode(listener: (mode: GuardReviewModeV1) => void): () => void;
  setBaseline(activity: GuardActivityRequestV1 | undefined): void;
  acquireActivity(activity: GuardActivityRequestV1, signal?: AbortSignal): Promise<GuardActivityLeaseV1>;
  openView(request: GuardViewRequestV1): Promise<void>;
  closeView(): void;
  reviewerSettings(): Promise<Readonly<GuardReviewerSettingsV1>>;
  configureReviewer(request: GuardReviewerControlRequestV1): Promise<Readonly<GuardReviewerControlResultV1>>;
  dispose(): void;
}
type ConnectionCallbacks = { connected?(runtime: GuardRuntimeV1): void; error?(error: Error): void; };
type ReviewConnectionCallbacks = { connected?(runtime: GuardReviewRuntimeV1): void; error?(error: Error): void; };
type DiscoveryV1 = { schemaVersion: 1; accept(runtime: GuardRuntimeV1): void };
type ReviewDiscoveryV1 = { schemaVersion: 1; accept(runtime: GuardReviewRuntimeV1): void };
type ClientEntry = { token: symbol; registration: Readonly<GuardClientRegistrationV1> };
type ReviewClientEntry = { token: symbol; registration: Readonly<GuardReviewClientRegistrationV1> };
type PendingActivity = {
  clientId: string; clientToken: symbol; activity: Readonly<GuardActivityRequestV1>; signal?: AbortSignal;
  abort?: () => void; resolve(lease: GuardActivityLeaseV1): void; reject(error: Error): void;
};
type PendingReview = {
  clientId: string;
  clientToken: symbol;
  request: Readonly<GuardReviewBackendRequestV1>;
  options: Readonly<GuardReviewOptionsV1>;
  abort?: () => void;
  diagnosticsClosed: boolean;
  diagnosticCount: number;
  diagnosticBytes: number;
  diagnosticError?: Error;
  resolve(result: Readonly<GuardReviewResultV1>): void;
};

function error(value: unknown, fallback = "Guard Runtime operation failed"): Error {
  return value instanceof Error ? value : new Error(value === undefined ? fallback : String(value));
}
function safeError(value: unknown, fallback: string): string {
  const text = error(value, fallback).message.replace(/[\u0000-\u001f\u007f]/g, " ").trim();
  return (text || fallback).slice(0, 4000);
}
function identifier(value: unknown): value is string {
  return typeof value === "string" && /^[a-z][a-z0-9-]{0,63}(?:\.[a-z][a-z0-9-]{0,63})*\.v[1-9][0-9]*$/.test(value);
}
function validateRegistration(value: GuardClientRegistrationV1): Readonly<GuardClientRegistrationV1> {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      !["id,label,schemaVersion","id,label,reviewerControl,schemaVersion"].includes(Object.keys(value).sort().join(",")) || value.schemaVersion !== 1 ||
      typeof value.id !== "string" || !/^[a-z][a-z0-9-]{0,63}$/.test(value.id) ||
      typeof value.label !== "string" || value.label !== value.label.trim() || !value.label ||
      value.label.length > 80 || /[\u0000-\u001f\u007f]/.test(value.label) ||
      (Object.hasOwn(value,"reviewerControl") && value.reviewerControl !== true)) {
    throw new Error("Invalid Guard Runtime client registration");
  }
  return Object.freeze({ ...value });
}
function validateReviewRegistration(value: GuardReviewClientRegistrationV1): Readonly<GuardReviewClientRegistrationV1> {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).sort().join(",") !== "decisionContract,evidenceProfile,id,label,schemaVersion" ||
      value.schemaVersion !== 1 || typeof value.id !== "string" || !/^[a-z][a-z0-9-]{0,63}$/.test(value.id) ||
      typeof value.label !== "string" || value.label !== value.label.trim() || !value.label || value.label.length > 80 ||
      /[\u0000-\u001f\u007f]/.test(value.label) || !identifier(value.evidenceProfile) || !identifier(value.decisionContract)) {
    throw new Error("Invalid Guard review client registration");
  }
  return Object.freeze({ ...value });
}
function validateJson(value: unknown, depth = 0, nodes = { value: 0 }): void {
  if (++nodes.value > 10000 || depth > 32) throw new Error("Guard review JSON exceeds structural bounds");
  if (value === null || typeof value === "string" || typeof value === "boolean") return;
  if (typeof value === "number" && Number.isFinite(value)) return;
  if (Array.isArray(value)) { for (const item of value) validateJson(item, depth + 1, nodes); return; }
  if (typeof value !== "object" || Object.getPrototypeOf(value) !== Object.prototype) {
    throw new Error("Guard review values must be plain JSON");
  }
  for (const [key, item] of Object.entries(value as Record<string, unknown>)) {
    if (!key || /[\u0000-\u001f\u007f]/.test(key)) throw new Error("Guard review JSON has an invalid key");
    validateJson(item, depth + 1, nodes);
  }
}
function frozenJson<T>(value: T, maxBytes = 128 * 1024, label = "Guard review request"): Readonly<T> {
  validateJson(value);
  const encoded = JSON.stringify(value);
  if (Buffer.byteLength(encoded, "utf8") > maxBytes) throw new Error(`${label} exceeds ${Math.floor(maxBytes / 1024)} KiB`);
  const copy = JSON.parse(encoded) as T;
  const freeze = (item: unknown): void => {
    if (!item || typeof item !== "object" || Object.isFrozen(item)) return;
    Object.freeze(item); for (const child of Object.values(item)) freeze(child);
  };
  freeze(copy); return copy as Readonly<T>;
}
function validateReviewRequest(value: GuardReviewRequestV1, client: Readonly<GuardReviewClientRegistrationV1>): Readonly<GuardReviewBackendRequestV1> {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).sort().join(",") !== "action,policy,schemaVersion" || value.schemaVersion !== 1) {
    throw new Error("Invalid Guard review request");
  }
  return frozenJson({ schemaVersion: 1 as const, client, action: value.action, policy: value.policy });
}
function validateReviewOptions(value: GuardReviewOptionsV1 | undefined): Readonly<GuardReviewOptionsV1> {
  if (value === undefined) return Object.freeze({});
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.getPrototypeOf(value) !== Object.prototype ||
      Object.keys(value).some(key => !["signal", "report"].includes(key)) ||
      (value.signal !== undefined && !(value.signal instanceof AbortSignal)) ||
      (value.report !== undefined && typeof value.report !== "function")) throw new Error("Invalid Guard review options");
  return Object.freeze({ ...(value.signal ? { signal: value.signal } : {}), ...(value.report ? { report: value.report } : {}) });
}
function validateDiagnostic(value: GuardReviewDiagnosticV1, clientId: string, sequence: number): Readonly<GuardReviewDiagnosticSnapshotV1> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid Guard review diagnostic");
  const hasDetails = Object.hasOwn(value, "details"), keys = Object.keys(value).sort().join(",");
  if (keys !== (hasDetails ? "details,event,level,message,schemaVersion" : "event,level,message,schemaVersion") || value.schemaVersion !== 1 ||
      !["INFO", "INVESTIGATE", "ERROR", "CANCELLED"].includes(value.level) || typeof value.event !== "string" ||
      !/^[a-z][a-z0-9_]{0,63}$/.test(value.event) || typeof value.message !== "string" || value.message !== value.message.trim() ||
      !value.message || value.message.length > 2400 || /[\u0000-\u001f\u007f]/.test(value.message)) throw new Error("Invalid Guard review diagnostic");
  const details = hasDetails ? frozenJson(value.details, 16 * 1024, "Guard review diagnostic details") : undefined;
  return Object.freeze({ schemaVersion: 1, level: value.level, event: value.event, message: value.message,
    ...(hasDetails ? { details } : {}), clientId, sequence });
}
function incompleteReview(cause: unknown, fallback = "Guard reviewer unavailable"): Readonly<GuardReviewResultV1> {
  return Object.freeze({ schemaVersion: 1, status: "incomplete", error: safeError(cause, fallback) });
}
function validateReviewResult(value: unknown): Readonly<GuardReviewResultV1> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid Guard review result");
  const row = value as Record<string, unknown>, keys = Object.keys(row).sort().join(",");
  if (row.schemaVersion !== 1) throw new Error("Invalid Guard review result");
  if (row.status === "completed" && keys === "decision,schemaVersion,status" && row.decision &&
      typeof row.decision === "object" && !Array.isArray(row.decision)) {
    const result = frozenJson({ schemaVersion: 1 as const, status: "completed" as const, decision: row.decision as Record<string, unknown> });
    if (Buffer.byteLength(JSON.stringify(result), "utf8") > 64 * 1024) throw new Error("Guard review result exceeds 64 KiB");
    return result;
  }
  if (row.status === "incomplete" && keys === "error,schemaVersion,status" && typeof row.error === "string" && row.error.trim() && row.error.length <= 4000) {
    return Object.freeze({ schemaVersion: 1, status: "incomplete", error: row.error });
  }
  throw new Error("Invalid Guard review result");
}
function validateActivity(value: GuardActivityRequestV1): Readonly<GuardActivityRequestV1> {
  const validText = (text: unknown) => typeof text === "string" && text === text.trim() && !!text &&
    text.length <= 120 && !/[\u0000-\u001f\u007f]/.test(text);
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).some(key => !["schemaVersion", "state", "detail", "right", "surface"].includes(key)) ||
      value.schemaVersion !== 1 || typeof value.state !== "string" ||
      !/^[a-z][a-z0-9-]{0,31}$/.test(value.state) ||
      (value.detail !== undefined && !validText(value.detail)) ||
      (value.right !== undefined && !validText(value.right)) ||
      (value.surface !== undefined && value.surface !== "guard" && value.surface !== "client")) {
    throw new Error("Invalid Guard Runtime activity");
  }
  return Object.freeze({ ...value });
}
function isReviewRuntime(value: unknown): value is GuardReviewRuntimeV1 {
  const candidate = value as Partial<GuardReviewRuntimeV1> | null;
  return !!candidate && candidate.kind === GUARD_REVIEW_RUNTIME_KIND && candidate.schemaVersion === GUARD_REVIEW_RUNTIME_VERSION &&
    typeof candidate.registerClient === "function" && typeof candidate.clients === "function";
}
function isRuntime(value: unknown): value is GuardRuntimeV1 {
  const candidate = value as Partial<GuardRuntimeV1> | null;
  return !!candidate && candidate.kind === GUARD_RUNTIME_KIND && candidate.schemaVersion === GUARD_RUNTIME_VERSION &&
    typeof candidate.registerClient === "function" && typeof candidate.clients === "function" &&
    typeof candidate.activity === "function" && typeof candidate.status === "function" &&
    typeof candidate.subscribeActivity === "function" && typeof candidate.subscribeStatus === "function" &&
    typeof candidate.reviewMode === "function" && typeof candidate.setReviewMode === "function" && typeof candidate.subscribeReviewMode === "function";
}
function renderStatusRow(label:string,activity: Readonly<GuardActivitySnapshotV1> | undefined, width: number): string {
  const safeWidth = Number.isFinite(width) ? Math.max(1, Math.floor(width)) : 1;
  const state = activity?.state.replaceAll("-", " ") ?? "ready";
  const left = `${label} · ${state}${activity?.detail ? ` ${activity.detail}` : ""}`;
  if (visibleWidth(left) >= safeWidth) return truncateToWidth(left, safeWidth, "…");
  const available = safeWidth - visibleWidth(left) - 2;
  if (!activity?.right || available < 12) return left;
  const right = truncateToWidth(activity.right, available, "…");
  return left + " ".repeat(Math.max(2, safeWidth - visibleWidth(left) - visibleWidth(right))) + right;
}
export function renderGuardStatus(activity: Readonly<GuardActivitySnapshotV1> | undefined, width: number): string{return renderStatusRow("guard",activity,width);}
export function renderGuardStatusRows(rows:readonly Readonly<{id:string;activity:Readonly<GuardActivitySnapshotV1>}>[],width:number):string[]{
  if(!rows.length)return [renderStatusRow("guard",undefined,width)];
  return rows.map(row=>renderStatusRow(row.id==="guardian"?"guard":row.id,row.activity,width));
}

export function connectGuardClient(
  pi: Pick<ExtensionAPI, "events" | "on">,
  registration: GuardClientRegistrationV1,
  callbacks: ConnectionCallbacks = {},
): GuardClientConnectionV1 {
  const definition = validateRegistration(registration);
  let handle: GuardClientHandleV1 | undefined, selected: GuardRuntimeV1 | undefined, disposed = false;
  const accept = (candidate: unknown) => {
    if (disposed || !isRuntime(candidate) || handle?.active()) return;
    try {
      handle = candidate.registerClient(definition); selected = candidate;
      callbacks.connected?.(candidate);
    } catch (cause) { callbacks.error?.(error(cause)); }
  };
  const stopAvailable = pi.events.on(GUARD_RUNTIME_AVAILABLE, accept);
  const stopShutdown = pi.on("session_shutdown", () => connection.dispose());
  const connection: GuardClientConnectionV1 = Object.freeze({
    connected: () => !disposed && !!handle?.active(),
    runtime: () => !disposed && handle?.active() ? selected : undefined,
    reviewMode: () => !disposed && handle?.active() && selected ? selected.reviewMode() : "unknown",
    setReviewMode(mode) {
      if (!handle?.active() || !selected) throw new Error("Guard Runtime client is unavailable");
      selected.setReviewMode(mode);
    },
    subscribeReviewMode(listener) {
      if (!handle?.active() || !selected) throw new Error("Guard Runtime client is unavailable");
      return selected.subscribeReviewMode(listener);
    },
    setBaseline(activity) {
      if (!handle?.active()) throw new Error("Guard Runtime client is unavailable");
      handle.setBaseline(activity);
    },
    acquireActivity: (activity, signal) => handle?.active()
      ? handle.acquireActivity(activity, signal)
      : Promise.reject(new Error("Guard Runtime client is unavailable")),
    openView: request => handle?.active() && handle.openView
      ? handle.openView(request)
      : Promise.reject(new Error("Guard Runtime viewer is unavailable")),
    closeView() { if (handle?.active()) handle.closeView?.(); },
    reviewerSettings: () => handle?.active() && handle.reviewerSettings
      ? handle.reviewerSettings()
      : Promise.reject(new Error("Guard Runtime reviewer settings are unavailable")),
    configureReviewer: request => handle?.active() && handle.configureReviewer
      ? handle.configureReviewer(request)
      : Promise.reject(new Error("Guard Runtime reviewer controls are unavailable")),
    dispose() {
      if (disposed) return;
      disposed = true; handle?.dispose(); stopAvailable(); stopShutdown();
    },
  });
  pi.events.emit(GUARD_RUNTIME_DISCOVER, { schemaVersion: 1, accept } satisfies DiscoveryV1);
  return connection;
}

export function connectGuardReviewClient(
  pi: Pick<ExtensionAPI, "events" | "on">,
  registration: GuardReviewClientRegistrationV1,
  callbacks: ReviewConnectionCallbacks = {},
): GuardReviewClientConnectionV1 {
  const definition = validateReviewRegistration(registration);
  let handle: GuardReviewClientHandleV1 | undefined, selected: GuardReviewRuntimeV1 | undefined, disposed = false;
  const accept = (candidate: unknown) => {
    if (disposed || !isReviewRuntime(candidate) || handle?.active()) return;
    try { handle = candidate.registerClient(definition); selected = candidate; callbacks.connected?.(candidate); }
    catch (cause) { callbacks.error?.(error(cause)); }
  };
  const stopAvailable = pi.events.on(GUARD_REVIEW_RUNTIME_AVAILABLE, accept);
  const stopShutdown = pi.on("session_shutdown", () => connection.dispose());
  const connection: GuardReviewClientConnectionV1 = Object.freeze({
    connected: () => !disposed && !!handle?.active(),
    runtime: () => !disposed && handle?.active() ? selected : undefined,
    review: (request, options) => handle?.active()
      ? handle.review(request, options)
      : Promise.resolve(incompleteReview(new Error("Guard review runtime is unavailable"))),
    dispose() { if (disposed) return; disposed = true; handle?.dispose(); stopAvailable(); stopShutdown(); },
  });
  pi.events.emit(GUARD_REVIEW_RUNTIME_DISCOVER, { schemaVersion: 1, accept } satisfies ReviewDiscoveryV1);
  return connection;
}

export function createGuardRuntimeExtension(options: GuardRuntimeOptions = {}) {
  if (options.reviewer !== undefined && (!options.reviewer || typeof options.reviewer.review !== "function")) {
    throw new Error("Invalid Guard reviewer backend");
  }
  return function guardRuntime(pi: ExtensionAPI) {
  const stateDir=process.env.PI_RUN_PROFILE_DIR||"/profile";
  const clients = new Map<string, ClientEntry>(), waiting: PendingActivity[] = [];
  const reviewClients = new Map<string, ReviewClientEntry>(), reviewWaiting: PendingReview[] = [];
  const baselines = new Map<string, { clientToken: symbol; order: number; snapshot: Readonly<GuardActivitySnapshotV1> }>();
  const activityListeners = new Set<(activity: Readonly<GuardActivitySnapshotV1> | undefined) => void>();
  const statusListeners = new Set<(status: Readonly<GuardActivitySnapshotV1> | undefined) => void>();
  const reviewModeListeners = new Set<(mode: GuardReviewModeV1) => void>();
  let closed = false, sequence = 0, baselineOrder = 0, reviewDiagnosticSequence = 0, reviewMode:GuardReviewModeV1 = "unknown";
  let statusContext: ExtensionContext | undefined, statusRedraw: (() => void) | undefined;
  let statusRows:readonly Readonly<{id:string;activity:Readonly<GuardActivitySnapshotV1>}>[]=[], stopStatus: (() => void) | undefined;
  let current: { clientToken: symbol; leaseToken: symbol; snapshot: Readonly<GuardActivitySnapshotV1> } | undefined;
  let currentReview: { pending: PendingReview; controller: AbortController } | undefined;
  let currentView: { clientToken: symbol; controller: AbortController } | undefined;
  const selectedBaseline = () => [...baselines.values()].sort((a, b) => b.order - a.order)[0]?.snapshot;
  const effectiveStatus = () => current?.snapshot ?? selectedBaseline();
  const effectiveStatusRows=():readonly Readonly<{id:string;activity:Readonly<GuardActivitySnapshotV1>}>[]=>{
    const rows=new Map<string,Readonly<GuardActivitySnapshotV1>>([...baselines].map(([id,value])=>[id,value.snapshot]));
    if(current){const target=current.snapshot.surface==="guard"?"guardian":current.snapshot.clientId,baseline=rows.get(target);
      rows.set(target,Object.freeze({...baseline,...current.snapshot,...(!current.snapshot.right&&baseline?.right?{right:baseline.right}:{}),clientId:target}));}
    const order=(id:string)=>id==="guardian"?0:id==="caf"?1:2;
    return Object.freeze([...rows].sort(([left],[right])=>order(left)-order(right)||left.localeCompare(right)).map(([id,activity])=>Object.freeze({id,activity})));
  };
  const notify = (listeners: Set<(value: Readonly<GuardActivitySnapshotV1> | undefined) => void>,
    value: Readonly<GuardActivitySnapshotV1> | undefined) => {
    for (const listener of listeners) try { listener(value); } catch { /* Presentation cannot affect ownership. */ }
  };
  const publishActivity = () => notify(activityListeners, current?.snapshot);
  const publishStatus = () => notify(statusListeners, effectiveStatus());
  const publish = () => { publishActivity(); publishStatus(); };
  const rejectWaiting = (predicate: (pending: PendingActivity) => boolean, cause: Error) => {
    for (let index = waiting.length - 1; index >= 0; index--) {
      const pending = waiting[index];
      if (!predicate(pending)) continue;
      waiting.splice(index, 1); if (pending.abort && pending.signal) pending.signal.removeEventListener("abort", pending.abort);
      pending.reject(cause);
    }
  };
  const activateNext = (): boolean => {
    while (!closed && !current && waiting.length) {
      const pending = waiting.shift()!;
      if (pending.abort && pending.signal) pending.signal.removeEventListener("abort", pending.abort);
      if (pending.signal?.aborted || clients.get(pending.clientId)?.token !== pending.clientToken) {
        pending.reject(error(pending.signal?.reason, "Guard Runtime activity cancelled")); continue;
      }
      const leaseToken = Symbol(pending.clientId);
      let leaseSnapshot: Readonly<GuardActivitySnapshotV1> = Object.freeze({
        ...pending.activity, clientId: pending.clientId, sequence: ++sequence,
      });
      current = { clientToken: pending.clientToken, leaseToken, snapshot: leaseSnapshot };
      const active = () => !closed && current?.leaseToken === leaseToken;
      const finish = () => {
        if (!active()) return;
        current = undefined;
        if (!activateNext()) publish();
      };
      const lease: GuardActivityLeaseV1 = Object.freeze({
        clientId: pending.clientId,
        active,
        snapshot: () => leaseSnapshot,
        update(value) {
          if (!active()) throw new Error("Guard Runtime activity lease is not active");
          leaseSnapshot = Object.freeze({ ...validateActivity(value), clientId: pending.clientId, sequence: ++sequence });
          current!.snapshot = leaseSnapshot; publish();
        },
        end: finish,
      });
      publish(); pending.resolve(lease); return true;
    }
    return false;
  };
  const acquire = (entry: ClientEntry, value: GuardActivityRequestV1, signal?: AbortSignal) => {
    let activity: Readonly<GuardActivityRequestV1>;
    try { activity = validateActivity(value); }
    catch (cause) { return Promise.reject(error(cause)); }
    if (closed || clients.get(entry.registration.id)?.token !== entry.token) {
      return Promise.reject(new Error("Guard Runtime client is unavailable"));
    }
    if (signal?.aborted) return Promise.reject(error(signal.reason, "Guard Runtime activity cancelled"));
    return new Promise<GuardActivityLeaseV1>((resolve, reject) => {
      const pending: PendingActivity = { clientId: entry.registration.id, clientToken: entry.token, activity, signal, resolve, reject };
      if (signal) {
        pending.abort = () => rejectWaiting(candidate => candidate === pending,
          error(signal.reason, "Guard Runtime activity cancelled"));
        signal.addEventListener("abort", pending.abort, { once: true });
      }
      waiting.push(pending); activateNext();
    });
  };
  const setBaseline = (entry: ClientEntry, value: GuardActivityRequestV1 | undefined) => {
    if (closed || clients.get(entry.registration.id)?.token !== entry.token) {
      throw new Error("Guard Runtime client is unavailable");
    }
    if (value === undefined) baselines.delete(entry.registration.id);
    else baselines.set(entry.registration.id, {
      clientToken: entry.token, order: ++baselineOrder,
      snapshot: Object.freeze({ ...validateActivity(value), clientId: entry.registration.id, sequence: ++sequence }),
    });
    if (!current) publishStatus();
  };
  const closeView = (entry?: ClientEntry, reason = "Guard viewer closed") => {
    if (!currentView || (entry && currentView.clientToken !== entry.token)) return;
    const controller = currentView.controller; currentView = undefined;
    controller.abort(new Error(reason));
  };
  const openView = (entry: ClientEntry, value: GuardViewRequestV1): Promise<void> => {
    let request: GuardViewRequestV1;
    try { request = validateGuardViewRequest(value); }
    catch (cause) { return Promise.reject(error(cause)); }
    if (closed || clients.get(entry.registration.id)?.token !== entry.token) {
      return Promise.reject(new Error("Guard Runtime client is unavailable"));
    }
    if (currentView) return Promise.resolve();
    const ctx = statusContext;
    if (!ctx) return Promise.reject(new Error("Guard Runtime viewer context is unavailable"));
    const controller = new AbortController(); currentView = { clientToken: entry.token, controller };
    return openGuardView(ctx, { request, signal: controller.signal }).finally(() => {
      if (currentView?.controller === controller) currentView = undefined;
      controller.abort(new Error("Guard viewer finished"));
    });
  };
  const resolvedReviewerSettings=(ctx:ExtensionContext,resolved:ResolvedGuardReviewerConfig):Readonly<GuardReviewerSettingsV1>=>{
    const configured=resolved.config.model,slash=configured?.indexOf("/")??-1;
    const model=configured&&slash>0?ctx.modelRegistry.find(configured.slice(0,slash),configured.slice(slash+1)):undefined,requested=resolved.config.thinking??"low";
    return Object.freeze({schemaVersion:1,config:Object.freeze({...resolved.config}),source:resolved.source,modelAvailable:!!model,
      effectiveThinking:model?effectiveAgenticThinking(model,requested):requested});
  };
  const reviewerSettings = async (entry:ClientEntry):Promise<Readonly<GuardReviewerSettingsV1>> => {
    if(closed||clients.get(entry.registration.id)?.token!==entry.token)throw new Error("Guard Runtime client is unavailable");
    const ctx=statusContext;if(!ctx)throw new Error("Guard Runtime reviewer context is unavailable");
    const resolved=await resolveGuardReviewerConfig(stateDir);
    if(closed||clients.get(entry.registration.id)?.token!==entry.token||statusContext!==ctx)throw new Error("Guard Runtime reviewer context changed");
    return resolvedReviewerSettings(ctx,resolved);
  };
  const configureReviewer = async (entry:ClientEntry,value:GuardReviewerControlRequestV1):Promise<Readonly<GuardReviewerControlResultV1>> => {
    if(closed||clients.get(entry.registration.id)?.token!==entry.token)throw new Error("Guard Runtime client is unavailable");
    if(entry.registration.reviewerControl!==true)throw new Error("Guard Runtime reviewer controls are unavailable for this client");
    if(!value||typeof value!=="object"||Array.isArray(value))throw new Error("Invalid Guard reviewer control request");
    const hasValue=Object.hasOwn(value,"value"),keys=Object.keys(value).sort().join(",");
    if(keys!==(hasValue?"schemaVersion,setting,value":"schemaVersion,setting")||value.schemaVersion!==1||
      !["model","thinking"].includes(value.setting)||(hasValue&&(typeof value.value!=="string"||!value.value.trim()||value.value!==value.value.trim()||value.value.length>512||/[\u0000-\u001f\u007f]/.test(value.value))))
      throw new Error("Invalid Guard reviewer control request");
    const ctx=statusContext;if(!ctx)throw new Error("Guard Runtime reviewer context is unavailable");
    let resolved:ResolvedGuardReviewerConfig;try{resolved=await resolveGuardReviewerConfig(stateDir);}catch{resolved={config:defaultGuardReviewerConfig(),source:"default"};}
    if(closed||clients.get(entry.registration.id)?.token!==entry.token||statusContext!==ctx)throw new Error("Guard Runtime reviewer context changed");
    const before=resolvedReviewerSettings(ctx,resolved),available=ctx.modelRegistry.getAvailable();let selected=value.value;
    if(value.setting==="model"){
      if(selected===undefined){
        if(!ctx.hasUI)return Object.freeze({schemaVersion:1,status:"shown",settings:before});
        const choices=[{value:"default",label:`No reviewer selected${!before.config.model?" [current]":""}`},...available.map(model=>({value:`${model.provider}/${model.id}`,label:`${model.provider}/${model.id}${before.config.model===`${model.provider}/${model.id}`?" [current]":""}`}))];
        const answer=await ctx.ui.select("Guardian model",choices.map(choice=>choice.label));
        if(statusContext!==ctx)throw new Error("Guard Runtime session changed during reviewer selection");
        if(answer===undefined)return Object.freeze({schemaVersion:1,status:"cancelled",settings:before});
        selected=choices.find(choice=>choice.label===answer)?.value;
        if(!selected)throw new Error("Invalid Guard reviewer model selection");
      }
      if(selected!=="default"){const slash=selected.indexOf("/");if(slash<1||!ctx.modelRegistry.find(selected.slice(0,slash),selected.slice(slash+1)))throw new Error("Unknown model");}
    }else{
      const configured=before.config.model,slash=configured?.indexOf("/")??-1,model=configured&&slash>0?ctx.modelRegistry.find(configured.slice(0,slash),configured.slice(slash+1)):undefined;
      const supported=model?supportedAgenticThinking(model):[...GUARD_REVIEWER_THINKING_LEVELS];
      if(selected===undefined){
        if(!ctx.hasUI)return Object.freeze({schemaVersion:1,status:"shown",settings:before});
        const choices=[{value:"default",label:`Use Guard default — low${!before.config.thinking?" [current]":""}`},...supported.map(thinking=>({value:thinking,label:(thinking==="off"?"Off — review remains enabled":thinking[0].toUpperCase()+thinking.slice(1))+(before.config.thinking===thinking?" [current]":"")}))];
        const answer=await ctx.ui.select("Guardian thinking",choices.map(choice=>choice.label));
        if(statusContext!==ctx)throw new Error("Guard Runtime session changed during reviewer selection");
        if(answer===undefined)return Object.freeze({schemaVersion:1,status:"cancelled",settings:before});
        selected=choices.find(choice=>choice.label===answer)?.value;
        if(!selected)throw new Error("Invalid Guard reviewer thinking selection");
      }
      if(selected!=="default"&&!supported.includes(selected as AgenticThinking))throw new Error("Thinking level not supported by this reviewer model");
    }
    const config:GuardReviewerConfig=value.setting==="model"?{...before.config,model:selected==="default"?null:selected!,schemaVersion:1}:
      {...before.config,thinking:selected==="default"?null:selected as AgenticThinking,schemaVersion:1};
    if(closed||clients.get(entry.registration.id)?.token!==entry.token||statusContext!==ctx)throw new Error("Guard Runtime reviewer context changed");
    const changed=before.source!=="guard_file"||JSON.stringify(config)!==JSON.stringify(before.config);
    if(changed)await saveGuardReviewerConfig(stateDir,config);
    const settings=changed?resolvedReviewerSettings(ctx,{config,source:"guard_file"}):before;
    return Object.freeze({schemaVersion:1,status:"applied",settings});
  };
  const removeClient = (entry: ClientEntry) => {
    if (clients.get(entry.registration.id)?.token !== entry.token) return;
    closeView(entry, "Guard Runtime client was disposed");
    clients.delete(entry.registration.id);
    if (baselines.get(entry.registration.id)?.clientToken === entry.token) baselines.delete(entry.registration.id);
    rejectWaiting(value => value.clientToken === entry.token, new Error("Guard Runtime client was disposed"));
    if (current?.clientToken === entry.token) {
      current = undefined;
      if (!activateNext()) publish();
    } else if (!current) publishStatus();
  };
  const service: GuardRuntimeV1 = Object.freeze({
    kind: GUARD_RUNTIME_KIND,
    schemaVersion: GUARD_RUNTIME_VERSION,
    registerClient(value) {
      if (closed) throw new Error("Guard Runtime is unavailable");
      const registration = validateRegistration(value);
      if (clients.has(registration.id)) throw new Error(`Guard Runtime client already registered: ${registration.id}`);
      const entry: ClientEntry = { token: Symbol(registration.id), registration };
      clients.set(registration.id, entry);
      return Object.freeze({
        id: registration.id,
        active: () => !closed && clients.get(registration.id)?.token === entry.token,
        setBaseline: activity => setBaseline(entry, activity),
        acquireActivity: (activity, signal) => acquire(entry, activity, signal),
        openView: request => openView(entry, request),
        closeView: () => closeView(entry),
        reviewerSettings: () => reviewerSettings(entry),
        configureReviewer: request => configureReviewer(entry,request),
        dispose: () => removeClient(entry),
      });
    },
    clients: () => Object.freeze([...clients.values()].map(entry => entry.registration)
      .sort((a, b) => a.id.localeCompare(b.id))),
    activity: () => current?.snapshot,
    status: effectiveStatus,
    subscribeActivity(listener) {
      if (typeof listener !== "function") throw new Error("Invalid Guard Runtime activity listener");
      if (closed) throw new Error("Guard Runtime is unavailable");
      activityListeners.add(listener); try { listener(current?.snapshot); } catch { /* Presentation cannot affect ownership. */ }
      return () => activityListeners.delete(listener);
    },
    subscribeStatus(listener) {
      if (typeof listener !== "function") throw new Error("Invalid Guard Runtime status listener");
      if (closed) throw new Error("Guard Runtime is unavailable");
      statusListeners.add(listener); try { listener(effectiveStatus()); } catch { /* Presentation cannot affect ownership. */ }
      return () => statusListeners.delete(listener);
    },
    reviewMode: () => reviewMode,
    setReviewMode(mode) {
      if (closed) throw new Error("Guard Runtime is unavailable");
      if (mode !== "on" && mode !== "off") throw new Error("Invalid Guard review mode");
      changeReviewMode(mode);
    },
    subscribeReviewMode(listener) {
      if (typeof listener !== "function") throw new Error("Invalid Guard review mode listener");
      if (closed) throw new Error("Guard Runtime is unavailable");
      reviewModeListeners.add(listener);try{listener(reviewMode);}catch{/* Client reaction cannot affect mode ownership. */}
      return () => reviewModeListeners.delete(listener);
    },
  });
  const finishReview = (pending: PendingReview, result: Readonly<GuardReviewResultV1>) => {
    pending.diagnosticsClosed = true;
    if (pending.abort && pending.options.signal) pending.options.signal.removeEventListener("abort", pending.abort);
    pending.resolve(result);
  };
  const reportReviewDiagnostic = (pending: PendingReview, value: GuardReviewDiagnosticV1) => {
    if (closed || pending.diagnosticsClosed || currentReview?.pending !== pending || currentReview.controller.signal.aborted) {
      throw new Error("Guard review diagnostics are no longer active");
    }
    try {
      if (++pending.diagnosticCount > 256) throw new Error("Guard review diagnostic count exceeded");
      const event = validateDiagnostic(value, pending.clientId, ++reviewDiagnosticSequence);
      pending.diagnosticBytes += Buffer.byteLength(JSON.stringify(event), "utf8");
      if (pending.diagnosticBytes > 256 * 1024) throw new Error("Guard review diagnostics exceed 256 KiB");
      try { pending.options.report?.(event); } catch { /* Presentation cannot affect review. */ }
    } catch (cause) {
      pending.diagnosticError = error(cause, "Invalid Guard review diagnostic");
      throw pending.diagnosticError;
    }
  };
  const removeQueuedReview = (pending: PendingReview, cause: unknown): boolean => {
    const index = reviewWaiting.indexOf(pending);
    if (index < 0) return false;
    reviewWaiting.splice(index, 1); finishReview(pending, incompleteReview(cause, "Guard review cancelled")); return true;
  };
  const activateNextReview = () => {
    if (closed || currentReview) return;
    const pending = reviewWaiting.shift();
    if (!pending) return;
    if (pending.options.signal?.aborted || reviewClients.get(pending.clientId)?.token !== pending.clientToken) {
      finishReview(pending, incompleteReview(pending.options.signal?.reason, "Guard review client is unavailable"));
      queueMicrotask(activateNextReview); return;
    }
    if (!options.reviewer) {
      finishReview(pending, incompleteReview(new Error("Guard reviewer backend is unavailable")));
      queueMicrotask(activateNextReview); return;
    }
    const controller = new AbortController(); currentReview = { pending, controller };
    const abortPromise = new Promise<never>((_, reject) => {
      controller.signal.addEventListener("abort", () => reject(controller.signal.reason), { once: true });
    });
    const context:Readonly<GuardReviewBackendContextV1> = Object.freeze({ signal: controller.signal,
      report: (event: GuardReviewDiagnosticV1) => reportReviewDiagnostic(pending, event) });
    const work = Promise.resolve().then(() => options.reviewer!.review(pending.request, context));
    work.catch(() => {});
    void Promise.race([work, abortPromise]).then(raw => {
      try {
        if (pending.diagnosticError) throw pending.diagnosticError;
        finishReview(pending, validateReviewResult(raw));
      }
      catch (cause) { finishReview(pending, incompleteReview(cause, "Guard reviewer returned an invalid result")); }
    }, cause => finishReview(pending, incompleteReview(cause, "Guard review cancelled"))).finally(() => {
      if (currentReview?.pending === pending) currentReview = undefined;
      controller.abort(new Error("Guard review finished")); activateNextReview();
    });
  };
  const stopPendingReview = (pending: PendingReview, cause: unknown) => {
    if (removeQueuedReview(pending, cause)) return;
    if (currentReview?.pending === pending) currentReview.controller.abort(error(cause, "Guard review cancelled"));
  };
  const review = (entry: ReviewClientEntry, value: GuardReviewRequestV1, optionValue?: GuardReviewOptionsV1) => {
    let request: Readonly<GuardReviewBackendRequestV1>, reviewOptions: Readonly<GuardReviewOptionsV1>;
    try { request = validateReviewRequest(value, entry.registration); reviewOptions = validateReviewOptions(optionValue); }
    catch (cause) { return Promise.reject(error(cause)); }
    if (closed || reviewClients.get(entry.registration.id)?.token !== entry.token) {
      return Promise.resolve(incompleteReview(new Error("Guard review client is unavailable")));
    }
    if(reviewMode!=="on")return Promise.resolve(incompleteReview(new Error(`Guard review is ${reviewMode}`)));
    if (reviewOptions.signal?.aborted) return Promise.resolve(incompleteReview(reviewOptions.signal.reason, "Guard review cancelled"));
    return new Promise<Readonly<GuardReviewResultV1>>(resolve => {
      const pending: PendingReview = { clientId: entry.registration.id, clientToken: entry.token, request, options: reviewOptions,
        diagnosticsClosed: false, diagnosticCount: 0, diagnosticBytes: 0, resolve };
      if (reviewOptions.signal) {
        pending.abort = () => stopPendingReview(pending, reviewOptions.signal!.reason);
        reviewOptions.signal.addEventListener("abort", pending.abort, { once: true });
      }
      reviewWaiting.push(pending); activateNextReview();
    });
  };
  function changeReviewMode(mode:GuardReviewModeV1):void{
    if(reviewMode===mode)return;reviewMode=mode;
    if(mode!=="on"){
      for(const pending of [...reviewWaiting])removeQueuedReview(pending,new Error(`Guard review is ${mode}`));
      currentReview?.controller.abort(new Error(`Guard review is ${mode}`));
    }
    for(const listener of reviewModeListeners)try{listener(mode);}catch{/* Client reaction cannot affect mode ownership. */}
  }
  const removeReviewClient = (entry: ReviewClientEntry) => {
    if (reviewClients.get(entry.registration.id)?.token !== entry.token) return;
    reviewClients.delete(entry.registration.id);
    for (const pending of [...reviewWaiting]) if (pending.clientToken === entry.token) {
      removeQueuedReview(pending, new Error("Guard review client was disposed"));
    }
    if (currentReview?.pending.clientToken === entry.token) {
      currentReview.controller.abort(new Error("Guard review client was disposed"));
    }
  };
  const reviewService: GuardReviewRuntimeV1 = Object.freeze({
    kind: GUARD_REVIEW_RUNTIME_KIND,
    schemaVersion: GUARD_REVIEW_RUNTIME_VERSION,
    registerClient(value) {
      if (closed) throw new Error("Guard review runtime is unavailable");
      const registration = validateReviewRegistration(value);
      if (reviewClients.has(registration.id)) throw new Error(`Guard review client already registered: ${registration.id}`);
      const entry: ReviewClientEntry = { token: Symbol(registration.id), registration };
      reviewClients.set(registration.id, entry);
      return Object.freeze({
        id: registration.id,
        active: () => !closed && reviewClients.get(registration.id)?.token === entry.token,
        review: (request, options) => review(entry, request, options),
        dispose: () => removeReviewClient(entry),
      });
    },
    clients: () => Object.freeze([...reviewClients.values()].map(entry => entry.registration)
      .sort((a, b) => a.id.localeCompare(b.id))),
  });
  const stopDiscovery = pi.events.on(GUARD_RUNTIME_DISCOVER, value => {
    const discovery = value as Partial<DiscoveryV1> | null;
    if (!closed && discovery?.schemaVersion === 1 && typeof discovery.accept === "function") discovery.accept(service);
  });
  const stopReviewDiscovery = pi.events.on(GUARD_REVIEW_RUNTIME_DISCOVER, value => {
    const discovery = value as Partial<ReviewDiscoveryV1> | null;
    if (!closed && discovery?.schemaVersion === 1 && typeof discovery.accept === "function") discovery.accept(reviewService);
  });
  const clearStatus = () => {
    stopStatus?.(); stopStatus = undefined; statusRedraw = undefined;
    try { statusContext?.ui.setWidget("guard-runtime", undefined, { placement: "belowEditor" }); } catch { /* UI only. */ }
    statusContext = undefined; statusRows=[];
  };
  const installStatus = (ctx: ExtensionContext) => {
    clearStatus(); statusContext = ctx;
    if (ctx.mode !== "tui") return;
    try {
      ctx.ui.setWidget("guard-runtime", (tui, theme) => {
        statusRedraw = () => tui.requestRender();
        return { render: (width: number) => renderGuardStatusRows(statusRows,width).map(line=>theme.fg("muted",line)), invalidate() {} };
      }, { placement: "belowEditor" });
      stopStatus = service.subscribeStatus(() => { statusRows = effectiveStatusRows(); statusRedraw?.(); });
    } catch { clearStatus(); statusContext=ctx; }
  };
  pi.on("session_start", (_event, ctx) => {closeView(undefined,"Guard session changed");changeReviewMode("unknown");installStatus(ctx);});
  pi.on("session_tree", (_event, ctx) => {closeView(undefined,"Guard session changed");installStatus(ctx);});
  pi.on("session_shutdown", () => {
    closeView(undefined,"Guard Runtime stopped");closed = true;
    rejectWaiting(() => true, new Error("Guard Runtime stopped"));
    for (const pending of [...reviewWaiting]) removeQueuedReview(pending, new Error("Guard review runtime stopped"));
    currentReview?.controller.abort(new Error("Guard review runtime stopped"));
    clients.clear(); reviewClients.clear(); baselines.clear(); current = undefined; publish();
    activityListeners.clear(); statusListeners.clear(); reviewModeListeners.clear();stopDiscovery(); stopReviewDiscovery(); clearStatus();
  });
  pi.events.emit(GUARD_RUNTIME_AVAILABLE, service);
  pi.events.emit(GUARD_REVIEW_RUNTIME_AVAILABLE, reviewService);
  };
}

export default function guardRuntime(pi: ExtensionAPI): void {
  createGuardRuntimeExtension({ reviewer: createAgenticGuardReviewBackend(pi) })(pi);
}
