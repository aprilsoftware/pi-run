# Call a Friend and reusable guard runtime

## Status and purpose

This document records the design evolution and implemented v0.9 line for **Call
a Friend (CAF)** and its reusable review infrastructure. The current behavior is
documented in the user guides; this historical task record is not a compatibility
promise or release authorization.

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
evidence and budgets, cancellation, reviewer routing, shared presentation
mechanics, one two-row status widget, and lifecycle cleanup. Shared Guard modules
provide journal and neutral evidence mechanics. A client owns its trigger,
policy, domain decision validation, reviewed action, configuration, enforcement,
journal semantics, and presentation data. It does not own a duplicate
implementation of a shared Guard dialog. The runtime returns a decision but never performs the
action. This is trusted-extension coordination, not an operating-system
boundary. The corrected presentation boundary is defined in
[Guard Runtime presentation architecture](guard-runtime-presentation.md).

## Ordinary-client requirement

Guardian must register through the same versioned contract offered to CAF. It
must not call private reviewer, logger, status, or dispute functions unavailable
to another trusted client. The implemented versioned contracts provide
registration, review routing, activity leases, reviewer controls, and bounded
view opening. Journal writers
remain a shared storage module rather than a Runtime authorization service.
Tests show that disabling Guardian registration leaves the runtime available but
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
sufficiently abstract, and consistent with profile confidentiality policy. One
explicitly configured Guard reviewer serves both domains while preserving their
separate policies, decisions, effects, and journals. A payload is never sent to
the friend merely to decide whether it is safe to send there.

Guardian's session mode is the shared Guard review mode. Guard On reviews both
Guardian commands and enabled CAF friend/search disclosures. Guard Off skips
command review and lets enabled CAF send its bounded actions without an
independent reviewer. Unknown Guard state sends nothing. A CAF concern withholds
CAF only; it does not open Guardian's command-dispute latch.

## Shared status surface

Guard Runtime owns one two-row widget. The Guard row shows the shared reviewer,
mode, command review, CAF disclosure review, and dispute state. The CAF row shows
CAF mode, friend model, friend activity, and search activity:

```text
guard · on                                     reviewer-model · low
caf · asking friend                            friend-model · high
```

A client obtains an activity lease, updates it, and releases it. Completion,
cancellation, session replacement, and shutdown clear the lease and restore the
client baselines. The runtime serializes reviews and CAF activity. The primary
must issue `call_friend` without sibling tool calls, supporting one sequential
interaction.

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
├── guard/
│   └── config.json
├── guardian/
│   ├── guardian.md
│   └── mode.json
├── caf/
│   ├── caf.md
│   ├── config.json
│   └── mode.json
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
contains private friend-model and thinking preferences, while `caf/mode.json`
stores the new-session default. Profile creation copies `guardian.md` and
`caf.md`, but not preferences, logs, sessions, or CAF conversations.

Exact CAF exchanges belong in branch-aware Pi session entries. The CAF journal
stores bounded diagnostics such as decisions, payload hashes and sizes,
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
serialized message, then starts a fresh native Pi `Agent` with a private
transcript containing only that message, bounded prior reviewed CAF exchanges,
and any research returned through the agent's restricted tools.

During one round the friend may receive `caf_ask_primary` and, when one explicit
canonical search provider is configured, one `caf_web_search` call. CAF invokes
the canonical `web_search` tool with one query, at most five results, no fetched
page content, no curator, and no proxy override. It removes all friend tools
before the final response.

The friend receives no arbitrary shell, filesystem, internal-network,
credential, page-fetching, source-check, or general MCP access. Every search
query can disclose information and receives destination-specific Guard review
while Guard is On. Public results are untrusted, grant no authority, and cannot
expand friend capabilities. Network policy remains a separate boundary.

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
- provider requests and concurrent work; and
- retained diagnostics and session content.

The implemented limits allow at most three friend questions per round, three
primary/friend rounds per consultation, and one search per `call_friend`.
Reaching a limit returns control to the primary and never continues silently.

Friend output is advisory and untrusted. The primary remains responsible for
checking it, integrating private facts, following development approvals, and
proposing any resulting action.

## Failure and recovery

Missing runtime, policy, model, credential, network route, valid friend result,
or known Guard mode withholds the CAF operation. Guard On additionally requires
a configured reviewer and complete `ALLOW`; Guard Off deliberately uses the
bounded direct path without a reviewer. Provider failure is not permission.
Cancellation aborts active model and research work and records a clear outcome.

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
9. [x] Replace the timed nested friend-completion workflow with a bounded native
   Pi Agent whose reviewed search continues in the same private transcript.

Completion of this experimental sequence does not authorize a release,
publication, real-provider test, or the next product increment.

## Integration-readiness evidence

At the initial integration checkpoint, the complete isolated shell suite ran 59
scripts successfully. The real-Docker managed-worktree test reported its
expected opt-in skip, and Guardian's live-provider review subcases remained
disabled; neither was reported as passed at that checkpoint. Fake-provider CAF
lifecycle, full Guardian fixtures, shared journal concurrency, profile
compatibility, packaging,
network policy, snapshots, SSH, upgrade, and ordinary worktree tests completed.
Documentation links and the complete `main...HEAD` diff were also checked.

That evidence made the branch ready for a merge or real-provider testing
decision; it was not itself real-Docker validation, real-provider
interoperability, release readiness, or publication approval.

Later v0.9.3 candidate validation ran 61 offline harnesses with 58 passes and
three explicit optional skips, built and smoke-tested local runtime and egress
images, passed the real-Docker managed-worktree E2E test, completed one guarded
CAF consultation, and passed four representative live Guardian decisions. These
bounded checks still do not prove provider confidentiality, broad provider
interoperability, or release publication.

## Remaining questions and acceptance

The experiment selected a maximum of three questions and three rounds per
consultation, one search and five results per `call_friend`, destination-specific
`ALLOW`/`ASK`/`USER_REFUSED` review, and hash-only payload diagnostics without
journal excerpts. Remaining work includes broader real-provider scenarios,
restricted-network validation against real provider endpoints, provider-specific
tool-call
interoperability, and whether friend credentials should move to a broker.

The architecture now has equal ordinary Guard Runtime clients, one shared
two-row status widget, separate journals, explicit external CAF boundaries, a
native bounded friend-agent loop, native fake-provider lifecycle coverage, and
documented limits.
This is experimental evidence, not a sandbox, confidentiality proof, or release
readiness claim.
