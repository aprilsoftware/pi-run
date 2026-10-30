# Security and isolation reference

This reference records Pi-Run's technical mount, identity, network, discovery,
and trust boundaries. For practical exposure reduction, start with the
[Security task guide](../security.md).

## Normal-session mounts

A launcher-managed Pi session uses these host-backed resources:

| Host resource | Container path | Access |
| --- | --- | --- |
| Selected workspace | `/workspace` | Read-write |
| Selected profile | `/profile` | Read-write base mount |
| Profile network configuration | `/profile/profile.json` | Read-only nested over-mount |
| Managed SSH credential directory, when present | `/profile/credentials/ssh` | Read-only nested over-mount |
| Shared directory, when enabled | `/shared` | Read-write |
| Selected global skills | `/skills/<name>` | Read-only |
| Host CA bundle | `/etc/ssl/certs/ca-certificates.crt` | Read-only |
| Private per-launch snapshot request directory | `/run/pi-run-snapshot` | Read-write control channel |

Profile-local skills and Pi-owned provider, settings, and session state remain
part of the writable profile mount. Normal sessions cannot rewrite the active
profile network configuration or managed SSH credentials through their nested
over-mounts. Core skills and baseline extensions come from the runtime image.
The snapshot request channel
contains a bounded request and token; it does not expose the repository,
recovery secrets, S3 credentials, Docker socket, or complete Pi-Run home.

A normal launch does not mount the host home, profiles other than the selected
one, machine-local workspace mappings, snapshot repositories and secrets, or
the Docker socket. The launcher passes selected environment values, not the
complete host environment.

These statements apply to normal interactive sessions. Host management commands
such as SSH-key installation, snapshot operations, and restore use separate
short-lived containers with operation-specific mounts and networking.

## Container lifecycle and filesystem

The launcher uses `--rm`, so the image filesystem is discarded when the
container exits. It is not launched read-only: processes can change image-local
files during that run. Bind-mounted host paths remain persistent.

The workspace and profile use the invoking user's mapped identity. Container
removal does not roll back their changes. Snapshot requests can briefly exit and
reopen a persistent Pi session, but that mechanism does not make workspace or
profile writes transactional.

## Runtime identity and privileges

The launcher drops all Linux capabilities, then adds `CHOWN`, `SETUID`, `SETGID`,
and `DAC_READ_SEARCH` for entrypoint setup. It also sets
`--security-opt=no-new-privileges`.

The entrypoint refuses host UID or GID zero. It maps the image's `node` account
to the invoking host UID/GID, updates its container home when needed, configures
profile SSH credentials, and executes Pi through `gosu node`.

This limits runtime privilege but does not make writable mounts disposable. The
container shares the host kernel, and the default backend shares host networking,
so it is neither a virtual machine nor protection against every kernel or
container runtime vulnerability. Alternate network backends narrow routes, not
the shared-kernel or writable-mount boundary.

The host user must have Docker-daemon access to launch Pi-Run. That access is
itself highly privileged. Pi-Run deliberately withholds the Docker socket from
the Pi container; mounting it would largely defeat the process and filesystem
boundary.

## Networking and service authority

The profile's `host` mode produces the `docker-host` backend and uses Docker
`--network host`. Loopback can reach Docker-host services, and surrounding
routes can expose LAN, internet, cloud, cluster, and database endpoints.
Profiles created by stable v0.6 releases may omit `network`; omission retains
this compatibility behavior. New profiles state `host` explicitly.

`offline` produces `docker-offline` and maps strictly to Docker `--network none`
for every Pi container in that launch. `restricted` produces
`docker-restricted` and uses an ephemeral version-matched sidecar. Normal launch
arguments cannot override the profile's network authority.

Before restricted startup, the launcher runs the runtime image's policy
resolver with Docker network-none, all capabilities dropped, the host UID/GID,
and the selected profile mounted read-only. The resolver derives exact TCP/443
model rules from `auth.json`, `models.json`, `settings.json`, and bundled
provider metadata, validates complete matching managed SSH pairs into exact
hostname or IPv4 `/32` TCP/22 rules, then normalizes manual `host`, `domain`,
`cidr`, and public-internet rules from `profile.json`. It emits destination and
port structure, never credential values, private or public keys, fingerprints,
URL paths, headers, or query strings.

Endpoint derivation must be deterministic before startup. Azure and Google
Vertex require an explicit HTTPS provider `baseUrl` in `models.json`.
Credential- or token-derived enterprise GitHub Copilot endpoints and Amazon
Bedrock endpoints selected through a stored region, AWS profile, or ARN model
are rejected with provider-specific diagnostics. These diagnostics omit
credential, endpoint, account, and region values. Static personal Copilot and
bundled Bedrock endpoint metadata remain accepted when no dynamic override applies.

The launcher validates the output again, combines and deduplicates rules, and
writes private `rules.json` staging with mode `0600`. Only the sidecar receives
that read-only file. Workspaces containing `/tmp`, including `/` and `/tmp`, are
rejected so staging cannot appear through `/workspace`. `profile.json` and the
managed SSH credential directory are separately over-mounted read-only in Pi,
while `auth.json`, `models.json`, and `settings.json` remain writable for Pi's
supported workflows.

The sidecar receives `NET_ADMIN`; Pi does not. Both share one network namespace
whose IPv4 and IPv6 output policies default to deny. Squid permits CONNECT when
a requested exact host, domain suffix, CIDR, or public-internet destination and
TCP port match a rule. CIDR and internet rules also allow matching direct TCP
from Pi's mapped UID. Internet rules exclude private and special-purpose ranges;
explicit CIDRs can separately grant selected private networks. External UDP,
alternate DNS, unlisted destinations, gateway access, direct TCP loopback other
than the local proxy, link-local, multicast, unspecified, and configured
adjacent ports remain blocked.

The launcher supplies HTTP proxy variables and enables Node's environment proxy
support. Before Docker starts, a restricted launch also configures the bundled
web tools through their profile interface. It locks the profile and creates
`web-search.json`, or atomically replaces it when an update is required, so
`.ssrf.trustEnvProxy` is `true`. Existing provider, policy, range, and other
compatible settings are preserved; a newly staged file is mode `0600`. If the
setting is already true, the file is left untouched.

The web-access configuration must be a contained, regular, non-symlink,
singly-linked JSON object with a compatible `ssrf` value. A malformed, linked,
unsafe, structurally incompatible, or colliding staging path prevents launch
before Docker starts rather than being overwritten. Host and offline launches
do not change this file. The setting may remain after a later mode change and is
inert when Pi-Run has not supplied a proxy. In restricted mode it lets the
controlled proxy resolve remote hostnames without exposing unrestricted DNS to
the workload.

Restricted mode also generates an OpenSSH `ProxyCommand` using `nc -X connect`,
so SSH, SCP, SFTP, Git-over-SSH, and OpenSSH-based Ansible use the sidecar. Other
hostname/domain clients must support HTTP CONNECT; arbitrary non-proxy-aware TCP
clients require an applicable CIDR or public-internet rule. There is no TLS or
application-protocol interception.

Resolver failure, invalid output, empty policy, sidecar startup failure, and
readiness failure all prevent Pi from starting without a host-network retry.
The normalized policy is frozen for that launcher process, including
snapshot-triggered Pi restarts. Startup reports exact model and manual TCP
rules plus the inferred SSH target count and port; it does not print the SSH
inventory. Profile or managed-key changes can influence a later launch but
cannot change the active firewall or proxy policy.

Offline or restricted networking does not hide credentials, undo prior writes,
or turn the container into a VM. An allowed endpoint can receive arbitrary data;
public-internet TCP authority is broad exfiltration authority even if an
enterprise firewall independently blocks some traffic. Authentication and
remote authorization remain separate controls. A credential, kubeconfig,
client, or reachable port is capability—not user permission for an unrelated
operation.

Snapshot and SSH-key management containers can use different network modes for
their bounded operations. An offline or restricted Pi container may request a
snapshot whose separate host-managed operation uses its documented backend.
Consult those task/reference guides rather than applying session networking
assumptions to every host command.

## Profile, shared, and skill exposure

The selected profile is Pi's configuration directory and can include
`auth.json`, model settings, Git configuration, SSH keys, local skills, shared
Guard reviewer preferences, Guardian and CAF modes and policies, CAF friend
preferences, separate Guardian/CAF journals, and sessions. Finalized CAF rounds
are branch-local session metadata. Most Pi-owned state remains writable for
atomic replacement; `profile.json` is separately mounted read-only because it
defines launch-time resource and network authority.

`/shared` is writable when `resources.shared` is `read-write`. Content is not
automatically loaded as context, but any available tool can read or change it.

Every valid profile-local skill is explicitly loaded from the writable profile.
Selected global skills are validated and mounted read-only. Read-only protects
the package files only; scripts and instructions execute or influence behavior
within the session's other permissions.

## CA trust

The host CA bundle is mounted read-only and selected tools can use it for TLS.
This permits organization certificate authorities configured on the host to be
trusted inside Pi-Run. Read-only access prevents container modification of the
host bundle; it does not limit which peers those authorities can authenticate.

## Managed discovery and executable trust

Pi-Run launches Pi with broad extension, skill, and prompt-template discovery
disabled. It then explicitly loads bundled web access, OKF, Planning, Guard
Runtime, Guardian, Call a Friend, and snapshot extensions; core skills; every
validated profile-local skill; and selected validated global skills.

Structural validation checks paths, types, frontmatter, links, and size where
applicable. It does not prove that instructions, scripts, extensions, or fetched
content are safe. Extensions execute in the Pi process with its mounted-data and
network environment, even when an extension exposes narrower internal tools.

Prompt injection can originate in repository instructions, source and data
files, web content, logs, command output, dependency metadata, skills, extension
results, and model responses. Content being inspected is not authorization to
follow embedded instructions.

## Project trust and context

Pi project trust controls project settings and resources supported by Pi. It is
not a tool-permission system. Context files such as `AGENTS.md` can load
regardless of the trust choice, and already enabled tools retain container
access.

Pi-Run's managed loading narrows resource discovery but does not make untrusted
project text harmless. Review unfamiliar project resources and apply explicit
scope restrictions. See [Pi's security guidance](https://pi.dev/docs/latest/security/).

## Runtime-image trust

Released launchers derive their default image from the installed Pi-Run version.
`PI_RUN_IMAGE` overrides that selection for development or alternate runtimes.
An image controls the entrypoint and bundled executables and receives the
selected workspace, profile, startup capabilities, network, and optional mounts.
Use the override only with an image trusted for that exposure.

Inspect the selected launcher and image with:

```bash
pi-run version
```

A matching tag and successful checksum verification do not create independent
security certification. Registry access, image provenance, host Docker security,
and surrounding network controls remain external concerns.

## Workflow-control boundaries

Profile and repository instructions, Planning, Guardian, project trust, and
transcript review are human-control layers rather than kernel-enforced
isolation:

- instructions describe authorization and workflow;
- Planning changes the objective while leaving tools selected;
- Guard is an optional shared review layer: while On it gates Guardian-covered
  `bash`/`run` calls and CAF disclosures; while Off those commands skip review
  and an enabled CAF sends bounded friend/search actions without reviewer calls;
- review failure while Guard is On never silently selects unreviewed execution;
  an open Guardian dispute withholds every acting-agent tool except bounded
  native reads and its structured justification handoff;
- CAF context separation and Guard review are same-process application controls,
  not OS isolation or proof of provider confidentiality;
- project trust controls supported project resources rather than tool access;
- transcripts and separate Guardian/CAF journals are bounded records, not
  tamper-proof audits;
- tool success is not independent verification of filesystem or remote effects.

Technical exposure and workflow controls should reinforce each other. Keep
mounts, credentials, identities, and network authority no broader than the
approved task requires.

[Security task guide](../security.md) · [Profiles](../profiles.md) ·
[Guardian](../guardian.md)
