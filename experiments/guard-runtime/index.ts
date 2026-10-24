// SPDX-License-Identifier: MIT
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";

export const GUARD_RUNTIME_KIND = "pi-run.guard-runtime";
export const GUARD_RUNTIME_VERSION = 1 as const;
export const GUARD_RUNTIME_AVAILABLE = "pi-run:guard-runtime:v1:available";
export const GUARD_RUNTIME_DISCOVER = "pi-run:guard-runtime:v1:discover";

export interface GuardClientRegistrationV1 { schemaVersion: 1; id: string; label: string; }
export interface GuardActivityRequestV1 { schemaVersion: 1; state: string; detail?: string; }
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
type DiscoveryV1 = { schemaVersion: 1; accept(runtime: GuardRuntimeV1): void };
type ClientEntry = { token: symbol; registration: Readonly<GuardClientRegistrationV1> };
type PendingActivity = {
  clientId: string; clientToken: symbol; activity: Readonly<GuardActivityRequestV1>; signal?: AbortSignal;
  abort?: () => void; resolve(lease: GuardActivityLeaseV1): void; reject(error: Error): void;
};

function error(value: unknown, fallback = "Guard Runtime operation failed"): Error {
  return value instanceof Error ? value : new Error(value === undefined ? fallback : String(value));
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
function validateActivity(value: GuardActivityRequestV1): Readonly<GuardActivityRequestV1> {
  const keys = value && typeof value === "object" && !Array.isArray(value) ? Object.keys(value).sort().join(",") : "";
  if (!value || (keys !== "schemaVersion,state" && keys !== "detail,schemaVersion,state") ||
      value.schemaVersion !== 1 || typeof value.state !== "string" ||
      !/^[a-z][a-z0-9-]{0,31}$/.test(value.state) ||
      (value.detail !== undefined && (typeof value.detail !== "string" || value.detail !== value.detail.trim() ||
        !value.detail || value.detail.length > 120 || /[\u0000-\u001f\u007f]/.test(value.detail)))) {
    throw new Error("Invalid Guard Runtime activity");
  }
  return Object.freeze({ ...value });
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
  const text = `guard · ${state}${activity?.detail ? ` ${activity.detail}` : ""}`;
  return truncateToWidth(text, safeWidth, "…");
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

export default function guardRuntime(pi: ExtensionAPI) {
  const clients = new Map<string, ClientEntry>(), waiting: PendingActivity[] = [];
  const baselines = new Map<string, { clientToken: symbol; order: number; snapshot: Readonly<GuardActivitySnapshotV1> }>();
  const activityListeners = new Set<(activity: Readonly<GuardActivitySnapshotV1> | undefined) => void>();
  const statusListeners = new Set<(status: Readonly<GuardActivitySnapshotV1> | undefined) => void>();
  let closed = false, sequence = 0, baselineOrder = 0;
  let statusContext: ExtensionContext | undefined, statusRedraw: (() => void) | undefined;
  let statusActivity: Readonly<GuardActivitySnapshotV1> | undefined, stopStatus: (() => void) | undefined;
  let current: { clientToken: symbol; leaseToken: symbol; snapshot: Readonly<GuardActivitySnapshotV1> } | undefined;
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
  const stopDiscovery = pi.events.on(GUARD_RUNTIME_DISCOVER, value => {
    const discovery = value as Partial<DiscoveryV1> | null;
    if (!closed && discovery?.schemaVersion === 1 && typeof discovery.accept === "function") discovery.accept(service);
  });
  const clearStatus = () => {
    stopStatus?.(); stopStatus = undefined; statusRedraw = undefined;
    try { statusContext?.ui.setWidget("guard-runtime", undefined, { placement: "belowEditor" }); } catch { /* UI only. */ }
    statusContext = undefined; statusActivity = undefined;
  };
  pi.on("session_start", (_event, ctx) => {
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
  });
  pi.on("session_shutdown", () => {
    closed = true;
    rejectWaiting(() => true, new Error("Guard Runtime stopped"));
    clients.clear(); baselines.clear(); current = undefined; publish();
    activityListeners.clear(); statusListeners.clear(); stopDiscovery(); clearStatus();
  });
  pi.events.emit(GUARD_RUNTIME_AVAILABLE, service);
}
