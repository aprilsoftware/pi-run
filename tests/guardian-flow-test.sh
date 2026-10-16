#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || {
    echo "guardian-flow-test: install Pi or set PI_PACKAGE_DIR to its package directory" >&2
    exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
TMPDIR="${TMP}" node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" <<'NODE'
import assert from 'node:assert/strict';
import { readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const [root, piDir] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const alias = Object.fromEntries(['pi-agent-core', 'pi-tui'].map(name => [
  `@earendil-works/${name}`, join(piDir, 'node_modules', '@earendil-works', name, 'dist', 'index.js'),
]));
alias['@earendil-works/pi-coding-agent'] = join(piDir, 'dist', 'index.js');
alias['@earendil-works/pi-ai'] = join(piDir, 'node_modules', '@earendil-works', 'pi-ai', 'dist', 'compat.js');
const file = join(root, 'tests', 'guardian-flow.ts');
const profileDir = process.env.PI_RUN_PROFILE_DIR;
const tests = await createJiti(import.meta.url, { alias, fsCache: false }).import(file);
await tests.runAutomatedTests();
const { loadExtensions } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'extensions', 'loader.js')).href);
const loaded = await loadExtensions([file], root);
assert.deepEqual(loaded.errors, [], 'Pi must load the interactive test extension');
assert.equal(loaded.extensions.length, 1);
assert.ok(loaded.extensions[0].commands.has('guardian-test'));
assert.equal(loaded.extensions[0].tools.size, 0, 'Test extension must register no executable tools');
assert.equal(loaded.extensions[0].handlers.size, 0, 'Test extension must register no live event hooks');
console.log('PASS guardian-flow: Pi extension loading (command only)');
const command = loaded.extensions[0].commands.get('guardian-test');
for (const name of ['allow', 'ask', 'user-refused', 'unavailable', 'no-ui']) {
  const notices = [];
  const ctx = { hasUI: true, isIdle: () => true, ui: {
    notify: (message, kind) => notices.push({ message, kind }),
    confirm: async () => { throw new Error('Dispute flow must not request confirmation'); },
  } };
  await command.handler(name, ctx);
  assert.ok(notices.some(n => n.message.startsWith(`PASS guardian-flow: ${name}.`)), JSON.stringify(notices));
}
console.log('PASS guardian-flow: interactive dispute wiring (scripted UI, no confirmation)');
const failures = [];
await command.handler('unknown', { hasUI: true, isIdle: () => true, ui: {
  notify: (message, kind) => { if (kind === 'error') failures.push(message); },
} });
assert.equal(failures.length, 0, 'Usage errors must not run a scenario');
assert.equal(process.env.PI_RUN_PROFILE_DIR, profileDir, 'Active profile environment must be restored');
assert.deepEqual((await readdir(tmpdir())).filter(name => name.startsWith('guardian-flow-')), [], 'All temporary fixture state must be removed');
NODE
