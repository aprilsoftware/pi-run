# Detachable and daemon Pi-Run research

## Status and purpose

This document records research into running Pi-Run independently of one attached host terminal and reconnecting later. It distinguishes a detachable interactive terminal from an unattended daemon worker and assesses implementation approaches.

This is research evidence, not an approved implementation plan, task, command contract, dependency decision, or authority to start background processes, agents, services, worktrees, or external operations. The saved Plan still contains the earlier private-tmux direction and must be amended before implementation.

## Research conclusion

Pi-Run should distinguish two related but materially different capabilities:

1. **Detachable interactive session:** the existing Pi terminal UI continues after its terminal or SSH client disconnects, and a human later reconnects to the same live terminal.
2. **Unattended daemon worker:** Pi runs without the native terminal UI and is controlled through structured prompts, events, status, cancellation, and lifecycle commands.

The initial research selected a private tmux layer as the safest mechanism Pi-Run could build itself. Subsequent evaluation of [Herdr](https://github.com/herdrdev/herdr) changes the build-versus-integrate decision: Herdr already provides persistent real terminal panes, detach and reattachment, global live-agent visibility, direct attachment, remote presentation, Pi detection, status aggregation, and optional Pi session reporting.

Pi-Run should therefore use Herdr as an optional external terminal runtime rather than implement its own multiplexer, run registry, retained-exit lifecycle, selector, or stop/remove protocol. Pi-Run remains responsible for the launcher, containers, profiles, networking, worktrees, conversations, Guardian, CAF, snapshots, and its normal runtime authority. A later unattended worker should still use Pi's supported RPC interface rather than automate keystrokes in an interactive terminal.

## Terminology

Pi-Run already uses **session** for a persisted Pi conversation and **worktree task** for a named managed checkout. This document uses **live execution** for one ordinary launcher process without creating a new user-facing Pi-Run identity or registry.

“Foreground” and “background” may be friendly descriptions, but shell job-control terms have narrower meanings. Herdr attachment reconnects a client to an existing terminal; it does not invoke a shell's built-in `fg` operation or create a second Pi session.

## Current Pi-Run launch lifecycle

A normal Pi-Run workspace launch currently invokes Docker with:

```text
docker run --rm -it ...
```

The host launcher remains important for the complete run. It:

- validates the selected profile and prepared runtime;
- registers or resolves workspace and managed-worktree identity;
- holds the shared home lifecycle lock and any managed-worktree ownership lock;
- resolves and freezes restricted network policy;
- creates and supervises the restricted egress sidecar;
- owns temporary policy and managed-Git staging paths;
- owns the snapshot request bridge and processes requested Pi restarts;
- cleans launch resources on exit;
- creates an optional automatic snapshot after final successful exit.

The Pi container is therefore one part of a supervised host lifecycle. Keeping the container alive while allowing the launcher to exit would break current ownership and cleanup assumptions.

## Required user experience

A useful detachable mode should support:

- keeping an ordinary Pi-Run launcher alive without one permanently attached client;
- distinguishing several live sessions, including several for one profile or workspace;
- attaching, detaching, reconnecting, and resizing the same live terminal;
- preserving profile, worktree, network, Guardian, CAF, session, snapshot, runtime, and cleanup semantics;
- allowing ordinary Pi exit to end the live terminal while preserving normal conversation history.

It does not require Pi-Run to retain exited terminals, create a process database, define a new stop/remove lifecycle, or restart work after reboot. It must not imply automatic task selection or continuation, new authority, correctness, sandboxing, or permission to commit, push, open a pull request, merge, deploy, or publish.

## Approach 1: shell job control

A user can normally suspend a foreground command with `Ctrl-Z`, continue it with `bg`, and restore it with `fg`. This is tied to the interactive shell's own job table.

It needs no new dependency, but a later shell cannot recover another shell's job, closing the owning terminal commonly sends hangup signals, and a background TUI that reads the terminal may be stopped with `SIGTTIN`. It provides no durable Pi-Run list, attach, status, or recovery model.

**Assessment:** useful for incidental shell process management, but not a Pi-Run detachable-run architecture.

## Approach 2: `nohup` or redirected one-shot execution

A print-mode invocation can be redirected and placed in the background:

```text
nohup pi-run <workspace> --print <prompt> >output 2>error &
```

This can suit simple noninteractive one-shot commands. It does not preserve the Pi terminal UI, provide structured state or attachment, or handle extension dialogs naturally. Output files may also duplicate sensitive conversation content.

**Assessment:** a user-managed shell technique, not sufficient for detachable interactive or factory execution.

## Approach 3: Docker detach and attach

Docker can start a container with open standard input and a pseudo-terminal, leave it detached, and later reconnect with `docker attach`.

This reuses an existing dependency and reconnects directly to the original terminal. In the current Pi-Run architecture, however, launcher exit would release locks and cleanup state while Pi remained alive. Restricted egress supervision, snapshot requests, automatic snapshots, persistent workload identity, stale recovery, and crash cleanup would all need a new durable supervisor.

Using Docker's detach sequence against today's foreground `docker run` may cause the client to return while the container continues. Pi-Run could then proceed as though the run ended and clean host resources. This must not be presented as supported behavior.

**Assessment:** viable only with a purpose-built supervisor; not a safe small launcher change.

## Approach 4: private tmux session

tmux owns pseudo-terminals in a server process. A client may disconnect while the command and terminal continue, then attach later. The command still sees itself as attached to a foreground terminal.

```text
host shell
    → Pi-Run run command
        → private Pi-Run tmux server/session
            → existing Pi-Run launcher
                → Pi workload container
                → optional restricted egress sidecar
```

Only the tmux client detaches. The launcher stays alive inside the tmux pseudo-terminal and continues to own existing locks, cleanup, sidecar, snapshot, and restart responsibilities.

### Advantages

- Preserves the native Pi TUI and current launcher lifecycle.
- Survives ordinary terminal and SSH disconnection.
- Supports reattachment, terminal resizing, and read-only clients.
- Requires substantially less lifecycle redesign than Docker detach.

### Costs and risks

- Adds an optional host dependency with version and WSL variation.
- Does not itself survive host reboot.
- Multiple writable clients could produce conflicting input.
- Socket paths, names, environments, and command quoting need strict validation.
- Abrupt tmux or host termination must not bypass cleanup silently.

If Pi-Run implemented this mechanism itself, it would need a private tmux socket or server label rather than the user's normal tmux namespace, and ordinary launches should remain independent of tmux.

**Earlier assessment:** strongest mechanism for a Pi-Run-owned detachable implementation. The Herdr evaluation below supersedes the decision to build that implementation.

## Approach 5: Herdr

Herdr is an Apache-2.0 terminal workspace and coding-agent runtime. A background server owns real pseudo-terminals arranged as workspaces, tabs, and panes. Clients may detach or disappear while pane processes continue, then reconnect through the full interface or directly to one terminal. Herdr also aggregates recognized agent state and supports local and remote SSH presentation.

Herdr already recognizes Pi. For a host-visible wrapper or container launcher, its documented `HERDR_AGENT=pi` hint tells Herdr to apply the Pi screen manifest to that foreground process:

```text
HERDR_AGENT=pi pi-run .
```

This preserves Pi-Run's existing foreground launcher inside a Herdr-owned terminal without requiring Pi-Run to create its own multiplexer or lifecycle database.

### Advantages

- Meets the detach, reconnect, multi-session, selector, status, notification, resize, and remote-presentation needs with an existing focused tool.
- Keeps ordinary Pi-Run launch grammar and launcher ownership unchanged.
- Supports multiple panes and sessions for the same repository or profile.
- Avoids a Pi-Run-owned tmux namespace, run schema, terminal retention policy, and stop/remove protocol.
- Remains optional; ordinary Pi-Run does not depend on Herdr.

### Integration risks and limits

- `herdr agent start --kind pi` launches plain `pi`, not Pi-Run, and must not be used as a replacement launcher.
- Herdr's official Pi extension reports lifecycle and session identity through the Herdr socket. Mounting that control socket into the Pi-Run container would give container processes access to the broader Herdr control plane.
- Herdr's native Pi restore command is `pi --session <path-or-id>`, which would bypass Pi-Run's profile, container, runtime, network, worktree, Guardian, and CAF setup.
- A full Herdr server or host stop ends live processes; Pi-Run conversation recovery remains a separate existing workflow.
- Herdr status is presentation evidence. Screen detection can be wrong and never authorizes input or effects.

The safe initial boundary is screen detection through the host-side wrapper hint, with no Herdr socket, CLI, automation skill, or official Pi integration exposed inside the agent container. Herdr installation, updates, server lifecycle, remote setup, and session deletion remain explicit user operations.

**Assessment:** preferred initial companion for detachable interactive Pi-Run sessions. Integrate at the documented wrapper boundary rather than reimplementing Herdr or making it a mandatory Pi-Run dependency.

## Approach 6: Pi RPC worker

Pi 1.5.2 supports `--mode rpc`, a long-lived JSONL protocol over standard input and output. A client sends commands and receives responses, messages, tool events, retries, and lifecycle events.

Relevant capabilities include:

- `prompt`, `steer`, `follow_up`, `abort`, and queue clearing;
- state, message, model, thinking, and session operations;
- streamed message and tool activity;
- `agent_settled` as the end of automatic work;
- extension UI request and response records;
- orderly shutdown through input EOF, `SIGTERM`, or `SIGHUP`.

RPC gives structured control without terminal scraping and is suitable for controllers, APIs, loops, event wakeups, and factory state machines. It clearly distinguishes prompt acceptance from completed work.

RPC is not the native Pi TUI and cannot simply be attached to that UI. Pi-Run would need a shell client, TUI, web client, or command set. RPC stdout must be continuously drained, extension dialogs require responses, TUI-only functions are degraded, and Guardian, CAF, Planning, Todo, snapshots, cancellation, and session behavior require acceptance testing.

**Assessment:** preferred long-term foundation for unattended factory workers, but a different experience from detachable native TUI runs.

## Approach 7: systemd user service

`systemd-run --user` can create transient services or scopes managed by the user's service manager. It offers supervision, logs, signals, resource controls, and status. `--pty` connects a service to the current terminal but does not provide a later attachable terminal multiplexer.

Availability and logout behavior vary, particularly across WSL. Reboot restart requires an explicit recovery policy, and journal output may duplicate sensitive model or terminal content.

**Assessment:** may later supervise a terminal runtime or RPC controller, but should not be the first portability requirement or primary attachment mechanism.

## Recommended product separation

### Detachable interactive session

Purpose: a human starts Pi-Run, disconnects, and later returns to the same native terminal UI.

Recommended mechanism: an ordinary Pi-Run launcher inside a user-operated Herdr pane.

Herdr owns terminal persistence and presentation. Pi-Run does not create a parallel run identity or lifecycle. A live Herdr pane is not a factory attempt, and losing or stopping it does not approve retry or continuation.

### Unattended factory worker

Purpose: an approved task continues through structured prompts, loops, events, validation, and review without a continuously attached terminal.

Recommended mechanism: host controller plus Pi RPC process.

A later state model may include:

```text
created → starting → idle → running → waiting → blocked
        → validating → reviewing → completed | failed | stopped
```

The exact factory state machine remains a future Plan decision and stays independent of Herdr pane state.

## Integration surface

The initial user contract remains ordinary Pi-Run syntax inside Herdr:

```text
HERDR_AGENT=pi pi-run <normal launch>
```

Pi-Run does not initially add `--background`, `attach`, `run start`, `run list`, `run stop`, or `run remove`. Herdr already supplies its own workspace, pane, agent-list, detach, attach, direct-attach, and server-lifecycle operations.

Ordinary Pi-Run launches outside Herdr remain unchanged. Pi-Run does not auto-install Herdr, make Doctor fail when it is absent, or treat a reachable Herdr server as authorization to create panes or agents.

## Attachment, stop, and recovery

Attachment is a Herdr client operation and changes no Pi-Run profile, runtime, conversation, tools, networking, Plan approval, or publication authority. Multiple writable-client and take-over behavior remains Herdr's visible terminal policy rather than a second Pi-Run protocol.

Normal Pi exit lets the existing launcher perform sidecar, staging, snapshot, and lock cleanup. Deliberately stopping a Herdr pane or server may interrupt a model call, command, remote operation, file write, or cleanup. Pi-Run must not claim that Herdr termination is an orderly factory cancellation or rollback. Compatibility acceptance should exercise normal exit and abrupt client/server loss honestly.

A missing Herdr client is never evidence that Pi stopped. A stopped Herdr server is not evidence that a Pi conversation was deleted; persisted Pi state remains governed by Pi-Run's existing session behavior. Recovery after a cold stop uses explicit Pi-Run launch and resume paths rather than Herdr's plain-`pi` native restore.

## Security and privacy considerations

- Herdr terminal state, screen history, labels, and session files can contain prompts, code, tool output, paths, and secrets; protect them as host-user data.
- The host-side `HERDR_AGENT=pi` hint is scoped to the wrapper process and should not be exported globally.
- Do not mount the Herdr socket into the Pi-Run container or expose Herdr automation merely to improve status reporting.
- Do not use plain `pi` start or restore commands where the Pi-Run launcher is required.
- A detached session retains its original frozen network and profile credentials until Pi-Run exits.
- Herdr status, waits, and notifications grant no task or action authority.
- Pi-Run must not expose the Docker socket to the agent for supervision.

## Validation implications

Herdr compatibility needs disposable real integration evidence for:

- direct workspace and managed-worktree Pi-Run launches with the wrapper hint;
- multiple live sessions for one profile or workspace;
- useful Pi lifecycle detection without the official integration socket;
- detach, SSH loss, reconnect, direct attach, resize, and normal exit;
- restricted sidecar continuity, managed-worktree locking, snapshot restart, automatic snapshot, and launcher cleanup;
- no Herdr socket, CLI, agent automation, or host-control authority inside the container;
- no plain-`pi` launch or cold-restore bypass;
- ordinary Pi-Run operation with Herdr absent;
- host or WSL shutdown and abrupt Herdr-stop limitations reported honestly.

An RPC worker additionally requires protocol, event ordering, stdout backpressure, extension UI, Guardian, CAF, session, cancellation, and `agent_settled` tests.

## Recommended sequence

1. **Architecture correction:** replace the planned Pi-Run multiplexer and run registry with the explicit optional Herdr boundary.
2. **Compatibility acceptance:** test ordinary Pi-Run launches in disposable Herdr sessions without exposing its control socket to the container.
3. **Documentation decision:** if acceptance passes, document Herdr as an optional companion rather than a bundled dependency.
4. **RPC factory-worker design:** bind an approved task to a durable controller, Pi events, deterministic validation, and human gates.
5. **Optional service supervision:** consider service management only when logout, reboot, timers, resource accounting, or unattended workers become explicit requirements.

No implementation stage follows automatically from this research.

## Sources

- [Pi CLI integration](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli-integration.md)
- [Pi RPC mode](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)
- [Pi RPC commands](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-commands.md)
- [Pi RPC extension UI](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-extension-ui.md)
- [Pi SDK](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md)
- [Docker container attach](https://docs.docker.com/reference/cli/docker/container/attach/)
- [Docker container run](https://docs.docker.com/reference/cli/docker/container/run/)
- [tmux manual](https://man.openbsd.org/tmux.1)
- [systemd-run manual](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html)
- [GNU Bash job-control builtins](https://www.gnu.org/software/bash/manual/html_node/Job-Control-Builtins.html)
- [GNU Bash job-control basics](https://www.gnu.org/software/bash/manual/html_node/Job-Control-Basics.html)
- [Herdr repository](https://github.com/herdrdev/herdr)
- [Herdr quick start](https://herdr.dev/docs/quick-start/)
- [Herdr agents and wrapper detection](https://herdr.dev/docs/agents/)
- [Herdr integrations](https://herdr.dev/docs/integrations/)
- [Herdr persistence and remote access](https://herdr.dev/docs/persistence-remote/)
- [Herdr session state and restore](https://herdr.dev/docs/session-state/)
