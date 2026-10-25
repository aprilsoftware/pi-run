# Shared agentic Guard reviewer

## Status and correction

This document proposes a post-v0.9 correction to the Guard Runtime and Call a
Friend (CAF) trust architecture. It does not authorize implementation,
migration, provider calls, publication, or release work. Shipped v0.9 behavior
remains described by [the original CAF task](call-a-friend.md).

The current Guard Runtime coordinates clients, activity, status, and shared
journal mechanics, but does not own review execution. Guardian runs an agentic
reviewer with bounded evidence tools. CAF instead asks the current primary model
for a non-agentic disclosure decision. That is narrower than the original
shared-runtime design and can collapse the provider boundary when the primary
and friend use the same destination.

A reviewer must receive the candidate disclosure before deciding whether to
allow it. Any evidence it investigates is also sent to its model provider. A
withheld friend request therefore protects the friend destination only when the
reviewer is itself inside an explicitly trusted boundary. Separate requests and
fresh contexts are useful context isolation, not provider confidentiality.

The corrected design uses one explicitly configured trusted Guard reviewer. The
intended deployed roles are:

```text
primary agent       openai-codex/gpt-5.6-sol
Guard reviewer      qwen3.8-flash-next/qwen3.8-flash-next
CAF friend          openai-codex/gpt-5.6-sol
```

Model names do not prove deployment, contractual, retention, or confidentiality
properties. The operator decides whether the Guard provider may receive bounded
internal evidence.

## Roles and invariants

- **Guard Runtime** owns reviewer-agent execution, reviewer resolution, bounded
  evidence dispatch, budgets, cancellation, decision transport, sequential
  activity, status, and shared journal mechanics.
- **Guardian** owns command policy, command actions, decision validation,
  enforcement, and dispute handling.
- **CAF** owns disclosure policy, disclosure/search actions, decision validation,
  friend interaction, and withholding while Guard review is On; while Guard is
  Off it sends the same bounded actions directly without a reviewer decision.
- **Primary agent** proposes work and CAF payloads but cannot approve its own
  disclosure while Guard review is On. With Guard Off, its bounded CAF payload
  is intentionally sent without independent review.
- **Friend agent** receives only the bounded CAF payload and bounded public
  research. It never receives Guard investigation evidence.

Guardian and CAF are ordinary runtime clients. They share a reviewer agent and
mechanisms, not policy, CAF activation, decisions, journals, or effects. The
Guardian session mode is the shared Guard review-layer mode; CAF keeps a separate
availability mode. Guard On applies review to Guardian commands and CAF
friend/search disclosures. Guard Off skips command review and lets an enabled
CAF use its direct path. The reviewer is never selected implicitly from the
primary or friend model. While Guard is On, missing, invalid, unavailable,
cancelled, timed-out, truncated, or incomplete review fails closed with no
fallback to direct execution. Only an explicit Guard Off state selects direct
CAF behavior.

## Runtime review contract

The versioned runtime should extend registration and activity leases with an
operation equivalent to:

```text
review({
  clientId,
  action,
  policy,
  evidenceProfile,
  decisionContract,
  signal,
  diagnostics
}) -> completed decision | incomplete result
```

The runtime validates the registered client, freezes bounded inputs, resolves
the configured Guard model, starts a fresh reviewer transcript, enforces shared
budgets, and returns a result without performing the action. The client validates
the domain decision again before enforcement.

The API must not accept arbitrary tools, provider options, system prompts, paths,
or evidence callbacks from callers. Evidence profiles and decision contracts
are registered trusted-extension definitions. An incompatible runtime leaves
both clients fail closed. Reviews are serialized process-locally; separate Pi
processes do not coordinate authorization through profile files.

## Shared agent harness

The existing Guardian `PiAgentReviewer` is the behavioral baseline. Its model
loop, cancellation, streamed lifecycle, tool scheduling, budgets,
final-decision phase, and source-identity validation move behind the runtime
contract without first changing Guardian behavior.

The reviewer receives private model-only evidence functions, never shell, acting
agent tools, network, or arbitrary MCP. Common mechanics include:

- bounded original-history search/read and later-user-direction checks;
- bounded regular-file reads, searches, and directory listings;
- secret-path and secret-pattern refusal;
- applicable instruction loading;
- explicit incomplete/truncated evidence markers;
- request, byte, evidence, token, and time budgets; and
- one final decision call that cannot be mixed with investigation calls.

Each client selects a registered evidence profile. Evidence sent to the reviewer
is still a disclosure to the Guard provider and must be minimized.

### Guardian profile

Guardian retains current user-authority, instruction, workspace/skill,
prior-effect, and review-guide evidence. Its decision basis, source validation,
command enforcement, disputes, and `guardian_justify` remain Guardian-owned.
Extraction is accepted only if fixture decisions, cancellation, dispute flow,
status, logs, and covered `bash`/`run` behavior remain equivalent.

### CAF profile

CAF begins with the exact candidate message or search query, purpose,
destination, bounded consultation history, CAF policy, and bounded current-branch
user authorization. The Guard agent investigates only when confidentiality or
authorization is materially uncertain.

Permitted CAF evidence is limited to:

- bounded original user-history search/read and later-direction checks;
- bounded non-secret workspace reads, searches, and listings;
- applicable `AGENTS.md` and the selected CAF policy; and
- confidentiality-review guidance that grants no authority.

CAF evidence excludes credentials, secrets, raw sessions, journals, model or
provider credentials, SSH material, snapshot secrets, arbitrary profile files,
shell, network, databases, services, and friend tools. Reads remain inside
validated roots and reject links, special files, oversized content, and
unreported truncation.

While Guard is On, the result remains destination-specific `ALLOW`, `ASK`, or
`USER_REFUSED`. `ALLOW` requires complete user authority and a minimized exact
payload, purpose, history, and destination. Findings and excerpts are never
appended to the friend payload. A non-allowing or incomplete result ends CAF
only; it does not open Guardian's command-dispute latch. Public-search queries
receive a fresh review; friend approval never authorizes a search provider.
While Guard is Off, CAF validates the same bounded action schemas but makes no
reviewer request and sends friend messages and friend-generated search queries
directly to their configured destinations.

## Reviewer and friend separation

The profile visibly identifies both destinations. While Guard is On, exact
Guard reviewer and CAF friend model equality is rejected. This catches the most
obvious collapse but cannot prove separation: distinct identifiers can still
reach the same operator, endpoint, logs, or confidentiality domain.

While Guard is On, same-provider configurations produce a persistent warning in
CAF status and menus. Those checks do not apply to direct CAF because no Guard
provider request occurs. Pi-Run cannot infer trust from provider identifiers.
Network policy and credentials remain independent capability boundaries, not
confidentiality proofs.

No reviewer evidence, prompt, policy, rationale, authorization source, or tool
result is sent to the friend. In guarded mode only the reviewed CAF action,
previously reviewed consultation history, and separately approved bounded
research may cross. In direct mode the bounded action, bounded consultation
history, and bounded public research cross without Guard review.

## Configuration and compatibility

A new private `guard/config.json` owns the shared reviewer model and thinking.
It is lazy, atomic, mode `0600`, under a validated mode-`0700` directory, and is
not copied with profiles. Fresh profiles have no reviewer selected.

Existing `guardian/config.json` remains readable during transition:

- an explicit legacy model may be adopted in memory without rewriting files;
- legacy `null` does not become a conversation-model fallback;
- the first explicit save writes `guard/config.json` atomically; and
- adoption never copies credentials, changes modes, or contacts a provider.

Guardian retains command policy and the shared Guard review-mode preference.
CAF retains friend model/thinking, disclosure policy, and its separate
availability preference. Guard and CAF are both Off for fresh profiles and
genuinely new sessions unless their profile-specific default is deliberately
changed. Resumed sessions restore recorded modes. Changing a future-session
default does not alter existing sessions. Guard Runtime begins each session in
an unknown state; Guardian publishes the restored explicit mode before clients
may choose guarded or direct behavior.

## Menus and commands

The primary UX is `/guardian` and `/caf` menus; users need not memorize
subcommands. Both show current mode, new-session default, shared Guard reviewer,
effective reviewer thinking, logs, and status. CAF also shows friend model and
thinking.

Existing Guardian commands remain compatible. CAF gains matching `/caf-mode`,
`/caf-model`, `/caf-thinking`, and `/caf-log` interfaces for autocomplete,
non-TUI use, and tests. There is no `/caf-resume`: CAF has no global dispute
latch. Changing the shared reviewer clearly states that it may receive bounded
Guardian command and CAF confidentiality evidence. Opening selectors makes no
provider call.

## Shared status surface

Guard Runtime keeps one bottom widget with two role-specific lines. The shared
Guard reviewer appears once and the CAF line shows the friend model. Guard state
already determines whether an enabled CAF is reviewed, so the compact CAF line
does not repeat derived `direct` or `guarded` labels:

```text
guard · off                    qwen3.8-flash-next · low
caf · on                       gpt-5.6-sol · high
```

During guarded activity, the relevant line changes while the other baseline
remains:

```text
guard · reviewing CAF disclosure   qwen3.8-flash-next · low
caf · on                            gpt-5.6-sol · high
```

Narrow rendering preserves client and state before model details. Presentation
failure never affects review, enforcement, or mode. Only one active
review/friend/research lease exists at a time.

## Journals and retained state

Guardian and CAF retain separate `/guardian-log` and `/caf-log` views and
`logs/<client>/runs/<run-id>.jsonl*`; there is no `/guard-log`. CAF journals
continue to exclude payloads, policies, authorization text, evidence, answers,
and search results while recording bounded hashes, sizes, stages, decisions,
usage, duration, and whether an external request started. Guardian retains its
documented private evidence diagnostics. Journal failure never changes review.

Finalized CAF rounds remain branch-local and excluded from ordinary primary
context. Guard investigation evidence is not persisted in CAF rounds.

## Implementation sequence

Each stage requires separate approval and stops after validation:

1. [x] Add the shared-review contract and fake-client tests while production
   paths remain unchanged.
2. [x] Extract the reusable Pi-agent model loop and private-tool dispatcher;
   preserve the Guardian domain adapter and prove reviewer/flow parity.
3. [x] Add bounded, client-local review diagnostics so runtime routing can
   preserve Guardian's review trace without putting callbacks in review JSON.
4. [x] Install the extracted harness as the runtime review backend and route
   Guardian through the shared contract without changing reviewer selection.
5. [x] Add private shared Guard configuration, safe legacy explicit-model
   adoption, and no implicit conversation-model fallback.
6. [x] Move shared reviewer resolution fully into the runtime backend without
   changing the selected destination or contacting a provider.
7. [x] Define and validate the bounded CAF evidence profile and privacy-filtered
   diagnostics while leaving production review routing unchanged.
8. [x] Replace primary-model CAF review with the shared Guard agent and reject
   exact reviewer/friend equality.
9. [x] Add the shared Guard review-layer mode, independent CAF availability,
   future-session defaults, direct CAF routing, and harmonized menus.
10. [x] Render both clients and model roles in the shared bottom widget.
11. [x] Update user documentation and run the complete isolated suite before any
   controlled real-provider candidate.

Stage 1 introduced a separately versioned additive review service with immutable
client domains, bounded frozen JSON requests, FIFO execution, cancellation,
strict result validation, and fail-closed unavailable/error outcomes. Only fake
reviewer clients use it; production Guardian and CAF review paths are unchanged.

Stage 2 moved the Pi model loop, private evidence-tool scheduling, budgets,
cancellation, streaming, and decision-only lifecycle into a reusable domain-
parameterized module. Guardian supplies its existing prompt, evidence operations,
decision schema, and validation, and still invokes the harness directly; runtime
routing and CAF behavior remain unchanged.

Stage 3 added runtime-validated, deeply frozen diagnostic events with client
identity, monotonic sequence, per-event and cumulative bounds, cancellation and
completion closure, and client-local delivery. Malformed or over-budget backend
diagnostics fail the review even if the backend catches the reporting error.
Client presentation callbacks remain outside serialized review requests, cannot
affect review outcomes, and cannot observe other clients.

Stage 4 installed the shared agentic backend dispatcher and routed Guardian
command reviews and dispute reassessments through the runtime FIFO contract.
Guardian retains its existing model selection and static domain implementation;
its full evidence state and reviewer binding stay in an opaque, single-use local
request record rather than serialized action JSON. Runtime absence, unsupported
domains, cancellation, malformed envelopes, or incomplete reviews fail closed
without direct-review fallback. CAF routing remains unchanged.

Stage 5 added lazy atomic `guard/config.json` storage with private directory/file
validation. An explicit legacy Guardian model may be adopted in memory while a
legacy null model leaves review unavailable; the legacy file is never rewritten.
Explicit Guardian model/thinking saves now target the shared file, and profile
cloning excludes it. At that stage reviewer construction remained in Guardian's
trusted domain adapter pending the separately approved backend-resolution work.

Stage 6 moved production model lookup, effective-thinking selection, and reviewer
timeout ownership into the runtime backend. Guardian now retains only an opaque
single-use evidence request; it constructs the domain reviewer from the backend's
immutable selection and cannot choose a destination through review action JSON.
Missing configuration, unavailable models, timeout, cancellation, and late
results remain fail closed. Test-only injected reviewers remain available to
isolated fixtures and are not the production path.

Stage 7 added the CAF-specific Guard domain and evidence adapter without routing
production calls to it. The profile carries only the exact candidate, policy,
bounded current-branch user authority, explicitly supplied instructions, and
validated non-secret evidence roots. Its tools provide bounded history, file,
search, listing, and guidance operations; links, special files, secret paths,
profile-state roots, oversized inputs, and incomplete authority are rejected.
CAF-facing diagnostic sanitization drops payloads, policy, authorization text,
paths, queries, evidence, and errors. The friend receives none of this evidence.

Stage 8 registered that profile through the shared runtime and removed the
primary conversation model from production CAF review. Friend messages and
public-search destinations now receive separate agentic Guard decisions through
opaque, single-use local request records. Exact reviewer/friend model equality
fails before either provider request. Missing selection, unavailable review,
incomplete authority, malformed output, cancellation, or runtime loss withholds
the disclosure. Reviewer usage remains included in CAF aggregate usage when the
provider reports it, while private review inputs and diagnostics remain absent
from friend payloads, finalized rounds, and CAF journals.

Stage 9 made Guardian's session mode the shared Guard review-layer state and
kept CAF activation independent, with private per-profile defaults for genuinely
new sessions. Missing defaults, old sessions without mode metadata, fresh
profiles, and profile clones remain Off. Changing a default does not alter the
current session. Guard Off keeps Guardian's documented skip-review behavior and
routes enabled CAF friend/search actions directly with zero reviewer requests.
Guard On requires completed review and never downgrades to direct because of an
error. CAF Off disables friend calls. Changes to either current mode cancel
active CAF work without retry. `/guardian` and `/caf` provide parallel menu-first
controls while dedicated mode, default, model, thinking, and log commands remain
available. CAF status shows the Guard mode without repeating a derived label on
the CAF state; exact equality blocking and same-provider warnings apply only
while Guard is On and do not claim identifiers prove separation.

Stage 10 replaced the latest-baseline-only display with one Guard Runtime-owned
two-row widget. The Guard row shows the single shared reviewer and command or CAF
review activity; the CAF row shows the friend model and friend/search activity.
Guard state already determines review behavior, so the compact CAF line does not
repeat `direct` or `guarded`. Presentation remains outside authorization and
transmission decisions.

Stage 11 aligned the overview, user guides, security guidance, behavior
references, profile-management skill, profile layout, and launcher diagnostic
with the implemented shared mode, explicit reviewer selection, bounded
unreviewed CAF path, private defaults, and two-row display. All 59 isolated shell
test scripts passed. Live Guardian provider fixtures and the opt-in real-Docker
worktree end-to-end case remained explicitly skipped; no real provider was
contacted.

No stage silently enables a client, migrates credentials, changes networking,
contacts a real provider, pushes, tags, installs, or releases.

## Acceptance criteria

The correction is complete only when tests demonstrate:

- both clients use the configured Guard reviewer service while Guard is On;
- either client can be absent without breaking the runtime or other client;
- Guardian parity for allowed, disputed, unavailable, cancelled, resumed, and
  logged command reviews;
- bounded CAF investigation and refusal of secret, linked, special, oversized,
  out-of-root, forbidden-profile, or incomplete evidence;
- no Guard evidence or rationale in friend requests or CAF round state;
- reviewer failure while Guard is On has no direct fallback and starts no friend
  request;
- Guard Off makes enabled CAF use bounded direct friend/search actions with zero
  reviewer requests;
- Guard mode changes cancel active CAF work without retrying it under the new
  mode;
- exact Guard/friend equality prevents guarded CAF use but is irrelevant to the
  direct path;
- Guard review and CAF availability modes/defaults begin Off and restore
  correctly;
- the widget shows both baselines and active model roles without enforcement
  effects;
- separate journals preserve privacy and concurrency; and
- native fake-provider lifecycle coverage includes investigation, allowance,
  withholding, cancellation, branch changes, friend calls, questions, search,
  persistence, and shutdown.

Real-provider testing remains a separate disclosure, cost, network, and release
decision. Passing it would show interoperability, not prove provider separation,
confidentiality, or sandboxing.
