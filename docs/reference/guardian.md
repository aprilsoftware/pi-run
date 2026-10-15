# Guardian behavior reference

This reference records Guardian preference, reviewer, evidence, confirmation,
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

The left side reports Off, On, Reviewing, Needs approval, Paused, or a temporary
interruption state. The right side reports reviewer model and effective thinking,
or that the reviewer is unavailable. Elapsed time appears only during active
review; completed durations remain in retained logs.

Needs approval means a confirmation dialog is pending. After an allowed,
withheld, or approved invocation, the row returns to On. Declining or dismissing
a confirmation leaves covered commands Paused until later user input reopens
normal review.

## Review scope and evidence

Only acting-agent calls whose tool name is exactly `bash` or `run` are guarded.
Aliases, shell-looking arguments to another tool, and host-terminal commands do
not extend coverage. When mode is Off, those calls skip assessment, but the
agent's instructions and authorization obligations still apply.

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

## Review outcomes and confirmation lifecycle

A valid decision can allow the invocation, request one-time confirmation, or
withhold it because of an existing restriction. Guardian does not ask the user
to approve against an explicit applicable restriction.

Long actions require opening the complete action before a Run once choice is
offered. Confirmation applies to the displayed invocation only. Conversation,
settings, branch, action, or proposal changes can invalidate a pending review or
dialog and never release the old invocation automatically.

A declined or dismissed dialog withholds that call, aborts other in-flight
covered review work, and pauses later `bash`/`run` calls in the same run. The
acting agent can still respond with text, and uncovered tools remain outside the
gate. Turning Guardian Off does not replay the cancelled invocation.

A later genuine user message clears the runtime pause for new review. No special
phrase or new session is required. Earlier restrictions still apply unless the
user actually changes them, and the cancelled invocation remains cancelled.

## Unavailable and interrupted review

Missing provider access, timeout, invalid reviewer output, missing instructions,
or another reviewer failure produces no AI decision. With interactive
confirmation, Guardian asks “Run once without review?” and records any approval
as a human bypass of incomplete review. Without confirmation UI, the action is
withheld.

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

Summary separates review outcome and basis, human confirmation, Guardian release
or withholding, and execution result. Command and evidence are bounded,
best-effort-redacted previews; they may omit fields, suffixes, output, or
original messages. Timeline records meaningful model, evidence, decision,
confirmation, release, and result events.

The browser cannot run or approve commands, change mode, fetch missing
conversation content, or reconstruct data no longer retained. It requires Pi's
terminal UI. An execution confirmation takes priority and closes or prevents the
log browser.

Logs use `guardian/guardian.log` plus two rotated backups, `.1` and `.2`, at
about 1 MiB each. Rotation, partial writes, process interruption, display limits,
missing tool results, and logging failures can create gaps. Logging failure does
not alter a review decision or confirmation choice.

Treat logs as private. They can contain commands, paths, selected conversation
text, evidence excerpts, model details, and errors. Redaction is best effort,
not proof that arbitrary secrets are absent. Do not put literal secrets in
commands or publish logs without inspection.

[Guardian task guide](../guardian.md) · [Planning](../planning.md) ·
[Security and isolation](../security.md)
