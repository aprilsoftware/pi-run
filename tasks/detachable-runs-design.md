# Herdr-backed detachable Pi-Run sessions

## Status and authority

This document selects the v0.11 direction for keeping interactive Pi-Run sessions
live after a terminal or SSH client disconnects. It refines the
[detachable-run research](detachable-and-daemon-runs-research.md).

It is not authority to install Herdr, start or stop processes, change Pi-Run,
invoke Docker, execute unrelated tasks, commit, push, publish, or release. Herdr
remains an optional external tool installed and operated explicitly by the user.

## Product outcome

A human can run ordinary Pi-Run inside a Herdr-managed terminal, detach or lose
the client connection, and later return to the same live Pi TUI. Multiple live
Pi-Run sessions may exist for one profile or workspace and remain distinguishable
through Herdr's workspace, tab, pane, agent, and naming facilities.

Detachment changes terminal presentation only. The unchanged Pi-Run launcher
continues to own the profile/runtime, managed-worktree lock, frozen networking,
restricted-egress sidecar, Pi conversation, snapshot bridge, automatic snapshot
behavior, and cleanup.

## Selected boundary

Herdr owns terminal and process presentation:

- persistent pseudo-terminals and the background server;
- client detach, reattachment, direct terminal attachment, and resizing;
- workspaces, tabs, panes, live-agent inventory, status, and notifications;
- optional remote presentation over SSH.

Pi-Run owns agent execution and its normal authority boundaries:

- profile, prepared image, container, mounts, credentials, and network policy;
- Guardian, CAF, Planning, Todo, sessions, snapshots, and managed worktrees.

Herdr state, labels, panes, prompts, automation, or lifecycle events never
authorize agent effects.

## Initial usage contract

Pi-Run adds no background, attach, run-registry, stop, or remove command in the
initial integration. The user opens a Herdr pane and launches Pi-Run normally:

```text
HERDR_AGENT=pi pi-run .
HERDR_AGENT=pi pi-run --profile operations /srv/runbooks
HERDR_AGENT=pi pi-run worktree open api-refactor . -c
```

`HERDR_AGENT=pi` is set on the host-visible wrapper command so Herdr may apply its
Pi screen manifest even though the foreground host process is Pi-Run or Docker.
It is scoped to that launch rather than exported globally.

The user detaches and reattaches with Herdr's own interface. Ordinary
`pi-run .`, Pi-Run resume commands, and managed-worktree commands remain
unchanged and do not require Herdr.

## Deliberate non-integration

The initial boundary does not:

- invoke `herdr agent start --kind pi`, which launches plain `pi` rather than
  the Pi-Run wrapper;
- install Herdr's Pi extension into a Pi-Run profile;
- mount or proxy `HERDR_SOCKET_PATH` into the Pi-Run container;
- expose the Herdr CLI, socket, pane controls, or agent-automation skill to the
  acting model merely because its terminal is hosted by Herdr;
- ask Herdr to restore a stopped Pi-Run process with `pi --session`;
- create `<PI_RUN_HOME>/runs/`, retain exited terminals, or add a Pi-Run
  lifecycle database;
- auto-install, auto-update, configure, or stop Herdr.

These exclusions prevent terminal orchestration from bypassing Pi-Run's launcher
or giving container processes cross-pane host control.

## Live and cold recovery

Detach and reattach preserve the original Pi-Run launcher and Pi process. A full
Herdr server or host stop does not preserve those processes. Pi conversation
state remains available through Pi-Run's existing session and resume behavior.

Herdr's current official Pi integration reports a native session reference and
restores it with `pi --session <path-or-id>`. That command is not a valid Pi-Run
restore path because it can bypass Pi-Run's profile, container, runtime, network,
Guardian, CAF, and worktree setup. Native Herdr restore for Pi-Run therefore
remains disabled unless a later explicit integration can restore the exact
Pi-Run launch context without exposing the Herdr control plane to the agent.

## Security and privacy boundaries

- Herdr runs as the host user and can display and control terminals owned by that
  Herdr server; its state and terminal history are private host data.
- The Pi-Run container receives no Herdr socket, host process controls, or new
  credentials.
- Herdr status is presentation evidence, not proof of correctness, completion,
  approval, or safe interruption.
- Herdr screen detection can be mistaken, especially around unfamiliar prompts;
  `idle` never authorizes input into a permission dialog.
- Herdr upgrades, remote installation, session deletion, server stop, and other
  host effects remain explicit user operations outside Pi-Run.

## Acceptance direction

Before documenting Herdr as a supported companion, disposable real integration
must demonstrate:

- ordinary direct and managed-worktree Pi-Run launches inside Herdr;
- multiple live sessions for the same profile and workspace;
- detach, SSH loss, reattach, direct attachment, resize, and normal Pi exit;
- useful Pi working, blocked, done, and idle presentation through the wrapper;
- unchanged host, offline, and restricted networking while detached;
- managed-worktree lock, snapshot restart, automatic snapshot, and cleanup;
- no Herdr socket, CLI, or automation authority inside the agent container;
- no plain-`pi` launch or native restore bypass;
- ordinary Pi-Run behavior when Herdr is absent;
- complete source regression and required real-Docker acceptance.

A screen-detection or fake-terminal test cannot replace the real disconnect,
reattach, Docker, restricted-sidecar, worktree, and cleanup paths.

## Deliberate exclusions

This direction does not implement a Pi-Run multiplexer, run selector, run
registry, retained-exit system, stop/remove protocol, reboot-persistent daemon,
RPC worker, cloud scheduler, factory controller, automatic commit, worktree
finish, push, PR, merge, release, deployment, or production repair.
