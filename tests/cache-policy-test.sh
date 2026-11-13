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
console.log('PASS cache policy: unset and unsafe modes preserve streaming behavior; explicit idle opts in without settings writes');
NODE
