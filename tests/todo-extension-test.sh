#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'todo-extension-test: Pi package unavailable' >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
PI_RUN_PROFILE_DIR="${TMP}/profile" node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { access, chmod, link, mkdir, readFile, stat, writeFile } from 'node:fs/promises';
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
const extensionPath = join(root, 'docker', 'extensions', 'todo', 'todo-agent.ts');
const module = await createJiti(import.meta.url, { alias, fsCache: false }).import(extensionPath);
const { loadExtensions } = await import(pathToFileURL(join(piDir, 'dist', 'core', 'extensions', 'loader.js')).href);
const loaded = await loadExtensions([extensionPath], root);
assert.deepEqual(loaded.errors, []);
assert.equal(loaded.extensions.length, 1);
assert.ok(loaded.extensions[0].commands.has('todo'));
assert.equal(loaded.extensions[0].tools.size, 0);

function runtime() {
  const commands = new Map(), events = new Map(), tools = [];
  module.default({
    registerCommand: (name, definition) => commands.set(name, definition),
    registerTool: definition => tools.push(definition),
    on: (name, handler) => { const list = events.get(name) ?? []; list.push(handler); events.set(name, list); },
  });
  assert.deepEqual([...events.keys()], ['session_start', 'session_shutdown']);
  assert.deepEqual(tools, []);
  return {
    command: commands.get('todo'),
    start: events.get('session_start')[0],
    shutdown: events.get('session_shutdown')[0],
  };
}

function context(sessionId, selections = ['Close'], editors = [], mode = 'tui', confirmations = [], initialEditorText = '') {
  const notices = [], statuses = [], menus = [], editorCalls = [], widgets = new Map(), placements = [];
  let editorText = initialEditorText, redraws = 0;
  return {
    ctx: {
      mode,
      sessionManager: { getSessionId: () => sessionId },
      ui: {
        select: async (title, choices) => { menus.push({ title, choices }); return selections.shift(); },
        editor: async (title, prefill) => {
          editorCalls.push({ title, prefill });
          const value = editors.shift();
          return typeof value === 'function' ? value() : value;
        },
        confirm: async () => confirmations.shift() ?? false,
        getEditorText: () => editorText,
        setEditorText: text => { editorText = text; },
        notify: (message, kind) => notices.push({ message, kind }),
        setStatus: (key, text) => statuses.push({ key, text }),
        setWidget: (key, factory, options) => {
          placements.push({ key, options });
          if (!factory) { widgets.delete(key); return; }
          widgets.set(key, factory(
            { requestRender: () => { redraws += 1; } },
            { fg: (role, text) => `<${role}>${text}</${role}>` },
          ));
        },
      },
    },
    notices, statuses, menus, editorCalls, placements,
    renderIndicator: () => widgets.get('pi-run-todo')?.render(80) ?? [],
    redraws: () => redraws,
    get editorText() { return editorText; },
  };
}

const firstId = '11111111-1111-4111-8111-111111111111';
const secondId = '22222222-2222-4222-8222-222222222222';
const todoDir = join(temp, 'profile', 'todos');
const firstPath = join(todoDir, `${firstId}.json`);
await mkdir(join(temp, 'profile'), { mode: 0o700 });

let app = runtime(), view = context(firstId, ['New prompt...', 'Close'], ['First line\nMore detail']);
await app.start({ type: 'session_start', reason: 'new' }, view.ctx);
await app.command.handler('', view.ctx);
assert.deepEqual(view.renderIndicator(), ['<muted>todo · 1</muted>']);
assert.deepEqual(view.statuses, [{ key: 'todo', text: undefined }], 'former footer status must be cleared');
assert.ok(view.placements.some(entry => entry.key === 'pi-run-todo' && entry.options?.placement === 'belowEditor'));
assert.ok(view.redraws() > 0);
assert.ok(view.notices.some(entry => entry.message === 'Todo prompt added'));
assert.equal((await stat(todoDir)).mode & 0o777, 0o700);
assert.equal((await stat(firstPath)).mode & 0o777, 0o600);
assert.deepEqual(JSON.parse(await readFile(firstPath, 'utf8')), {
  schemaVersion: 1, sessionId: firstId, nextId: 2,
  items: [{ id: 1, text: 'First line\nMore detail' }],
});
await app.shutdown({ type: 'session_shutdown', reason: 'test' }, view.ctx);
assert.deepEqual(view.renderIndicator(), [], 'shutdown must remove the Todo widget');

app = runtime(); view = context(firstId);
await app.start({ type: 'session_start', reason: 'resume' }, view.ctx);
await app.command.handler('', view.ctx);
assert.deepEqual(view.renderIndicator(), ['<muted>todo · 1</muted>']);
assert.ok(view.menus[0].choices.includes('1. #1 First line'));

app = runtime(); view = context(secondId);
await app.start({ type: 'session_start', reason: 'fork' }, view.ctx);
await app.command.handler('', view.ctx);
assert.equal(view.menus[0].title, 'Todo — 0 queued');
assert.deepEqual(view.renderIndicator(), []);
assert.equal(await readFile(firstPath, 'utf8') !== '', true, 'fork must not alter the source queue');

app = runtime(); view = context(firstId,
  ['1. #1 First line', 'Edit', '1. #1 First line', 'Edit', '1. #1 First line', 'Edit', 'Close'],
  [undefined, '   ', 'x'.repeat(16 * 1024 + 1)]);
await app.start({ type: 'session_start', reason: 'resume' }, view.ctx);
await app.command.handler('', view.ctx);
assert.ok(view.notices.some(entry => entry.message.includes('cannot be empty')));
assert.ok(view.notices.some(entry => entry.message.includes('16 KiB')));
assert.equal(JSON.parse(await readFile(firstPath, 'utf8')).items[0].text, 'First line\nMore detail');

view = context(firstId,
  ['1. #1 First line', 'Edit', 'New prompt...', 'New prompt...', 'Close'],
  ['Edited prompt\nDetails', 'Same summary\nA', 'Same summary\nB']);
await app.command.handler('', view.ctx);
assert.equal(view.editorCalls[0].prefill, 'First line\nMore detail');
let saved = JSON.parse(await readFile(firstPath, 'utf8'));
assert.deepEqual(saved.items.map(item => [item.id, item.text]), [
  [1, 'Edited prompt\nDetails'], [2, 'Same summary\nA'], [3, 'Same summary\nB'],
]);

view = context(firstId, [
  '1. #1 Edited prompt', 'Back',
  '3. #3 Same summary', 'Back',
  '3. #3 Same summary', 'Move up', 'Close',
]);
await app.command.handler('', view.ctx);
assert.equal(view.menus[1].choices.includes('Move up'), false);
assert.equal(view.menus[1].choices.includes('Move down'), true);
assert.equal(view.menus[3].choices.includes('Move up'), true);
assert.equal(view.menus[3].choices.includes('Move down'), false);
saved = JSON.parse(await readFile(firstPath, 'utf8'));
assert.deepEqual(saved.items.map(item => item.id), [1, 3, 2]);

app = runtime(); view = context(firstId);
await app.start({ type: 'session_start', reason: 'resume' }, view.ctx);
const queueIndicator = view;
await app.command.handler('', view.ctx);
assert.ok(view.menus[0].choices.includes('2. #3 Same summary'));
assert.ok(view.menus[0].choices.includes('3. #2 Same summary'));

view = context(firstId,
  ['1. #1 Edited prompt', 'Use as next prompt', 'Cancel', 'Close'], [], 'tui', [], 'Keep this draft');
await app.command.handler('', view.ctx);
assert.equal(view.editorText, 'Keep this draft');
saved = JSON.parse(await readFile(firstPath, 'utf8'));
assert.deepEqual(saved.items.map(item => item.id), [1, 3, 2]);

view = context(firstId, ['1. #1 Edited prompt', 'Use as next prompt']);
await app.command.handler('', view.ctx);
assert.equal(view.editorText, 'Edited prompt\nDetails');
assert.ok(view.notices.some(entry => entry.message.includes('removed from Todo')));
saved = JSON.parse(await readFile(firstPath, 'utf8'));
assert.deepEqual(saved.items.map(item => item.id), [3, 2]);
assert.deepEqual(queueIndicator.renderIndicator(), ['<muted>todo · 2</muted>']);

view = context(firstId,
  ['1. #3 Same summary', 'Use as next prompt', 'Replace editor text'], [], 'tui', [], 'Existing draft');
await app.command.handler('', view.ctx);
assert.equal(view.editorText, 'Same summary\nB');
saved = JSON.parse(await readFile(firstPath, 'utf8'));
assert.deepEqual(saved.items.map(item => item.id), [2]);
assert.deepEqual(queueIndicator.renderIndicator(), ['<muted>todo · 1</muted>']);

view = context(firstId,
  ['1. #2 Same summary', 'Use as next prompt', 'Append after editor text'], [], 'tui', [], 'Existing draft\n');
await app.command.handler('', view.ctx);
assert.equal(view.editorText, 'Existing draft\n\nSame summary\nA');
saved = JSON.parse(await readFile(firstPath, 'utf8'));
assert.deepEqual(saved.items, []);
assert.deepEqual(queueIndicator.renderIndicator(), []);

view = context(firstId, ['New prompt...', 'New prompt...', 'Close'], ['Delete one', 'Delete two']);
await app.command.handler('', view.ctx);
saved = JSON.parse(await readFile(firstPath, 'utf8'));
assert.deepEqual(saved.items.map(item => item.id), [4, 5]);

view = context(firstId,
  ['1. #4 Delete one', 'Delete', '1. #4 Delete one', 'Delete', 'Close'], [], 'tui', [false, true]);
await app.command.handler('', view.ctx);
saved = JSON.parse(await readFile(firstPath, 'utf8'));
assert.deepEqual(saved.items.map(item => item.id), [5]);
assert.deepEqual(queueIndicator.renderIndicator(), ['<muted>todo · 1</muted>']);

view = context(firstId, ['1. #5 Delete two', 'Delete', 'Close'], [], 'tui', [true]);
await app.command.handler('', view.ctx);
saved = JSON.parse(await readFile(firstPath, 'utf8'));
assert.deepEqual(saved.items, []);
assert.deepEqual(queueIndicator.renderIndicator(), []);

const tooLargeId = '33333333-3333-4333-8333-333333333333';
app = runtime(); view = context(tooLargeId, ['New prompt...', 'Close'], ['x'.repeat(16 * 1024 + 1)]);
await app.start({ type: 'session_start', reason: 'new' }, view.ctx);
await app.command.handler('', view.ctx);
assert.ok(view.notices.some(entry => entry.message.includes('16 KiB')));

const failureId = '55555555-5555-4555-8555-555555555555';
const failurePath = join(todoDir, `${failureId}.json`);
app = runtime(); view = context(failureId, ['New prompt...'], [async () => {
  await chmod(todoDir, 0o755);
  return 'Must not be saved';
}]);
await app.start({ type: 'session_start', reason: 'new' }, view.ctx);
await app.command.handler('', view.ctx);
assert.deepEqual(view.renderIndicator(), ['<muted>todo · unavailable</muted>']);
assert.ok(view.notices.some(entry => entry.message.includes('was not saved')));
await assert.rejects(access(failurePath));
await chmod(todoDir, 0o700);

const consumeFailureId = '77777777-7777-4777-8777-777777777777';
const consumeFailurePath = join(todoDir, `${consumeFailureId}.json`);
await writeFile(consumeFailurePath, `${JSON.stringify({
  schemaVersion: 1, sessionId: consumeFailureId, nextId: 2,
  items: [{ id: 1, text: 'Must remain queued' }],
})}\n`, { mode: 0o600 });
app = runtime(); view = context(consumeFailureId,
  ['1. #1 Must remain queued', 'Use as next prompt', 'Replace editor text'], [], 'tui', [], 'Keep safe draft');
await app.start({ type: 'session_start', reason: 'resume' }, view.ctx);
await chmod(todoDir, 0o755);
await app.command.handler('', view.ctx);
assert.equal(view.editorText, 'Keep safe draft');
assert.deepEqual(view.renderIndicator(), ['<muted>todo · unavailable</muted>']);
assert.ok(view.notices.some(entry => entry.message.includes('was not saved')));
assert.deepEqual(JSON.parse(await readFile(consumeFailurePath, 'utf8')).items, [
  { id: 1, text: 'Must remain queued' },
]);
await chmod(todoDir, 0o700);

const malformedId = '44444444-4444-4444-8444-444444444444';
const malformedPath = join(todoDir, `${malformedId}.json`);
await writeFile(malformedPath, '{bad json}\n', { mode: 0o600 });
app = runtime(); view = context(malformedId);
await app.start({ type: 'session_start', reason: 'resume' }, view.ctx);
await app.command.handler('', view.ctx);
assert.deepEqual(view.renderIndicator(), ['<muted>todo · unavailable</muted>']);
assert.ok(view.notices.some(entry => entry.kind === 'error' && entry.message.includes('unavailable')));
assert.equal(await readFile(malformedPath, 'utf8'), '{bad json}\n');

const linkedId = '66666666-6666-4666-8666-666666666666';
const linkedPath = join(todoDir, `${linkedId}.json`);
await writeFile(linkedPath, `${JSON.stringify({ schemaVersion: 1, sessionId: linkedId, nextId: 1, items: [] })}\n`, { mode: 0o600 });
await link(linkedPath, `${linkedPath}.alias`);
app = runtime(); view = context(linkedId);
await app.start({ type: 'session_start', reason: 'resume' }, view.ctx);
assert.deepEqual(view.renderIndicator(), ['<muted>todo · unavailable</muted>']);
assert.equal(JSON.parse(await readFile(linkedPath, 'utf8')).sessionId, linkedId);

await chmod(firstPath, 0o644);
app = runtime(); view = context(firstId);
await app.start({ type: 'session_start', reason: 'resume' }, view.ctx);
assert.deepEqual(view.renderIndicator(), ['<muted>todo · unavailable</muted>']);
await chmod(firstPath, 0o600);

app = runtime(); view = context(firstId, [], [], 'print');
await app.command.handler('', view.ctx);
assert.ok(view.notices.some(entry => entry.message.includes('interactive mode')));
view = context(firstId);
await app.command.handler('add hidden', view.ctx);
assert.ok(view.notices.some(entry => entry.message === 'Usage: /todo'));

const launcher = await readFile(join(root, 'bin', 'pi-run'), 'utf8');
const planPath = '--extension /usr/local/lib/node_modules/pi-run-extensions/plan/plan-agent.ts';
const todoPath = '--extension /usr/local/lib/node_modules/pi-run-extensions/todo/todo-agent.ts';
const guardPath = '--extension /usr/local/lib/node_modules/pi-run-extensions/guard/guard-runtime.ts';
assert.ok(launcher.indexOf(planPath) < launcher.indexOf(todoPath));
assert.ok(launcher.indexOf(todoPath) < launcher.indexOf(guardPath),
  'Todo must register its below-editor widget above Guard Runtime');

console.log('todo extension capture, isolation, muted placement, permissions, limits and fail-closed state tests passed');
NODE
