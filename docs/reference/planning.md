# Planning behavior reference

This reference records Planning's draft, revision, export, approval, discard, and
branch behavior. For the normal discuss-save-review-approve workflow, start with
the [Planning task guide](../planning.md).

## Planning mode and goals

`/plan <goal>` discards the previous active draft, enables planning, and sends the
new goal to the agent as a planning-only request. The goal must be nonblank. A
`planning` indicator appears below Pi's editor while the mode is active.

A bare `/plan` enables planning without discarding the current draft or sending
a model request. Use it to continue refining the same goal. Repeating
`/plan <goal>`, even with similar text, starts a new goal rather than updating the
saved draft.

Planning changes the agent's objective, not its selected tools or operating-system
permissions. Guardian review remains independent and keeps its current mode,
reviewer, and thinking settings.

## Draft recording and revision identity

The agent records a draft with the direct-call `plan_record` tool. It is available
only in planning mode and accepts a nonblank title, goal, and full Markdown body.
The complete draft is bounded to 32 KiB. A failed record does not replace the
previous valid revision.

Each successful record creates a new session entry and revision identity while
preserving history. The active saved draft is distinct from conversation text;
changes discussed afterward remain unsaved until another `plan_record` call.
Recording is neither approval nor a workspace file change.

`/plan-show` displays the active branch's saved draft and whether that exact
revision is approved. It does not start a model turn, change planning mode, or
approve content. A missing, discarded, invalid, or unsupported draft cannot be
shown, exported, or approved.

## Export rules

`/plan-export <path.md>` creates a standalone Markdown rendering of the active
saved draft. The path:

- is relative to the current workspace;
- must end in `.md`;
- cannot be absolute or contain `..` traversal;
- cannot pass through symbolic-link components;
- requires an existing parent directory; and
- must name a target that does not already exist.

Spaces can be entered directly in the slash-command argument. Export creates the
file with mode `0600` and an explicit notice that export is not approval. It does
not overwrite, create parent directories, commit, publish, change mode, or start
a model turn.

The exported content does not carry the session's local approval record. Even an
approved draft receives the export-is-not-approval notice. The file is plaintext,
not encrypted by its restrictive permissions.

Export failures are not retried automatically. If publication succeeded but
finalization reported a failure, inspect the target before retrying because the
file may already exist.

## Approval identity and confirmation

`/plan-approve` hashes and identifies the active saved title, goal, and body. Pi
displays the complete draft and asks whether to approve that exact revision.
Cancellation records no approval and sends no handoff.

Approval is rejected when there is no valid active draft or when the session,
branch, draft entry, or plan content changes while confirmation is pending. A
word such as “approved” inside conversation or plan content does not create an
approval record.

On confirmation, Pi appends the local approval record, exits planning, retains
the approved draft, and sends one user-message handoff containing that plan to
the normal agent workflow. The handoff explicitly preserves applicable
`AGENTS.md` checkpoints and does not change Guardian.

Approval is idempotent for the same revision: repeating `/plan-approve`, including
after session resume, exits planning without sending another handoff. Recording
a new revision creates a new identity and requires fresh approval even when its
text is identical.

## Exit and discard behavior

`/plan-exit` takes no arguments. It disables planning and appends a discard marker
for the active branch. The discarded draft can no longer be shown, exported, or
approved there.

Exit does not approve work, send a handoff, start a model turn, delete
conversation history, remove historical branches, or delete exported files. It
can also discard a retained draft after approval, but it cannot undo work that
already occurred.

Use `/plan-exit`, not `/plan off`; any text after `/plan` is interpreted as a new
goal.

## Session and branch behavior

Planning state is session metadata. Mode, revisions, approval records, and
discard markers follow the active branch and survive normal session resume.
Switching to a historical branch can expose that branch's own draft and mode; it
never transfers approval from another revision or branch.

After resume or branch navigation, `/plan-show` is the authoritative user-facing
check for the active saved revision and approval state.

## Unsupported operations and boundaries

Planning provides no plan import, overwrite export, automatic export, or
whole-plan executor. It does not require a particular document structure and
does not itself impose development increment fields, file lists, or diff
estimates; applicable workflow instructions can require those later.

The extension manages only its planning metadata tool and slash commands. Normal
tool availability remains unchanged, so read-only or no-network planning depends
on explicit user instructions and actual runtime permissions.

[Planning task guide](../planning.md) · [Guardian](../guardian.md) ·
[Workspaces and sessions](../workspaces-and-sessions.md)
