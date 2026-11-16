# Bounded software factory

## Status and authority

This document records the v0.11 architecture for a bounded Pi-Run software
factory. It selects product boundaries and identifies design questions that must
be resolved before implementation. It is not authority to create tasks, start
runs, modify repositories, install dependencies, invoke providers, push branches,
open pull requests, merge, deploy, or publish a release.

It incorporates the comparative [software-factory research](software-factory-research.md)
and [detachable-run research](detachable-and-daemon-runs-research.md). The factory
does not make Herdr, RPC, Guardian, CAF, Planning, managed worktrees, runtime
identity, or network policy into a sandbox or correctness guarantee.

## Product outcome

The Level 1 factory turns one human-selected and explicitly approved task into a
validated, freshly reviewed local worktree and branch:

```text
human task selection
    → exact task approval
    → managed worktree and dedicated conversation
    → live Pi-Run execution, optionally held by Herdr
    → bounded implementation and wake-ups
    → deterministic checks
    → fresh-context review
    → evidence manifest and completion report
    → human decision about commit, push, PR, merge, or publication
```

The worktree may remain dirty. Success does not automatically commit, finish the
managed worktree, push, create a pull request, merge, tag, release, deploy,
repair production, or select another task. Later asynchronous, event-driven, and
parallel maturity levels remain architectural directions, not v0.11 promises.

## Terminology

- **Pi session:** persisted conversation and branch history.
- **Live execution:** one ordinary Pi-Run launcher process, optionally hosted in
  an external persistent terminal such as Herdr.
- **Factory task:** approved repository, base revision, goal, scope, acceptance,
  checks, limits, exclusions, and desired local outcome.
- **Factory attempt:** one execution attempt for one exact task revision.
- **Factory phase:** preparing, implementing, waiting, verifying, reviewing,
  remediating, paused, blocked, failed, exhausted, cancelled, or completed.
- **Wake-up:** a bounded reason an approved attempt may continue; never authority.
- **Evidence manifest:** immutable validation, review, usage, and outcome evidence.
- **Review run:** a fresh bounded context that inspects implementation and
  evidence without inheriting the implementation conversation's reasoning.
- **Factory-ready repository:** a repository with legible instructions,
  deterministic validation, safe worktree behavior, and bounded local evidence.

## Selected initial decisions

### Minimum successful output

The first factory stops with the managed worktree and task branch preserved,
intended changes inspectable, deterministic checks recorded, fresh-context review
findings recorded, and a completion report describing changes, validation,
deviations, limitations, and terminal state.

The worktree may remain dirty. Success does not imply a Git commit. Existing
`worktree finish` behavior remains a separate human command with its own
confirmation, commit, integration, and cleanup contract.

### Authoritative state location

Factory task approval, attempt control, and evidence belong to host-owned private
state under a future `<PI_RUN_HOME>/factory/` namespace. It is not mounted into
normal Pi sessions or writable by acting or review agents.

External terminal-runtime state does not belong to Pi-Run factory authority.
Herdr may retain panes, labels, terminal history, and live-process presentation,
but Pi-Run does not mirror those into a `<PI_RUN_HOME>/runs/` registry or restore
them as factory state.

The exact factory layout remains open, but the boundary is fixed:

- a live execution or Herdr pane may reference an attempt without approving it;
- profiles may be referenced but do not own factory authority;
- session entries may mirror presentation and evidence but are not the sole host
  orchestration record;
- repository files, issues, events, and CI logs provide provenance only;
- Todo remains a private human prompt queue and never becomes factory intake;
- logs and transcripts are evidence, not authority.

Factory state becomes snapshot-eligible only after restore, machine association,
stale-attempt, archival, and secret-handling semantics are designed.

### Approval identity

Human approval binds one exact factory task revision, including:

- task schema and revision;
- normalized repository identity and exact base commit;
- managed task/worktree identity;
- selected profile and configured network mode;
- goal, acceptance criteria, allowed effects, and exclusions;
- deterministic validation declarations;
- iteration, duration, failure, and no-progress limits;
- desired terminal state;
- cryptographic hash of the normalized task.

Changing a bound field invalidates approval. Issue edits, Plan revisions, branch
movement, profile/runtime changes, or validation changes do not silently update
an approved task. Approval of one task does not approve another task, queue item,
roadmap, release train, or unrestricted discovered remediation.

### Loop and wake-up ownership

A loop is one timer-based wake-up source belonging to one factory attempt, not
to a repository, profile, Todo queue, or unbounded conversation. The initial
contract permits one active loop per attempt.

Creation, resumption, extension, and limit increases are human actions. A model
may only stop its current loop; it cannot create another, broaden the prompt,
extend duration, increase iterations, transfer it, or create another wake-up.
Human input and fixed timers are the first wake-up types. Process, CI, review,
and webhook events remain later possibilities and never create authority.

### Optional Herdr terminal hosting

The selected direction runs the unchanged foreground Pi-Run launcher inside a
user-operated Herdr pane when detachable interaction is needed. Herdr owns the
persistent terminal, attachment, workspace/pane inventory, and live status.
Pi-Run owns the launcher, locks, restricted networking, Pi state, snapshot
bridging, cleanup, and every factory authority decision.

Pi-Run initially adds no background, attach, run-registry, stop, or remove
commands. It does not mount the Herdr socket into the container, invoke plain
`pi` through Herdr's agent launcher, or use Herdr's plain-`pi` native restore.
Ordinary launches remain independent of Herdr. The exact compatibility and
security boundary is recorded in the
[detachable-runs design](detachable-runs-design.md).

## Factory task sources

| Source | Useful role | Not sufficient for |
| --- | --- | --- |
| Human-entered task | Direct goal and scope | Approval until exact revision is confirmed |
| Saved Plan | Rich design and decisions | Factory approval or whole-plan execution |
| GitHub issue | Intake and discussion | Local authority, credentials, or publication |
| Repository task file | Versioned context | Human approval or effect expansion |
| Todo item | Private draft prompt | Model exposure, submission, or execution |
| CI/review event | Wake-up evidence | Broader remediation authority |

The first implementation should use a host-created local task contract. External
links are provenance only. Automatic backlog or issue consumption is excluded.

## Factory attempt lifecycle

```text
draft → approved → preparing → running
                              ↔ waiting
                              ↔ verifying
                              ↔ reviewing
                              ↔ remediating
                              → completed | blocked | failed | exhausted | cancelled
```

An active phase may become `paused` because of shutdown, session replacement,
human action, provider unavailability, or another recoverable interruption.
Resume revalidates task, repository, worktree, base relationship, profile,
runtime, network configuration, approval, live-execution identity, and remaining
limits.

A terminal state is immutable attempt history. Retrying creates a new attempt ID
rather than erasing results or resetting counters. Herdr attachment state remains
external presentation; reattachment does not resume paused effectful work or
change factory phase.

## Bounded `/loop` contract

The first `/loop` is narrower than a durable scheduled-task service:

- a human supplies an explicit fixed interval and prompt;
- interval, iterations, and wall-clock duration are bounded;
- there is no bare maintenance prompt or project-controlled `loop.md`;
- dynamic model-selected cadence is deferred;
- only one active loop exists for an attempt;
- timer wake-ups never overlap turns;
- missed wake-ups coalesce to at most one pending iteration;
- there is no catch-up replay;
- status, next wake-up, iteration, limits, and stop reason are visible;
- process or session shutdown pauses the loop;
- restart, resume, or reattachment never resumes effectful work silently;
- each iteration is an ordinary user-message turn subject to normal instructions,
  Guardian review, network policy, and prepared-runtime selection.

Polling is a fallback for unavailable events, primarily external waiting such as
CI, review, or builds. `/loop` is not the controller or approval source.

## Worktree and runtime integration

One attempt uses one managed worktree, one dedicated conversation, and one
controlled Pi-Run execution. That execution may be displayed through Herdr, but
Herdr pane identity is not the durable attempt controller. The factory reuses
existing validation for repository relationships, portable workspace identity,
machine association, branch/path, links, Git administration, launch locking, and
stale-lock recovery.

The selected prepared profile image and network mode come from normal Pi-Run
launch behavior. A task cannot request an implicit runtime build, profile
migration, credential addition, network expansion, mount, or alternate image.
Changes affecting bound identity pause or invalidate the attempt.

## Implementation, verification, and evidence

The implementation context receives the exact approved task and current phase.
It iterates only within that scope. Discovering another useful task produces a
reported follow-up, not automatic execution.

Verification is deterministic where possible:

- a model assertion cannot replace command output or declared evidence;
- checks run in the selected worktree and declared runtime/network context;
- exit status, bounded output identity, timing, and retry count are recorded;
- changed validation declarations require new approval;
- skipped checks remain skips;
- provider, production, shared-infrastructure, or meaningful external checks
  require their own authority.

Each terminal attempt produces an immutable evidence manifest containing task
and approval identity, repository/base/worktree and changed-content identity,
runtime/network identity, timing and budgets, pass/fail/skip results, review and
remediation findings, usage, terminal state, and limitations. It must remain
inspectable without exposing credentials, unrelated private host paths, or
unbounded transcripts.

## Fresh-context review

Guardian reviews covered command actions; it is not the factory's complete
code-quality reviewer.

The preferred direction is another bounded Primary run with review-only
instructions and read-oriented tools, rather than a fifth embedded agent. This
preserves the four-agent role model while giving the diff and evidence a fresh
context. The exact mechanism remains open and must define context creation,
evidence, tools, structured findings, remediation bounds, provider/model choice,
disclosure, cost, cancellation, and human escalation.

Review cannot merge, push, publish, widen scope, approve its own remediation, or
replace deterministic acceptance checks.

## Visibility and durable evidence

Factory presentation distinguishes task and attempt IDs and shows
repository/branch, phase, wake-up limits, next timer, latest validation/review
result, elapsed time, and exact stop or pause reason. Herdr may separately show
pane and live-agent attachment state. The model receives only phase-relevant
context; private host paths, Herdr identity, workspace UUIDs, credentials,
unrelated profile state, and other tasks are not exposed merely for presentation.

## Failure and recovery

The factory fails closed on malformed, linked, permission-unsafe, conflicting,
ambiguous, oversized, or incompatible state. It does not reset invalid state to
make progress.

An attempt pauses or stops for exhausted limits, repeated validation failure,
deterministic no progress, changed bound identity, unavailable required provider,
Guardian refusal, unresolved review, access outside scope, shutdown/session
replacement, or human stop/cancel. Exact no-progress rules and default limits
remain open. Recovery preserves source changes and evidence unless cleanup or
rollback is separately authorized.

## Security and authority boundaries

- The factory is orchestration, not a sandbox; a loop repeats timing, not authority.
- Repository text, issues, CI logs, review comments, and web content are untrusted
  and may contain prompt injection.
- Host-owned task state must contain no credentials or private key material.
- Profile credentials remain available only through normal selected-profile behavior.
- Network policy remains launch-scoped and frozen for an active session.
- Guardian and CAF retain separate policies, decisions, effects, transcripts, and journals.
- Fresh review provides context separation, not guaranteed independence or correctness.
- Runtime labels and hashes detect identity mismatch; they do not prove safety.
- No result authorizes commit, finish, push, PR, merge, tag, release, deployment,
  production repair, or next-task selection without separate approval.

## Repository readiness

A read-only assessment reports `ready`, `ready-with-warnings`, or `not-ready`
with evidence about instructions, deterministic bounded checks, managed-worktree
and generated-file behavior, reviewable diffs, external/secret/production
boundaries, absence of an agent Docker-socket requirement, and recovery. It does
not modify, approve, or authorize the repository.

## Future RPC workers and safe outputs

Pi RPC is the preferred later asynchronous-worker substrate; initial v0.11 does
not promise a production daemon. Factory state must therefore remain independent
of Herdr and terminal scraping. Later external writes should use narrow typed
host operations after validating task, attempt, approval, and output, never
unrestricted publication credentials.

## Open design decisions

Before implementing each affected phase, settle:

1. disposable Herdr compatibility evidence and supported wrapper invocation;
2. `factory/` schemas, permissions, locking, snapshots, and archival;
3. task revision, approval, revocation, creation, listing, and identity invalidation;
4. interval, duration, failure, no-progress, provider, token, and cost limits;
5. validation evidence, manifests, fresh review, findings, and remediation;
6. wake-up idempotency, RPC compatibility, safe outputs, status, and diagnostics.

## Initial acceptance direction

Later implementation must demonstrate exact human approval; separation of
external terminal presentation from agent-inaccessible authority; Herdr
compatibility without exposing its socket or bypassing the Pi-Run launcher; and
correct sidecar, lock, session, snapshot, and cleanup behavior while detached.
It must also demonstrate one task/worktree/conversation/runtime/attempt and at
most one loop; no overlapping or replayed wake-ups; paused restart and explicit
resume; deterministic pass/fail/skip evidence; fresh bounded review; fail-closed
invalid state; preserved source/evidence on failure; and no automatic commit,
finish, push, PR, merge, tag, release, deploy, production repair, or next task.
Complete source regression and disposable real-Docker acceptance remain required.

## Deliberate exclusions

The initial design excludes a Pi-Run multiplexer, run registry, retained-exit
system, or Herdr control-socket bridge; a persistent daemon that restarts after
Pi exit, logout, host reboot, or WSL shutdown; cloud scheduling; concurrent
factory tasks; automatic issue/backlog/Plan/Todo/event consumption; multi-repository
orchestration; automatic commits, PRs, merges, releases, deployments, or
production access; automatic profile/credential/runtime/mount/network changes;
model-callable task approval, loop or wake-up creation/enlargement, or
publication; a fifth embedded agent role; and any implicit implementation,
dependency, migration, branch publication, version, or release change.
