# Getting started with Pi-Run

Pi-Run gives [Pi](https://pi.dev/), a terminal AI agent, a ready-to-use
containerized environment for software development and system administration.
You choose one workspace and profile; Pi-Run supplies the toolchain and keeps
your configuration and conversations available between runs.

This guide takes you from an installed Pi-Run to one bounded task and a saved
conversation. Run `pi-run` commands in your **host terminal** and slash commands
such as `/login` inside **Pi's input editor**.

## 1. Install and check Pi-Run

First follow the [installation guide](installation.md). Then initialize your
private data home and check the installation:

```bash
pi-run version
pi-run init
pi-run doctor
```

`version` identifies the launcher plus its runtime and egress images. `init`
creates the initial profile and persistent data directories, normally under
`~/Pi-Run`. `doctor` reports `OK`, `WARN`, and `FAIL` without repairing state or
printing credential contents.

Required checks should pass before launch. If a command or check fails, use the
[startup troubleshooting reference](reference/getting-started.md#troubleshoot-startup).

## 2. Understand what you are opening

| Concept | What it gives you |
| --- | --- |
| Workspace | The host directory Pi works in, mounted read-write at `/workspace`. |
| Profile | Selected instructions, settings, credentials, skills, and sessions, mounted read-write at `/profile`. |
| Pi-Run home | Persistent Pi-Run data, normally `~/Pi-Run`; separate from the installed application. |

The initial profile is `default`. Purpose-specific profiles help keep unrelated
accounts, sessions, and instructions out of a run.

The workspace and profile are real writable host data. The default profile also
exposes writable shared files at `/shared`, and normal sessions use host
networking. Containerization does not make files, localhost services, or remote
systems disposable. Open only the directory and access needed for the task; see
[Security and isolation](security.md).

## 3. Open a workspace

Change to the directory you want Pi to use, then run:

```bash
pi-run .
```

You can pass another existing directory instead of `.`. Pi-Run reports the data
home, selected profile, workspace, Guardian state, and enabled optional mounts,
then opens Pi's interactive terminal interface. The normal terminal mode keeps
standard scrollback.

The first launch also initializes a missing data home and registers this
workspace. For profile selection and exact startup behavior, see the
[Getting Started reference](reference/getting-started.md#how-launch-selection-works).

## 4. Connect a model

In Pi, enter:

```text
/login
```

Choose a supported provider and follow its authentication prompts. Provider
access and model use can incur charges. Then choose an available model:

```text
/model
```

Authentication and model settings belong to the selected profile. Keep the
profile private, and expect a different profile to require its own setup.

Type `/` to browse Pi commands. `/settings` changes common preferences and
`/thinking` selects a supported reasoning level. See
[Pi's documentation](https://pi.dev/docs/latest/) for general Pi usage.

## 5. Give Pi a bounded first task

Begin with investigation rather than a broad request to change everything. For
a development workspace, try:

```text
Explain how this repository is organized and identify its documented build
and test commands. Do not modify files or run the build yet.
```

For an administration workspace, try:

```text
Review the scripts and operational notes in this directory. Summarize their
purpose and prerequisites. Do not execute scripts, connect remotely, or change
files.
```

Review the result before authorizing a concrete next step. The default profile
asks the agent to investigate and propose one increment before implementation.
For operations, state the exact target, effect, and limits. A reachable service
or available credential is not permission to use it.

[Planning](planning.md) can structure a larger goal. [Guardian](guardian.md) can
review covered commands when enabled, but every new session starts Off and it is
not a sandbox. Continue to inspect commands and changed files yourself.

## 6. Name, leave, and continue your session

Give useful work a recognizable name and leave normally:

```text
/name Investigate build failure
/quit
```

Pi saves normal sessions automatically. From the same workspace and profile,
continue the latest conversation:

```bash
pi-run . -c
```

Or choose a saved conversation:

```bash
pi-run . -r
```

To find work across profiles and workspaces:

```bash
pi-run resume
```

Sessions are private records, not backups. Use the
[Workspaces and Sessions guide](workspaces-and-sessions.md) for listing,
relinking, and restored-session reconnection, and use
[encrypted snapshots](snapshots.md) for portable Pi-Run state.

[Documentation index](index.md) · [Profiles](profiles.md) ·
[Security](security.md)
