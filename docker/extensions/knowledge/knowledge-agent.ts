// SPDX-License-Identifier: MIT

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { lstat, mkdir, readlink, realpath, rename, rm, symlink, unlink } from "node:fs/promises";
import { Buffer } from "node:buffer";
import { join, relative, resolve, sep } from "node:path";

const SESSION_ID = /^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/;
const profileDirectory = resolve(process.env.PI_RUN_PROFILE_DIR || "/profile");
const knowledgeDirectory = resolve(profileDirectory, "knowledge");
const runtimeDirectory = resolve(process.env.PI_RUN_KNOWLEDGE_RUNTIME_DIR || "/run/pi-run-knowledge");
const currentLink = join(runtimeDirectory, "current");

function owned(uid: number): boolean {
    return typeof process.getuid !== "function" || uid === process.getuid();
}

function contained(parent: string, candidate: string): boolean {
    const path = relative(parent, candidate);
    return path !== "" && path !== ".." && !path.startsWith(`..${sep}`) && !path.startsWith(sep);
}

async function ensurePrivateDirectory(path: string): Promise<void> {
    await mkdir(path, { recursive: true, mode: 0o700 });
    const stat = await lstat(path);
    if (!stat.isDirectory() || stat.isSymbolicLink() || !owned(stat.uid) || (stat.mode & 0o077) !== 0 ||
        await realpath(path) !== path) throw new Error(`Unsafe knowledge directory: ${path}`);
}

function targetForSession(sessionId: string): string {
    if (!SESSION_ID.test(sessionId) || Buffer.byteLength(sessionId, "utf8") > 255) {
        throw new Error("Pi session identity is unsafe for knowledge storage");
    }
    const target = resolve(knowledgeDirectory, sessionId);
    if (!contained(knowledgeDirectory, target)) throw new Error("Pi session knowledge path escaped its storage root");
    return target;
}

async function selectKnowledge(sessionId: string): Promise<string> {
    await ensurePrivateDirectory(knowledgeDirectory);
    await ensurePrivateDirectory(runtimeDirectory);
    const target = targetForSession(sessionId);
    await ensurePrivateDirectory(target);

    const temporary = join(runtimeDirectory, `.current-${randomUUID()}`);
    try {
        await symlink(target, temporary, "dir");
        await rename(temporary, currentLink);
    } finally {
        await rm(temporary, { force: true });
    }
    return target;
}

async function clearKnowledge(target: string | undefined): Promise<void> {
    if (!target) return;
    try {
        const stat = await lstat(currentLink);
        if (!stat.isSymbolicLink() || await readlink(currentLink) !== target) return;
        await unlink(currentLink);
    } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
}

export default function knowledgeAgent(pi: ExtensionAPI): void {
    let activeTarget: string | undefined;

    pi.on("session_start", async (_event, ctx: ExtensionContext) => {
        try {
            activeTarget = await selectKnowledge(ctx.sessionManager.getSessionId());
        } catch (error) {
            activeTarget = undefined;
            const message = error instanceof Error ? error.message : String(error);
            ctx.ui.notify(`Session knowledge is unavailable: ${message}`, "error");
            throw error;
        }
    });

    pi.on("session_shutdown", async () => {
        const target = activeTarget;
        activeTarget = undefined;
        await clearKnowledge(target);
    });
}
