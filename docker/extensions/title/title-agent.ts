// SPDX-License-Identifier: MIT

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Activity = "idle" | "working" | "settled";

const SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"] as const;
const SPINNER_INTERVAL_MS = 160;

function activityTitle(activity: Activity, frame: string, sessionName?: string): string {
    const status = activity === "working" ? `π ${frame}` : activity === "settled" ? "π ✓" : "π";
    const session = sessionName?.trim();
    return session ? `${status} | ${session}` : status;
}

export default function titleAgent(pi: ExtensionAPI): void {
    let activity: Activity = "idle";
    let frameIndex = 0;
    let deferredTitle: ReturnType<typeof setTimeout> | undefined;
    let spinner: ReturnType<typeof setInterval> | undefined;

    function setActivityTitle(ctx: ExtensionContext, sessionName?: string): void {
        if (ctx.mode === "tui") {
            ctx.ui.setTitle(activityTitle(activity, SPINNER_FRAMES[frameIndex], sessionName));
        }
    }

    function cancelDeferredTitle(): void {
        if (deferredTitle) {
            clearTimeout(deferredTitle);
            deferredTitle = undefined;
        }
    }

    function stopSpinner(): void {
        if (spinner) {
            clearInterval(spinner);
            spinner = undefined;
        }
        frameIndex = 0;
    }

    function deferActivityTitle(ctx: ExtensionContext): void {
        cancelDeferredTitle();
        if (ctx.mode !== "tui") return;
        deferredTitle = setTimeout(() => {
            deferredTitle = undefined;
            setActivityTitle(ctx, pi.getSessionName());
        }, 0);
        deferredTitle.unref?.();
    }

    function startSpinner(ctx: ExtensionContext): void {
        stopSpinner();
        if (ctx.mode !== "tui") return;
        spinner = setInterval(() => {
            frameIndex = (frameIndex + 1) % SPINNER_FRAMES.length;
            setActivityTitle(ctx, pi.getSessionName());
        }, SPINNER_INTERVAL_MS);
        spinner.unref?.();
    }

    pi.on("session_start", (_event, ctx) => {
        cancelDeferredTitle();
        stopSpinner();
        activity = "idle";
        setActivityTitle(ctx, pi.getSessionName());
        deferActivityTitle(ctx);
    });

    pi.on("session_info_changed", (event, ctx) => {
        setActivityTitle(ctx, event.name);
        deferActivityTitle(ctx);
    });

    pi.on("agent_start", (_event, ctx) => {
        cancelDeferredTitle();
        activity = "working";
        setActivityTitle(ctx, pi.getSessionName());
        startSpinner(ctx);
    });

    pi.on("agent_settled", (_event, ctx) => {
        cancelDeferredTitle();
        stopSpinner();
        activity = "settled";
        setActivityTitle(ctx, pi.getSessionName());
    });

    pi.on("session_shutdown", () => {
        cancelDeferredTitle();
        stopSpinner();
    });
}
