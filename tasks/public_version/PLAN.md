# pi-run public standalone version — implementation plan

## Status

- Planning only; no product code has been changed for this initiative.
- This document is the implementation reference and must be reviewed before Phase 0 begins.
- Each phase is split into reviewable increments. Completing one increment does not authorize the next phase automatically.
- Backward compatibility with the current internal layout, CLI, `pi-state`, or April Flow conventions is not a goal.

## Product goal

Turn `pi-run` into a neutral, open-source, standalone application that is:

- easy to install and run without cloning this repository;
- desktop-friendly even when operated from a terminal;
- understandable through a visible `~/Pi-Run` folder;
- configurable through complete user-owned profiles and reusable skills;
- portable between workstations through encrypted snapshots;
- able to discover and resume sessions without requiring the original repository path;
- explicit about access to workspaces, shared files, credentials, SSH agents, and other resources;
- usable without a central server or database.

## Decisions already made

1. The default user home is `${PI_RUN_HOME:-$HOME/Pi-Run}`. It is visible in desktop file managers; no hidden-dot directory is used by default.
2. `pi-state` and `/pi-state` are removed. No compatibility alias or migration is required.
3. Each profile directory is complete and authoritative. It contains its instructions, Guardian policy, Pi configuration, credentials, and sessions.
4. Profile files are not copied into a separate runtime state. The selected profile directory is the source of truth and is mounted read-write.
5. Only the selected profile is mounted into a running container. Other profiles and their credentials are not visible.
6. `/workspace` remains the single selected host working directory exposed read-write to the agent.
7. `${PI_RUN_HOME}/shared` is mounted read-write at `/shared` when granted to the profile.
8. Skills are reusable resources under `${PI_RUN_HOME}/skills`; only skills selected by the active profile are mounted.
9. The Guardian extension is installed and loaded by default, but review mode starts **Off**. Its commands, status, logs, and UI remain available.
10. The current path-derived session namespace is replaced by a stable logical workspace identity.
11. SSH agent integration is supported as an explicit local resource grant. The agent socket is never snapshotted.
12. April Flow names, paths, endpoints, email addresses, policy assumptions, and branding are removed from the public distribution.
13. Snapshot support is included, but continuous or bidirectional synchronization is not.
14. Snapshot storage targets local repositories and S3-compatible object storage, including Ceph RGW.
15. Restic is the preferred snapshot engine to validate and bundle; users must not install it separately.
16. No central `pi-run` server, PostgreSQL service, or multi-user control plane is part of this plan.
17. Pi-Run's original source code is licensed under the MIT License; bundled third-party software retains its own license terms.

## Decisions requiring review

These must be resolved before the affected increment starts:

1. **Public coordinates:** GitHub organization, container registry, image name, and release URL.
2. **Initial profile name:** `dev`, `default`, or another neutral name.
3. **Workspace marker:** registry only, optional repository-local marker, or local Git configuration marker.
4. **Specialized skills:** remove `norm4j-dev` and `tomee-dev`, or retain them only as optional non-default examples/packages.
5. **Pi-screen snapshot scope:** active profile plus shared files, or a request to perform a complete `Pi-Run` snapshot after Pi exits.
6. **Configuration format:** JSON is proposed to avoid another runtime parser.
7. **Shared folder default:** granted automatically to locally created profiles, or explicitly enabled per profile.

## Current behavior being replaced

Today the launcher:

- requires `pi-run <profile> <workspace>`;
- reads profiles and skills from this Git checkout;
- stores state under `${APRILFLOW_AGENT_DATA_DIR:-~/Repositories/aprilflow-pi-state}/<profile>`;
- copies `AGENTS.md` and optional `guardian.md` into profile state;
- mounts profile state at `/pi-state`;
- identifies workspace sessions using `<basename>-<hash of absolute host path>`;
- can browse sessions only after being launched from the corresponding profile and workspace;
- activates Guardian based on the presence of `guardian.md`.

The public version replaces this model directly rather than preserving it.

## Target `Pi-Run` home

```text
${PI_RUN_HOME:-$HOME/Pi-Run}/
├── config.json
├── README.md
├── profiles/
│   ├── dev/
│   │   ├── profile.json
│   │   ├── AGENTS.md
│   │   ├── auth.json
│   │   ├── models.json
│   │   ├── settings.json
│   │   ├── gitconfig
│   │   ├── credentials/
│   │   ├── guardian/
│   │   │   ├── guardian.md
│   │   │   ├── config.json
│   │   │   └── guardian.log*
│   │   └── sessions/
│   │       └── <workspace-id>/
│   └── ops/
│       └── ...
├── skills/
│   └── <skill>/
│       └── SKILL.md
├── shared/
├── workspaces/
│   └── registry.json
├── machines/
│   └── <machine-id>.json       # local paths and resource grants
└── snapshots/
    ├── config.json
    ├── metadata/
    ├── restore-staging/
    └── secrets                  # mode 0600; excluded from snapshots
```

The exact metadata files may be split for atomic writes, but the visible top-level model must remain simple.

### Path selection

Precedence:

1. `pi-run --home <path>`;
2. `PI_RUN_HOME`;
3. `$HOME/Pi-Run`.

The launcher provides:

```text
pi-run home
pi-run open-home
pi-run open-shared
pi-run open-profile <name>
```

`open-*` uses the platform file manager when available and otherwise prints the path.

### First run

A first run creates `Pi-Run`, its `README.md`, and an initial profile from a neutral installed template. After creation, files under `Pi-Run/profiles` and `Pi-Run/skills` belong to the user and are never overwritten by an application upgrade.

## Profile model

A profile is the unit of behavior, persistence, credentials, sessions, and isolation.

### Profile definition and runtime files

Shareable definition files:

```text
profile.json
AGENTS.md
guardian/guardian.md
```

Private/runtime files in the same profile directory:

```text
auth.json
models.json
settings.json
gitconfig
credentials/
sessions/
guardian/config.json
guardian/guardian.log*
```

Keeping them together is intentional: one directory represents the complete profile and is easy to inspect, snapshot, and restore.

Because the directory contains secrets, it must default to mode `0700`; sensitive files default to `0600`.

### Safe sharing

Copying a complete profile also copies its credentials and identity. Provide distinct operations:

```text
pi-run profile export <name>       # definition only; safe to share
pi-run profile backup <name>       # complete encrypted snapshot
```

`profile export` includes only `profile.json`, `AGENTS.md`, `guardian/guardian.md`, and validated profile-local skills. It never includes auth, credentials, Guardian preferences, sessions, logs, or machine grants.

Each created profile contains a short visible warning explaining that the complete directory is private.

### Profile management

```text
pi-run profile list
pi-run profile default [<name>]
pi-run profile show <name>
pi-run profile create <name> --from <template-or-profile>
pi-run profile edit <name>
pi-run profile export <name>
pi-run profile backup <name>
pi-run profile remove <name>
```

`${PI_RUN_HOME}/config.json` records the profile used when `--profile` is
omitted. `profile default <name>` validates the complete target profile and
updates that setting atomically; an explicit `--profile` remains a one-run
override. Profile creation without `--from` continues to use the neutral profile
named `default` rather than the configured launch default.

Creating a profile from another profile must ask separately before copying credentials or sessions. They are never copied implicitly.

### Example profile configuration

```json
{
  "schemaVersion": 1,
  "name": "dev",
  "skills": ["development", "ansible"],
  "resources": {
    "shared": "read-write",
    "sshAgent": "requested"
  }
}
```

A profile may request host resources, but imported profiles do not grant them automatically. Local grants are recorded only in `Pi-Run/machines/<machine-id>.json` after user approval; machine files are excluded from snapshots.

## Container model

For `pi-run --profile dev <workspace>`:

```text
Host                                   Container                    Mode
${PI_RUN_HOME}/profiles/dev            /profile                     read-write
${PI_RUN_HOME}/shared                  /shared                      read-write when granted
selected workspace                     /workspace                   read-write
selected skill directory               /skills/<skill>              read-only
host SSH agent socket                  /run/pi-run/ssh-agent.sock   socket when granted
host CA bundle                         standard container path       read-only
```

Environment and Pi arguments:

```text
PI_CODING_AGENT_DIR=/profile
GIT_CONFIG_GLOBAL=/profile/gitconfig
--session-dir /profile/sessions/<workspace-id>
```

There is no `/pi-state` mount and no startup copy of profile files.

### Why mount the selected profile directory

Mounting individual Pi configuration files can break applications that update files through atomic replace/rename. Mounting the complete selected profile directory:

- lets Pi safely update `auth.json` and settings;
- preserves direct host/container visibility;
- accommodates new Pi configuration files without launcher changes;
- keeps the security boundary understandable: selected profile versus every other profile.

The launcher validates that the selected profile resolves within `PI_RUN_HOME/profiles`, rejects unsafe symlink escapes, and never mounts the profiles parent directory.

## Skills

User-managed skills live under:

```text
${PI_RUN_HOME}/skills/<skill>/SKILL.md
```

The active profile selects skills through `profile.json`. Only selected directories are mounted read-only.

Management commands:

```text
pi-run skill list
pi-run skill add <profile> <skill>
pi-run skill remove <profile> <skill>
pi-run skill create <skill>
pi-run skill edit <skill>
pi-run skill import <source>
```

The installed application may provide neutral templates, but initialization/import is explicit. Upgrades never overwrite user skill directories.

The current `aprilflow-development` skill is replaced with a neutral equivalent or removed. Organization- and product-specific skills are not selected by the default profile.

## Guardian

- Guardian code remains a versioned extension in the runtime image.
- The extension loads for standard profiles regardless of review mode.
- It reads policy directly from `/profile/guardian/guardian.md`; no policy copy is created.
- Without `/profile/guardian/config.json`, review mode starts Off and the reviewer follows the conversation model and thinking level.
- `/guardian-mode`, `/guardian-model`, and `/guardian-thinking` atomically save private profile preferences in `guardian/config.json`.
- Definition export excludes Guardian preferences and logs.
- `/guardian`, status, logs, model/thinking controls, and enable/disable remain functional.
- Interactive status uses one minimal, width-aware row: current Guardian state on the left and reviewer model/thinking on the right.
- Elapsed time is shown only during an active review; completed durations remain in the log and idle status returns immediately to On.
- `/guardian-log` presents only actual retained review attempts across sessions. It excludes Guardian-Off skips and raw diagnostic events while retaining search, refresh, and Summary, Command, Evidence, and Timeline details.
- Logs are written under `/profile/guardian/` and are part of the complete profile snapshot unless excluded.

Planned host controls:

```text
pi-run guardian status <profile>
pi-run guardian enable <profile>
pi-run guardian disable <profile>
pi-run guardian edit <profile>
```

## Shared folder

`${PI_RUN_HOME}/shared` is a deliberate host/container exchange area mounted at `/shared`.

Typical content:

```text
shared/
├── inputs/
├── outputs/
├── documents/
├── inventories/
└── generated/
```

Safety rules:

- nothing in `shared` is automatically executed;
- it is not automatically scanned for skills, extensions, prompts, or credentials;
- profiles must have a local grant before it is mounted if explicit grant mode is selected;
- it is included in complete snapshots by default, with configurable exclusions for large/cache directories;
- its purpose and mount mode are shown at startup.

## SSH agent and credentials

### Preferred SSH mode

When granted, mount the current host `SSH_AUTH_SOCK` at a stable container path and set:

```text
SSH_AUTH_SOCK=/run/pi-run/ssh-agent.sock
```

This enables OpenSSH, Git, rsync, Ansible's OpenSSH connection plugin, and similar tools without copying private keys into the container or snapshot.

The launcher must:

- verify that the host path is a Unix socket;
- mount only that socket, never all of `~/.ssh`;
- show that signing/authentication capability is being granted;
- resolve the socket on every launch;
- never snapshot it.

Recommended user protections include dedicated agents, short key lifetimes, confirmation-required keys, destination constraints, and hardware-backed keys.

### File credentials

`/profile/credentials` remains available for kubeconfigs, certificates, cloud configuration, and headless SSH identities. These files are visible only to the selected profile and are included only in encrypted snapshots.

Profile-local SSH configuration and `known_hosts` may be stored under credentials or a documented profile subdirectory. Private keys are optional when the SSH agent is used.

## Workspace and session model

### Logical workspace

A workspace represents one checkout or working directory, not every clone of the same Git remote.

Portable metadata records a stable UUID, display name, kind, and optional Git remotes. Machine metadata maps that UUID to a local path. Git metadata may suggest a match but cannot silently bind a session to a checkout.

Example:

```json
{
  "schemaVersion": 1,
  "id": "<uuid>",
  "name": "example-project",
  "kind": "git",
  "gitRemotes": ["https://example.invalid/org/example-project"]
}
```

### Session placement

```text
${PI_RUN_HOME}/profiles/<profile>/sessions/<workspace-id>/*.jsonl
```

Sessions remain associated with the profile that created them because a different profile may expose different credentials, instructions, skills, and resources.

### Launcher experience

No legacy syntax is promised. Target forms:

```text
pi-run .                         # configured default profile, current workspace
pi-run --profile ops .
pi-run open <workspace>
pi-run resume                    # global profile/workspace/session picker
pi-run workspace list
pi-run workspace link <workspace> <path>
```

If a snapshotted workspace has no local path, the launcher offers to locate an existing checkout or leaves it unavailable. It does not silently clone or mount a heuristic match.

A running container cannot mount a different host workspace. Global workspace/session selection belongs to the host launcher. A future Pi command may request a controlled exit and relaunch, but that is not required initially.

## Snapshot MVP (no synchronization)

### Packaging

Restic is bundled in the runtime image as a pinned, checksum-verified binary. The build supports at least `amd64` and `arm64`, or fails clearly on unsupported architectures.

### Interfaces

```text
pi-run snapshot configure
pi-run snapshot status
pi-run snapshot create
pi-run snapshot create --profile <name>
pi-run snapshot list
pi-run snapshot diff <snapshot>
pi-run snapshot stage-restore <snapshot>
pi-run snapshot check
```

Pi interface:

```text
/snapshot
```

The extension is a thin UI over a separately testable helper. Recovery must work from the host command even when Pi cannot start.

### S3 organization

Default proposal:

```text
s3://<bucket>/users/<stable-user-id>/restic
```

One bucket can serve a deployment while each user has an independent encrypted Restic repository/prefix and password. Per-user buckets remain configurable.

### Snapshot set

Complete snapshots include:

```text
Pi-Run/config.json
Pi-Run/profiles/
Pi-Run/skills/
Pi-Run/shared/
Pi-Run/workspaces/
Pi-Run/snapshots/config.json
```

They exclude:

```text
Pi-Run/machines/
Pi-Run/snapshots/secrets
Pi-Run/snapshots/restore-staging
temporary locks
SSH agent sockets
explicit shared-folder cache exclusions
```

Because complete profiles contain credentials, Restic encryption is mandatory.

### Safety invariants

- Snapshot objects are immutable in normal flows.
- No prune/delete command is provided in the MVP.
- Restore always targets staging first.
- Current local data is snapshotted before applying a restore.
- Restore is applied before the next Pi process starts, not over live profile/session files.
- Workspace source trees are excluded by default.
- Manifests record pi-run version, Pi version, profile/workspace schema versions, included paths, and exclusions.
- The Pi extension never mounts every profile merely to create a full snapshot; it snapshots its allowed scope or requests a host-side snapshot after exit.

## Standalone distribution

A release contains:

- the `pi-run` host launcher;
- neutral profile and skill templates;
- the versioned runtime image;
- checksums and installation metadata.

Target installation:

```text
curl -fsSL <release-url>/install.sh | sh
pi-run .
```

The installer:

- verifies release checksums;
- installs the launcher under a user-local executable directory by default;
- pulls the pinned runtime image;
- creates `$HOME/Pi-Run` on first run, not during an unrelated package operation;
- never removes `Pi-Run` during upgrade or uninstall unless explicitly requested.

No host Pi, Node, Restic, source checkout, or April Flow repository is required.

## Implementation phases

### Phase 0 — Characterize current behavior and add a test harness

**Purpose:** establish a safety net for intentional replacement.

Increments:

1. Add shell tests for argument parsing, workspace canonicalization, profile/skill selection, Docker arguments, and entrypoint UID/GID behavior using fake dependencies.
2. Add a documented image smoke matrix for Pi, baseline extensions, sessions, and Guardian.
3. Add mount-inventory tests proving that only the selected workspace/profile/skills are exposed.
4. Resolve current ShellCheck findings or document tightly scoped exceptions.

Acceptance:

- tests describe current effects without committing the public version to compatibility;
- `bash -n` passes;
- tests do not contact real infrastructure or expose credentials.

### Phase 1 — Neutral open-source baseline

**Purpose:** remove organizational assumptions and establish public identity.

Increments:

1. Add the selected license and third-party notices process.
2. Rewrite README and examples for the standalone product.
3. Remove April Flow branding, internal endpoints, internal email addresses, monorepo paths, and internal policy assumptions.
4. Define public command, environment, image, and release names without deprecated aliases.
5. Replace profiles and generic skills with neutral templates; remove/separate specialized content.
6. Load Guardian as a baseline extension in Off mode.

Acceptance:

- repository-wide checks find no unintended internal references;
- examples use placeholders;
- Guardian commands work while default tool calls are not reviewed;
- no source path or internal service is required by documentation.

### Phase 2 — Upgrade and pin Pi

**Purpose:** move to a tested current Pi release before building new state features.

At plan creation, npm reported Pi `1.0.4`, Pi Web Access `0.37.0`, and Pi OKF `0.4.0`. Recheck immediately before implementation and pin exact reviewed versions.

Increments:

1. Pin Pi and every baseline extension explicitly.
2. Update Guardian's legacy imports and lower-level Pi API usage.
3. Validate Pi 1.x project trust, resource discovery, Codemode/MCP defaults, sessions, and fullscreen behavior.
4. Run profile/session/extension/Guardian smoke tests.

Acceptance:

- image reports expected versions;
- web access, OKF, sessions, model configuration, and selected skills work;
- Guardian loads Off and works when enabled;
- no new automatic resource broadens access unexpectedly.

### Phase 3 — `Pi-Run` home, profiles, skills, shared folder, and SSH agent

**Purpose:** replace `pi-state` and source-checkout configuration with the final user model.

Increments:

1. Implement `PI_RUN_HOME`, `--home`, and the visible `$HOME/Pi-Run` default.
2. Implement first-run initialization and generated `Pi-Run/README.md`.
3. Implement profile validation and selected-profile read-write mount at `/profile`.
4. Point Pi and Git directly at the selected profile; remove all `AGENTS.md`/Guardian copying and `/pi-state` use.
5. Implement user skill selection and read-only selected-skill mounts.
6. Implement `/shared` as an explicit read-write resource with startup visibility.
7. Implement profile/skill/Guardian management commands in separate reviewable increments.
8. Implement safe definition-only profile export.
9. Implement optional SSH agent socket validation, grant, mount, and startup reporting.

Acceptance:

- host and container observe the same selected profile files;
- Pi can update auth/settings safely;
- no other profile is mounted;
- shared files are read-write on both sides and never auto-executed;
- only selected skills are visible;
- SSH tools can use an explicitly granted host agent without private-key copying;
- `pi-run home` and file-manager commands work;
- Guardian remains loaded with review mode Off by default.

### Phase 4 — Stable workspace registry and global session discovery

**Purpose:** replace path-derived session identity.

Increments:

1. Add stable workspace UUIDs and registry metadata.
2. Add machine/path mappings and explicit relinking.
3. Store sessions under `<profile>/sessions/<workspace-id>`.
4. Auto-register a new current directory with a clear name.
5. Add workspace list/show/register/link/remove commands.
6. Add launcher-level global resume selection across profiles and workspaces.

Acceptance:

- moving a checkout is repaired by relinking without moving sessions;
- restored sessions remain discoverable before their workspace is located;
- same-name workspaces do not collide;
- clones remain separate unless explicitly linked;
- no heuristic Git match is mounted without confirmation.

### Phase 5 — Standalone installation and releases

**Purpose:** eliminate the source-checkout requirement.

Increments:

1. Define versioned release archive and runtime image coordinates.
2. Make launcher discovery independent of this repository.
3. Add checksum-verifying installer and clean uninstall behavior.
4. Add `pi-run version`, `doctor`, installation, upgrade, and recovery documentation.
5. Add architecture-aware tool downloads or explicit unsupported-platform errors.

Acceptance:

- a clean Linux account can install and run `pi-run .` without cloning the repository;
- no host Pi, Node, or Restic is required;
- upgrades do not overwrite `~/Pi-Run`;
- uninstall leaves user data intact by default.

### Phase 6 — Snapshot MVP

**Purpose:** back up and restore `Pi-Run` locally or through Ceph S3 without synchronization.

Increments:

1. Add pinned, checksum-verified Restic to the image.
2. Implement the helper with a local Restic repository first.
3. Add Ceph/S3 configuration and connectivity validation.
4. Add create/list/show/diff/check operations.
5. Add staged restore, validation, pre-restore snapshot, and next-start application.
6. Add `/snapshot` as a thin Pi UI.
7. Add host recovery through the same image/helper.

Acceptance:

- no host Restic installation is required;
- recovery works when Pi cannot start;
- complete profiles and credentials are encrypted;
- bootstrap secrets are excluded;
- restore never overwrites live files;
- no automatic synchronization, conflict merge, prune, or remote deletion exists.

### Phase 7 — Public release hardening

**Purpose:** make the first public release supportable and reproducible.

Increments:

1. Add CI for syntax, static analysis, tests, and image architecture builds.
2. Generate release checksums, image provenance/SBOM, and third-party license inventory.
3. Add security policy, contribution guide, vulnerability reporting, and release procedure.
4. Test fresh install, profile creation, workspace relinking, session resume, snapshot/restore, upgrade, and uninstall from clean environments.
5. Document recovery for missing workspaces, corrupt profiles, failed restores, and stale Restic locks.
6. Tag and validate a release candidate before stable publication.

Acceptance:

- release inputs and versions are identifiable;
- clean installation and upgrade paths pass;
- snapshot restore and workspace relinking pass;
- no real credentials, internal endpoints, or private assumptions are present.

## Validation matrix

| Area | Checks |
|---|---|
| Home | default `~/Pi-Run`, override, spaces, symlinks, permissions, file-manager commands |
| Profiles | create, select, malformed config, private permissions, safe export, only selected profile mounted |
| Skills | selected only, invalid name, missing `SKILL.md`, read-only mount, import trust |
| Guardian | loaded, default Off, status/log UI, enable/disable, allow, ask, refusal, unavailable review |
| Shared | absent, disabled, read-only option if added, read-write host/container, no auto-discovery/execution |
| SSH agent | absent socket, valid socket, explicit grant, revocation, changed socket, no snapshot inclusion |
| Workspaces | new, moved, missing, same-name clones, explicit relink, no silent heuristic binding |
| Sessions | new, continue, resume, named, cross-profile separation, restored workspace unavailable |
| Snapshot | local, Ceph S3, wrong password, unavailable endpoint, exclusions, staged/interrupted restore |
| Security | no Docker socket, no unrelated profiles, no secret output, symlink escape rejection, file modes |
| Architectures | amd64 and arm64 where supported |

## Principal risks

1. **Profile sharing leaks secrets:** complete profiles are private; provide definition-only export and visible warnings.
2. **Profile mount escape:** validate canonical paths and reject unsafe symlinks before constructing mounts.
3. **Session misbinding:** require explicit workspace relinking rather than silent Git heuristics.
4. **Shared folder execution:** never auto-load or execute content from `/shared`.
5. **SSH agent authority:** a socket hides private keys but grants authentication/signing capability; require explicit local grant and display it.
6. **Guardian compatibility:** Guardian uses lower-level Pi APIs and needs focused Pi upgrade tests.
7. **Restore self-corruption:** stage restores and apply only before Pi starts.
8. **Snapshot bootstrap loop:** S3 and Restic unlock credentials must remain independently provisioned and excluded.
9. **Branding leakage:** inspect docs, images, skills, examples, variables, and logs.
10. **Architecture support:** current downloads are hard-coded for AMD64.
11. **Public supply chain:** pin dependencies, verify downloadable binaries, and inventory licenses.
12. **Scope growth:** implement each phase as bounded increments rather than one rewrite.

## Explicit non-goals

- compatibility with `pi-state`, `APRILFLOW_*`, old paths, or old launcher syntax;
- automatic import/migration of existing private installations;
- continuous or bidirectional synchronization;
- automatic conflict merging;
- a central multi-user server;
- PostgreSQL or another mandatory database;
- remote workspace provisioning;
- sharing one live session between multiple active workstations;
- automatic snapshot pruning/deletion;
- snapshotting arbitrary host directories or an entire workstation;
- mounting every profile into one container;
- weakening the selected-workspace boundary;
- enabling Guardian review mode by default.

## Recommended review order

1. Confirm the remaining product decisions, especially license, initial profile name, and public coordinates.
2. Review the exact `Pi-Run` directory and profile schema.
3. Review resource grants for `/shared`, SSH agent, and future credentials.
4. Review workspace identity and global resume behavior.
5. Confirm phase order and approve Phase 0 only; each later phase should receive a concrete increment proposal after the preceding result.

## Upstream references

- Pi documentation: <https://pi.dev/docs/latest/>
- Pi repository: <https://github.com/earendil-works/pi>
- Pi Durable (future research, not required here): <https://github.com/earendil-works/pi/tree/main/packages/durable>
- Restic S3 setup: <https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html>
- Restic backup/restore: <https://restic.readthedocs.io/en/stable/040_backup.html> and <https://restic.readthedocs.io/en/stable/050_restore.html>
- Ceph RGW S3 API: <https://docs.ceph.com/en/latest/radosgw/s3/>
