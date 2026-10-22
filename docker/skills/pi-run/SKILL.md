---
name: pi-run
description: Use and troubleshoot the Pi-Run launcher, container boundaries, profiles, shared files, sessions, and runtime configuration.
---

# Pi-Run

## Purpose

Use this skill for questions and work involving Pi-Run itself: launcher behavior,
container mounts, profile selection, skill loading, sessions, and runtime image
configuration.

## Command context

`pi-run` is a host launcher, not a command available inside a normal Pi
container. Host management commands in this skill must be run by the user in a
host terminal. When working inside Pi, explain the exact host command and its
expected effect instead of attempting to execute it. Slash commands such as
`/snapshot` belong in Pi's input editor.

## Runtime model

Pi-Run exposes intentionally selected resources:

| Resource | Container path | Mode |
|---|---|---|
| Selected workspace | `/workspace` | read-write |
| Selected profile | `/profile` | read-write base mount |
| Profile configuration | `/profile/profile.json` | read-only nested over-mount |
| Managed SSH credentials, when present | `/profile/credentials/ssh` | read-only nested over-mount |
| Shared directory, when enabled | `/shared` | read-write |
| Profile-local skill | `/profile/skills/<name>` | read-write |
| Global skill | `/skills/<name>` | read-only |
| Host CA bundle | `/etc/ssl/certs/ca-certificates.crt` | read-only |
| Per-launch snapshot request directory | `/run/pi-run-snapshot` | read-write control channel |

Networking belongs to the selected profile. `host` uses Docker host networking;
`offline` uses Docker network-none; `restricted` uses a default-deny namespace
with a version-matched egress sidecar and frozen TCP policy. A missing network
object preserves host networking for stable v0.6 profiles. Reachable services
may be real host or remote systems. The host home, other profiles, machine-local
workspace mappings, snapshot repositories and secrets, and Docker socket are not
mounted in a normal session.

The selected profile is the source of truth for Pi configuration, credentials,
instructions, Guardian policy, and sessions. Other profiles are not mounted.
The nested read-only mounts prevent a normal session from rewriting next-launch
network authority or managed SSH keys; other permitted profile state remains
real writable host data.

The launcher disables broad automatic skill, extension, and prompt-template
discovery. Core Pi-Run skills and baseline extensions are loaded explicitly.
Every validated direct child of `/profile/skills` is loaded explicitly and
remains writable. Validated global skills under the Pi-Run home are mounted
read-only when enabled by the active profile's global skill filter.

## Host layout

The default host location is:

```text
${PI_RUN_HOME:-$HOME/Pi-Run}/
```

Important directories:

```text
profiles/<profile>/
skills/<skill>/
shared/
workspaces/
worktrees/
machines/
snapshots/
```

Use `pi-run home` to print the resolved location. A command-line `--home` value
overrides `PI_RUN_HOME`, which overrides `$HOME/Pi-Run`.

## Version and diagnostics

Use `pi-run version` to report the installed Pi-Run version and selected runtime
image. Use `pi-run doctor` for read-only checks of the host commands, Docker
daemon, local runtime image, installed resources, Pi-Run home, and selected
profile. Warnings do not fail the command; failed requirements produce a
nonzero exit status.

`doctor` does not initialize or repair state, pull images, access registries, or
inspect credential contents. Do not treat a successful diagnostic as authority
to change the host or contact infrastructure.

## Profile networking

Inspect and change network authority from a host terminal:

```bash
pi-run --profile <name> network show
pi-run --profile <name> network mode <host|offline|restricted>
pi-run --profile <name> network allow list
pi-run --profile <name> network allow add host <hostname> --tcp-port <port>
pi-run --profile <name> network allow add domain <domain> --all-tcp
pi-run --profile <name> network allow add cidr <cidr> --all-tcp
pi-run --profile <name> network allow add internet --all-tcp
pi-run --profile <name> network allow remove internet
```

Host and domain rules use hostname-aware HTTP CONNECT. CIDR rules permit direct
TCP to the normalized network. An internet rule permits public TCP destinations
while excluding private and special-purpose ranges; explicit CIDRs can grant
selected private networks. Supplying `tcpPorts` restricts any rule to unique
ports from 1 through 65535. Profile JSON omits `tcpPorts` for all TCP, while the
host CLI requires the deliberate `--all-tcp` flag. External UDP and ICMP remain
denied. Public-internet authority is broad exfiltration authority even when an
enterprise firewall independently restricts it.

Restricted startup automatically derives exact TCP/443 model destinations and
exact-target TCP/22 rules from complete matching managed SSH key pairs. It
reports only `model-tcp` and `ssh-tcp` target counts and fixed ports while
reporting exact explicitly configured `manual-tcp` rules. Inferred hostnames are
not printed. Use `ssh-key list` to request the SSH inventory. The normalized
policy is private from Pi and frozen before startup; profile, provider, or key
changes affect only a new launch. Network reachability and credential presence
are capabilities, not user authorization for a task.

Mode and rule commands lock, validate, stage, and atomically replace
`profile.json`. Host or offline mode cannot retain manual rules; use
`--discard-rules` only when deliberate removal is intended. CIDR mutation uses
the locally installed version-matched runtime image in an offline, capability-
free, read-only helper with no mounts.

## Managed Git worktrees

Managed worktrees provide persistent host-visible parallel checkouts for a
normal non-bare Git repository. Ask the user to run these commands from the
repository in a host terminal:

```bash
pi-run worktree start <task-name> <repository>
pi-run worktree open <task-name> <repository>
pi-run worktree open <task-name> <repository> -c
pi-run worktree open <task-name> <repository> -r
pi-run worktree finish <task-name>
pi-run worktree list
pi-run worktree list --all
```

`worktree start` requires a relative or absolute repository path; use `.` for
the current repository. It creates one explicitly named task, while ordinary
launches use the selected checkout directly. A managed task begins at
the selected checkout's exact committed `HEAD` on
`pi-run/<task-name>/<workspace-uuid>`. Dirty source-checkout changes are reported
but not copied. Ordinary launch and exit do not stash, commit, clean, reset,
merge, rebase, push, remove worktrees, or delete branches. Managed checkouts live under:

```text
<Pi-Run home>/worktrees/<repository-id>/<workspace-id>/
```

`worktree open` requires the same explicit repository-path form and reuses
exactly the named task without creating another checkout. Without a selector it
starts a fresh conversation; `-c` and `-r` stay within the selected profile's
conversations for that task. Global `pi-run resume` also
follows the selected workspace's recorded association. One Pi-Run process may
use a particular managed task at a time, while distinct tasks may run concurrently.

Managed startup reports only the selected profile, task name, and current task
revision. `worktree list` is read-only and uses a compact `TASK`, `STATE`,
`STATUS`, and `CREATED` table. Normal output omits repository/workspace UUIDs,
internal branch names, and managed storage paths. Status may be `available`,
`missing`, `pending`, `path-conflict`, `git-conflict`, or `unsafe`; `--all` also
shows `finished`/`archived` history.

`worktree finish` is the explicit integration and cleanup workflow. Run it from
the clean checkout whose attached branch should receive the task. It shows the
task name, target branch, and commit count without exposing internal workspace
identifiers, then proposes a local merge, managed-checkout removal, and local
task-branch deletion. It requires interactive confirmation and refuses active
use, dirty or ignored content, submodules, missing active tasks, and unsafe or
conflicting state. Merge and inspection run offline in the restricted runtime
with Git hooks disabled. Conflicts are aborted and the target is verified
restored; only successful integration permits non-force checkout and local
branch removal. Conversations and portable history remain. Finish never fetches,
pushes, force-deletes, or deletes a remote branch. Never interpret exit or an
inactive or missing session as permission to finish.

A worktree separates branches, indexes, and working files; it is not a sandbox.
The selected checkout is mounted at `/workspace`, but the writable common Git
directory is also mounted for normal Git operation. Objects, refs,
configuration, hooks, remotes, credentials, caches, network authority, and
external systems can remain shared. Managed source trees and machine
associations are excluded from encrypted snapshots and are never reconstructed
from remote names or restored conversations. See
[Workspaces and sessions](https://github.com/aprilsoftware/pi-run/blob/main/docs/workspaces-and-sessions.md)
and [Security and isolation](https://github.com/aprilsoftware/pi-run/blob/main/docs/security.md)
for the full status, recovery, and authority boundaries.

## Sessions

Sessions are grouped by profile and stable workspace ID:

```text
profiles/<profile>/sessions/<workspace-id>/*.jsonl
```

Use `pi-run session list` to discover groups globally, or
`pi-run session list <workspace-id>` to show individual sessions with their
profile, exact ID, creation time, latest Pi session name, and physical filename.
`pi-run resume` selects a profile and workspace on the host, then delegates
individual session selection to Pi's native `--resume` interface.

For an `unavailable` restored group, interactive `pi-run resume` asks for an
existing checkout path and confirmation before reconnecting it. From an eligible
new checkout, `pi-run . -r` can offer matching unavailable work for the selected
profile. Reconnection refuses a checkout that already has session state and does
not modify workspace source or session JSONL. An `unregistered` group lacks
portable registry metadata and cannot be repaired automatically. Use
`pi-run workspace link <id> <path>` for a known moved directory, not as a
required precursor to guided restored-session reconnection.

Pi-Run validates session headers for discovery but does not rewrite session
JSONL.

## Automatic snapshots

The automatic-snapshot setting is machine-local and disabled by default. The
resulting encrypted snapshots use the configured local or S3 backend. Manage the
setting explicitly from the host:

```bash
pi-run snapshot auto status
pi-run snapshot auto enable
pi-run snapshot auto disable
```

When enabled, Pi-Run creates one complete snapshot after the final successful
Pi exit. Failed or interrupted runs and intermediate `/snapshot` exits do not
trigger one. Remote backup failures are never retried automatically. This is
separate from Pi's normal session JSONL persistence.

## Profile SSH keys

Passphrase-free keys under `/profile/credentials/ssh` use `user@host` private
filenames, matching `.pub` files, and a shared `known_hosts`. On startup Pi-Run
creates ephemeral OpenSSH configuration that supplies the inferred user,
private key, `IdentitiesOnly yes`, and profile host-key database. OpenSSH-based
Ansible can therefore use the matching hostname without an inventory user or
private-key path.

Manage stored keys explicitly from the host:

```bash
pi-run --profile <name> ssh-key list
pi-run --profile <name> ssh-key add <user@host>
pi-run --profile <name> ssh-key remove <user@host>
```

Listing is read-only and networkless. Add creates or reuses a local Ed25519 pair
and makes one interactive `ssh-copy-id` attempt; a failed installation retains
the pair for an explicit retry. Remove affects only local files and never
revokes remote `authorized_keys`. Startup and listing do not contact targets.
On the next restricted launch, each complete matching pair grants its exact
hostname—or IPv4 `/32`—TCP/22 reachability. The managed store is mounted
read-only in normal sessions, and the active policy remains frozen. Host-key
checking remains enabled, and credential presence does not authorize remote
work. Encrypted keys, imports, aliases, nonstandard inferred ports, IPv6 names,
and multiple users for one hostname are not supported by this mechanism.

## Security boundaries

Do not casually change Pi-Run to:

- mount the Docker socket;
- mount all profiles or the host home directory;
- expose unrelated workspaces;
- remove capability dropping or `no-new-privileges`;
- enable automatic resource discovery;
- treat network or credential availability as authorization.

Skills describe procedures; they do not grant authority. Profile instructions,
the current user request, operating-system permissions, and remote access
controls remain applicable.

## Development

The launcher is `bin/pi-run`; the runtime image is defined by
`docker/Dockerfile`. Validate launcher changes with:

```bash
bash -n bin/pi-run docker/entrypoint.sh
shellcheck bin/pi-run docker/entrypoint.sh
```

Use a temporary `PI_RUN_HOME` and a fake `docker` executable when checking
launcher argument construction without starting a container. Inspect the final
mount list and ensure only intended resources are present.
