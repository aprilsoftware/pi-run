# Profile-owned runtime Dockerfiles

## Status

This document records the implemented product design and acceptance evidence for
profile-specific Pi-Run runtimes. The implementation is present in the current
source tree, but this record is not authority to change release metadata, commit,
publish images, or begin later work. Those remain separate increments.

## Product goal

Pi-Run no longer imposes one broad development workstation on every profile.
Each profile defines the tools needed for its purpose while retaining Pi-Run's
common launch, identity, policy, session, and recovery contracts.

The design optimizes for first users rather than preserving the current runtime
layout. A profile without the new definition may fail with a clear setup command;
there is no requirement for a silent full-image fallback.

## Authoritative profile layout

Every profile uses one fixed location:

```text
<profile>/
├── profile.json
└── runtime/
    ├── Dockerfile
    ├── .dockerignore
    └── optional build assets
```

`runtime/Dockerfile` is the authoritative runtime definition and `runtime/` is
the complete Docker build context. `profile.json` does not duplicate the path or
hide bundle selection. The profile directory is the portable source of truth:
`profile.json` owns ordinary settings, while the runtime directory owns image
composition.

Pi-Run never uses the profile root, workspace, sessions, credentials, Todo state,
or logs as an implicit build context.

## Core image and local derivation

Pi-Run publishes a small immutable core image for each release and architecture.
The host builds the profile image locally from its exact digest:

```dockerfile
# syntax=docker/dockerfile:1

ARG PI_RUN_BASE_IMAGE
FROM ${PI_RUN_BASE_IMAGE}

# Profile-owned Docker instructions follow.
```

Pi-Run supplies `PI_RUN_BASE_IMAGE`; users can use normal Dockerfile and BuildKit
syntax after `FROM`. A generated Dockerfile becomes user-owned. Pi-Run does not
silently regenerate it, replace edited blocks, or add capabilities on upgrade.

## Built-in bundles

A built-in bundle is a reviewed Dockerfile fragment shipped with Pi-Run. It is a
convenience for generating ordinary Docker instructions, not a second package
language. The release-owned source is
`templates/runtime/full-development.Dockerfile`, which is also a complete
core-derived Dockerfile for reviewing the aggregate.

The maintained bundle names are `utility-belt`, `network-diagnostics`,
`python-development`, `operations`, `native-development`, `java-development`,
`rust-development`, `headless-gui`, `flutter-development`, `database-clients`,
and `kubernetes`. Current downloaded SDK/tool binaries retain the broad image's
amd64 contract; architecture expansion remains separate work.

Profiles have no separate bundle manifest or lock file. `runtime add` inserts the
complete fragment between visible `# BEGIN PI-RUN BUNDLE <name>` and matching
`# END` markers. Markers support duplicate detection and navigation; the
Dockerfile text remains authoritative after insertion.

## The `all` aggregate

Pi-Run provides `all`, described as the full-development group, representing
every maintained capability in the current broad runtime.

`runtime add all` expands every member directly into the Dockerfile in this
order: utility belt, network diagnostics, Python, operations, native, Java,
Rust, headless GUI, Flutter, database clients, and Kubernetes. The maintained
full-development template records that exact expansion. It leaves no hidden
reference whose meaning changes on upgrade, and includes each member once.

Later releases may change their catalog, but existing profile Dockerfiles remain
unchanged until deliberately edited.

## Command contract

Profile-sensitive commands use Pi-Run's normal selected-profile mechanism, such
as `pi-run --profile java-dev runtime build`. Exact parser wiring is an
implementation detail; command meanings are fixed below.

### `pi-run runtime list`

List release-owned fragments and aggregate groups without modifying a profile or
contacting Docker. Output shows name, type (`bundle` or `group`), and a short
description. `all` is visibly a group, not an image variant.

### `pi-run runtime init`

Create `runtime/`, a bounded `.dockerignore`, and the core-derived Dockerfile
for a legacy profile. Refuse existing runtime content rather than replacing it.
Fresh and newly derived profiles already materialize the same base layout.

### `pi-run runtime add <bundle>`

Append one built-in fragment without building. Validate the profile path, reject
unknown names and duplicate generated blocks, and report the changed file.

`runtime add all` expands the aggregate. A custom fragment can be inserted with:

```text
pi-run runtime add --file ./company-tools.Dockerfile
```

The exact source is visible in the maintained aggregate and inserted by the
explicit command. Assets referenced by
`COPY` must be placed deliberately under `runtime/`. Direct Dockerfile editing
always remains supported.

### `pi-run runtime status`

Report profile, Dockerfile, context, exact local base image ID, current source identity,
matching local image, and the build command when no match exists. Perform no
build or pull.

### `pi-run runtime build`

Perform the explicit host-authorized Docker build. Before execution, report the
profile, context, base image ID, source identity, build-network/code-execution
boundary, and absence of implicit profile credentials or workspace files.

The explicit `runtime build` command is itself the host-side authority; it has no
secondary confirmation or `--yes` option. The operation supplies no Docker
socket to the agent and no implicit Docker secrets, SSH forwarding, host mounts,
or credentials.

## Source identity and image reuse

A conservative identity covers:

- exact selected local core image ID;
- Pi-Run build-contract version;
- architecture;
- every entry under `runtime/`, including relative path, type, permissions,
  regular-file content, and symlink target text without following links;
- relevant explicit build options.

Hashing the full directory may invalidate an image for a Docker-ignored file,
but avoids silent reuse after any runtime input changes.

The build gets a stable profile-path-derived tag and identity labels through
`docker build --label`, including build contract, exact local core image ID,
context hash, architecture, and source hash. Labels are build outputs, not
profile metadata. Launch recomputes the identity and validates every label before
using the stable tag.

When context or core changes, launch refuses the stale image and prints the exact
build command. It never builds automatically or falls back to the old universal
image. Running containers retain their selected image.

## Build and trust boundary

A profile Dockerfile is trusted build code. It can download mutable content,
install unpinned packages, override the entrypoint, or create a hostile image.
Pi-Run provides transparency and bounded inputs, not a guarantee that arbitrary
Docker instructions are safe or reproducible.

Pi-Run must:

- build only after a human-facing host action;
- use only the selected profile's `runtime/` directory as context;
- reject paths escaping that directory and avoid following links while hashing;
- add no profile credentials, sessions, workspaces, or host secrets;
- freeze the exact selected core image ID under a private temporary tag;
- validate final architecture and identity labels;
- refuse missing, stale, malformed, or incompatible images clearly.

The selected profile is writable to its agent. An agent may edit the Dockerfile,
but that edit cannot invoke Docker. The separate host build is the authority
boundary.

## Current Dockerfile inventory

`docker/core/Dockerfile` is the release-authoritative image definition, built
from the `docker/` context with `--file docker/core/Dockerfile` and published at
the existing versioned `ghcr.io/aprilsoftware/pi-run` coordinate. Older tags
remain immutable broad images. The retained `docker/Dockerfile` records the old
broad inventory but is not selected by the release workflow.

### Core

- Slim Node 24, npm/Corepack, and exact Pi, pi-web-access, and pi-okf.
- Pi-Run extensions, core skills, licenses, entrypoint, UID/GID mapping, and
  network-policy resolver.
- Bash, CA certificates, OpenSSL, `passwd`, and `gosu` for startup contracts.
- Git, OpenSSH, and netcat while managed worktrees and restricted managed SSH
  require them in the selected runtime.
- `jq`, `curl`, and `ripgrep` while core skills and diagnostics rely on them.
- Restic while Snapshot uses the selected runtime rather than a helper image;
  download-only dependencies remain in a separate build stage.

### Candidate optional fragments

- Utility and network diagnostics: archive/XML tools, ShellCheck, `rsync`, DNS,
  `iproute2`, ping, traceroute, and maintained troubleshooting commands.
- Operations and data: Ansible plus PostgreSQL, Redis, MySQL, and SQLite clients.
- Java, Python, native, and Rust development toolchains.
- Flutter, Dart, and headless Linux GUI dependencies: ALSA, GTK, Mesa,
  Vulkan/DRI, XKB, Xauth, and Xvfb.
- Kubernetes tooling: kubectl, Helm, Kustomize, and yq.

### Core split boundaries

Java trust initialization is capability-aware. The core carries the shell setup
and `PiRunJavaTrustStore.java` source without requiring a JDK. Startup skips the
bridge when Java is absent. When Java is present, it executes the source helper,
requires valid default and host trust inputs, and atomically replaces the Java
trust store. The Java fragment must therefore install a JDK with source-file
mode rather than relying on a class compiled into the core.

Restic and Git remain core until Snapshot and managed-worktree evidence proves
that moving them to helpers or optional images preserves contracts. Image size
alone does not authorize moving a dependency.

## Profile lifecycle

A newly initialized home gives its default profile the core-derived runtime
layout. `profile create --from` copies a source runtime context as portable
definition data; a legacy source without one receives the same base definition.
This creates reviewable source but never builds an image.

Copied contexts permit directories, regular files, and un-followed symlinks.
Regular files must have one hard link. Contexts are limited to 4,096 entries and
512 MiB of regular-file content, and must contain safe `Dockerfile` and
`.dockerignore` files. Credentials, sessions, logs, Docker layers, and local
build cache are not copied. Encrypted snapshots include `runtime/` with the
profile, while restored profiles rebuild images locally.

Existing profiles are not migrated automatically. A profile without
`runtime/Dockerfile` can use explicit `runtime init`; there is no invisible
compatibility default.

## Acceptance contract

Core acceptance must prove launch, profile mounting, Guard Runtime, Guardian,
CAF, Plan, Todo, Snapshot, networking, sessions, worktrees, UID/GID mapping, CA
behavior, and Doctor diagnostics appropriate to core.

`runtime add all` must additionally prove the current maintained tool inventory:
language/SDK versions, minimal compiler builds, Ansible local operation, Java CA
trust, Flutter/Dart, Xvfb, Vulkan/DRI/ALSA/XKB, Kubernetes tools, database
clients, Restic, complete isolated tests, and applicable real-Docker worktree and
restricted-network checks.

Custom-runtime acceptance must show that edits change source identity, stale
images are refused, context cannot escape `runtime/`, no secret paths are added,
incompatible images fail checks, and unchanged input reuses the exact image.

## Acceptance results and remaining decisions

Catalog, initialization, bundle insertion, identity, status, explicit build,
strict launch selection, profile lifecycle integration, Doctor/version
presentation, packaging, and release-workflow selection are implemented in
source. Deterministic tests cover custom context changes, stale and incompatible
images, bounded context handling, launch refusal, and exact prepared-image
selection.

The isolated executable suite passes with **68 PASS and 7 SKIP**. The three
Docker-gated skips were then executed on a Docker-capable Linux/amd64 host and
passed:

- `tests/runtime-images-e2e-test.sh` built and ran core image
  `sha256:fcfa4def1cd1d2a312ee03833302f596e9fd863bfbee3142abd97252bc91c3e8`
  and full-development image
  `sha256:cf1aced2cd6f249168f97d738a8b7aee611b582e87f883a49f41fa0943f85343`,
  with source identity
  `b74f0748c369bb90733195e05389f55e2977e170abc707a9df335eeee1599dda`;
- `tests/worktree-e2e-test.sh` passed the real start, open, finish, and restart
  lifecycle with a prepared profile image;
- `tests/docker-egress-rules-e2e-test.sh` passed production restricted-egress
  allow and block cases using egress image
  `sha256:13db8cc4aabd306151b4d98c4e68a387febfb35e151ac1717e56c4a0d1b97d0e`.

The four remaining skips are optional live-provider Guardian/CAF evaluations,
not runtime-image acceptance gaps. The v0.10.12 acceptance run observed Docker's
`InvalidDefaultArgInFrom` warning for the intentionally required base argument.
Commit `ae68bb1` suppresses only that check through Docker's built-in check
control and passed the same real-Docker runtime acceptance without the warning;
it is assigned to the v0.10.13 candidate and is not part of immutable v0.10.12.
Ansible's interpreter-discovery warning remains a separate non-failing
observation.

The runtime foundation, core image cutover, and profile build workflow were
released as immutable v0.10.12. The v0.10.13 warning fix is prepared but not
published. One optional future design question remains: whether Git or Restic
should later move from the core to dedicated helpers. No such change or later
publication is implied by this record.
