# Todo behavior reference

This reference describes the session identity, storage, limits, and failure
semantics behind Pi-Run's `/todo` prompt queue. For normal use, start with the
[Todo task guide](../todo.md).

## Command and model exposure

Pi-Run registers one user command:

```text
/todo
```

It accepts no arguments. The command requires Pi's interactive TUI. It registers
no model-callable tool, adds no system-prompt instructions, and performs no
`before_agent_start` injection. Loading an item calls Pi's editor API only; it
does not create a user message, custom message, steering message, follow-up, or
provider request.

The selected profile remains available to the Pi process and its permitted
tools. Lack of automatic model exposure is not a filesystem confidentiality
boundary.

## Session and branch identity

The queue key is `ctx.sessionManager.getSessionId()`. One in-memory state is
loaded for the current extension runtime and reloaded on session startup.

Branch navigation does not change the session ID and therefore does not roll the
queue backward or forward. New, forked, and cloned sessions receive new session
IDs and do not copy the source queue. Resuming the original session reuses its
original queue.

## Private storage

State is stored under the selected profile:

```text
/profile/todos/<session-id>.json
```

`PI_RUN_PROFILE_DIR` supplies the profile root; normal Pi-Run launches set it to
`/profile`. Session IDs must be UUID-shaped safe path components.

The `todos` directory must be a real directory with no group or other permission
bits. Newly created directories use mode `0700`. State files must be regular,
non-linked files with no group or other permission bits. Newly written files use
mode `0600`.

Writes use a new exclusive temporary file in the same directory, flush its
contents, and atomically rename it over the prior state. A failed write does not
make the unpersisted mutation authoritative; the extension marks Todo
unavailable for that runtime.

The JSON state has this logical shape:

```json
{
  "schemaVersion": 1,
  "sessionId": "session UUID",
  "nextId": 4,
  "items": [
    {"id": 1, "text": "Review the test failure"},
    {"id": 3, "text": "Ask for a smaller alternative"}
  ]
}
```

Item IDs are positive, unique, stable integers. Reordering changes array order,
not IDs. Deletion does not renumber remaining items or reset `nextId`.

Deleting a Pi conversation does not currently remove a matching Todo state file.
The orphan is not selected by another conversation, but it remains private
profile data until that profile data is deliberately cleaned or restored.

## Validation limits

The loader accepts only schema version 1 with the matching session ID. It rejects:

- more than 100 items;
- empty or whitespace-only item text;
- item text over 16 KiB in UTF-8;
- duplicate, unsafe, or out-of-sequence IDs;
- state files over 2 MiB;
- malformed JSON or incompatible schema data;
- unsafe directory, file type, link, or permissions.

A rejected state is not truncated, migrated, reset, or overwritten. The TUI
shows `Todo: unavailable`, and `/todo` reports a bounded error without including
stored item text.

## Editor behavior

Selecting **Use as next prompt** reads Pi's current editor text. An empty editor
is replaced directly. A non-empty editor requires an explicit Replace, Append,
or Cancel selection.

Append preserves both strings and adds only enough newline characters at their
boundary to provide at least one blank line. The command then sets editor text
and returns. It never submits the editor or deletes the item.

## Authority boundary

Todo entries are user-owned draft text. Their existence, position, selection,
or presence in the editor is not authorization to execute them. Normal
conversation instructions, Plan identity, Guardian review, and human approval
checkpoints continue to apply after submission.

[Todo task guide](../todo.md) · [Planning reference](planning.md) ·
[Workspace and session reference](workspaces-and-sessions.md)
