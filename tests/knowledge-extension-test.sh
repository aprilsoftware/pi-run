#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] \
    || { echo 'knowledge-extension-test: Pi package unavailable' >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -m 0700 "${TMP}/profile" "${TMP}/runtime"

PI_RUN_PROFILE_DIR="${TMP}/profile" \
PI_RUN_KNOWLEDGE_RUNTIME_DIR="${TMP}/runtime" \
node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { chmod, lstat, mkdir, readFile, readlink, symlink, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [root, piDir, temp] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const alias = Object.fromEntries(['pi-agent-core', 'pi-tui'].map(name => [
  `@earendil-works/${name}`, join(piDir, 'node_modules', '@earendil-works', name, 'dist', 'index.js'),
]));
alias['@earendil-works/pi-coding-agent'] = join(piDir, 'dist', 'index.js');
const extensionPath = join(root, 'docker', 'extensions', 'knowledge', 'knowledge-agent.ts');
const module = await createJiti(import.meta.url, { alias, fsCache: false }).import(extensionPath);
const { loadExtensions } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'extensions', 'loader.js')).href);
const loaded = await loadExtensions([extensionPath], root);
assert.deepEqual(loaded.errors, []);
assert.equal(loaded.extensions.length, 1);
assert.equal(loaded.extensions[0].commands.size, 0);
assert.equal(loaded.extensions[0].tools.size, 0);

function runtime() {
  const events = new Map();
  module.default({
    on: (name, handler) => {
      const handlers = events.get(name) ?? [];
      handlers.push(handler);
      events.set(name, handlers);
    },
  });
  assert.deepEqual([...events.keys()], ['session_start', 'session_shutdown']);
  return {
    start: events.get('session_start')[0],
    shutdown: events.get('session_shutdown')[0],
  };
}

function context(sessionId) {
  const notices = [];
  return {
    ctx: {
      sessionManager: { getSessionId: () => sessionId },
      ui: { notify: (message, kind) => notices.push({ message, kind }) },
    },
    notices,
  };
}

const profile = join(temp, 'profile');
const runtimeDir = join(temp, 'runtime');
const knowledge = join(profile, 'knowledge');
const current = join(runtimeDir, 'current');
const firstId = '11111111-1111-4111-8111-111111111111';
const secondId = 'session.two';
const firstTarget = join(knowledge, firstId);
const secondTarget = join(knowledge, secondId);

let extension = runtime();
let view = context(firstId);
await extension.start({ type: 'session_start', reason: 'new' }, view.ctx);
assert.equal(await readlink(current), firstTarget);
assert.equal((await lstat(knowledge)).mode & 0o777, 0o700);
assert.equal((await lstat(firstTarget)).mode & 0o777, 0o700);
assert.deepEqual(view.notices, []);
await writeFile(join(firstTarget, 'memory.md'), '# persistent\n', { mode: 0o600 });
await extension.shutdown({ type: 'session_shutdown', reason: 'test' }, view.ctx);
await assert.rejects(lstat(current), error => error.code === 'ENOENT');

extension = runtime();
view = context(firstId);
await extension.start({ type: 'session_start', reason: 'resume' }, view.ctx);
assert.equal(await readlink(current), firstTarget);
assert.equal(await readFile(join(firstTarget, 'memory.md'), 'utf8'), '# persistent\n');

view = context(secondId);
await extension.start({ type: 'session_start', reason: 'new' }, view.ctx);
assert.equal(await readlink(current), secondTarget);
assert.equal((await lstat(secondTarget)).mode & 0o777, 0o700);
await extension.shutdown({ type: 'session_shutdown', reason: 'test' }, view.ctx);
await assert.rejects(lstat(current), error => error.code === 'ENOENT');
assert.equal(await readFile(join(firstTarget, 'memory.md'), 'utf8'), '# persistent\n');

extension = runtime();
view = context('../escape');
await assert.rejects(
  extension.start({ type: 'session_start', reason: 'new' }, view.ctx),
  /identity is unsafe/,
);
assert.ok(view.notices.some(entry => entry.kind === 'error' && entry.message.includes('unavailable')));

const linkedId = 'linked-session';
await symlink(firstTarget, join(knowledge, linkedId), 'dir');
extension = runtime();
view = context(linkedId);
await assert.rejects(
  extension.start({ type: 'session_start', reason: 'resume' }, view.ctx),
  /Unsafe knowledge directory/,
);

await chmod(runtimeDir, 0o755);
extension = runtime();
view = context('runtime-permissions');
await assert.rejects(
  extension.start({ type: 'session_start', reason: 'new' }, view.ctx),
  /Unsafe knowledge directory/,
);
await chmod(runtimeDir, 0o700);

const launcher = await readFile(join(root, 'bin', 'pi-run'), 'utf8');
assert.ok(launcher.includes(
  '--extension /usr/local/lib/node_modules/pi-run-extensions/knowledge/knowledge-agent.ts',
));
const entrypoint = await readFile(join(root, 'docker', 'entrypoint.sh'), 'utf8');
assert.ok(entrypoint.includes('KNOWLEDGE_LINK=/knowledge'));
assert.ok(entrypoint.includes('KNOWLEDGE_TARGET=${KNOWLEDGE_RUNTIME_DIR}/current'));

console.log('knowledge extension session selection, persistence, link lifecycle and path safety tests passed');
NODE
