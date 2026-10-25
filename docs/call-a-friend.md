# Call a Friend

Call a Friend (CAF) lets the private primary agent ask a separately configured
model for bounded advisory reasoning without automatically transferring the
primary transcript, workspace, profile knowledge, tools, or credentials. The
primary remains authoritative and responsible for checking the answer.

CAF is application-level orchestration. It is not a sandbox, a confidentiality
proof, or evidence that either model or provider handles data correctly.

## What crosses the boundary

The primary invokes a model-only tool equivalent to:

```text
call_friend({ message, purpose })
```

CAF sends only an allowed message and purpose to the configured friend model.
A continuation may also include earlier reviewed CAF requests and friend
responses from the same pending consultation. It does not include the primary
transcript, assistant reasoning, tool results, workspace files, profile policy,
authorization evidence, or unrelated CAF consultations.

Before transmission, the current primary model receives the exact proposed
disclosure, the CAF policy, and bounded user-authored messages from the selected
session branch. It must return `ALLOW`, `ASK`, or `USER_REFUSED`. Missing,
malformed, cancelled, timed-out, truncated, or non-allowing review withholds the
transmission. An `ALLOW` authorizes that exact purpose and destination; it does
not make the information public or authorize onward disclosure.

A model reviewer can make mistakes. Keep sensitive material out of proposed CAF
messages and use provider, contractual, identity, and network controls as the
actual authority boundaries.

## Configure CAF

CAF starts unconfigured. In Pi, select an available friend model and optionally
a reasoning level:

```text
/caf model <provider/model>
/caf thinking <default|off|minimal|low|medium|high|xhigh|max>
/caf status
```

The model must already be available through the selected profile's normal Pi
provider configuration. CAF stores the preference lazily in private
`caf/config.json`. Profile cloning does not copy that private preference.
Selecting a model does not contact it.

Fresh profiles contain `caf/caf.md`. Customize this file with concrete
profile-specific protected categories, abstraction guidance, and external
research constraints. Do not place secrets in the policy. Profiles created
before CAF remain valid without it and use the built-in review contract.

CAF review is mandatory and independent of Guardian's On/Off state. Guardian
reviews covered command tools; CAF reviews external disclosures.

## Dialogue and questions

A friend invocation returns either a bounded final answer or at most three
structured questions. Questions end the friend round and return control to the
primary. The friend cannot invoke the primary recursively.

To answer, the primary must issue another standalone `call_friend` invocation.
That answer receives a fresh disclosure review. A consultation is limited to
three primary/friend rounds and must continue with the same friend model. A
final answer closes the consultation.

`call_friend` must be the only tool call in its assistant message. The friend
answer is untrusted advice; the primary must verify it and decide whether any
action is appropriate.

## Reviewed public search

CAF can offer the friend one constrained public search when all of these are
true:

- the bundled canonical `web_search` tool is callable;
- `web-search.json` selects one explicit provider;
- the provider is not `auto`, `all`, or an array; and
- the active network policy permits the provider traffic.

Use the bundled web-search configuration UI to select a provider, or configure
one explicit `provider` or `searchProvider` in the profile's
`web-search.json`. `/caf status` reports the provider CAF loaded at session
start.

The friend may request one `caf_web_search({ query, purpose })`. CAF pauses the
friend and separately reviews the exact query, purpose, and search-provider
destination. Approval to contact the friend model does not authorize this
second destination.

After `ALLOW`, CAF calls `web_search` with one query, at most five results, no
page content, no curator, and no proxy override. It sends bounded titles,
snippets, URLs, and any bounded provider answer to one final friend request with
no tools. The primary receives the advisory answer plus a CAF-generated source
list.

Search results and pages are untrusted. CAF does not fetch result URLs, perform
source checks, validate the claims behind snippets, or permit a second search in
the same invocation. Offline and restricted networking remain independent and
authoritative.

## Branch state and resume

Only finalized answers, questions, and bounded research evidence are saved as
branch-local custom session entries. These entries are excluded from ordinary
primary-model context. Selecting another session branch reconstructs only that
branch's CAF consultation state.

A normal exit may resume the consultation later. Malformed retained state,
friend-model changes during a pending consultation, and exhausted round budgets
fail closed.

## Diagnostics

`/caf-log` shows bounded recent diagnostics merged from private per-run shards:

```text
<profile>/logs/caf/runs/<run-id>.jsonl*
```

Records include operation identities, destinations, outcomes, byte counts,
SHA-256 payload hashes, usage, duration, and result counts. They exclude exact
messages, purposes, queries, policies, authorization evidence, answers, search
results, credentials, and workspace content. Hashes still permit equality
correlation and can confirm guesses about low-entropy content.

CAF and Guardian use the same journal implementation but separate namespaces
and commands. There is no `/guard-log`. Journal or presentation failure never
changes authorization or release behavior.

## Current limits

CAF has native Pi lifecycle coverage with fake primary, friend, and search
providers. This does not establish interoperability with every real provider.
Provider-side retention, logging, tool-call behavior, and confidentiality remain
outside Pi-Run's control. Pi extensions execute in the same process, and CAF's
context separation is not an operating-system boundary.

Current public research is intentionally limited to one canonical search. There
is no friend page fetching, arbitrary URL access, shell, filesystem, internal
network, arbitrary MCP access, or autonomous research loop.
