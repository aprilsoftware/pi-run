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
one status surface, namespaced journal infrastructure, and lifecycle cleanup.
A client owns its trigger, policy, decision meaning, reviewed action, evidence,
configuration, enforcement, and rendering. The runtime returns a decision but
never performs the action. This is trusted-extension coordination, not an
operating-system boundary.

## Ordinary-client requirement

Guardian must register through the same versioned contract offered to CAF. It
must not call private reviewer, logger, status, or dispute functions unavailable
to another trusted client. The contract needs operations equivalent to:

```text
registerClient(...)
review(...)
beginActivity(...)
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
command. Guardian and CAF retain separate views:

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
│   ├── guardian/
│   │   └── runs/
│   │       └── <run-id>.jsonl*
│   └── caf/
│       └── runs/
│           └── <run-id>.jsonl*
└── sessions/
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

### Concurrent writers and retention

The journal hot path has no profile-wide writer lock. Every Pi process gets
a random run ID and is the only writer and rotator of its bounded journal
segments. A resumed session uses a new run ID, so uncertain process overlap
cannot create two writers for one file. Events retain run, process, and session
identities. `/guardian-log` and `/caf-log` validate their own regular files and
merge completed and active segments chronologically, using per-run sequence as
a deterministic tie-breaker.

Profile-wide retention cleanup uses a separate best-effort maintenance lock.
Contention can postpone cleanup but must never block or drop journal writes.
Per-run limits prevent one writer from growing without bound; aggregate usage
may temporarily exceed its retention target until a later cleanup succeeds.
Unsafe ownership, links, unexpected file types, and redirected directories fail
closed. Activity leases and status remain process-local and never coordinate
unrelated Pi-Run sessions through the profile filesystem.

Old shared Guardian logs are non-vital diagnostics and are intentionally not
read or migrated. The per-run layout does not change schema 1 in `profile.json`.

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

## Proposed implementation sequence

Each stage requires a separate approved increment:

1. Define the versioned Guard Runtime/client contract and tests.
2. Extract common mechanics while preserving Guardian behavior.
3. Register Guardian command review as an ordinary client and prove parity.
4. Use namespaced per-run logs without legacy-log migration.
5. Add isolated CAF configuration and conversation without network calls.
6. Add reviewed friend dialogue and `caf_ask_primary`.
7. Add reviewed public-web research functions and bounded citations.
8. Validate the complete lifecycle with internal and friend models.

No stage authorizes the next one, a release, or publication.

## Open questions and acceptance

The experiment must select the smallest public-web tool set, exact budgets, CAF
decision schema, journal excerpt policy, restricted-network integration, useful
real-model scenarios, and whether friend credentials move to a broker.
The design is complete when both features are ordinary clients, one status
surface presents sequential activity, journals remain separate, every external
CAF boundary is explicit, and agent dialogue is bounded without unsupported
security claims.
