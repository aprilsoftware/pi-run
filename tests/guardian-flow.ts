/** Test-only: real Guardian gate, fixed reviewer, synthetic context, NO executor. */
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext, ExtensionUIContext, ToolCallEventResult } from "@earendil-works/pi-coding-agent";
import { createGuardianExtension, parseGuardianConfig, type ReviewDecision } from "../docker/extensions/guardian-agent.ts";

type Outcome = ReviewDecision["outcome"] | "unavailable";
type Answer = boolean | undefined;
type Dialog = { title: string; message: string; answer: Answer };
type Handler = (event: any, ctx: ExtensionContext) => unknown | Promise<unknown>;
const scenarios = {
  allow: { outcome: "ALLOW", answer: true, released: true, dialogs: 0, instruction: "No dialog should appear." },
  approve: { outcome: "ASK", answer: true, released: true, dialogs: 1, instruction: "Choose Yes." },
  refuse: { outcome: "ASK", answer: false, released: false, dialogs: 1, instruction: "Choose No." },
  dismiss: { outcome: "ASK", answer: undefined, released: false, dialogs: 1, instruction: "Dismiss with Escape." },
  reopen: { outcome: "ASK", answer: false, released: false, dialogs: 1, instruction: "Choose No; fresh user direction will then be simulated." },
  "user-refused": { outcome: "USER_REFUSED", answer: false, released: false, dialogs: 0, instruction: "No dialog should appear." },
  unavailable: { outcome: "unavailable", answer: true, released: true, dialogs: 1, instruction: "Choose Yes to the run-without-review question." },
  "no-ui": { outcome: "ASK", answer: true, released: false, dialogs: 0, instruction: "No dialog should appear (UI deliberately unavailable)." },
} as const;
type Scenario = keyof typeof scenarios;

async function runScenario(name: Scenario, realUI?: ExtensionUIContext): Promise<void> {
  const scenario = scenarios[name];
  const root = await mkdtemp(join(tmpdir(), "guardian-flow-"));
  const profile = join(root, "profile"), workspace = join(root, "workspace");
  const handlers = new Map<string, Handler>(), commands = new Map<string, {handler:(args:string,ctx:ExtensionContext)=>Promise<void>}>();
  const dialogs: Dialog[] = [], calls: string[] = [], reviewedIds: string[] = [];
  let outcome: Outcome = scenario.outcome, answer: Answer = scenario.answer, sessionId = "guardian-flow-test";
  let reviews = 0, aborts = 0;
  const userEntry = { type: "message", id: "user-1", message: { role: "user", content: "Synthetic test direction; no action may execute." } };
  const entries:any[] = [{ type: "custom", id: "mode-1", customType: "guardian-mode", data: { mode: "on" } }, userEntry];
  let branch:any[] = entries;
  // Only confirm is forwarded to Pi. Test status/widgets cannot disturb live Guardian.
  const ctx = {
    cwd: workspace, hasUI: name !== "no-ui", hasPendingMessages: () => false,
    abort: () => { aborts++; },
    sessionManager: {
      getSessionId: () => sessionId, getCwd: () => workspace,
      getLeafId: () => branch.at(-1)?.id, getBranch: () => branch, getEntries: () => entries,
    },
    ui: {
      setStatus() {}, setWidget() {}, notify() {},
      async confirm(title: string, message: string, options: any) {
        assert.ok(ctx.hasUI, "Unavailable UI must never be called");
        const value = realUI ? await realUI.confirm(`TEST ONLY · ${title}`, message, options) : answer;
        dialogs.push({ title, message, answer: value });
        return value;
      },
      async select() { throw new Error("Unexpected selector in short-action fixture"); },
    },
  } as unknown as ExtensionContext;
  const dispatch = async (name: string, event: unknown) => {
    const handler = handlers.get(name);
    assert.ok(handler, `Missing Guardian handler: ${name}`);
    return handler(event, ctx);
  };
  const invoke = async () => {
    const id = `synthetic-${calls.length + 1}`;
    calls.push(id);
    // A release is observed and discarded. There is no tool registration or execution.
    return await dispatch("tool_call", {
      type: "tool_call", toolName: "bash", toolCallId: id,
      input: { command: "printf 'TEST ONLY: synthetic invocation, never executed\\n'", timeout: 1 },
    }) as ToolCallEventResult | undefined;
  };
  try {
    await mkdir(join(profile, "guardian"), { recursive: true, mode: 0o700 });
    await mkdir(workspace);
    await writeFile(join(profile, "AGENTS.md"), "Synthetic profile: user direction defines authorization.\n");
    await writeFile(join(profile, "guardian", "guardian.md"), "Synthetic reviewer fixture; never execute actions.\n");
    const config = JSON.stringify({ schemaVersion: 1, mode: "on", model: null, thinking: "low" });
    await writeFile(join(profile, "guardian", "config.json"), config, { mode: 0o600 });
    const api = {
      on: (name: string, handler: Handler) => { handlers.set(name, handler); },
      registerCommand: (name:string, command:{handler:(args:string,ctx:ExtensionContext)=>Promise<void>}) => { commands.set(name,command); },
      appendEntry: (customType:string,data:unknown) => {
        const entry={type:"custom",id:`mode-${entries.length+1}`,customType,data};entries.push(entry);if(branch!==entries)branch.push(entry);
      },
      getAllTools: () => [{ name: "bash", description: "Synthetic command; this harness has no executor." }],
    } as unknown as ExtensionAPI;
    // Guardian captures this directory synchronously; restore the environment before any await.
    const previous = process.env.PI_RUN_PROFILE_DIR;
    try {
      process.env.PI_RUN_PROFILE_DIR = profile;
      createGuardianExtension(() => ({
        select: () => ({
          id: "fixed-test-reviewer",
          async review(request) {
            reviews++;
            reviewedIds.push(request.action.toolCallId);
            if (outcome === "unavailable") return { status: "incomplete", error: "Synthetic reviewer failure" };
            return { status: "completed", decision: {
              outcome, basis: outcome === "ALLOW" ? "explicit_authorization" : outcome === "ASK" ? "missing_authorization" : "user_refusal",
              reason: `TEST ONLY: forced ${outcome}; this harness cannot execute commands.`,
              userMessageIds: [request.conversation.filter(m => m.role === "user").at(-1)!.id],
            } };
          },
        }),
      }))(api);
    } finally {
      if (previous === undefined) delete process.env.PI_RUN_PROFILE_DIR;
      else process.env.PI_RUN_PROFILE_DIR = previous;
    }
    await dispatch("session_start", { type: "session_start" });
    const first = await invoke();
    assert.equal(first?.block !== true, scenario.released, `${name}: wrong release disposition`);
    assert.equal(reviews, 1, "The real gate must invoke the fixed reviewer");
    assert.equal(dialogs.length, scenario.dialogs, `${name}: wrong dialog count`);
    if (scenario.dialogs) {
      assert.match(dialogs[0].title, name === "unavailable" ? /review unavailable/ : /approval needed/);
      assert.match(dialogs[0].message, /synthetic invocation, never executed/);
      assert.match(dialogs[0].message, name === "unavailable" ? /Run once without review\?/ : /Run once\?/);
      assert.equal(dialogs[0].answer === true, scenario.answer === true, "Unexpected human answer; rerun with the instructed choice");
    }
    if(name==="allow"&&!realUI){
      branch=[userEntry];await dispatch("session_tree",{type:"session_tree"});
      assert.equal((await invoke())?.block,undefined,"Branch navigation must retain session-wide mode");
      assert.equal(reviews,2);
      await commands.get("guardian-mode")!.handler("off",ctx);
      assert.equal(await invoke(),undefined,"Turning Guardian off must bypass review in this session");
      assert.equal(reviews,2);
      await commands.get("guardian-mode")!.handler("on",ctx);
      assert.equal((await invoke())?.block,undefined,"Turning Guardian on must restore review in this session");
      assert.equal(reviews,3);
      entries.splice(0,entries.length,userEntry);branch=entries;sessionId="guardian-flow-new-session";
      await dispatch("session_start",{type:"session_start"});
      assert.equal(await invoke(),undefined,"A new session must start Off despite legacy profile mode");
      assert.equal(reviews,3);
    }
    if (name === "approve" && !realUI) {
      answer = false;
      assert.equal((await invoke())?.block, true, "Approval must not authorize another invocation");
      assert.equal(dialogs.length, 2, "The next forced ASK needs its own confirmation");
      assert.equal(reviews, 2);
    }
    if (["refuse", "dismiss", "reopen"].includes(name)) {
      outcome = "ALLOW";
      assert.equal((await invoke())?.block, true, "Decline must pause subsequent commands");
      await dispatch("input", { type: "input", source: "extension", text: "Synthetic extension input" });
      assert.equal((await invoke())?.block, true, "Extension input must not clear the pause");
      assert.equal(reviews, 1, "Paused commands must not reach the reviewer");
      assert.equal(dialogs.length, 1, "Paused commands must not ask repeatedly");
      if (name === "reopen") {
        branch.push({ type: "message", id: "user-2", message: { role: "user", content: "New synthetic direction; reassess a new invocation." } });
        await dispatch("input", { type: "input", source: "interactive", text: "New synthetic direction" });
        assert.equal((await invoke())?.block, undefined, "New user direction must permit fresh review");
        assert.equal(reviews, 2, "Reopened work must be reviewed again");
        assert.deepEqual(reviewedIds, ["synthetic-1", "synthetic-4"], "Only the new invocation may be reassessed");
        assert.equal(dialogs.length, 1);
        assert.deepEqual(calls, ["synthetic-1", "synthetic-2", "synthetic-3", "synthetic-4"], "Old invocation must not replay");
      }
    }
    assert.equal(aborts, 0, "Guardian must not abort the acting agent after a decline");
    await dispatch("session_shutdown", { type: "session_shutdown" });
    handlers.delete("session_shutdown");
    const events = (await readFile(join(profile, "guardian", "guardian.log"), "utf8")).trim().split("\n").map(line => JSON.parse(line));
    const disposition = events.find(e => e.toolCallId === "synthetic-1" && ["invocation_released", "invocation_withheld"].includes(e.event));
    assert.equal(disposition?.event, scenario.released ? "invocation_released" : "invocation_withheld");
    const basis = name === "allow" ? "reviewer_decision" : name === "approve" ? "human_confirmation" :
      name === "unavailable" ? "human_without_review" : name === "user-refused" ? "existing_user_refusal" :
      name === "no-ui" ? "confirmation_unavailable" : "dialog_not_approved";
    assert.equal(disposition?.details.basis, basis, "Release/withholding must use the expected path");
    assert.ok(!events.some(e => e.event === "tool_result"), "No execution result may be fabricated");
    assert.equal(await readFile(join(profile, "guardian", "config.json"), "utf8"), config);
  } finally {
    try {
      if (handlers.has("session_shutdown")) await dispatch("session_shutdown", { type: "session_shutdown" });
    } finally { await rm(root, { recursive: true, force: true }); }
  }
}

export async function runAutomatedTests(): Promise<void> {
  assert.deepEqual(parseGuardianConfig(JSON.stringify({schemaVersion:1,mode:"on",model:null,thinking:"low"})),
    {schemaVersion:2,model:null,thinking:"low"},"Legacy profile mode must migrate out of preferences");
  for (const name of Object.keys(scenarios) as Scenario[]) {
    await runScenario(name);
    console.log(`PASS guardian-flow: ${name}`);
  }
  console.log("PASS guardian-flow: session-scoped mode and legacy preference migration");
}

/** Opt-in Pi extension; registers a command only, never a tool or live Guardian hook. */
export default function guardianFlowTests(pi: ExtensionAPI): void {
  let running = false;
  pi.registerCommand("guardian-test", {
    description: "Safe Guardian flow test: allow, approve, refuse, dismiss, reopen, user-refused, unavailable, no-ui",
    handler: async (args, ctx) => {
      const name = args.trim();
      if (!Object.hasOwn(scenarios, name)) {
        ctx.ui.notify(`Usage: /guardian-test ${Object.keys(scenarios).join("|")}`, "info");
        return;
      }
      if (!ctx.hasUI || !ctx.isIdle() || running) {
        ctx.ui.notify("Guardian flow tests require an idle dialog-capable UI; run one at a time.", "warning");
        return;
      }
      running = true;
      try {
        ctx.ui.notify(`TEST ONLY — zero commands execute. ${scenarios[name as Scenario].instruction}`, "info");
        await runScenario(name as Scenario, ctx.ui);
        ctx.ui.notify(`PASS guardian-flow: ${name}. Zero commands executed; test state removed.`, "info");
      } catch (e) {
        ctx.ui.notify(`FAIL guardian-flow: ${name}: ${e instanceof Error ? e.message : String(e)}`, "error");
      } finally { running = false; }
    },
  });
}
