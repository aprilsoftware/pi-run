# Security and isolation reference

This reference records Pi-Run's technical mount, identity, network, discovery,
and trust boundaries. For practical exposure reduction, start with the
[Security task guide](../security.md).

## Normal-session mounts

A launcher-managed Pi session uses these host-backed resources:

| Host resource | Container path | Access |
| --- | --- | --- |
| Selected workspace | `/workspace` | Read-write |
| Selected profile | `/profile` | Read-write |
| Shared directory, when enabled | `/shared` | Read-write |
| Selected global skills | `/skills/<name>` | Read-only |
| Host CA bundle | `/etc/ssl/certs/ca-certificates.crt` | Read-only |
| Private per-launch snapshot request directory | `/run/pi-run-snapshot` | Read-write control channel |

Profile-local skills are part of the writable profile mount. Core skills and
baseline extensions come from the runtime image. The snapshot request channel
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
container shares the host kernel and normal sessions share host networking, so
it is neither a virtual machine nor protection against every kernel or container
runtime vulnerability.

The host user must have Docker-daemon access to launch Pi-Run. That access is
itself highly privileged. Pi-Run deliberately withholds the Docker socket from
the Pi container; mounting it would largely defeat the process and filesystem
boundary.

## Networking and service authority

The default `docker-host` backend uses `--network host`. Loopback can reach
Docker-host services, and surrounding routes can expose LAN, internet, cloud,
cluster, and database endpoints. Package managers, web tools, service clients,
and generated commands can transfer data over that network.

An invocation can instead select `--network docker-offline` before the workspace
or `resume` command. This maps strictly to Docker `--network none` for every Pi
container started by that invocation and provides loopback but no external
container interface.

Experimental `docker-restricted` requires one or more exact hostnames supplied
with repeated `--allow-host` options. The launcher writes the validated list to
a private temporary host file, mounts that copy read-only into a version-matched
egress sidecar, and never mounts it into Pi. The sidecar receives `NET_ADMIN`;
Pi retains its normal dropped-capability set and shares the sidecar's network
namespace. The launcher waits for firewall and proxy readiness before starting
Pi, sets loopback `HTTPS_PROXY` variables, and reports every allowed
`hostname:443`.

The restricted firewall defaults to deny for IPv4 and IPv6. Squid permits HTTPS
CONNECT only to an exact listed hostname on port 443. Direct IP, alternate DNS,
private-address, and arbitrary TCP paths remain blocked by the network-namespace
firewall; clients that ignore the proxy cannot connect directly. There is no TLS
interception or HTTP method/path inspection. An allowed HTTPS service can
receive arbitrary data by design.

Backend and hostname selections apply only to one invocation and its
snapshot-triggered Pi restarts. They are not persisted with a profile or
session. A later launch or resume returns to `docker-host` unless another
backend is selected explicitly. Sidecar startup or readiness failure prevents Pi
from starting, and Pi is never retried with host networking. If the proxy exits,
the firewall remains default-deny and the session loses egress.

Offline or restricted networking does not make writable mounts read-only, hide
credentials in the selected profile, undo prior writes, or turn the container
into a VM. Service authentication and remote authorization remain independent
controls. A credential, kubeconfig, client binary, or reachable port is
capability—not user permission for an unrelated operation.

Snapshot and SSH management containers can use different network modes for their
bounded operations. An offline or restricted Pi container may request a snapshot
whose separate host-managed operation uses its documented backend. Consult those
task/reference guides rather than applying session networking assumptions to
every host command.

## Profile, shared, and skill exposure

The selected profile is Pi's configuration directory and can include
`auth.json`, model settings, Git configuration, SSH keys, local skills, Guardian
logs, and sessions. It is writable as a whole so Pi can safely update files
through atomic replacement.

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
disabled. It then explicitly loads bundled web access, OKF, Planning, Guardian,
and snapshot extensions; core skills; every validated profile-local skill; and
selected validated global skills.

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
- Guardian normally gates acting-agent `bash` and `run` calls; an open dispute
  withholds every acting-agent tool except bounded native reads and its structured
  justification handoff;
- project trust controls supported project resources rather than tool access;
- transcripts and Guardian logs are bounded records, not tamper-proof audits;
- tool success is not independent verification of filesystem or remote effects.

Technical exposure and workflow controls should reinforce each other. Keep
mounts, credentials, identities, and network authority no broader than the
approved task requires.

[Security task guide](../security.md) · [Profiles](../profiles.md) ·
[Guardian](../guardian.md)
