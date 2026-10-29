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

- **Guard Runtime** — reusable in-process infrastructure for reviewer model
  selection, routing, activity, presentation, cancellation, and shared bounded
  mechanics. It is not an agent and owns no command or disclosure policy.
- **Primary agent** — ordinary Pi agent with the selected workspace, profile,
  conversation, and tools.
- **Guardian agent** — the separate native reviewing agent used by the Guardian
  client for protected primary-agent commands and actions.
- **CAF reviewer agent** — the separate native reviewing agent used by the CAF
  client for exact outbound disclosures and reviewed CAF research operations.
- **CAF agent** — the isolated external advisory agent historically called the
  friend agent. It has only its private CAF conversation and explicitly supplied
  advisory tools.
- **Guardian client** — deterministic integration that submits Guardian actions
  to its reviewing agent through Guard Runtime and enforces Guardian decisions.
- **CAF client** — deterministic orchestration that submits disclosures to the
  CAF reviewer agent through Guard Runtime and releases exact allowed actions to
  the CAF agent.
- **CAF guard** — CAF-specific policy for information leaving the private
  boundary.

The public names remain **Guardian** and **Call a Friend**. `Guard Runtime` is an
internal name. Humans use `/caf`; the model-facing tool is `call_friend`. A
shared reviewer model selection may serve Guardian and CAF review, but every
review uses a separate agent instance, private transcript, role prompt, policy,
tool set, decision contract, and journal semantics.

## Multi-agent architecture contract

Pi-Run preserves four distinct agent roles:

1. The **primary agent** performs the user's task and proposes protected actions
   or CAF consultations.
2. The **Guardian agent** reviews protected commands and actions under Guardian
   policy using its own evidence tools and agent loop.
3. The **CAF reviewer agent** reviews each exact primary-to-CAF disclosure under
   CAF policy using its own evidence tools and agent loop.
4. The **CAF agent** independently advises the primary from only the information
   and tools explicitly released to it.

Guardian and the CAF reviewer are sibling clients of Guard Runtime. They share
infrastructure, reviewer configuration, generic activity, cancellation, and
bounded mechanics. They do not share policy, evidence transcripts, decisions,
effects, journals, or presentation semantics, and they have no direct dependency
on each other. Guard Runtime routes and presents reviews; it never becomes the
reviewing agent and never performs a reviewed action.

Cross-agent communication follows deterministic contracts without replacing
agentic reasoning:

1. The primary proposes an exact action or CAF disclosure.
2. The responsible reviewing agent may investigate with its permitted bounded
   session, workspace, file, resource, policy, and instruction evidence tools.
3. The reviewer returns its domain-specific structured decision. Only an exact
   valid release decision can release the exact bound action.
4. The CAF agent receives no implicit primary transcript, workspace state,
   reviewer evidence, policy, credentials, or tools.
5. A CAF answer or clarification returns to the primary. Any new information the
   primary proposes sending to CAF is a new exact disclosure and receives a new
   CAF reviewer decision.
6. Provider, review, evidence, or protocol failure releases nothing. The primary
   receives an explain-and-stop result rather than an opaque stalled turn.

Agent loops are part of the role contract. Reliability work must not collapse
Guardian or the CAF reviewer into one-shot classifiers, merge reviewing roles,
or remove role-appropriate tools merely to reduce model requests. Deterministic
schemas, candidate binding, budgets, destinations, state transitions, and
failure effects constrain communication between agents; model reasoning remains
agentic inside those boundaries.

The current v0.9.6 CAF reviewer is a known mismatch: its evidence tools were
removed and it was made decision-only. Its authorization evidence is also backed
by a newest-32-user-message subset rather than bounded access to the actual
current branch. This must be corrected before a later release; Guardian and the
CAF agent must not be redesigned as part of that correction.

Question-count limits, total consultation rounds, and whether clarification may
continue automatically in the same primary run remain unresolved. Agreement on
this architecture does not authorize changing those consultation semantics.

## Goals and non-goals

The system should let the primary request outside reasoning without
forwarding its Pi transcript, system prompt, workspace, or tool history. The
friend can research the public internet, ask for specific additional information,
and receive only reviewed disclosures. Guardian and CAF share mechanisms without
sharing policy; both remain bounded, visible, cancellable, and fail closed.

The system does not prove that text is non-confidential, delegate the whole
primary task, or give the friend workspace, profile, shell, credential, internal
service, cloud, database, or arbitrary MCP access. It does not transfer files or
history automatically, permit unrestricted URLs or unbounded autonomous
dialogue, create a boundary between trusted in-process extensions, or replace
provider contracts,
network policy, and human judgment.

## Architecture

```text
                         Guard Runtime
                    (shared infrastructure)
                       /              \
             Guardian agent      CAF reviewer agent
                   ^                    ^
          protected action        CAF disclosure
                   |                    |
                   +-------- Primary agent
                                        |
                                      ALLOW
                                        v
                                    CAF agent
                                        |
                               advice or clarification
                                        v
                                  Primary agent
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
explicitly configured reviewer model and thinking selection routes separate
Guardian-agent and CAF-reviewer-agent instances while preserving their private
transcripts, policies, tools, decisions, effects, and journals. A payload is
never sent to the CAF agent merely to decide whether it is safe to send there.

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
│       ├── guardian.jsonl*
│       └── caf.jsonl*
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

### Workspace writers and rotation

Guardian and CAF each write a fixed stream inside the active workspace's log
directory. Events retain writer, process, workspace, and session identities, but
the session ID is record data rather than a path component. A private lock per
client and workspace serializes appends and rotation across Pi processes.
`/guardian-log` and `/caf-log` validate their own regular files and present the
current workspace's retained records chronologically. Their non-TUI fallbacks
report the exact active journal path.

Only unusually large workspace files rotate. There is no completion marker,
profile-wide pruning, or separate retention process. Unsafe ownership, links,
unexpected file types, redirected directories, and unsafe locks fail closed.
Activity leases and status remain process-local and never coordinate unrelated
Pi-Run sessions through the profile filesystem.

Earlier run-shard and nested session-directory journals are non-vital
diagnostics and are intentionally left untouched, unread, and unmigrated. The
journal layout does not change schema 1 in `profile.json`.

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
bounded direct path without a reviewer. The Guard reviewer receives bounded
initial evidence and only `caf_guard_decide`, with no investigative tools or
rounds; incomplete authorization requires `ASK`. Provider failure is not
permission. Cancellation aborts active model and research work and records a
clear outcome.

Every unsuccessful `call_friend` reports `retryAllowed: false`. For ordinary
failures while the primary run remains active, CAF removes all model-visible
tools and permits one explain-only automatic follow-up; it restores the prior
tool set only after the agent settles. This prevents same-turn retry or tool
substitution while allowing the primary to report what failed. If the restricted
loadout cannot be established, CAF returns Pi's terminate signal instead. The
result separately records whether a friend request started. Configuration,
disclosure-policy, and branch-state failures identify the failed state and
include the exact active CAF journal path when diagnostics are available.

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
   later storage corrections made them fixed workspace streams with session
   identity retained inside records.
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
