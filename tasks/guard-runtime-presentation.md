# Guard Runtime presentation architecture

## Status and purpose

This document defines the presentation boundary for Guard Runtime, Guardian, and
Call a Friend (CAF). It corrects an ownership gap found after v0.9.1: Guardian
contains a complete custom journal-browser overlay, while CAF renders its journal
as a multi-line notification. Shared storage did not produce a shared user
experience because the reusable dialog mechanics remained inside one client.

This is an architecture decision, not implementation or release authorization.
Each implementation stage requires separate approval.

## Current finding

Pi-Run currently has one custom Pi overlay:

```text
docker/extensions/guardian-agent.ts
└── GuardianLogViewer / openGuardianLogViewer
```

It predates Guard Runtime and combines two kinds of responsibility:

- generic interaction: overlay lifecycle, framing, focus, selection, search,
  refresh, tabs, scrolling, keyboard handling, sizing, and close behavior;
- Guardian semantics: review grouping, decision labels, command columns, and
  Summary, Command, Evidence, and Timeline content.

Guard Runtime later became the owner of the shared two-row status widget, but the
journal browser was not migrated. CAF consequently had no reusable dialog and
implemented `/caf-log` by sending formatted journal lines through a notification.
Independent tests then preserved both behaviors.

The same review also found a separate dependency inversion: CAF imports shared
evidence types and implementations from `guardian-agent.ts`. Shared Guard
reviewer controls also remain implemented in Guardian even though their model
and thinking configuration serves both clients. Those problems are related
follow-up work; they must not be hidden inside the viewer extraction.

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
└── storage, reading, retention, permissions, and concurrency only
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

- per-run writing and completion markers;
- bounded reading and deterministic merge order;
- retention and maintenance locking;
- regular-file, ownership, mode, and link checks; and
- concurrency behavior.

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
action, send a CAF payload, or alter journal retention.

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

CAF's current import of shared evidence machinery from Guardian violates the
intended dependency direction and must be removed in a later, separately scoped
extraction into the shared reviewer layer.

## Implementation sequence

Each stage is independently reviewed, implemented, validated, and stopped:

1. Add the bounded runtime presentation contract and private generic viewer;
   migrate Guardian without changing visible behavior.
2. Add the CAF journal adapter and route `/caf-log` through the same runtime
   viewer; retain old journal compatibility and privacy.
3. Add cross-client presentation contract tests and harmonize log loading,
   refresh, search, bounds, and non-TUI behavior.
4. Extract shared evidence machinery so CAF no longer imports Guardian.
5. Move shared reviewer controls behind Runtime-owned capabilities while keeping
   public Guardian command compatibility.
6. Audit and separately harmonize remaining menu, alias, selector, and status
   presentation differences.

No stage may combine this refactor with provider routing, policy, journal schema,
mode semantics, release publication, or unrelated UI frameworks.

## Acceptance criteria

The presentation correction is complete only when:

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
