// SPDX-License-Identifier: MIT

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Activity = "…" | "✓";

function activityTitle(pi: ExtensionAPI, activity: Activity): string {
    const session = pi.getSessionName()?.trim();
    return session ? `π ${activity} — ${session}` : `π ${activity}`;
}

function setActivityTitle(pi: ExtensionAPI, ctx: ExtensionContext, activity: Activity): void {
    if (ctx.mode === "tui") {
        ctx.ui.setTitle(activityTitle(pi, activity));
    }
}

export default function titleAgent(pi: ExtensionAPI): void {
    pi.on("agent_start", (_event, ctx) => {
        setActivityTitle(pi, ctx, "…");
    });

    pi.on("agent_settled", (_event, ctx) => {
        setActivityTitle(pi, ctx, "✓");
    });
}
