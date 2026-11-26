# Software-factory worker experiment

## Status

This directory records an experimental direction for making Pi-Run a worker
execution platform for a future software factory. It is not a product
specification, approved command contract, implementation plan, or authority to
add commands, persistent state, services, publication, deployment, or production
access.

Earlier bounded-factory specifications, task contracts, schemas, and roadmap
material have been removed. New work should begin from this smaller execution
boundary and proceed through separately approved increments.

## Direction

The software factory is an end-to-end engineering production system. Pi-Run is
not that control plane. Pi-Run supplies controlled agent Workers that a factory
can launch and supervise.

```text
Software Factory
  ├── definitions and workflows
  ├── orchestration and human decisions
  ├── quality gates and evidence
  ├── delivery and operations integrations
  └── Worker manager
          ↓
       Pi-Run
          ├── profiles
          ├── prepared runtimes
          ├── network and credentials
          ├── managed worktrees
          ├── sessions
          ├── Guardian and CAF
          └── Pi process lifecycle
                  ↓
                 Pi
```

The factory decides what work exists, which Worker Role is needed, when a Worker
starts, whether a workflow advances, and what outcome is accepted. Pi-Run decides
how one selected Worker runs in a controlled Pi-Run Environment.

## No subagent requirement

Pi-Run does not need native subagent orchestration for this direction.
Factory-level orchestration can start separate Pi-Run Workers when it needs
planning, implementation, QA, Review, security analysis, or another Role.

Optional within-session delegation may be investigated independently later, but
it must not become the factory's task scheduler, authority system, or required
Worker protocol.

## Worker concept

A Pi-Run Worker is one Pi execution bound to an explicit:

- profile;
- Workspace or managed worktree;
- prepared runtime;
- network and credential policy;
- persistent Pi session;
- interaction mode.

A Worker is not a factory task, workflow, Stage, queue item, or Role. The factory
owns those semantic identities and records their relationship to the Pi-Run
Worker.

## Candidate responsibility boundary

### Factory owns

- Work Definitions and workflow state;
- Worker Roles and scheduling;
- human Decisions and effect authority;
- retries, timeouts, and escalation;
- quality Gates and Evidence interpretation;
- publication, release, deployment, and operational policy;
- Factory Run history and status.

### Pi-Run owns

- profile and prepared-image validation;
- Workspace resolution and managed-worktree locking;
- container construction and cleanup;
- network and credential selection;
- Pi session creation and exact resume;
- Pi process launch and termination behavior;
- structured Worker readiness and runtime identity;
- existing Guardian, CAF, snapshot, and session semantics.

### Pi owns

- model interaction;
- conversation and context;
- tool execution;
- JSON or RPC events;
- agent settling, cancellation, and session behavior.

## Existing foundation

Pi already supports interactive, print, JSON, and RPC modes. JSON mode provides
structured events for one invocation. RPC mode provides a long-lived,
bidirectional process interface with prompts, events, cancellation, session
operations, and shutdown.

Pi-Run already forwards Pi arguments through ordinary and managed-worktree
launches. A factory can therefore experiment with RPC Workers through the normal
Pi-Run launcher without terminal scraping.

The experiment should reuse Pi's supported JSON and RPC protocols rather than
invent another agent protocol.

## Candidate Pi-Run Worker commands

Exact grammar remains open. A machine-facing namespace may eventually resemble:

```text
pi-run worker launch ...
pi-run worker resume ...
pi-run worker inspect ... --json
```

`launch` is preferred over `start` when the command remains a foreground process.
It should validate and prepare the selected Pi-Run Environment, then run Pi in an
explicit TUI, JSON, or RPC mode.

`resume` should launch an exact validated session through normal Pi-Run setup,
without an interactive selector, newest-session guessing, or direct plain-Pi
restore that bypasses Pi-Run.

`inspect` should return bounded machine-readable metadata needed by the factory,
without exposing credentials, private policy, or unrelated profile state.

The command names, arguments, output schema, and identity model are experimental.

## Foreground ownership

The preferred initial Worker process remains in the foreground. The factory
starts it as a child process and owns its PID, event stream, live status,
cancellation, retry policy, and historical result.

This avoids adding a Pi-Run daemon, background Worker registry, retained exits,
log service, scheduler, or second control plane. Herdr may host the factory's
foreground terminal when detachment is needed.

A future requirement for independently managed background Workers would require a
new design rather than being implied by the initial commands.

## Structured readiness

A factory needs an unambiguous indication that:

- Pi-Run validation succeeded;
- the expected profile and Workspace were selected;
- the container and Pi process started;
- the exact session identity is known;
- RPC input may begin when RPC mode is selected.

RPC stdout must remain valid JSONL. Human diagnostics cannot be mixed into the
protocol stream. Readiness may require a Pi-Run protocol event, a separately
specified file descriptor, or another bounded machine channel.

## Worker identity and resume

The experiment must distinguish:

- factory Run, Stage, and Role identity;
- Pi-Run Worker execution identity;
- stable Workspace identity;
- managed-task name when applicable;
- Pi session identity;
- operating-system process identity.

Factory identity must not be inferred from a terminal title, prompt, newest
session, or worktree name alone.

Resume creates another live execution for the same validated Pi session and
Workspace. It does not imply that a factory workflow may continue without its
own revalidation and authority.

## Termination semantics

The Worker interface should distinguish:

- agent settled while Pi remains available;
- graceful RPC shutdown;
- user exit;
- cancellation;
- Pi or provider failure;
- Pi-Run launch failure;
- external process termination;
- forced termination after a bounded timeout.

Worker exit alone is not proof that a factory Stage succeeded. The factory owns
that interpretation.

## Machine-readable inspection

Candidate inspection data may include:

```json
{
  "profile": "development",
  "workspaceId": "...",
  "managedTask": "feature-x",
  "sessionId": "...",
  "mode": "rpc",
  "networkMode": "restricted",
  "runtimeImageId": "sha256:...",
  "state": "inactive"
}
```

The final contract should expose only stable data required for integration.
Internal host paths, credentials, reviewer policy, and unrelated identifiers
should remain private.

## Deterministic execution

A software factory also needs deterministic Checks that do not require an agent
to run a command. This may justify a separate future Pi-Run primitive such as:

```text
pi-run exec ... -- <exact argument array>
```

That primitive would execute a declared command in a prepared Pi-Run Environment
against a selected Workspace. It is distinct from a Pi-Run Worker because no
model or Pi session is involved.

The Worker experiment should not silently implement this larger execution
contract, but its Environment and Workspace identities should leave the later
primitive possible.

## Questions for the experiment

1. Does Pi-Run own only Worker provisioning and foreground execution while the
   factory owns scheduling, logs, retries, and history?
2. Can the existing launcher safely expose Pi RPC without changing ordinary TUI
   behavior?
3. How should readiness metadata coexist with the JSONL RPC stream?
4. What exact session reference permits safe noninteractive resume?
5. Should worktree provisioning remain combined with launch or gain a separate
   machine-oriented operation?
6. Which metadata is stable enough for a public machine interface?
7. How are exit, cancel, abort, settled, and forced termination represented?
8. Which existing Pi-Run locks remain held for the complete Worker lifetime?
9. How does restricted networking and its sidecar behave during RPC shutdown and
   restart requests?
10. Which Factory-specific extension, if any, is needed for structured Worker
    result proposals?
11. Can the experiment avoid all background state and still support the intended
    factory control plane?
12. Which behavior requires changes in Pi and which can remain entirely in
    Pi-Run?

## Initial experiment boundary

A first proof should be disposable and demonstrate:

1. launch one managed-worktree Worker through Pi-Run in RPC mode;
2. receive bounded readiness and exact session identity;
3. send one prompt and consume events through `agent_settled`;
4. cancel or shut down predictably;
5. relaunch through Pi-Run and resume the exact session;
6. preserve normal profile, runtime, network, worktree, Guardian, CAF, snapshot,
   and cleanup behavior;
7. keep factory state and authority outside the Worker container;
8. leave ordinary `pi-run .` behavior unchanged.

The proof does not require subagents, parallel Workers, a daemon, a web UI,
publication, release, deployment, production access, or a complete software
factory.
