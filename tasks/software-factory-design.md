# Bounded software factory

## Status and authority

This document records the initial v0.11 architecture for a bounded Pi-Run
software factory. It selects the first product boundaries and identifies design
questions that must be resolved before implementation. It is not authority to
create tasks, run agents, modify repositories, invoke providers, push branches,
open pull requests, merge, deploy, or publish a release.

The factory coordinates existing Pi-Run capabilities. It does not make Guardian,
CAF, Planning, managed worktrees, runtime identity, or network policy into a
sandbox or correctness guarantee.

## Product outcome

The factory turns one human-selected and explicitly approved task into a
validated, reviewable local worktree and branch:

```text
human task selection
    → exact task approval
    → managed worktree and dedicated conversation
    → bounded implementation and verification
    → fresh-context review
    → visible terminal state and completion report
    → human decision about commit, push, PR, merge, or publication
```

The initial terminal output is deliberately local. Success does not automatically
commit, finish the managed worktree, push, create a pull request, merge, tag,
release, deploy, or select another task.

## Terminology

- **Factory task:** approved intent: repository, base revision, goal, scope,
  acceptance checks, limits, exclusions, and desired local outcome.
- **Factory run:** one execution attempt for one exact approved task revision.
- **Factory phase:** a visible state such as preparing, implementing, verifying,
  reviewing, paused, blocked, failed, completed, or cancelled.
- **Loop:** a bounded scheduler belonging to one run. It may request another
  normal agent turn but does not own task authority.
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

Factory task approvals and run-control state belong to host-owned private state
under a future `<PI_RUN_HOME>/factory/` namespace. It must not be mounted into
normal Pi sessions or writable by acting or review agents.

The exact layout and schema remain open, but the boundary is fixed:

- profiles may be referenced but do not own factory authority;
- session entries may mirror presentation and evidence but are not the sole host
  orchestration record;
- repository files and GitHub issues may provide provenance but cannot approve
  themselves;
- Todo remains a private human prompt queue and never becomes factory intake;
- logs and transcripts are evidence, not authority.

Factory state becomes snapshot-eligible only after restore, machine association,
stale-run, and secret-handling semantics are designed.

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

### Loop ownership

A loop belongs to one factory run, not to a repository, profile, Todo queue, or
unbounded conversation. The initial contract permits one active loop per run.

Creation, resumption, extension, and limit increases are human actions. A model
may only stop its current loop; it cannot create another, broaden the prompt,
extend duration, increase iterations, or transfer the loop to another task.

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

## Run lifecycle

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
runtime, network configuration, approval, and remaining limits.

A terminal state is immutable run history. Retrying creates a new run ID linked
to the same or a newly approved task revision; it does not erase the prior result
or invisibly reset counters.

## Bounded `/loop` contract

The first `/loop` is narrower than Claude Code's full scheduled-task feature:

- a human supplies an explicit fixed interval and prompt;
- interval, iterations, and wall-clock duration are bounded;
- there is no bare maintenance prompt or project-controlled `loop.md`;
- dynamic model-selected cadence is deferred;
- only one active loop exists for a run;
- wake-ups never overlap turns;
- missed wake-ups coalesce to at most one pending iteration;
- there is no catch-up replay;
- status, next wake-up, iteration, limits, and stop reason are visible;
- process or session shutdown pauses the loop;
- restart never resumes effectful work silently;
- each iteration is an ordinary user-message turn subject to normal instructions,
  Guardian review, network policy, and prepared-runtime selection.

Polling is primarily for external waiting such as CI, review, or builds. Factory
continuation should be event/state driven when work is already available.

## Worktree and runtime integration

One run uses one managed worktree and one dedicated conversation. It reuses
existing validation for repository relationships, portable workspace identity,
machine association, dedicated branch/path, ownership and links, Git
administration, launch locking, and stale-lock recovery.

The selected prepared profile image and network mode come from normal Pi-Run
launch behavior. A factory task cannot request an implicit runtime build, profile
migration, credential addition, network expansion, mount, or alternate image.
Changes affecting bound identity pause or invalidate the run.

## Implementation and verification

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

Terminal presentation shows task/run IDs, repository and branch, phase, loop
limits and next wake-up, latest validation/review result, elapsed time, and exact
stop or pause reason. The model receives only phase-relevant context; private host
paths, workspace UUIDs, credentials, unrelated profile state, and other tasks are
not exposed merely for presentation.

## Failure and recovery

The factory fails closed on malformed, linked, permission-unsafe, conflicting,
ambiguous, oversized, or incompatible state. It does not reset invalid state to
make progress.

A run pauses or stops for exhausted limits, repeated validation failure,
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

Readiness requires clear instructions, deterministic bounded checks, managed
worktree compatibility, reviewable diffs, explicit external/secret boundaries,
no agent Docker socket requirement, and recovery. It informs but does not approve.

## Open design decisions

Before implementing the task controller, settle:

1. host schemas, bounds, permissions, locking, atomic writes, snapshots, and archival;
2. task revision, approval, revocation, creation, listing, and command contracts;
3. interval, iteration, duration, failure, no-progress, token, and cost limits;
4. validation evidence, fresh review, findings, and remediation contracts;
5. provider/model freezing, usage accounting, events, polling, and resume recovery;
6. later commit/PR authority, status, transcript entries, journals, and diagnostics.

## Initial acceptance direction

Later implementation must demonstrate exact human approval, agent-inaccessible
host state, one task/worktree/conversation/runtime/loop per run, no overlapping
or replayed turns, paused restart and explicit resume, branch/fork safety,
deterministic pass/fail/skip evidence, fresh bounded review, fail-closed invalid
state, preserved worktree/evidence on failure, and no automatic commit, finish,
push, PR, merge, tag, release, deploy, or next task. Complete source regression
and disposable real-Docker factory acceptance remain required.

## Deliberate exclusions

The initial design excludes background operation after Pi exits, a host daemon,
cloud scheduling, concurrent factory tasks, automatic issue/backlog consumption,
Todo submission, multi-repository orchestration, automatic commits or PRs,
merge/release/deployment/production access, automatic profile/credential/runtime/
mount/network changes, a model-callable capability to create or enlarge loops, a
fifth embedded agent role, and any implicit implementation, migration, dependency,
branch publication, or version change.
