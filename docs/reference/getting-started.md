# Getting Started reference

This reference explains initialization, launch selection, model persistence, and
common startup failures. For the normal first-run path, start with
[Getting started](../getting-started.md).

## Host commands and Pi commands

Run launcher commands in the host terminal:

```bash
pi-run init
pi-run doctor
pi-run .
```

Run slash commands after Pi's interface opens:

```text
/login
/model
/settings
/thinking
/name Example session
/quit
```

Arguments after the workspace are forwarded to Pi. Launcher-wide options such
as `--home` and `--profile` belong before the workspace:

```bash
pi-run --home /private/pi-run --profile operations /srv/runbooks -r
```

Network selection belongs to `profile.json`. `host` maps to Docker host
networking, `offline` maps to Docker network-none, and experimental `restricted`
resolves model-provider TCP/443 endpoints plus the profile's typed manual rules.
The removed prerelease `--network` and `--allow-host` launch options are not
competing policy sources.

The selected profile is re-evaluated on each launch or resume. Its normalized
restricted policy remains frozen across snapshot-triggered Pi restarts in that
launcher process. Host-side edits and writable model/authentication settings can
change the next launch, not the active sidecar.

## Initialization behavior

`pi-run init` resolves the data home, validates its path, creates missing base
directories, and installs the initial `default` profile from the application
template. It also creates initial configuration, workspace registry, and
home-level README files when absent.

With the default location, important paths include:

```text
~/Pi-Run/
├── config.json
├── README.md
├── profiles/default/
├── skills/
├── shared/
├── workspaces/
├── machines/
└── snapshots/
```

The data home and profiles directory are restricted to the current user during
initialization. Existing initial files and the default profile are not replaced
merely because `init` is run again. Initialization validates important data
paths and refuses unsafe symlinks or conflicting non-directory entries.

A normal workspace launch, profile command, or other stateful command initializes
missing base state automatically. Running `init` explicitly is still useful
because it separates setup errors from the first interactive launch.

Application installation and data initialization are independent. Upgrade and
uninstall operate on application files and do not remove the data home. See the
[Installation guide](../installation.md#application-files-and-user-data).

## Resolve and inspect the data home

The data-home choice, from highest to lowest precedence, is:

1. `pi-run --home <path> ...` for this invocation.
2. `PI_RUN_HOME` from the environment.
3. `$HOME/Pi-Run`.

`pi-run home` prints the resolved path without creating it:

```bash
pi-run home
pi-run --home /private/pi-run home
```

Changing the setting selects another data home; it does not move profiles,
credentials, workspace identities, or sessions from the old one. Keep each data
home private and know which one a command selected before diagnosing missing
state.

## Check installation state

These checks do not have the same effect:

| Command | Purpose |
| --- | --- |
| `pi-run version` | Print the launcher version and selected runtime and egress images. |
| `pi-run home` | Print the resolved data-home path without initializing it. |
| `pi-run doctor` | Validate host commands, installation, both images, and selected profile; do not repair them. |
| `pi-run init` | Create missing persistent data-home structure and the initial profile. |

`doctor` reports `OK`, `WARN`, and `FAIL` and exits nonzero when required checks
fail. An uninitialized home is a warning. Doctor does not pull images, contact a
registry, initialize or repair state, or reveal credential contents.

When checking another profile or data home, select it explicitly:

```bash
pi-run --home /private/pi-run --profile operations doctor
```

## How launch selection works

A normal launch requires an existing workspace directory. Pi-Run resolves its
real path, initializes missing home state, reads the selected profile, registers
or finds the workspace identity, creates that profile's workspace session
directory, validates managed resources, and then starts the container.

Unless `--profile <name>` is supplied, the launcher reads `defaultProfile` from
the selected home's `config.json`. The initial value is `default`. An explicit
profile affects one command; use `pi-run profile default <name>` to change the
saved default.

Only the selected profile is mounted. Its authentication, settings, sessions,
local skills, and resource requests therefore determine what Pi sees. The
workspace is independently selected by its path; changing profiles does not
create another workspace identity.

Before Docker starts, Pi-Run validates required profile files and configuration,
the host CA bundle, skills, and session paths. On launch it reports:

```text
pi-run: home=<resolved-data-home>
pi-run: profile=<profile> workspace=<resolved-workspace>
pi-run: network=<docker-host|docker-offline|docker-restricted>
pi-run: model-tcp=<provider-host>:443[...]                 # restricted only
pi-run: ssh-tcp=<count> managed targets on port 22          # restricted only
pi-run: manual-tcp=<selector>=<destination>:<ports>[...]   # restricted only
pi-run: Guardian loaded; review mode starts Off
```

It also reports `/shared` when that optional resource is mounted. Stop if the
reported selection differs from your intent.

For exact mounts and privilege boundaries, see the
[Security reference](security.md). For workspace identity and session selection,
see the [Workspaces and Sessions reference](workspaces-and-sessions.md).

## Terminal behavior

Unless Pi arguments or profile/project settings select another supported mode,
Pi-Run passes `--tui-mode regular`. This lets the interface use normal terminal
scrollback. Explicit Pi arguments after the workspace remain authoritative:

```bash
pi-run . --tui-mode fullscreen
```

Profile settings at `/profile/settings.json` and project settings at
`<workspace>/.pi/settings.json` can also select `regular` or `fullscreen`.
Pi-Run leaves those choices for Pi to resolve rather than adding another mode.

The launcher requires an interactive terminal for a normal Pi session and uses
Docker's interactive TTY mode. Automation should not assume that `pi-run .` is a
headless API.

## Model authentication and settings

Pi stores provider authentication and settings under its configuration
directory. Pi-Run points that directory at the selected writable profile, so
credentials and preferences persist between runs for that profile without being
shared with other profiles.

Use `/login` for supported provider authentication and `/model` to select from
models available to that provider. `/settings` and `/thinking` adjust supported
preferences. The provider controls account access, quotas, billing, model
availability, and credential revocation.

Do not copy an entire profile to share ordinary configuration: it can contain
authentication and private sessions. Use profile creation and the documented
credential workflows instead; see [Profiles](../profiles.md).

## Troubleshoot startup

### `pi-run` is not found

Confirm installation succeeded and the executable directory is on `PATH`. The
default is `~/.local/bin`; see the [installation check](../installation.md#check-your-installation).

### Doctor reports a Docker failure

Confirm Docker is installed, its daemon is running, and your normal user has the
intended daemon access. Docker access is highly privileged. Do not solve a
permission error by exposing the Docker socket inside Pi or broadly changing
unrelated filesystem ownership.

### A runtime or egress image is missing

Run `pi-run version` to identify both exact selected images. Follow the
role-specific Doctor diagnostic and confirm required registry authentication
before pulling it. Do not substitute an unrelated runtime image;
`PI_RUN_IMAGE` is a development boundary that grants an alternate image the
selected mounts and privileges. `PI_RUN_EGRESS_IMAGE` is the corresponding
maintainer override for the policy-enforcement sidecar image.

### Initialization is refused

Read the reported path before changing anything. Pi-Run rejects a symlink data
home and unsafe/conflicting data paths. Do not delete profiles, credentials, or
restore state as generic cleanup. If a restore was interrupted, use the snapshot
recovery guidance rather than manually editing transaction files.

### A profile is missing or invalid

Check the selected home and list profiles:

```bash
pi-run home
pi-run profile list
```

Select an existing profile or create one using the [Profiles guide](../profiles.md).
Do not recreate a profile over an expected restored or backed-up profile until
you understand why it is absent.

### No model is available

Inside Pi, use `/login` to check provider authentication and `/model` to inspect
models available to that account. Also confirm the intended profile was selected.
Network reachability does not guarantee provider authorization or quota.

### A session is missing

Confirm the selected data home, profile, and workspace first. Sessions are
scoped by profile and stable workspace identity. Use `pi-run session list` and
the [Workspaces and Sessions guide](../workspaces-and-sessions.md) rather than
copying or editing session JSONL.

### Startup selections are unexpected

Stop before doing work. Compare the launch report with `pi-run home`, the saved
profile from `pi-run profile default`, and any `--home`, `PI_RUN_HOME`, or
`--profile` selection. The optional shared mount is reported only when active.

[Getting started](../getting-started.md) · [Installation](../installation.md) ·
[Security](../security.md)
