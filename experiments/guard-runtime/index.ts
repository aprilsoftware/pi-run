// SPDX-License-Identifier: MIT
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const GUARD_RUNTIME_KIND = "pi-run.guard-runtime";
export const GUARD_RUNTIME_VERSION = 1 as const;
export const GUARD_RUNTIME_AVAILABLE = "pi-run:guard-runtime:v1:available";
export const GUARD_RUNTIME_DISCOVER = "pi-run:guard-runtime:v1:discover";

export interface GuardClientRegistrationV1 { schemaVersion: 1; id: string; label: string; }
export interface GuardClientHandleV1 {
  readonly id: string;
  active(): boolean;
  dispose(): void;
}
export interface GuardRuntimeV1 {
  readonly kind: typeof GUARD_RUNTIME_KIND;
  readonly schemaVersion: typeof GUARD_RUNTIME_VERSION;
  registerClient(registration: GuardClientRegistrationV1): GuardClientHandleV1;
  clients(): readonly Readonly<GuardClientRegistrationV1>[];
}
export interface GuardClientConnectionV1 {
  connected(): boolean;
  runtime(): GuardRuntimeV1 | undefined;
  dispose(): void;
}
type ConnectionCallbacks = { connected?(runtime: GuardRuntimeV1): void; error?(error: Error): void; };
type DiscoveryV1 = { schemaVersion: 1; accept(runtime: GuardRuntimeV1): void };

function error(value: unknown): Error { return value instanceof Error ? value : new Error(String(value)); }
function validateRegistration(value: GuardClientRegistrationV1): GuardClientRegistrationV1 {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).sort().join(",") !== "id,label,schemaVersion" || value.schemaVersion !== 1 ||
      typeof value.id !== "string" || !/^[a-z][a-z0-9-]{0,63}$/.test(value.id) ||
      typeof value.label !== "string" || value.label !== value.label.trim() || !value.label ||
      value.label.length > 80 || /[\u0000-\u001f\u007f]/.test(value.label)) {
    throw new Error("Invalid Guard Runtime client registration");
  }
  return Object.freeze({ ...value });
}
function isRuntime(value: unknown): value is GuardRuntimeV1 {
  const candidate = value as Partial<GuardRuntimeV1> | null;
  return !!candidate && candidate.kind === GUARD_RUNTIME_KIND &&
    candidate.schemaVersion === GUARD_RUNTIME_VERSION &&
    typeof candidate.registerClient === "function" && typeof candidate.clients === "function";
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
    dispose() {
      if (disposed) return;
      disposed = true; handle?.dispose(); stopAvailable(); stopShutdown();
    },
  });
  pi.events.emit(GUARD_RUNTIME_DISCOVER, { schemaVersion: 1, accept } satisfies DiscoveryV1);
  return connection;
}

export default function guardRuntime(pi: ExtensionAPI) {
  const clients = new Map<string, { token: symbol; registration: Readonly<GuardClientRegistrationV1> }>();
  let closed = false;
  const service: GuardRuntimeV1 = Object.freeze({
    kind: GUARD_RUNTIME_KIND,
    schemaVersion: GUARD_RUNTIME_VERSION,
    registerClient(value) {
      if (closed) throw new Error("Guard Runtime is unavailable");
      const registration = validateRegistration(value);
      if (clients.has(registration.id)) throw new Error(`Guard Runtime client already registered: ${registration.id}`);
      const token = Symbol(registration.id);
      clients.set(registration.id, { token, registration });
      return Object.freeze({
        id: registration.id,
        active: () => !closed && clients.get(registration.id)?.token === token,
        dispose: () => {
          if (clients.get(registration.id)?.token === token) clients.delete(registration.id);
        },
      });
    },
    clients: () => Object.freeze([...clients.values()]
      .map(entry => entry.registration).sort((a, b) => a.id.localeCompare(b.id))),
  });
  const stopDiscovery = pi.events.on(GUARD_RUNTIME_DISCOVER, value => {
    const discovery = value as Partial<DiscoveryV1> | null;
    if (!closed && discovery?.schemaVersion === 1 && typeof discovery.accept === "function") discovery.accept(service);
  });
  pi.on("session_shutdown", () => {
    closed = true; clients.clear(); stopDiscovery();
  });
  pi.events.emit(GUARD_RUNTIME_AVAILABLE, service);
}
