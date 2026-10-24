# Guardian behavior reference

This reference records Guardian preference, reviewer, evidence, dispute,
and retained-log behavior. For normal setup and decisions, start with the
[Guardian task guide](../guardian.md).

## Preferences and startup

Guardian is loaded for every Pi-Run profile. Saved preferences live in the
selected profile's private `guardian/config.json` and include only the optional
reviewer model and thinking level. Those preferences apply to later sessions.
Legacy schema-1 files remain readable, but their saved mode is ignored and is
removed when preferences are next written.

Activation is session-scoped. Every new session starts Off. `/guardian-mode on`
or `off` appends private extension state to the current session; it is not sent
to the model. Resuming that session restores the latest mode. Mode is operational
session state rather than conversational authority, so branch navigation retains
the latest setting from anywhere in that session. Another session using the same
profile still starts Off.

An unreadable or invalid preference file produces a warning and uses default
reviewer preferences without changing session mode. A failed preference write
leaves the previous model and thinking settings in effect. Profile creation does
not copy Guardian preferences, even though it copies the profile's review policy.

Use `/guardian status` to inspect effective mode, reviewer, thinking, and log
path. `/guardian` opens the settings menu. `/guardian-mode`, with no argument,
opens a selector; `on` and `off` change the current session. `/guardian on` and
`/guardian off` are aliases.

## Reviewer model and thinking

With no model override, Guardian uses the conversation model. Select an available
configured model through:

```text
/guardian-model
```

A direct `/guardian-model <provider>/<model-id>` requires the exact configured
identifier. Return to the conversation model with:

```text
/guardian-model default
```

Select reviewer thinking with `/guardian-thinking`. `default` follows the
conversation setting; an explicit supported value overrides it. The effective
level may be adjusted when the selected model does not support the requested
level.

**Thinking Off does not disable command review.** `/guardian-thinking off`
controls reviewer reasoning effort; `/guardian-mode off` disables the gate.
Model and thinking selectors do not invoke the conversation agent merely by
opening them.

A fixed reviewer is independent of the acting model. Reviewer requests use Pi's
configured provider access and can incur separate latency and cost. Context sent
to the provider can include instructions, command arguments, conversation
excerpts, and bounded file evidence.

## Status row

Guardian owns a muted row below Pi's editor, for example:

```text
guard · reviewing · 4s                       reviewer-model · high
```

The left side reports Off, On, Reviewing, Dispute, or a temporary interruption
state. The right side reports reviewer model and effective thinking, or that the
reviewer is unavailable. Elapsed time appears only during active review;
completed durations remain in retained logs.

Dispute reports `investigating` while the acting agent may make bounded native
file reads, `assessing` during automatic justification review, or `awaiting you`
after assessment, settlement, or read-budget exhaustion. A genuine user message
or `/guardian-resume` returns the row to On; neither event grants authority merely
by clearing the latch.

## Review scope and evidence

During normal operation, only acting-agent calls whose tool name is exactly
`bash` or `run` are reviewed. Aliases, shell-looking arguments to another tool,
and host-terminal commands do not extend normal coverage. When mode is Off,
those calls skip assessment, but the agent's instructions and authorization
obligations still apply.

An open dispute is a separate stop state. It permits at most six direct native
`read` calls during the same agent run and withholds every other acting-agent
tool, including normally uncovered tools, except Guardian's model-only
`guardian_justify` handoff. After justification or settlement, every tool is
blocked until human feedback clears the dispute.

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
`USER_REFUSED` both open a human-arbitrated dispute; the latter records that an
applicable user restriction already exists. Guardian never releases either case
through a confirmation dialog.

The blocked invocation is permanently cancelled. Guardian records and displays
its reason independently, cancels sibling command reviews, and enters the
`investigating` phase. The acting agent can use only the bounded native read
allowance to check file evidence. It then calls `guardian_justify` with a
`retract`, `narrow`, or `contest` position, a bounded explanation, and up to eight
bounded evidence references. Tool variants, edits, writes, commands, nested
tools, and unknown tools cannot route around the latch.

The justification tool is active only while that submission is pending. After
submission it is removed, status changes to `assessing`, and Guardian starts a
fresh bounded reviewer pass over the original blocked action, current authority,
its original concern, and the structured position. The agent's explanation and
references remain untrusted claims. The same source validation, evidence limits,
time limits, and fail-closed transport behavior apply to this pass.

The assessment classifies the position as **Concern resolved** (`ALLOW`),
**Concern remains** (`ASK`), **User restriction remains** (`USER_REFUSED`), or
**Assessment unavailable**. These labels are advisory: none releases or replays
the action. The custom transcript rendering shows the original concern, agent
position, assessment, and reason. Its result uses Pi's terminate signal so the
acting agent cannot automatically continue after submission.

After assessment—or when an agent turn settles without a submission—the dispute
changes to `awaiting-user`. The active branch stores
the open or resolved dispute and any submitted position as private extension
state, excluded from model context. A completed or unavailable assessment is
stored with the position; a cancelled or late assessment cannot be attached
after human feedback resolves the dispute. Resume and branch navigation
reconstruct that branch's state; Guardian mode itself remains session-wide.

A later genuine user message resolves the latch before starting a fresh turn.
`/guardian-resume` also resolves it, but deliberately contributes no authority
and triggers no model turn. Earlier restrictions still apply unless the user
actually changes them. Turning Guardian Off resolves the latch and disables
future review, but never replays the cancelled invocation.

## Unavailable and interrupted review

Missing provider access, timeout, invalid reviewer output, missing instructions,
or another reviewer failure produces no AI decision. During initial review,
Guardian withholds the action and opens a dispute regardless of UI mode. During
justification assessment, it records **Assessment unavailable** and still waits
for the human. It never offers a bypass that releases an unreviewed invocation.

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

`/guardian-log` opens a read-only browser of retained review attempts across the
selected profile's sessions. `/guardian log` is an alias, and
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

Each Pi process writes its own bounded run journal under
`logs/guardian/runs/<run-id>.jsonl*`, with up to two rotated segments at about
1 MiB each. Concurrent sessions do not share a writer lock. `/guardian-log`
merges these runs chronologically and continues to read existing
`guardian/guardian.log*` files; this compatibility does not move or delete them.
After stopping all Pi-Run sessions, migrate those files explicitly from a host
terminal with `pi-run migrate guardian-logs`. The command takes the exclusive
Pi-Run home lock, moves each profile through private restartable staging into
`logs/guardian/legacy/`, and refuses destination collisions or unsafe files.
`guardian.log`, `.1`, and `.2` become `events.jsonl`, `.1`, and `.2`
respectively.
After a clean run closure, best-effort retention targets 64 MiB and 128 run
groups by pruning completed runs oldest first. Active, incomplete, unsafe, and
legacy files are not automatically removed, so the aggregate can temporarily
exceed those targets.
Rotation, partial writes, process interruption, display limits, missing tool
results, and logging failures can create gaps. Logging or retention failure does
not alter a review decision or dispute state.

Treat logs as private. They can contain commands, paths, selected conversation
text, evidence excerpts, model details, and errors. Redaction is best effort,
not proof that arbitrary secrets are absent. Do not put literal secrets in
commands or publish logs without inspection.

[Guardian task guide](../guardian.md) · [Planning](../planning.md) ·
[Security and isolation](../security.md)
