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

## Recommended order

1. Todo extension.
2. Stronger planning-state visibility.
3. Repository-linked Plan design.
4. Managed-worktree missing-directory recovery assurance.
5. Guardian, CAF, and cache-policy regression assurance.
6. Profile-specific runtime-image design.

The order may change when user evidence identifies a more valuable or urgent
problem. Reliability work can also be selected independently of feature order.

## Product features

### 1. Todo extension

**User-visible goal:** maintain a small actionable list that survives session
resume and remains correctly scoped when conversation branches diverge.

**Current recommendation:** store todos as branch-local session entries by
default. Workspace files should be an explicit durability/export choice rather
than an automatic side effect. Todo state must remain distinct from
[Plan](../docs/planning.md) drafts and approvals: a todo is work tracking, not
planning authority or implementation approval.

**Open decisions:**

- command and tool surface for adding, listing, completing, reopening, and
  removing items;
- stable item identity and ordering;
- branch inheritance and divergence behavior;
- whether completed items remain visible by default;
- optional export or workspace-backed mode; and
- compact TUI rendering without prompt or transcript noise.

**Smallest likely first increment:** define and test a branch-local session schema
with one minimal add/list workflow and no workspace writes.

**Validation expectations:** resume persistence, branch isolation, malformed
entry handling, bounded storage, deterministic ordering, and no effect on Plan
approval state.

### 2. Stronger planning-state visibility

**User-visible goal:** make it difficult to forget that a conversation is still
in planning mode, especially after resume, branch navigation, or a custom-message
turn.

**Current state:** Plan mode, drafts, and approval identity are durable session
entries, and planning already owns a terminal status/widget. The system-prompt
section is restored for user- and custom-message turns, but the visible reminder
can still be missed.

**Current recommendation:** add one restrained terminal-native reminder rather
than bells, desktop notifications, repeated chat messages, or broad prompt
changes. Preserve the exact session-entry authority described in the
[planning reference](../docs/reference/planning.md).

**Open decisions:** reminder surface, timing, behavior outside TUI mode, and how
to avoid competing with Guardian, CAF, title, or normal status presentation.

**Smallest likely first increment:** choose one observable planning-state surface
and test it across startup, resume, tree navigation, custom-message turns, and
exit.

### 3. Repository-linked Plan behavior

**User-visible goal:** optionally discover that a repository already has relevant
planning work without confusing repository metadata with session approval.

**Current recommendation:** keep branch-local session entries authoritative. Any
repository link should be an index or reference to planning context, never a
portable proof of approval and never an automatic instruction to execute work.

**Open decisions:** repository identity, worktree behavior, stale or missing
sessions, multiple competing plans, privacy of plan titles, snapshot behavior,
and whether linking is explicit or automatic.

**Smallest likely first increment:** produce a design record comparing no link,
an explicit repository index, and a workspace document reference. Do not write
repository metadata until one lifecycle is selected.

### 4. Profile-specific runtime images

**User-visible goal:** allow a profile to select an additional or specialized
toolchain without making every Pi-Run image larger.

**Current recommendation:** defer implementation until at least one repeated
profile need justifies the lifecycle cost. Preserve immutable image versions and
keep the runtime and restricted-egress version relationship explicit.

**Open decisions:** image naming and trust, profile schema, installation and
upgrade behavior, offline availability, doctor diagnostics, release ownership,
and compatibility with snapshots and managed worktrees.

**Smallest likely first increment:** document concrete use cases and compare a
small set of immutable selection models; no profile schema change.

## Reliability and assurance improvements

### 5. Managed-worktree missing-directory recovery

Managed worktree listing can identify missing checkout state, but a dedicated
end-to-end recovery acceptance remains outstanding. The first increment should
be a disposable test that removes only its own managed checkout and verifies the
existing refusal or recovery contract before proposing behavior changes. See
[Workspaces and sessions](../docs/workspaces-and-sessions.md).

### 6. Guardian and CAF live regression coverage

Offline and deterministic tests cover reviewer protocols, lifecycle, budgets,
and fail-closed behavior. Optional live-review tests remain useful after major Pi
or provider changes, but they disclose fictional test actions and consume
provider capacity. Run them only as a separately authorized assurance operation,
with Guardian and CAF results reported independently. See
[Guardian](../docs/guardian.md) and [Call a Friend](../docs/call-a-friend.md).

### 7. Cache-policy runtime assurance

Pi-Run preserves active-run-only cache warming when `cacheWarming` is unset and
does not rewrite profile settings. Unit, extension-load, and real-runtime checks
cover that policy boundary. A future deterministic timed test could prove that
an idle refresh is stopped before provider execution while an active refresh is
unchanged, without using a paid provider.

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
