// SPDX-License-Identifier: MIT
import { constants } from "node:fs";
import { lstat, mkdir, open, realpath, rename, unlink } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { join, resolve } from "node:path";

export interface GuardJournalOptionsV1 {
  schemaVersion: 1;
  stateDir: string;
  clientId: string;
  maxBytes?: number;
  backups?: number;
  maxPending?: number;
}
export interface GuardJournalHealthV1 {
  pending: number;
  dropped: number;
  written: number;
  lastError: string | null;
}
export interface GuardJournalWriterV1 {
  readonly schemaVersion: 1;
  readonly clientId: string;
  readonly runId: string;
  readonly path: string;
  write(entry: Record<string, unknown>): void;
  flush(): Promise<void>;
  health(): Readonly<GuardJournalHealthV1>;
}

const DEFAULT_MAX_BYTES = 1024 * 1024;
const DEFAULT_BACKUPS = 2;
const DEFAULT_MAX_PENDING = 128;
const MAX_RECORD_BYTES = 32 * 1024;

function errorText(value: unknown): string {
  return value instanceof Error ? value.message : String(value);
}
function missing(value: unknown): boolean {
  return (value as NodeJS.ErrnoException)?.code === "ENOENT";
}
function validateInteger(value: number, minimum: number, maximum: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new Error(`Invalid Guard journal ${name}`);
  }
  return value;
}
function ownedByProcess(uid: number): boolean {
  return typeof process.getuid !== "function" || uid === process.getuid();
}
async function privateChild(parent: string, name: string): Promise<string> {
  const resolvedParent = await realpath(parent), path = join(resolvedParent, name);
  try { await mkdir(path, { mode: 0o700 }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(path, constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    const stat = await handle.stat();
    if (!stat.isDirectory() || !ownedByProcess(stat.uid) || (stat.mode & 0o777) !== 0o700) {
      throw new Error(`Unsafe Guard journal directory: ${path}`);
    }
    if (await realpath(path) !== path) throw new Error(`Redirected Guard journal directory: ${path}`);
  } finally { await handle?.close(); }
  return path;
}
async function regularFile(path: string) {
  try {
    const stat = await lstat(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || !ownedByProcess(stat.uid) ||
        (stat.mode & 0o777) !== 0o600) {
      throw new Error(`Unsafe Guard journal file: ${path}`);
    }
    return stat;
  } catch (error) { if (missing(error)) return undefined; throw error; }
}

export function createGuardJournalWriter(
  options: GuardJournalOptionsV1,
  warn: (message: string) => void = () => {},
): GuardJournalWriterV1 {
  if (!options || options.schemaVersion !== 1 || typeof options.stateDir !== "string" || !options.stateDir ||
      typeof options.clientId !== "string" || !/^[a-z][a-z0-9-]{0,63}$/.test(options.clientId)) {
    throw new Error("Invalid Guard journal options");
  }
  const maxBytes = validateInteger(options.maxBytes ?? DEFAULT_MAX_BYTES, 256, 64 * 1024 * 1024, "size limit");
  const backups = validateInteger(options.backups ?? DEFAULT_BACKUPS, 0, 8, "backup count");
  const maxPending = validateInteger(options.maxPending ?? DEFAULT_MAX_PENDING, 1, 1024, "queue limit");
  const stateDir = resolve(options.stateDir), runId = randomUUID();
  const runsPath = join(stateDir, "logs", options.clientId, "runs");
  const path = join(runsPath, `${runId}.jsonl`);
  let queue: Promise<void> = Promise.resolve(), pending = 0, dropped = 0, written = 0, sequence = 0;
  let lastError: string | undefined, warned = false, claimed = false;

  async function directories(): Promise<void> {
    const stateStat = await lstat(stateDir), resolvedState = await realpath(stateDir);
    if (!stateStat.isDirectory() || stateStat.isSymbolicLink() || resolvedState !== stateDir) {
      throw new Error("Guard journal state directory is redirected");
    }
    const logs = await privateChild(resolvedState, "logs");
    const client = await privateChild(logs, options.clientId);
    const runs = await privateChild(client, "runs");
    if (runs !== join(resolvedState, "logs", options.clientId, "runs") || runs !== runsPath) {
      throw new Error("Guard journal path is redirected");
    }
  }
  async function create(line: string): Promise<void> {
    const handle = await open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try {
      const stat = await handle.stat();
      if (!stat.isFile() || stat.nlink !== 1 || !ownedByProcess(stat.uid)) throw new Error("Unsafe new Guard journal file");
      await handle.chmod(0o600); await handle.writeFile(line, "utf8");
    } finally { await handle.close(); }
    claimed = true;
  }
  async function append(line: string): Promise<void> {
    await directories();
    if (!claimed) { await create(line); return; }
    const current = await regularFile(path);
    if (!current) throw new Error("Active Guard journal file disappeared");
    if (current.size + Buffer.byteLength(line) > maxBytes) {
      for (let index = 1; index <= backups; index++) await regularFile(`${path}.${index}`);
      if (backups > 0) {
        try { await unlink(`${path}.${backups}`); } catch (error) { if (!missing(error)) throw error; }
        for (let index = backups - 1; index >= 0; index--) {
          const from = index === 0 ? path : `${path}.${index}`;
          try { await rename(from, `${path}.${index + 1}`); }
          catch (error) { if (!missing(error)) throw error; }
        }
      } else await unlink(path);
      claimed = false; await create(line); return;
    }
    const handle = await open(path, constants.O_WRONLY | constants.O_APPEND | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const stat = await handle.stat();
      if (!stat.isFile() || stat.nlink !== 1 || !ownedByProcess(stat.uid) || (stat.mode & 0o777) !== 0o600) {
        throw new Error("Unsafe active Guard journal file");
      }
      await handle.writeFile(line, "utf8");
    } finally { await handle.close(); }
  }
  function failure(error: unknown): void {
    lastError = errorText(error); dropped++;
    if (!warned) {
      warned = true;
      try { warn(`Guard journal unavailable: ${lastError}`); } catch { /* Diagnostics cannot affect clients. */ }
    }
  }
  const writer: GuardJournalWriterV1 = Object.freeze({
    schemaVersion: 1 as const, clientId: options.clientId, runId, path,
    write(entry) {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) { failure(new Error("Invalid Guard journal entry")); return; }
      if (pending >= maxPending) { failure(new Error("Guard journal queue is full")); return; }
      let line: string;
      try {
        line = JSON.stringify({ ...entry, journal: { schemaVersion: 1, clientId: options.clientId,
          runId, processId: process.pid, sequence: ++sequence } }) + "\n";
        const size = Buffer.byteLength(line);
        if (size > MAX_RECORD_BYTES || size > maxBytes) throw new Error("Guard journal record exceeds its size limit");
      } catch (error) { failure(error); return; }
      pending++;
      queue = queue.then(async () => {
        try { await append(line); written++; lastError = undefined; warned = false; }
        catch (error) { failure(error); }
        finally { pending--; }
      });
    },
    flush: async () => { for (;;) { const batch = queue; await batch; if (batch === queue) return; } },
    health: () => Object.freeze({ pending, dropped, written, lastError: lastError ?? null }),
  });
  return writer;
}
