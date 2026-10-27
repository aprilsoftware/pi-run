// SPDX-License-Identifier: MIT
import type { AgenticThinking, GuardReviewerConfig, ResolvedGuardReviewerConfig } from "./guard-reviewer-agent.ts";
import type { GuardViewRequestV1 } from "./guard-viewer.ts";

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
export function error(value: unknown, fallback = "Guard Runtime operation failed"): Error {
  return value instanceof Error ? value : new Error(value === undefined ? fallback : String(value));
}
export function safeError(value: unknown, fallback: string): string {
  const text = error(value, fallback).message.replace(/[\u0000-\u001f\u007f]/g, " ").trim();
  return (text || fallback).slice(0, 4000);
}
function identifier(value: unknown): value is string {
  return typeof value === "string" && /^[a-z][a-z0-9-]{0,63}(?:\.[a-z][a-z0-9-]{0,63})*\.v[1-9][0-9]*$/.test(value);
}
export function validateRegistration(value: GuardClientRegistrationV1): Readonly<GuardClientRegistrationV1> {
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
export function validateReviewRegistration(value: GuardReviewClientRegistrationV1): Readonly<GuardReviewClientRegistrationV1> {
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
export function validateReviewRequest(value: GuardReviewRequestV1, client: Readonly<GuardReviewClientRegistrationV1>): Readonly<GuardReviewBackendRequestV1> {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).sort().join(",") !== "action,policy,schemaVersion" || value.schemaVersion !== 1) {
    throw new Error("Invalid Guard review request");
  }
  return frozenJson({ schemaVersion: 1 as const, client, action: value.action, policy: value.policy });
}
export function validateReviewOptions(value: GuardReviewOptionsV1 | undefined): Readonly<GuardReviewOptionsV1> {
  if (value === undefined) return Object.freeze({});
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.getPrototypeOf(value) !== Object.prototype ||
      Object.keys(value).some(key => !["signal", "report"].includes(key)) ||
      (value.signal !== undefined && !(value.signal instanceof AbortSignal)) ||
      (value.report !== undefined && typeof value.report !== "function")) throw new Error("Invalid Guard review options");
  return Object.freeze({ ...(value.signal ? { signal: value.signal } : {}), ...(value.report ? { report: value.report } : {}) });
}
export function validateDiagnostic(value: GuardReviewDiagnosticV1, clientId: string, sequence: number): Readonly<GuardReviewDiagnosticSnapshotV1> {
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
export function incompleteReview(cause: unknown, fallback = "Guard reviewer unavailable"): Readonly<GuardReviewResultV1> {
  return Object.freeze({ schemaVersion: 1, status: "incomplete", error: safeError(cause, fallback) });
}
export function validateReviewResult(value: unknown): Readonly<GuardReviewResultV1> {
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
export function validateActivity(value: GuardActivityRequestV1): Readonly<GuardActivityRequestV1> {
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
