# Guard Runtime presentation architecture

## Status and purpose

This document records the implemented presentation boundary for Guard Runtime,
Guardian, and Call a Friend (CAF). The correction was implemented after v0.9.1
on `experiment/call-a-friend` and checkpointed in `12daf89` and `ebada28`. It has
not been versioned, built, installed, pushed, tagged, published, or released by
those commits.

The work corrected an ownership gap found after v0.9.1 while preserving separate
Guardian and CAF policy, journals, decisions, and effects. Each implementation
stage was separately approved and validated.

## Original finding and implemented correction

Before this work, Pi-Run had one custom Pi journal overlay inside
`guardian-agent.ts`. It combined generic dialog interaction with Guardian review
semantics. CAF had no reusable dialog and rendered `/caf-log` through a
multi-line notification, so shared storage did not produce a shared experience.

The implemented structure is now:

```text
docker/extensions/guard/guard-runtime.ts
└── docker/extensions/guard/guard-viewer.ts   private generic viewer

docker/extensions/guardian/guardian-agent.ts Guardian presentation model
docker/extensions/caf/caf-agent.ts           CAF presentation model
```

Only Guard Runtime imports and opens the private viewer. Guardian and CAF supply
bounded rows and details, flush their own pending journal writes, and use the
same search, refresh, navigation, sizing, fallback, and lifecycle mechanics.

The related dependency and control findings were also resolved in separate
stages. Guardian and CAF now import shared evidence machinery from
`guard-evidence.ts`; CAF no longer imports Guardian. Runtime owns shared reviewer
configuration capabilities, while Guardian remains the sole client granted
mutation capability and continues to own the canonical `/guardian-model` and
`/guardian-thinking` commands. CAF retains friend-only model and thinking
commands.

## Architectural boundary

```text
Guard Runtime
├── registered Guardian client
├── registered CAF client
├── reviewer/runtime coordination
├── shared activity and status widget
└── shared presentation service
    └── private generic dialog implementation

Guardian client
├── command policy and enforcement
├── Guardian journal adapter
└── Guardian presentation model

CAF client
├── disclosure and friend behavior
├── CAF journal adapter
└── CAF presentation model

Guard Journal
└── storage, reading, rotation, permissions, and concurrency only
```

### Guard Runtime owns presentation mechanics

Guard Runtime owns at most one active Guard dialog in addition to its persistent
status widget, and owns that dialog's complete mechanical lifecycle:

- opening and closing the Pi custom overlay;
- list and detail panels;
- focus and keyboard handling;
- selection and pagination;
- search input and restoration;
- refresh sequencing;
- tab/section navigation;
- line wrapping, truncation, sizing, and narrow-terminal behavior;
- TUI capability checks and non-TUI fallback;
- cancellation on session replacement, client disposal, and shutdown; and
- preventing simultaneous or stacked Guard dialogs.

A private module such as `guard-viewer.ts` may contain the component code so
`guard-runtime.ts` does not become a monolith. That module is part of the Guard
Runtime implementation: only Guard Runtime imports and instantiates it. Guardian
and CAF must not import it or call `ctx.ui.custom()` themselves.

### Clients own semantic presentation data

A registered client owns what its records mean. It supplies a bounded,
validated presentation model through its Guard Runtime client handle:

- stable row identity;
- display timestamp;
- outcome/state and duration text;
- concise activity label;
- bounded search text;
- named detail sections; and
- bounded detail lines for a selected row and section.

Guardian therefore continues to own command/review grouping and its Summary,
Command, Evidence, and Timeline content. CAF owns operation grouping and its
friend/search Summary and Timeline content. Runtime does not interpret command
authorization, disclosure outcomes, journal event names, or client policy.

Clients may provide local in-process load/detail callbacks because all bundled
extensions are trusted code. These callbacks are presentation-only, are not
serialized into review requests, and cannot access another client's adapter.
Runtime validates every returned snapshot before rendering it.

Clients cannot supply custom components, key handlers, arbitrary ANSI control
sequences, Pi UI objects, or executable rendering callbacks. They provide data;
Runtime provides interaction and rendering.

### Guard Journal remains storage-only

`guard-journal.ts` owns:

- session-owned Guardian and CAF streams with bounded per-file rotation;
- bounded current-workspace reading and deterministic merge order;
- regular-file, ownership, mode, and link checks; and
- session-writer concurrency behavior.

It must not import Pi TUI, create overlays, define navigation, or understand
Guardian/CAF events. A journal snapshot is storage data, not a view model.

### Other UI remains outside this service

The shared presentation service is not a universal UI framework.

- Pi's built-in `select`, `confirm`, and `input` dialogs remain Pi primitives.
- Guardian and CAF menus remain client-owned because their controls have
  different semantics.
- The planning indicator remains owned by Plan Agent.
- Snapshot menus remain owned by Snapshot Agent.
- `guardian_justify` result rendering remains Guardian-owned.
- Host-terminal snapshot, restore, session, and worktree menus remain outside
  Pi's TUI boundary.

Only a stateful interaction genuinely shared by registered Guard clients belongs
in the Guard Runtime presentation service.

## Runtime contract

The exact TypeScript shape is decided during implementation, but registration
must expose an operation equivalent to:

```text
client.openView({
  schemaVersion,
  title,
  initialQuery,
  columns,
  sections,
  fallbackText,
  load(signal) -> bounded snapshot,
  details(rowId, sectionId, signal) -> bounded lines
})
```

The handle establishes client identity; callers do not provide a client ID.
Runtime rejects a request from an inactive or replaced registration.

The contract must bound at least:

- title, labels, cell values, search text, and line lengths;
- rows, sections, detail lines, and total characters;
- refresh duration and cancellation;
- duplicate row/section identifiers; and
- unsupported control characters.

Snapshot and detail validation failures close or withhold the viewer with a
bounded diagnostic. They never change mode, complete a review, release an
action, send a CAF payload, or alter journal storage.

## Lifecycle and concurrency

Guard Runtime owns one viewer controller per Pi process.

- Opening a second viewer never stacks another overlay.
- A refresh uses a fresh client snapshot and preserves selection only when the
  row identity still exists.
- Session-tree changes and shutdown close the active viewer and cancel pending
  presentation loads.
- Client disposal closes a viewer owned by that client.
- Escape and Q close the viewer; Ctrl+C closes the viewer and never aborts Pi.
- Viewer cancellation is separate from Guard-review and CAF-operation signals.
- Widget rendering and viewer rendering cannot authorize or transmit anything.

The client flushes its own pending journal writer before returning an initial or
refreshed snapshot. Runtime does not receive journal paths or writer ownership.

## Privacy and trust

The presentation service is local trusted-extension coordination, not a security
boundary. It still enforces structural bounds so malformed client output cannot
produce an unbounded TUI operation.

Guardian may present its documented private evidence diagnostics. CAF view data
must continue to exclude exact messages, purposes, policies, authorization text,
queries, answers, search results, credentials, workspace content, and private
Guard evidence. Runtime does not combine client snapshots or expose one client's
rows through another client's handle.

Non-TUI fallback reports a bounded client-supplied description or journal
location. It does not dump an arbitrary journal into the transcript.

## Dependency rules

The target dependency direction is:

```text
Guardian ─┐
          ├──> Guard Runtime contract ──> private Guard viewer
CAF ──────┘

Guardian ─┐
          ├──> Guard Journal
CAF ──────┘
```

Forbidden directions are:

- Guard Runtime importing Guardian or CAF;
- one client importing another client's presentation implementation;
- clients importing the private viewer;
- Guard Journal importing presentation code; and
- presentation callbacks entering serialized review requests.

The former CAF-to-Guardian evidence import was removed. Both clients now depend
on the neutral `guard-evidence.ts` layer, which imports neither client nor Guard
Runtime. Focused source-contract tests preserve this dependency direction.

## Implementation sequence

Each stage is independently reviewed, implemented, validated, and stopped:

1. [x] Add the bounded runtime presentation contract and private generic viewer;
   migrate Guardian without changing visible behavior.
2. [x] Add the CAF journal adapter and route `/caf-log` through the same runtime
   viewer while preserving journal privacy. A later storage correction removed
   compatibility reading in favor of session-owned, workspace-viewed journals.
3. [x] Add cross-client presentation contract tests and harmonize log loading,
   refresh, search, bounds, and non-TUI behavior.
4. [x] Extract shared evidence machinery so CAF no longer imports Guardian.
5. [x] Move shared reviewer controls behind Runtime-owned capabilities while
   keeping `/guardian-model` and `/guardian-thinking` canonical.
6. [x] Harmonize role labels and status discovery. `/guardian-status` and
   `/caf-status` are dedicated autocomplete-visible commands; the nested
   `/guardian status` and `/caf status` forms were removed.

The resulting menus keep their semantic ownership. Guardian configures the
shared reviewer; CAF configures only the friend. Both expose read-only status,
and CAF reads reviewer identity and effective thinking through Runtime without
receiving reviewer mutation capability. Search terms supplied to
`/guardian-log` or `/caf-log` remain user input rather than hidden subcommands.

No stage combined this refactor with provider routing, policy, journal schema,
mode semantics, release publication, or unrelated UI frameworks.

Focused offline validation covered the shared presentation contract, runtime
registry and lifecycle, journal bounds, Guardian flow/reviewer/evidence/reference
fixtures, CAF configuration and lifecycle, command registration, privacy fields,
dependency direction, Bash syntax, ShellCheck, and diff hygiene. The Guardian
model fixture definitions passed while live reviewer calls remained explicitly
disabled. No real-provider call, image build, installation, or release validation
is claimed by this architecture checkpoint.

## Acceptance criteria

The implemented presentation correction satisfies these criteria:

- Guardian and CAF use one Runtime-owned overlay implementation;
- no client calls `ctx.ui.custom()` for Guard views;
- only one Guard viewer can exist at a time;
- Guardian's existing log information and controls remain available;
- CAF operations are grouped and browsable without raw lifecycle-line dumping;
- both clients support bounded search and refresh through the same mechanics;
- TUI, non-TUI, narrow-width, cancellation, and refresh failures are tested;
- CAF view data preserves its documented exclusions;
- presentation failure has no effect on authorization, enforcement,
  cancellation, journaling, or external transmission; and
- dependency checks prevent client-to-client presentation imports.
