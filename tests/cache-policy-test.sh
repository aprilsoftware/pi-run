#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] \
    || { echo 'cache-policy-test: Pi package unavailable' >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PI_CODING_AGENT_DIR="${TMP}" node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { readFile, rm, stat, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [root, piDir, profileDir] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const alias = { '@earendil-works/pi-coding-agent': join(piDir, 'dist', 'index.js') };
const extensionFile = join(root, 'docker/extensions/cache/cache-policy-agent.ts');
const module = await createJiti(import.meta.url, { alias, fsCache: false }).import(extensionFile);

const handlers = new Map();
module.default({ on: (event, handler) => handlers.set(event, handler) });
assert.deepEqual([...handlers.keys()], ['cache_warming_decision']);
const decide = handlers.get('cache_warming_decision');
const settingsFile = join(profileDir, 'settings.json');
const warm = { type: 'cache_warming_decision', warmCost: 0.01, missCost: 1,
    continuationProbability: 0.15, action: 'warm' };
const stopped = { ...warm, action: 'stop' };
const active = { isIdle: () => false };
const idle = { isIdle: () => true };

assert.equal(await decide(warm, active), undefined, 'active refresh must remain unchanged');
assert.deepEqual(await decide(warm, idle), { action: 'stop' }, 'unset mode must stop idle refresh');
await assert.rejects(stat(settingsFile), { code: 'ENOENT' });

await writeFile(settingsFile, '{invalid');
assert.deepEqual(await decide(warm, idle), { action: 'stop' }, 'malformed settings must fail conservative');
assert.equal(await readFile(settingsFile, 'utf8'), '{invalid', 'policy must not rewrite malformed settings');

for (const mode of ['off', 'streaming']) {
    const contents = `${JSON.stringify({ theme: 'dark', cacheWarming: mode })}\n`;
    await writeFile(settingsFile, contents);
    assert.deepEqual(await decide(warm, idle), { action: 'stop' }, `${mode} must not permit idle refresh`);
    assert.equal(await readFile(settingsFile, 'utf8'), contents, 'policy must not rewrite explicit settings');
}

const idleContents = `${JSON.stringify({ theme: 'dark', cacheWarming: 'idle' })}\n`;
await writeFile(settingsFile, idleContents);
assert.equal(await decide(warm, idle), undefined, 'explicit idle mode must retain Pi decision');
assert.equal(await decide(stopped, idle), undefined, 'an existing stop decision needs no override');
assert.equal(await readFile(settingsFile, 'utf8'), idleContents, 'policy must not rewrite idle opt-in');

await writeFile(settingsFile, '{"cacheWarming":"unexpected"}\n');
assert.deepEqual(await decide(warm, idle), { action: 'stop' }, 'invalid mode must fail conservative');
await rm(settingsFile);
assert.deepEqual(await decide(warm, idle), { action: 'stop' }, 'removed settings must take effect immediately');

const { CacheWarmer } = await import(pathToFileURL(join(piDir, 'dist/core/cache-warmer.js')).href);
const originalSetTimeout = globalThis.setTimeout;
const originalClearTimeout = globalThis.clearTimeout;
const timers = [];
let usageWrites = 0;
const usage = {
    input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 1_000_000,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};
const model = {
    id: 'cache-policy-fixture', name: 'Cache policy fixture', provider: 'fixture',
    api: 'openai-responses', reasoning: false, input: ['text'],
    cost: { input: 10, output: 1, cacheRead: 1, cacheWrite: 10 },
    contextWindow: 2_000_000, maxTokens: 1024, promptCache: { short: 11, long: 11 },
};
const sessionManager = {
    getBranch: () => [{ type: 'message', message: { role: 'assistant', usage } }],
    appendUsage: () => { usageWrites += 1; return { type: 'usage' }; },
};
const request = {
    model, context: { messages: [] }, options: { cacheRetention: 'short', reasoning: false },
};

function installControlledTimers() {
    globalThis.setTimeout = (callback, delay, ...args) => {
        const timer = { delay, callback: () => callback(...args), unref() {} };
        timers.push(timer);
        return timer;
    };
    globalThis.clearTimeout = (timer) => {
        const index = timers.indexOf(timer);
        if (index >= 0) timers.splice(index, 1);
    };
}

async function settleUntil(predicate, message) {
    for (let attempt = 0; attempt < 20; attempt += 1) {
        if (predicate()) return;
        await new Promise((resolve) => setImmediate(resolve));
    }
    assert.fail(message);
}

function createRuntimeWarmer(isIdle) {
    let providerCalls = 0;
    const models = {
        streamSimple: () => {
            providerCalls += 1;
            return { result: async () => ({
                role: 'assistant', content: [], api: model.api, provider: model.provider,
                model: model.id, usage, stopReason: 'stop', timestamp: Date.now(),
            }) };
        },
    };
    const runtimeDecide = async (event) => {
        const result = await decide(event, { isIdle: () => isIdle });
        return result?.action ?? event.action;
    };
    return {
        warmer: new CacheWarmer(models, sessionManager, () => 'idle', runtimeDecide),
        providerCalls: () => providerCalls,
    };
}

installControlledTimers();
try {
    const idleRuntime = createRuntimeWarmer(true);
    idleRuntime.warmer.start(request, () => true);
    idleRuntime.warmer.onAgentSettled();
    assert.equal(timers.length, 1, 'idle runtime must have one scheduled refresh');
    assert.equal(timers[0].delay, 1000, 'fixture refresh must use its deterministic one-second delay');
    timers.shift().callback();
    await settleUntil(
        () => idleRuntime.warmer.status.reason === 'stopped by extension',
        'idle runtime did not settle after the policy decision',
    );
    assert.equal(idleRuntime.providerCalls(), 0, 'idle policy must stop before provider execution');
    assert.equal(usageWrites, 0, 'blocked idle refresh must not persist cache usage');
    assert.equal(idleRuntime.warmer.status.extensionOverride, true,
        'idle runtime must record the extension override');

    const activeRuntime = createRuntimeWarmer(false);
    activeRuntime.warmer.start(request, () => true);
    assert.equal(timers.length, 1, 'active runtime must have one scheduled refresh');
    timers.shift().callback();
    await settleUntil(
        () => activeRuntime.providerCalls() === 1 && usageWrites === 1 && timers.length === 1,
        'active runtime did not complete and reschedule its refresh',
    );
    assert.equal(activeRuntime.warmer.status.extensionOverride, false,
        'active refresh must retain Pi\'s warming decision');
    activeRuntime.warmer.cancel();
    assert.equal(timers.length, 0, 'runtime cleanup must remove the rescheduled timer');
} finally {
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
}

console.log('PASS cache policy: idle runtime stops before provider execution; active runtime remains unchanged');
NODE
