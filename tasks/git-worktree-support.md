# Managed Git worktrees for parallel Pi-Run sessions

## Status and purpose

This document records the agreed v0.8 direction and the decisions that still
need evidence or discussion. It describes intended behavior, not implemented
functionality.

The goal is to let several Pi-Run sessions work concurrently on one Git
repository without sharing one writable checkout. Each active task receives a
separate host-visible Git worktree while normal Pi-Run launch, profile, session,
network, Guardian, and snapshot behavior remains recognizable.

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
3. choose a committed base revision;
4. create a dedicated branch and host-visible worktree;
5. assign and register a new workspace UUID;
6. record the repository-to-workspace association atomically; and
7. launch Pi with the managed worktree mounted at `/workspace`.

The launch must report that a managed worktree is active, including a sanitized
branch name and host path. Transparent invocation must not make source location
or branch state invisible.

For associated managed workspaces:

```bash
pi-run --worktree . -c
pi-run --worktree . -r
```

should continue or select managed-worktree sessions for that repository. If no
managed session exists, `-c` should fail clearly rather than create a new
worktree while claiming to continue work. Resume selection must reopen the
recorded child workspace before delegating individual conversation selection to
Pi.

An existing direct-checkout session must not migrate automatically when invoked
with `--worktree`. Migration would require explicit policy for dirty files,
base revisions, workspace identity, and historical filesystem assumptions and
is outside the initial implementation.

## Concurrency

Only one active Pi-Run process may use a particular managed worktree. A
machine-local per-workspace launch lock should fail clearly when the same
workspace is already active. Different managed worktrees may run concurrently.

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

## Dirty primary checkout and base revision

A linked worktree starts from a commit and cannot inherit uncommitted primary
checkout changes safely. Pi-Run must never stash, copy, commit, reset, or discard
those changes automatically.

The initial policy remains open between two conservative choices:

1. refuse creation while the selected primary checkout is dirty; or
2. allow creation but report clearly that the new worktree starts from the
   committed `HEAD` and excludes uncommitted changes.

Existing managed worktrees retain their current branch state when the primary
branch advances. Pi-Run must not automatically rebase or merge them.

Unborn branches, detached `HEAD`, submodules, nested repositories, bare
repositories, and Git-LFS-specific behavior require explicit support decisions
rather than accidental acceptance.

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

`workspacePaths` remains authoritative for the concrete path of every primary,
ordinary, or managed workspace. A managed-workspace record relates that
workspace to a repository and branch without duplicating its path. No source
content, remote URL, credential, commit contents, or Git configuration enters
the machine file.

Repository IDs and workspace IDs must be unique. Canonical common Git
directories must be unique across repository records, and a workspace may
belong to at most one managed-workspace record. Display names and branch names
are validated and sanitized before display; paths are canonical absolute host
paths and are never interpreted as authorization to mount an unrelated target.

When worktree functionality first needs a schema-version-1 machine file,
Pi-Run performs a locked atomic migration that preserves `machineId` and
`workspacePaths`, adds an empty `repositories` array, writes schema version 2,
and publishes the replacement only after complete validation. Invalid,
linked, hard-linked, unexpectedly permissive, or unsupported machine files fail
without partial migration. Ordinary v0.7 launches do not need to rewrite the
file merely because v0.8 is installed.

Machine files and the managed worktree root remain excluded from portable
snapshots. The portable workspace registry schema does not need to change for
this metadata foundation.

## Container Git metadata

A linked worktree contains a `.git` file pointing to administration data beneath
the primary repository's common Git directory. Mounting only the selected
worktree at `/workspace` does not make the host path in that pointer available
inside the container.

The preferred feasibility direction is to:

1. resolve the selected worktree Git directory and common directory on the host;
2. validate that both are ordinary, consistently related Git paths;
3. mount the common Git directory at a private container path;
4. over-mount a launcher-generated `.git` pointer at `/workspace/.git`; and
5. preserve Git's expected selected-worktree administration layout beneath the
   mounted common directory.

This avoids exposing the primary checkout's working files or reproducing an
arbitrary host absolute path in the container. It still makes common Git
metadata writable, which is inherent to normal worktree Git operations and must
be documented as shared authority.

The generated pointer and any staging directory must be private from unrelated
host users, frozen before Pi starts, and removed during cleanup. Invalid links,
unexpected ownership, path escapes, mount collisions, missing administration
files, or inconsistent common-directory relationships must fail before launch.

This mount design is a hypothesis until proven with disposable repositories,
real Docker, commits, branches, status operations, and concurrent worktrees.

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

## Proposed implementation sequence

Each step requires a separate concrete proposal and approval.

1. **Disposable feasibility probe:** prove linked-worktree Git operation through
   the proposed mounts, including expected failure with only `/workspace`, safe
   path validation, common-metadata sharing, and concurrent independent status.
2. **Repository and managed-workspace metadata:** define schemas, atomic updates,
   validation, locking, listing, and snapshot exclusions without changing normal
   launch behavior.
3. **On-demand creation:** implement `--worktree` for new workspaces, startup
   reporting, and one-active-launch locking. Keep normal launches unchanged.
4. **Continuation and selection:** route `-c`, `-r`, and global resume to the
   associated managed worktree without automatic migration.
5. **Repository preference:** add `worktree enable`, `disable`, and `status`, plus
   `--no-worktree` precedence.
6. **Inspection and explicit cleanup:** add repository-grouped listing and a
   separately reviewed conservative removal workflow.
7. **Documentation and real-Docker validation:** document boundaries and test
   parallel sessions, restricted networking, snapshots, restore visibility, and
   failure cleanup.

## Decisions required before production implementation

- branch naming and collision handling;
- dirty-checkout policy and base-revision reporting;
- supported Git states and features for the initial release;
- exact active-launch lock ownership and stale-lock recovery;
- command semantics when several managed workspaces could satisfy `-c`;
- whether profile selection participates in latest-session routing;
- cleanup command shape and treatment of worktrees with sessions but no changes;
- behavior when users move a primary checkout or remove or relocate managed
  worktrees with ordinary Git;
- hook and repository-config exposure in the container; and
- safe mount behavior when host paths overlap the workspace or Pi-Run home.

Related current behavior: [Workspaces and Sessions](../docs/workspaces-and-sessions.md)
and the [workspace/session reference](../docs/reference/workspaces-and-sessions.md).
