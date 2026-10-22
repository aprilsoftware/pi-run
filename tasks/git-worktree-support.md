# Managed Git worktrees for explicit parallel tasks

## Status and purpose

The first v0.8 prerelease prototype is implemented and validated, but user
validation rejected its automatic repository mode. It incorrectly treated a
fresh Pi conversation as a request for a fresh worktree and branch. This record
defines the task-oriented replacement. Named task start, open, finish, and
historical listing are now implemented.

A worktree is the filesystem and branch context for one explicitly named
parallel task. It may contain many Pi conversations over its lifetime. Ordinary
Pi-Run launches remain attached to the checkout the user selected and never
create a worktree implicitly.

Git worktrees provide change isolation, not a security boundary. They cannot
safely provide independent working files while several worktrees update the same
checked-out branch. Tasks therefore use separate branches and share Git objects,
refs, configuration, hooks, remotes, credentials, and external systems.

## Selected user model

Ordinary direct-checkout behavior remains familiar:

```bash
pi-run .
pi-run . -c
pi-run . -r
```

The selected complete workflow uses explicit named tasks:

```bash
pi-run worktree start <task-name> <repository>
pi-run worktree open <task-name> <repository>
pi-run worktree open <task-name> <repository> -c
pi-run worktree open <task-name> <repository> -r
pi-run worktree list
pi-run worktree list --all
pi-run worktree finish <task-name>
```

`start`, `open`, `finish`, bare `list`, and historical `list --all` are
implemented. `start` and `open` require a relative or absolute repository path;
`.` selects the current directory. `finish` resolves the repository containing
the current host directory. Task names are unique within that machine-local
repository and use a short validated command-line spelling rather than exposing
UUIDs as the normal user interface. Profiles continue to select credentials,
instructions, skills, settings, and conversations; they do not create or
identify source worktrees.

`start` is the only ordinary operation that creates a worktree. `open` always
uses the named existing task and starts a fresh Pi conversation unless `-c` or
`-r` is supplied. Any number of profile-scoped Pi conversations can therefore
belong to one task without allocating more branches or checkouts.

The replacement removes repository `enable`, `disable`, and `status` preferences
and removes the `--worktree` and `--no-worktree` launch overrides. Worktree use
is neither a repository default nor an automatic consequence of starting Pi.
Existing direct sessions remain direct, and ordinary launches never migrate
between direct and managed source contexts.

Startup and listing report editor-neutral facts only: task name, full workspace
UUID, branch, generic host path, and relevant state. Pi-Run does not launch,
configure, or print commands for a particular editor.

## Identity model

The current workspace UUID remains the identity of one concrete writable
directory. Every task receives one workspace UUID, one worktree, one branch, and
one profile-scoped session directory per profile.

```text
repository identity
├── primary direct workspace identity
├── named task A → managed workspace identity A
│   ├── profile session group
│   └── multiple Pi conversations
└── named task B → managed workspace identity B
    ├── profile session group
    └── multiple Pi conversations
```

The repository association must not collapse tasks into the primary workspace
UUID or allocate a task for each JSONL file. Pi owns individual conversation IDs
and conversation branches inside the task workspace's session directory. The
durable association is one named task to one worktree and workspace UUID to many
related Pi conversations.

Each repository receives a random UUID on the current machine. Its canonical,
validated Git common directory is the local uniqueness key. A remote URL is not
required and does not establish identity: separate clones remain separate
repositories even when they share a remote.

Repository identity and managed-workspace associations are machine-local. The
existing portable workspace registry continues to identify workspace identities
and session groups without claiming that a source repository or its worktrees
can be reconstructed on another machine.

## Task start, open, and resume behavior

Starting a named task must:

1. validate the task name and reject duplicates in the selected repository;
2. validate a supported non-bare Git repository and its common Git directory;
3. resolve the selected checkout's `HEAD` to one exact commit and inspect its
   working state;
4. allocate one workspace UUID and preflight its task name, branch, checkout
   path, Git administration path, and metadata associations;
5. create the dedicated branch and host-visible worktree at the recorded commit;
6. publish the workspace registration, path mapping, and task association using
   the recoverable metadata transaction; and
7. launch a fresh Pi conversation with that task mounted at `/workspace`.

New branches use a meaningful validated form such as
`pi-run/<task-name>/<workspace-uuid>`. Managed checkout storage remains
`<Pi-Run home>/worktrees/<repository-id>/<workspace-id>/`. The UUID is generated
once. Any collision involving the task name, UUID, branch, checkout path, Git
administration path, registry, or machine metadata fails without silently
selecting another identity.

`open` resolves exactly one active task by name in the current repository. It
never creates a branch or checkout. Without a selector it starts another Pi
conversation in the same task workspace; `-c` continues the newest conversation
for the selected profile, and `-r` delegates selection among that task's
conversations to Pi. Missing, finished, active elsewhere, or ambiguous task state
fails before Docker starts.

Every managed launch reports the selected profile, task name, and current task
revision. Workspace UUIDs, internal branches, and managed storage paths remain
validation details and are not part of normal startup output. No automatic
selection by newest transcript occurs across tasks because the user has already
named the source context.

Interactive and explicit global `pi-run resume` remain association-driven. A
selected active task reopens its exact worktree and acquires its launch lock. A
finished task is historical and cannot be resumed as though its checkout still
exists. Direct sessions remain direct and are never migrated automatically.

## Concurrency

Only one active Pi-Run process may use a particular managed worktree. Every
fresh or resumed managed launch acquires a machine-local lock at:

```text
<Pi-Run home>/worktrees/.launch-locks/<workspace-id>/owner.json
```

The owner record contains the machine ID, PID, Linux `/proc` process start token,
a random lock-ownership token, workspace ID, and UTC creation time. The lock
root and workspace lock directories are ordinary private directories owned by
the current user; the owner file is an ordinary private file. Linked,
hard-linked, wrong-owner, unexpectedly permissive, wrong-machine, malformed, or
incomplete state fails closed.

A matching live PID and process start token produces a clear already-active
failure. A well-formed same-machine owner is stale only when its PID is absent or
its current `/proc` start token differs. Pi-Run may atomically rename that lock
directory, remove the renamed stale state, and retry acquisition. Missing or
ambiguous owner state is never treated as stale. Pi-Run does not signal or
terminate the recorded process.

Release removes a lock only when its random ownership token still matches the
owner file. The lock remains held through Pi execution, snapshot-requested
restarts, restricted-egress sidecar lifetime, and final launch cleanup. Abrupt
process death can leave a stale directory, which the validated acquisition path
recovers on a later launch. Different managed worktrees may run concurrently.

Git supplies locks for common repository metadata, but that does not make every
cross-worktree operation safe. Pi-Run must not run automatic repository-wide
maintenance, pruning, branch deletion, rebasing, merging, pushing, or force
operations during ordinary launch or exit.

Worktrees do not isolate shared build caches, databases, service ports,
credentials, network authority, remote repositories, or files outside the
selected checkout.

## Task finish behavior

Normal Pi exit suspends a task; it does not mean the work is complete. A task
remains open across terminal closure, failed runs, snapshot restarts, and any
number of Pi conversations until the user explicitly runs from the intended
integration checkout:

```bash
pi-run worktree finish <task-name>
```

`finish` presents the task name, attached target branch, and number of task
commits not yet in that target. It deliberately omits internal workspace IDs and
storage paths. The confirmation proposes one understandable outcome: integrate
the task, remove its managed checkout, and delete its local task branch. Typing
the complete task name authorizes that bounded local workflow.

The task and target checkouts must both be clean, including ignored and nested
content. Pi-Run refuses active or ambiguous launch locks, unsafe or conflicting
metadata, a missing active checkout, Git administration mismatch, submodules,
or a detached target. Inspection and merge run in a version-matched offline,
capability-free runtime without profiles or credentials and with Git hooks
disabled, so repository code is not executed on the host merely to decide or
perform integration.

Finish uses fast-forward integration when possible and a normal unsigned merge
commit for non-conflicting divergence. On conflict or merge failure, it aborts
the merge and verifies the target's original commit and clean status. Verified
rollback leaves the task active; unverifiable target state fails closed for
manual inspection. Pi-Run does not fetch or push.

Only successful integration transitions the task to `finishing`. Pi-Run then
removes the linked checkout, non-force deletes the integrated local task branch,
removes the concrete path mapping, and marks the task `finished`. Portable
workspace identity and every profile's conversation history remain as historical
records. Normal `worktree list` shows open tasks; `worktree list --all` also
shows finished task metadata without claiming that a checkout exists.

Finish remains a recoverable state transition rather than an uncoordinated
sequence of Git and JSON changes. An interruption leaves an explicit `finishing`
state that a validated retry may complete. It never force-deletes, deletes a
remote branch, rebases, resets, discards source changes, or infers completion
from `/quit`, transcript absence, cleanliness, or an inactive lock.

## Source checkout and base revision

A linked worktree starts from a commit and cannot inherit uncommitted checkout
changes safely. Pi-Run resolves the selected checkout's `HEAD^{commit}` before
creating anything and uses that full commit ID as the base. Attached and
detached `HEAD` are accepted when they resolve to a commit; an unborn repository
is rejected.

A dirty selected checkout is allowed. Before creation, Pi-Run reports that its
modified, staged, untracked, or other uncommitted state is excluded and that the
managed worktree begins at the displayed commit. Pi-Run must never stash, copy,
commit, reset, clean, or discard source-checkout changes automatically.

Existing managed worktrees retain their current branch state when the source
branch advances. Pi-Run must not automatically rebase or merge them.

Submodules, nested repositories, and Git-LFS-specific behavior require explicit
support decisions rather than accidental acceptance.

## Creation failure and interruption

All paths, refs, identities, metadata relationships, and ownership requirements
are preflighted before `git worktree add` runs. Portable and machine-local
metadata is published only after Git successfully creates the new branch and
worktree.

On an ordinary creation failure, Pi-Run may roll back only the branch, worktree,
and empty private parent directories created by that invocation. Rollback first
verifies that the worktree remains at the recorded base commit, has no tracked
or untracked changes, still uses the expected administration directory, and has
not been published in metadata. Pre-existing or ambiguous state is never
removed as cleanup.

An interruption can leave Git state without published Pi-Run metadata. A later
operation must detect the branch, path, or administration collision and report
it for explicit recovery. It must not reuse the UUID, register the partial state,
or delete it speculatively. Recovery and removal commands remain separate
future work.

## Storage location

Managed worktree checkouts live under a private machine-local root:

```text
<Pi-Run home>/worktrees/<repository-id>/<workspace-id>/
```

Repository and workspace IDs are complete lowercase UUIDs. The root and its
managed descendants must be ordinary non-symlink directories owned by the host
user. Creation uses private permissions and refuses existing, linked, special,
or ambiguously mapped paths. The location remains inspectable from the host and
supports ordinary Git commands; worktree content is not container-only or
ephemeral.

The primary checkout and shared common Git directory remain at their existing
host locations. Only managed checkout files live under the Pi-Run worktree root;
Git's linked-worktree administration remains beneath the validated common Git
directory.

The managed root is source state, not Pi-Run portable state. Complete snapshots
must not mount or archive it and should identify `worktrees` explicitly among
excluded paths once the root exists. Git or a separate workspace backup remains
responsible for tracked and untracked checkout content.

After snapshot restore, portable workspace registrations and profile sessions
remain available, but machine mappings and repository associations do not.
Managed groups therefore appear unavailable until an existing checkout is
explicitly reconnected. Pi-Run must not recreate a branch, clone, or worktree
from restored names, remotes, or paths.

## Machine-local metadata

The task-oriented machine file uses schema version 3:

```json
{
  "schemaVersion": 3,
  "machineId": "<machine-id>",
  "snapshotAuto": {"onSessionExit": true},
  "workspacePaths": [
    {"workspaceId": "<workspace-uuid>", "path": "<canonical-host-path>"}
  ],
  "repositories": [
    {
      "id": "<repository-uuid>",
      "name": "<display-name>",
      "commonGitDir": "<canonical-host-path>",
      "primaryPath": "<canonical-host-path>",
      "createdAt": "<UTC-timestamp>",
      "tasks": [
        {
          "name": "<task-name>",
          "workspaceId": "<workspace-uuid>",
          "branch": "pi-run/<task-name>/<workspace-uuid>",
          "state": "active",
          "createdAt": "<UTC-timestamp>",
          "finishedAt": null
        }
      ]
    }
  ]
}
```

`snapshotAuto` is optional and retains the existing machine-local
successful-exit snapshot preference. `workspacePaths` remains authoritative for
concrete active or finishing paths; task records relate names, workspaces, and
branches without duplicating paths. `active` and `finishing` tasks require an
exact path mapping and a null `finishedAt`; `finished` tasks require a timestamp
and no path mapping. No source content, remote URL, credential, commit contents,
Git configuration, or editor state enters the machine file.

Repository IDs, workspace IDs, branches, canonical common Git directories, and
task names within each repository are unique. Task names and branch names are
validated before use; display text is sanitized; paths are canonical absolute
host paths and are never interpreted as authorization to mount an unrelated
target.

When task creation first needs a schema-version-1 machine file, Pi-Run performs
a locked atomic migration that preserves `machineId`, `workspacePaths`, and
optional `snapshotAuto`, adds an empty `repositories` array, writes schema
version 3, and publishes the replacement only after complete validation.
Invalid, linked, hard-linked, unexpectedly permissive, or unsupported machine
files fail without partial migration.

The task-oriented replacement does not migrate this prerelease schema. v0.8.0
and v0.8.1 are unsupported prototype upgrade sources, and their prerelease
artifacts are to be withdrawn. Before installing the replacement, the operator
performs a one-time inspected cleanup: remove clean linked worktrees through Git,
optionally delete their branches, remove their registry and profile-session
records, then remove the prototype machine file and managed-worktree root. Exact
commands must be derived from the machine's validated metadata so direct
workspaces, sessions, and unrelated repositories are not selected accidentally.

The replacement initializes its task metadata from clean state. Encountering
prototype metadata fails closed with a cleanup-required error; Pi-Run does not
ship permanent compatibility or schema-migration code for withdrawn prereleases.

Machine files and the managed worktree root remain excluded from portable
snapshots. The portable workspace registry schema does not need to change for
this metadata foundation.

## Metadata publication transaction

The portable registry and machine file cannot be replaced atomically together.
Managed-worktree publication therefore uses a recoverable ordered transaction
while holding the workspace registry lock. After revalidating the worktree's
repository, path, Git administration, and branch, Pi-Run atomically adds its
`workspacePaths` and named `tasks` records together in the machine file. That
complete machine association is the durable local publication marker. Pi-Run
then atomically publishes the portable `kind: "git"` workspace entry with the
same workspace ID, repository-and-task display name, and creation timestamp.
Pi must not launch until both files validate.

An interruption after machine publication can leave a machine-only pending
association. Retrying publication may complete its missing portable entry only
when the exact worktree, repository, branch, path, and timestamp relationship
still validates. A matching completed publication is idempotent and does not
rewrite either file. Registry-only, incomplete, duplicate, moved, missing, or
conflicting state fails closed and is not repaired by inference.

Pending machine metadata is preserved rather than rolled back speculatively.
It remains machine-local and is ignored by ordinary portable workspace listing
until the registry entry exists. No publication or recovery step changes Git
branches, indexes, commits, working files, or linked-worktree administration.

## Container Git metadata

A linked worktree contains a `.git` file pointing to administration data beneath
the primary repository's common Git directory. Mounting only the selected
worktree at `/workspace` does not make the host path in that pointer available
inside the container.

The selected creation and mount sequence is to:

1. create the branch and linked-worktree administration on the host with
   `git worktree add --no-checkout`, without materializing repository content;
2. verify that no working files or repository-controlled checkout code ran;
3. resolve and validate the selected worktree Git directory and common Git
   directory on the host;
4. mount the empty worktree and common Git directory into a short-lived offline
   runtime container;
5. over-mount a launcher-generated `.git` pointer at `/workspace/.git`;
6. materialize the recorded commit with checkout hooks explicitly disabled; and
7. preserve Git's expected selected-worktree administration layout beneath the
   mounted common directory for the subsequent Pi session.

This avoids exposing the primary checkout's working files or reproducing an
arbitrary host absolute path in the container. It still makes common Git
metadata writable, which is inherent to normal worktree Git operations and must
be documented as shared authority.

The materialization container uses the installed version-matched runtime image
without pulling, Docker network-none, the host UID and GID, no capabilities,
no-new-privileges, a read-only root filesystem, and only the selected worktree,
common Git directory, generated pointer, and private temporary storage. Profiles,
credentials, shared files, primary and sibling checkouts, and Docker sockets are
not mounted.

Repository-configured content filters can execute during materialization, but
only within that restricted container. A filter that requires unavailable host
resources, credentials, tools, or network access causes creation to fail closed.
Checkout hooks are disabled for bootstrap materialization. Hooks and filters are
never moved to host execution as a compatibility fallback.

The generated pointer and any staging directory must be private from unrelated
host users, frozen before Pi starts, and removed during cleanup. Invalid links,
unexpected ownership, path escapes, mount collisions, missing administration
files, or inconsistent common-directory relationships must fail before launch.

The disposable real-Docker probe demonstrates isolated materialization,
independent files, indexes and branches, shared refs, hidden sibling and primary
files, and concurrent status containers. It also demonstrates that an ordinary
host worktree checkout invokes repository hooks and filters while the selected
`--no-checkout` sequence does not.

## Security and recovery boundaries

Managed worktrees narrow accidental file and index conflicts; they do not make
parallel agents mutually untrusted sandboxes. A process able to modify the
shared common Git directory may affect refs, objects, configuration, hooks, and
metadata used by other worktrees.

Pi-Run must continue to expose only the selected worktree's working files. The
primary checkout and sibling worktree files should not be mounted merely for
convenience. The Docker socket remains unavailable.

Repository, workspace, branch, and path availability are capabilities rather
than user authorization to merge, push, delete, or publish work. Only the
interactive, task-name confirmation in `worktree finish` authorizes its displayed
local merge and cleanup plan. Existing Guardian and human-approval semantics
remain unchanged elsewhere.

Session snapshots can preserve portable metadata and conversations but not
source content, commits absent from a durable remote, untracked worktree files,
or external side effects. Missing worktrees after restore should be reported as
unavailable, not recreated from guesses.

## Task-oriented implementation status

The replacement now provides unconditional direct ordinary launches, explicit
`worktree start <task-name> <repository>`, schema-v3 named task lifecycle records,
collision-safe isolated materialization, recoverable machine-first publication,
name-first task reporting, compact repository-grouped listing, one-active-launch
locking, and association-driven global resume. Prototype repository preferences,
launch flags, unnamed
workspaces, and cross-worktree transcript routing have been removed.

Named `worktree open <task-name> <repository>` supports fresh, `-c`, and `-r`
task-local conversations without creating another checkout. Recoverable
`finish` explicitly integrates committed work, removes the checkout and local
task branch, and preserves portable identity and conversations. It is never
inferred from ordinary exit or Git state.

## Deferred decisions and exclusions

The selected replacement still excludes:

- automatic worktree creation, inferred task completion, or source-state
  migration;
- unconfirmed merge or branch deletion, rebase, push, reset, pruning, or
  repository maintenance;
- implicit cleanup based on exit, transcript absence, Git cleanliness, or merge
  detection;
- recovery after users move a primary checkout or manually remove or relocate a
  managed task worktree;
- task reopening after finish; and
- declared support for submodules, nested repositories, and Git LFS-specific
  workflows.

Unsupported, missing, moved, unsafe, or ambiguous state continues to fail closed
rather than being guessed, repaired, or deleted automatically.

Related current behavior: [Workspaces and Sessions](../docs/workspaces-and-sessions.md)
and the [workspace/session reference](../docs/reference/workspaces-and-sessions.md).
