# Installation reference

This reference records release artifacts, installer safeguards, path selection,
upgrade rules, and custom uninstall behavior. For the normal lifecycle, start
with [Install, upgrade, and uninstall Pi-Run](../installation.md).

## Host requirements

Pi-Run supports Linux on amd64/x86-64. The host launcher requires Bash, Docker,
`jq`, `flock`, a CA bundle at `/etc/ssl/certs/ca-certificates.crt`, and standard
utilities including `curl`, `tar`, `sha256sum`, `readlink`, `realpath`, `stat`,
`sync`, and `timeout`.

Workspace IDs use `/proc/sys/kernel/random/uuid` when available or `uuidgen` as
a fallback. The host user must be able to reach the Docker daemon. The runtime
image supplies Pi, Node.js, and the in-container toolchain; it does not supply
host launcher requirements.

### Experimental Windows/WSL configuration

The initial Windows target is x86-64 WSL2 with Ubuntu or Debian and Docker
Engine running inside that distribution. Docker Desktop is optional, not a
requirement; its integration/networking behavior is not validated by these
checks. Use the [WSL setup procedure](../installation.md#windows-via-wsl2-ubuntu-or-debian).
Keep application files, the data home, and workspaces in the Linux filesystem;
Explorer can reach them through `\\wsl.localhost\<distribution>\home\<user>`.

Doctor recognizes common WSL2 kernel markers (`microsoft-standard` or `wsl2`)
and reports an unsupported WSL1 kernel ending in `-Microsoft`, ignoring case.
Other Microsoft kernels or WSL environment markers produce a warning asking
for confirmation with `wsl --list --verbose` in Windows. Customized kernels
without recognizable markers can appear as native Linux.

On recognized WSL, doctor checks the backing filesystem of the data home, or
its nearest existing ancestor when the home does not exist. Known Windows-backed
filesystem types (`9p`, `drvfs`, `ntfs`, `ntfs3`) are diagnostic failures; an
unreadable filesystem type is a warning. Other types are reported, not certified.
This check does not inspect workspace storage, create directories, change
permissions, move data, or introduce a runtime storage rejection. Existing
permission checks remain unchanged.

Doctor checks daemon reachability and local image presence, not the active
Docker context's locality, host-network behavior, container-visible permissions,
locking, or restore durability. Distribution-local Engine host networking
shares WSL networking; Windows service access needs separate verification.
WSL-specific diagnostics have automated coverage, but the maintainer does not
currently have a Windows computer for end-to-end testing. Real integration
testing is therefore pending, and diagnostics explicitly warn that the
configuration is experimental. Feedback and test reports are welcome through
[GitHub Issues](https://github.com/aprilsoftware/pi-run/issues). ARM64, WSL1,
and native Windows execution remain outside the target.

## Select a release

An installable release has a canonical `vX.Y.Z` GitHub tag and exactly one
uploaded asset with each of these names:

```text
install.sh
pi-run-X.Y.Z.tar.gz
pi-run-X.Y.Z.tar.gz.sha256
```

Its matching image is:

```text
ghcr.io/aprilsoftware/pi-run:X.Y.Z
```

The public latest-release URL redirects to the installer attached to GitHub's
current Latest release. The installer contains its own default version and uses
that version for the archive, checksum, and image; it does not infer a version
from documentation examples.

To install an exact published release, replace the placeholder with a real tag:

```bash
release_tag=vX.Y.Z
curl -fsSL "https://github.com/aprilsoftware/pi-run/releases/download/${release_tag}/install.sh" -o install.sh
sh ./install.sh
```

`vX.Y.Z` is a placeholder, not a released version. GitHub downloads do not need
the executable bit when the script is invoked through `sh`.

For restricted assets, use [private-release access](../maintainers/private-release-access.md).
The installer accepts `GH_TOKEN` or `GITHUB_TOKEN`, with `GH_TOKEN` taking
precedence, for authenticated GitHub asset downloads. Container-registry access
is separate and must already be configured for Docker.

## Verification and trust boundary

The selected installer downloads the archive and checksum for its embedded
version. `sha256sum` detects corruption or a mismatch between those downloaded
assets. It does not authenticate the installer itself and is not a release
signature.

Before installation, the script validates the platform, required commands,
version syntax, destination paths, and whether an existing executable link is
managed by the selected installation. After extraction it requires the expected package directory, executable
launcher, version match, installer, and safe component files. Archives containing
symlinks or special files under the package directory are refused.

The matching image must pull successfully before application activation. The
installer then copies the package through a temporary release directory and
atomically replaces the `current` and executable symlinks. A failed download,
checksum, validation, or image pull does not activate that release.

Installation also refuses an already-present release directory, a symlink or
non-directory installation root, a non-symlink `current` path, unsafe metadata,
a changed executable directory, or an unrelated executable at the destination.
Do not delete user data to resolve these failures.

## Application and data paths

Application-path precedence is:

1. `PI_RUN_INSTALL_ROOT` when set.
2. `<XDG_DATA_HOME>/pi-run` when `XDG_DATA_HOME` is set.
3. `$HOME/.local/share/pi-run`.

`PI_RUN_BIN_DIR` selects the executable-link directory and defaults to
`$HOME/.local/bin`. The installer records that directory under the application
root so upgrades can preserve it.

The launcher data home is independent:

1. `pi-run --home <path> ...` for one invocation.
2. `PI_RUN_HOME`.
3. `$HOME/Pi-Run`.

Changing any setting selects a location; it does not move an existing
installation or data home. `PI_RUN_INSTALL_ROOT` and `PI_RUN_HOME` must not point
to the same content. Keep application packages separate from profiles,
credentials, sessions, and snapshots.

A custom installation can be requested by setting variables for the installer:

```bash
PI_RUN_INSTALL_ROOT=/opt/user/pi-run \
PI_RUN_BIN_DIR="$HOME/bin" \
sh ./install.sh
```

Use locations writable by the invoking normal user. The installer rejects `/`
and the user's home directory as application roots and refuses a symlinked root.
It does not elevate privileges.

## Executable lookup and installation checks

If the shell cannot find `pi-run`, add the configured executable directory to
`PATH`. For the default location, test the current shell with:

```bash
export PATH="$HOME/.local/bin:$PATH"
pi-run version
```

Persist that change using the appropriate shell configuration only after
confirming the path.

`pi-run version` reports the launcher version and selected image without checking
Docker. `pi-run home` resolves the data path without initializing it. `pi-run
doctor` checks the platform, required commands, UUID source, Docker daemon,
local image, CA bundle, installed templates, data-home safety, and selected
profile.

Doctor never repairs failures. It reports the exact image to pull when that
image is unavailable locally. Confirm the tag and registry authentication before
following that instruction.

## Upgrade selection and activation

Upgrade works only from the active installed release. It validates that the
running launcher's directory is the target of the installation's `current`
symlink, reads the recorded executable directory, and uses the installer stored
in that active release.

`pi-run upgrade --check` and `pi-run upgrade` query up to 100 published GitHub
releases and choose the highest numeric canonical `vX.Y.Z` version that is neither
a draft nor a prerelease and has exactly one uploaded installer, archive, and
checksum. This is independent of GitHub's separate Latest designation.

An already-current check or upgrade succeeds without reinstalling. If the
highest installable published version is older than the installed version, the
operation refuses to downgrade.

Choose an exact newer tag with:

```bash
pi-run upgrade vX.Y.Z
```

The tag must be canonical and newer than the installed version. Exact upgrade
uses the active release's retained installer for the target version, including
checksum, archive, image, and destination validation. It can install an explicitly
selected published prerelease even though automatic upgrade selection ignores
prereleases.

Authentication is resolved from `GH_TOKEN`, then `GITHUB_TOKEN`, then an
available authenticated `gh` session. The token is passed to the installer but
is not saved in a Pi-Run profile. Docker registry authentication remains
separate.

A successful upgrade adds `releases/<new-version>` and uses temporary symlinks
and atomic replacement when repointing `current` and the managed executable.
Older release directories remain. Pi-Run
does not provide automatic rollback or release cleanup; do not repoint symlinks
or remove packages without understanding the recorded installation layout.

## Custom-location uninstall

The default uninstall command is:

```bash
sh "$HOME/.local/share/pi-run/current/install.sh" --uninstall
```

For a custom installation, run `install.sh` from that installation's `current`
directory and provide the same location settings used for installation:

```bash
PI_RUN_INSTALL_ROOT=/opt/user/pi-run \
PI_RUN_BIN_DIR="$HOME/bin" \
sh /opt/user/pi-run/current/install.sh --uninstall
```

If `XDG_DATA_HOME` selected the root, preserve that setting instead. The
uninstaller uses these settings; it does not infer the root from the script's
own location.

Uninstall removes the executable only when it is a symlink into the selected
installation root. It refuses an unrelated executable, a symlinked root, or a
root that is not a directory. When checks pass, it removes the selected
application root, including every installed release, while preserving the
separate data home and Docker images.

The success message reports the data-home setting, but that path is not deleted.
Always verify custom roots before running uninstall; a deliberately selected
application root is recursively removed.

[Installation task guide](../installation.md) ·
[Getting Started reference](getting-started.md) ·
[Private release access](../maintainers/private-release-access.md)
