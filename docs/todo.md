# Queue future prompts with Todo

Todo is a user-controlled queue for thoughts and requests you want to send later.
It is useful when an agent is still working and you are already thinking about the
next question, correction, or task.

Todo does not send work to an agent, approve an increment, or replace
[planning](planning.md). It prepares text in Pi's normal editor; you still review
and submit that text yourself.

All commands below belong in **Pi's input editor**, not the host shell.

## Open the Todo menu

Enter:

```text
/todo
```

The menu shows the queued prompts for the current conversation. You can open it
while a model response is still running. Creating or managing an item does not
cancel, steer, or submit another request to that model turn.

Choose **New prompt...** to open a multiline editor. The item is saved when you
finish that editor. Empty items are rejected.

## Manage queued prompts

Select an existing item to open its actions:

- **Use as next prompt** loads it into Pi's normal prompt editor.
- **Edit** opens the complete item in a multiline editor.
- **Delete** asks for confirmation before removing it.
- **Move up** and **Move down** change its queue position.
- **Back** returns to the queue without changing the item.

The menu displays each item's stable ID and first non-empty line. Items with the
same visible summary remain separate and independently selectable.

A small `Todo: N` status appears while the current conversation has queued
items. It clears when the last item is deleted. `Todo: unavailable` means the
private state could not be read or safely updated.

## Load the next prompt deliberately

When the normal prompt editor is empty, **Use as next prompt** copies the selected
item into it and closes the Todo menu.

If the editor already contains text, choose one of these actions:

- **Replace editor text** discards the current editor draft and loads the item.
- **Append after editor text** preserves both drafts with a blank-line boundary.
- **Cancel** leaves the editor unchanged and returns to the Todo menu.

Loading text never submits it. Review and edit the resulting prompt, then submit
it through Pi normally when you are ready. Loading also does not remove or mark
the Todo item; deletion remains explicit.

## Understand the session lifecycle

Each Pi conversation has an independent Todo queue:

- Resuming the same saved conversation restores its queue.
- Navigating that conversation's `/tree` branches keeps the same queue.
- A genuinely new conversation starts empty.
- `/fork` and `/clone` create new conversations with empty queues, even though
  conversation history may be copied.
- Other conversations do not appear in the current `/todo` menu.

This is deliberately session-wide rather than branch history. Todo records what
you intend to ask next, not what the model knew at a historical branch point.

## Keep Todo separate from authority and planning

Todo is a private prompt drafting aid, not an execution mechanism:

- Creating, editing, reordering, or selecting an item grants no authority.
- An item is not a Plan draft, Plan approval, roadmap entry, issue, or project
  backlog record.
- Todo does not alter `AGENTS.md`, Guardian, CAF, Plan state, or approval
  identity.
- The extension registers no Todo tool for the model and does not automatically
  inject queued text into model context.

Todo state still belongs to the selected profile. Processes and tools with
access to that profile can access its files, so Todo is not a secret vault or an
isolation boundary. Keep credentials and material unsuitable for the selected
profile out of queued prompts.

## Limits and failure behavior

A conversation may hold at most 100 items. Each item may contain at most 16 KiB
of UTF-8 text. Todo writes private state atomically and refuses malformed,
oversized, broadly permissioned, linked, or otherwise unsafe state instead of
silently replacing it.

When state is unavailable, `/todo` reports the problem without printing queued
prompt contents. Correct the private profile state deliberately before retrying;
do not treat a failure as permission to recreate or discard the queue.

For exact storage, schema, permissions, and failure semantics, see the
[Todo behavior reference](reference/todo.md).

[Documentation index](index.md) · [Getting started](getting-started.md) ·
[Planning](planning.md) · [Workspaces and sessions](workspaces-and-sessions.md)
