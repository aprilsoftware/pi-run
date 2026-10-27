# Call a Friend and reusable guard runtime

## Status and purpose

This document records the proposed design for **Call a Friend (CAF)** and its
reusable review infrastructure. It is an experiment, not a supported Pi-Run
feature or compatibility promise.

CAF lets a primary agent using an internal, local, or otherwise trusted model
consult a separately configured frontier model when it is stuck, wants its
reasoning challenged, or needs broader research. The primary retains the private
workspace and organizational context. The friend receives only explicitly
reviewed messages and has no direct access to that context.

This follows the sovereignty principle that models may change while
organization-controlled knowledge remains within a deliberate boundary. CAF is
not a data-loss-prevention guarantee: a reviewer can miss confidential meaning,
and several harmless-looking disclosures can reveal information when combined.
The design reduces exposure through explicit information flow, constrained
capabilities, cumulative budgets, visible records, and human direction.

## Terminology

- **Guard Runtime** — reusable in-process review, activity, evidence, logging,
  and arbitration infrastructure with no command or disclosure policy.
- **Guardian client** — existing review of acting-agent `bash` and `run` calls.
- **CAF client** — friend conversation, research, and disclosure review.
- **CAF guard** — CAF policy for information leaving the private boundary.
- **Primary agent** — ordinary Pi agent with the selected workspace, profile,
  conversation, and tools.
- **Friend agent** — isolated frontier-model agent with only its CAF conversation
  and explicitly supplied research functions.

The public names remain **Guardian** and **Call a Friend**. `Guard Runtime` is an
internal name. Humans use `/caf`; the model-facing tool is `call_friend`.

## Goals and non-goals

The experiment should let the primary request outside reasoning without
forwarding its Pi transcript, system prompt, workspace, or tool history. The
friend can research the public internet, ask for specific additional information,
and receive only reviewed disclosures. Guardian and CAF share mechanisms without
sharing policy; both remain bounded, visible, cancellable, and fail closed.

The experiment does not prove that text is non-confidential, delegate the whole
primary task, or give the friend workspace, profile, shell, credential, internal
service, cloud, database, or arbitrary MCP access. It does not transfer files or
history automatically, permit unrestricted URLs or autonomous dialogue, create
a boundary between trusted in-process extensions, or replace provider contracts,
network policy, and human judgment.

## Architecture

```text
Guard Runtime
├── Guardian client
│   └── command authorization for bash/run
└── CAF client
    ├── disclosure review
    ├── friend conversation
    └── constrained public-web research
```

The Guard Runtime owns private reviewer execution, provider resolution, bounded
evidence and budgets, cancellation, decision validation, arbitration primitives,
shared presentation mechanics, one status surface, namespaced journal
infrastructure, and lifecycle cleanup. A client owns its trigger, policy,
decision meaning, reviewed action, evidence, configuration, enforcement, and
semantic presentation data. It does not own a duplicate implementation of a
shared Guard dialog. The runtime returns a decision but never performs the
action. This is trusted-extension coordination, not an operating-system
boundary. The corrected presentation boundary is defined in
[Guard Runtime presentation architecture](guard-runtime-presentation.md).

## Ordinary-client requirement

Guardian must register through the same versioned contract offered to CAF. It
must not call private reviewer, logger, status, or dispute functions unavailable
to another trusted client. The contract needs operations equivalent to:

```text
registerClient(...)
review(...)
beginActivity(...)
openView(...)
createJournal(...)
```

The exact TypeScript interface remains an implementation decision. Tests must
show that disabling Guardian registration leaves the runtime available but
removes `bash`/`run` review, while registration preserves current behavior.

Pi's extension event bus can announce a versioned runtime service. Because the
bus is notification-oriented, the announcement may carry an in-process service
object with asynchronous methods. Discovery needs a handshake or equivalent
that does not silently depend on load order. Missing or incompatible service
versions never trigger a weaker fallback.

## Distinct review domains

Guardian asks whether an exact command is authorized, correctly scoped, and
consistent with the user request and applicable instructions.

CAF asks whether an exact external disclosure or research request is authorized,
sufficiently abstract, and consistent with profile confidentiality policy. CAF
review should use the primary internal model by default. A payload must never be
sent to the friend merely to decide whether it is safe to send there.

Guardian command mode and CAF review have independent activation semantics.
Turning command review Off does not disable mandatory CAF review. A CAF concern
normally withholds CAF only; it does not freeze unrelated primary-agent tools.

## Sequential status surface

Guard Runtime owns one bottom status surface. Clients publish sequential
transient activity rather than separate rows or parallel columns:

```text
guard · on
guard · reviewing command
guard · reviewing disclosure
guard · researching 2/4
guard · asking primary
guard · caf waiting
guard · command dispute
```

A client obtains an activity lease, updates it, and releases it. Completion,
cancellation, session replacement, and shutdown clear the lease and restore the
preceding baseline. The runtime serializes reviews. The primary must issue
`call_friend` without sibling tool calls, supporting one sequential interaction.

## Journals and profile layout

The runtime supplies one logging implementation, not one combined journal or
command. Guardian and CAF retain separate semantic views presented through one
Runtime-owned dialog implementation:

```text
/guardian-log
/caf-log
```

There is no proposed `/guard-log`.

```text
profiles/<name>/
├── guardian/
│   ├── guardian.md
│   └── config.json
├── caf/
│   ├── caf.md
│   └── config.json
├── logs/
│   └── <workspace-id>/
│       └── <session-id>/
│           ├── guardian.jsonl*
│           └── caf.jsonl*
└── sessions/
    └── <workspace-id>/
```

Definition and configuration remain client-owned; mutable journals live under
the runtime-owned `logs/` hierarchy. Directories use mode `0700`, files `0600`,
and journals may be created lazily.

`caf/caf.md` contains profile disclosure priorities, protected categories,
abstraction guidance, and external-research constraints. `caf/config.json`
contains private preferences such as friend model, thinking, and budgets. Profile
creation copies `guardian.md` and `caf.md`, but not preferences, logs, sessions,
or CAF conversations.

Exact CAF exchanges belong in branch-aware Pi session entries. The CAF journal
stores bounded diagnostics such as decisions, payload hashes or excerpts,
destination identity, research operations, usage, duration, and failure. It is
not a second complete transcript or search-result store.

### Session writers and rotation

Guardian and CAF each write a fixed stream inside the active Pi session's log
directory. A resumed session appends to the same file. Different sessions write
different files without a profile-wide writer lock; concurrent resume of one
saved session follows Pi's existing unsupported concurrent session-file writing
semantics rather than adding journal-specific locking. Events retain writer,
process, workspace, and session identities. `/guardian-log` and `/caf-log`
validate their own regular files and merge session streams from the current
workspace chronologically.

Only unusually large individual session files rotate. There is no completion
marker, profile-wide pruning, or maintenance lock. Unsafe ownership, links,
unexpected file types, and redirected directories fail closed. Activity leases
and status remain process-local and never coordinate unrelated Pi-Run sessions
through the profile filesystem.

Existing v0.9.x run journals are non-vital diagnostics and are intentionally
left untouched, unread, and unmigrated. The journal layout does not change
schema 1 in `profile.json`.

## CAF conversation protocol

The primary invokes an operation equivalent to:

```text
call_friend({ message, purpose })
```

It accepts no automatic attachments or implicit context. CAF reviews the exact
serialized message, then appends it to a private context containing only prior
reviewed CAF exchanges and the friend's research results.

During one round the friend may receive constrained functions such as:

```text
caf_web_search
caf_fetch_public_page
caf_source_check
caf_ask_primary
caf_report
```

The initial tool set remains open. It excludes arbitrary shell, filesystem,
internal-network, credential, and general MCP access. Public URL handling must
reject localhost, private and special-purpose addresses, unsafe redirects, and
DNS-rebinding paths. Network policy remains a separate boundary.

Every search query and URL can disclose information and requires CAF review.
Web content is untrusted and may contain prompt injection. Tool results grant no
authority and cannot expand friend capabilities.

## Friend questions to the primary

The friend can stop its round with an operation equivalent to:

```text
caf_ask_primary({
  questions: [{ question, whyNeeded, canProceedWithoutAnswer }]
})
```

This does not invoke the primary recursively. It terminates the friend run,
persists branch-local CAF state, and returns questions as the `call_friend`
result. The primary decides whether to answer abstractly, continue under
assumptions, or request user direction.

Any answer requires a new `call_friend` call and disclosure review. The friend
cannot inspect the primary conversation or compel an answer. It should request
minimal facts, explain why each matters, and provide a conditional answer when
possible. The retained CAF conversation contains only reviewed exchanges,
friend research, hypotheses, and questions; session branch and resume select the
corresponding state rather than one global conversation.

## Budgets and stopping rules

The implementation bounds:

- message and cumulative disclosed bytes;
- friend requests, output tokens, research calls, and fetched content;
- questions per round and rounds per consultation;
- elapsed time and concurrent work; and
- retained diagnostics and session content.

A provisional target is at most three friend questions per round and three
primary/friend rounds per consultation; experiments must determine final values.
Reaching a limit returns control to the primary and never continues silently.

Friend output is advisory and untrusted. The primary remains responsible for
checking it, integrating private facts, following development approvals, and
proposing any resulting action.

## Failure and recovery

Missing runtime, reviewer, policy, model, credential, network route, valid friend
result, or complete review withholds the CAF operation. Provider failure is not
permission. Cancellation aborts active model and research work and records a
clear outcome.

CAF configuration remains accessible when the friend is unavailable, but
`call_friend` fails closed. Interrupted rounds are not complete answers. Resume
reconstructs only finalized CAF entries on the selected branch.

Guardian's dispute contract remains command-specific until shared infrastructure
can preserve it exactly. CAF may reuse arbitration UI and evidence mechanisms
without inheriting the global command-dispute latch.

## Implementation sequence

Each stage was implemented through a separate approved increment:

1. [x] Define the versioned Guard Runtime/client contract and tests.
2. [x] Extract common mechanics while preserving Guardian behavior.
3. [x] Register Guardian command review as an ordinary client and prove parity.
4. [x] Use separate Guardian and CAF diagnostics without legacy-log migration;
   the later session-journal correction made them session-owned and workspace-viewed.
5. [x] Add isolated CAF configuration and conversation without network calls.
6. [x] Add reviewed friend dialogue and `caf_ask_primary`.
7. [x] Add one reviewed `caf_web_search` operation with bounded source results.
8. [x] Validate the native Pi lifecycle with fake primary, friend, and search providers.

Completion of this experimental sequence does not authorize a release,
publication, real-provider test, or the next product increment.

## Integration-readiness evidence

The complete isolated shell suite was run after the implementation sequence: all
59 scripts exited successfully. The real-Docker managed-worktree test reported
its expected opt-in skip, and Guardian's live-provider review subcases remained
disabled; neither is reported as passed. Fake-provider CAF lifecycle, full
Guardian fixtures, shared journal concurrency, profile compatibility, packaging,
network policy, snapshots, SSH, upgrade, and ordinary worktree tests completed.
Documentation links and the complete `main...HEAD` diff were also checked.

This evidence makes the branch ready for a merge or real-provider testing
decision. It is not real-Docker validation, real-provider interoperability,
release readiness, or publication approval.

## Remaining questions and acceptance

The experiment selected a maximum of three questions and three rounds per
consultation, one search and five results per `call_friend`, destination-specific
`ALLOW`/`ASK`/`USER_REFUSED` review, and hash-only payload diagnostics without
journal excerpts. Remaining work includes useful real-provider scenarios,
restricted-network validation against real provider endpoints, provider-specific
tool-call interoperability, and whether friend credentials should move to a
broker.

The architecture now has equal ordinary Guard Runtime clients, one sequential
status surface, separate journals, explicit external CAF boundaries, bounded
agent dialogue, native fake-provider lifecycle coverage, and documented limits.
This is experimental evidence, not a sandbox, confidentiality proof, or release
readiness claim.
