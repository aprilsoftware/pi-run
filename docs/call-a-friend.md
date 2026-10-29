# Call a Friend

Call a Friend (CAF) lets the private primary agent ask a separately configured
model for bounded advisory reasoning without automatically transferring the
primary transcript, workspace, profile knowledge, tools, or credentials. The
primary remains authoritative and responsible for checking the answer.

Each released invocation runs the friend through a fresh native Pi `Agent` with
its own private transcript and a deliberately restricted tool set. CAF remains
application-level orchestration: it is not a sandbox, a confidentiality proof,
or evidence that either model or provider handles data correctly.

## Understand CAF and Guard

CAF availability and Guard review are separate controls:

| Guard | CAF | Behavior |
| --- | --- | --- |
| Off | Off | `call_friend` is unavailable. |
| Off | On | CAF sends bounded friend and search actions without Guard review. |
| On | Off | `call_friend` is unavailable. |
| On | On | Guard reviews each friend and search destination before CAF sends it. |

Only an explicit Guard Off state selects the unreviewed path. If Guard mode is
unknown, CAF cannot choose a path and sends nothing. If Guard is On but its
reviewer is missing, unavailable, cancelled, timed out, truncated, or invalid,
CAF fails closed; it never silently falls back to unreviewed transmission.

Guard Off can avoid the latency and cost of a reviewer request. It also removes
the independent disclosure judgment: the primary agent's bounded proposal goes
directly to the configured destination. This can be useful when a small primary
model uses a stronger friend as a router, but it is a different trust choice.

## What crosses the boundary

The primary invokes the model-only tool:

```text
call_friend({ message, purpose })
```

CAF validates and sends only the bounded message and purpose. A continuation may
also include bounded CAF requests and friend responses from the same pending
consultation. It does not automatically include the primary transcript,
assistant reasoning, tool results, workspace files, profile policy,
authorization evidence, credentials, or unrelated CAF consultations.

While Guard is On, a separate CAF reviewer agent receives the exact proposed
action, CAF policy, applicable instructions, and compact initial evidence from
the current session branch. It may investigate through bounded history,
file-search/read, resource-listing, user-change, and review-guidance tools. The
original branch remains local until an initial excerpt or requested evidence is
selected; an incomplete compact snapshot does not itself invalidate a complete
current user direction. The reviewer must return `ALLOW`, `ASK`, or
`USER_REFUSED`. Only a valid `ALLOW`, bound to complete original user evidence
and that exact action and destination, releases it. Reviewer evidence,
rationale, tools, and policy never become part of the CAF agent payload.

A reviewer request is itself disclosure to the configured Guard provider.
Separate model requests isolate contexts; they do not prove provider
confidentiality. A reviewer can make mistakes, and an unreviewed primary can
make mistakes. Keep sensitive material out of proposed CAF messages and use
provider, contractual, identity, credential, and network controls as actual
authority boundaries.

## Configure and enable CAF

CAF and Guard both start Off for fresh profiles and genuinely new sessions,
unless their profile-specific new-session defaults were deliberately changed.
Existing sessions without mode metadata also remain Off.

Open the CAF menu:

```text
/caf
```

Direct commands remain available for accessibility, automation, autocomplete,
and non-TUI sessions:

```text
/caf-mode on|off
/caf-default on|off
/caf-model <provider/model>
/caf-thinking <default|off|minimal|low|medium|high|xhigh|max>
/caf-status
/caf-log
```

`/caf-mode` changes only the current session. `/caf-default` changes only the
selected profile's default for genuinely new sessions. Resuming a session
restores its recorded mode; branch navigation does not create a new mode.
Turning CAF Off cancels active review, friend, and search work without retrying.

The friend model must already be available through the selected profile's normal
Pi model registry. CAF stores friend preferences lazily in private
`caf/config.json` and the new-session default in private `caf/mode.json`.
Selecting settings does not contact a provider. Profile cloning copies neither
file, so a clone starts CAF Off and unconfigured.

Fresh profiles include `caf/caf.md`. Customize it with concrete protected
categories, abstraction guidance, and external-research constraints. Do not put
secrets in policy text. The policy guides Guard review while Guard is On; it
does not enable CAF, grant authority, or inspect unreviewed calls while Guard is
Off.

Use `/guardian` or the direct Guardian commands to configure the shared Guard
reviewer and mode; see [Guardian and shared Guard review](guardian.md).

## Reviewer and friend separation

While Guard is On, the reviewer and friend model identifiers must differ
exactly. CAF rejects an exact match before either model provider request.
Different models under the same provider identifier produce a persistent
warning. Identifiers cannot prove that endpoints, operators, logs, retention,
or confidentiality domains are separate.

These checks do not apply while Guard is Off because CAF makes no reviewer
request. They do not limit which model may be selected as the friend.

## Dialogue and questions

A friend invocation returns either a bounded final answer or a byte-bounded
structured clarification request containing the focused questions it needs.
There is no ordinary semantic question-count limit. Questions terminate only
the CAF agent's current round; the successful `call_friend` result returns
control to the primary without ending the primary agent run. The CAF agent
cannot invoke the primary recursively or obtain an answer by itself.

The primary may process the questions and immediately issue another standalone
`call_friend` in the same run; a new user turn is not mechanically required. It
may instead ask the user when the available authority or information is
insufficient. Every continuation is a new exact disclosure and follows the
Guard mode current at that call, so automatic continuation never bypasses the
CAF reviewer. A consultation may continue while clarification materially
improves the advice and must use the same CAF model. It ends when CAF answers,
the primary stops, review withholds a continuation, the user cancels, or a real
provider, context, protocol, or emergency persistence boundary is reached. A
final answer closes the consultation.

`call_friend` must be the only tool call in its assistant message. The friend
answer is untrusted advice; the primary must verify it and decide whether any
action is appropriate.

## Public search

CAF can offer the friend constrained public research when all of these are
true:

- the bundled canonical `web_search` tool is callable;
- `web-search.json` selects one explicit provider;
- the provider is not `auto`, `all`, or an array; and
- the active network policy permits the provider traffic.

Use the bundled web-search configuration UI to select a provider, or configure
one explicit `provider` or `searchProvider` in the profile's
`web-search.json`. `/caf-status` reports the provider loaded at session start.

The CAF agent may request `caf_web_search({ query, purpose })` whenever another
focused query materially improves its advice. CAF pauses the agent and validates
each exact query, purpose, and search-provider destination independently. With
Guard On, every search action receives a fresh CAF reviewer decision; approval
of the CAF destination or an earlier query never authorizes a later search. With
Guard Off, CAF sends each bounded query without reviewer judgment.

After release, the CAF agent calls `web_search` with one query, at most five
results, no page content, no curator, and no proxy override. Bounded titles,
snippets, URLs, and any bounded provider answer return as one tool result inside
the same private agent transcript. The agent may refine its research with
another independently reviewed query, answer, or request clarification. There
is no ordinary search-count limit. Cumulative retained research is bounded to
512 KiB; provider context, cancellation, refusal, and failures remain stopping
conditions.

Research retained with a clarification round is included in the bounded,
reviewed continuation state so the next fresh CAF agent can continue without
receiving implicit primary context. The primary receives the advisory response
plus a CAF-generated source list grouped by search. Search results and pages are
untrusted. CAF does not fetch result URLs, perform source checks, or validate
claims behind snippets. Offline and restricted networking remain independent
and authoritative.

## Status display

Guard Runtime owns one two-line widget below Pi's editor:

```text
guard · off                                     reviewer-model · low
caf · on                                        friend-model · high
```

The Guard row determines whether an enabled CAF is reviewed, so the CAF row does
not repeat derived labels. During Guard review, the Guard row shows review
activity. During a consultation, the CAF row uses plain-language states:

```text
guard · reviewing disclosure · 12s
caf · asking friend · 14s
caf · searching the web · 20s
caf · friend reviewing search results · 25s
```

Elapsed time is continuous across one `call_friend` invocation as activity moves
between disclosure review, friend, and search stages. After the activity finishes,
the Guard and CAF rows return to their normal On or Off baselines. Consultation
round details remain available through `/caf-status` and the journal. Narrow
terminals retain role and state before truncating model details. Non-TUI sessions
have no widget. Presentation failure never changes mode, review, or transmission.

`/caf-status` gives detailed readiness, configuration, Guard mode, policy,
research, and branch-state information without contacting either model.

## Branch state and resume

Only finalized answers, questions, and bounded research evidence are saved as
branch-local custom session entries. These entries are excluded from ordinary
primary-model context. Selecting another session branch reconstructs only that
branch's CAF consultation state.

A normal exit may resume the consultation later. Malformed retained state,
friend-model changes during a pending consultation, and exhausted round budgets
fail closed. An unsuccessful `call_friend` returns a structured explain-only
failure with `retryAllowed: false`. Before an ordinary automatic follow-up, CAF
removes every model-visible tool so the primary can only explain the failure and
end its turn; the prior tool set is restored after the agent settles. If that
restricted loadout cannot be established, CAF retains Pi's strict terminate
signal instead. User cancellation can still prevent the explanatory follow-up.
The result records whether a friend request started, distinguishing local
withholding from a possible external effect. Configuration, disclosure-policy,
and branch-state failures identify the unavailable state and report the exact
active CAF journal path when diagnostics are available.

## Diagnostics

`/caf-log` shows bounded recent diagnostics from Pi sessions belonging to the
current workspace:

```text
<profile>/logs/<workspace-id>/caf.jsonl*
```

The active file is shared by that workspace's Pi sessions. During each append
or rotation, the writer creates
`<profile>/logs/<workspace-id>/.caf-journal.lock/` as a private `0700`
coordination directory containing one private `0600` random-token file. It is
removed when that serialized operation finishes; it is neither a completion
marker nor retained journal state. A lock older than 30 seconds is atomically
isolated and removed only after ownership, type, mode, link, and token-name
validation. An unsafe or still-busy lock rejects that diagnostic write without
changing CAF review or release behavior. Session identity remains inside each
record, not in the path. Unusually large files rotate locally; there is no
profile-wide journal pruning or completion marker. Earlier run-shard and nested
session-directory journals remain untouched and are not read. Outside Pi's
terminal UI, `/caf-log` reports the exact active `caf.jsonl` path.

Records include operation identities, destinations, whether the path used Guard
review, outcomes, byte counts, SHA-256 payload hashes, usage, duration, and
result counts. They exclude exact messages, purposes, queries, policies,
authorization evidence, answers, search results, credentials, workspace
content, and private Guard evidence. Hashes still permit equality correlation
and can confirm guesses about low-entropy content.

CAF and Guardian use the same journal implementation but separate fixed streams
and commands. There is no `/guard-log`. Journal or presentation failure never
changes review, transmission, or tool-result behavior.

## Current limits

CAF has native Pi lifecycle coverage with fake primary, reviewer, friend, and
search providers. This does not establish interoperability with every real
provider. Provider-side retention, logging, tool-call behavior, and
confidentiality remain outside Pi-Run's control. Pi extensions execute in the
same process, and CAF's context separation is not an operating-system boundary.

Current public research is intentionally limited to one canonical search. There
is no friend page fetching, arbitrary URL access, shell, filesystem, internal
network, arbitrary MCP access, or autonomous research loop. CAF imposes no
wall-clock deadline on the friend agent's model response; explicit provider
failure stops the CAF operation and enters bounded failure reporting, while
user, mode, or session cancellation can stop the run outright.

[Documentation index](index.md) · [Guardian](guardian.md) · [Security](security.md)
