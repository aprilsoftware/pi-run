# Access private Pi-Run releases

These instructions are for maintainers and testers accessing restricted release
assets or images. They supplement the [installation guide](../installation.md);
they are not extra requirements for assets that are publicly accessible.

GitHub release downloads and container-image pulls are separate authentication
steps. Use accounts with access to the repository and package. Do not publish
tokens, paste their values into documentation, or commit credential files.

## Install with GitHub CLI

Authenticate GitHub CLI if needed, and sign Docker into the registry using a
credential authorized to pull the image:

```bash
gh auth login
docker login ghcr.io
```

In an empty download directory, replace `vX.Y.Z` with an existing release tag
before running:

```bash
release_tag=vX.Y.Z
gh release download "$release_tag" --repo aprilsoftware/pi-run --pattern install.sh
GH_TOKEN="$(gh auth token)" sh ./install.sh
```

Invoke the downloaded installer with `sh`; it need not be executable. The
installer uses the supplied token to obtain the archive and checksum through
GitHub's release-asset API, then uses Docker's existing authentication for the
image pull. It does not arrange registry authentication itself.

If GitHub CLI is unavailable, download `install.sh` from the selected release
through an authenticated browser. Make an authorized token available through
`GH_TOKEN` or `GITHUB_TOKEN` using your credential-management method, then run
`sh ./install.sh`. A fine-grained GitHub token needs access to this repository
and Contents read permission. Its permissions do not automatically grant
container-registry access.

The installer accepts either token variable; `GH_TOKEN` takes precedence. It
does not automatically obtain a token from GitHub CLI, so the installation
command above passes it explicitly without displaying it.

## Check or apply an upgrade

With GitHub CLI already authenticated, the installed launcher can obtain its
token automatically:

```bash
pi-run upgrade --check
pi-run upgrade
```

Upgrade also accepts `GH_TOKEN` or `GITHUB_TOKEN`. Docker must already be
authenticated when the target image is private. Neither upgrade nor installation
stores the supplied GitHub token in Pi-Run profiles.

An unavailable download can indicate a missing release, incomplete assets, or
insufficient access—not a need to reset local profiles or sessions. Confirm
both release access and image-pull permission before retrying.

[Installation guide](../installation.md) · [User documentation](../index.md)
