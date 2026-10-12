// SPDX-License-Identifier: MIT

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type, type Static } from "typebox";
import { Check } from "typebox/value";
import { constants } from "node:fs";
import { link, open, realpath, unlink, type FileHandle } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { createHash, randomUUID } from "node:crypto";

const ENTRY = "pi-run-plan";
const DRAFT_ENTRY = "pi-run-plan-draft";
const DISCARD_ENTRY = "pi-run-plan-discard";
const APPROVAL_ENTRY = "pi-run-plan-approval";
const RECORD = "plan_record";
const Text = Type.String({ minLength: 1, maxLength: 2000, pattern: "\\S" });
const DraftSchema = Type.Object({
    title: Type.String({ minLength: 1, maxLength: 200, pattern: "\\S" }),
    goal: Text,
    body: Type.String({ minLength: 1, maxLength: 30000, pattern: "\\S", description: "The full plan in Markdown; choose its structure to suit the goal and discussion" }),
}, { additionalProperties: false });
const StoredDraftSchema = Type.Object({
    schemaVersion: Type.Literal(2), draft: DraftSchema,
}, { additionalProperties: false });
type Draft = Static<typeof DraftSchema>;
interface DraftRevision { id: string; draft: Draft }
const ApprovalSchema = Type.Object({
    schemaVersion: Type.Literal(2),
    draftEntryId: Type.String({ minLength: 1 }),
    planHash: Type.String({ pattern: "^[a-f0-9]{64}$" }),
}, { additionalProperties: false });
const INSTRUCTIONS = `Planning mode: investigate the user's goal and discuss a plan; do not implement or execute the planned work.
Follow the current conversation and applicable AGENTS.md instructions. Use normal tools
for investigation, including writing and running investigative scripts, within that scope.
Resolve ordinary uncertainty from evidence; discuss meaningful alternatives and unresolved choices.
Develop the overall plan with the user. Choose its structure to suit the goal: desired
outcomes, scope, approach, steps, risks, and validation where useful. Do not force an
implementation proposal, file list, diff estimate, or a next increment into planning.
Agreement during discussion is not a request to begin implementation automatically.
Use plan_record to save and refine the current plan as a title, goal, and full Markdown body.
Recording updates session metadata only; it does not approve work or edit project files.
The user can export with /plan-export, approve with /plan-approve, or abandon with /plan-exit.
Continue planning until /plan-approve confirms the saved plan or /plan-exit abandons it.
Approval hands work back to the normal AGENTS.md implementation/execution workflow;
do not duplicate that workflow here.
Planning changes the objective, not tool permissions. Guardian remains independent;
report evidence limitations rather than inventing findings.`;

interface PlanState {
    schemaVersion: 2;
    enabled: boolean;
}

function validDraft(data: unknown): data is Draft {
    return Check(DraftSchema, data) && Buffer.byteLength(JSON.stringify(data), "utf8") <= 32768;
}

function renderDraft(draft: Draft, approved?: boolean): string {
    const notice = approved === undefined
        ? "**Exported plan. Exporting does not grant approval; execution follows applicable AGENTS.md instructions.**"
        : approved ? "**Plan approved for this saved revision. Execution follows applicable AGENTS.md instructions.**"
        : "**Not approved. Recording or displaying a plan does not approve work.**";
    return [`# Plan: ${draft.title}`, notice, "## Goal", draft.goal, draft.body].join("\n\n");
}

function activeDraftEntry(ctx: ExtensionContext) {
    return [...ctx.sessionManager.getBranch()].reverse().find(item => item.type === "custom" &&
        (item.customType === DRAFT_ENTRY || item.customType === DISCARD_ENTRY));
}

function currentDraftRevision(ctx: ExtensionContext): DraftRevision {
    const entry = activeDraftEntry(ctx);
    if (!entry || entry.type !== "custom" || entry.customType === DISCARD_ENTRY) throw new Error("No active plan on this branch. Use /plan <goal> to prepare one.");
    const data = entry.type === "custom" ? entry.data : undefined;
    if (!Check(StoredDraftSchema, data) || Buffer.byteLength(JSON.stringify(data.draft), "utf8") > 32768) {
        throw new Error("Saved draft is invalid or unsupported. Record a new draft in planning mode; no approval is implied.");
    }
    if (typeof entry.id !== "string" || !entry.id) throw new Error("Saved draft has no revision identity; record a new draft.");
    return { id: entry.id, draft: data.draft };
}

function currentDraft(ctx: ExtensionContext): Draft {
    return currentDraftRevision(ctx).draft;
}

function planHash(draft: Draft): string {
    return createHash("sha256").update(JSON.stringify([draft.title, draft.goal, draft.body])).digest("hex");
}

function approvalRecorded(ctx: ExtensionContext, revision: DraftRevision): boolean {
    const entry = [...ctx.sessionManager.getBranch()].reverse().find(
        item => item.type === "custom" && item.customType === APPROVAL_ENTRY,
    );
    const data = entry?.type === "custom" ? entry.data : undefined;
    return Check(ApprovalSchema, data) && data.draftEntryId === revision.id && data.planHash === planHash(revision.draft);
}

function errorText(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
}

function draftView(ctx: ExtensionContext): string {
    try {
        const revision = currentDraftRevision(ctx);
        return renderDraft(revision.draft, approvalRecorded(ctx, revision));
    } catch (error) { return errorText(error); }
}

async function exportDraft(cwd: string, path: string, content: string): Promise<void> {
    if (!path || isAbsolute(path) || !path.endsWith(".md") || /[\\\x00-\x1f\x7f]/.test(path)) {
        throw new Error("Use an explicit workspace-relative .md path without control characters or backslashes.");
    }
    const parts = path.split("/");
    if (parts.some(part => !part || part === "..")) throw new Error("Empty path components and traversal are not allowed.");
    const components = parts.filter(part => part !== ".");
    const filename = components.pop()!;
    const directories: FileHandle[] = [];
    let handle: FileHandle | undefined;
    let temporary: string | undefined;
    let published = false;
    try {
        // Pi-Run is Linux-only. Pin directory descriptors so an ancestor swapped
        // for a symlink cannot redirect publication or temporary-file cleanup.
        const flags = constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW;
        let directory = await open(await realpath(cwd), flags);
        directories.push(directory);
        for (const component of components) {
            directory = await open(`/proc/self/fd/${directory.fd}/${component}`, flags);
            directories.push(directory);
        }
        const parent = `/proc/self/fd/${directory.fd}`;
        const candidate = `${parent}/.pi-run-plan-export-${randomUUID()}`;
        handle = await open(candidate, "wx", 0o600);
        temporary = candidate; // Cleanup only files this invocation created.
        await handle.writeFile(`${content}\n`, "utf8");
        await handle.sync();
        await handle.close();
        handle = undefined;
        // Atomic create-only publication: existing files, directories, and even
        // dangling symlinks fail rather than being replaced or followed.
        await link(temporary, `${parent}/${filename}`);
        published = true;
        await unlink(temporary);
        temporary = undefined;
        await directory.sync();
    } catch (error) {
        await handle?.close().catch(() => undefined);
        handle = undefined;
        let cleanupError = "";
        if (temporary) {
            try { await unlink(temporary); }
            catch (cleanup) { cleanupError = ` Temporary-file cleanup failed: ${errorText(cleanup)}`; }
        }
        throw new Error(`${published ? "Export file was created, but finalization failed; inspect it before retrying" : "Export was not published"}: ${errorText(error)}${cleanupError}`);
    } finally {
        await handle?.close().catch(() => undefined);
        for (const directory of directories.reverse()) await directory.close().catch(() => undefined);
    }
}

function validState(data: unknown): data is PlanState {
    if (!data || typeof data !== "object") return false;
    const state = data as PlanState;
    return state.schemaVersion === 2 && typeof state.enabled === "boolean";
}

export default function planAgent(pi: ExtensionAPI): void {
    let enabled = false;
    type PlanIndicator = { enabled: boolean; redraw?: () => void };
    const indicator: PlanIndicator = { enabled: false };

    function installIndicator(ctx: ExtensionContext): void {
        if (ctx.mode !== "tui") return;
        indicator.enabled = enabled;
        try {
            // Clear the former footer status. This widget is owned only by planning;
            // extension load order places it immediately above Guardian's widget.
            ctx.ui.setStatus(ENTRY, undefined);
            ctx.ui.setWidget(ENTRY, (tui, theme) => {
                indicator.redraw = () => tui.requestRender();
                return { render: () => indicator.enabled ? [theme.fg("muted", "planning")] : [], invalidate() {} };
            }, { placement: "belowEditor" });
        } catch { indicator.redraw = undefined; }
    }

    function status(ctx: ExtensionContext): void {
        if (ctx.mode !== "tui") return;
        indicator.enabled = enabled;
        indicator.redraw?.();
    }

    function syncRecorder(): void {
        const tools = pi.getActiveTools();
        if (enabled && !tools.includes(RECORD)) pi.setActiveTools([...tools, RECORD]);
        if (!enabled && tools.includes(RECORD)) pi.setActiveTools(tools.filter(name => name !== RECORD));
    }

    function restore(ctx: ExtensionContext): void {
        const branch = [...ctx.sessionManager.getBranch()].reverse();
        const entry = branch.find(item => item.type === "custom" && item.customType === ENTRY);
        const data = entry?.type === "custom" ? entry.data : undefined;
        // Retain guidance for invalid state, but never impose a tool blockade.
        enabled = entry ? !validState(data) || data.enabled : false;
        syncRecorder();
        status(ctx);
        if (entry && !validState(data) && ctx.hasUI) {
            ctx.ui.notify("Saved planning state is invalid; planning guidance retained.", "warning");
        }
    }

    pi.registerTool({
        name: RECORD,
        label: "Record plan draft",
        description: "Save or refine the active branch's plan: title, goal, and full Markdown body. Planning is discussion and design, not an implementation increment. Recording is not approval; no project files are changed.",
        exposure: "model-only",
        defaultActive: false,
        executionMode: "sequential",
        parameters: DraftSchema,
        async execute(_id, params, signal) {
            if (!enabled) throw new Error("plan_record requires planning mode");
            if (signal?.aborted) throw new Error("Draft recording cancelled");
            if (!validDraft(params)) throw new Error("Invalid draft: required fields must be nonblank and the draft must fit within 32 KiB");
            const draft = structuredClone(params);
            pi.appendEntry(DRAFT_ENTRY, { schemaVersion: 2, draft });
            return { content: [{ type: "text", text: renderDraft(draft, false) }], details: undefined };
        },
    });

    pi.on("session_start", (_event, ctx) => { installIndicator(ctx); restore(ctx); });
    pi.on("session_tree", (_event, ctx) => { installIndicator(ctx); restore(ctx); });
    pi.on("session_shutdown", (_event, ctx) => {
        if (ctx.mode !== "tui") return;
        indicator.redraw = undefined;
        try {
            ctx.ui.setStatus(ENTRY, undefined);
            ctx.ui.setWidget(ENTRY, undefined, { placement: "belowEditor" });
        } catch { /* Presentation never changes planning state. */ }
    });

    function setPlanning(next: boolean, ctx: ExtensionContext): void {
        if (next !== enabled) {
            enabled = next;
            pi.appendEntry(ENTRY, { schemaVersion: 2, enabled } satisfies PlanState);
        }
        syncRecorder();
        status(ctx);
        if (ctx.hasUI) ctx.ui.notify(enabled
            ? "Planning mode enabled: investigate the goal and discuss the plan. Export, approve, or exit when ready."
            : "Planning mode exited. Normal tools unchanged; execution follows applicable AGENTS.md instructions.", "info");
    }

    function discardDraft(ctx: ExtensionContext): void {
        const entry = activeDraftEntry(ctx);
        if (entry?.type === "custom" && entry.customType === DRAFT_ENTRY) pi.appendEntry(DISCARD_ENTRY, { schemaVersion: 2 });
    }

    pi.registerCommand("plan", {
        description: "Investigate and discuss a plan: [goal]",
        handler: async (args, ctx) => {
            await ctx.waitForIdle();
            const goal = args.trim();
            if (goal) discardDraft(ctx);
            setPlanning(true, ctx);
            if (goal) pi.sendUserMessage(`Plan only: ${goal}`);
        },
    });

    pi.registerCommand("plan-exit", {
        description: "Exit planning without approval and discard the active draft (exports/history are kept)",
        handler: async (args, ctx) => {
            await ctx.waitForIdle();
            if (args.trim()) {
                pi.sendMessage({ customType: "pi-run-plan-command-hint", content: "Usage: /plan-exit (no arguments)", display: true }, { triggerTurn: false });
                return;
            }
            discardDraft(ctx);
            setPlanning(false, ctx);
            pi.sendMessage({ customType: "pi-run-plan-exit", content: "Planning exited; active draft discarded without approval. Exports and conversation history are unchanged.", display: true }, { triggerTurn: false });
        },
    });

    pi.registerCommand("plan-show", {
        description: "Display the active branch's saved draft without changing planning mode",
        handler: async (args, ctx) => {
            await ctx.waitForIdle();
            pi.sendMessage({ customType: "pi-run-plan-view", content: args.trim()
                ? "Usage: /plan-show (no arguments)" : draftView(ctx), display: true }, { triggerTurn: false });
        },
    });

    pi.registerCommand("plan-approve", {
        description: "Approve the saved plan, exit planning, and hand work to the normal AGENTS.md workflow",
        handler: async (args, ctx) => {
            await ctx.waitForIdle();
            let content: string;
            let handoff: string | undefined;
            try {
                if (args.trim()) throw new Error("Usage: /plan-approve (no arguments)");
                if (!ctx.hasUI) throw new Error("A confirmation UI is required; no approval was recorded.");
                const revision = currentDraftRevision(ctx);
                if (approvalRecorded(ctx, revision)) {
                    setPlanning(false, ctx);
                    content = "This saved plan is already approved. Planning exited; no additional work handoff was sent.";
                } else {
                    const session = ctx.sessionManager.getSessionId(), leaf = ctx.sessionManager.getLeafId();
                    const hash = planHash(revision.draft);
                    const confirmed = await ctx.ui.confirm("Approve this plan and begin the normal workflow?",
                        `${renderDraft(revision.draft, false)}\n\nApprove the work described in this exact saved plan, exit planning, and hand it to the agent under applicable AGENTS.md instructions. This does not authorize automatic execution of every step or change Guardian.`);
                    if (confirmed !== true) {
                        content = "Approval cancelled. No approval was recorded.";
                    } else {
                        const current = currentDraftRevision(ctx);
                        if (session !== ctx.sessionManager.getSessionId() || leaf !== ctx.sessionManager.getLeafId() ||
                            revision.id !== current.id || hash !== planHash(current.draft)) {
                            throw new Error("Session, branch, or proposal changed during confirmation. Review it again; no approval was recorded.");
                        }
                        pi.appendEntry(APPROVAL_ENTRY, { schemaVersion: 2, draftEntryId: revision.id, planHash: hash });
                        setPlanning(false, ctx);
                        content = "Plan approved; planning exited. Handing work to the normal AGENTS.md workflow. Guardian is unchanged.";
                        handoff = `Apply the current conversation and applicable AGENTS.md implementation/execution workflow to this approved plan. Follow its approval checkpoints; do not automatically execute the entire plan.\n\n${renderDraft(revision.draft, true)}`;
                    }
                }
            } catch (error) {
                content = `Plan approval not recorded: ${errorText(error)}`;
            }
            pi.sendMessage({ customType: "pi-run-plan-approval-result", content, display: true }, { triggerTurn: false });
            if (handoff) pi.sendUserMessage(handoff);
        },
    });

    pi.registerCommand("plan-export", {
        description: "Export the branch's draft to a new workspace-relative .md file (parent must exist)",
        handler: async (args, ctx) => {
            await ctx.waitForIdle();
            const path = args.trim();
            let content: string;
            try {
                if (!path) throw new Error("Usage: /plan-export <workspace-relative.md>");
                await exportDraft(ctx.cwd, path, renderDraft(currentDraft(ctx)));
                content = `Draft exported to ${JSON.stringify(path)}. This is not implementation approval.`;
            } catch (error) {
                content = `Plan export failed: ${JSON.stringify(path)} — ${errorText(error)} No automatic retry was attempted.`;
            }
            pi.sendMessage({ customType: "pi-run-plan-export", content, display: true }, { triggerTurn: false });
        },
    });

    // Only the planning metadata recorder has mode/direct-call restrictions.
    pi.on("tool_call", event => {
        if (event.toolName === RECORD && (!enabled || event.parentToolCallId)) return {
            block: true, reason: "plan_record is available only as a direct call in planning mode; recording is not approval.",
        };
    });
    pi.on("before_agent_start", event => {
        syncRecorder();
        if (enabled) event.systemPromptOptions.sections.pi_run_plan = INSTRUCTIONS;
    });
}
