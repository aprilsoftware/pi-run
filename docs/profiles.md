# Profiles

A profile is a complete Pi-Run working context: instructions, provider access,
credentials, settings, skills, Guardian preferences, and saved conversations.
Use separate profiles when work needs different behavior or access—for example,
development, review, and system administration.

Only the selected profile is mounted into a normal run. Other profiles stay out
of view, but the selected profile is writable and available to the agent. A
profile separates contexts; it does not hide its own credentials from that run.

Run `pi-run` commands in your **host terminal**. Slash commands such as `/login`
belong in **Pi's input editor**.

## Find and select a profile

The initial profile is named `default`. List profiles and show the saved launch
default:

```bash
pi-run profile list
pi-run profile default
```

Select another existing profile for one run:

```bash
pi-run --profile operations .
```

This does not change the saved default. To use an existing profile whenever
`--profile` is omitted:

```bash
pi-run profile default development
pi-run .
```

Profiles keep their own authentication and sessions. Selecting another profile
does not transfer either one or change a container that is already running.

## Create a profile

Create a new context from the profile named `default`:

```bash
pi-run profile create development
pi-run profile create operations
```

Creation without `--from` always uses the profile literally named `default`, not
the configured launch default. To derive definitions from another profile:

```bash
pi-run profile create review --from development
```

Creation refuses an existing name and does not select the new profile, connect
to services, or copy private runtime state.

### What is copied

The new profile receives:

- `profile.json`, with the new name;
- `AGENTS.md` instructions;
- `guardian/guardian.md` review policy; and
- validated profile-local skills.

Provider authentication, SSH keys, settings, Git configuration, Guardian
preferences and logs, and sessions are **not copied**. Authenticate and configure
the new profile deliberately.

Shared-folder and network configuration are inherited, so review both before
first launch. The global skill filter resets to `null`, meaning all installed
global skills are initially selected.

## Configure resources and skills

Edit the selected profile's `profile.json`. A minimal profile with optional host
resources disabled looks like:

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

| Setting | Effect |
| --- | --- |
| `skills: null` | Load every global skill. |
| `skills: []` | Load no global skills. |
| `skills: ["name"]` | Load only the named installed global skills. |
| `network.mode: "host"` | Use Docker host networking. |
| `network.mode: "offline"` | Use Docker network-none. |
| `network.mode: "restricted"` | Resolve and enforce the profile's model and manual TCP rules. |
| `resources.shared: "read-write"` | Mount the home's shared directory at writable `/shared`. |
| `resources.shared: "disabled"` | Do not mount `/shared`. |

Restricted mode accepts an optional `network.allow` array. Each entry contains
exactly one of `host`, `domain`, or `cidr`, plus optional `tcpPorts`. A domain
matches its apex and subdomains; omitted ports mean every TCP port for that
rule. Provider hosts already represented by `auth.json`, `models.json`, or
`settings.json` are added automatically as exact TCP/443 rules. For example:

```json
"network": {
  "mode": "restricted",
  "allow": [
    {"host": "git.example.com", "tcpPorts": [22]},
    {"domain": "example.com", "tcpPorts": [80, 443]},
    {"cidr": "10.20.30.0/24", "tcpPorts": [5432]}
  ]
}
```

The skill filter affects global skills only. Core and valid profile-local skills
remain active. Inspect the profile before launch:

```bash
pi-run --profile operations skill list
pi-run --profile operations doctor
```

Restart Pi-Run after changing resources, skills, or network rules because the
active launch configuration and policy are frozen at startup. `profile.json` is
mounted read-only during a run; Pi-owned authentication and model settings stay
writable and can influence automatic provider rules on the next launch. See
[Skills](skills.md) and
[SSH access](ssh.md) for their normal workflows.

## Understand the working context

Authentication saved by `/login`, preferences saved by `/settings`, profile SSH
keys, Guardian settings, and session history all belong to the selected profile.
`AGENTS.md` supplies working instructions, while `guardian/guardian.md` supplies
review priorities. Instructions guide behavior but are not an operating-system
permission boundary.

The complete profile lives under `<Pi-Run home>/profiles/<name>/`; use
`pi-run home` to find the data home. User-owned profile definitions survive
application upgrades.

## Keep profiles private

A profile can contain provider tokens, private keys, conversation history, file
excerpts, commands, and tool output. Do not commit or publish the complete
directory. Creating a profile is not a sanitized export for sharing.

Use [encrypted snapshots](snapshots.md) to back up or move complete Pi-Run state,
and keep snapshot recovery secrets separately. Snapshots include every profile
and its credentials.

Pi-Run currently provides profile listing, creation, default selection, and
one-run selection. It does not provide profile deletion, import, or definition
export commands.

For exact file layout, creation permissions, schema validation, inherited and
reset fields, and unsupported operations, see the
[Profiles and Skills reference](reference/profiles-and-skills.md).

[Documentation index](index.md) · [Getting started](getting-started.md) ·
[Security](security.md)
