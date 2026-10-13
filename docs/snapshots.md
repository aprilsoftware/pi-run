# Encrypted snapshots and recovery

Profiles accumulate model access, instructions, skills, preferences, Guardian
records, and conversations that are tedious to rebuild. Pi-Run snapshots protect
that complete portable environment in one encrypted operation, without requiring
a separate Restic installation on the host.

Use snapshots for routine recovery points, workstation migration, and protection
before risky changes. They complement source control and infrastructure backups;
they do not replace them.

## Know what is protected

Every snapshot has **complete** scope:

| Included | Not included |
| --- | --- |
| Home configuration and saved default profile | Machine-local workspace paths and automatic-snapshot preference |
| All profiles, including credentials, settings, Guardian logs, and sessions | Snapshot recovery password and S3 credentials |
| Global and profile skills, plus shared files | Snapshot repository contents and restore staging |
| Portable workspace identities and snapshot configuration | Workspace source trees and remote-system data |

A snapshot includes **every profile and its credentials**, regardless of a
`--profile` option used for other commands. Profile-only snapshots are not
supported. Keep workspace code in version control and back up databases or
infrastructure through their own systems.

## Configure storage

Run snapshot commands in your **host terminal**. Start the guided setup:

```bash
pi-run snapshot configure
```

Choose the backend that matches the protection you need:

| Backend | Best for | Important limitation |
| --- | --- | --- |
| Local | Fast recovery points on this workstation | A repository on the same disk does not protect against disk loss. |
| S3/Ceph | Off-machine backup and workstation migration | Requires an existing bucket and credentials; storage and transfer operations may cost money. |

The wizard shows a non-secret summary and asks before configuring storage. It
will not overwrite an existing or incomplete setup. Check the configured
repository at any time with:

```bash
pi-run snapshot status
```

### Preserve the recovery material separately

Configuration stores the repository recovery password at `snapshots/secrets`
under the Pi-Run home. S3 additionally uses `snapshots/s3-credentials`. These
files are **excluded from snapshots**.

Back up the recovery password, S3 credentials when applicable, and repository
location through a separate private method. Losing the recovery password makes
the encrypted repository unrecoverable; S3 credentials alone cannot decrypt it.
Do not put these secrets in a workspace or public repository.

## Create, list, and inspect snapshots

Create a complete recovery point and list available snapshots:

```bash
pi-run snapshot create
pi-run snapshot list
```

The list is oldest first and newest last, keeping the latest snapshot near the
returned terminal prompt. It provides the snapshot ID needed by other commands.
To inspect one snapshot or compare it with the newest Pi-Run snapshot:

```bash
snapshot_id=0123456789ab
pi-run snapshot show "$snapshot_id"
pi-run snapshot diff "$snapshot_id"
```

`show` displays the validated manifest and protection boundaries. `diff` compares
the selected snapshot with the newest snapshot—not with live files.

Run a complete repository integrity check when appropriate:

```bash
pi-run snapshot check
```

A check reads and verifies every stored data pack. On S3 this can take time,
transfer substantial data, and incur provider charges. It does not repair,
unlock, delete, or prune repository data.

Running `pi-run snapshot` without a subcommand opens a guided menu for setup,
status, creation, listing, and checks.

## Optional automatic snapshots

Automatic snapshots are disabled by default. Enable one complete snapshot after
the final successful Pi exit on this machine:

```bash
pi-run snapshot auto status
pi-run snapshot auto enable
```

Failed or interrupted runs do not trigger one. S3 automation can consume storage,
bandwidth, and provider operations after every successful run. Disable future
automatic snapshots with:

```bash
pi-run snapshot auto disable
```

This setting is machine-local and is not restored on another workstation.

## Request a snapshot action inside Pi

In **Pi's input editor**, enter:

```text
/snapshot
```

The menu offers status, list, complete creation, and a full integrity check. Pi
briefly exits so the host launcher performs the operation; the running agent does
not receive the repository, recovery password, S3 credentials, or Docker socket.

Creation and checks require confirmation in the host terminal. After success or
host cancellation, Pi-Run reopens the exact persistent session that requested
the action. Use host commands for setup, recovery, restore, deletion, and
snapshot-ID operations.

## Recover files without replacing live state

Use recovery when you want to inspect or copy files without changing the active
Pi-Run home:

```bash
pi-run snapshot recover "$snapshot_id"
```

Pi-Run validates and publishes the recovered contents under
`snapshots/recovered/<full-snapshot-id>/`. Existing live profiles, sessions,
configuration, and skills remain unchanged.

**Recovered files are decrypted.** They can contain provider authentication,
private SSH keys, conversations, and tool output. Keep the directory private and
remove it deliberately when no longer needed.

## Restore portable state in place

Use restore only when you intend to replace the active portable state:

```bash
pi-run snapshot restore "$snapshot_id"
```

Restore replaces configuration, **all profiles and credentials**, skills, shared
files, and portable workspace identities. It does not restore workspace source,
remote infrastructure, repository secrets, snapshot history, machine-local
workspace paths, or automatic-snapshot preference.

Stop all Pi sessions using that home first. Pi-Run requires exclusive access,
stages and validates the snapshot, asks for the complete snapshot ID, and creates
a verified `pre-restore` snapshot before applying changes transactionally. When
possible it rolls back an application failure. Successful restore exits; launch
Pi-Run again to use the restored state.

Recover a separate copy first when you are unsure whether live replacement is
appropriate. Restored sessions may need
[workspace reconnection](workspaces-and-sessions.md#reconnect-restored-sessions)
on the new machine.

## Delete a snapshot deliberately

```bash
pi-run snapshot delete "$snapshot_id"
```

Deletion requires interactive confirmation with the complete snapshot ID. It is
permanent and prunes encrypted data that no remaining snapshot references.
Review the recovery points that will remain before proceeding. Never retry an
uncertain deletion automatically; inspect repository state first.

## Handle failures without expanding the intervention

- **Busy home:** stop affected sessions before live restore. Separate recovery
  does not require exclusive home access.
- **Busy repository:** let the competing operation finish; do not casually force
  an unlock.
- **Missing secrets or TLS failure:** restore the intended trusted access instead
  of deleting repository state or weakening verification.
- **Failed remote backup or deletion:** inspect list/show and reported output
  before retrying because the remote effect may be uncertain.
- **Restore or rollback failure:** preserve staging and transaction state for
  diagnosis rather than deleting it to silence an error.

For exact S3 inputs, manifests, ID rules, request mechanics, locking, recovery
publication, restore transactions, and deletion semantics, see the
[snapshot behavior reference](reference/snapshots.md).

[Documentation index](index.md) · [Profiles](profiles.md) ·
[Workspaces and sessions](workspaces-and-sessions.md)
