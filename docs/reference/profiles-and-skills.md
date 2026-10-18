# Profiles and Skills reference

This reference records detailed profile creation, schema, file, permission, and
skill-package behavior. For normal tasks, start with the [Profiles](../profiles.md)
and [Skills](../skills.md) guides.

## Profile names and selection

Profile names begin with a letter or digit and contain only letters, digits,
dots, underscores, or hyphens. Profiles are direct children of
`<Pi-Run home>/profiles/` and resolve within that directory.

The home-level `config.json` stores the launch default. `profile default <name>`
validates the complete target profile before atomically changing that setting.
An explicit `--profile <name>` overrides it for one invocation without modifying
the saved default.

Profile commands and launches must use the same `--home` or `PI_RUN_HOME` when a
non-default data home is selected. Changing the default does not affect running
containers, transfer sessions, or move credentials.

## Profile creation semantics

`profile create <name>` always derives from the profile literally named
`default`. The configured launch default is irrelevant. `--from <profile>`
selects another explicit source. The source configuration, definition files, and
local skills must validate before creation.

Creation stages a private directory and publishes it only after materializing:

- `profile.json`, with `.name` changed and `.skills` reset to `null`;
- `AGENTS.md`;
- `guardian/guardian.md`;
- validated profile-local skill packages; and
- empty `credentials/` and `sessions/` directories, with no copied Guardian
  preferences or logs.

The new profile directory and private subdirectories use mode `0700`.
`profile.json`, `AGENTS.md`, and `guardian/guardian.md` use mode `0600`. Copied
skill files remain user-writable but are not made group/world writable.

Creation does not copy `auth.json`, `models.json`, `settings.json`, `gitconfig`,
general credentials, SSH keys, sessions, Guardian preferences, or logs. It does
not overwrite an existing profile or select the new one.

Resource and network fields are copied as part of `profile.json`, so shared and
network exposure remain as in the source. Resetting `skills` to `null` selects
all global skills, even if the source selected fewer.

## Profile file layout

A populated profile can contain:

```text
profiles/<name>/
├── profile.json
├── AGENTS.md
├── auth.json
├── models.json
├── settings.json
├── gitconfig
├── skills/
├── credentials/
├── guardian/
│   ├── guardian.md
│   ├── config.json
│   └── guardian.log*
└── sessions/
```

`profile.json`, `AGENTS.md`, and `guardian/guardian.md` must be regular,
non-symlink, singly linked files contained by the profile. The Guardian and skill
directories must also be ordinary contained directories.

Pi uses the selected profile as its configuration directory. Provider login,
model configuration, settings, Git configuration, credentials, Guardian state,
and sessions therefore coexist with shareable definitions. A complete profile
is private state, not a shareable template.

## Profile schema

`profile.json` uses schema version 1. Its `name` must exactly match the directory.
The supported resource values are:

```json
{
  "schemaVersion": 1,
  "name": "operations",
  "skills": null,
  "network": {
    "mode": "host"
  },
  "resources": {
    "shared": "disabled"
  }
}
```

- `skills` may be absent, `null`, or an array of unique valid global skill names.
- `resources` contains only `shared`, which is `disabled` or `read-write`.
- `network` may be absent for v0.6 compatibility or contain one mode: `host`,
  `offline`, or `restricted`. Host and offline objects contain only `mode`.
- A restricted network object may contain `allow`, an array of unique rules.
  Each rule has exactly one `host`, `domain`, or `cidr` selector and optional
  unique integer `tcpPorts` from 1 through 65535. Omitted ports mean all TCP.
- Host and domain values are lowercase multi-label DNS names. CIDRs are
  semantically normalized by the isolated resolver; blocked special ranges and
  malformed prefixes fail restricted startup.
- A legacy or arbitrary top-level `guardian` field is not accepted.

The restricted resolver also reads provider identities and endpoints from
`auth.json`, `models.json`, and `settings.json`, plus bundled metadata. It adds
model TCP/443 rules independently of `allow`. Unsupported endpoint forms or
configured providers without resolvable metadata fail closed. This structure is
resolved and frozen before Pi starts.

Every selected global name must exist, and reserved core names are invalid in
the global filter. Profile-local names do not belong in that filter; selecting a
global package with the same active local name creates a conflict. Resource,
network, and skill changes take effect only on a new launch.

The host interface has no profile deletion, show, edit, import, export, or
profile-only backup command. Do not infer commands from direct file ownership.

## Skill names and metadata

Skill names use at most 64 characters: lowercase letters and digits separated by
single hyphens, with no leading, trailing, or repeated hyphen. `pi-run` and
`profile-management` are reserved core names.

Each package is a direct child directory containing a regular `SKILL.md`.
Frontmatter starts on the first line and provides non-empty, single-line `name`
and `description` values. The declared name must match the package directory.

A package can contain additional regular files and directories. Supporting links
inside documentation should be relative to the package. Pi-Run does not install
a skill's external dependencies merely because its package exists.

## Skill locations and loading

| Kind | Host location | Runtime behavior |
| --- | --- | --- |
| Core | Runtime image | Always loaded explicitly |
| Global | `<Pi-Run home>/skills/<name>/` | Selected packages mounted read-only at `/skills/<name>` |
| Profile-local | `profiles/<profile>/skills/<name>/` | Every valid package loaded from writable `/profile/skills/<name>` |

Pi-Run disables broad automatic skill discovery and explicitly supplies these
managed locations. Packages elsewhere do not become active automatically.
Selection is fixed when the container starts.

The global filter affects only global packages. Missing selected names fail
validation. An active global and profile-local package cannot share a name;
Pi-Run refuses the conflict rather than choosing one. A filtered global can
share a local name because only the local package is active.

`skill list` validates the selected profile, all local packages, the global
skills directory, selected-name existence, and every installed global package,
including filtered packages. It reports core and local packages as active, and
global packages as active or filtered. Listing starts no container and invokes
no model.

## Package structure limits

Package validation walks one filesystem without following links. It rejects
symbolic links, hard-linked regular files, special files, and filesystem
crossings. Current limits per package are:

- 1,000 total entries;
- 500 regular files;
- 10 MiB per file; and
- 50 MiB total regular-file content.

A profile can contain at most 64 profile-local skill directories. Global roots
and profile skill roots may contain only direct child package directories; loose
files and nested collection wrappers are invalid.

Normal launch validates every local package and each selected global package.
Listing additionally validates filtered global packages. Structural validation
protects package boundaries but does not evaluate the intent or safety of
instructions and executable files.

## Security and lifecycle boundaries

- The selected profile exposes its private runtime state to that session. Most
  Pi-owned files are writable; `profile.json` is over-mounted read-only.
- Global skills are read-only only at their package mount; their instructions and
  scripts can still affect other writable or network resources.
- Profile-local packages are writable and can be changed by the selected run.
- Profile creation is not a sanitized export, even though credentials and
  sessions begin empty; copied instructions and local skills may still contain
  private information.
- Application upgrades do not overwrite user-owned profile definitions or skill
  packages.

[Profiles task guide](../profiles.md) · [Skills task guide](../skills.md) ·
[Security and isolation](../security.md)
