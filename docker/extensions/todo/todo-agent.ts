// SPDX-License-Identifier: MIT

import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { constants } from "node:fs";
import { lstat, mkdir, open, realpath, rename, rm } from "node:fs/promises";
import { resolve } from "node:path";
import { randomUUID } from "node:crypto";

interface TodoItem {
    id: number;
    text: string;
}

interface TodoState {
    schemaVersion: 1;
    sessionId: string;
    nextId: number;
    items: TodoItem[];
}

const MAX_ITEMS = 100;
const MAX_ITEM_BYTES = 16 * 1024;
const MAX_STATE_BYTES = 2 * 1024 * 1024;
const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const stateDirectory = resolve(process.env.PI_RUN_PROFILE_DIR || "/profile", "todos");

function missing(error: unknown): boolean {
    return !!error && typeof error === "object" && "code" in error && error.code === "ENOENT";
}

function owned(uid: number): boolean {
    return typeof process.getuid !== "function" || uid === process.getuid();
}

function emptyState(sessionId: string): TodoState {
    return { schemaVersion: 1, sessionId, nextId: 1, items: [] };
}

function parseState(value: unknown, sessionId: string): TodoState {
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("state is not an object");
    const state = value as Partial<TodoState>;
    if (state.schemaVersion !== 1 || state.sessionId !== sessionId || !Number.isSafeInteger(state.nextId) || state.nextId! < 1 ||
        state.nextId! >= Number.MAX_SAFE_INTEGER || !Array.isArray(state.items) || state.items.length > MAX_ITEMS) throw new Error("state schema is invalid");
    const seen = new Set<number>();
    const items = state.items.map((candidate) => {
        if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) throw new Error("item schema is invalid");
        const item = candidate as Partial<TodoItem>;
        if (!Number.isSafeInteger(item.id) || item.id! < 1 || seen.has(item.id!) || typeof item.text !== "string" ||
            !item.text.trim() || Buffer.byteLength(item.text, "utf8") > MAX_ITEM_BYTES) throw new Error("item schema is invalid");
        seen.add(item.id!);
        return { id: item.id!, text: item.text };
    });
    if (items.some((item) => item.id >= state.nextId!)) throw new Error("state sequence is invalid");
    return { schemaVersion: 1, sessionId, nextId: state.nextId!, items };
}

function sessionPath(sessionId: string): string {
    if (!SESSION_ID.test(sessionId)) throw new Error("session identity is invalid");
    return resolve(stateDirectory, `${sessionId}.json`);
}

async function ensureStateDirectory(): Promise<void> {
    await mkdir(stateDirectory, { recursive: true, mode: 0o700 });
    const stat = await lstat(stateDirectory);
    if (!stat.isDirectory() || stat.isSymbolicLink() || !owned(stat.uid) || (stat.mode & 0o077) !== 0 ||
        await realpath(stateDirectory) !== stateDirectory) throw new Error("Todo state directory is unsafe");
}

async function loadState(sessionId: string): Promise<TodoState> {
    await ensureStateDirectory();
    const path = sessionPath(sessionId);
    let file;
    try {
        file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
        const stat = await file.stat();
        if (!stat.isFile() || stat.nlink !== 1 || !owned(stat.uid) || (stat.mode & 0o077) !== 0 ||
            stat.size > MAX_STATE_BYTES) throw new Error("Todo state file is unsafe");
        return parseState(JSON.parse(await file.readFile("utf8")), sessionId);
    } catch (error) {
        if (missing(error)) return emptyState(sessionId);
        throw error;
    } finally {
        await file?.close();
    }
}

async function saveState(state: TodoState): Promise<void> {
    await ensureStateDirectory();
    const path = sessionPath(state.sessionId);
    const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`;
    let file;
    try {
        file = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
        await file.writeFile(`${JSON.stringify(state)}\n`);
        await file.sync();
        await file.close();
        file = undefined;
        await rename(temporary, path);
    } finally {
        await file?.close();
        await rm(temporary, { force: true });
    }
}

function summary(text: string): string {
    const first = text.split(/\r?\n/).find((line) => line.trim())?.trim() || "(empty)";
    const safe = first.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ");
    return safe.length > 72 ? `${safe.slice(0, 69)}...` : safe;
}

export default function todoAgent(pi: ExtensionAPI): void {
    let activeSessionId: string | undefined;
    let state: TodoState | undefined;
    let stateError: string | undefined;

    function updateStatus(ctx: ExtensionContext): void {
        ctx.ui.setStatus("todo", stateError ? "Todo: unavailable" : state?.items.length ? `Todo: ${state.items.length}` : undefined);
    }

    async function activate(ctx: ExtensionContext): Promise<void> {
        const sessionId = ctx.sessionManager.getSessionId();
        if (sessionId === activeSessionId && (state || stateError)) return;
        activeSessionId = sessionId;
        try {
            state = await loadState(sessionId);
            stateError = undefined;
        } catch (error) {
            state = undefined;
            stateError = error instanceof Error ? error.message : String(error);
        }
        updateStatus(ctx);
    }

    async function persist(next: TodoState, ctx: ExtensionContext, message: string): Promise<boolean> {
        try {
            await saveState(next);
            state = next;
            stateError = undefined;
            updateStatus(ctx);
            ctx.ui.notify(message, "info");
            return true;
        } catch (error) {
            state = undefined;
            stateError = error instanceof Error ? error.message : String(error);
            updateStatus(ctx);
            ctx.ui.notify(`Todo state was not saved: ${stateError}`, "error");
            return false;
        }
    }

    pi.on("session_start", async (_event, ctx) => activate(ctx));
    pi.registerCommand("todo", {
        description: "Open the session Todo prompt queue",
        handler: async (args: string, ctx: ExtensionCommandContext) => {
            if (args.trim()) { ctx.ui.notify("Usage: /todo", "error"); return; }
            if (ctx.mode !== "tui") { ctx.ui.notify("/todo requires interactive mode", "error"); return; }
            await activate(ctx);
            if (!state) { ctx.ui.notify(`Todo state is unavailable: ${stateError || "unknown error"}`, "error"); return; }
            while (true) {
                const itemChoices = state.items.map((item, index) => `${index + 1}. #${item.id} ${summary(item.text)}`);
                const choices = ["New prompt...", ...itemChoices, "Close"];
                const selected = await ctx.ui.select(`Todo — ${state.items.length} queued`, choices);
                if (selected === undefined || selected === "Close") return;
                if (selected === "New prompt...") {
                    if (state.items.length >= MAX_ITEMS) { ctx.ui.notify(`Todo is limited to ${MAX_ITEMS} items`, "error"); continue; }
                    const text = (await ctx.ui.editor("New Todo prompt"))?.replace(/\r\n/g, "\n");
                    if (text === undefined) continue;
                    if (!text.trim()) { ctx.ui.notify("Todo text cannot be empty", "error"); continue; }
                    if (Buffer.byteLength(text, "utf8") > MAX_ITEM_BYTES) {
                        ctx.ui.notify(`Todo text is limited to ${MAX_ITEM_BYTES / 1024} KiB`, "error");
                        continue;
                    }
                    const next: TodoState = { ...state, nextId: state.nextId + 1, items: [...state.items, { id: state.nextId, text }] };
                    if (!(await persist(next, ctx, "Todo prompt added"))) return;
                    continue;
                }
                const index = itemChoices.indexOf(selected);
                if (index < 0) continue;
                const item = state.items[index];
                const actions = ["Use as next prompt", "Edit", "Delete", ...(index > 0 ? ["Move up"] : []),
                    ...(index < state.items.length - 1 ? ["Move down"] : []), "Back"];
                const action = await ctx.ui.select(`Todo #${item.id}`, actions);
                if (action === undefined || action === "Back") continue;
                if (action === "Use as next prompt") {
                    const current = ctx.ui.getEditorText();
                    let prompt = item.text;
                    if (current.length > 0) {
                        const collision = await ctx.ui.select("Prompt editor already contains text", [
                            "Replace editor text", "Append after editor text", "Cancel",
                        ]);
                        if (collision === undefined || collision === "Cancel") continue;
                        if (collision === "Append after editor text") {
                            const trailingNewlines = current.match(/\n*$/)?.[0].length || 0;
                            const leadingNewlines = item.text.match(/^\n*/)?.[0].length || 0;
                            prompt = `${current}${"\n".repeat(Math.max(0, 2 - trailingNewlines - leadingNewlines))}${item.text}`;
                        }
                    }
                    ctx.ui.setEditorText(prompt);
                    ctx.ui.notify("Todo prompt loaded into the editor", "info");
                    return;
                }
                if (action === "Edit") {
                    const text = (await ctx.ui.editor("Edit Todo prompt", item.text))?.replace(/\r\n/g, "\n");
                    if (text === undefined) continue;
                    if (!text.trim()) { ctx.ui.notify("Todo text cannot be empty", "error"); continue; }
                    if (Buffer.byteLength(text, "utf8") > MAX_ITEM_BYTES) {
                        ctx.ui.notify(`Todo text is limited to ${MAX_ITEM_BYTES / 1024} KiB`, "error");
                        continue;
                    }
                    const items = [...state.items];
                    items[index] = { ...item, text };
                    if (!(await persist({ ...state, items }, ctx, "Todo prompt updated"))) return;
                    continue;
                }
                if (action === "Delete") {
                    if (!(await ctx.ui.confirm("Delete Todo prompt?", "This removes the selected queued prompt."))) continue;
                    const items = state.items.filter((_, candidate) => candidate !== index);
                    if (!(await persist({ ...state, items }, ctx, "Todo prompt deleted"))) return;
                    continue;
                }
                const target = action === "Move up" ? index - 1 : action === "Move down" ? index + 1 : index;
                if (target === index || target < 0 || target >= state.items.length) continue;
                const items = [...state.items];
                [items[index], items[target]] = [items[target], items[index]];
                if (!(await persist({ ...state, items }, ctx, "Todo prompt moved"))) return;
            }
        },
    });
}
