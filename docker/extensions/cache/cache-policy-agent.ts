// SPDX-License-Identifier: MIT

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { join } from "node:path";

type CacheWarmingMode = "off" | "streaming" | "idle";

function configuredCacheWarmingMode(): CacheWarmingMode | undefined {
    const agentDirectory = process.env.PI_CODING_AGENT_DIR;
    if (!agentDirectory) return undefined;
    try {
        const settings: unknown = JSON.parse(readFileSync(join(agentDirectory, "settings.json"), "utf8"));
        if (!settings || typeof settings !== "object" || Array.isArray(settings)) return undefined;
        const mode = (settings as { cacheWarming?: unknown }).cacheWarming;
        return mode === "off" || mode === "streaming" || mode === "idle" ? mode : undefined;
    } catch {
        return undefined;
    }
}

export default function cachePolicyAgent(pi: ExtensionAPI): void {
    pi.on("cache_warming_decision", (event, ctx) => {
        if (!ctx.isIdle() || event.action === "stop") return;
        if (configuredCacheWarmingMode() === "idle") return;
        return { action: "stop" };
    });
}
