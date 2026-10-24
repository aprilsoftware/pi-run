// SPDX-License-Identifier: MIT
import { constants } from "node:fs";
import { lstat, mkdir, open, readdir, realpath, rename, unlink } from "node:fs/promises";
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

export interface GuardJournalReadOptionsV1 {
  schemaVersion: 1;
  stateDir: string;
  clientId: string;
  maxFiles?: number;
  maxFileBytes?: number;
  maxTotalBytes?: number;
  maxRecords?: number;
}
export interface GuardJournalRecordV1 {
  value: Record<string, unknown>;
  source: string;
  line: number | null;
  timestamp: string | null;
  runId: string;
  sequence: number | null;
}
export interface GuardJournalSnapshotV1 {
  records: readonly Readonly<GuardJournalRecordV1>[];
  notices: readonly string[];
  files: readonly string[];
  loadedAt: string;
  malformed: number;
  unstable: number;
}

type ReadCandidate = { path: string; source: string; size: number; mtimeMs: number; dev: number; ino: number };
const RUN_FILE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.jsonl(?:\.[1-8])?$/;
const LEGACY_FILE = /^events\.jsonl(?:\.[1-8])?$/;

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
function readIdentity(value: Record<string, unknown>, source: string, line: number): {timestamp:string|null;time:number;runId:string;sequence:number} {
  const journal = value.journal && typeof value.journal === "object" && !Array.isArray(value.journal)
    ? value.journal as Record<string, unknown> : {};
  const rawTimestamp = typeof value.timestamp === "string" ? value.timestamp :
    typeof journal.recordedAt === "string" ? journal.recordedAt : null;
  const time = rawTimestamp === null ? 0 : Date.parse(rawTimestamp);
  const runId = typeof journal.runId === "string" ? journal.runId : `legacy:${source}`;
  return { timestamp: Number.isFinite(time) ? rawTimestamp : null, time: Number.isFinite(time) ? time : 0,
    runId, sequence: readNumber(journal.sequence) ?? line };
}

export async function readGuardJournal(options: GuardJournalReadOptionsV1, signal?: AbortSignal): Promise<GuardJournalSnapshotV1> {
  if (!options || options.schemaVersion !== 1 || typeof options.stateDir !== "string" || !options.stateDir ||
      typeof options.clientId !== "string" || !/^[a-z][a-z0-9-]{0,63}$/.test(options.clientId)) {
    throw new Error("Invalid Guard journal read options");
  }
  const maxFiles = validateInteger(options.maxFiles ?? 128, 1, 4096, "read file limit");
  const maxFileBytes = validateInteger(options.maxFileBytes ?? 2 * 1024 * 1024, 64, 16 * 1024 * 1024, "per-file read limit");
  const maxTotalBytes = validateInteger(options.maxTotalBytes ?? 8 * 1024 * 1024, 64, 64 * 1024 * 1024, "total read limit");
  const maxRecords = validateInteger(options.maxRecords ?? 5000, 1, 100000, "record read limit");
  const stateDir = resolve(options.stateDir), notices: string[] = [], candidates: ReadCandidate[] = [];
  let malformed = 0, unstable = 0;
  const snapshot = (records: GuardJournalRecordV1[], files: string[]): GuardJournalSnapshotV1 => Object.freeze({
    records: Object.freeze(records.map(record => Object.freeze(record))), notices: Object.freeze([...notices]),
    files: Object.freeze(files), loadedAt: new Date().toISOString(), malformed, unstable,
  });
  try {
    signal?.throwIfAborted();
    const stateStat = await lstat(stateDir), resolvedState = await realpath(stateDir);
    if (!stateStat.isDirectory() || stateStat.isSymbolicLink() || resolvedState !== stateDir) throw new Error("State directory is redirected");
    const logs = join(stateDir,"logs"),client = join(logs, options.clientId);
    if (!await readableDirectory(logs) || !await readableDirectory(client)) return snapshot([], []);
    for (const [kind, pattern] of [["runs", RUN_FILE], ["legacy", LEGACY_FILE]] as const) {
      const directory = join(client, kind);
      if (!await readableDirectory(directory)) continue;
      for (const entry of await readdir(directory, { withFileTypes: true })) {
        signal?.throwIfAborted();
        const source = `${kind}/${entry.name}`, path = join(directory, entry.name);
        if (!pattern.test(entry.name)) { notices.push(`${source}: unexpected entry omitted.`); continue; }
        try {
          const stat = await lstat(path);
          if (!entry.isFile() || !stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 ||
              !ownedByProcess(stat.uid) || (stat.mode & 0o777) !== 0o600) throw new Error("unsafe file");
          candidates.push({ path, source, size: stat.size, mtimeMs: stat.mtimeMs, dev: stat.dev, ino: stat.ino });
        } catch (error) { notices.push(`${source}: ${errorText(error)}; omitted.`); }
      }
    }
  } catch (error) {
    if (signal?.aborted) throw signal.reason;
    notices.push(`Journals unavailable: ${errorText(error)}.`);
    return snapshot([], []);
  }
  candidates.sort((a, b) => b.mtimeMs - a.mtimeMs || a.source.localeCompare(b.source));
  if (candidates.length > maxFiles) notices.push(`${candidates.length - maxFiles} older journal file(s) omitted by the file limit.`);
  const selected = candidates.slice(0, maxFiles), records: (GuardJournalRecordV1 & {time:number})[] = [], files: string[] = [];
  let remaining = maxTotalBytes;
  for (const candidate of selected) {
    signal?.throwIfAborted();
    if (remaining <= 0) { notices.push(`${candidate.source}: omitted by the total byte limit.`); continue; }
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(candidate.path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      const initial = await handle.stat();
      if (!initial.isFile() || initial.nlink !== 1 || !ownedByProcess(initial.uid) || (initial.mode & 0o777) !== 0o600) {
        throw new Error("unsafe open file");
      }
      const bytes = Math.min(initial.size, maxFileBytes, remaining), start = initial.size - bytes;
      const buffer = Buffer.alloc(bytes); let offset = 0;
      while (offset < bytes) {
        signal?.throwIfAborted();
        const result = await handle.read(buffer, offset, Math.min(64 * 1024, bytes - offset), start + offset);
        if (!result.bytesRead) break;
        offset += result.bytesRead;
      }
      remaining -= offset; files.push(candidate.source);
      if (start > 0) notices.push(`${candidate.source}: only the newest ${bytes} bytes read.`);
      const text = buffer.subarray(0, offset).toString("utf8"), lines = text.split("\n"), from = start > 0 ? 1 : 0;
      if (!text.endsWith("\n") && lines.at(-1)?.trim()) notices.push(`${candidate.source}: incomplete trailing record omitted.`);
      const until = text.endsWith("\n") ? lines.length : lines.length - 1;
      for (let index = from; index < until; index++) {
        const raw = lines[index]; if (!raw.trim()) continue;
        try {
          const value = JSON.parse(raw);
          if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("not an object");
          const identity = readIdentity(value, candidate.source, index + 1);
          records.push({ value, source: candidate.source, line: start > 0 ? null : index + 1,
            timestamp: identity.timestamp, runId: identity.runId, sequence: identity.sequence, time: identity.time });
        } catch { malformed++; }
      }
      try {
        const current = await lstat(candidate.path);
        if (current.dev !== candidate.dev || current.ino !== candidate.ino || current.size < candidate.size) {
          unstable++; notices.push(`${candidate.source}: replaced or truncated during the snapshot.`);
        }
      } catch (error) {
        unstable++; notices.push(`${candidate.source}: could not verify snapshot: ${errorText(error)}.`);
      }
    } catch (error) {
      if (signal?.aborted) throw signal.reason;
      notices.push(`${candidate.source}: ${errorText(error)}; omitted.`);
    } finally { await handle?.close(); }
  }
  records.sort((a, b) => a.time - b.time || a.runId.localeCompare(b.runId) ||
    (a.sequence ?? 0) - (b.sequence ?? 0) || a.source.localeCompare(b.source) || (a.line ?? 0) - (b.line ?? 0));
  if (malformed) notices.push(`${malformed} malformed journal record(s) omitted.`);
  if (records.length > maxRecords) notices.push(`${records.length - maxRecords} older journal record(s) omitted by the record limit.`);
  const retained = records.slice(-maxRecords).map(({time: _time, ...record}) => record);
  return snapshot(retained, files);
}
