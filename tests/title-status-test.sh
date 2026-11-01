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
assert.deepEqual([...handlers.keys()], ['agent_start', 'agent_settled']);

const titles = [];
const tui = { mode: 'tui', ui: { setTitle: title => titles.push(title) } };
await handlers.get('agent_start')({}, tui);
await handlers.get('agent_settled')({}, tui);
assert.deepEqual(titles, ['π …', 'π ✓']);

sessionName = 'Migration task';
await handlers.get('agent_start')({}, tui);
await handlers.get('agent_settled')({}, tui);
assert.deepEqual(titles.slice(-2), ['π … — Migration task', 'π ✓ — Migration task']);

const before = titles.length;
const ignored = { mode: 'json', ui: { setTitle: title => titles.push(title) } };
await handlers.get('agent_start')({}, ignored);
await handlers.get('agent_settled')({}, ignored);
assert.equal(titles.length, before, 'non-TUI modes must not receive terminal titles');

const dockerfile = await readFile(join(root, 'docker/Dockerfile'), 'utf8');
const launcher = await readFile(join(root, 'bin/pi-run'), 'utf8');
assert.ok(dockerfile.includes(
    'COPY extensions/title/title-agent.ts /usr/local/lib/node_modules/pi-run-extensions/title/'));
assert.ok(launcher.includes(
    '--extension /usr/local/lib/node_modules/pi-run-extensions/title/title-agent.ts'));

console.log('Pi-Run TUI title reports working and settled states without affecting non-TUI modes');
NODE
