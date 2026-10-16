/** Test-only: real Guardian gate, fixed reviewer, synthetic context, NO executor. */
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext, ExtensionUIContext, ToolCallEventResult } from "@earendil-works/pi-coding-agent";
import { createGuardianExtension, parseGuardianConfig, type ReviewDecision } from "../docker/extensions/guardian-agent.ts";

type Outcome = ReviewDecision["outcome"] | "unavailable";
type Handler = (event: any, ctx: ExtensionContext) => unknown | Promise<unknown>;
const scenarios = {
  allow: { outcome: "ALLOW", assessment: null, released: true },
  ask: { outcome: "ASK", assessment: "ALLOW", released: false },
  "user-refused": { outcome: "USER_REFUSED", assessment: "USER_REFUSED", released: false },
  unavailable: { outcome: "unavailable", assessment: "unavailable", released: false },
  "no-ui": { outcome: "ASK", assessment: "ASK", released: false },
  fallback: { outcome: "ASK", assessment: null, released: false },
  "cancel-assessment": { outcome: "ASK", assessment: "delayed", released: false },
} as const;
type Scenario = keyof typeof scenarios;

async function runScenario(name: Scenario, realUI?: ExtensionUIContext): Promise<void> {
  const scenario = scenarios[name];
  const root = await mkdtemp(join(tmpdir(), "guardian-flow-"));
  const profile = join(root, "profile"), workspace = join(root, "workspace");
  const handlers = new Map<string, Handler>();
  const commands = new Map<string, {handler:(args:string,ctx:ExtensionContext)=>Promise<void>}>();
  const tools = new Map<string,any>();
  let activeTools=["bash","read","edit","write","custom-effect"];
  const calls: string[] = [], reviewedIds: string[] = [], notices: string[] = [], statusLines: string[] = [];
  let outcome: Outcome = scenario.outcome, sessionId = "guardian-flow-test", reviews = 0, assessmentReviews=0, aborts = 0;
  const userEntry = { type: "message", id: "user-1", message: { role: "user", content: "Synthetic test direction; no action may execute." } };
  const entries:any[] = [{ type: "custom", id: "mode-1", customType: "guardian-mode", data: { mode: "on" } }, userEntry];
  let branch:any[] = entries, widget:any;
  const tui = { requestRender: () => { if (widget) statusLines.push(widget.render(120)[0]); } };
  const theme = { fg: (_color:string, text:string) => text, bold:(text:string)=>text };
  const ctx = {
    cwd: workspace, hasUI: name !== "no-ui", hasPendingMessages: () => false,
    abort: () => { aborts++; },
    sessionManager: {
      getSessionId: () => sessionId, getCwd: () => workspace,
      getLeafId: () => branch.at(-1)?.id, getBranch: () => branch, getEntries: () => entries,
    },
    ui: {
      setStatus() {},
      setWidget(_id:string, factory:any) { widget = typeof factory === "function" ? factory(tui, theme) : undefined; tui.requestRender(); },
      notify(message:string) { notices.push(message); realUI?.notify(`TEST ONLY · ${message}`, "info"); },
      async confirm() { throw new Error("Guardian disputes must not open confirmation dialogs"); },
      async select() { throw new Error("Unexpected selector in short-action fixture"); },
    },
  } as unknown as ExtensionContext;
  const dispatch = async (eventName: string, event: unknown) => {
    const handler = handlers.get(eventName);
    assert.ok(handler, `Missing Guardian handler: ${eventName}`);
    return handler(event, ctx);
  };
  const invoke = async (toolName="bash", input:Record<string,unknown>={ command: "printf 'TEST ONLY: synthetic invocation, never executed\\n'", timeout: 1 }) => {
    const id = `synthetic-${calls.length + 1}`; calls.push(id);
    return await dispatch("tool_call", { type: "tool_call", toolName, toolCallId: id, input }) as ToolCallEventResult | undefined;
  };
  const justify = async (params:Record<string,unknown>) => {
    const id=`synthetic-${calls.length+1}`;calls.push(id);
    const gate=await dispatch("tool_call",{type:"tool_call",toolName:"guardian_justify",toolCallId:id,input:params}) as ToolCallEventResult|undefined;
    assert.equal(gate?.block,undefined,"Active justification must pass the dispute gate");
    return tools.get("guardian_justify").execute(id,params,undefined,undefined,ctx);
  };
  try {
    await mkdir(join(profile, "guardian"), { recursive: true, mode: 0o700 });
    await mkdir(workspace);
    await writeFile(join(profile, "AGENTS.md"), "Synthetic profile: user direction defines authorization.\n");
    await writeFile(join(profile, "guardian", "guardian.md"), "Synthetic reviewer fixture; never execute actions.\n");
    const config = JSON.stringify({ schemaVersion: 1, mode: "on", model: null, thinking: "low" });
    await writeFile(join(profile, "guardian", "config.json"), config, { mode: 0o600 });
    const api = {
      on: (eventName: string, handler: Handler) => { handlers.set(eventName, handler); },
      registerCommand: (commandName:string, command:{handler:(args:string,ctx:ExtensionContext)=>Promise<void>}) => { commands.set(commandName,command); },
      registerTool: (tool:any) => { tools.set(tool.name,tool);if(tool.defaultActive!==false&&!activeTools.includes(tool.name))activeTools.push(tool.name); },
      appendEntry: (customType:string,data:unknown) => {
        const entry={type:"custom",id:`custom-${entries.length+1}`,customType,data};entries.push(entry);if(branch!==entries)branch.push(entry);
      },
      getActiveTools:()=>[...activeTools],
      setActiveTools:(names:string[])=>{activeTools=[...names];},
      getAllTools: () => [...["bash","read","edit","write","custom-effect"].map(toolName => ({ name:toolName, description:"Synthetic tool; this harness has no executor." })),...tools.values()],
    } as unknown as ExtensionAPI;
    const previous = process.env.PI_RUN_PROFILE_DIR;
    try {
      process.env.PI_RUN_PROFILE_DIR = profile;
      createGuardianExtension(() => ({
        select: () => ({
          id: "fixed-test-reviewer",
          async review(request,services) {
            const reassessment=request.dispute!==undefined;
            if(reassessment){
              assessmentReviews++;
              assert.equal(request.action.toolName,"bash","Assessment must retain the original blocked tool");
              assert.match(String(request.action.input.command),/synthetic invocation, never executed/,"Assessment must retain exact original arguments");
              assert.match(request.dispute.guardianReason,/TEST ONLY|Review could not complete/,"Assessment must include Guardian's original concern");
              if(scenario.assessment==="delayed")await new Promise((_resolve,reject)=>services.signal.addEventListener("abort",()=>reject(services.signal.reason),{once:true}));
              if(scenario.assessment==="unavailable")return {status:"incomplete",error:"Synthetic assessment failure"};
              const assessed=scenario.assessment as ReviewDecision["outcome"];
              return {status:"completed",decision:{outcome:assessed,basis:assessed==="ALLOW"?"explicit_authorization":assessed==="ASK"?"uncertainty":"user_refusal",
                reason:`TEST ONLY: assessment ${assessed}; human judgment remains required.`,userMessageIds:[request.conversation.filter(m=>m.role==="user").at(-1)!.id]}};
            }
            reviews++; reviewedIds.push(request.action.toolCallId);
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
    assert.ok(tools.has("guardian_justify"),"Guardian must register its structured justification tool");
    assert.ok(!activeTools.includes("guardian_justify"),"Justification must be hidden outside a dispute");
    const first = await invoke();
    assert.equal(first?.block !== true, scenario.released, `${name}: wrong release disposition`);
    assert.equal(reviews, 1, "The real gate must invoke the fixed reviewer");

    if (name === "allow") {
      branch=[userEntry];await dispatch("session_tree",{type:"session_tree"});
      assert.equal((await invoke())?.block,undefined,"Branch navigation must retain session-wide mode");
      assert.equal(reviews,2);
      await commands.get("guardian-mode")!.handler("off",ctx);
      assert.equal(await invoke(),undefined,"Turning Guardian off must bypass review in this session");
      await commands.get("guardian-mode")!.handler("on",ctx);
      entries.splice(0,entries.length,userEntry);branch=entries;sessionId="guardian-flow-new-session";
      await dispatch("session_start",{type:"session_start"});
      assert.equal(await invoke(),undefined,"A new session must start Off despite legacy profile mode");
      assert.equal(reviews,2);
    } else {
      assert.ok(notices.some(message=>message.includes("Guardian stopped this action; nothing was executed")),"Guardian must show its own dispute reason");
      assert.ok(statusLines.some(line=>line.includes("guard · dispute · investigating")),"Status must show dispute investigation");
      assert.ok(activeTools.includes("guardian_justify"),"An investigating dispute must activate structured justification");

      if(name==="ask"){
        await dispatch("session_start",{type:"session_start"});
        assert.ok(statusLines.at(-1)?.includes("guard · dispute · investigating"),"Resume must restore an open dispute");
        branch=[userEntry];await dispatch("session_tree",{type:"session_tree"});
        assert.ok(statusLines.at(-1)?.includes("guard · on"),"A branch without the dispute must remain usable");
        assert.ok(!activeTools.includes("guardian_justify"),"A branch without a dispute must hide justification");
        branch=entries;await dispatch("session_tree",{type:"session_tree"});
        assert.ok(statusLines.at(-1)?.includes("guard · dispute"),"Returning to the disputed branch must restore its latch");
        assert.ok(activeTools.includes("guardian_justify"),"Returning to the disputed branch must restore justification");
      }

      const readCount=name==="fallback"?6:2;
      for(let i=0;i<readCount;i++)assert.equal(await invoke("read",{path:`fixture-${i}.txt`}),undefined,"Bounded native reads must remain available");
      assert.equal(reviews,1,"Dispute reads must not invoke the command reviewer");
      if(name==="fallback")assert.equal((await invoke("read",{path:"too-many.txt"}))?.block,true,"The read budget must be enforced");
      let cancellationHandled=false;
      if(scenario.assessment!==null){
        const justificationTool=tools.get("guardian_justify");
        if(name==="ask"){
          await assert.rejects(()=>justificationTool.execute("invalid",{position:"contest",explanation:""},undefined,undefined,ctx),/Invalid Guardian justification/);
          await assert.rejects(()=>justificationTool.execute("invalid",{position:"contest",explanation:"x".repeat(4001)},undefined,undefined,ctx),/Invalid Guardian justification/);
          await assert.rejects(()=>justificationTool.execute("invalid",{position:"contest",explanation:"bounded",evidence:Array(9).fill("file")},undefined,undefined,ctx),/Invalid Guardian justification/);
        }
        const params={position:name==="unavailable"?"retract":"contest",explanation:"The fixture action remains intentionally synthetic.",evidence:["fixture-0.txt","fixture-1.txt"]};
        if(name==="cancel-assessment"){
          const pending=justify(params);
          for(let i=0;i<100&&assessmentReviews===0;i++)await new Promise(resolve=>setTimeout(resolve,0));
          assert.equal(assessmentReviews,1,"Delayed assessment must start");
          assert.ok(statusLines.some(line=>line.includes("guard · dispute · assessing")),"Status must expose assessment work");
          branch.push({type:"message",id:"user-cancel",message:{role:"user",content:"Cancel the pending assessment."}});
          await dispatch("input",{type:"input",source:"interactive",text:"Cancel the pending assessment."});
          const result=await pending;
          assert.equal(result.details.assessment.status,"unavailable","Cancelled assessment must not produce a decision");
          assert.match(result.details.assessment.error,/cancelled/i);
          assert.ok(!entries.some(e=>e.customType==="guardian-dispute"&&e.data?.assessment),"Late assessment must not be persisted after resolution");
          outcome="ALLOW";assert.equal((await invoke())?.block,undefined,"Fresh work after cancellation must receive normal review");
          assert.equal(reviews,2);cancellationHandled=true;
        }else{
          const result=await justify(params);
          assert.equal(result.terminate,true,"Structured justification must terminate automatic agent follow-up");
          assert.equal(result.details.executed,false);assert.equal(result.details.humanRequired,true);
          assert.equal(assessmentReviews,1,"Every structured submission must receive one assessment");
          assert.match(result.content[0].text,/Guardian dispute — awaiting human judgment/);
          const rendered=justificationTool.renderResult(result,{},theme,{}).render(120).join("\n");
          assert.match(rendered,/Agent position: (contest|retract)/);assert.match(rendered,/fixture action remains intentionally synthetic/);
          const label=scenario.assessment==="ALLOW"?"Concern resolved":scenario.assessment==="ASK"?"Concern remains":scenario.assessment==="USER_REFUSED"?"User restriction remains":"Assessment unavailable";
          assert.match(rendered,new RegExp(`Guardian assessment: ${label}`));
          assert.ok(!activeTools.includes("guardian_justify"),"Submitted justification must remove its model tool");
          const saved=[...entries].reverse().find(e=>e.type==="custom"&&e.customType==="guardian-dispute"&&e.data?.assessment);
          assert.equal(saved?.data.justification.explanation,params.explanation,"Structured position must persist on the active branch");
          assert.equal(saved?.data.assessment.status,scenario.assessment==="unavailable"?"unavailable":"completed","Assessment must persist on the active branch");
          assert.ok(statusLines.some(line=>line.includes("guard · dispute · assessing")),"Status must expose assessment work");
          assert.ok(statusLines.at(-1)?.includes("guard · dispute · awaiting you"),"Assessment must finish waiting for human judgment");
          if(name==="ask"){
            await dispatch("session_start",{type:"session_start"});
            assert.ok(statusLines.at(-1)?.includes("guard · dispute · awaiting you"),"Resume must restore the assessed position's waiting state");
            assert.ok(!activeTools.includes("guardian_justify"),"Resume must not reactivate an assessed submission");
          }
        }
      }else assert.equal(assessmentReviews,0,"Fallback flow must make no assessment call");

      if(!cancellationHandled){
        for(const toolName of ["bash","edit","write","custom-effect"])
          assert.equal((await invoke(toolName,toolName==="bash"?{command:"echo blocked"}:{path:"blocked"}))?.block,true,`${toolName} must be blocked during dispute`);
        assert.equal(reviews,1,"Blocked dispute tools must not reach the reviewer");
        await dispatch("agent_settled",{type:"agent_settled",aborted:false});
        assert.ok(statusLines.at(-1)?.includes("guard · dispute · awaiting you"),"Settled agent must wait for the user");
        assert.ok(!activeTools.includes("guardian_justify"),"Settled disputes must not retain the justification tool");
        await dispatch("input",{type:"input",source:"extension",text:"Synthetic extension input"});
        assert.equal((await invoke("read",{path:"still-blocked.txt"}))?.block,true,"Extension input must not clear the dispute");

        if(name==="ask"){
          await commands.get("guardian-resume")!.handler("",ctx);
          assert.ok(notices.some(message=>message.includes("No action was authorized or replayed")),"Resume must disclaim authorization");
          assert.ok(!activeTools.includes("guardian_justify"),"Resume must remove dispute-only tools");
          assert.equal((await invoke())?.block,true,"Resume must not authorize the next invocation");
          assert.equal(reviews,2,"The next invocation must receive a fresh review");
          await commands.get("guardian-mode")!.handler("off",ctx);
          assert.ok(!activeTools.includes("guardian_justify"),"Guardian Off must remove dispute-only tools");
          assert.equal(await invoke(),undefined,"Turning Guardian off must clear the dispute without replaying it");
          assert.equal(reviews,2,"Guardian Off must not review the fresh invocation");
          await commands.get("guardian-mode")!.handler("on",ctx);
        }
        outcome="ALLOW";
        branch.push({type:"message",id:"user-2",message:{role:"user",content:"New synthetic feedback; reassess, but infer no authority from presence alone."}});
        await dispatch("input",{type:"input",source:"interactive",text:"New synthetic feedback"});
        assert.ok(!activeTools.includes("guardian_justify"),"Real user feedback must remove dispute-only tools");
        assert.equal((await invoke())?.block,undefined,"Real user feedback must reopen fresh review");
        assert.equal(reviews,name==="ask"?3:2);
      }
    }

    assert.equal(aborts,0,"Guardian must not abort the acting agent when opening a dispute");
    await dispatch("session_shutdown",{type:"session_shutdown"});handlers.delete("session_shutdown");
    const events=(await readFile(join(profile,"guardian","guardian.log"),"utf8")).trim().split("\n").map(line=>JSON.parse(line));
    const disposition=events.find(e=>e.toolCallId==="synthetic-1"&&["invocation_released","invocation_withheld"].includes(e.event));
    assert.equal(disposition?.event,scenario.released?"invocation_released":"invocation_withheld");
    const basis=name==="allow"?"reviewer_decision":name==="user-refused"?"existing_user_refusal":name==="unavailable"?"review_unavailable":"reviewer_dispute";
    assert.equal(disposition?.details.basis,basis,"Release/withholding must use the expected path");
    if(!scenario.released)assert.ok(events.some(e=>e.toolCallId==="synthetic-1"&&e.event==="dispute_opened"),"Dispute event must stay attached to the blocked review");
    if(scenario.assessment!==null)assert.ok(events.some(e=>e.event==="dispute_justification_submitted"),"Structured justification must be retained in Guardian diagnostics");
    if(["unavailable","delayed"].includes(String(scenario.assessment)))assert.ok(events.some(e=>e.event==="dispute_assessment_unavailable"),"Unavailable assessment must be diagnosed");
    else if(scenario.assessment!==null)assert.ok(events.some(e=>e.event==="dispute_assessment_decision"&&e.details.outcome===scenario.assessment),"Completed assessment must be diagnosed without release");
    assert.ok(!events.some(e=>e.event==="confirmation_requested"||e.event==="confirmation_answer"),"Disputes must never create confirmation events");
    assert.ok(!events.some(e=>e.event==="tool_result"),"No execution result may be fabricated");
    assert.equal(await readFile(join(profile,"guardian","config.json"),"utf8"),config);
    assert.ok(reviewedIds.includes("synthetic-1"));
  } finally {
    try { if (handlers.has("session_shutdown")) await dispatch("session_shutdown", { type: "session_shutdown" }); }
    finally { await rm(root, { recursive: true, force: true }); }
  }
}

export async function runAutomatedTests(): Promise<void> {
  assert.deepEqual(parseGuardianConfig(JSON.stringify({schemaVersion:1,mode:"on",model:null,thinking:"low"})),
    {schemaVersion:2,model:null,thinking:"low"},"Legacy profile mode must migrate out of preferences");
  for(const name of Object.keys(scenarios) as Scenario[]){await runScenario(name);console.log(`PASS guardian-flow: ${name}`);}
  console.log("PASS guardian-flow: automatic justification assessment, cancellation, persistence, human arbitration, and fresh review");
}

/** Opt-in Pi extension; registers a command only, never a tool or live Guardian hook. */
export default function guardianFlowTests(pi: ExtensionAPI): void {
  let running=false;
  pi.registerCommand("guardian-test",{
    description:"Safe Guardian flow test: allow or open a synthetic dispute; zero commands execute",
    handler:async(args,ctx)=>{
      const name=args.trim();
      if(!Object.hasOwn(scenarios,name)){ctx.ui.notify(`Usage: /guardian-test ${Object.keys(scenarios).join("|")}`,"info");return;}
      if(!ctx.hasUI||!ctx.isIdle()||running){ctx.ui.notify("Guardian flow tests require an idle UI; run one at a time.","warning");return;}
      running=true;
      try{ctx.ui.notify("TEST ONLY — zero commands execute; no confirmation dialog will appear.","info");
        await runScenario(name as Scenario,ctx.ui);ctx.ui.notify(`PASS guardian-flow: ${name}. Zero commands executed; test state removed.`,"info");}
      catch(e){ctx.ui.notify(`FAIL guardian-flow: ${name}: ${e instanceof Error?e.message:String(e)}`,"error");}
      finally{running=false;}
    },
  });
}
