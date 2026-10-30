// SPDX-License-Identifier: MIT
import { constants } from "node:fs";
import { lstat, mkdir, open, readdir, realpath, rename, rmdir, unlink } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { basename, dirname, join, resolve } from "node:path";

export interface GuardJournalHealth {
  pending: number;
  dropped: number;
  written: number;
  lastError: string | null;
}

const DEFAULT_MAX_BYTES = 1024 * 1024;
const DEFAULT_BACKUPS = 2;
const DEFAULT_MAX_PENDING = 128;
const MAX_RECORD_BYTES = 32 * 1024;
const LOCK_STALE_MS = 30_000;
const LOCK_ATTEMPTS = 100;
const LOCK_WAIT_MS = 10;

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

type ReadCandidate = { path: string; source: string; size: number; mtimeMs: number; dev: number; ino: number };

async function readableDirectory(path: string): Promise<boolean> {
  try {
    const stat = await lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink() || !ownedByProcess(stat.uid) ||
        (stat.mode & 0o777) !== 0o700 || await realpath(path) !== path) {
      throw new Error(`Unsafe Guard journal directory: ${path}`);
    }
    return true;
  } catch (error) { if (missing(error)) return false; throw error; }
}
function readNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : null;
}
export type GuardJournalKind = "guardian" | "caf";
export interface WorkspaceGuardJournalOptions {
  schemaVersion: 2;
  stateDir: string;
  workspaceId: string;
  sessionId: string;
  kind: GuardJournalKind;
  maxBytes?: number;
  backups?: number;
  maxPending?: number;
}
export interface WorkspaceGuardJournalWriter {
  readonly schemaVersion: 2;
  readonly workspaceId: string;
  readonly sessionId: string;
  readonly kind: GuardJournalKind;
  readonly path: string;
  write(entry: Record<string, unknown>): void;
  flush(): Promise<void>;
  close(): Promise<void>;
  health(): Readonly<GuardJournalHealth>;
}
export interface WorkspaceGuardJournalReadOptions {
  schemaVersion: 2;
  stateDir: string;
  workspaceId: string;
  kind: GuardJournalKind;
  maxFiles?: number;
  maxFileBytes?: number;
  maxTotalBytes?: number;
  maxRecords?: number;
}
export interface WorkspaceGuardJournalRecord {
  value: Record<string, unknown>;
  source: string;
  line: number | null;
  timestamp: string | null;
  sessionId: string;
  writerId: string;
  sequence: number | null;
}
export interface WorkspaceGuardJournalSnapshot {
  records: readonly Readonly<WorkspaceGuardJournalRecord>[];
  notices: readonly string[];
  files: readonly string[];
  loadedAt: string;
  malformed: number;
  unstable: number;
}

const JOURNAL_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
function journalId(value: unknown, name: string): string {
  if (typeof value !== "string" || !JOURNAL_ID.test(value)) throw new Error(`Invalid Guard journal ${name}`);
  return value;
}
function journalKind(value: unknown): GuardJournalKind {
  if (value !== "guardian" && value !== "caf") throw new Error("Invalid Guard journal kind");
  return value;
}
function wait(milliseconds: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}
async function removeStaleLock(path: string): Promise<void> {
  for (const entry of await readdir(path, { withFileTypes: true })) {
    const entryPath = join(path, entry.name), stat = await lstat(entryPath);
    if (!JOURNAL_ID.test(entry.name) || !entry.isFile() || !stat.isFile() || stat.isSymbolicLink() ||
        stat.nlink !== 1 || !ownedByProcess(stat.uid) || (stat.mode & 0o777) !== 0o600) {
      throw new Error(`Unsafe stale Guard journal lock: ${path}`);
    }
    await unlink(entryPath);
  }
  await rmdir(path);
}
async function acquireJournalLock(workspacePath: string, kind: GuardJournalKind): Promise<() => Promise<void>> {
  const path = join(workspacePath, `.${kind}-journal.lock`), token = randomUUID(), tokenPath = join(path, token);
  for (let attempt = 0; attempt < LOCK_ATTEMPTS; attempt++) {
    try {
      await mkdir(path, { mode: 0o700 });
      let handle: Awaited<ReturnType<typeof open>> | undefined;
      try {
        handle = await open(tokenPath, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
        await handle.writeFile(`${token}\n`, "utf8");
      } catch (error) {
        await handle?.close().catch(() => {}); await rmdir(path).catch(() => {}); throw error;
      } finally { await handle?.close(); }
      return async () => {
        try { await unlink(tokenPath); } catch (error) { if (!missing(error)) throw error; else return; }
        try { await rmdir(path); } catch (error) { if (!missing(error) && (error as NodeJS.ErrnoException).code !== "ENOTEMPTY") throw error; }
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      let stat;
      try { stat = await lstat(path); } catch (statError) { if (missing(statError)) continue; throw statError; }
      if (!stat.isDirectory() || stat.isSymbolicLink() || !ownedByProcess(stat.uid) || (stat.mode & 0o777) !== 0o700) {
        throw new Error(`Unsafe Guard journal lock: ${path}`);
      }
      if (Date.now() - stat.mtimeMs > LOCK_STALE_MS) {
        const stale = `${path}.stale.${token}`;
        try { await rename(path, stale); } catch (renameError) { if (missing(renameError)) continue; throw renameError; }
        await removeStaleLock(stale); continue;
      }
      await wait(LOCK_WAIT_MS);
    }
  }
  throw new Error(`Guard journal lock is busy: ${path}`);
}
export function guardJournalWorkspaceId(stateDir: string, sessionDir: string): string {
  if (typeof stateDir !== "string" || !stateDir || typeof sessionDir !== "string" || !sessionDir) throw new Error("Invalid Guard journal session directory");
  const sessions = join(resolve(stateDir), "sessions"), candidate = resolve(sessionDir);
  if (dirname(candidate) !== sessions) throw new Error("Guard journal session directory is outside the selected profile");
  return journalId(basename(candidate), "workspace ID");
}

/** Workspace journal contract. Session identity is retained in records, never in paths. */
export function createWorkspaceGuardJournalWriter(
  options: WorkspaceGuardJournalOptions,
  warn: (message: string) => void = () => {},
): WorkspaceGuardJournalWriter {
  if (!options || options.schemaVersion !== 2 || typeof options.stateDir !== "string" || !options.stateDir) {
    throw new Error("Invalid Guard journal workspace options");
  }
  const workspaceId = journalId(options.workspaceId, "workspace ID"), sessionId = journalId(options.sessionId, "session ID");
  const kind = journalKind(options.kind), maxBytes = validateInteger(options.maxBytes ?? DEFAULT_MAX_BYTES, 256, 64 * 1024 * 1024, "size limit");
  const backups = validateInteger(options.backups ?? DEFAULT_BACKUPS, 0, 8, "backup count");
  const maxPending = validateInteger(options.maxPending ?? DEFAULT_MAX_PENDING, 1, 1024, "queue limit");
  const stateDir = resolve(options.stateDir), writerId = randomUUID();
  const workspacePath = join(stateDir, "logs", workspaceId), path = join(workspacePath, `${kind}.jsonl`);
  let queue: Promise<void> = Promise.resolve(), pending = 0, dropped = 0, written = 0, sequence = 0;
  let lastError: string | undefined, warned = false, closed = false, closePromise: Promise<void> | undefined;

  async function directories(): Promise<void> {
    const stateStat = await lstat(stateDir), resolvedState = await realpath(stateDir);
    if (!stateStat.isDirectory() || stateStat.isSymbolicLink() || resolvedState !== stateDir) throw new Error("Guard journal state directory is redirected");
    const logs = await privateChild(resolvedState, "logs"), workspace = await privateChild(logs, workspaceId);
    if (workspace !== workspacePath) throw new Error("Guard journal workspace path is redirected");
  }
  async function create(line: string): Promise<void> {
    const handle = await open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try {
      const stat = await handle.stat();
      if (!stat.isFile() || stat.nlink !== 1 || !ownedByProcess(stat.uid)) throw new Error("Unsafe new Guard journal file");
      await handle.chmod(0o600); await handle.writeFile(line, "utf8");
    } finally { await handle.close(); }
  }
  async function append(line: string): Promise<void> {
    await directories();
    const release = await acquireJournalLock(workspacePath, kind);
    try {
      let current = await regularFile(path);
      if (!current) { await create(line); return; }
      if (current.size + Buffer.byteLength(line) > maxBytes) {
        for (let index = 1; index <= backups; index++) await regularFile(`${path}.${index}`);
        if (backups > 0) {
          try { await unlink(`${path}.${backups}`); } catch (error) { if (!missing(error)) throw error; }
          for (let index = backups - 1; index >= 0; index--) {
            const from = index === 0 ? path : `${path}.${index}`;
            try { await rename(from, `${path}.${index + 1}`); } catch (error) { if (!missing(error)) throw error; }
          }
        } else await unlink(path);
        await create(line); return;
      }
      const handle = await open(path, constants.O_WRONLY | constants.O_APPEND | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      try {
        current = await handle.stat();
        if (!current.isFile() || current.nlink !== 1 || !ownedByProcess(current.uid) || (current.mode & 0o777) !== 0o600) {
          throw new Error("Unsafe Guard journal file");
        }
        await handle.writeFile(line, "utf8");
      } finally { await handle.close(); }
    } finally { await release(); }
  }
  function failure(error: unknown): void {
    lastError = errorText(error); dropped++;
    if (!warned) { warned = true; try { warn(`Guard journal unavailable: ${lastError}`); } catch { /* Diagnostics only. */ } }
  }
  const writer: WorkspaceGuardJournalWriter = Object.freeze({
    schemaVersion: 2 as const, workspaceId, sessionId, kind, path,
    write(entry) {
      if (closed) { failure(new Error("Guard journal writer is closed")); return; }
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) { failure(new Error("Invalid Guard journal entry")); return; }
      if (pending >= maxPending) { failure(new Error("Guard journal queue is full")); return; }
      let line: string;
      try {
        line = JSON.stringify({ ...entry, journal: { schemaVersion: 2, kind, workspaceId, sessionId,
          writerId, processId: process.pid, sequence: ++sequence } }) + "\n";
        const size = Buffer.byteLength(line);
        if (size > MAX_RECORD_BYTES || size > maxBytes) throw new Error("Guard journal record exceeds its size limit");
      } catch (error) { failure(error); return; }
      pending++;
      queue = queue.then(async () => {
        try { await append(line); written++; lastError = undefined; warned = false; } catch (error) { failure(error); }
        finally { pending--; }
      });
    },
    flush: async () => { for (;;) { const batch = queue; await batch; if (batch === queue) return; } },
    close() { if (!closePromise) { closed = true; closePromise = writer.flush(); } return closePromise; },
    health: () => Object.freeze({ pending, dropped, written, lastError: lastError ?? null }),
  });
  return writer;
}

type WorkspaceReadCandidate = ReadCandidate;
export async function readWorkspaceGuardJournal(options: WorkspaceGuardJournalReadOptions, signal?: AbortSignal): Promise<WorkspaceGuardJournalSnapshot> {
  if (!options || options.schemaVersion !== 2 || typeof options.stateDir !== "string" || !options.stateDir) throw new Error("Invalid Guard journal workspace read options");
  const workspaceId = journalId(options.workspaceId, "workspace ID"), kind = journalKind(options.kind);
  const maxFiles = validateInteger(options.maxFiles ?? 128, 1, 4096, "read file limit");
  const maxFileBytes = validateInteger(options.maxFileBytes ?? 2 * 1024 * 1024, 64, 16 * 1024 * 1024, "per-file read limit");
  const maxTotalBytes = validateInteger(options.maxTotalBytes ?? 8 * 1024 * 1024, 64, 64 * 1024 * 1024, "total read limit");
  const maxRecords = validateInteger(options.maxRecords ?? 5000, 1, 100000, "record read limit");
  const stateDir = resolve(options.stateDir), notices: string[] = [], candidates: WorkspaceReadCandidate[] = [];
  let malformed = 0, unstable = 0;
  const snapshot = (records: WorkspaceGuardJournalRecord[], files: string[]): WorkspaceGuardJournalSnapshot => Object.freeze({
    records: Object.freeze(records.map(record => Object.freeze(record))), notices: Object.freeze([...notices]), files: Object.freeze(files),
    loadedAt: new Date().toISOString(), malformed, unstable,
  });
  try {
    signal?.throwIfAborted();
    const stateStat = await lstat(stateDir), resolvedState = await realpath(stateDir);
    if (!stateStat.isDirectory() || stateStat.isSymbolicLink() || resolvedState !== stateDir) throw new Error("State directory is redirected");
    const logs = join(stateDir, "logs"), workspace = join(logs, workspaceId);
    if (!await readableDirectory(logs) || !await readableDirectory(workspace)) return snapshot([], []);
    for (const entry of await readdir(workspace, { withFileTypes: true })) {
      signal?.throwIfAborted();
      const own = new RegExp(`^${kind}\\.jsonl(?:\\.[1-8])?$`).test(entry.name);
      if (!own) {
        if (entry.isDirectory() && JOURNAL_ID.test(entry.name)) continue;
        if (!/^(?:guardian|caf)\.jsonl(?:\.[1-8])?$/.test(entry.name) &&
            !/^\.(?:guardian|caf)-journal\.lock(?:\.stale\.[0-9a-f-]+)?$/.test(entry.name)) {
          notices.push(`${entry.name}: unexpected workspace log entry omitted.`);
        }
        continue;
      }
      try {
        const path = join(workspace, entry.name), source = entry.name, stat = await lstat(path);
        if (!entry.isFile() || !stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || !ownedByProcess(stat.uid) || (stat.mode & 0o777) !== 0o600) {
          throw new Error(`unsafe file: ${source}`);
        }
        candidates.push({ path, source, size: stat.size, mtimeMs: stat.mtimeMs, dev: stat.dev, ino: stat.ino });
      } catch (error) { notices.push(`${entry.name}: ${errorText(error)}; omitted.`); }
    }
  } catch (error) {
    if (signal?.aborted) throw signal.reason;
    notices.push(`Journals unavailable: ${errorText(error)}.`); return snapshot([], []);
  }
  candidates.sort((a, b) => b.mtimeMs - a.mtimeMs || a.source.localeCompare(b.source));
  if (candidates.length > maxFiles) notices.push(`${candidates.length - maxFiles} older journal file(s) omitted by the file limit.`);
  const selected = candidates.slice(0, maxFiles), records: (WorkspaceGuardJournalRecord & { time: number })[] = [], files: string[] = [];
  let remaining = maxTotalBytes;
  for (const candidate of selected) {
    signal?.throwIfAborted();
    if (remaining <= 0) { notices.push(`${candidate.source}: omitted by the total byte limit.`); continue; }
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(candidate.path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      const initial = await handle.stat();
      if (!initial.isFile() || initial.nlink !== 1 || !ownedByProcess(initial.uid) || (initial.mode & 0o777) !== 0o600) throw new Error("unsafe open file");
      const bytes = Math.min(initial.size, maxFileBytes, remaining), start = initial.size - bytes, buffer = Buffer.alloc(bytes); let offset = 0;
      while (offset < bytes) { signal?.throwIfAborted(); const result = await handle.read(buffer, offset, Math.min(64 * 1024, bytes - offset), start + offset); if (!result.bytesRead) break; offset += result.bytesRead; }
      remaining -= offset; files.push(candidate.source);
      if (start > 0) notices.push(`${candidate.source}: only the newest ${bytes} bytes read.`);
      const text = buffer.subarray(0, offset).toString("utf8"), lines = text.split("\n"), from = start > 0 ? 1 : 0;
      if (!text.endsWith("\n") && lines.at(-1)?.trim()) notices.push(`${candidate.source}: incomplete trailing record omitted.`);
      const until = text.endsWith("\n") ? lines.length : lines.length - 1;
      for (let index = from; index < until; index++) {
        if (!lines[index].trim()) continue;
        try {
          const value = JSON.parse(lines[index]); if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("not an object");
          const journal = value.journal && typeof value.journal === "object" && !Array.isArray(value.journal) ? value.journal as Record<string, unknown> : {};
          if (journal.schemaVersion !== 2 || journal.kind !== kind || journal.workspaceId !== workspaceId) throw new Error("wrong journal identity");
          const sessionId = journalId(journal.sessionId, "session ID"), writerId = journalId(journal.writerId, "writer ID");
          const rawTimestamp = typeof value.timestamp === "string" ? value.timestamp : null;
          const time = rawTimestamp === null ? 0 : Date.parse(rawTimestamp), sequence = readNumber(journal.sequence);
          records.push({ value, source: candidate.source, line: start > 0 ? null : index + 1, timestamp: Number.isFinite(time) ? rawTimestamp : null,
            sessionId, writerId, sequence, time: Number.isFinite(time) ? time : 0 });
        } catch { malformed++; }
      }
      const current = await lstat(candidate.path);
      if (current.dev !== candidate.dev || current.ino !== candidate.ino || current.size < candidate.size) { unstable++; notices.push(`${candidate.source}: replaced or truncated during the snapshot.`); }
    } catch (error) {
      if (signal?.aborted) throw signal.reason; notices.push(`${candidate.source}: ${errorText(error)}; omitted.`);
    } finally { await handle?.close(); }
  }
  records.sort((a, b) => a.time - b.time || a.sessionId.localeCompare(b.sessionId) || a.writerId.localeCompare(b.writerId) ||
    (a.sequence ?? 0) - (b.sequence ?? 0) || a.source.localeCompare(b.source) || (a.line ?? 0) - (b.line ?? 0));
  if (malformed) notices.push(`${malformed} malformed journal record(s) omitted.`);
  if (records.length > maxRecords) notices.push(`${records.length - maxRecords} older journal record(s) omitted by the record limit.`);
  return snapshot(records.slice(-maxRecords).map(({ time: _time, ...record }) => record), files);
}
