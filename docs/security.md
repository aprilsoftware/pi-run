# Security and isolation

Pi-Run puts Pi, its tools, extensions, and generated commands in a temporary
container instead of running them directly across your host environment. A
normal session receives the workspace, profile, and optional resources selected
for that task—not your complete home directory or every Pi-Run profile.

This reduces accidental exposure and makes the boundary easier to understand. It
does **not** make model-generated actions safe or turn the container into a
sandbox or virtual machine. Treat commands, code, instructions, web content, and
tool output as untrusted.

## Understand a normal launch

A normal Pi-Run session can access:

| Resource | Exposure |
| --- | --- |
| Selected workspace | Writable at `/workspace` |
| Selected profile | Writable at `/profile`, including its credentials and sessions |
| Shared directory | Writable at `/shared` when enabled by the profile |
| Profile-local skills | Writable inside the selected profile |
| Selected global skills | Mounted read-only |

The image filesystem is temporary and removed after the run. Host-backed files
are not temporary: changes under `/workspace`, `/profile`, and optional `/shared`
are real host changes.

A normal session does not mount the host home, other profiles, machine-local
workspace mappings, snapshot repositories and recovery secrets, or the Docker
socket. Technical mounts and operation-specific management containers are
listed in the [security reference](reference/security.md#normal-session-mounts).

## Account for host networking

Normal sessions use host networking. From Pi-Run, `localhost` can reach services
on the Docker host, and LAN, internet, cloud, cluster, or database endpoints may
also be reachable.

Filesystem exposure can therefore be narrow while network authority is broad.
A credential can turn a reachable endpoint into real access. Do not assume a
service is disposable because it is called local, dev, or runs in a container.
Name the actual host, account, cluster, namespace, database, operation, and
intended effect for administrative work.

Pi-Run does not provide a per-session network allowlist. Enforce stronger
network separation outside Pi-Run when a task requires it.

## Treat mounted data as exposed

The selected profile can contain provider authentication, SSH keys, model
settings, Guardian diagnostics, and conversation history. The running agent and
other container processes can read or change files allowed to the mapped user.
A separate profile limits which context is selected; it does not protect secrets
inside that profile from the selected run.

The initial profile enables writable `/shared`. Shared files are not loaded as
instructions automatically, but tools can read and modify them. Set
`resources.shared` to `disabled` when the task does not need shared data, then
restart Pi-Run.

Read-only global skill mounts prevent package modification, not execution of
scripts or influence on writable files and services. Review complete packages
before selecting them; see [skill trust](skills.md#validation-and-trust).

## Treat content and code as untrusted

Prompt injection can arrive through source files, `AGENTS.md`, documentation,
web pages, issues, logs, dependency metadata, command output, and model replies.
A request to inspect content does not authorize instructions embedded in it.

Pi-Run explicitly loads its managed extensions and skills instead of broadly
discovering them, but structural validation cannot decide whether their content
is trustworthy. Extensions run inside the Pi process with the selected mounts
and network. Use only reviewed skills and trusted runtime images.

Project trust controls supported Pi project resources, not tool permissions.
Context such as `AGENTS.md` can still load, and enabled tools retain their runtime
access. See [Pi's security guidance](https://pi.dev/docs/latest/security/).

## Know what workflow controls do not enforce

- Instructions define expected authorization and workflow; they do not reduce
  operating-system access.
- Planning changes the objective, not tool permissions, and is not read-only.
- Guardian normally reviews acting-agent calls named `bash` and `run`; while a
  dispute is open, it withholds every acting-agent tool except bounded native
  reads and its structured justification handoff. It is not a sandbox.
- Project trust does not constrain tool access after startup.
- A visible or successful command result is not independent verification.
- Available credentials, clients, skills, and network paths are not permission to
  use them.

Use [Planning](planning.md), [Guardian](guardian.md), explicit task limits, and
human review as control layers while keeping technical exposure small.

## Reduce exposure before launch

1. **Choose the smallest useful workspace.** Do not open a parent directory with
   unrelated repositories, secrets, or operational data. Pi-Run has no read-only
   workspace mode.
2. **Use a purpose-specific profile.** Keep unrelated provider accounts, remote
   credentials, sessions, and private skills elsewhere.
3. **Disable optional resources.** Turn off shared access and filter global
   skills. Restart after changing exposure.
4. **Review the runtime and project.** Use a trusted image and inspect unfamiliar
   instructions, extensions, and skill packages.
5. **State operational boundaries.** Name targets, effects, sequencing, and
   prohibitions. Reachability and credentials do not grant blanket authority.
6. **Prepare recovery.** Commit or back up workspace source and use
   [encrypted snapshots](snapshots.md) for portable Pi-Run state.

Useful host-side checks are:

```bash
pi-run version
pi-run --profile operations doctor
pi-run --profile operations skill list
```

The launcher reports the selected profile, workspace, and shared mount at
startup. Stop if they do not match your intention.

## Protect private records

Profiles, sessions, Guardian logs, recovered snapshots, and exported plans can
contain prompts, file excerpts, commands, output, paths, and credentials. Do not
publish them without inspection and redaction.

Encrypted snapshots include all profiles and credentials, but exclude repository
recovery passwords and S3 credentials. Preserve those through a separate private
method. Source control is not an appropriate backup for profile state or secrets.

## Respond to suspected exposure

1. Stop the affected run and do not automatically retry uncertain actions.
2. Identify the mounted files, credentials, network targets, commands, and time
   window involved.
3. Preserve useful evidence without sharing secrets.
4. Verify local and remote effects independently.
5. Revoke or rotate affected provider tokens, keys, passwords, and remote SSH
   authorization through the systems that trust them. Local key deletion alone
   does not revoke a remote `authorized_keys` entry.
6. Restore reviewed files or Pi-Run state only after understanding the effect;
   do not use a broad reset as unexplained cleanup.

For the exact mount allowlist, runtime identity, capabilities, CA trust,
discovery controls, project trust, and alternate-image boundary, see the
[Security reference](reference/security.md).

[Documentation index](index.md) · [Getting started](getting-started.md) ·
[Profiles](profiles.md)
