# Develop and release Pi-Run

This guide is for maintainers building Pi-Run from a source checkout, validating
changes, creating application archives, or operating the release workflow. User
installation and configuration belong in the [user documentation](../index.md).

## Requirements

Development and release builds currently target Linux/amd64. The host needs
Bash, Docker, `jq`, and standard GNU command-line tools. Image builds also need
network access to the upstream package and binary sources declared in
`docker/Dockerfile`.

Tests may require additional commands for the behavior they cover. They create
temporary homes and use fake Docker, Restic, SSH, and network fixtures where
appropriate; they must not use real profiles, credentials, repositories, or
remote systems.

## Build and run the development image

From the repository root:

```bash
docker build -t pi-run:dev docker
PI_RUN_IMAGE=pi-run:dev ./bin/pi-run .
```

The first command builds the runtime image. The second runs the source-checkout
launcher against the current directory while selecting that image instead of
the version-derived release image. It uses the normal Pi-Run data home unless
you provide a temporary `PI_RUN_HOME` or `--home` value.

The image contains Pi, baseline extensions, core skills, Restic, and a broad
development and operations toolchain. Credentials, workspaces, selected skills,
and optional host resources remain separate runtime inputs; an installed tool
does not grant authority to use a service.

Build the versioned egress sidecar separately from the same Docker context:

```bash
docker build -t pi-run-egress:dev -f docker/egress/Dockerfile docker
```

The sidecar image contains Squid, iptables, the proven firewall entrypoint, and
the Pi-Run license. It contains no hostname policy; a restricted launch mounts
already-resolved host-owned policy at runtime. Building this image does not
select restricted mode; the active profile does. The production Dockerfile was
build-validated on Debian Trixie with Docker Engine 26.1.5 during v0.7
validation. On the same baseline, Doctor successfully
inspected locally built runtime and egress image overrides.

Check which launcher and images are selected without starting Pi:

```bash
PI_RUN_IMAGE=pi-run:dev \
PI_RUN_EGRESS_IMAGE=pi-run-egress:dev \
./bin/pi-run version
```

`PI_RUN_IMAGE` and `PI_RUN_EGRESS_IMAGE` are development overrides; normal
release coordinates come from `VERSION`. Do not use untrusted images. The
runtime image receives the workspace, profile, startup privileges, and optional
mounts chosen for a run. The egress image is intended to receive network-policy
enforcement authority when restricted launcher integration is enabled.

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
| `docker/Dockerfile` | Versioned runtime toolchain and bundled components |
| `docker/entrypoint.sh` | Runtime UID/GID mapping, setup, and privilege drop |
| `docker/egress/` | Versioned restricted-egress sidecar image and firewall/proxy entrypoint |
| `docker/extensions/` | Planning, Guardian, and snapshot-request extensions |
| `docker/skills/` | Runtime-owned core skills |
| `templates/profiles/default/` | Definitions copied when the data home is initialized |
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

Some scripts exercise TypeScript extensions through their shell harnesses. Keep
temporary fixtures outside the repository, unset unrelated credentials, and
inspect the final Git diff. A skipped optional integration is not a pass; report
it separately. Do not substitute a live provider, remote host, registry, or
snapshot repository for an existing fake fixture.

For launcher argument changes, place a fake `docker` executable first on
`PATH`, use a temporary `PI_RUN_HOME`, and assert the complete generated mount,
environment, privilege, network, extension, and image arguments. Do not start a
container merely to inspect command construction.

## Build application release artifacts

Create the deterministic host-application archive and checksum in a disposable
output directory:

```bash
output_dir="$(mktemp -d)"
./scripts/build-release "$output_dir"
version="$(cat VERSION)"
(cd "$output_dir" && sha256sum -c "pi-run-${version}.tar.gz.sha256")
```

The archive contains the launcher, Bash components, installer, profile template,
license, and version metadata. The runtime image is built and distributed
separately. `scripts/build-release` rejects missing, linked, or special-file
inputs; the component-layout test verifies that the launcher, installer, source
tree, and archive use the same component set.

Keep these release coordinates aligned:

- `VERSION` contains `X.Y.Z` without a `v` prefix.
- `PI_RUN_DEFAULT_VERSION` in `install.sh` matches `VERSION`.
- The GitHub Release tag is exactly `vX.Y.Z`.
- The runtime image tag is exactly `ghcr.io/aprilsoftware/pi-run:X.Y.Z`.
- The egress image tag is exactly `ghcr.io/aprilsoftware/pi-run-egress:X.Y.Z`.

Changing a version or publishing artifacts requires its own reviewed release
scope; a successful local archive build is not publication approval.

## Release workflow

Publishing a GitHub Release, including a prerelease, triggers
`.github/workflows/release.yml`. The workflow verifies that its tag matches
`VERSION`, builds the application archive, builds and pushes matching
Linux/amd64 runtime and egress images, and uploads `LICENSE`, `install.sh`, the
archive, and its checksum to that release. Both images use the exact release
version; the workflow does not publish mutable `latest` images.

For candidate testing, publish the intended canonical tag as a prerelease and
install it by exact tag (`pi-run upgrade vX.Y.Z`). Automatic upgrade discovery
ignores prereleases. After testing the built assets and image, promote that same
release without moving its tag or changing its contents. The current
`published`-only workflow builds on initial prerelease publication and does not
rebuild when that prerelease is promoted. If candidate testing requires a code
change, publish a new version rather than rewriting the tested tag. Clients from
before prerelease filtering may still discover candidates, so establish the
stable filtering release before relying on this channel for a wider audience.

Before publication, verify the intended public coordinates, release notes,
asset access, container-package access, and actual supported platform. For
restricted testing, follow [private-release access](private-release-access.md).
Do not infer public availability from examples or from the existence of the
workflow.

[Documentation index](../index.md) · [Installation](../installation.md) ·
[License](../../LICENSE)
