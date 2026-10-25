// SPDX-License-Identifier: MIT
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

export const GUARD_RUNTIME_KIND = "pi-run.guard-runtime";
export const GUARD_RUNTIME_VERSION = 1 as const;
export const GUARD_RUNTIME_AVAILABLE = "pi-run:guard-runtime:v1:available";
export const GUARD_RUNTIME_DISCOVER = "pi-run:guard-runtime:v1:discover";
export const GUARD_REVIEW_RUNTIME_KIND = "pi-run.guard-review-runtime";
export const GUARD_REVIEW_RUNTIME_VERSION = 1 as const;
export const GUARD_REVIEW_RUNTIME_AVAILABLE = "pi-run:guard-review-runtime:v1:available";
export const GUARD_REVIEW_RUNTIME_DISCOVER = "pi-run:guard-review-runtime:v1:discover";

export interface GuardClientRegistrationV1 { schemaVersion: 1; id: string; label: string; }
export interface GuardReviewClientRegistrationV1 extends GuardClientRegistrationV1 {
  evidenceProfile: string;
  decisionContract: string;
}
export interface GuardReviewRequestV1 { schemaVersion: 1; action: unknown; policy: unknown; }
export type GuardReviewResultV1 =
  | { schemaVersion: 1; status: "completed"; decision: Readonly<Record<string, unknown>> }
  | { schemaVersion: 1; status: "incomplete"; error: string };
export interface GuardReviewBackendRequestV1 extends GuardReviewRequestV1 {
  client: Readonly<GuardReviewClientRegistrationV1>;
}
export interface GuardReviewBackendV1 {
  review(request: Readonly<GuardReviewBackendRequestV1>, signal: AbortSignal): Promise<unknown>;
}
export interface GuardReviewClientHandleV1 {
  readonly id: string;
  active(): boolean;
  review(request: GuardReviewRequestV1, signal?: AbortSignal): Promise<Readonly<GuardReviewResultV1>>;
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
  review(request: GuardReviewRequestV1, signal?: AbortSignal): Promise<Readonly<GuardReviewResultV1>>;
  dispose(): void;
}
export interface GuardRuntimeOptions { reviewer?: GuardReviewBackendV1; }
export interface GuardActivityRequestV1 { schemaVersion: 1; state: string; detail?: string; right?: string; }
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
}
export interface GuardClientConnectionV1 {
  connected(): boolean;
  runtime(): GuardRuntimeV1 | undefined;
  setBaseline(activity: GuardActivityRequestV1 | undefined): void;
  acquireActivity(activity: GuardActivityRequestV1, signal?: AbortSignal): Promise<GuardActivityLeaseV1>;
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
  signal?: AbortSignal;
  abort?: () => void;
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
      Object.keys(value).sort().join(",") !== "id,label,schemaVersion" || value.schemaVersion !== 1 ||
      typeof value.id !== "string" || !/^[a-z][a-z0-9-]{0,63}$/.test(value.id) ||
      typeof value.label !== "string" || value.label !== value.label.trim() || !value.label ||
      value.label.length > 80 || /[\u0000-\u001f\u007f]/.test(value.label)) {
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
function frozenJson<T>(value: T): Readonly<T> {
  validateJson(value);
  const encoded = JSON.stringify(value);
  if (Buffer.byteLength(encoded, "utf8") > 128 * 1024) throw new Error("Guard review request exceeds 128 KiB");
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
      Object.keys(value).some(key => !["schemaVersion", "state", "detail", "right"].includes(key)) ||
      value.schemaVersion !== 1 || typeof value.state !== "string" ||
      !/^[a-z][a-z0-9-]{0,31}$/.test(value.state) ||
      (value.detail !== undefined && !validText(value.detail)) ||
      (value.right !== undefined && !validText(value.right))) {
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
    typeof candidate.subscribeActivity === "function" && typeof candidate.subscribeStatus === "function";
}
export function renderGuardStatus(activity: Readonly<GuardActivitySnapshotV1> | undefined, width: number): string {
  const safeWidth = Number.isFinite(width) ? Math.max(1, Math.floor(width)) : 1;
  const state = activity?.state.replaceAll("-", " ") ?? "ready";
  const left = `guard · ${state}${activity?.detail ? ` ${activity.detail}` : ""}`;
  if (visibleWidth(left) >= safeWidth) return truncateToWidth(left, safeWidth, "…");
  const available = safeWidth - visibleWidth(left) - 2;
  if (!activity?.right || available < 12) return left;
  const right = truncateToWidth(activity.right, available, "…");
  return left + " ".repeat(Math.max(2, safeWidth - visibleWidth(left) - visibleWidth(right))) + right;
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
    setBaseline(activity) {
      if (!handle?.active()) throw new Error("Guard Runtime client is unavailable");
      handle.setBaseline(activity);
    },
    acquireActivity: (activity, signal) => handle?.active()
      ? handle.acquireActivity(activity, signal)
      : Promise.reject(new Error("Guard Runtime client is unavailable")),
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
    review: (request, signal) => handle?.active()
      ? handle.review(request, signal)
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
  const clients = new Map<string, ClientEntry>(), waiting: PendingActivity[] = [];
  const reviewClients = new Map<string, ReviewClientEntry>(), reviewWaiting: PendingReview[] = [];
  const baselines = new Map<string, { clientToken: symbol; order: number; snapshot: Readonly<GuardActivitySnapshotV1> }>();
  const activityListeners = new Set<(activity: Readonly<GuardActivitySnapshotV1> | undefined) => void>();
  const statusListeners = new Set<(status: Readonly<GuardActivitySnapshotV1> | undefined) => void>();
  let closed = false, sequence = 0, baselineOrder = 0;
  let statusContext: ExtensionContext | undefined, statusRedraw: (() => void) | undefined;
  let statusActivity: Readonly<GuardActivitySnapshotV1> | undefined, stopStatus: (() => void) | undefined;
  let current: { clientToken: symbol; leaseToken: symbol; snapshot: Readonly<GuardActivitySnapshotV1> } | undefined;
  let currentReview: { pending: PendingReview; controller: AbortController } | undefined;
  const selectedBaseline = () => [...baselines.values()].sort((a, b) => b.order - a.order)[0]?.snapshot;
  const effectiveStatus = () => current?.snapshot ?? selectedBaseline();
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
  const removeClient = (entry: ClientEntry) => {
    if (clients.get(entry.registration.id)?.token !== entry.token) return;
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
  });
  const finishReview = (pending: PendingReview, result: Readonly<GuardReviewResultV1>) => {
    if (pending.abort && pending.signal) pending.signal.removeEventListener("abort", pending.abort);
    pending.resolve(result);
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
    if (pending.signal?.aborted || reviewClients.get(pending.clientId)?.token !== pending.clientToken) {
      finishReview(pending, incompleteReview(pending.signal?.reason, "Guard review client is unavailable"));
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
    const work = Promise.resolve().then(() => options.reviewer!.review(pending.request, controller.signal));
    work.catch(() => {});
    void Promise.race([work, abortPromise]).then(raw => {
      try { finishReview(pending, validateReviewResult(raw)); }
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
  const review = (entry: ReviewClientEntry, value: GuardReviewRequestV1, signal?: AbortSignal) => {
    let request: Readonly<GuardReviewBackendRequestV1>;
    try { request = validateReviewRequest(value, entry.registration); }
    catch (cause) { return Promise.reject(error(cause)); }
    if (closed || reviewClients.get(entry.registration.id)?.token !== entry.token) {
      return Promise.resolve(incompleteReview(new Error("Guard review client is unavailable")));
    }
    if (signal?.aborted) return Promise.resolve(incompleteReview(signal.reason, "Guard review cancelled"));
    return new Promise<Readonly<GuardReviewResultV1>>(resolve => {
      const pending: PendingReview = { clientId: entry.registration.id, clientToken: entry.token, request, signal, resolve };
      if (signal) {
        pending.abort = () => stopPendingReview(pending, signal.reason);
        signal.addEventListener("abort", pending.abort, { once: true });
      }
      reviewWaiting.push(pending); activateNextReview();
    });
  };
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
        review: (request, signal) => review(entry, request, signal),
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
    statusContext = undefined; statusActivity = undefined;
  };
  const installStatus = (ctx: ExtensionContext) => {
    clearStatus();
    if (ctx.mode !== "tui") return;
    try {
      statusContext = ctx;
      ctx.ui.setWidget("guard-runtime", (tui, theme) => {
        statusRedraw = () => tui.requestRender();
        return { render: (width: number) => [theme.fg("muted", renderGuardStatus(statusActivity, width))], invalidate() {} };
      }, { placement: "belowEditor" });
      stopStatus = service.subscribeStatus(activity => { statusActivity = activity; statusRedraw?.(); });
    } catch { clearStatus(); }
  };
  pi.on("session_start", (_event, ctx) => installStatus(ctx));
  pi.on("session_tree", (_event, ctx) => installStatus(ctx));
  pi.on("session_shutdown", () => {
    closed = true;
    rejectWaiting(() => true, new Error("Guard Runtime stopped"));
    for (const pending of [...reviewWaiting]) removeQueuedReview(pending, new Error("Guard review runtime stopped"));
    currentReview?.controller.abort(new Error("Guard review runtime stopped"));
    clients.clear(); reviewClients.clear(); baselines.clear(); current = undefined; publish();
    activityListeners.clear(); statusListeners.clear(); stopDiscovery(); stopReviewDiscovery(); clearStatus();
  });
  pi.events.emit(GUARD_RUNTIME_AVAILABLE, service);
  pi.events.emit(GUARD_REVIEW_RUNTIME_AVAILABLE, reviewService);
  };
}

export default createGuardRuntimeExtension();
