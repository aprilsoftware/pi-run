# Guardian behavior reference

This reference records Guardian preference, reviewer, evidence, dispute,
and retained-log behavior. For normal setup and decisions, start with the
[Guardian task guide](../guardian.md).

## Preferences and startup

Guardian is loaded for every Pi-Run profile. Shared reviewer model and thinking
preferences live in private `guard/config.json`. The current session's Guard
mode is private extension metadata, while the profile-specific default for
genuinely new sessions is stored in private `guardian/mode.json`. The editable
command-review policy remains `guardian/guardian.md`.

An explicit model in legacy `guardian/config.json` may be adopted in memory when
`guard/config.json` is absent, but the legacy file is never rewritten as a
migration. A missing or null selection never becomes a conversation-model
fallback. The first explicit reviewer save writes `guard/config.json`.

Activation is session-scoped. Fresh profiles, genuinely new sessions, and older
sessions without mode metadata default Off unless `guardian/mode.json` was
deliberately changed. `/guardian-mode on|off` appends private extension state to
the current session; it is not sent to either model. Resuming restores the
latest mode, and branch navigation retains it. `/guardian-default on|off`
changes only future genuinely new sessions.

Profile creation copies the Guardian policy but not reviewer preferences, mode
defaults, sessions, or logs. Invalid private configuration is reported rather
than silently rewritten.

Use `/guardian-status` to inspect current mode, future default, reviewer,
thinking, and log path. `/guardian` opens the settings menu. `/guardian-mode`,
with no argument, opens a selector; `/guardian on` and `/guardian off` remain
aliases.

## Reviewer model and thinking

Guard review requires one explicitly selected model. It never silently uses the
conversation model or CAF friend. Select an available configured model through:

```text
/guardian-model
```

A direct `/guardian-model <provider>/<model-id>` requires the exact locally
registered identifier. Model resolution and selectors contact no provider.
`/guardian-thinking` selects a supported explicit level; `default` clears the
stored override. Guard Runtime requests `low` when no explicit level is stored
and clamps it to a level supported by the selected model.

**Thinking Off does not disable command review.** `/guardian-thinking off`
controls reviewer reasoning effort; `/guardian-mode off` disables the gate.
Model and thinking selectors do not invoke the conversation agent merely by
opening them.

The shared reviewer is independent of the acting model and CAF friend. Reviewer
requests use Pi's configured provider access and can incur separate latency and
cost. Context sent to the provider can include instructions, command arguments,
CAF candidate disclosures, conversation excerpts, and bounded file evidence.

## Status rows

Guard Runtime owns one muted two-line widget below Pi's editor, for example:

```text
guard · off                                  reviewer-model · low
caf · on                                     friend-model · high
```

The Guard row reports Off, On, Reviewing, Dispute, or a temporary interruption
state and shows the single shared reviewer. The CAF row reports CAF availability
or friend/search activity and shows only the friend model. Guard state already
determines whether an enabled CAF receives review, so the compact CAF row does
not repeat a derived label. During CAF disclosure review, activity appears on
the Guard row; during friend or search calls, it appears on the CAF row.

Narrow rendering preserves role and state before model details. Non-TUI modes
install no widget. Presentation failure cannot alter mode, review, enforcement,
or transmission. Completed durations remain in retained logs.

Dispute reports `investigating` while the acting agent may make bounded native
file reads, `assessing` during automatic justification review, or `awaiting you`
after assessment, settlement, or read-budget exhaustion. A genuine user message
or `/guardian-resume` returns the row to On; neither event grants authority merely
by clearing the latch.

## Review scope and evidence

During normal Guardian operation, only acting-agent calls whose tool name is
exactly `bash` or `run` are reviewed. Aliases, shell-looking arguments to another
tool, and host-terminal commands do not extend normal command coverage. Guard
mode also controls CAF disclosure review: On requires a completed decision for
each friend/search destination; Off skips command assessment and makes enabled
CAF send its bounded actions without reviewer calls. In either mode, the agent's
instructions and authorization obligations still apply.

An open dispute is a separate stop state. It permits at most six direct native
`read` calls during the same agent run and withholds every other acting-agent
tool, including normally uncovered tools, except Guardian's model-only
`guardian_justify` handoff. After settlement without a position, or after an
unresolved contest, every tool is blocked until human feedback clears the
dispute. Retraction, narrowing, or an accepted contest closes the challenge and
allows the primary to continue.

A review considers the proposed invocation, working directory, current user
request, relevant conversation history, profile policy, and applicable
repository instructions. The reviewer can request bounded read-only evidence,
including:

- original active-branch messages and later user changes;
- possible effects recorded on sibling branches, which never grant authority;
- non-secret workspace and managed-skill files;
- bounded file-name or text searches and directory listings; and
- built-in review guides for scripts, storage, and scope.

Evidence tools do not execute the proposed action. A path mentioned by a command
is not proof that the reviewer inspected it, and available evidence does not
guarantee correct interpretation.

## Review outcomes and dispute lifecycle

A valid decision either allows the invocation or withholds it. `ASK` and
`USER_REFUSED` both open a challenge; the latter records that an applicable user
restriction already exists. The acting agent may retract, narrow, or contest as
described below, and only unresolved outcomes require human arbitration.
Guardian never releases either case through a confirmation dialog.

The blocked invocation is permanently cancelled. Guardian records and displays
its reason independently, cancels sibling command reviews, and enters the
`investigating` phase. The acting agent can use only the bounded native read
allowance to check file evidence. It then calls `guardian_justify` with a
`retract`, `narrow`, or `contest` position, a bounded explanation, and up to eight
bounded evidence references. Tool variants, edits, writes, commands, nested
tools, and unknown tools cannot route around the latch.

The justification tool is active only while a submission is pending. Retraction
closes the challenge immediately and executes nothing. Narrowing also withdraws
the original action; a replacement is a new invocation subject to normal review.
Neither path spends another reviewer request or requires human arbitration.

A contest changes status to `assessing` and starts a fresh bounded reviewer pass
over the original blocked action, current authority, original concern, and
structured position. The explanation and references remain untrusted claims.
The same source validation, evidence limits, time limits, and fail-closed
transport behavior apply.

The assessment classifies the position as **Concern resolved** (`ALLOW`),
**Concern remains** (`ASK`), **User restriction remains** (`USER_REFUSED`), or
**Assessment unavailable**. `ALLOW` closes the challenge and creates a
process-local, one-use release for a new invocation matching the exact tool,
arguments, working directory, session, and unchanged conversation. Guardian
does not replay the cancelled tool call itself. A mismatch consumes the release
and receives normal review.

The other assessment outcomes leave the dispute `awaiting-user` and use Pi's
terminate signal to stop automatic follow-up. The active branch stores open and
resolved dispute state outside model context. Completed or unavailable unresolved
assessments are stored with the position; a cancelled or late assessment cannot
be attached after user feedback resolves the dispute. The one-use exact release
is process-local and is not restored after reload, resume, or branch navigation.
Guardian mode itself remains session-wide.

A later genuine user message resolves the latch before starting a fresh turn.
`/guardian-resume` also resolves it, but deliberately contributes no authority
and triggers no model turn. Earlier restrictions still apply unless the user
actually changes them. Turning Guard Off resolves the latch, disables future command and CAF disclosure
review, and cancels active CAF work without retry, but never replays the cancelled
invocation.

## Unavailable and interrupted review

Missing provider access, timeout, invalid reviewer output, missing instructions,
or another reviewer failure produces no AI decision. During initial review,
Guardian withholds the action and opens a dispute regardless of UI mode. The
primary may retract or narrow the original without another assessment. A contest
whose assessment is unavailable still waits for the human. Guardian never offers
a bypass that releases an unreviewed invocation.

Cancellation caused by session, branch, settings, or action changes does not
become approval. Use status and logs to identify the interruption before
proposing a new invocation.

Review release means only that the gate released a tool call. The call can still
fail, be cancelled elsewhere, produce partial effects, or report an uncertain
result. Verification and cautious retry rules remain separate from Guardian.

## Review policy

The profile policy is stored at `guardian/guardian.md`. Inside Pi-Run it appears
at `/profile/guardian/guardian.md`. It is evaluated alongside profile
`AGENTS.md`, applicable workspace instructions, the current request, and the
built-in reviewer contract.

Useful policy names concrete protected resources and consequential effects:
persistent-data deletion, database changes, shared-service disruption, broad
permission changes, credential disclosure, external publication, and unapproved
scope expansion. Policy updates guide subsequent reviews but do not authorize a
task or change operating-system permissions.

## Retained review logs

`/guardian-log` opens a read-only browser of retained review attempts across Pi
sessions belonging to the current workspace. `/guardian log` is an alias, and
`/guardian-log <search terms>` applies an initial filter. Calls skipped while
Guardian was Off and raw diagnostic-only records do not appear as reviews.

| Key | Action |
| --- | --- |
| Up/Down, Page Up/Page Down | Select reviews or scroll details |
| Enter | Open the selected review |
| `/` | Search; Enter applies and Escape restores the prior filter |
| `1`–`4`, Tab, Left/Right | Switch Summary, Command, Evidence, and Timeline |
| `R` | Refresh the retained snapshot |
| Escape | Return from details or close the list |
| `Q` or Ctrl+C | Close the browser, not the acting agent |

Summary separates review outcome and basis, Guardian release or withholding,
and execution result. Historical traces can still show confirmation fields from
older Guardian versions. Command and evidence are bounded, best-effort-redacted
previews; they may omit fields, suffixes, output, or original messages. Timeline
records meaningful model, evidence, decision, dispute, release, and result events.

The browser cannot run or approve commands, change mode, resolve a dispute, fetch
missing conversation content, or reconstruct data no longer retained. It
requires Pi's terminal UI. Opening a dispute closes the log browser so its reason
is not obscured.

Each Pi session writes its bounded Guardian stream under
`logs/<workspace-id>/<session-id>/guardian.jsonl`, with up to two rotated
segments at about 1 MiB each. A resumed session appends to the same file, and
`/guardian-log` merges Guardian streams from the current workspace
chronologically. Separate sessions do not share a writer lock. Concurrently
resuming the same saved session has the same unsupported file-writing semantics
as Pi's session file itself; the journal adds no separate lock.

Rotation applies only to an unusually large individual session file. There is
no profile-wide pruning, completion marker, or retention lock. Existing v0.9.x
run journals remain untouched and are not read. Rotation, partial writes,
process interruption, display limits, missing tool results, and logging failures
can create gaps. Logging failure does not alter a review decision or dispute
state.

Treat logs as private. They can contain commands, paths, selected conversation
text, evidence excerpts, model details, and errors. Redaction is best effort,
not proof that arbitrary secrets are absent. Do not put literal secrets in
commands or publish logs without inspection.

[Guardian task guide](../guardian.md) · [Planning](../planning.md) ·
[Security and isolation](../security.md)
