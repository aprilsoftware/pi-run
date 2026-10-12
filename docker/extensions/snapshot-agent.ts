// SPDX-License-Identifier: MIT

import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { link, lstat, open, unlink } from "node:fs/promises";
import { basename, isAbsolute, join } from "node:path";
import { randomUUID } from "node:crypto";

const ACTIONS = ["status", "list", "create", "check"] as const;
type SnapshotAction = typeof ACTIONS[number];

async function writeRequest(
    action: SnapshotAction,
    resumeSessionId: string | null,
    resumeSessionFile: string | null,
): Promise<void> {
    const token = process.env.PI_RUN_SNAPSHOT_TOKEN ?? "";
    const directory = process.env.PI_RUN_SNAPSHOT_REQUEST_DIR ?? "";
    if (!isAbsolute(directory) || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(token)) {
        throw new Error("Pi-Run snapshot request channel is unavailable");
    }
    if ((resumeSessionId === null) !== (resumeSessionFile === null)) {
        throw new Error("the current Pi session identity is incomplete");
    }
    if (resumeSessionId !== null && !/^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/.test(resumeSessionId)) {
        throw new Error("the current Pi session ID is invalid");
    }
    if (resumeSessionFile !== null && (
        resumeSessionFile.length > 255 ||
        !resumeSessionFile.endsWith(".jsonl") ||
        basename(resumeSessionFile) !== resumeSessionFile ||
        /[\\/]/.test(resumeSessionFile) ||
        !/^[\x20-\x7e]+$/.test(resumeSessionFile)
    )) {
        throw new Error("the current Pi session filename is invalid");
    }
    const target = join(directory, "request.json");
    const temporary = join(directory, `.request.${process.pid}.${randomUUID()}`);
    let handle;
    try {
        handle = await open(temporary, "wx", 0o600);
        await handle.writeFile(`${JSON.stringify({ schemaVersion: 3, token, action, resumeSessionId, resumeSessionFile })}\n`, "utf8");
        await handle.sync();
        await handle.close();
        handle = undefined;
        await link(temporary, target);
        await unlink(temporary);
        const directoryHandle = await open(directory, "r");
        try {
            await directoryHandle.sync();
        } finally {
            await directoryHandle.close();
        }
    } catch (error) {
        if (handle) await handle.close().catch(() => undefined);
        await unlink(temporary).catch(() => undefined);
        throw error;
    }
}

async function resumableSessionIdentity(ctx: ExtensionCommandContext): Promise<{
    resumeSessionId: string | null;
    resumeSessionFile: string | null;
}> {
    const sessionFile = ctx.sessionManager.getSessionFile();
    if (!sessionFile) return { resumeSessionId: null, resumeSessionFile: null };

    let metadata;
    try {
        metadata = await lstat(sessionFile);
    } catch (error) {
        if (error && typeof error === "object" && "code" in error && error.code === "ENOENT") {
            return { resumeSessionId: null, resumeSessionFile: null };
        }
        throw new Error(`could not inspect the current Pi session file: ${sessionFile}`);
    }
    if (!metadata.isFile() || metadata.isSymbolicLink()) {
        throw new Error(`the current Pi session must be a regular non-symlink file: ${sessionFile}`);
    }
    return {
        resumeSessionId: ctx.sessionManager.getSessionId(),
        resumeSessionFile: basename(sessionFile),
    };
}

async function chooseAction(ctx: ExtensionCommandContext): Promise<SnapshotAction | undefined> {
    const choice = await ctx.ui.select("Pi-Run snapshots", [
        "Status",
        "List snapshots",
        "Create complete snapshot",
        "Run full integrity check",
        "Cancel",
    ]);
    if (choice === "Status") return "status";
    if (choice === "List snapshots") return "list";
    if (choice === "Create complete snapshot") {
        return await ctx.ui.confirm(
            "Create snapshot?",
            "Pi will briefly exit for snapshot creation, then restart.",
        ) ? "create" : undefined;
    }
    if (choice === "Run full integrity check") {
        return await ctx.ui.confirm(
            "Run full integrity check?",
            "Pi will briefly exit for the integrity check, then restart. S3 checks download all data and may incur bandwidth or provider charges.",
        ) ? "check" : undefined;
    }
    return undefined;
}

export default function snapshotAgent(pi: ExtensionAPI): void {
    pi.registerCommand("snapshot", {
        description: "Request a host-side Pi-Run snapshot operation",
        handler: async (_args, ctx) => {
            if (ctx.mode !== "tui") {
                ctx.ui.notify("/snapshot requires interactive TUI mode", "error");
                return;
            }
            const action = await chooseAction(ctx);
            if (!action) {
                ctx.ui.notify("Snapshot request cancelled", "info");
                return;
            }
            try {
                const { resumeSessionId, resumeSessionFile } = await resumableSessionIdentity(ctx);
                await writeRequest(action, resumeSessionId, resumeSessionFile);
                const restartMessage = resumeSessionId
                    ? "Pi will briefly exit for host-side execution, then reopen this session."
                    : "Pi will briefly exit for host-side execution, then restart with a fresh session; this session has no saved transcript to reopen.";
                ctx.ui.notify(`Snapshot ${action} requested. ${restartMessage}`, "info");
                ctx.shutdown();
            } catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                ctx.ui.notify(`Could not request snapshot operation: ${message}`, "error");
            }
        },
    });
}
