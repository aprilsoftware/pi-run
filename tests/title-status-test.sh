#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] \
    || { echo 'title-status-test: Pi package unavailable' >&2; exit 1; }

node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" <<'NODE'
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join } from 'node:path';

const [root, piDir] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const alias = { '@earendil-works/pi-coding-agent': join(piDir, 'dist', 'index.js') };
const extensionFile = join(root, 'docker/extensions/title/title-agent.ts');
const module = await createJiti(import.meta.url, { alias, fsCache: false }).import(extensionFile);

const handlers = new Map();
let sessionName;
const pi = {
    getSessionName: () => sessionName,
    on: (event, handler) => handlers.set(event, handler),
};
module.default(pi);
assert.deepEqual([...handlers.keys()],
    ['session_start', 'session_info_changed', 'agent_start', 'agent_settled', 'session_shutdown']);

const nextTimer = () => new Promise(resolve => setTimeout(resolve, 0));
const spinnerTick = () => new Promise(resolve => setTimeout(resolve, 220));
const spinnerTitle = /^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] π(?: · .+)?$/u;
const titles = [];
const tui = { mode: 'tui', ui: { setTitle: title => titles.push(title) } };
titles.push('π - workspace');
await new Promise(resolve => setTimeout(resolve, 10)); // Earlier extensions may perform async startup work.
await handlers.get('session_start')({}, tui);
titles.push('π - workspace'); // Pi updates its default title after extension binding.
await nextTimer();
assert.deepEqual(titles, ['π - workspace', 'π', 'π - workspace', 'π']);

await handlers.get('agent_start')({}, tui);
assert.equal(titles.at(-1), '⠋ π');
const beforeTick = titles.length;
await spinnerTick();
assert.ok(titles.length > beforeTick, 'working title spinner did not advance');
assert.match(titles.at(-1), spinnerTitle);

sessionName = 'Migration task';
await handlers.get('session_info_changed')({ name: sessionName }, tui);
assert.match(titles.at(-1), /^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] π · Migration task$/u);
titles.push('π - Migration task - workspace');
await nextTimer();
assert.match(titles.at(-1), /^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] π · Migration task$/u);
await handlers.get('agent_settled')({}, tui);
assert.equal(titles.at(-1), '✓ π · Migration task');
const afterSettled = titles.length;
await spinnerTick();
assert.equal(titles.length, afterSettled, 'settlement must stop the title spinner');

sessionName = undefined;
await handlers.get('session_info_changed')({ name: undefined }, tui);
await nextTimer();
assert.equal(titles.at(-1), '✓ π');
sessionName = 'Review';
await handlers.get('session_start')({}, tui);
titles.push('π - Review - workspace');
await nextTimer();
assert.equal(titles.at(-1), 'π · Review');

sessionName = undefined;
await handlers.get('session_start')({}, tui);
titles.push('π - workspace');
await handlers.get('session_shutdown')({}, tui);
await nextTimer();
assert.equal(titles.at(-1), 'π - workspace', 'shutdown must cancel a deferred title update');

await handlers.get('session_start')({}, tui);
await nextTimer();
await handlers.get('agent_start')({}, tui);
const beforeSpinnerShutdown = titles.length;
await handlers.get('session_shutdown')({}, tui);
await spinnerTick();
assert.equal(titles.length, beforeSpinnerShutdown, 'shutdown must stop the title spinner');

const before = titles.length;
const ignored = { mode: 'json', ui: { setTitle: title => titles.push(title) } };
await handlers.get('session_start')({}, ignored);
await handlers.get('session_info_changed')({ name: 'Ignored' }, ignored);
await handlers.get('agent_start')({}, ignored);
await handlers.get('agent_settled')({}, ignored);
await handlers.get('session_shutdown')({}, ignored);
assert.equal(titles.length, before, 'non-TUI modes must not receive terminal titles');

const dockerfile = await readFile(join(root, 'docker/Dockerfile'), 'utf8');
const launcher = await readFile(join(root, 'bin/pi-run'), 'utf8');
assert.ok(dockerfile.includes(
    'COPY extensions/title/title-agent.ts /usr/local/lib/node_modules/pi-run-extensions/title/'));
const titleExtension = '--extension /usr/local/lib/node_modules/pi-run-extensions/title/title-agent.ts';
assert.ok(launcher.includes(titleExtension));
const extensionLines = launcher.split('\n')
    .map(line => line.trim())
    .filter(line => line.startsWith('--extension '));
assert.equal(extensionLines.at(-1), titleExtension,
    'title extension must load after extensions with asynchronous session_start handlers');

console.log('Pi-Run loads title ownership last and prefixes animated activity status');
NODE
