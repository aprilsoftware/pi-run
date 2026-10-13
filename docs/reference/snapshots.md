# Snapshot behavior reference

This reference records detailed repository, manifest, recovery, restore, and
failure behavior. For normal configuration and backup commands, start with the
[snapshot task guide](../snapshots.md).

## Complete scope and source validation

Snapshot creation always captures the complete portable Pi-Run home. Its
manifest declares these included paths:

```text
config.json
profiles/
skills/
shared/
workspaces/
snapshots/config.json
current creation manifest
```

It excludes machine-local state, repository recovery secrets, S3 credentials,
repository contents, restore staging, unrelated snapshot metadata, temporary
locks, and workspace source trees. Profile selection does not narrow scope.

Creation requires ordinary directories and singly linked regular files. It
rejects symbolic links, hard-linked files, special objects, and nested filesystem
crossings rather than following them. Files can change while sessions are open;
use a quiet period when a consistent portable state matters. This is not a live
database snapshot mechanism.

## Repository configuration

`pi-run snapshot status` validates configuration and repository access. For S3,
status contacts the remote service. An unconfigured home can use the interactive
`pi-run snapshot configure` wizard. Cancellation publishes no configuration.
Existing, partial, or staged setup prevents reconfiguration rather than being
overwritten.

### Local repository

Local setup creates:

```text
snapshots/config.json
snapshots/repository/
snapshots/secrets
```

Pi-Run generates the Restic password without printing it and stores it in
`snapshots/secrets` with mode `0600`. The local repository and secret remain on
the same machine unless backed up separately. `configure` does not import an
existing local repository; repository data, configuration, and its recovery
secret must be supplied through a separate recovery procedure.

### S3/Ceph repository

The wizard requires:

| Input | Rules |
| --- | --- |
| Endpoint | HTTPS S3 API host, optionally with a port; no path or web-console URL |
| Bucket | Existing lowercase-compatible bucket; Pi-Run does not provision it |
| Prefix | Unique slash-separated location without a leading slash or `.`/`..` segments |
| Region | Defaults to `us-east-1` |
| Operation | Create a new encrypted repository or connect to an existing one |

Create generates a recovery password. Connect requires the existing password
and never initializes after a failed connection. Access and secret keys are read
through prompts, not command arguments; secret input is hidden. Configuration
network calls are bounded to 90 seconds. An uncertain create is checked only
with the same generated password instead of attempting another initialization.

S3 uses path-style bucket lookup and the host CA bundle without disabling TLS
verification. Pi-Run stores credentials in `snapshots/s3-credentials` with mode
`0600`; that file and `snapshots/secrets` are excluded from snapshots. Existing
local repositories are not converted or switched to S3.

S3 backup uses no persistent Restic cache, a bounded temporary filesystem,
16 MiB target packs, and two upload connections. Failed remote backup is not
retried automatically because repository effects can be uncertain.

## Manifests, IDs, and inspection

Every new snapshot records a manifest containing the request and creation time,
Pi-Run and Pi versions, runtime image, schema versions, scope, purpose, included
paths, and exclusions. Restic metadata also records Pi-Run tags and the
originating machine ID.

Purposes are `manual`, `automatic`, and `pre-restore`. Older metadata can display
`-`. Lists include only Pi-Run snapshots, oldest first and newest last, with a
12-character ID, UTC time, machine, scope, and purpose.

Commands taking an ID accept 12 or 64 lowercase hexadecimal characters and
require a unique Pi-Run snapshot. `show` validates the embedded manifest against
repository metadata before displaying it. `diff` compares the selected baseline
with the newest Pi-Run snapshot, including file metadata and aggregate changes;
it does not compare live files or accept an arbitrary second ID.

`check` verifies repository structure and every stored pack. An advisory about
unused data is non-fatal; broken packs, repair recommendations, malformed output,
or Restic errors fail the command. Check never repairs, unlocks, deletes, or
prunes. Remote inspection and checks can consume bandwidth and provider
operations.

The guided menu confirms creation and full checks. Direct `snapshot create` and
`snapshot check` are explicit operations and do not repeat that menu
confirmation.

## Automatic snapshot behavior

The successful-exit setting is machine-local, excluded from snapshots, and
disabled by default. Enabling first validates the configured repository.

When enabled, Pi-Run creates at most one `automatic` snapshot after the final
successful Pi exit. Failed or interrupted runs do not trigger it. An intermediate
exit used by `/snapshot` does not trigger automation before the exact session is
reopened. Automatic failures are reported and not retried.

## In-session request channel

The snapshot extension offers status, list, complete create, and full check. It
writes one bounded, token-authenticated request to a private per-launch mount and
asks Pi to exit. The container has no repository, recovery-secret, S3-credential,
Pi-Run-home, or Docker-socket mount.

After a clean exit, the host validates the request, removes it, and invokes the
same host snapshot functions. Because any container process could write to the
request mount, create and check require a second literal `yes` confirmation in
an interactive host terminal.

After success or host cancellation, Pi-Run validates and reopens the exact
persistent session by both header ID and filename. This disambiguates imported
files that share an ID. Failures and non-persistent sessions remain exited. The
request interface does not expose configure, recover, restore, delete, or
arbitrary-ID operations.

## Recovery publication

`recover` resolves and validates the complete snapshot before publishing it at:

```text
snapshots/recovered/<full-snapshot-id>/
```

Configuration, profiles, sessions, skills, shared files, workspace metadata,
snapshot configuration, and the manifest appear directly in that directory.
There is no exposed internal input directory. Existing recovery destinations are
never overwritten. Safe temporary state is removed after ordinary failures.

Recovery does not replace live state and can run while sessions are open. The
published files are decrypted, remain until deliberately removed, and are
excluded from later snapshots. Copying selected recovered content into live
state is a separate user action.

## Live restore transaction

Restore supports local and S3 repositories and requires an interactive terminal
plus exclusive access to the Pi-Run home. It resolves one complete snapshot,
displays its identity, and requires the full 64-character ID as confirmation.

Before live changes, Pi-Run:

1. restores into private staging;
2. validates the manifest, schemas, profiles, workspace registry, file types,
   and exclusion boundaries;
3. requires restored and active repository configurations to match; and
4. creates and validates a complete `pre-restore` snapshot.

Application uses a durable journal and rollback data. Ordinary failures roll
back before safe staging is removed. A later invocation attempts recovery after
a crash. Uncertain or unrecoverable transaction state is preserved. There are
no public staging, apply, status, or cancellation commands; deleting internal
state to bypass an error can destroy recovery evidence.

Restore replaces portable configuration, every profile and credential, skills,
shared data, and the workspace registry. It does not replace repository data,
repository access secrets, snapshot history, or machine-local state. Live and
staged paths must reside on the Pi-Run home filesystem.

Before application, Pi-Run can find safe, unique matches between local checkout
paths and restored workspaces with sessions. It offers one grouped confirmation
and applies accepted mappings after portable restore commits. Ambiguous,
missing, conflicting, or declined mappings remain for guided `pi-run resume`.
A successful restore exits so the next launch is the first to use restored
state.

## Deletion, pruning, and locking

`delete` resolves one validated Pi-Run snapshot, displays its identity, and
requires the complete ID. It performs one Restic `forget --prune`, verifies the
snapshot is absent, and runs a structural repository check.

Pruning permanently removes data not referenced by any remaining snapshot,
including unused data from interrupted operations. Remote pruning can require
substantial transfer, provider operations, temporary capacity, and time. A
failure can follow partial deletion or pruning, so Pi-Run never retries,
unlocks, or repairs automatically.

Ordinary stateful commands and sessions hold shared home lifecycle locks. Restore
holds the home lock exclusively. Snapshot status, list, show, and diff share the
repository lifecycle lock; configure, create, check, delete, recover, and restore
hold it exclusively. Restic locking provides cross-workstation protection. An
open Pi session alone does not block deletion, but competing repository work can.

## Failure boundaries

- Preserve an uncertain remote result and inspect repository state before an
  explicit retry.
- Restore trusted credentials or CA configuration rather than weakening TLS or
  deleting an incomplete repository.
- Do not force-unlock a repository merely because another operation is slow.
- Preserve restore staging, journal, and rollback state after an unrecoverable
  error.
- Do not treat a successful Pi-Run snapshot as backup of workspace source,
  databases, remote systems, or excluded recovery secrets.

[Snapshot task guide](../snapshots.md) ·
[Workspace reconnection](../workspaces-and-sessions.md#reconnect-restored-sessions) ·
[Security and isolation](../security.md)
