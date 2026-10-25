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
  friend interaction, and withholding.
- **Primary agent** proposes work and CAF payloads but cannot approve its own
  disclosure merely by proposing it.
- **Friend agent** receives only a separately allowed CAF payload and approved
  bounded public research. It never receives Guard investigation evidence.

Guardian and CAF are equal ordinary runtime clients. They share a reviewer agent
and mechanisms, not policy, activation, decisions, journals, or effects. Their
modes remain independent. The reviewer is never selected implicitly from the
primary or friend model. Missing, invalid, unavailable, cancelled, timed-out,
truncated, or incomplete review fails closed with no fallback.

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

The result remains destination-specific `ALLOW`, `ASK`, or `USER_REFUSED`.
`ALLOW` requires complete user authority and a minimized exact payload, purpose,
history, and destination. Findings and excerpts are never appended to the friend
payload. A non-allowing or incomplete result ends CAF only; it does not open
Guardian's command-dispute latch. Public-search queries receive a fresh review;
friend approval never authorizes a search provider.

## Reviewer and friend separation

The profile visibly identifies both destinations. Exact Guard reviewer and CAF
friend model equality is rejected while CAF is enabled. This catches the most
obvious collapse but cannot prove separation: distinct identifiers can still
reach the same operator, endpoint, logs, or confidentiality domain.

Same-provider configurations produce a persistent warning in CAF status and
menus. Pi-Run cannot infer trust from provider identifiers. Network policy and
credentials remain independent capability boundaries, not confidentiality
proofs.

No reviewer evidence, prompt, policy, rationale, authorization source, or tool
result is sent to the friend. Only the reviewed CAF action, previously reviewed
consultation history, and separately approved bounded research may cross.

## Configuration and compatibility

A new private `guard/config.json` owns the shared reviewer model and thinking.
It is lazy, atomic, mode `0600`, under a validated mode-`0700` directory, and is
not copied with profiles. Fresh profiles have no reviewer selected.

Existing `guardian/config.json` remains readable during transition:

- an explicit legacy model may be adopted in memory without rewriting files;
- legacy `null` does not become a conversation-model fallback;
- the first explicit save writes `guard/config.json` atomically; and
- adoption never copies credentials, changes modes, or contacts a provider.

Guardian retains command policy and activation preferences. CAF retains friend
model/thinking, disclosure policy, and activation preferences. Both are Off for
fresh profiles and genuinely new sessions unless their profile-specific default
is deliberately changed. Resumed sessions restore recorded modes. Changing a
future-session default does not alter existing sessions.

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

Guard Runtime keeps one bottom widget but may render multiple client lines:

```text
guardian · on                 guard qwen3.8-flash-next · low
caf · on                      guard qwen → friend gpt-5.6-sol
```

During activity, the relevant line changes while the other baseline remains:

```text
guardian · reviewing          qwen3.8-flash-next · low
caf · asking friend           gpt-5.6-sol · high
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
3. [ ] Install the extracted harness as the runtime review backend and route
   Guardian through the shared contract without changing reviewer selection.
4. [ ] Add explicit shared Guard configuration and legacy explicit-model
   adoption, without fallback or provider calls.
5. [ ] Add the CAF evidence profile and replace primary-model review with the
   shared Guard agent; reject exact reviewer/friend equality.
6. [ ] Add independent client modes, future-session defaults, and harmonized
   menus.
7. [ ] Render both clients and model roles in the shared bottom widget.
8. [ ] Update user documentation and run the complete isolated suite before any
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

No stage silently enables a client, migrates credentials, changes networking,
contacts a real provider, pushes, tags, installs, or releases.

## Acceptance criteria

The correction is complete only when tests demonstrate:

- both clients use the configured Guard reviewer service;
- either client can be absent without breaking the runtime or other client;
- Guardian parity for allowed, disputed, unavailable, cancelled, resumed, and
  logged command reviews;
- bounded CAF investigation and refusal of secret, linked, special, oversized,
  out-of-root, forbidden-profile, or incomplete evidence;
- no Guard evidence or rationale in friend requests or CAF round state;
- reviewer failure has no fallback and starts no friend request;
- exact Guard/friend equality prevents CAF use;
- independent modes/defaults begin Off and restore correctly;
- the widget shows both baselines and active model roles without enforcement
  effects;
- separate journals preserve privacy and concurrency; and
- native fake-provider lifecycle coverage includes investigation, allowance,
  withholding, cancellation, branch changes, friend calls, questions, search,
  persistence, and shutdown.

Real-provider testing remains a separate disclosure, cost, network, and release
decision. Passing it would show interoperability, not prove provider separation,
confidentiality, or sandboxing.
