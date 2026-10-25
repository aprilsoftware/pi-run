# Pi-Run documentation

Pi-Run turns [Pi](https://pi.dev/) into a durable local work environment for
software development and system administration. One launcher provides a broad,
versioned toolchain, keeps agent state in visible user-owned profiles, and limits
host filesystem exposure to the selected workspace, profile, and narrowly
defined runtime resources.

The result is less host setup, clearer separation between work contexts, easier
continuation of long-running work, and practical controls for planning, command
review, remote access, backup, and recovery. Pi-Run runs locally through Docker;
it does not require a central Pi-Run server or database.

## How control works

Pi-Run aims for useful autonomy without turning every routine command into a
human approval prompt. The supplied default profile asks the agent to investigate,
propose a small verifiable increment, wait for approval, implement it, validate
the result, and stop before choosing the next increment. That lifecycle is an
opinionated starting point, not hard-coded enforcement: each profile owns an
editable `AGENTS.md` working contract.

Selecting a profile chooses the profile-managed identity, credentials,
instructions, skills, settings, and sessions exposed to the run. Only the
selected profile is mounted; other profiles remain outside, while everything in
the selected profile is available to that run. Credentials in the workspace or
optional shared mount, and access offered by reachable services, remain outside
this profile boundary.

Guard is an optional shared review layer. While it is On, one explicitly
selected evidence-aware reviewer handles Guardian-covered `bash` and `run` calls
and Call a Friend disclosures. Guardian releases supported commands without
interruption; otherwise it cancels the invocation and opens a human-arbitrated
dispute. The agent's structured position receives an advisory reassessment but
cannot grant itself authority or release the action. Guard review starts Off and
is not a sandbox.

Call a Friend lets the private primary agent request bounded advice from a
separately configured model. While Guard is On, each primary-to-friend
disclosure and public-search destination receives its own review. While Guard is
explicitly Off, enabled CAF sends the same bounded actions without a reviewer
request. The friend receives no automatic transcript, workspace, credential, or
general tool access. CAF is application-level context isolation, not a sandbox
or confidentiality proof.

The container narrows exposure, but selected mounts contain real host data and
the default backend uses host networking. Explicit offline and restricted TCP
modes narrow session networking with exact hosts, domains,
CIDRs, or public-internet rules without hiding mounted credentials. Profiles,
credentials, and external permissions bound authority;
instructions, Guardian, and human review reduce the likelihood of harmful
actions.

These controls assume something unexpected can still pass. Git history can
recover committed project content, while an independent workspace backup can
protect other files. Encrypted Pi-Run snapshots recover portable state but not
workspace source or remote-system data.
Databases, cloud resources, and other infrastructure need their own recovery
mechanisms.

Read [why Pi-Run exists](../README.md#why-pi-run-exists) for the fuller rationale
and the [design background](../README.md#design-background) for the motivating
essays.

## What Pi-Run brings

| Component | Benefit |
| --- | --- |
| [Runtime and installation](installation.md) | Pi, Node.js, language toolchains, diagnostics, service clients, and baseline extensions arrive in a versioned runtime image, paired with the restricted-egress image. Application upgrades leave user data untouched. |
| [Security boundaries](security.md) | A disposable container receives the selected workspace and profile—not the complete host home, every profile, or the Docker socket. Choose host, offline, or restricted TCP session networking explicitly. |
| [Profiles](profiles.md) | Select a purpose-specific identity, credentials, instructions, skills, preferences, and conversations. Only that profile is mounted, and all of it is available to the run. |
| [Skills](skills.md) and [shared files](security.md#treat-mounted-data-as-exposed) | Reuse reviewed expertise and supporting material across tasks without copying it into every request or every profile. |
| [Workspaces and sessions](workspaces-and-sessions.md) | Continue named conversations by stable workspace identity, find them across profiles, reconnect them after recovery, and use persistent managed Git worktrees for parallel repository sessions. |
| [Planning](planning.md) | Investigate alternatives, refine a saved plan, and approve an exact revision before handing work back to the normal execution workflow. |
| [Guardian](guardian.md) | Control the shared Guard review layer, review acting-agent `bash` and `run` calls, and focus human attention where judgment is needed. |
| [Call a Friend](call-a-friend.md) | Ask a separately configured model for bounded advice through constrained dialogue and optional public search, with destination-specific review whenever Guard is On. |
| [SSH access](ssh.md) | Give a profile a dedicated remote identity without mounting the host's entire SSH directory. |
| [Encrypted snapshots](snapshots.md) | Protect portable Pi-Run state, automate successful-exit recovery points, move between workstations, or restore deliberately. Use Git or backups for workspace and infrastructure data. |

These features reduce setup and make agent work easier to control and recover;
they do not make generated actions inherently safe. Planning is not read-only,
Guardian is not a sandbox, writable mounts remain real host files, and exposed
credentials retain their authority. Start with the benefits, then use the linked
guides to understand each boundary.

## Start here

- [Getting started](getting-started.md): open a workspace, connect a model,
  give Pi a bounded task, and continue a saved session.
- [Install and check Pi-Run](installation.md).
- [Upgrade](installation.md#upgrade) or
  [uninstall](installation.md#uninstall) while preserving user data.

## Configure your environment

- [Profiles](profiles.md): select instructions, configuration, credentials,
  resources, skills, and session context.
- [Skills](skills.md) and
  [shared files](security.md#treat-mounted-data-as-exposed).
- [Profile SSH keys](ssh.md#manage-profile-ssh-keys).
- [Security and isolation](security.md): mounts, networking, credentials,
  runtime privileges, trust, and exposure reduction.

## Plan, continue, and protect your work

- [Planning inside Pi](planning.md): discuss, save, inspect, export, and approve
  a plan without bypassing execution checkpoints.
- [Guardian and shared Guard review](guardian.md): configure review, arbitrate
  command disputes, and inspect private diagnostics while understanding its
  limits.
- [Call a Friend](call-a-friend.md): configure an advisory model, understand
  Guard-reviewed and unreviewed operation, continue bounded questions, and
  inspect separate diagnostics.
- [Workspaces and sessions](workspaces-and-sessions.md): identity, continuation,
  saved-session discovery, reconnection, and managed Git worktrees for parallel
  repository sessions.
- [Encrypted snapshots and recovery](snapshots.md): protect complete portable
  Pi-Run state without confusing it with workspace or infrastructure backup.

## Maintain Pi-Run

- [Build, test, architecture, and release maintenance](maintainers/development.md).
- [Access restricted release assets](maintainers/private-release-access.md).

[About Pi-Run](../README.md) · [License](../LICENSE)
