// SPDX-License-Identifier: MIT

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Activity = "…" | "✓" | undefined;

function activityTitle(activity: Activity, sessionName?: string): string {
    const status = activity ? `π ${activity}` : "π";
    const session = sessionName?.trim();
    return session ? `${status} — ${session}` : status;
}

function setActivityTitle(ctx: ExtensionContext, activity: Activity, sessionName?: string): void {
    if (ctx.mode === "tui") {
        ctx.ui.setTitle(activityTitle(activity, sessionName));
    }
}

export default function titleAgent(pi: ExtensionAPI): void {
    let activity: Activity;

    pi.on("session_start", (_event, ctx) => {
        activity = undefined;
        setActivityTitle(ctx, activity, pi.getSessionName());
    });

    pi.on("session_info_changed", (event, ctx) => {
        setActivityTitle(ctx, activity, event.name);
    });

    pi.on("agent_start", (_event, ctx) => {
        activity = "…";
        setActivityTitle(ctx, activity, pi.getSessionName());
    });

    pi.on("agent_settled", (_event, ctx) => {
        activity = "✓";
        setActivityTitle(ctx, activity, pi.getSessionName());
    });
}
