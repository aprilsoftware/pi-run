#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PI_PACKAGE_DIR="${PI_PACKAGE_DIR:-$(npm root -g)/@earendil-works/pi-coding-agent}"
[[ -f "${PI_PACKAGE_DIR}/package.json" ]] || { echo 'plan-extension-test: Pi package unavailable' >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

node --input-type=module - "${ROOT}" "${PI_PACKAGE_DIR}" "${TMP}" <<'NODE'
import assert from 'node:assert/strict';
import { mkdir, readFile, readdir, stat, symlink, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
const [root, piDir, testDir] = process.argv.slice(2);
const require = createRequire(join(piDir, 'package.json'));
const { createJiti } = require('jiti');
const alias = { '@earendil-works/pi-coding-agent': join(piDir, 'dist', 'index.js'),
    typebox: require.resolve('typebox'), 'typebox/value': require.resolve('typebox/value'),
};
const file = join(root, 'docker/extensions/plan-agent.ts');
const module = await createJiti(import.meta.url, { alias, fsCache: false }).import(file);
const { loadExtensions } = await import(pathToFileURL(join(piDir, 'dist/core/extensions/loader.js')).href);
const loaded = await loadExtensions([file], root);
assert.deepEqual(loaded.errors, []);
assert.equal(loaded.extensions.length, 1);
assert.ok(loaded.extensions[0].commands.has('plan'));
assert.ok(!loaded.extensions[0].commands.has('plan-off'));
assert.ok(loaded.extensions[0].commands.has('plan-exit'));
assert.ok(loaded.extensions[0].commands.has('plan-show'));
assert.ok(loaded.extensions[0].commands.has('plan-export'));
assert.ok(loaded.extensions[0].commands.has('plan-approve'));
assert.equal(loaded.extensions[0].tools.size, 1);
const recordTool = loaded.extensions[0].tools.get('plan_record').definition;
assert.equal(recordTool.defaultActive, false);
assert.equal(recordTool.exposure, 'model-only');
assert.equal(recordTool.executionMode, 'sequential');
const original = ['read', 'bash', 'edit', 'write', 'web_search', 'custom'];
const planning = [...original, 'plan_record'];
const themeFg = (color, text) => `<${color}>${text}</${color}>`;
function harness(branch = [], initialTools = original, mode = 'tui', cwd = root) {
    branch = structuredClone(branch);
    const handlers = new Map(), commands = new Map(), registered = new Map();
    const prompts = [], notices = [], statuses = [], messages = [], confirmations = [], widgets = new Map();
    let tools = [...initialTools], idleWaits = 0, waiting = false, sessionId = randomUUID(), redraws = 0;
    let confirmation = async () => true;
    const hasUI = mode === 'tui' || mode === 'rpc';
    const ctx = { cwd, mode, hasUI,
        sessionManager: { getBranch: () => branch, getSessionId: () => sessionId, getLeafId: () => branch.at(-1)?.id ?? null },
        waitForIdle: async () => { waiting = true; idleWaits++; },
        ui: hasUI ? { notify: (...args) => notices.push(args), setStatus: (...args) => statuses.push(args),
            setWidget: (key, factory, options) => {
                assert.equal(options.placement, 'belowEditor');
                if (factory) widgets.set(key, factory({ requestRender: () => { redraws++; } }, { fg: themeFg }));
                else widgets.delete(key);
            },
            theme: { fg: themeFg },
            confirm: async (...args) => { confirmations.push(args); return confirmation(...args); },
        } : undefined,
    };
    module.default({
        on: (event, handler) => handlers.set(event, handler),
        registerCommand: (name, command) => commands.set(name, command),
        registerTool: tool => registered.set(tool.name, tool),
        getActiveTools: () => [...tools], setActiveTools: names => { tools = [...names]; },
        appendEntry: (customType, data) => { assert.ok(waiting); branch.push({ id: randomUUID(), type: 'custom', customType, data: structuredClone(data) }); },
        sendUserMessage: message => prompts.push(message),
        sendMessage: (message, options) => messages.push({ message, options }),
    });
    return { branch, prompts, notices, statuses, commands, messages, confirmations, widgets,
        renderIndicator: () => widgets.get('pi-run-plan')?.render(80) ?? [], redraws: () => redraws,
        confirmWith: callback => { confirmation = callback; },
        changeSession: () => { sessionId = randomUUID(); },
        record: (draft, signal) => registered.get('plan_record').execute('record', draft, signal, undefined, ctx),
        tools: () => tools, selectTools: names => { tools = [...names]; }, waits: () => idleWaits,
        emit: (name, event = {}) => handlers.get(name)(event, ctx),
        command: args => commands.get('plan').handler(args, ctx),
        exit: (args = '') => commands.get('plan-exit').handler(args, ctx),
        approvalEntry: () => [...branch].reverse().find(entry => entry.customType === 'pi-run-plan-approval'),
        show: (args = '') => commands.get('plan-show').handler(args, ctx),
        export: args => commands.get('plan-export').handler(args, ctx),
        approve: (args = '') => commands.get('plan-approve').handler(args, ctx),
        // Pi restores a destination branch's transcript loadout before session_tree.
        navigate: async (entries, loadout) => { branch = entries; tools = [...loadout]; await handlers.get('session_tree')({}, ctx); },
    };
}
const h = harness();
await h.emit('session_start');
assert.deepEqual(h.tools(), original);
assert.equal(h.emit('tool_call', { toolName: 'write' }), undefined);
await h.command('  Add planning support  ');
assert.deepEqual(h.tools(), planning);
assert.deepEqual(h.prompts, ['Plan only: Add planning support']);
assert.equal(h.waits(), 1);
assert.deepEqual(h.renderIndicator(), ['<muted>planning</muted>']);
const saved = structuredClone(h.branch);
assert.deepEqual(saved[0].data, { schemaVersion: 2, enabled: true });
for (const toolName of planning) assert.equal(h.emit('tool_call', { toolName }), undefined);
for (const toolName of ['edit', 'write', 'bash', 'powershell', 'run', 'custom', 'okf_init', 'web_search', 'codemode', 'tool_search', 'mcp__server__write']) {
    for (const parentToolCallId of [undefined, 'parent']) {
        assert.equal(h.emit('tool_call', { toolName, parentToolCallId, input: {} }), undefined, toolName);
    }
}
const event = { systemPromptOptions: { sections: { existing: 'keep me' } } };
h.emit('before_agent_start', event);
assert.equal(event.systemPromptOptions.sections.existing, 'keep me');
for (const text of ['Develop the overall plan', 'writing and running investigative scripts', 'not tool permissions', 'applicable AGENTS.md',
    'Agreement during discussion', '/plan-exit', 'do not duplicate that workflow']) assert.ok(event.systemPromptOptions.sections.pi_run_plan.includes(text));
for (const text of ['Propose only the smallest', '5 hand-maintained files', '300', 'exactly one concrete']) {
    assert.ok(!event.systemPromptOptions.sections.pi_run_plan.includes(text));
}
await h.command('');
await h.command('Refine the approach');
assert.equal(h.branch.length, 1, 'Repeated enabling must not append redundant mode state');
assert.equal(h.prompts.length, 2);
await h.exit();
assert.deepEqual(h.tools(), original);
assert.equal(h.emit('tool_call', { toolName: 'write' }), undefined);
assert.ok(h.notices.at(-1)[0].includes('execution follows applicable AGENTS.md'));
assert.deepEqual(h.renderIndicator(), []);
const offEvent = { systemPromptOptions: { sections: {} } };
h.emit('before_agent_start', offEvent);
assert.deepEqual(offEvent.systemPromptOptions.sections, {});
await h.exit('  ');
assert.equal(h.branch.length, 2);
await h.command('  ');
assert.deepEqual(h.tools(), planning);
await h.command('');
assert.deepEqual(h.tools(), planning, 'Bare /plan enables rather than toggles');
assert.equal(h.branch.length, 3);
assert.deepEqual(h.branch.at(-1).data, { schemaVersion: 2, enabled: true });
await h.exit();
assert.deepEqual(h.tools(), original);
for (const mode of ['tui', 'print']) {
    const routing = harness([], original, mode);
    await routing.emit('session_start');
    for (const goal of ['on', 'off', 'show']) await routing.command(`  ${goal}  `);
    assert.deepEqual(routing.prompts, ['Plan only: on', 'Plan only: off', 'Plan only: show']);
    assert.deepEqual(routing.tools(), planning);
    const count = routing.branch.length;
    await routing.exit('unexpected');
    assert.ok(routing.messages.at(-1).message.content.includes('Usage: /plan-exit'));
    await routing.show('unexpected');
    assert.ok(routing.messages.at(-1).message.content.includes('Usage: /plan-show'));
    assert.deepEqual(routing.messages.at(-1).options, { triggerTurn: false });
    assert.equal(routing.branch.length, count, 'Usage errors must not change state');
    await routing.exit();
    assert.deepEqual(routing.tools(), original);
}
console.log('PASS commands: hyphenated names, ordinary goals, idempotent enable/disable, and no-turn usage errors');

const selections = harness();
await selections.emit('session_start');
await selections.command('');
const chosen = ['run', 'late_tool', 'write'];
selections.selectTools(chosen);
selections.emit('before_agent_start', { systemPromptOptions: { sections: {} } });
assert.deepEqual(selections.tools(), [...chosen, 'plan_record'], 'Do not force the original tool loadout');
await selections.command('');
assert.deepEqual(selections.tools(), [...chosen, 'plan_record']);
const resumed = harness(saved, [...chosen, 'plan_record'], 'print');
await resumed.emit('session_start');
assert.deepEqual(resumed.tools(), [...chosen, 'plan_record']);
await resumed.exit();
assert.deepEqual(resumed.tools(), chosen, 'Off removes only the recorder, including after resume');
assert.equal(resumed.statuses.length, 0, 'Print mode does not access TUI status or theme');
await selections.exit();
assert.deepEqual(selections.tools(), chosen);
await selections.navigate(saved, chosen);
assert.deepEqual(selections.tools(), [...chosen, 'plan_record']);
await selections.navigate(h.branch, [...chosen, 'plan_record']);
assert.deepEqual(selections.tools(), chosen, 'An off branch removes stale recorder declarations');
const branched = harness(saved, planning);
await branched.emit('session_start');
assert.deepEqual(branched.renderIndicator(), ['<muted>planning</muted>'], 'Resume restores themed indicator');
await branched.navigate([], ['read', 'custom']);
assert.deepEqual(branched.renderIndicator(), []);
assert.equal(branched.emit('tool_call', { toolName: 'custom' }), undefined);
assert.deepEqual(branched.tools(), ['read', 'custom'], 'Do not overwrite destination branch tools');
await branched.navigate(structuredClone(saved), planning);
assert.deepEqual(branched.renderIndicator(), ['<muted>planning</muted>'], 'Returning to an enabled branch restores muted indicator');
assert.equal(branched.emit('tool_call', { toolName: 'write' }), undefined);
await branched.exit();
assert.deepEqual(branched.tools(), original);
const invalid = harness([{ type: 'custom', customType: 'pi-run-plan', data: { enabled: false } }]);
await invalid.emit('session_start');
assert.deepEqual(invalid.tools(), planning, 'Malformed state retains guidance without restricting normal tools');
assert.equal(invalid.notices.at(-1)[1], 'warning');
await invalid.emit('session_shutdown');
assert.equal(invalid.widgets.has('pi-run-plan'), false);
assert.equal(invalid.emit('tool_call', { toolName: 'write' }), undefined);
const retained = { systemPromptOptions: { sections: {} } };
invalid.emit('before_agent_start', retained);
assert.ok(retained.systemPromptOptions.sections.pi_run_plan.includes('Develop the overall plan'));
console.log('PASS tools: unrestricted calls, live selections, recorder-only toggling, and resume/branches');
const draft = { title: 'Session planning', goal: 'Keep a reviewable plan',
    body: '## Approach\nSave branch-aware plans.\n\n## Alternatives\nExplicit export or session storage.\n\n## Open questions\nWhich export path?\n\n## Work\nDiscuss, save, and export the whole plan.\n\n## Validation\nExercise the complete workflow.',
};
const exportedView = view => view.replace('**Not approved. Recording or displaying a plan does not approve work.**',
    '**Exported plan. Exporting does not grant approval; execution follows applicable AGENTS.md instructions.**');
const drafts = harness();
await drafts.emit('session_start');
await drafts.show();
assert.ok(drafts.messages.at(-1).message.content.includes('No active plan'));
assert.deepEqual(drafts.tools(), original);
assert.equal(drafts.branch.length, 0);
assert.equal(drafts.prompts.length, 0);
assert.equal(drafts.emit('tool_call', { toolName: 'plan_record' }).block, true);
await assert.rejects(drafts.record(draft), /requires planning mode/);
await drafts.command('');
assert.equal(drafts.emit('tool_call', { toolName: 'plan_record', parentToolCallId: 'parent' }).block, true);
const recorded = await drafts.record(draft);
assert.ok(recorded.content[0].text.includes('Not approved'));
assert.equal(drafts.branch.length, 2);
assert.deepEqual(drafts.branch.at(-1).data, { schemaVersion: 2, draft });
const firstRevision = JSON.parse(JSON.stringify(drafts.branch));
const invalidDrafts = [null, {}, { ...draft, title: '   ' }, { ...draft, approved: true },
    { ...draft, body: '   ' }, { ...draft, body: null }, { ...draft, nextIncrement: {} },
    { ...draft, body: 'x'.repeat(30001) }, { ...draft, body: 'é'.repeat(20000) },
];
for (const value of invalidDrafts) await assert.rejects(drafts.record(value), /Invalid draft/);
await assert.rejects(drafts.record(draft, AbortSignal.abort()), /cancelled/);
assert.equal(drafts.branch.length, 2, 'Invalid/cancelled records must not replace the saved draft');
await drafts.show();
const firstView = drafts.messages.at(-1).message.content;
for (const text of [draft.title, draft.goal, draft.body, 'Not approved']) assert.ok(firstView.includes(text), text);
assert.ok(!firstView.includes('Proposed next increment'));
assert.deepEqual(drafts.messages.at(-1).options, { triggerTurn: false });
assert.equal(drafts.messages.at(-1).message.display, true);
assert.equal(drafts.branch.length, 2);
assert.deepEqual(drafts.tools(), planning);
const revision = { ...draft, title: 'Revised planning', body: 'A free-form revised plan without mandatory sections.' };
await drafts.record(revision);
await drafts.show();
const revisionView = drafts.messages.at(-1).message.content;
assert.ok(revisionView.includes(revision.body));
const latestRevision = structuredClone(drafts.branch);
await drafts.exit();
await drafts.show();
assert.ok(drafts.messages.at(-1).message.content.includes('No active plan'));
assert.deepEqual(drafts.tools(), original);
assert.equal(drafts.prompts.length, 0, 'Recording, viewing, and exit must never launch a model turn');
const discardedBranch = structuredClone(drafts.branch);
const exited = harness(discardedBranch, planning, 'print');
await exited.emit('session_start');
await exited.show();
assert.ok(exited.messages.at(-1).message.content.includes('No active plan'));
await exited.approve();
assert.ok(exited.messages.at(-1).message.content.startsWith('Plan approval not recorded:'));
await exited.export('discarded.md');
assert.ok(exited.messages.at(-1).message.content.startsWith('Plan export failed:'));
assert.deepEqual(exited.tools(), original);
const countAfterExit = exited.branch.length;
await exited.exit();
assert.equal(exited.branch.length, countAfterExit, 'Repeated exit is harmless');
const draftResume = harness(latestRevision, planning, 'print');
await draftResume.emit('session_start');
await draftResume.show();
assert.equal(draftResume.messages.at(-1).message.content, revisionView);
await draftResume.navigate(firstRevision, planning);
await draftResume.show();
assert.equal(draftResume.messages.at(-1).message.content, firstView, 'Branch navigation selects its own revision');
await draftResume.navigate([], original);
await draftResume.show();
assert.ok(draftResume.messages.at(-1).message.content.includes('No active plan'));
for (const data of [null, { schemaVersion: 99, draft }, { schemaVersion: 2, draft: {} },
    { schemaVersion: 2, draft, approved: true }]) {
    await draftResume.navigate([...firstRevision, { type: 'custom', customType: 'pi-run-plan-draft', data }], planning);
    await draftResume.show();
    assert.ok(draftResume.messages.at(-1).message.content.includes('invalid or unsupported'), 'Never fall back to a stale revision');
}
console.log('PASS drafts: validation, cancellation, replacement, display, resume, branching, no-UI, and no approval');
const workspace = join(testDir, 'export workspace'), outside = join(testDir, 'outside');
await mkdir(join(workspace, 'tasks', 'example'), { recursive: true });
await mkdir(outside);
const exports = harness(latestRevision, planning, 'print', workspace);
await exports.emit('session_start');
await exports.show();
const exportView = exportedView(exports.messages.at(-1).message.content);
const branchCount = exports.branch.length;
await exports.export('tasks/example/PLAN.md');
assert.equal(await readFile(join(workspace, 'tasks/example/PLAN.md'), 'utf8'), `${exportView}\n`);
assert.equal((await stat(join(workspace, 'tasks/example/PLAN.md'))).mode & 0o777, 0o600);
assert.ok(exports.messages.at(-1).message.content.startsWith('Draft exported to'));
assert.ok(exports.messages.at(-1).message.content.includes('not implementation approval'));
assert.deepEqual(exports.messages.at(-1).options, { triggerTurn: false });
assert.deepEqual(exports.tools(), planning);
assert.equal(exports.branch.length, branchCount);
assert.equal(exports.prompts.length, 0);
await exports.export('tasks/example/PLAN.md');
assert.ok(exports.messages.at(-1).message.content.includes('Export was not published'));
assert.equal(await readFile(join(workspace, 'tasks/example/PLAN.md'), 'utf8'), `${exportView}\n`);
assert.deepEqual(await readdir(join(workspace, 'tasks/example')), ['PLAN.md'], 'Collision cleanup leaves no temporary file');
await exports.export('');
assert.ok(exports.messages.at(-1).message.content.includes('Usage: /plan-export'));
for (const path of ['../escape.md', 'tasks/../../escape.md', join(outside, 'absolute.md'),
    'file.txt', 'tasks//file.md', 'bad\\name.md', 'bad\u0000.md', 'bad\nname.md', 'missing/PLAN.md']) {
    await exports.export(path);
    assert.ok(exports.messages.at(-1).message.content.startsWith('Plan export failed:'), path);
}
assert.deepEqual(await readdir(outside), []);
assert.deepEqual((await readdir(workspace)).sort(), ['tasks']);
await mkdir(join(workspace, 'space folder'));
await exports.export('  space folder/my plan.md  ');
assert.equal(await readFile(join(workspace, 'space folder/my plan.md'), 'utf8'), `${exportView}\n`);
await exports.export('./dot-prefix.md');
assert.equal(await readFile(join(workspace, 'dot-prefix.md'), 'utf8'), `${exportView}\n`);
const protectedFile = join(outside, 'protected.md');
await writeFile(protectedFile, 'keep me');
await symlink(outside, join(workspace, 'linked'));
await symlink('tasks', join(workspace, 'internal-link'));
await symlink(protectedFile, join(workspace, 'symlink.md'));
await symlink(join(outside, 'absent.md'), join(workspace, 'dangling.md'));
await mkdir(join(workspace, 'directory.md'));
const beforeRejected = (await readdir(workspace)).sort();
for (const path of ['linked/new.md', 'internal-link/new.md', 'symlink.md', 'dangling.md', 'directory.md']) {
    await exports.export(path);
    assert.ok(exports.messages.at(-1).message.content.startsWith('Plan export failed:'), path);
}
assert.equal(await readFile(protectedFile, 'utf8'), 'keep me');
assert.deepEqual(await readdir(outside), ['protected.md']);
assert.deepEqual((await readdir(workspace)).sort(), beforeRejected, 'Symlink/existing-target failures leave no temporary files');
await Promise.all([exports.export('race.md'), exports.export('race.md')]);
assert.equal(exports.messages.slice(-2).filter(item => item.message.content.startsWith('Draft exported to')).length, 1);
assert.equal(exports.messages.slice(-2).filter(item => item.message.content.startsWith('Plan export failed:')).length, 1);
assert.equal(await readFile(join(workspace, 'race.md'), 'utf8'), `${exportView}\n`);
assert.ok(!(await readdir(workspace)).some(name => name.startsWith('.pi-run-plan-export-')));
await exports.navigate(firstRevision, planning);
await exports.export('first-revision.md');
assert.equal(await readFile(join(workspace, 'first-revision.md'), 'utf8'), `${exportedView(firstView)}\n`);
assert.deepEqual(exports.tools(), planning);
assert.equal(exports.emit('tool_call', { toolName: 'write' }), undefined);
for (const branch of [[], [...firstRevision, { type: 'custom', customType: 'pi-run-plan-draft', data: { schemaVersion: 99, draft } }]]) {
    await exports.navigate(branch, original);
    await exports.export('invalid.md');
    assert.ok(exports.messages.at(-1).message.content.startsWith('Plan export failed:'));
    await assert.rejects(stat(join(workspace, 'invalid.md')), { code: 'ENOENT' });
}
assert.equal(exports.prompts.length, 0);
assert.equal(loaded.extensions[0].tools.size, 1, 'Export must not be model-callable');
console.log('PASS export: contents, paths, symlinks, create-only publication, cleanup, branches, no-UI, and unchanged mode');
const abandoned = harness(latestRevision, planning, 'print', workspace);
await abandoned.emit('session_start');
await abandoned.exit();
await abandoned.export('after-exit.md');
await assert.rejects(stat(join(workspace, 'after-exit.md')), { code: 'ENOENT' });
assert.equal(await readFile(join(workspace, 'tasks/example/PLAN.md'), 'utf8'), `${exportView}\n`, 'Exit must not alter exports');
await abandoned.navigate(firstRevision, planning);
await abandoned.show();
assert.equal(abandoned.messages.at(-1).message.content, firstView, 'Historical branches keep their own draft');
await abandoned.navigate(discardedBranch, original);
await abandoned.show();
assert.ok(abandoned.messages.at(-1).message.content.includes('No active plan'));
const fresh = harness(firstRevision, planning);
await fresh.emit('session_start');
await fresh.command('A different goal');
await fresh.show();
assert.ok(fresh.messages.at(-1).message.content.includes('No active plan'), 'A new goal cannot approve an older plan');
await fresh.approve();
assert.equal(fresh.confirmations.length, 0);
await fresh.record(revision);
await fresh.show();
assert.ok(fresh.messages.at(-1).message.content.includes(revision.body));
const approvals = harness(firstRevision, planning);
await approvals.emit('session_start');
await approvals.approve('all');
assert.ok(approvals.messages.at(-1).message.content.includes('Usage: /plan-approve'));
assert.equal(approvals.confirmations.length, 0);
await approvals.approve();
assert.equal(approvals.confirmations.length, 1);
const confirmationBody = approvals.confirmations[0][1];
for (const text of [draft.title, draft.goal, draft.body, 'exit planning', 'AGENTS.md']) assert.ok(confirmationBody.includes(text), text);
assert.equal(approvals.branch.length, firstRevision.length + 2);
assert.equal(approvals.approvalEntry().data.draftEntryId, firstRevision.at(-1).id);
assert.equal(approvals.approvalEntry().data.schemaVersion, 2);
assert.match(approvals.approvalEntry().data.planHash, /^[a-f0-9]{64}$/);
assert.equal(approvals.messages.at(-1).options.triggerTurn, false);
assert.deepEqual(approvals.tools(), original);
assert.equal(approvals.statuses.at(-1)[1], undefined);
assert.equal(approvals.emit('tool_call', { toolName: 'write' }), undefined);
assert.equal(approvals.prompts.length, 1);
assert.ok(approvals.prompts[0].includes(draft.body));
assert.ok(approvals.prompts[0].includes('Follow its approval checkpoints'));
const afterApproval = { systemPromptOptions: { sections: {} } };
approvals.emit('before_agent_start', afterApproval);
assert.equal(afterApproval.systemPromptOptions.sections.pi_run_plan, undefined);
await approvals.show();
assert.ok(approvals.messages.at(-1).message.content.includes('Plan approved for this saved revision'));
const approvedBranch = JSON.parse(JSON.stringify(approvals.branch));
await approvals.approve();
assert.equal(approvals.confirmations.length, 1, 'Repeated approval is idempotent');
assert.equal(approvals.branch.length, approvedBranch.length);
assert.equal(approvals.prompts.length, 1, 'Repeated approval must not hand work off twice');
const approvalResume = harness(approvedBranch, planning, 'print', workspace);
await approvalResume.emit('session_start');
await approvalResume.show();
assert.ok(approvalResume.messages.at(-1).message.content.includes('Plan approved for this saved revision'));
assert.deepEqual(approvalResume.tools(), original);
await approvalResume.approve();
assert.ok(approvalResume.messages.at(-1).message.content.includes('confirmation UI is required'));
assert.equal(approvalResume.branch.length, approvedBranch.length);
await approvalResume.export('tracking-only.md');
assert.ok((await readFile(join(workspace, 'tracking-only.md'), 'utf8')).includes('Exported plan'));
assert.ok(!(await readFile(join(workspace, 'tracking-only.md'), 'utf8')).includes('Plan approved for this saved revision'));
await approvalResume.navigate(firstRevision, planning);
await approvalResume.show();
assert.ok(approvalResume.messages.at(-1).message.content.includes('Not approved'), 'Approval must not leak to an earlier branch');
await approvalResume.navigate(approvedBranch, planning);
await approvalResume.show();
assert.ok(approvalResume.messages.at(-1).message.content.includes('Plan approved for this saved revision'));
await approvals.command('');
await approvals.record(draft); // Identical contents, but a new saved revision.
await approvals.show();
assert.ok(approvals.messages.at(-1).message.content.includes('Not approved'));
await approvals.approve();
assert.equal(approvals.confirmations.length, 2);
assert.equal(approvals.prompts.length, 2);
const approvedResume = harness(approvals.branch, original, 'tui');
await approvedResume.emit('session_start');
await approvedResume.approve();
assert.equal(approvedResume.prompts.length, 0, 'Resume must not replay a previous handoff');
await approvedResume.exit();
await approvedResume.show();
assert.ok(approvedResume.messages.at(-1).message.content.includes('No active plan'));
for (const answer of [false, undefined]) {
    const cancelled = harness(firstRevision, planning);
    await cancelled.emit('session_start');
    cancelled.confirmWith(async () => answer);
    await cancelled.approve();
    assert.equal(cancelled.branch.length, firstRevision.length);
    assert.ok(cancelled.messages.at(-1).message.content.includes('cancelled'));
    assert.deepEqual(cancelled.tools(), planning);
    assert.equal(cancelled.prompts.length, 0);
}
for (const branch of [[], [{ id: 'invalid', type: 'custom', customType: 'pi-run-plan-draft', data: {} }],
    [{ type: 'custom', customType: 'pi-run-plan-draft', data: { schemaVersion: 2, draft } }]]) {
    const missing = harness(branch);
    await missing.emit('session_start');
    await missing.approve();
    assert.equal(missing.confirmations.length, 0);
    assert.equal(missing.branch.length, branch.length);
    assert.ok(missing.messages.at(-1).message.content.startsWith('Plan approval not recorded:'));
}
for (const change of [async h => h.record(revision), async h => h.changeSession(),
    async h => h.navigate([...firstRevision, { id: randomUUID(), type: 'custom', customType: 'other' }], planning),
    ...['title', 'goal', 'body'].map(field => async h => { h.branch.at(-1).data.draft[field] += ' changed'; })]) {
    const pending = harness(firstRevision, planning);
    await pending.emit('session_start');
    pending.confirmWith(async () => { await change(pending); return true; });
    await pending.approve();
    assert.ok(pending.messages.at(-1).message.content.includes('changed during confirmation'));
    assert.ok(!pending.branch.some(entry => entry.customType === 'pi-run-plan-approval'));
    assert.equal(pending.prompts.length, 0);
}
const approvedData = approvedBranch.find(entry => entry.customType === 'pi-run-plan-approval').data;
for (const data of [null, {}, { ...approvedData, draftEntryId: 'wrong-revision' },
    { ...approvedData, planHash: '0'.repeat(64) }]) {
    const malformed = harness([...approvedBranch, { id: randomUUID(), type: 'custom', customType: 'pi-run-plan-approval', data }]);
    await malformed.emit('session_start');
    await malformed.show();
    assert.ok(malformed.messages.at(-1).message.content.includes('Not approved'), 'Malformed/latest mismatching approval fails closed');
}
const rpcApproval = harness(firstRevision, planning, 'rpc');
await rpcApproval.emit('session_start');
await rpcApproval.approve();
assert.equal(rpcApproval.confirmations.length, 1);
assert.equal(rpcApproval.approvalEntry().customType, 'pi-run-plan-approval');
assert.deepEqual(rpcApproval.tools(), original);
assert.equal(rpcApproval.prompts.length, 1);
assert.equal(rpcApproval.statuses.length, 0, 'RPC mode does not display TUI status');
const exitedPending = harness(firstRevision, planning);
await exitedPending.emit('session_start');
exitedPending.confirmWith(async () => { await exitedPending.exit(); return true; });
await exitedPending.approve();
assert.equal(exitedPending.approvalEntry(), undefined);
assert.equal(exitedPending.prompts.length, 0);
console.log('PASS lifecycle: whole-plan approval, exit/discard, fresh goals, cancellation, revisions, handoff, and resume/branches');
// Exercise Pi's real dispatcher: normal tools reach independent later reviewers.
const { ExtensionRunner } = await import(pathToFileURL(join(piDir, 'dist/core/extensions/runner.js')).href);
let runtimeTools = [...original], laterCalls = 0, holdCommands = false;
const runtimeBranch = [];
const later = { handlers: new Map([['tool_call', [event => {
    laterCalls++;
    if (holdCommands && event.toolName === 'bash') return { block: true, reason: 'Independent reviewer withheld command' };
}]]]) };
const runner = new ExtensionRunner([...loaded.extensions, later], loaded.runtime, root,
    { getBranch: () => runtimeBranch }, {});
runner.bindCore({ getActiveTools: () => runtimeTools, setActiveTools: names => { runtimeTools = [...names]; },
    sendMessage() {},
    appendEntry: (customType, data) => runtimeBranch.push({ type: 'custom', customType, data }),
}, {});
await runner.emit({ type: 'session_start', reason: 'startup' });
await loaded.extensions[0].commands.get('plan').handler('', runner.createCommandContext());
const runtimeBase = { cwd: root };
const runtimePrompt = await runner.emitBeforeAgentStart('inspect', undefined, runtimeBase);
assert.ok(runtimePrompt.systemPromptOptions.sections.pi_run_plan.includes('Develop the overall plan'));
assert.deepEqual(runtimeTools, planning);
for (const toolName of ['write', 'bash', 'run']) {
    for (const parentToolCallId of [undefined, 'parent']) {
        assert.equal(await runner.emitToolCall({ type: 'tool_call', toolName, toolCallId: 'call', parentToolCallId, input: {} }), undefined);
    }
}
assert.equal(laterCalls, 6);
holdCommands = true;
assert.equal((await runner.emitToolCall({ type: 'tool_call', toolName: 'bash', toolCallId: 'held', input: {} })).block, true);
assert.equal(await runner.emitToolCall({ type: 'tool_call', toolName: 'read', toolCallId: 'read', input: {} }), undefined);
assert.equal(laterCalls, 8);
await recordTool.execute('record', draft, undefined, undefined, runner.createToolContext('record'));
assert.deepEqual(runtimeBranch.at(-1).data, { schemaVersion: 2, draft });
await loaded.extensions[0].commands.get('plan-exit').handler('', runner.createCommandContext());
const disabledPrompt = await runner.emitBeforeAgentStart('ordinary work', undefined, runtimeBase);
assert.equal(disabledPrompt.systemPromptOptions.sections.pi_run_plan, undefined);
assert.deepEqual(runtimeTools, original);
assert.equal((await runner.emitToolCall({ type: 'tool_call', toolName: 'plan_record', toolCallId: 'record', input: draft })).block, true);
assert.equal(laterCalls, 8);
console.log('PASS planning: real Pi tools reach later reviewers; recorder-only restrictions still short-circuit');
const { SessionManager } = await import(pathToFileURL(join(piDir, 'dist/core/session-manager.js')).href);
const nativeSession = SessionManager.inMemory(root), nativeMessages = [], nativePrompts = [];
const nativeLoaded = await loadExtensions([file], root);
const nativeRunner = new ExtensionRunner(nativeLoaded.extensions, nativeLoaded.runtime, root, nativeSession, {});
nativeRunner.bindCore({ getActiveTools: () => runtimeTools, setActiveTools: names => { runtimeTools = [...names]; },
    appendEntry: (type, data) => nativeSession.appendCustomEntry(type, data),
    sendMessage: message => nativeMessages.push(message),
    sendUserMessage: message => nativePrompts.push(message),
}, {});
nativeRunner.setUIContext({ confirm: async () => true, notify() {}, setStatus() {}, setWidget() {}, theme: { fg: themeFg } }, 'tui');
await nativeRunner.emit({ type: 'session_start', reason: 'startup' });
const nativeCommands = nativeLoaded.extensions[0].commands;
await nativeCommands.get('plan').handler('', nativeRunner.createCommandContext());
await nativeLoaded.extensions[0].tools.get('plan_record').definition.execute('record', draft, undefined, undefined, nativeRunner.createToolContext('record'));
const nativeDraftId = nativeSession.getLeafId();
await nativeCommands.get('plan-approve').handler('', nativeRunner.createCommandContext());
const nativeApprovalId = nativeSession.getLeafId();
assert.equal(nativeSession.getBranch().find(entry => entry.customType === 'pi-run-plan-approval').data.draftEntryId, nativeDraftId);
assert.deepEqual(runtimeTools, original);
assert.equal(nativePrompts.length, 1);
await nativeCommands.get('plan-show').handler('', nativeRunner.createCommandContext());
assert.ok(nativeMessages.at(-1).content.includes('Plan approved for this saved revision'));
nativeSession.branch(nativeDraftId);
await nativeRunner.emit({ type: 'session_tree' });
await nativeCommands.get('plan-show').handler('', nativeRunner.createCommandContext());
assert.ok(nativeMessages.at(-1).content.includes('Not approved'));
nativeSession.branch(nativeApprovalId);
await nativeRunner.emit({ type: 'session_tree' });
await nativeCommands.get('plan-show').handler('', nativeRunner.createCommandContext());
assert.ok(nativeMessages.at(-1).content.includes('Plan approved for this saved revision'));
await nativeCommands.get('plan-exit').handler('', nativeRunner.createCommandContext());
const nativeExitId = nativeSession.getLeafId();
await nativeCommands.get('plan-show').handler('', nativeRunner.createCommandContext());
assert.ok(nativeMessages.at(-1).content.includes('No active plan'));
nativeSession.branch(nativeApprovalId);
await nativeRunner.emit({ type: 'session_tree' });
await nativeCommands.get('plan-show').handler('', nativeRunner.createCommandContext());
assert.ok(nativeMessages.at(-1).content.includes('Plan approved for this saved revision'));
nativeSession.branch(nativeExitId);
await nativeRunner.emit({ type: 'session_tree' });
await nativeCommands.get('plan-show').handler('', nativeRunner.createCommandContext());
assert.ok(nativeMessages.at(-1).content.includes('No active plan'));
console.log('PASS lifecycle: real Pi confirmation, handoff, native session IDs, branch navigation, and discard');
// Load Plan, Guard Runtime, and Guardian and verify their widget insertion order.
const guardRuntimeFile = join(root, 'docker/extensions/guard-runtime.ts');
const guardianFile = join(root, 'docker/extensions/guardian-agent.ts');
const planSource = await readFile(file, 'utf8'), guardianSource = await readFile(guardianFile, 'utf8');
assert.ok(!planSource.includes('pi.events'), 'Planning must not coordinate through extension events');
assert.ok(!guardianSource.includes('pi-run-plan'), 'Guardian must not depend on planning');
const layoutProfile = join(testDir, 'layout-profile');
await mkdir(layoutProfile);
const oldProfile = process.env.PI_RUN_PROFILE_DIR;
let layoutLoaded;
try {
    process.env.PI_RUN_PROFILE_DIR = layoutProfile;
    layoutLoaded = await loadExtensions([file, guardRuntimeFile, guardianFile], root);
} finally {
    if (oldProfile === undefined) delete process.env.PI_RUN_PROFILE_DIR;
    else process.env.PI_RUN_PROFILE_DIR = oldProfile;
}
assert.deepEqual(layoutLoaded.errors, []);
const layoutSession = SessionManager.inMemory(root), layoutStatuses = new Map(), layoutWidgets = new Map();
let redraws = 0;
const layoutRunner = new ExtensionRunner(layoutLoaded.extensions, layoutLoaded.runtime, root, layoutSession, {});
layoutRunner.bindCore({ getActiveTools: () => runtimeTools, setActiveTools: names => { runtimeTools = [...names]; },
    appendEntry: (type, data) => layoutSession.appendCustomEntry(type, data),
    sendMessage() {}, sendUserMessage() {},
}, {});
layoutRunner.setUIContext({ confirm: async () => true, notify() {}, theme: { fg: themeFg },
    setStatus: (key, value) => layoutStatuses.set(key, value),
    setWidget: (key, factory, options) => {
        assert.equal(options.placement, 'belowEditor');
        layoutWidgets.delete(key);
        if (factory) layoutWidgets.set(key, factory({ requestRender: () => { redraws++; } }, { fg: themeFg }));
    },
}, 'tui');
const layoutCommands = layoutLoaded.extensions[0].commands;
const planRows = () => layoutWidgets.get('pi-run-plan').render(100);
const guardianRows = () => layoutWidgets.get('guard-runtime').render(100);
await layoutRunner.emit({ type: 'session_start', reason: 'startup' });
assert.deepEqual([...layoutWidgets.keys()], ['pi-run-plan', 'guard-runtime']);
assert.deepEqual(planRows(), []);
assert.ok(guardianRows()[0].startsWith('<muted>guard · off'));
await layoutCommands.get('plan').handler('', layoutRunner.createCommandContext());
assert.deepEqual(planRows(), ['<muted>planning</muted>']);
assert.ok(guardianRows()[0].startsWith('<muted>guard · off'), 'Guardian rendering remains independent');
assert.equal(layoutStatuses.get('pi-run-plan'), undefined, 'No duplicate footer label');
const layoutStartId = layoutSession.getLeafId();
await layoutLoaded.extensions[0].tools.get('plan_record').definition.execute('record', draft, undefined, undefined, layoutRunner.createToolContext('record'));
await layoutCommands.get('plan-approve').handler('', layoutRunner.createCommandContext());
assert.deepEqual(planRows(), [], 'Approval hides planning without changing Guardian');
layoutSession.branch(layoutStartId);
await layoutRunner.emit({ type: 'session_tree' });
assert.deepEqual([...layoutWidgets.keys()], ['pi-run-plan', 'guard-runtime']);
assert.deepEqual(planRows(), ['<muted>planning</muted>'], 'Branch restoration restores planning');
await layoutCommands.get('plan-exit').handler('', layoutRunner.createCommandContext());
assert.deepEqual(planRows(), [], 'Exit hides planning');
layoutSession.branch(layoutStartId);
await layoutRunner.emit({ type: 'session_start', reason: 'resume' });
assert.deepEqual([...layoutWidgets.keys()], ['pi-run-plan', 'guard-runtime']);
assert.deepEqual(planRows(), ['<muted>planning</muted>'], 'Resume restores planning');
assert.ok(redraws > 0);
await layoutRunner.emit({ type: 'session_shutdown' });
assert.equal(layoutWidgets.size, 0);
console.log('PASS placement: independent widgets, planning before Guardian, approval/exit, resume/branches, and shutdown');
const launcher = await readFile(join(root, 'bin/pi-run'), 'utf8');
const planPath = '/usr/local/lib/node_modules/plan-agent/plan-agent.ts';
const runtimePath = '/usr/local/lib/node_modules/guardian-agent/guard-runtime.ts';
const guardianPath = '/usr/local/lib/node_modules/guardian-agent/guardian-agent.ts';
assert.ok(launcher.includes(`--extension ${planPath}`));
assert.ok(launcher.indexOf(planPath) < launcher.indexOf(runtimePath));
assert.ok(launcher.indexOf(runtimePath) < launcher.indexOf(guardianPath));
const dockerfile = await readFile(join(root, 'docker/Dockerfile'), 'utf8');
assert.ok(dockerfile.includes('COPY extensions/plan-agent.ts /usr/local/lib/node_modules/plan-agent/'));
assert.ok(dockerfile.includes('COPY extensions/guard-runtime.ts /usr/local/lib/node_modules/guardian-agent/'));
console.log('PASS planning: loading, commands, prompt, direct/nested hooks, restoration, no-UI, and wiring');
NODE

mkdir -p "${TMP}/fake-bin" "${TMP}/workspace"
# shellcheck disable=SC2016 # Expand these variables in the fake Docker process.
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" > "${DOCKER_LOG:?}"' > "${TMP}/fake-bin/docker"
chmod 0755 "${TMP}/fake-bin/docker"
PATH="${TMP}/fake-bin:${PATH}" PI_RUN_HOME="${TMP}/Pi-Run" DOCKER_LOG="${TMP}/docker.log" \
    "${ROOT}/bin/pi-run" "${TMP}/workspace" >/dev/null
grep -Fx -- /usr/local/lib/node_modules/plan-agent/plan-agent.ts "${TMP}/docker.log" >/dev/null
grep -Fx -- /usr/local/lib/node_modules/guardian-agent/guard-runtime.ts "${TMP}/docker.log" >/dev/null
echo 'PASS planning: launcher passes the explicit extension paths'
