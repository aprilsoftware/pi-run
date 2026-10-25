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

## Network mode commands

`network show` reports the selected profile, effective mode, configuration
source, and manual-rule count. A missing `network` object is reported as the
v0.6 compatibility host default.

`network mode <host|offline|restricted>` validates the existing profile, locks
the profile directory against another network-mode command, stages a complete
replacement, validates it, sets mode `0600`, and atomically replaces
`profile.json`. An explicit `--profile` selects the target; otherwise the saved
default is used. Selecting the already-configured mode does not rewrite the
file.

Host and offline objects cannot contain manual allow rules. A change from
restricted mode therefore refuses when rules exist. `--discard-rules` with host
or offline explicitly replaces the network object and reports the number of
removed rules; it is invalid with restricted mode. No mode command changes an
active launch.

`network allow list` displays every configured manual host, domain, CIDR, and
public-internet rule. Host, domain, and CIDR rules can be changed with:

```text
network allow add <host|domain|cidr> <value> (--tcp-port <port>...|--all-tcp)
network allow remove <host|domain|cidr> <value> (--tcp-port <port>...|--all-tcp)
```

The single public-internet rule uses:

```text
network allow add internet (--tcp-port <port>...|--all-tcp)
network allow remove internet
```

Add and remove require restricted mode. Names are normalized to lowercase;
CIDRs are semantically normalized to their canonical network; ports are sorted
and must be unique integers from 1 through 65535. All-port authority requires
`--all-tcp`. Host, domain, and CIDR removal matches the exact normalized
selector and port set. Internet removal needs no port options because only one
internet rule may exist. Duplicate additions, absent removals, extra
internet-removal arguments, and combining explicit ports with `--all-tcp` fail
without replacing the profile. Existing unrelated rules remain unchanged.

CIDR normalization runs in the locally available, version-matched runtime image
with network-none, no capabilities, no-new-privileges, a read-only image
filesystem, the host UID/GID, and no mounts. The command does not implicitly
pull an unavailable image. Invalid prefixes and CIDRs overlapping blocked
special ranges fail before the profile is locked or changed.

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
├── caf/
│   ├── caf.md
│   └── config.json
├── guardian/
│   ├── guardian.md
│   └── config.json
├── logs/
│   └── guardian/
│       └── runs/
│           └── <run-id>.jsonl*
└── sessions/
```

`profile.json`, `AGENTS.md`, and `guardian/guardian.md` must be regular,
non-symlink, singly linked files contained by the profile. The Guardian and skill
directories must also be ordinary contained directories. When `caf/` is
present, it receives the same directory checks; an optional `caf/caf.md`
receives the same containment and link checks as other definition files.

Fresh default profiles include `caf/caf.md`, and profile creation copies it when
the source has one. Profiles without a CAF policy remain valid and are not
modified automatically. The policy defines profile-specific external-disclosure
priorities; it does not enable CAF or grant external access. CAF loads the
optional policy as a bounded private regular file and reports only its source,
not its contents, through `/caf status`. Unsafe or malformed policy is
unavailable rather than silently ignored.

The CAF disclosure gate accepts only a complete valid `ALLOW` for the exact
message, purpose, and friend-model destination. Missing, failed, malformed,
cancelled, or non-allowing review remains withheld. Its production reviewer
uses the current primary model with no tools and receives only that disclosure,
the CAF policy, and bounded user-authored messages from the selected session
branch. It receives no assistant or tool results, workspace contents, or
credentials. If user-message evidence exceeds its bounds, an `ALLOW` is
reduced to `ASK`. Startup and `/caf status` do not invoke the reviewer.

`/caf` configures a friend model and thinking preference without contacting that
model. Preferences are created lazily in private `caf/config.json`; a missing
model remains explicitly unconfigured.

The primary can invoke `call_friend({ message, purpose })` as one standalone,
sequential tool call. After disclosure review allows the exact payload, CAF
sends the message and purpose under a dedicated advisory system prompt to the
configured friend model. A continuation also includes only the previously
reviewed requests and friend responses from that pending consultation; the
reviewer sees that exact history again before release. The friend receives no
primary transcript, authorization evidence, CAF policy, workspace data,
credentials, or unrelated CAF rounds. This is application-level context
isolation, not a sandbox or confidentiality guarantee.

Without research, each invocation performs one friend request. The friend may
return one bounded answer or end its round with the constrained
`caf_ask_primary` function containing up to three minimal questions. That
function does not execute the primary. The primary receives the questions and
must use a new standalone `call_friend` invocation to answer; the answer receives
a new disclosure review before transmission. A consultation is limited to three
primary/friend rounds.

When `web-search.json` selects one explicit provider and the bundled canonical
`web_search` tool is callable, the friend also receives `caf_web_search`. It may
request one query and purpose. CAF pauses the friend and independently reviews
the exact query, purpose, and search-provider destination. Only `ALLOW` permits
a nested `web_search` call with one query, at most five results, no fetched page
content, no curator, and no proxy override. CAF sends bounded, normalized,
untrusted titles, snippets, and URLs back for one final friend request with no
tools. The result returned to the primary includes a CAF-generated source list.
`auto`, `all`, provider arrays, repeated searches, custom-renamed search tools,
and arbitrary URL fetching are unavailable.

The search provider and friend model are separate disclosure destinations.
Approval for one does not authorize the other. Search credentials remain inside
`pi-web-access` and are not included in friend or reviewer context. Offline and
restricted network policy remains authoritative. The friend has no filesystem,
shell, arbitrary Pi, or MCP tools, and public results cannot expand its
capabilities. There is no recursive primary invocation or unbounded autonomous
loop. Review refusal and failures before release produce no corresponding
external request. Failures after a request starts report that uncertain external
effect and must not be retried automatically.

Successful answers, question requests, and bounded research evidence are stored
as finalized branch-local session metadata while the tool result supplies the
response to the primary model. `/caf status` reports whether explicitly
configured public-web research is available, reconstructs only finalized CAF
rounds on the selected branch, marks a pending consultation as awaiting the
primary or at its round limit, and reports malformed state as unavailable.

CAF diagnostics use the shared journal implementation but remain separate from
Guardian under `logs/caf/runs/<run-id>.jsonl*`. `/caf-log` merges a bounded set
of active and completed CAF shards and presents recent review, friend, search,
persistence, cancellation, and failure events. There is no combined
`/guard-log`.

CAF journal records contain operation and session identifiers, destinations,
outcomes, byte counts, SHA-256 payload hashes, bounded usage, duration, and
research-result counts. They do not contain exact messages, purposes, queries,
policies, authorization evidence, friend answers, search results, credentials,
or workspace content. Hashes permit equality correlation and do not constitute
a confidentiality guarantee. Exact finalized exchanges remain branch-local
session metadata. Clean shutdown creates a completion marker and runs best-effort
retention targeting 64 MiB and 128 completed run groups. Journal write, read,
presentation, completion, or retention failure never changes CAF review,
release, or tool-result behavior. Legacy Guardian logs are neither read nor
migrated.

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
  Each rule has exactly one `host`, `domain`, `cidr`, or `internet` selector and
  optional unique integer `tcpPorts` from 1 through 65535. Omitted ports mean
  all TCP. `internet` must be `true`, and at most one internet rule may exist.
- Host and domain values are lowercase multi-label DNS names. CIDRs are
  semantically normalized by the isolated resolver; blocked special ranges and
  malformed prefixes fail restricted startup. Internet rules cover public TCP
  destinations while excluding private and special-purpose ranges; explicit
  CIDR rules can separately grant selected private networks.
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

The host interface has no profile deletion, general definition show/edit,
import, export, or profile-only backup command. Network mode and
host/domain/CIDR/internet rule management use the dedicated commands above. Do
not infer other commands from direct file ownership.

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
  Pi-owned files are writable; `profile.json` and the managed SSH credential
  directory are over-mounted read-only.
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
