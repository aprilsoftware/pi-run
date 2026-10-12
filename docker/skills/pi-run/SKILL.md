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
| Selected profile | `/profile` | read-write |
| Shared directory, when enabled | `/shared` | read-write |
| Profile-local skill | `/profile/skills/<name>` | read-write |
| Global skill | `/skills/<name>` | read-only |
| Host CA bundle | `/etc/ssl/certs/ca-certificates.crt` | read-only |
| Per-launch snapshot request directory | `/run/pi-run-snapshot` | read-write control channel |

Normal sessions use host networking, so loopback and other reachable services
may be real host or remote systems. The host home, other profiles, machine-local
workspace mappings, snapshot repositories and secrets, and Docker socket are not
mounted in a normal session.

The selected profile is the source of truth for Pi configuration, credentials,
instructions, Guardian policy, and sessions. Other profiles are not mounted.

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
Host-key checking remains enabled, and credential presence does not authorize
remote access. Encrypted keys, imports, aliases, ports, IPv6 names, and multiple
users for one hostname are not supported by this mechanism.

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
