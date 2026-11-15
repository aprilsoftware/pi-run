# Next features and improvements

## Status and use

This is the active forward-looking product roadmap for Pi-Run. It records likely
priorities, open decisions, and useful first increments after the current stable
baseline. It is not an approved implementation plan, backlog authorization, or
permission to begin the next item automatically.

Each development item still follows the repository workflow: investigate,
propose one concrete increment, wait for approval, implement only that increment,
validate it, and stop. Operational checks and profile changes also require their
own explicit scope.

## Prioritization principles

Prefer work that improves everyday continuity and makes agent state visible
without weakening existing boundaries. Keep durable authority explicit, preserve
immutable runtime identities, and avoid adding storage or image variants before
their lifecycle is understood. New presentation should remain terminal-native
and non-disruptive.

## Current release state

The profile-owned runtime Dockerfile foundation and the intentional Docker build
warning suppression were released as immutable v0.10.13. The active development
line is now local branch `experiment/v0.11`; branch publication, implementation,
preview metadata, and release work remain separate decisions requiring approval.

## Active product direction

### Bounded software factory

v0.11 develops a bounded, visible software factory that turns one exact
human-approved task into a validated, reviewable local worktree and branch.
`/loop` is one scheduling primitive inside the factory, not backlog authority or
a substitute for task approval, deterministic verification, fresh-context
review, or human publication decisions.

The first architecture selects host-owned task/run state outside normal agent
mounts, exact task-hash approval, one managed worktree and conversation per run,
one human-created loop, paused restart behavior, and no automatic commit, push,
PR, merge, release, deployment, or next-task selection. See the
[bounded software factory design](software-factory-design.md) for the lifecycle,
authority boundaries, selected initial output, open design decisions, and
acceptance direction.

## Delivered foundation

### Profile-owned runtime Dockerfiles

Each profile owns a fixed `runtime/Dockerfile`, with `runtime/` as its complete
Docker build context. Pi-Run provides a small immutable core image, visible
Dockerfile fragments through `runtime list` and `runtime add`, and an `all` group
that generates the maintained broad capability set. Users can edit the
Dockerfile directly or add custom fragments, then explicitly build and reuse the
matching local image.

There is no separate profile bundle manifest, hidden fallback image, or
automatic host build. The Dockerfile is generated once and remains user-owned.
Fresh and copied profiles carry the runtime definition; legacy profiles use
explicit `runtime init`. Normal, resumed, restricted, snapshot-restarted, and
managed-worktree launches require a matching prepared profile image.

The isolated source suite passes with 68 tests and seven opt-in skips. Actual
Linux/amd64 Docker acceptance passed for the core and `runtime add all`
full-development image, mapped startup and Java CA initialization, real launcher
selection, managed-worktree lifecycle, and production restricted-egress rules.
The remaining four non-Docker skips require optional live-provider calls and are
not runtime acceptance failures.

See the [profile runtime Dockerfile design](profile-runtime-dockerfile-design.md)
for the command contract, current-image inventory, trust boundary, acceptance
evidence, and remaining optional design questions.

### Todo prompt queue

Todo is implemented in the current source tree as a user-owned queue of future
prompts for one Pi conversation. `/todo` opens the interactive menu for creating,
editing, deleting, reordering, and loading items into Pi's normal editor. Loading
never submits a prompt, and items remain queued until explicitly deleted.

State is keyed by session ID under private profile storage. It survives resume
and is shared across `/tree` branches; genuinely new sessions, forks, and clones
start empty. Stable item IDs preserve identity across edits and reordering. The
extension registers no model-callable Todo tool and performs no automatic prompt
or transcript injection. Todo content is still selected-profile data rather than
a filesystem confidentiality boundary.

The implementation limits each session to 100 items and each item to 16 KiB,
uses private atomic state writes, and fails closed on malformed or unsafe state.
Todo remains separate from Plan drafts, Plan approval identity, roadmaps,
backlogs, and execution authority. See the [Todo guide](../docs/todo.md) and
[behavior reference](../docs/reference/todo.md).

This source work has not changed release metadata or published images. Further
Todo behavior should require new user evidence rather than treating the former
open design questions as an active backlog.

### Model-readable saved Plans

The current source tree provides the model-only, read-only `plan_read` tool. It
is available during planning and remains available after approval while the
current branch retains a saved draft. It returns the exact revision ID, SHA-256
identity, title, goal, body, and approval state without mutating session state or
starting another model turn.

Resume and branch navigation restore the correct branch-local availability. New
revisions fail closed as unapproved until that exact identity is approved, while
`/plan-exit` discards the active draft and removes read access. Reading a Plan
does not approve, export, execute, or grant authority. See the
[Planning guide](../docs/planning.md) and
[behavior reference](../docs/reference/planning.md).

### Missing managed-worktree directory assurance

The deterministic managed-worktree lifecycle test now removes its own disposable
checkout and verifies the existing fail-closed contract. Listing reports the
active task as `missing`, opening refuses before Docker starts, and Pi-Run does
not silently recreate, repair, finish, or unregister the task. Machine and
portable metadata, session data, Git administration, and the task branch remain
preserved for explicit recovery.

No automatic recovery behavior was added. Further recovery work should require
a concrete user need and a separately selected lifecycle rather than treating a
missing checkout as authority to mutate or discard task state.

### Cache-policy runtime assurance

The deterministic cache-policy test now exercises Pi 1.5.2's actual cache-warmer
scheduling and provider-dispatch path with controlled timers and a fake provider.
With no explicit idle opt-in, an idle refresh is stopped by the extension before
provider execution or usage persistence. The same warming decision during an
active run reaches the fake provider unchanged and reschedules normally.

This assurance uses no network access, credentials, paid provider, or wall-clock
wait and does not rewrite profile settings. Live-provider cache checks are not an
active roadmap item.

### Guardian and CAF live regression assurance

A bounded Guardian action-review regression passed representative `ALLOW`,
`ASK`, and `USER_REFUSED` cases with one reviewer request each and unchanged
settings. A guarded CAF candidate initially exposed Pi 1.5.2's optional
`usage.cost.totalFromProvider` field; CAF now validates and aggregates that field,
and its deterministic configuration, agent-loop, dialogue, and lifecycle suites
pass.

The explicitly authorized guarded CAF retry completed with one reviewer request,
one friend request, no other model or search requests, no command execution, and
no real-profile writes. Future live checks remain optional assurance operations:
they disclose fictional test content, consume provider capacity, and require
separate authorization. See [Guardian](../docs/guardian.md) and
[Call a Friend](../docs/call-a-friend.md).

## Deferred ideas

### Stronger planning-state visibility

Planning already has a muted terminal widget, durable branch-local mode state,
and restored system-prompt guidance. The recent user requirement concerned model
access to the saved Plan and is addressed by `plan_read`; a stronger visual
banner is therefore not an active priority.

Revisit presentation only with new user evidence. Any future reminder should
remain terminal-native and avoid bells, desktop notifications, repeated chat
messages, broad prompt changes, or competition with Guardian, CAF, Todo, title,
and normal status presentation.

## Operational follow-up

Retired provider models are profile-owned configuration, not repository roadmap
implementation. Removing a retired model should be a separate bounded profile
operation that first identifies the exact provider entry without printing its
credentials. In particular, the retired Mistral configuration should not remain
a target for future acceptance tests.

Snapshot configuration and repository integrity have been checked successfully.
Pruning unused snapshot repository data is not part of this roadmap and would
require a separate state-changing maintenance decision.

## Selection checklist

Before choosing a roadmap item, confirm:

- the user-visible problem and one observable result;
- authoritative storage and lifecycle boundaries;
- files, dependencies, migrations, and external effects;
- security and privacy implications;
- validation that can distinguish a pass from a skip; and
- important exclusions that keep the increment small.

For general authority and isolation boundaries, see
[Profiles](../docs/profiles.md) and [Security](../docs/security.md).
