# Software-factory Worker support

## Status and scope

This experiment records agreed principles for making Pi-Run an execution engine
for a software factory. The initial Worker interface is now implemented in source;
see [RPC Workers](../../docs/workers.md) for the concrete command, storage,
protocol, and validation contract. The design discussion below records the
principles and questions that preceded implementation, not release acceptance.
Implementation does not authorize installation, live-provider calls, or publication.

Earlier bounded-factory specifications, task contracts, and schemas were removed.
The current scope is Worker support in Pi-Run, not the factory control plane.

## Agreed responsibility boundary

```text
Factory coordinator and human interface
    ↕ instructions, messages, interaction responses, execution events
Pi-Run Worker interface
    ↕ controlled environment and process lifecycle
Pi agent in the selected profile and workspace
```

Factory instantiates Workers through Pi-Run. Factory owns workflows, work
assignment, scheduling, retries, task state, human Decisions, quality Gates,
logs, and history. It decides what happens after a Worker responds.

Pi-Run validates the selected profile, prepared runtime, workspace, and session;
launches and supervises the controlled Pi process; and exposes structured
identity and execution events. It does not decide whether a factory task passed.

Ordinary interactive `pi-run .` remains independent of Factory.

## Profiles, Role prompts, and work instructions

A Worker launches with a selected profile and workspace. Factory supplies two
kinds of instructions:

- **Role prompt:** dynamic instructions describing the Worker's responsibility
  throughout the session, such as independent code review.
- **Work instruction:** the concrete request to perform now, sent as a user
  message through RPC. Further instructions or discussion may follow.

A Role does not require a dedicated profile. The profile supplies existing
runtime, model, network, credentials, tools, Guardian, CAF, and baseline
instructions. The Role prompt guides behavior but cannot grant permissions or
replace the profile's actual protections. A prompt saying "read-only reviewer"
is not an enforced read-only environment.

The agreed direction is to append the Role to Pi's system instructions at launch,
without replacing the profile baseline. Pi supports
`--append-system-prompt <text-or-file>`. Pi-Run should preserve a host-owned copy
associated with the session and expose it read-only to the Worker. The proposed
transport is a per-launch read-only file; exact storage and mount details remain
for the implementation specification.

"Trusted Role" describes its Factory/host provenance, not a security guarantee
about the model's interpretation. The Worker must not be able to rewrite the
host-owned Role. Resume reapplies that same Role; a different Role requires a new
session.

## Factory is the communication channel

The initial Worker interface uses Pi RPC, not a second interactive TUI attached
to the Worker. Factory forwards coordinator instructions and human messages to
the same conversation, and consumes structured responses and events.

A Worker remains running after an instruction settles, available for multiple
messages until Factory requests shutdown. "Agent finished responding" and
"Worker stopped" are different conditions.

The human interface belongs to Factory. Pi-Run must forward supported Pi
interaction requests, such as extension confirmations or input dialogs, and wait
for a response from Factory. It must not automatically approve them. Factory
owns how it involves the human and records authority-changing Decisions.

Messaging, progress, interaction responses, and abort use the supported Pi RPC
connection. Process shutdown belongs to the controlled connection lifecycle;
exact EOF, signal, timeout, and escalation mechanics remain to be specified.

## Worktree creation and ownership

Factory may ask Pi-Run to create a managed worktree without launching an agent.
Existing `worktree start` combines creation and launch; the new creation primitive
should separate these operations while reusing existing managed-worktree rules.

Successive Workers can reuse the same worktree. Initially, only one Worker may
be active in a particular managed worktree at a time. The previous Worker must
shut down before another takes ownership, even when it has finished responding.
Independent Workers may run concurrently in different managed worktrees.

Stopping a Worker does not commit, integrate, or delete its worktree. Existing
`worktree finish` is not disposable Worker cleanup: it has its own explicit
commit, integration, and cleanup effects.

## Agreed command surface

Concrete arguments and output schemas are defined in [RPC Workers](../../docs/workers.md).

| Command | Intended responsibility |
| --- | --- |
| `pi-run worktree create` | Create a managed worktree without launching Pi. |
| `pi-run worker launch` | Launch a foreground RPC Worker with profile, workspace, and dynamic Role. |
| `pi-run worker resume` | Start a new Worker process for an exact saved session. |
| `pi-run worker inspect` | Return bounded session binding and configuration metadata. |

Existing worktree and session listing commands may gain machine-readable output
where needed. Live Worker status, logs, orchestration, retries, and historical
outcomes remain Factory responsibilities; no global live Worker registry is
introduced.

## Session reference, inspection, and resume

Launch returns an opaque session reference. Factory uses that reference for
`inspect` and `resume`; it need not resupply the profile and workspace. Pi-Run
resolves and validates their association rather than guessing the newest session
or opening an interactive selector.

The reference identifies the conversation binding, not a currently running process
or a factory task. The implementation defines its opaque lookup and snapshot
portability, including inspection of bindings whose transcript is not yet saved.

Resume is explicit and preserves:

- the exact saved Pi conversation;
- associated profile;
- associated workspace;
- original Role instructions.

A missing or moved workspace requires explicit reconnection. Changed execution
configuration or prepared runtime refuses resume with an explanation; ordinary
source edits and conversation history do not constitute configuration drift.

Resume starts a new process through normal Pi-Run setup. It is not process
restoration, automatic replay of interrupted actions, or rollback of partial
work. Factory must reconcile the saved results and source state before deciding
what work to send next.

Host-owned Role and session-binding metadata are needed for this contract. They
are not a Factory task database, background Worker registry, or retained-exit
service. The implementation stores private host bindings and includes them in
encrypted snapshots, without automatic restart or automatic retention/deletion.

## Abort, shutdown, and connection loss

The interface distinguishes:

- **Abort:** interrupt current agent work, including tool execution where
  cancellation is supported, while keeping the Worker available for messages.
- **Shutdown:** end the Worker process while preserving its conversation and
  worktree for explicit resume.
- **Connection loss:** when the controlling Factory connection disappears,
  attempt bounded shutdown rather than allow unsupervised continuation. Require
  explicit resume afterward.

These operations do not undo completed effects, guarantee rollback of external
actions, commit changes, or remove the worktree. Exact cancellation and cleanup
behavior must be validated, including child processes and restricted-network
sidecar cleanup.

Herdr is optional terminal hosting only. It is not required for Factory or RPC
Worker operation and is not part of the Worker protocol. Connection loss means
loss of the controlling Factory channel, not detachment of an unrelated terminal
client.

## Execution status is not task success

Pi-Run reports observable execution facts: readiness, agent settled, aborted or
failed execution, and Worker exit, together with Pi's responses and events.
Factory decides whether the assigned work succeeded using results, tests, and
review.

A successful prompt acknowledgment is not completion. `agent_settled` indicates
that automatic agent work has settled, not that acceptance criteria passed. A
zero process exit or a model's success claim is also not a quality Gate.

## Existing foundations and integration work

Pi provides JSONL RPC commands, responses, execution events, and extension
interaction requests. Pi-Run already supplies profiles, prepared runtimes,
managed worktrees, persistent sessions, and network/credential controls.

These foundations were not sufficient by themselves: ordinary argument
forwarding used interactive Docker startup. The Worker path now implements
non-TTY transport, readiness, stream separation, exact resume, and bounded
termination, with deterministic tests and separate opt-in host acceptance.

Readiness must establish the selected binding and usable Pi connection. RPC
stdout must contain protocol records only; diagnostics must not corrupt it.
The metadata channel, supported RPC operations, and treatment of session/model
changes must preserve the agreed Worker binding.

## Deferred and excluded

- `pi-run exec` is deferred. It could later run deterministic checks without an
  agent in a controlled environment. Initially, Workers can use their existing
  tools to run tests; that does not establish independent validation.
- No subagents or subagent framework are required.
- No mandatory Herdr, daemon, web UI, global live Worker registry, automatic
  reboot restart, or Pi-Run-owned Factory scheduling is introduced.
- No separate Worker permission system replaces profile protections.
- No automatic commit, worktree finish, push, PR, release, deployment, or
  production access follows from Worker completion.
- No Factory implementation or universal lifecycle-capability catalog is part of
  this Pi-Run increment.

## Original implementation questions

The initial answers are documented in [RPC Workers](../../docs/workers.md).
Bindings are snapshot-portable without automatic restart; changed execution
configuration or prepared runtime refuses resume. The following list preserves
the investigation scope:

1. Command arguments, errors, readiness metadata, and clean protocol framing.
2. Opaque session-reference resolution and safe host-owned Role/binding storage.
3. Exact configuration-change detection and resume/reconnection handling.
4. Supported RPC operations, interaction forwarding, and protection against
   in-process session or Role changes that would invalidate the binding.
5. Abort, shutdown, connection-loss detection, deadlines, process-tree cleanup,
   and restricted-network sidecar lifecycle.
6. Worktree creation-only behavior, lock ownership, and machine-readable listing.
7. Guardian, CAF, snapshots, and session lifecycle behavior in noninteractive mode.
8. Retention, portability, privacy, and snapshot treatment of new session metadata.

## Validation direction

Validation uses disposable resources to demonstrate:

- worktree creation without an agent or model call;
- foreground RPC launch and unambiguous session reference/readiness;
- multiple messages and human interaction requests through Factory only;
- preserved profile baseline and read-only dynamic Role instructions;
- one active Worker per managed worktree and separate-worktree concurrency;
- abort without shutdown, bounded shutdown, and connection-loss cleanup;
- exact resume with the same Role/profile/workspace and changed-binding reporting;
- execution status distinct from task success;
- preservation of ordinary Pi-Run, runtime, profile, network, Guardian, CAF,
  session, snapshot, and cleanup behavior.

Deterministic Worker, offline native-Pi RPC, snapshot, and regression tests now
cover the source implementation. Real-Docker and live-provider acceptance remain
separate, explicit checks; simulated tests do not establish those results.
