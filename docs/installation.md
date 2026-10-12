# Install, upgrade, and uninstall Pi-Run

Pi-Run installs a small host launcher and a matching container image. Pi,
Node.js, and the bundled toolchain stay in the image, while profiles, credentials,
and sessions remain in a separate private data directory.

Run these commands in your **host terminal** as your normal user with Docker
access.

## Requirements

- Linux on amd64/x86-64. Windows via WSL2 with Ubuntu/Debian is an
  experimental configuration; see [Windows setup](#windows-via-wsl2-ubuntu-or-debian).
- Bash and a working Docker daemon accessible to your user.
- `curl`, `jq`, `tar`, `flock`, and standard GNU command-line tools.
- The host CA bundle at `/etc/ssl/certs/ca-certificates.crt`.
- Access to the selected GitHub release and its container image.

Docker access is highly privileged on the host. Pi-Run does not mount the Docker
socket into normal Pi sessions; see [Security and isolation](security.md).

## Windows via WSL2 (Ubuntu or Debian)

This configuration runs the existing Linux launcher and image. It needs an
x86-64 Windows machine, WSL2, and Docker Engine **inside the distribution**.
Docker Desktop is not required. WSL1, Windows ARM64, and native PowerShell/Git
Bash execution are outside this configuration. Real WSL integration validation
is still pending; diagnostic success is not certification.

### Prepare WSL and Docker Engine

In an administrator PowerShell terminal, install one distribution if needed:

```powershell
wsl --install -d Ubuntu
# Alternatively: wsl --install -d Debian
wsl --list --verbose
```

Complete Windows restart/distribution setup if requested. Confirm that your
chosen distribution shows version `2`. For an existing WSL1 installation, see
[Microsoft's WSL installation instructions](https://learn.microsoft.com/en-us/windows/wsl/install).

Open the Ubuntu or Debian terminal as your normal Linux user. All remaining
installation commands, including the Pi-Run installer below, run **inside WSL**:

```bash
sudo apt-get update
sudo apt-get install -y bash ca-certificates curl jq coreutils util-linux tar
```

Install Docker Engine using the official instructions for
[Ubuntu](https://docs.docker.com/engine/install/ubuntu/) or
[Debian](https://docs.docker.com/engine/install/debian/). Do not install a second
Engine alongside an existing Docker Desktop integration without first choosing
which backend to use. This procedure targets the distribution-local Engine.

For service management, check `systemctl status`. If systemd is unavailable,
follow [Microsoft's WSL systemd setup](https://learn.microsoft.com/en-us/windows/wsl/systemd).
Then start Docker and enable it for distribution startup:

```bash
sudo systemctl enable --now docker
```

Configure normal-user Docker access using Docker's
[post-installation instructions](https://docs.docker.com/engine/install/linux-postinstall/).
Docker-group membership grants root-level privileges in the distribution. After
refreshing your group membership, verify access without `sudo`:

```bash
docker info
```

Do not run Pi-Run as root or use `sudo pi-run`; the runtime refuses UID/GID zero.

### Keep Linux storage accessible from Explorer

Use Linux-side paths for the installed application, `~/Pi-Run`, and workspaces
(for example `~/projects/my-project`), rather than `/mnt/c/...`. This preserves
Unix permissions, locking, and filesystem behavior used by credentials and
snapshots. Linux-side files remain accessible from Windows Explorer:

```text
\\wsl.localhost\Ubuntu\home\<linux-user>\Pi-Run
\\wsl.localhost\Debian\home\<linux-user>\Pi-Run
```

After `pi-run init`, open the data folder from WSL with `cd ~/Pi-Run` followed by
`explorer.exe .`, and optionally pin it to Quick Access. Windows applications
access these files as the distribution's default Linux user; this is not an
isolation boundary against that Windows user. See
[WSL file permissions](https://learn.microsoft.com/en-us/windows/wsl/file-permissions).

### Networking and integration checks

With distribution-local Docker Engine, Pi-Run's host networking refers to WSL,
not automatically Windows. Access to Windows-hosted databases, local models,
and other services depends on NAT/mirrored networking, listeners, and firewall
settings; see [WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking).
No networking settings are changed by Pi-Run diagnostics.

After installation, run `pi-run doctor`, then use disposable workspaces and a
separate test data home to verify launch, file ownership/permissions, session
resume, Windows/WSL service access, and local snapshot creation/restore. Never
use production credentials or meaningful data for integration tests. The
[snapshot guide](snapshots.md) describes explicit setup and restore operations.

## Install a release

For the latest published public release, download the installer so you can
review it before execution:

```bash
curl -fsSL https://github.com/aprilsoftware/pi-run/releases/latest/download/install.sh -o install.sh
sh ./install.sh
```

The downloaded installer is bound to its release version. It downloads the
matching archive and checksum, verifies the archive, pulls the matching runtime
image, and activates the application.

A checksum detects an archive mismatch; it is not a signature or independent
verification of the installer you chose to run. Obtain the installer from a
release you trust. If release assets or images require authentication, use the
[restricted-release instructions](maintainers/private-release-access.md).

On success, the installer reports the application location and executable path.
If that executable directory is not on `PATH`, follow the printed instruction
before continuing.

For an exact older/newer tag, custom locations, and installer refusal behavior,
see the [Installation reference](reference/installation.md#select-a-release).

## Application files and user data

The default locations are separate:

```text
~/.local/share/pi-run/
├── releases/<version>/
└── current -> releases/<version>
~/.local/bin/pi-run
~/Pi-Run/
```

The first two locations are installed application files. `~/Pi-Run` is your
persistent data home for profiles, credentials, sessions, skills, shared data,
and snapshots.

Installation does not create the data home. Initialize it explicitly:

```bash
pi-run init
```

A first workspace launch can also initialize it. Upgrade and uninstall preserve
the data home. Keep it private and back it up separately with
[encrypted snapshots](snapshots.md); snapshots do not include workspace source.

Custom application and data paths have different settings and do not move
existing data. See [path selection](reference/installation.md#application-and-data-paths).

## Check your installation

```bash
pi-run version
pi-run home
pi-run doctor
```

`version` prints the installed launcher version and selected image. `home` prints
the resolved data location. `doctor` checks host requirements, Docker access,
the local runtime image, application resources, and selected profile.

Doctor reports `OK`, `WARN`, and `FAIL` and exits nonzero for failed requirements.
It does not initialize or repair state, pull images, contact registries, or
inspect credential contents. An uninitialized data home is a warning.

When required checks pass, continue with [Getting started](getting-started.md).

## Upgrade

Check for a newer installable release without changing anything:

```bash
pi-run upgrade --check
```

Apply the newest eligible release:

```bash
pi-run upgrade
```

Upgrade verifies the new archive, pulls its matching image, installs it beside
older application releases, and activates it. It preserves profiles,
credentials, sessions, skills, and other data-home contents.

There is no background upgrade, automatic rollback, or automatic removal of old
application releases. Upgrade requires an active installed release; it does not
run from a source-checkout launcher. Restricted releases may require GitHub and
container-registry authentication.

Exact-version upgrades and candidate-selection rules are documented in the
[upgrade reference](reference/installation.md#upgrade-selection-and-activation).

## Uninstall

For a default installation, run the installer retained in the active release:

```bash
sh "$HOME/.local/share/pi-run/current/install.sh" --uninstall
```

This removes the managed `pi-run` executable link and all application releases.
It preserves `~/Pi-Run` and downloaded Docker images. There is no automatic
user-data purge.

Confirm the application location before uninstalling, especially when custom
paths were used. Do not point the installation root at the data home. See the
[uninstall reference](reference/installation.md#custom-location-uninstall) for
custom settings and safety refusals.

[Documentation index](index.md) · [Getting started](getting-started.md)
