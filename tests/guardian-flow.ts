/** Test-only: real Guardian gate, fixed reviewer, synthetic context, NO executor. */
import assert from "node:assert/strict";
import { chmod, lstat, mkdtemp, mkdir, writeFile, readFile, readdir, rm, symlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import type { ExtensionAPI, ExtensionContext, ExtensionUIContext, ToolCallEventResult } from "@earendil-works/pi-coding-agent";
import guardRuntime, { GUARD_RUNTIME_DISCOVER, type GuardRuntimeV1 } from "../docker/extensions/guard-runtime.ts";
import { createGuardianExtension, createGuardianLogViewRequest, createLogger, loadGuardianModeConfig, parseGuardianConfig, parseGuardianModeConfig, readGuardianLogs, saveGuardianModeConfig, type ReviewDecision } from "../docker/extensions/guardian-agent.ts";

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

async function runScenario(name: Scenario, realUI?: ExtensionUIContext, withRuntime=true): Promise<void> {
  const scenario = scenarios[name];
  const root = await mkdtemp(join(tmpdir(), "guardian-flow-"));
  const profile = join(root, "profile"), workspace = join(root, "workspace");
  const handlers = new Map<string, Handler[]>(), busHandlers = new Map<string, Set<(data:unknown)=>void>>();
  const commands = new Map<string, {handler:(args:string,ctx:ExtensionContext)=>Promise<void>}>();
  const tools = new Map<string,any>();
  let activeTools=["bash","read","edit","write","custom-effect"];
  const calls: string[] = [], reviewedIds: string[] = [], notices: string[] = [], statusLines: string[] = [];
  let outcome: Outcome = scenario.outcome, sessionId = "guardian-flow-test", reviews = 0, assessmentReviews=0, aborts = 0;
  let viewerCalls=0,viewerText="";
  let runtimeService:GuardRuntimeV1|undefined;
  const userEntry = { type: "message", id: "user-1", message: { role: "user", content: "Synthetic test direction; no action may execute." } };
  const entries:any[] = [{ type: "custom", id: "caf-mode-ignored", customType: "pi-run-caf-mode", data: { mode: "off" } },{ type: "custom", id: "mode-1", customType: "guardian-mode", data: { mode: "on" } }, userEntry];
  let branch:any[] = entries;
  const widgets=new Map<string,any>();
  const tui = { terminal:{rows:24},requestRender: () => { for(const widget of widgets.values())statusLines.push(widget.render(120)[0]); } };
  const theme = { fg: (_color:string, text:string) => text, bg:(_color:string,text:string)=>text,bold:(text:string)=>text };
  const reviewerModel={id:"reviewer",provider:"synthetic",api:"openai-responses",reasoning:false,contextWindow:128_000,maxTokens:4096};
  const ctx = {
    cwd: workspace, mode:name==="no-ui"?"print":"tui",hasUI: name !== "no-ui", hasPendingMessages: () => false,
    model:reviewerModel,modelRegistry:{find:(provider:string,id:string)=>provider==="synthetic"&&id==="reviewer"?reviewerModel:undefined,getAvailable:()=>[reviewerModel]},
    abort: () => { aborts++; },
    sessionManager: {
      getSessionId: () => sessionId, getCwd: () => workspace,
      getLeafId: () => branch.at(-1)?.id, getBranch: () => branch, getEntries: () => entries,
    },
    ui: {
      setStatus() {},
      setWidget(id:string, factory:any) { if(typeof factory==="function")widgets.set(id,factory(tui,theme));else widgets.delete(id);tui.requestRender(); },
      notify(message:string) { notices.push(message); realUI?.notify(`TEST ONLY · ${message}`, "info"); },
      async custom(factory:any){viewerCalls++;return await new Promise(resolve=>{let component:any;
        const done=(value:unknown)=>{component?.dispose?.();resolve(value);};component=factory(tui,theme,{},done);
        viewerText=component.render(120).join("\n");done(undefined);});},
      async confirm() { throw new Error("Guardian disputes must not open confirmation dialogs"); },
      async select() { throw new Error("Unexpected selector in short-action fixture"); },
    },
  } as unknown as ExtensionContext;
  const dispatch = async (eventName: string, event: unknown) => {
    const registered=handlers.get(eventName)??[];
    assert.ok(registered.length, `Missing Guardian handler: ${eventName}`);
    let result:unknown;
    for(const handler of registered){const value=await handler(event,ctx);if(value!==undefined)result=value;}
    return result;
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
    const config = JSON.stringify({ schemaVersion: 1, mode: "on", model: "synthetic/reviewer", thinking: "low" });
    await writeFile(join(profile, "guardian", "config.json"), config, { mode: 0o600 });
    const api = {
      events:{on:(channel:string,handler:(data:unknown)=>void)=>{const values=busHandlers.get(channel)??new Set();values.add(handler);busHandlers.set(channel,values);return()=>values.delete(handler);},
        emit:(channel:string,data:unknown)=>{for(const handler of busHandlers.get(channel)??[])handler(data);}},
      on: (eventName: string, handler: Handler) => { const values=handlers.get(eventName)??[];values.push(handler);handlers.set(eventName,values);return()=>handlers.set(eventName,(handlers.get(eventName)??[]).filter(value=>value!==handler)); },
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
      if(withRuntime){
        guardRuntime(api);
        api.events.emit(GUARD_RUNTIME_DISCOVER,{schemaVersion:1,accept:(service:GuardRuntimeV1)=>{runtimeService=service;}});
        assert.ok(runtimeService,"Guard Runtime must be discoverable before Guardian loads");
      }
      createGuardianExtension(() => ({
        select: () => ({
          id: "fixed-test-reviewer",
          async review(request,services) {
            const reassessment=request.dispute!==undefined;
            if(withRuntime){
              assert.equal(runtimeService?.activity()?.clientId,"guardian","Guardian review must own the active Guard lease");
              assert.equal(runtimeService?.activity()?.state,reassessment?"dispute":"reviewing","Guardian activity must identify the active review phase");
            }
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
    if(withRuntime)assert.equal(runtimeService?.reviewMode(),"on","Guardian session mode must publish the shared Guard review mode");
    assert.deepEqual([...widgets.keys()],name!=="no-ui"&&withRuntime?["guard-runtime"]:[],
      "Guardian status must use only the shared runtime widget");
    assert.ok(tools.has("guardian_justify"),"Guardian must register its structured justification tool");
    assert.ok(!activeTools.includes("guardian_justify"),"Justification must be hidden outside a dispute");
    const first = await invoke();
    assert.equal(first?.block !== true, scenario.released&&withRuntime, `${name}: wrong release disposition`);
    assert.equal(reviews, withRuntime?1:0, withRuntime?"The runtime backend must invoke the fixed reviewer":"A missing runtime must not invoke a direct reviewer fallback");
    assert.equal(runtimeService?.activity(),undefined,"Guardian must release its command-review activity");
    if(withRuntime)assert.equal(runtimeService?.status()?.clientId,"guardian","Guardian baseline must resume after command review");

    if (name === "allow"&&withRuntime) {
      assert.ok(commands.has("guardian-default"),"Guardian must expose a dedicated new-session default command");
      assert.ok(commands.has("guardian-status"),"Guardian must expose a dedicated autocomplete-visible status command");
      await commands.get("guardian-status")!.handler("",ctx);assert.match(notices.at(-1)!,/Guard review · On/);
      await commands.get("guardian")!.handler("status",ctx);assert.match(notices.at(-1)!,/Usage: \/guardian/);
      await commands.get("guardian-log")!.handler("forced",ctx);
      assert.equal(viewerCalls,1,"Guardian must open logs through the shared runtime viewer");
      assert.match(viewerText,/Guardian reviews · all retained sessions · UTC/);
      assert.match(viewerText,/Read-only · not a confirmation|log read warning/);
      (ctx.ui as any).select=async(title:string,choices:string[])=>{assert.match(title,/Guard review — On/);for(const label of ["Current session — On (turn Off)","New sessions — Off","Status","Logs","Close"])assert.ok(choices.includes(label),label);return "Close";};
      await commands.get("guardian")!.handler("",ctx);
      branch=[userEntry];await dispatch("session_tree",{type:"session_tree"});
      assert.equal((await invoke())?.block,undefined,"Branch navigation must retain session-wide mode");
      assert.equal(reviews,2);
      await commands.get("guardian-mode")!.handler("off",ctx);assert.equal(runtimeService?.reviewMode(),"off");
      assert.equal(await invoke(),undefined,"Turning Guardian off must bypass review in this session");
      await commands.get("guardian-mode")!.handler("on",ctx);assert.equal(runtimeService?.reviewMode(),"on");
      await commands.get("guardian-default")!.handler("on",ctx);assert.equal((await loadGuardianModeConfig(profile)).defaultMode,"on");
      entries.splice(0,entries.length);branch=entries;sessionId="guardian-flow-new-session";await dispatch("session_start",{type:"session_start"});entries.push(userEntry);
      assert.equal((await invoke())?.block,undefined,"A genuinely new session must use the saved On default");assert.equal(reviews,3);
      await commands.get("guardian-default")!.handler("off",ctx);assert.equal((await invoke())?.block,undefined,"Changing the future default must not alter the current On session");assert.equal(reviews,4);
      await commands.get("guardian-default")!.handler("on",ctx);entries.splice(0,entries.length,userEntry);branch=entries;sessionId="guardian-flow-legacy-session";
      await dispatch("session_start",{type:"session_start"});assert.equal(runtimeService?.reviewMode(),"off");assert.equal(await invoke(),undefined,"An existing session without mode metadata must remain Off");assert.equal(reviews,4);
    } else {
      assert.ok(notices.some(message=>message.includes("Guardian stopped this action; nothing was executed")),"Guardian must show its own dispute reason");
      if(name==="no-ui"||!withRuntime)assert.deepEqual(statusLines,[],"Non-TUI or missing-runtime review must not create status output");
      else assert.ok(statusLines.some(line=>line.includes("guard · dispute · investigating")),"Status must show dispute investigation");
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
      assert.equal(reviews,withRuntime?1:0,"Dispute reads must not invoke the command reviewer");
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
          assert.equal(runtimeService?.activity(),undefined,"Cancelled assessment must release its Guard activity");
          assert.equal(result.details.assessment.status,"unavailable","Cancelled assessment must not produce a decision");
          assert.match(result.details.assessment.error,/cancelled/i);
          assert.ok(!entries.some(e=>e.customType==="guardian-dispute"&&e.data?.assessment),"Late assessment must not be persisted after resolution");
          outcome="ALLOW";assert.equal((await invoke())?.block,undefined,"Fresh work after cancellation must receive normal review");
          assert.equal(reviews,2);cancellationHandled=true;
        }else{
          const result=await justify(params);
          assert.equal(runtimeService?.activity(),undefined,"Completed assessment must release its Guard activity");
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
          if(name!=="no-ui"){
            assert.ok(statusLines.some(line=>line.includes("guard · dispute · assessing")),"Status must expose assessment work");
            assert.ok(statusLines.at(-1)?.includes("guard · dispute · awaiting you"),"Assessment must finish waiting for human judgment");
          }
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
        assert.equal(reviews,withRuntime?1:0,"Blocked dispute tools must not reach the reviewer");
        await dispatch("agent_settled",{type:"agent_settled",aborted:false});
        if(name!=="no-ui"&&withRuntime)assert.ok(statusLines.at(-1)?.includes("guard · dispute · awaiting you"),"Settled agent must wait for the user");
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
        const reopened=await invoke();
        assert.equal(reopened?.block,withRuntime?undefined:true,withRuntime?"Real user feedback must reopen fresh review":"Missing runtime must remain fail closed after fresh user feedback");
        assert.equal(reviews,withRuntime?(name==="ask"?3:2):0);
      }
    }

    assert.equal(aborts,0,"Guardian must not abort the acting agent when opening a dispute");
    await dispatch("session_shutdown",{type:"session_shutdown"});handlers.delete("session_shutdown");
    const snapshot=await readGuardianLogs(profile),events=snapshot.entries.map(entry=>entry.value);
    assert.ok(snapshot.reviews.length>=1,"Completed actions must be grouped for the read-only log viewer");
    let viewFlushes=0;const view=createGuardianLogViewRequest(profile,async()=>{viewFlushes++;},"synthetic"),presented=await view.load(new AbortController().signal);
    await view.load(new AbortController().signal);assert.equal(viewFlushes,2,"Guardian must flush before initial load and refresh");
    assert.equal(presented.rows.length,snapshot.reviews.length,"Guardian must present every grouped review through the runtime contract");
    assert.ok(presented.rows.every(row=>row.searchText&&row.wide&&row.compact));
    assert.match(view.details(presented.rows[0].id,"summary").join("\n"),/Decision|Review|Command/);
    assert.match(view.details(presented.rows[0].id,"timeline").join("\n"),/Times UTC/);
    const runFiles=await readdir(join(profile,"logs","guardian","runs"));
    assert.equal(runFiles.filter(name=>name.endsWith(".jsonl")).length,1,"Guardian must write one run shard");
    assert.equal(runFiles.filter(name=>name.endsWith(".complete")).length,1,"Clean shutdown must complete the run journal");
    assert.ok(snapshot.files.some(name=>name.startsWith("logs/guardian/runs/")),"Run journals must be visible");
    assert.ok(!(await readdir(profile,{recursive:true})).some(name=>String(name).includes(".guardian-log.lock")),"Guardian must not use the shared writer lock");
    const disposition=events.find(e=>e.toolCallId==="synthetic-1"&&["invocation_released","invocation_withheld"].includes(e.event));
    assert.equal(disposition?.event,scenario.released&&withRuntime?"invocation_released":"invocation_withheld");
    const basis=!withRuntime?"review_unavailable":name==="allow"?"reviewer_decision":name==="user-refused"?"existing_user_refusal":name==="unavailable"?"review_unavailable":"reviewer_dispute";
    assert.equal(disposition?.details.basis,basis,"Release/withholding must use the expected path");
    if(!scenario.released||!withRuntime)assert.ok(events.some(e=>e.toolCallId==="synthetic-1"&&e.event==="dispute_opened"),"Dispute event must stay attached to the blocked review");
    if(scenario.assessment!==null)assert.ok(events.some(e=>e.event==="dispute_justification_submitted"),"Structured justification must be retained in Guardian diagnostics");
    if(["unavailable","delayed"].includes(String(scenario.assessment)))assert.ok(events.some(e=>e.event==="dispute_assessment_unavailable"),"Unavailable assessment must be diagnosed");
    else if(scenario.assessment!==null)assert.ok(events.some(e=>e.event==="dispute_assessment_decision"&&e.details.outcome===scenario.assessment),"Completed assessment must be diagnosed without release");
    assert.ok(!events.some(e=>e.event==="confirmation_requested"||e.event==="confirmation_answer"),"Disputes must never create confirmation events");
    assert.ok(!events.some(e=>e.event==="tool_result"),"No execution result may be fabricated");
    assert.equal(await readFile(join(profile,"guardian","config.json"),"utf8"),config);
    assert.equal(reviewedIds.includes("synthetic-1"),withRuntime,"Only the shared runtime backend may invoke the reviewer");
    assert.equal(events.some(e=>e.event==="step_started"&&e.details?.operation==="reviewer assessment"),withRuntime,
      "Backend reviewer diagnostics must be present only when the shared runtime executes the review");
  } finally {
    try { if (handlers.has("session_shutdown")) await dispatch("session_shutdown", { type: "session_shutdown" }); }
    finally { await rm(root, { recursive: true, force: true }); }
  }
}

async function testAutomaticRetention():Promise<void>{
  const root=await mkdtemp(join(tmpdir(),"guardian-retention-")),activeRoot=await mkdtemp(join(tmpdir(),"guardian-retention-active-"));
  const warnings:string[]=[];
  try{
    const paths:string[]=[];
    for(let index=0;index<3;index++){
      const logger=createLogger(root,message=>warnings.push(message),{maxBytes:1024*1024,maxRuns:1});paths.push(logger.path);
      logger.write({timestamp:`2026-01-01T00:00:0${index}.000Z`,event:"retention_fixture",index});
      await Promise.all([logger.close(),logger.close()]);await new Promise(resolve=>setTimeout(resolve,5));
    }
    const runDir=join(root,"logs","guardian","runs"),files=await readdir(runDir);
    assert.deepEqual(files.sort(),[`${basename(paths.at(-1)!)}.complete`,basename(paths.at(-1)!)].sort(),"Only the newest completed run must remain");
    assert.match(await readFile(paths.at(-1)!,"utf8"),/"index":2/);
    const active=createLogger(activeRoot,message=>warnings.push(message),{maxBytes:1024*1024,maxRuns:1});
    active.write({timestamp:"2026-01-01T00:00:00.000Z",event:"active_fixture"});await active.flush();
    const completed=createLogger(activeRoot,message=>warnings.push(message),{maxBytes:1024*1024,maxRuns:1});
    completed.write({timestamp:"2026-01-01T00:00:01.000Z",event:"completed_fixture"});await completed.close();
    assert.match(await readFile(active.path,"utf8"),/active_fixture/);
    await assert.rejects(readFile(completed.path,"utf8"),(error:any)=>error?.code==="ENOENT");
    await active.close();assert.deepEqual(warnings,[]);
  }finally{await rm(root,{recursive:true,force:true});await rm(activeRoot,{recursive:true,force:true});}
}

async function testGuardianModeConfig():Promise<void>{
  const root=await mkdtemp(join(tmpdir(),"guardian-mode-")),profile=join(root,"profile");try{await mkdir(join(profile,"guardian"),{recursive:true,mode:0o700});
    assert.deepEqual(await loadGuardianModeConfig(profile),{schemaVersion:1,defaultMode:"off"});assert.deepEqual(parseGuardianModeConfig('{"schemaVersion":1,"defaultMode":"on"}'),{schemaVersion:1,defaultMode:"on"});
    for(const value of [{schemaVersion:2,defaultMode:"off"},{schemaVersion:1,defaultMode:"invalid"},{schemaVersion:1,defaultMode:"off",extra:true}])assert.throws(()=>parseGuardianModeConfig(JSON.stringify(value)),/mode configuration/);
    await saveGuardianModeConfig(profile,{schemaVersion:1,defaultMode:"on"});const path=join(profile,"guardian","mode.json"),first=(await lstat(path)).ino;
    assert.equal((await lstat(path)).mode&0o777,0o600);await saveGuardianModeConfig(profile,{schemaVersion:1,defaultMode:"off"});assert.notEqual((await lstat(path)).ino,first);
    await chmod(path,0o644);await assert.rejects(loadGuardianModeConfig(profile),/private single-link/);await chmod(path,0o600);const outside=join(root,"outside");await writeFile(outside,'{}\n',{mode:0o600});await rm(path);await symlink(outside,path);
    await assert.rejects(saveGuardianModeConfig(profile,{schemaVersion:1,defaultMode:"on"}),/private single-link/);
  }finally{await rm(root,{recursive:true,force:true});}
}

export async function runAutomatedTests(): Promise<void> {
  assert.deepEqual(parseGuardianConfig(JSON.stringify({schemaVersion:1,mode:"on",model:null,thinking:"low"})),
    {schemaVersion:2,model:null,thinking:"low"},"Legacy profile mode must migrate out of preferences");
  for(const name of Object.keys(scenarios) as Scenario[]){await runScenario(name);console.log(`PASS guardian-flow: ${name}`);}
  await runScenario("allow",undefined,false);
  await testGuardianModeConfig();await testAutomaticRetention();
  console.log("PASS guardian-flow: runtime client, journal retention, unavailable presentation, assessment, cancellation, persistence, human arbitration, and fresh review");
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
