# Workspaces and sessions

Pi-Run keeps conversations connected to a stable workspace identity. You can
close the terminal, resume later, find work across profiles, move a checkout, or
reconnect restored sessions without copying or editing conversation files.

A **workspace** is the host directory selected for Pi-Run. A **session** is a
saved Pi conversation for that workspace and profile.

Run `pi-run` commands in your **host terminal**. Slash commands such as `/name`
belong in **Pi's input editor**.

## Open, continue, or choose a session

Open the current directory as a workspace:

```bash
pi-run .
```

The first launch registers the directory and mounts it read-write at
`/workspace`. It can be a source checkout or a directory of operational scripts
and documents.

Continue the latest saved conversation for this workspace and profile:

```bash
pi-run . -c
```

Choose from saved conversations for the same workspace and profile:

```bash
pi-run . -r
```

Select another existing profile for one run when needed:

```bash
pi-run --profile operations . -r
```

Sessions and credentials belong to their profile. If an expected conversation is
missing, first check the selected profile, data home, and workspace path.

Inside Pi, give useful work a recognizable name and leave normally:

```text
/name Investigate service startup
/quit
```

Normal sessions save automatically. An explicitly ephemeral Pi run cannot be
resumed, and saved sessions are not a backup.

## Understand the identities

Pi-Run assigns each registered directory a stable workspace ID, so conversations
are not tied only to its absolute path. Separate clones and directories receive
separate identities even when names or Git remotes match.

You normally do not need to manage IDs directly. They become useful when listing
work, relinking a moved directory, or diagnosing restored state. See the
[identity reference](reference/workspaces-and-sessions.md#identity-and-storage)
for storage paths and identifier differences.

## Use managed Git worktrees

Managed worktrees let separate Pi-Run sessions use independent branches,
indexes, and working files from one normal non-bare Git repository. They are
persistent, host-visible source checkouts—not temporary container state and not
a security boundary.

Create one explicitly named managed task for a selected repository:

```bash
pi-run worktree start api-refactor .
```

The repository argument is required and accepts `.` or another relative or
absolute repository path. Ordinary launches use the selected checkout directly.
Task names begin with a lowercase letter or digit, contain only lowercase
letters, digits, `.`, `_`, or
`-`, are at most 63 characters, and are unique within the repository. Separate
clones remain separate repository identities even when their remotes match.

A task start records the selected checkout's exact committed `HEAD`, creates the
branch `pi-run/<task-name>`, and places the checkout at:

```text
<Pi-Run home>/worktrees/<repository-id>/<task-name>/
```

The task name is the persistent worktree identity. Repository and workspace UUIDs
remain internal and are not shown by normal startup or task-list output.

Attached and detached committed `HEAD` are accepted; an unborn repository is
not. Dirty source state is allowed, but staged, modified, untracked, and other
uncommitted changes are excluded from the new checkout. Pi-Run does not stash,
copy, commit, clean, reset, merge, rebase, push, remove worktrees, or delete
branches automatically.

Open an existing task by naming the same repository explicitly:

```bash
pi-run worktree open api-refactor .
pi-run worktree open api-refactor . -c
pi-run worktree open api-refactor . -r
```

The required repository path may be supplied from inside or outside the
repository. Without a selector, `open` starts a fresh Pi conversation in the
existing task. `-c` continues that task's newest conversation for the selected profile, and
`-r` opens Pi's selector for that task. Open never creates another branch,
worktree, workspace identity, or metadata record. Global `pi-run resume` also follows a
selected task's immutable machine association and never reconnects it as an
ordinary checkout.

Startup reports the selected profile, task name, and current task revision. It
does not print the internal workspace identity, branch name, or storage path.

Only one Pi-Run process may use a managed task at a time. A private machine-local
ownership lock detects active use and safely recovers only well-formed stale
records. Different tasks may run concurrently.

Inspect registered repositories and unfinished managed tasks from any directory.
Include finished task history with `--all`:

```bash
pi-run worktree list
pi-run worktree list --all
```

The compact, dynamically aligned table reports only `TASK`, `STATE`, `STATUS`,
and `CREATED`. Repository and workspace UUIDs, internal branches, and managed
storage paths are intentionally omitted.

Statuses mean:

| Status | Meaning |
| --- | --- |
| `available` | Path, portable identity, branch, and Git administration match. |
| `missing` | The recorded managed checkout is absent. |
| `pending` | Machine association exists, but portable publication is incomplete. |
| `path-conflict` | The mapped path is not the required managed path. |
| `git-conflict` | The present checkout does not match recorded Git state. |
| `unsafe` | Ownership, links, or filesystem structure are unsafe to trust. |
| `archived` | A finished task is historical and has no managed checkout path. |

Finish a task from the checkout whose current branch should receive its work:

```bash
pi-run worktree finish api-refactor
```

Finish shows the task name, target branch, and number of commits to integrate;
internal workspace identifiers and storage paths are omitted. It proposes a
local merge, managed-checkout removal, and local task-branch deletion, then
requires typing the complete task name. Both checkouts must be clean, including
ignored and nested-repository content, and the target must have an attached
branch. Pi-Run also refuses active use, unsafe or conflicting metadata, and
submodules.

Inspection and merge run in an offline restricted runtime container without
profile credentials and with Git hooks disabled. A task that is ahead of the
target is fast-forwarded when possible; diverged non-conflicting work creates a
normal merge commit. A conflicting or failed merge is aborted and the target is
verified restored before Pi-Run reports a recoverable refusal. Only after
successful integration does Pi-Run remove the linked checkout and delete its
local branch without force. It never fetches, pushes, or deletes a remote
branch.

Portable workspace identity and every profile's conversations remain as
historical records. An interrupted `finishing` cleanup is shown by normal
listing and can be retried. Pi-Run never infers finish from exit or session
activity.

Managed source trees and machine associations are excluded from encrypted
snapshots. Portable identities and sessions can be restored, but Pi-Run does not
recreate a repository, branch, or worktree from names or remotes. If this
machine still records the managed association but its checkout is unavailable,
resume refuses to reconnect it as an ordinary workspace. On a machine without
that association, restored portable metadata alone cannot prove or reconstruct
the former managed layout.

## List workspaces and saved conversations

```bash
pi-run workspace list
pi-run session list
```

`workspace list` shows known workspace identities and their path on this machine.
`session list` finds conversation groups across all profiles, including restored
groups whose checkout is not yet connected.

To inspect individual conversations for one workspace, copy its complete
workspace ID from the list:

```bash
workspace_id='paste-the-complete-workspace-UUID-here'
pi-run session list "$workspace_id"
```

The detailed list includes profile, session ID, creation time, saved name, and
filename. Listing does not move directories, open Pi, or change sessions.

## Resume across workspaces

Use the guided resume menu when you are not already in the intended directory:

```bash
pi-run resume
```

Choose a profile/workspace group on the host, then choose the conversation in
Pi's native resume selector. This does not change the saved default profile.

If you already know an available group's profile and complete workspace ID:

```bash
workspace_id='paste-the-complete-workspace-UUID-here'
pi-run resume operations "$workspace_id"
```

Resume remains interactive even with explicit arguments. Pi handles individual
conversation selection, branching, naming, and deletion.

## Relink a moved directory

When a workspace moved on the same machine, find its original ID with
`workspace list`, then connect that identity to the directory's new location:

```bash
workspace_id='paste-the-original-workspace-UUID-here'
pi-run workspace link "$workspace_id" /new/path/to/project
```

The destination must already exist. Linking updates the machine-local path; it
does not move files, merge conversations, or change the portable workspace ID.
Do this before launching the moved directory so it is not registered as a new
workspace.

## Reconnect restored sessions

[Encrypted snapshots](snapshots.md) include workspace identities and sessions,
but not source directories or machine-local paths. Prepare the checkout or
working directory separately, then run:

```bash
pi-run resume
```

Choose an `unavailable` restored group, enter its directory, and confirm the
mapping. Pi-Run preserves the restored conversations and opens Pi's session
selector.

From an already prepared directory, this can offer the same guided reconnection:

```bash
pi-run . -r
```

The shortcut is offered only when the selected profile has matching unavailable
work and the current workspace has no session state. Check the proposed group;
a matching directory name is a suggestion, not proof of identity. `-c` does not
request reconnection.

If a restored group is `unregistered`, its portable registry identity is missing
and guided reconnection cannot repair it automatically. Inspect the selected
data home and snapshot metadata rather than inventing an ID.

## Essential boundaries

- The selected workspace is a real writable host directory.
- Profile choice determines which sessions and credentials are available.
- Workspace registration does not clone, move, restore, or back up source files.
- Managed worktrees isolate checkout files and indexes, but share Git objects,
  refs, configuration, hooks, remotes, credentials, and repository-wide effects.
- Session files can contain prompts, source excerpts, commands, tool output, and
  secrets; keep profiles private.
- Use encrypted snapshots for portable Pi-Run state and version control or an
  appropriate backup for workspace content.
- Use Pi-Run commands rather than editing registry, mapping, or session JSONL to
  repair identity problems.

For storage layout, status meanings, conflict rules, direct-resume behavior, and
reconnection eligibility, see the
[Workspaces and Sessions reference](reference/workspaces-and-sessions.md).

[Documentation index](index.md) · [Profiles](profiles.md) ·
[Getting started](getting-started.md)
