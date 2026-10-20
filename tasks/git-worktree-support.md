# Managed Git worktrees for parallel Pi-Run sessions

## Status and purpose

The v0.8 managed-worktree scope described here is implemented and validated.
This document preserves the design constraints, selected semantics, and deferred
work behind that implementation. The separately reviewed cleanup/removal
operation remains intentionally unimplemented.

Pi-Run can run several sessions against one Git repository without sharing one
writable checkout. Each active task receives a separate host-visible Git
worktree while normal Pi-Run launch, profile, session, network, Guardian, and
snapshot behavior remains recognizable.

Git worktrees provide change isolation, not a security boundary. They share Git
objects, refs, configuration, hooks, remotes, and external systems.

## Selected user model

Worktree behavior can be selected as a persistent repository preference or as an
override when creating a managed workspace.

Persistent commands:

```bash
pi-run worktree enable
pi-run worktree disable
pi-run worktree status
pi-run worktree list
```

Per-launch overrides:

```bash
pi-run --worktree .
pi-run --no-worktree .
```

The persistent setting applies to the repository on the current machine. It is
not committed to the repository and does not belong to a profile. Profiles
continue to select credentials, instructions, skills, settings, and sessions;
they do not decide where source worktrees live.

For a new managed workspace, command-line intent takes precedence:

| Repository preference | Launch | New workspace behavior |
| --- | --- | --- |
| Disabled | `pi-run .` | Use the selected checkout directly. |
| Disabled | `pi-run --worktree .` | Create a managed worktree. |
| Enabled | `pi-run .` | Create a managed worktree. |
| Enabled | `pi-run --no-worktree .` | Use the selected checkout directly. |

Worktree selection becomes immutable once a workspace/session group exists.
Continuing or resuming always reopens its recorded directory. A later flag must
not silently move an existing conversation between the primary checkout and a
managed worktree.

## Identity model

The current workspace UUID remains the identity of one concrete writable
directory. Every managed worktree receives its own workspace UUID and its own
profile-scoped session directory.

A new repository-level association groups the primary checkout and its managed
workspaces for discovery:

```text
repository identity
├── primary workspace identity
├── managed workspace identity A
│   └── profile session groups
└── managed workspace identity B
    └── profile session groups
```

The repository association must not collapse child worktrees into the primary
workspace UUID. Doing so could resume a conversation against the wrong branch
or filesystem state.

Pi owns individual conversation IDs and conversation branches inside a
workspace's session directory. The durable Pi-Run association is therefore one
managed worktree to one workspace UUID to one or more related Pi session files,
not necessarily one worktree for every JSONL file.

Each repository receives a random UUID on the current machine. Its canonical,
validated Git common directory is the local uniqueness key. A remote URL is not
required and does not establish identity: separate clones remain separate
repositories even when they share a remote.

Repository identity and managed-workspace associations are machine-local. The
existing portable workspace registry continues to identify workspace identities
and session groups without claiming that a source repository or its worktrees
can be reconstructed on another machine.

## Launch and resume behavior

Starting a new managed session should:

1. validate that the selected path belongs to a supported non-bare Git
   repository;
2. resolve and validate the repository's Git directory and common Git directory;
3. resolve the selected checkout's `HEAD` to one exact commit and inspect its
   working state;
4. allocate one workspace UUID and preflight its branch, checkout path, Git
   administration path, and metadata associations;
5. create the dedicated branch and host-visible worktree at the recorded commit;
6. publish the workspace registration, path mapping, and repository association
   atomically; and
7. launch Pi with the managed worktree mounted at `/workspace`.

The branch is `pi-run/<complete-workspace-uuid>`, and the final checkout path is
`<Pi-Run home>/worktrees/<repository-id>/<workspace-id>/`. The UUID is generated
once for the operation. Any collision involving the UUID, branch, checkout path,
Git administration path, workspace registry, or machine metadata fails without
silently choosing another identity.

The launch must report that a managed worktree is active, including the full
workspace identity, sanitized branch and host path, and recorded base commit.
Transparent invocation must not make source location or branch state invisible.

For associated managed workspaces:

```bash
pi-run --worktree . -c
pi-run --worktree . -r
```

select only among managed workspaces associated with that exact machine-local
repository. A candidate must have complete portable and machine metadata, an
available canonical worktree with the expected Git relationship, and at least
one valid session transcript under the selected profile. Profile selection
therefore participates directly in routing.

Pi-Run selects the workspace whose valid session transcripts have the newest
filesystem modification time. `-c` then asks Pi to continue within that
workspace, while `-r` delegates individual transcript selection to Pi within the
same workspace. Modification time is routing convenience, not authorization or
trusted provenance. If there is no candidate, Pi-Run fails without creating a
worktree. If multiple workspaces tie for newest activity, it fails as ambiguous
rather than choosing by UUID or branch name.

An older specific workspace remains selectable with
`pi-run resume <profile> <workspace-id>`. Interactive global resume continues to
present session groups for human selection. Both explicit and interactive
global resume must recognize a selected managed association, reopen its recorded
child path, acquire its launch lock, and use the managed common-Git and generated
`.git` mounts rather than treating the path as an ordinary checkout.

An existing direct-checkout session must not migrate automatically when invoked
with `--worktree`. Migration would require explicit policy for dirty files,
base revisions, workspace identity, and historical filesystem assumptions and
is outside the initial implementation.

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

## Disable and cleanup behavior

`pi-run worktree disable` changes only the repository preference for future new
workspaces. It must not:

- remove an existing worktree;
- delete a branch;
- discard tracked or untracked changes;
- move commits;
- merge, rebase, push, or reset;
- invalidate workspace identities or saved sessions; or
- prevent an existing managed session from being resumed.

Cleanup must be a separate explicit operation. Its initial command shape is
open. Any removal operation should refuse an active, dirty, locked, missing, or
ambiguous worktree by default. Branch deletion, if ever offered, must remain a
separate deliberate choice and must not be implied by worktree removal.

Automatic removal of apparently empty worktrees is excluded initially. A run
can exit before writing a transcript while still leaving meaningful source or
Git state.

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

The existing machine file advances from schema version 1 to schema version 2.
Its selected shape is:

```json
{
  "schemaVersion": 2,
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
      "enabled": true,
      "createdAt": "<UTC-timestamp>",
      "managedWorkspaces": [
        {
          "workspaceId": "<workspace-uuid>",
          "branch": "<branch-name>",
          "createdAt": "<UTC-timestamp>"
        }
      ]
    }
  ]
}
```

`snapshotAuto` is optional and retains the existing machine-local
successful-exit snapshot preference. `workspacePaths` remains authoritative for
the concrete path of every primary, ordinary, or managed workspace. A
managed-workspace record relates that workspace to a repository and branch
without duplicating its path. No source content, remote URL, credential, commit
contents, or Git configuration enters the machine file.

Repository IDs and workspace IDs must be unique. Canonical common Git
directories must be unique across repository records, and a workspace may
belong to at most one managed-workspace record. Display names and branch names
are validated and sanitized before display; paths are canonical absolute host
paths and are never interpreted as authorization to mount an unrelated target.

When worktree functionality first needs a schema-version-1 machine file,
Pi-Run performs a locked atomic migration that preserves `machineId`,
`workspacePaths`, and optional `snapshotAuto`, adds an empty `repositories`
array, writes schema version 2, and publishes the replacement only after
complete validation. Invalid,
linked, hard-linked, unexpectedly permissive, or unsupported machine files fail
without partial migration. Ordinary v0.7 launches do not need to rewrite the
file merely because v0.8 is installed.

Machine files and the managed worktree root remain excluded from portable
snapshots. The portable workspace registry schema does not need to change for
this metadata foundation.

## Metadata publication transaction

The portable registry and machine file cannot be replaced atomically together.
Managed-worktree publication therefore uses a recoverable ordered transaction
while holding the workspace registry lock. After revalidating the worktree's
repository, path, Git administration, and branch, Pi-Run atomically adds its
`workspacePaths` and `managedWorkspaces` records together in the machine file.
That complete machine association is the durable local publication marker.
Pi-Run then atomically publishes the portable `kind: "git"` workspace entry with
the same workspace ID, repository-derived display name, and creation timestamp.
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
than user authorization to merge, push, delete, or publish work. Existing
Guardian and human-approval semantics remain unchanged.

Session snapshots can preserve portable metadata and conversations but not
source content, commits absent from a durable remote, untracked worktree files,
or external side effects. Missing worktrees after restore should be reported as
unavailable, not recreated from guesses.

## Implementation status

The separately approved increments completed:

1. the disposable linked-worktree mount and isolated-materialization probe;
2. schema-v2 repository and managed-workspace metadata with atomic migration;
3. repository preferences and per-launch overrides;
4. collision-safe creation from attached or detached committed `HEAD`;
5. recoverable machine-first metadata publication;
6. managed mounting, reporting, and one-active-launch locking;
7. profile-specific `-c` and `-r` routing plus association-driven global resume;
8. repository-grouped, non-mutating status inspection;
9. user, reference, and security documentation; and
10. isolated tests plus real-Docker materialization, launch, coexistence,
    continuation, override, listing, and temporary-state cleanup validation.

The implementation keeps direct launches compatible for unregistered or
disabled repositories and does not migrate existing direct sessions. Every
managed workspace retains an immutable repository, branch, path, and workspace
association.

## Deferred decisions and exclusions

These are future features, not incomplete implicit behavior:

- an explicit conservative cleanup/removal command and its treatment of active,
  dirty, locked, missing, conflicting, or session-bearing worktrees;
- optional branch deletion, which must remain separate from worktree removal;
- explicit recovery after users move a primary checkout or remove or relocate a
  managed worktree with ordinary Git;
- automatic migration of direct sessions or uncommitted source state;
- automatic merge, rebase, push, reset, pruning, or repository maintenance; and
- declared support policy for submodules, nested repositories, and Git
  LFS-specific workflows.

Unsupported, missing, moved, unsafe, or ambiguous state continues to fail closed
rather than being guessed, repaired, or deleted automatically.

Related current behavior: [Workspaces and Sessions](../docs/workspaces-and-sessions.md)
and the [workspace/session reference](../docs/reference/workspaces-and-sessions.md).
