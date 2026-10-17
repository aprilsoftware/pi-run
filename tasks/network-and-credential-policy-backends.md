# Network and credential policy backends

## Status and purpose

This document records the v0.7 investigation and recommended experiment. It
does not describe implemented Pi-Run behavior or authorize production use.

The goal is to add enforceable network policy while retaining Pi-Run's existing
profile, workspace, session, Guardian, and snapshot semantics. The preferred
solution should require no host service beyond the Docker Engine that Pi-Run
already uses.

## Current boundary

A normal Pi-Run session runs the complete Pi process in Docker with:

- host networking;
- one workspace and the complete selected profile mounted read-write;
- optional shared files mounted read-write;
- selected global skills mounted read-only;
- dropped capabilities except those needed for entrypoint UID/GID setup;
- `no-new-privileges`; and
- no host home, other profiles, snapshot repository, or Docker socket.

The selected profile can contain provider authentication, SSH keys, settings,
instructions, skills, sessions, and Guardian state. Profile selection narrows
which identity is present, but Pi can read every raw credential exposed in that
profile. Guardian and instructions do not constrain routes available through
host networking.

## Required invariants

A restricted backend must ensure:

- policy failure never broadens access;
- the Pi container cannot modify its active policy or firewall;
- the effective exposure is displayed before Pi starts;
- direct IP, alternate DNS, IPv6, private-address, and proxy bypasses fail;
- raw credentials are never described as hidden when Pi can read them;
- policy remains host-owned rather than writable through the selected profile;
- the unrestricted backend remains explicit and unchanged; and
- cleanup does not leave privileged containers, networks, or policy material.

Kernel or Docker daemon compromise, malicious host administrators, complete DLP,
and guarantees against every covert channel remain outside the initial scope.
An allowed endpoint can receive data by design.

## Host-dependency constraint

Pi-Run is intended to hide most host complexity behind a versioned image and a
small launcher. Requiring users to install and operate another gateway, runtime,
or policy daemon would weaken that property and create support differences
between otherwise valid Docker hosts.

The v0.7 experiment therefore uses only ordinary Docker primitives and
versioned Pi-Run-owned images. Docker remains a powerful host dependency, but
no Docker socket is mounted into the session and no persistent Pi-Run daemon is
introduced.

## Alternatives evaluated

### OpenShell

OpenShell provides strong network, filesystem, process, and credential controls.
A real local probe reached its Docker driver but failed during boundary-bundle
staging on Debian Trixie's Docker Engine 26.1.5. OpenShell 0.1.4 documents Docker
Engine 28 or newer as its supported baseline. Making OpenShell work would have
required replacing Debian's Docker package or adding Podman and operating an
OpenShell gateway.

That is a valid architecture for deployments already standardized on
OpenShell, but it is not the default Pi-Run direction. The experiment also
confirmed that arbitrary bind mounts require deliberately weakening
OpenShell's default gateway configuration.

### Docker Sandboxes

Docker Sandboxes provides a managed microVM, network policy, and credential
proxying. Its local Linux support and installation path introduce a separate
`sbx` platform and supported-host assumptions. Its workload user, workspace,
and mount contracts also differ from the released Pi-Run image.

It remains relevant prior art but is not an appropriate baseline for ordinary
Debian Docker installations.

### Tool-only Pi extensions

`sandboxed-pi`, `pi-secure-it`, permission-mode extensions, Bubblewrap, and
similar projects can constrain selected tools. They are useful when Pi runs on
the host, but they do not provide the same whole-process boundary as Pi-Run:
extensions, model clients, and any unwrapped process may remain outside the tool
sandbox.

`sandboxed-pi` is nevertheless valuable prior art for transparent egress:
iptables prevents direct traffic while a proxy and DNS interceptor enforce
hostname policy.

### Complete agent environment managers

`agent-sandbox` runs complete coding agents with a mitmproxy sidecar and an
iptables bypass-prevention layer. Its later variants also support fine-grained
request policy and proxy-side secret injection. This is the closest published
architecture to the proposed Pi-Run backend.

Using its project generator and Compose environment directly would duplicate
Pi-Run's identity, profile, image, and lifecycle model. Pi-Run should reuse the
architectural lessons, not wrap a second workstation manager.

Clampdown provides a stronger multi-container and nested-container model, but
requires a substantially larger supervisor and Podman-oriented runtime. It is
outside the small local-workstation scope.

### Firewall in the Pi container

The root entrypoint could receive `NET_ADMIN`, install nftables rules, drop the
capability, switch to the mapped user, and run Pi. This is small, but it makes
the privileged bootstrap responsible for proving that Pi descendants can never
recover network administration.

It would also be dangerous with host networking: `NET_ADMIN` in the host
network namespace could affect host policy. A restricted backend must never
combine these two settings.

IP firewall rules alone do not provide durable hostname policy. SaaS and
package endpoints rotate addresses and often share CDN addresses. Resolving a
hostname into an allowed IP set can accidentally permit unrelated services on
the same address.

## Recommended architecture

Use an ephemeral Docker egress sidecar:

```text
Pi-Run launcher
├── egress sidecar
│   ├── ordinary Docker bridge networking
│   ├── NET_ADMIN for firewall bootstrap
│   ├── dedicated proxy UID
│   ├── host-owned policy mounted read-only
│   └── hostname/port-aware HTTP CONNECT proxy
│
└── Pi container
    ├── shares the sidecar network namespace
    ├── receives no NET_ADMIN
    ├── has no host network
    ├── sends HTTP(S) to the loopback proxy
    └── retains current workspace/profile mounts
```

The sidecar installs a default-deny output firewall before the Pi container
starts. Only traffic owned by the proxy's dedicated UID may leave the network
namespace. Pi can reach the proxy over loopback but cannot open direct external,
host, LAN, or private-address connections. Processes that ignore proxy
environment variables fail rather than bypass policy.

The Pi container does not mount the policy and cannot modify firewall rules.
The launcher starts Pi only after a sidecar health check confirms that policy
and firewall initialization succeeded. If the proxy exits, unmatched traffic
continues to be denied and the session loses egress.

The sidecar is not a general host daemon. It is created for one Pi-Run launch,
receives no workspace or profile mount, exposes no host port, and is removed at
cleanup. Neither container receives the Docker socket.

## Backend model

The initial product vocabulary should remain small:

- `docker-host` — current host-network behavior;
- `docker-offline` — no network namespace access; and
- `docker-restricted` — default-deny egress through the sidecar.

Backend selection must be explicit. A restricted-backend failure must not retry
with `docker-host`.

No general backend framework should be added before the sidecar experiment
passes. The launcher may initially implement the experiment as a separate path.

## Policy ownership

Authoritative policy must not live only in the writable selected profile. The
intended ownership remains:

```text
Pi-Run home/
├── profiles/<name>/profile.json       # requested working identity
├── policies/<policy>.json             # portable host-managed limits
└── machines/<machine-id>.json         # local assignment and grants
```

Effective exposure is the intersection of the profile request, portable policy,
and machine-local grant. The sidecar receives only the already-resolved runtime
policy. `policies/` and `machines/` are not mounted into Pi.

This layout is directional; the feasibility harness does not introduce these
schemas.

## Initial policy scope

The first restricted experiment should support only:

- default deny;
- exact HTTPS hostname and port rules;
- an explicit offline mode;
- blocked direct IP and non-HTTP protocols; and
- readable audit events containing no secrets.

It should not perform TLS interception. Clients that honor `HTTP_PROXY` and
`HTTPS_PROXY` use CONNECT, allowing the proxy to enforce the requested hostname
and port without reading encrypted content. Clients that do not support the
proxy are blocked.

HTTP method/path enforcement, transparent TLS interception, SSH, databases,
arbitrary TCP, package-manager compatibility exceptions, and credential
injection are separate experiments.

## Credentials

The first sidecar does not hide credentials. Provider authentication in the
selected profile remains readable by Pi and must be described that way.

A later proxy may hold provider credentials and inject them only for approved
TLS destinations. That would require TLS termination or a provider-specific
protocol and careful OAuth-refresh handling. It must not be implied by network
allowlisting alone.

SSH-agent forwarding hides key bytes but grants signing authority and is not
destination-restricted by itself. It remains separate from HTTP egress policy.

## Feasibility harness

The first implementation should stay outside the normal launcher path and use
only disposable endpoints, policy, containers, and credentials. It must prove:

| Area | Required observation |
| --- | --- |
| Allowed HTTPS | One exact hostname succeeds through the proxy |
| Denied hostname | An unlisted hostname fails |
| Direct IP | Connecting to the allowed service by IP fails |
| Private networks | Loopback exceptions aside, host/LAN/RFC1918/link-local fail |
| IPv6 | No unlisted IPv6 route succeeds |
| DNS bypass | Alternate DNS and direct DNS packets fail |
| Other protocols | UDP, SSH, and arbitrary TCP fail |
| Capabilities | Pi has no effective or permitted `NET_ADMIN` |
| Policy | Pi cannot read or modify the host-owned policy |
| Failure | Killing the proxy does not restore direct connectivity |
| Credentials | No test secret appears in Pi files, env, args, or logs |
| Existing semantics | Workspace/profile writes and session paths are unchanged |
| Cleanup | Sidecar, workload, and temporary state are removed |

The harness should inspect actual kernel-visible capabilities and routes rather
than infer them from Docker arguments. Negative tests are required; a successful
allowed request alone is not evidence of enforcement.

### Observed feasibility result

The disposable harness passed on Debian Trixie with Docker Engine 26.1.5. It
allowed `example.com:443` through the explicit proxy and blocked an unlisted
hostname, an IP literal through the proxy, direct public IP access, a private
container address, alternate DNS, direct IPv6, and non-proxy TCP. The workload
had no `NET_ADMIN`, could not see the sidecar policy, and remained unable to
connect after the proxy was killed. The cleanup trap removed every test
container; no custom Docker network was created.

A second harness built the current Pi-Run Dockerfile and ran that image in the
sidecar network namespace. The real entrypoint mapped the host UID/GID, executed
`pi --version`, and persisted writes through disposable workspace, selected
profile, and session-path mounts. The image had no `NET_ADMIN`, could not see a
sibling profile or the sidecar policy, allowed `example.com:443`, blocked an
unlisted hostname and direct public IP, and remained blocked after proxy
termination. Its containers and temporary host state were removed.

Together these results prove the bounded network-namespace and sidecar pattern
with the current source-built Pi-Run image on Pi-Run's Debian Docker baseline.
They do not prove a published release artifact, interactive TUI behavior,
actual transcript creation or resume, provider credentials and model requests,
Guardian, SSH, snapshots, or normal launcher integration. The locally built
images remain only as build cache unless removed explicitly.

## Important limitations

- This is container isolation on a shared host kernel, not a VM sandbox.
- The proxy and its policy parser become security-sensitive Pi-Run components.
- A vulnerability in the proxy may weaken policy.
- An approved HTTPS endpoint can accept arbitrary uploaded data.
- CONNECT and WebSocket access can create long-lived channels.
- Certificate-pinned clients may not work if TLS interception is added later.
- Docker administrators and root on the host remain trusted.

These limitations must be visible in documentation and release notes.

## Decision

For v0.7, stop product integration work on OpenShell and Docker Sandboxes. Test
a Docker-native sidecar based on the enforcement pattern demonstrated by
`agent-sandbox` and `sandboxed-pi`.

If the sidecar cannot reliably deny direct IP, private-network, IPv6, and DNS
bypasses on Pi-Run's supported Docker baseline, do not ship hostname claims.
Retain only an explicit offline backend while reconsidering the architecture.

## Sources

- [Pi containerization guide](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/containerization.md)
- [Docker runtime privilege and capabilities](https://docs.docker.com/engine/containers/run/)
- [Docker packet filtering and firewalls](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [Docker bridge networking](https://docs.docker.com/engine/network/drivers/bridge/)
- [agent-sandbox](https://github.com/telepathykat/agent-sandbox)
- [agent-sandbox with fine-grained policy and secret injection](https://github.com/mattolson/agent-sandbox)
- [sandboxed-pi](https://github.com/rnorth/sandboxed-pi)
- [Clampdown](https://github.com/89luca89/clampdown)
- [OpenShell installation requirements](https://github.com/NVIDIA/OpenShell/blob/main/docs/about/installation.mdx)
- [Pi-Run security reference](../docs/reference/security.md)
- [Pi-Run profiles reference](../docs/reference/profiles-and-skills.md)
