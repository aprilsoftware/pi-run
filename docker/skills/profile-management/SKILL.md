---
name: profile-management
description: Manage Pi-Run profiles, instructions, Guard/Guardian/CAF policy and preferences, selected skills, credentials, and private profile data.
---

# Pi-Run Profile Management

## Purpose

Use this skill when inspecting or changing a Pi-Run profile. The active profile
is mounted at `/profile` and is the authoritative copy; there is no separate
runtime state directory and no startup copy of its instruction files.

`pi-run` management commands run in the user's host terminal, not inside the Pi
container. Within Pi, edit only the mounted active profile when authorized and
tell the user which host command to run for profile, skill, or SSH management.

## Profile contents

```text
/profile/
├── profile.json
├── AGENTS.md
├── auth.json
├── models.json
├── settings.json
├── gitconfig
├── skills/
├── credentials/
├── guard/
│   └── config.json
├── guardian/
│   ├── guardian.md
│   ├── config.json          # optional legacy preference
│   └── mode.json
├── caf/
│   ├── caf.md
│   ├── config.json
│   └── mode.json
├── logs/
│   └── <workspace-id>/
│       ├── guardian.jsonl*
│       └── caf.jsonl*
└── sessions/
```

The complete profile directory is private because it can contain authentication
data, credentials, settings, logs, and session history. Use encrypted Pi-Run
snapshots for backup and workstation transfer.

## Responsibilities

- `profile.json` filters global skills and requests optional resources.
- `AGENTS.md` defines the profile's working and authorization contract.
- `guardian/guardian.md` supplies Guardian command-review instructions.
- `guard/config.json` privately stores the explicitly selected shared Guard
  reviewer model and thinking preference.
- `guardian/mode.json` and `caf/mode.json` privately store profile-specific
  defaults for genuinely new sessions; current modes remain session metadata.
- `caf/caf.md` supplies guarded external-disclosure priorities, while
  `caf/config.json` privately stores the friend model and thinking preference.
- Legacy `guardian/config.json` may supply an explicit reviewer model when no
  shared config exists, but Pi-Run does not rewrite it as migration.
- Pi owns `auth.json`, `settings.json`, `models.json`, and session data.
- `credentials/` contains profile-specific configuration supplied by the user.
- Every valid direct child of `skills/` is a writable profile-local skill that
  Pi-Run loads on the next start.

A minimal profile configuration is:

```json
{
  "schemaVersion": 1,
  "name": "example",
  "skills": null,
  "resources": {
    "shared": "read-write"
  }
}
```

Core skills named `pi-run` and `profile-management` are supplied by the runtime
and are reserved names that must not appear in global or profile-local skill
directories.

## SSH credentials

Profile-local OpenSSH credentials have this layout:

```text
/profile/credentials/ssh/
├── user@host
├── user@host.pub
└── known_hosts
```

Use host management commands instead of editing key files casually:

```bash
pi-run --profile <name> ssh-key list
pi-run --profile <name> ssh-key add <user@host>
pi-run --profile <name> ssh-key remove <user@host>
```

`list` displays states and fingerprints without private-key contents. `add`
generates a passphrase-free Ed25519 pair if absent, reuses a valid pair, and
interactively invokes `ssh-copy-id`; failed installation keeps the pair and is
not retried automatically. `remove` confirms local deletion, preserves
`known_hosts`, and does not revoke the remote `authorized_keys` entry.

Startup configures valid private keys whether or not their public key has been
installed remotely. It does not connect to targets. Host-key verification uses
the profile's `known_hosts` and remains enabled. Stored credentials confer no
authority to use them.

## Safety

- Never display secret values while inspecting a profile.
- Keep profile directories mode `0700` and sensitive files mode `0600`.
- Do not commit complete profiles to source control.
- Do not copy credentials or sessions when deriving a profile unless the user
  explicitly requests it.
- Do not infer authority from a credential's presence.
- Do not modify another profile: it is intentionally absent from the container.

Profile definition changes are made directly in `/profile`. After editing an
already loaded skill, use Pi's `/reload` command to refresh it. Restart Pi-Run
after adding or removing a skill, changing the global-skill filter, or otherwise
changing mounts and skill arguments selected at launch.

## Host management commands

Run the commands in this section in the host terminal.

Inspect or change the profile used when `--profile` is omitted:

```bash
pi-run profile default
pi-run profile default <name>
```

An explicit `--profile <name>` overrides the saved default for one invocation.
Changing the launch default does not change profile creation: without `--from`,
a new profile is copied from the neutral profile named `default`.

Create a profile from that neutral definition or another profile definition:

```bash
pi-run profile create <name>
pi-run profile create <name> --from <source-profile>
```

Creation copies only `profile.json`, `AGENTS.md`, `guardian/guardian.md`,
`caf/caf.md` when present, and profile-local skills; private runtime state starts
empty. It resets `skills` to `null`, so a new profile initially loads every
global skill. Use encrypted
Pi-Run snapshots rather than copying complete profile directories for backup or
workstation transfer.

## Profile-local skill authoring

When asked to create a skill from knowledge in the selected workspace:

1. inspect the relevant workspace sources;
2. create `/profile/skills/<name>/SKILL.md` and any supporting files;
3. ensure the directory and frontmatter names match Agent Skills rules;
4. report that Pi-Run must restart before the skill becomes available.

Do not add a profile-local skill to `profile.json`: every valid direct skill
directory is loaded. Keep unfinished drafts outside `/profile/skills`.
Profile-local skills may contain private workspace knowledge.

## User skill management

Core skills are part of the runtime. Global skills under the host's
`Pi-Run/skills` directory are mounted read-only. In `profile.json`, setting
`skills` to `null` or omitting it loads all global skills, an empty array loads
none, and a non-empty array loads only the named global skills. Profile-local
skills are always active. List every skill and its active or filtered status
from the host with:

```bash
pi-run skill list
```

To add a reviewed global skill, use the host terminal to copy its complete
directory into the selected Pi-Run home's `skills/` directory; that parent is
not mounted in a normal Pi session. To scope it to the active profile instead,
copy it into `/profile/skills`. Pi-Run fully validates profile-local and active
global skill packages before launch; inactive global entries receive full
validation when listed or selected. Structural validation does not establish
trust. Review all instructions, scripts, references, and assets before placing a
skill there. An active global and profile-local skill cannot share a name.
