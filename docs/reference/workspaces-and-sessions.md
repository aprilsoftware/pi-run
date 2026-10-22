# Workspaces and Sessions reference

This reference records workspace identity, session discovery, path mapping, and
reconnection behavior. For normal open, continue, list, and resume commands,
start with the [Workspaces and Sessions task guide](../workspaces-and-sessions.md).

## Identity and storage

The first launch of a directory assigns a portable workspace UUID. Registry
metadata lives at:

```text
<Pi-Run home>/workspaces/registry.json
```

Machine-local files under `<Pi-Run home>/machines/` map workspace IDs to paths
and store the automatic-snapshot preference. This state is deliberately excluded
from snapshots. The registry records portable identity and display names; it
does not contain workspace source.

Sessions are grouped by profile and workspace ID:

```text
<Pi-Run home>/profiles/<profile>/sessions/<workspace-id>/*.jsonl
```

A workspace ID, an individual session ID, and a physical session filename are
different values. Workspace commands use the complete workspace UUID. Pi manages
conversation IDs and branches inside the workspace's session directory.

`pi-run machine-id` reports a separate 16-character identifier used for
machine-local state and snapshot provenance. It is not a workspace ID,
authentication secret, or stable identity after relevant machine/user identity
changes.

Registration is directory-based. Different clones or directories are distinct
even when their names and Git remotes match. Pi-Run does not infer identity from
Git metadata for ordinary workspaces.

Managed Git tasks add a machine-local repository UUID keyed by the validated
canonical common Git directory. Each task receives its own portable workspace
UUID and profile-scoped session directory. Repository records store the primary
path, creation time, and named task/workspace/branch associations; authoritative
concrete paths remain in `workspacePaths`.

Managed checkout content lives at:

```text
<Pi-Run home>/worktrees/<repository-id>/<task-name>/
```

Its branch is `pi-run/<task-name>` and Git's linked-worktree administration uses
the task name under the repository's common Git directory. Repository and
workspace UUIDs remain internal identity keys.

Machine repository associations, managed paths, and checkout content
are excluded from snapshots. The portable registry contains no remote URL,
source content, or reconstruction instructions.

## Workspace and session inventory

`workspace list` shows each registered ID, display name, and usable local path.
A stale or missing path can still appear; `-` means there is no usable mapping on
this machine. A workspace can appear without having any sessions.

`session list` scans session groups across every profile and workspace. Statuses
mean:

| Status | Meaning |
| --- | --- |
| `available` | The portable identity has a usable path mapping on this machine. |
| `unavailable` | The identity is registered, but its local path is missing or unusable. |
| `unregistered` | Session files exist for an ID absent from the portable registry. |

Unregistered groups remain visible, but guided reconnection refuses to invent
missing portable metadata.

`session list <workspace-id>` requires the complete UUID and displays every
validated physical session file across profiles: profile, exact session ID,
creation time, latest saved name, and filename. Unnamed sessions display `-`.
Imported files with the same session ID remain separate rows and are
distinguished by filename.

Discovery validates UUID directory names and JSONL session headers. It refuses
unsafe or inconsistent files rather than rewriting or guessing their identity.

## Launch and direct session selection

A normal launch calls `ensure_workspace_registered` for the selected real
workspace path. It creates a portable registry entry and machine mapping only
when no identity is already mapped to that directory.

Pi-Run passes the profile-specific directory for that workspace ID to Pi through
`--session-dir`. `-c` delegates to Pi's continue behavior; `-r` delegates to its
resume selector after any applicable reconnection flow. Pi owns conversation
branching, naming, individual selection, and deletion.

Changing the selected profile changes the session directory and authentication
context. It does not copy conversations or credentials between profiles.

## Managed-worktree selection and creation

`worktree list` is repository-grouped, deterministically sorted, sanitized for
terminal display, and inspection-only. It also shows registered repositories
with no managed children. Its dynamically sized table contains only `TASK`,
`STATE`, `STATUS`, and `CREATED`; repository/workspace UUIDs, internal branch
names, and managed storage paths are omitted from normal output.

Ordinary launches use the selected checkout directly. `worktree start
<task-name> <repository>` explicitly creates one named managed task from the
required repository path. The path may be relative or absolute; `.` selects the
current directory. Additional Pi arguments require a `--` separator. Missing
paths and duplicate or invalid names fail before Git worktree mutation.

Creation accepts a supported non-bare repository with attached or detached
committed `HEAD` and rejects an unborn repository. Pi-Run resolves `HEAD^{commit}`
before creation and reports dirty source state as excluded. It allocates one UUID
and strictly preflights the branch, worktree path, Git administration path, and
metadata. Collisions fail instead of selecting another identity.

The branch is `pi-run/<task-name>`, and both the checkout and linked-worktree
administration directory use `<task-name>` as their final component. Pi-Run first
runs `git worktree add --no-checkout` on the host, then materializes the recorded commit in
a temporary version-matched runtime container. Materialization uses `--pull never`, network
none, the host UID/GID, a read-only root, dropped capabilities,
no-new-privileges, checkout hooks disabled, and no profile, credential, shared,
or Docker-socket mount. Repository content filters may run only inside that
container; missing dependencies fail creation without a host fallback.

Portable metadata is published only after the machine path and repository
association. A machine-only association can therefore appear as `pending` after
interruption. Completion is allowed only when the exact recorded Git and
metadata relationship still validates. Conflicting, partial, moved, or
registry-only state fails closed. Creation rollback removes only provably new,
empty, unchanged state from that invocation; ambiguous state is preserved.

`worktree list` statuses are:

| Status | Meaning |
| --- | --- |
| `available` | Expected path, portable record, ownership, Git administration, common directory, and branch validate. |
| `missing` | Expected mapped checkout path does not exist. |
| `pending` | Complete machine association exists without its portable workspace entry. |
| `path-conflict` | Authoritative path mapping differs from the required managed path. |
| `git-conflict` | The safe path exists but its common directory, administration directory, or branch differs. |
| `unsafe` | Repository, path, ownership, symlink, hard-link, permission, or administration checks prevent trusted inspection. |
| `archived` | A finished historical task intentionally has no concrete path. |

Normal listing excludes `finished` tasks; `worktree list --all` includes them.
The separate `STATE` column distinguishes `active`, recoverable `finishing`, and
historical `finished` lifecycle records. Status computation still validates the
hidden path, identity, Git administration, and branch relationships before
printing each compact row.

Metadata-level contradictions that cannot be represented safely fail the whole
command rather than being reduced to a row status. Existing schema-version-1
machine metadata is listed as having no managed repositories without mutation.
The first task creation adds an empty `repositories` array atomically while
retaining schema version 1 and preserving existing machine settings and direct
workspace mappings.

## Managed continuation and locking

`worktree open <task-name> <repository>` resolves the required relative or
absolute repository path and then requires exactly one active task with that
name. It validates the recorded path, portable identity, branch, Git
administration, common directory, and current commit without creating or
changing Git or metadata.
Missing, ambiguous, unavailable, or conflicting state fails before Docker starts.

With no selector, `open` starts a fresh conversation in the task's selected-profile
session directory. `-c` and `--continue` delegate newest-conversation continuation
to Pi in that directory; `-r` and `--resume` delegate task-local transcript
selection. At most one continuation selector is accepted. No transcript activity
is used to choose among tasks.

Managed startup identifies the selected profile and task and reports only the
current task revision. Internal workspace identity, branch, and host path remain
available to validation logic but are not printed.

Global resume is association-driven. Selecting a managed group reopens its
immutable recorded path and
uses managed Git mounts; selecting an ordinary group keeps direct behavior. A
known managed group unavailable on this machine is never silently reconnected
as an ordinary checkout.

Each managed launch holds a private machine-local lock through Pi execution,
snapshot-requested restarts, egress-sidecar lifetime, and final cleanup. The
owner records machine ID, PID, Linux process-start token, random ownership token,
workspace ID, and creation time. A matching live owner blocks launch. Only a
well-formed same-machine record with an absent PID or changed start token is
recovered as stale; Pi-Run never signals the process. Ownership-token mismatch,
foreign-machine, malformed, linked, or ambiguous lock state fails closed.
Different managed task workspace UUIDs can run concurrently.

## Managed task finish

`worktree finish <task-name>` must run from the checkout whose attached branch
should receive the task, not from the task checkout itself. It acquires the
task's launch lock and revalidates both checkouts. Its confirmation displays the
task name, human-readable target branch, commit count, task changes, and ignored
task paths; internal workspace identifiers and storage paths are not part of the
normal finish interface.

Before confirmation, Pi-Run inspects the task in a version-matched runtime
container with network none, a read-only root, read-only source and common-Git
mounts, no capabilities, no-new-privileges, Git hooks and filesystem monitoring
disabled, and no profiles or credentials. It reports tracked and non-ignored
untracked changes that will be committed and ignored paths that will be discarded
with the checkout. Submodules and nested repositories remain refusals.

After the user types the complete task name, Pi-Run revalidates the displayed
state and commits all tracked and non-ignored untracked changes as `Complete task
<task-name>` in the restricted runtime. Ignored content is never added to that
commit. A commit failure leaves the task active. When commits need integration,
the target must have no tracked modifications. Pi-Run enumerates changed task
paths and actual untracked and ignored target paths, refusing exact or
parent/child overlap before merge. Unrelated target-local content is normal
machine-local state and remains untouched. If the task is already integrated, no target
working-content inspection or merge occurs.

Pi-Run merges in the same restricted environment. It fast-forwards when possible
and otherwise creates a normal unsigned merge commit using the user's resolved
Git identity. Merge failure or conflicts trigger `git merge --abort`; Pi-Run
verifies the original target commit and tracked working state before reporting
that the task remains active. An unverifiable rollback fails closed for manual target
inspection.

After successful integration, finish revalidates and removes exactly the ignored
task content disclosed at confirmation, transitions `active` to `finishing`,
removes the now-clean checkout with non-force `git worktree remove`, and deletes
the integrated local task branch with non-force `git branch -d`. Once checkout
and branch cleanup are complete, it removes the machine path
mapping and marks the task `finished` with a timestamp. A retry may continue an
exact `finishing` record after partial cleanup. Missing-active or conflicting
state fails closed.

The portable workspace registry entry and every profile's conversation files
remain unchanged as historical records. Finish never fetches, pushes,
force-deletes, or deletes a remote branch. Finished tasks cannot be opened or
resumed as live workspaces. Ordinary launch and exit never imply finish or
integration.

## Resume across workspaces

`pi-run resume` builds groups from saved session files, not from empty workspace
registrations. The interactive host menu selects a profile/workspace group. If
its path is available, Pi-Run mounts that workspace and profile and opens Pi's
native resume selector.

`pi-run resume <profile> <workspace-id>` selects an exact group but remains an
interactive Pi launch. It does not provide a headless session API. The group must
exist and contain saved sessions. An unavailable exact group requires an
interactive terminal for reconnection.

Resume selection does not change the home-level default profile. Session names,
branches, and deletion remain Pi behavior, and Pi-Run does not rewrite JSONL.

## Manual workspace linking

`workspace link <workspace-id> <path>` requires a registered full UUID and an
existing directory. It replaces the machine-local path for that identity without
changing the registry entry or session files.

Manual linking refuses a destination already registered under another identity,
even when that other identity has no sessions. This conservative command does
not delete placeholder registrations or merge identities. Use guided restored
session reconnection for the narrowly validated placeholder case.

Launching a moved directory before linking can register a new identity. Link the
original ID first when the move is known.

## Guided restored-session reconnection

Snapshots restore the portable registry and session groups but not local path
mappings or source directories. Interactive `pi-run resume` can reconnect an
`unavailable` registered group to an existing directory after displaying the
profile, workspace, session count, and proposed path for confirmation.

If that path is already mapped to a different current identity, guided
reconnection can replace it only when the current identity has no session state
in any profile. It removes that unused placeholder mapping/registration while
preserving the restored identity, checkout files, and sessions. Any existing
session state under the current identity causes refusal.

The operation also refuses missing restored registry metadata, invalid paths,
ambiguous/conflicting mappings, or absent confirmation. Cancellation leaves the
mapping unchanged.

## Same-name `-r` shortcut

From a newly registered checkout, `pi-run . -r` can search the selected profile
for `unavailable` groups with the same workspace display name when the current
identity has no session state.

One candidate is proposed directly; multiple candidates require selection. The
name is only a hint, and confirmation is always required. On success, Pi-Run
reconnects the restored identity and opens Pi's selector. Declining changes
nothing.

The shortcut requires an interactive terminal, matching name, selected-profile
sessions, and an empty current identity. `-c` never invokes this flow. If no safe
candidate exists, normal resume behavior continues for the current workspace.

## Privacy and recovery boundaries

Session JSONL can retain user prompts, model responses, source excerpts, tool
arguments, output, paths, and secrets. It belongs to the private profile and is
included in complete encrypted snapshots.

Restoring sessions does not restore workspace source or remote-system state.
Reconnection attaches an existing local directory to a portable ordinary
identity; it never creates, clones, resets, or validates the contents as the
original checkout. Known managed associations are not eligible for this direct
reconnection path: their machine-local repository association and exact
worktree must already validate.

Use launcher commands for mapping changes. Manual edits to registry, machine, or
session files can create unregistered groups, duplicate IDs, or unsafe metadata
that automatic recovery deliberately refuses.

[Workspaces and Sessions task guide](../workspaces-and-sessions.md) ·
[Snapshots](../snapshots.md) · [Profiles](../profiles.md)
