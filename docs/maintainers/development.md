# Develop and release Pi-Run

This guide is for maintainers building Pi-Run from a source checkout, validating
changes, creating application archives, or operating the release workflow. User
installation and configuration belong in the [user documentation](../index.md).

## Requirements

Development and release builds currently target Linux/amd64. The host needs
Bash, Docker, `jq`, and standard GNU command-line tools. Image builds also need
network access to the upstream package and binary sources declared by
`docker/core/Dockerfile` and the selected profile runtime Dockerfile.

Tests may require additional commands for the behavior they cover. They create
temporary homes and use fake Docker, Restic, SSH, and network fixtures where
appropriate; they must not use real profiles, credentials, repositories, or
remote systems.

## Build and run a development profile runtime

From the repository root, build the same small core used by releases, initialize
a disposable home, and explicitly prepare its profile image:

```bash
docker build -t pi-run:dev-core -f docker/core/Dockerfile docker
PI_RUN_HOME="$(mktemp -d)"
export PI_RUN_HOME
./bin/pi-run init
PI_RUN_CORE_IMAGE=pi-run:dev-core \
  PI_RUN_IMAGE=pi-run:dev-core ./bin/pi-run runtime build
PI_RUN_CORE_IMAGE=pi-run:dev-core \
  PI_RUN_IMAGE=pi-run:dev-core ./bin/pi-run .
```

The core contains Pi-Run launch-contract components, Pi, baseline extensions,
core skills, Git/SSH utilities, and Restic. Profile-owned Dockerfiles add only
the capabilities needed by that profile. Run `runtime add all` before the build
when testing the maintained broad development set. Credentials, workspaces,
selected skills, and optional host resources remain separate runtime inputs; an
installed tool does not grant authority to use a service.

Build the versioned egress sidecar separately from the same Docker context:

```bash
docker build -t pi-run-egress:dev -f docker/egress/Dockerfile docker
```

The sidecar image contains Squid, iptables, the proven firewall entrypoint, and
the Pi-Run license. It contains no hostname policy; a restricted launch mounts
already-resolved host-owned policy at runtime. Building this image does not
select restricted mode; the active profile does. The production Dockerfile was
build-validated on Debian Trixie with Docker Engine 26.1.5 during v0.7
validation. That historical result predates profile-owned runtimes; use the
current candidate checks below for release evidence.

Check which launcher and release-image roles are selected without starting Pi:

```bash
PI_RUN_CORE_IMAGE=pi-run:dev-core \
PI_RUN_IMAGE=pi-run:dev-core \
PI_RUN_EGRESS_IMAGE=pi-run-egress:dev \
./bin/pi-run version
```

`PI_RUN_CORE_IMAGE` selects the profile build/identity base. `PI_RUN_IMAGE`
selects utility containers and cannot bypass prepared profile selection.
`PI_RUN_EGRESS_IMAGE` selects the restricted sidecar. Normal release coordinates
come from `VERSION`. Do not use untrusted images. The prepared profile image
receives the workspace, profile, startup privileges, and optional mounts chosen
for a run. The egress image receives network-policy enforcement authority in
restricted mode.

## Source architecture

`bin/pi-run` is the host entry point. It validates the active installation,
loads the implementation components, parses global options, initializes local
state when required, and dispatches commands. The Bash components under
`lib/pi-run/` are sourced into that process; they are organizational units, not
independent services.

| Path | Responsibility |
| --- | --- |
| `bin/pi-run` | Host CLI, launch argument construction, mounts, and command dispatch |
| `lib/pi-run/doctor.sh` | Host, installation, image, home, and profile diagnostics |
| `lib/pi-run/profiles.sh` | Profile lifecycle and SSH-key management containers |
| `lib/pi-run/workspaces.sh` | Machine identity, workspace registration, and path mappings |
| `lib/pi-run/sessions.sh` | Session discovery, resume selection, and workspace reconnection |
| `lib/pi-run/skills.sh` | Global and profile-local skill validation and selection |
| `lib/pi-run/snapshots.sh` | Snapshot repository configuration, backup, inspection, and deletion |
| `lib/pi-run/restore.sh` | Recovery, staged restore, transactions, rollback, and crash recovery |
| `lib/pi-run/upgrade.sh` | Release discovery and atomic application upgrade |
| `docker/core/Dockerfile` | Release-authoritative small core built from the `docker/` context |
| `docker/Dockerfile` | Retained broad-image reference used for inventory and migration validation, not release publication |
| `docker/entrypoint.sh` | Runtime UID/GID mapping, setup, and privilege drop |
| `docker/egress/` | Versioned restricted-egress sidecar image and firewall/proxy entrypoint |
| `docker/extensions/guard/` | Runtime contracts, reviewer routing, evidence, journals, activity/status, and shared viewer mechanics |
| `docker/extensions/guardian/` | Guardian command/dispute controller, reviewer domain, review tracing, and log presentation |
| `docker/extensions/caf/` | CAF friend/transmission controller, protocol helpers, and log presentation |
| `docker/extensions/plan/`, `snapshot/` | Planning and Snapshot extension entrypoints |
| `docker/extensions/todo/` | Session-scoped user prompt queue, private persistence, and editor handoff |
| `docker/skills/` | Runtime-owned core skills |
| `templates/profiles/default/` | Definitions copied when the data home is initialized |
| `templates/runtime/` | Base and full-development profile Dockerfile definitions |
| `scripts/build-release` | Reproducible host-application archive and checksum builder |

The selected profile is the authoritative Pi configuration and session
directory. The launcher deliberately disables broad extension, skill, and
prompt-template discovery, then loads managed resources explicitly. Review the
[security guide](../security.md) before changing mounts, discovery, networking,
or runtime privileges.

## Validate changes

Start with syntax checks for shell entry points:

```bash
bash -n bin/pi-run docker/entrypoint.sh lib/pi-run/*.sh scripts/build-release
```

When ShellCheck is available, run it on the changed shell files. Run a focused
test while iterating, then the complete isolated shell suite before reporting a
cross-component change:

```bash
bash tests/component-layout-test.sh
for test in tests/*-test.sh; do
  bash "$test"
done
```

Some scripts exercise TypeScript extensions through their shell harnesses. The
repository does not currently define a complete TypeScript project/type-check
step, so behavioral harnesses, transformed-source checks, dependency assertions,
and exact packaged-layout tests remain important. Keep temporary fixtures
outside the repository, unset unrelated credentials, and inspect the final Git
diff. A skipped optional integration is not a pass; report
it separately. Do not substitute a live provider, remote host, registry, or
snapshot repository for an existing fake fixture.

For launcher argument changes, place a fake `docker` executable first on
`PATH`, use a temporary `PI_RUN_HOME`, and assert the complete generated mount,
environment, privilege, network, extension, and image arguments. Do not start a
container merely to inspect command construction.

Validate both the release core and maintained broad profile definition on a
Docker-capable host:

```bash
docker build --file docker/core/Dockerfile --tag pi-run-core:candidate docker
docker build \
  --file templates/runtime/full-development.Dockerfile \
  --build-arg PI_RUN_BASE_IMAGE=pi-run-core:candidate \
  --tag pi-run-full:candidate \
  templates/runtime
```

The full-development definition records the deterministic `runtime add all`
result. These commands do not authorize publication.

Run the canonical image and launch acceptance on a Docker-capable Linux/amd64
host:

```bash
PI_RUN_TEST_REAL_DOCKER=1 tests/runtime-images-e2e-test.sh
```

This opt-in test builds the production core, creates a disposable profile,
applies `runtime add all`, builds through `runtime build`, checks matching status,
exercises UID/GID and Java CA startup, smoke-tests every maintained capability,
and launches Pi through the real launcher. It removes its unique image tags and
filesystem state but does not prune shared Docker cache. It requires network
access for image/package downloads and must use no meaningful profiles,
credentials, or workspaces.

When Docker is unavailable, the test prints `SKIP`. Report that as skipped rather
than inferring build success from Dockerfile, fake-Docker, or static checks.

The managed-worktree end-to-end test is deliberately opt-in because it starts
real containers and creates disposable linked worktrees. Build a local candidate
runtime image and select it explicitly:

```bash
docker build -t pi-run:worktree-e2e-core -f docker/core/Dockerfile docker
PI_RUN_TEST_REAL_DOCKER=1 \
PI_RUN_TEST_CORE_IMAGE=pi-run:worktree-e2e-core \
tests/worktree-e2e-test.sh
```

The test uses only a temporary Pi-Run home and repository. It validates named
task start and open, finish cancellation, automatic task commit, restricted
local integration, preservation of unrelated target-local content, managed
checkout and branch cleanup, finished-task restart from the current target,
workspace/session identity reuse with `-c`, sibling isolation, historical and
reactivated listing, and lock cleanup. Without
`PI_RUN_TEST_CORE_IMAGE`, it expects the version-matched release core image to
exist locally. A skipped invocation is not a successful real-Docker validation
and must be reported as skipped.

## Build application release artifacts

Create the deterministic host-application archive and checksum in a disposable
output directory:

```bash
output_dir="$(mktemp -d)"
./scripts/build-release "$output_dir"
version="$(cat VERSION)"
(cd "$output_dir" && sha256sum -c "pi-run-${version}.tar.gz.sha256")
```

The archive contains the launcher, Bash components, installer, profile and
runtime templates, license, and version metadata. The core and egress images are
built and distributed separately. `scripts/build-release` rejects missing,
linked, or special-file inputs; the component-layout test verifies that the
launcher, installer, source tree, and archive use the same component set.

Keep these release coordinates aligned:

- `VERSION` contains `X.Y.Z` without a `v` prefix.
- `PI_RUN_DEFAULT_VERSION` in `install.sh` matches `VERSION`.
- The GitHub Release tag is exactly `vX.Y.Z`.
- The core image tag is exactly `ghcr.io/aprilsoftware/pi-run:X.Y.Z`.
- The egress image tag is exactly `ghcr.io/aprilsoftware/pi-run-egress:X.Y.Z`.

Changing a version or publishing artifacts requires its own reviewed release
scope; a successful local archive build is not publication approval.

## Release workflow

Publishing a GitHub Release, including a prerelease, triggers
`.github/workflows/release.yml`. The workflow verifies that its tag matches
`VERSION`, builds the application archive, builds and pushes matching
Linux/amd64 core and egress images, and uploads `LICENSE`, `install.sh`, the
archive, and its checksum to that release. Both images use the exact release
version; the workflow does not publish mutable `latest` images.

Before publication, build local candidates from the exact intended commit and
version. Use non-canonical local tags so validation cannot be mistaken for a
published release:

```bash
version="$(cat VERSION)"
docker build -f docker/core/Dockerfile -t "pi-run-core:${version}-candidate" docker
docker build -f docker/egress/Dockerfile -t "pi-run-egress:${version}-candidate" docker
```

Validate the application archive and complete isolated suite, then run the
feature-specific checks that exercise the candidate's actual boundaries. These
may include the real-Docker runtime-image and worktree tests, fake-provider
Guardian/CAF lifecycle and hostile-primary tests, controlled live-provider
interoperability, or the production restricted-egress test. A skipped optional
check remains a reported skip, not a pass. For manual source-launcher smoke
tests, use a disposable profile, select the candidate with `PI_RUN_CORE_IMAGE`,
select utility containers with `PI_RUN_IMAGE`, select the sidecar with
`PI_RUN_EGRESS_IMAGE`, and explicitly run `runtime build` before launch. Do not
push local candidate tags as canonical images.

Only after local validation should the intended canonical tag be published as a
prerelease when exact workflow-built assets require testing. Install it by exact
tag (`pi-run upgrade vX.Y.Z`); automatic upgrade discovery ignores prereleases.
Treat the published tag, release assets, and matching container images as
immutable. After testing them, promote that same release without moving its tag,
replacing assets, or changing image contents. The current `published`-only
workflow builds on initial prerelease publication and does not rebuild when that
prerelease is promoted. If testing requires any code, metadata, image, or asset
change, prepare and publish a new version rather than rewriting the tested one.
Clients from before prerelease filtering may still discover candidates, so
establish the stable filtering release before relying on this channel for a
wider audience.

Before publication, also verify the intended public coordinates, release notes,
asset access, container-package access, and actual supported platform. For
restricted testing, follow [private-release access](private-release-access.md).
Do not infer public availability from examples or from the existence of the
workflow.

[Documentation index](../index.md) · [Installation](../installation.md) ·
[License](../../LICENSE)
