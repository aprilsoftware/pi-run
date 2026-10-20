# Network and credential policy backends

## Status and purpose

This document records the v0.7 investigation, the `docker-offline` and
`docker-restricted` launcher modes first published in the v0.7.0 prerelease, and
the profile-driven follow-up promoted to stable support in v0.7.2. Supported
availability does not make Pi-Run a sandbox or authorize use of reachable
systems.

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
- the resolved policy is frozen before Pi starts and cannot be changed by the
  running Pi process;
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

The product vocabulary remains small:

- `docker-host` — current host-network behavior and the compatibility default;
- `docker-offline` — Docker `--network none`; and
- `docker-restricted` — default-deny egress through the version-matched
  sidecar.

The v0.7.0 prerelease selects offline and restricted modes per invocation and
requires repeated `--allow-host` values. This proved the enforcement path, but
real use showed that repeating provider and task hostnames makes ordinary model
access cumbersome and makes a later launch easy to return accidentally to host
networking. The per-invocation interface is therefore evidence and a migration
source, not the intended long-term user experience.

## Profile-driven follow-up

A follow-up prerelease should select networking from the profile with one
optional top-level object and typed TCP rules:

```json
{
  "network": {
    "mode": "restricted",
    "allow": [
      {"host": "git.example.com", "tcpPorts": [22, 443]},
      {"domain": "example.com", "tcpPorts": [80, 443, 8443]},
      {"cidr": "10.20.30.0/24", "tcpPorts": [22, 5432]},
      {"cidr": "10.50.0.0/16"}
    ]
  }
}
```

`mode` accepts `host`, `offline`, or `restricted`. An absent `network` object
preserves host networking for profiles created by stable v0.6 releases. The
v0.7.0 interface was explicitly prerelease-only, so its launch flags and
exact-host policy do not establish a migration contract.

Each manual rule has exactly one selector. `host` is exact, `domain` covers the
named DNS suffix and its apex, and `cidr` identifies an IP subnet. Optional
`tcpPorts` is a non-empty set of ports from 1 through 65535; omitting it permits
all TCP ports for that destination. UDP and ICMP remain denied. Automatically
resolved model-provider destinations are separate exact-host TCP/443 rules and
do not need to be repeated in `allow`.

Normal launch syntax remains only profile and workspace selection:

```text
pi-run --profile <name> <workspace>
```

The follow-up removes `--network` and `--allow-host` from normal launches rather
than maintaining two competing sources of authority. Profile creation copies
the source profile's network choice. Policy changes take effect on the next
launch, never in a running namespace.

## Automatic model-provider egress

For restricted profiles, Pi-Run resolves model connectivity automatically from
the selected profile before starting the sidecar:

1. HTTPS `baseUrl` values for custom providers in `models.json` contribute their
   normalized hostname.
2. Provider identities present in `auth.json` are matched to versioned built-in
   provider metadata containing API and required token-refresh hostnames.
3. Model/provider selections in `settings.json` identify configured providers
   that may not need a stored credential.
4. Every resolvable configured provider is included so `/model` switching does
   not require restarting with another hostname list.

Resolution reads only structure needed for provider identity and endpoint
selection. It must not print, copy into policy, or log credential values,
headers, account identifiers, URL paths, or query strings. Hostnames are
lowercased, validated, deduplicated, and restricted to HTTPS port 443. A custom
provider using HTTP, an explicit alternate port, an IP literal, or an invalid
URL makes a restricted launch fail with a clear diagnostic.

The resulting provider TCP/443 rules and optional manual `allow` rules are
normalized and frozen into the private runtime policy copy. Startup reports
model-derived and manual destinations and ports separately. Missing metadata,
unsupported dynamic provider extensions, invalid manual rules, or an empty
effective restricted policy fail closed rather than restoring host networking.
Offline mode does not infer or allow provider endpoints.

Initial automatic resolution targets providers already represented by the
profile. Signing in to a previously unconfigured provider from a restricted
session may remain unsupported until its intent can be known before launch.
This limitation is preferable to allowing every built-in provider endpoint.

## Profile trust and active policy

The selected profile is already the durable identity boundary for model
configuration and credentials. The profile-driven design deliberately treats
`profile.json`, `models.json`, `auth.json`, and `settings.json` as trusted input
for the next launch instead of introducing separate policy and machine-grant
files. This is the chosen usability tradeoff for the profile-driven design.

`profile.json` should be over-mounted read-only in the Pi container because Pi
does not need to update Pi-Run's resource definition. Pi still needs writable
`auth.json`, `models.json`, and `settings.json` for login and model selection.
Changes to those files cannot alter the active sidecar, but they can change the
model-derived host set on a later launch. Pi-Run must display that complete set
at every startup, and documentation must state this trust boundary directly.

The active normalized rule policy remains private temporary host state mounted
read-only only into the sidecar. It is never mounted into Pi. Restricted staging
must continue to reject workspace overlap, provider-resolution failure,
sidecar failure, and proxy failure without falling back to `docker-host`.

## Generalized TCP policy scope

The v0.7.0 restricted path proved default-deny exact HTTPS access. The next
experiment generalizes that boundary to selected TCP services without adding
UDP:

- exact host and DNS-suffix rules use hostname-aware HTTP CONNECT with optional
  destination ports;
- CIDR rules permit direct TCP with optional destination ports;
- omitted ports mean all TCP ports for that one rule;
- direct traffic that does not match a CIDR remains blocked; and
- UDP, ICMP, alternate DNS, and unlisted destinations remain blocked.

CONNECT does not inspect encrypted content and can tunnel protocols such as SSH.
OpenSSH can use `nc -X connect` through the loopback proxy. Other hostname-based
clients must support HTTP CONNECT; a non-proxy-aware application needs an
explicit CIDR rule. This limitation is preferable to resolving names into broad
IP firewall grants, which can admit unrelated services sharing an address.

Port and destination rules constrain reachability, not application behavior or
data contents. HTTP method/path enforcement, TLS interception, UDP, transparent
proxying for arbitrary applications, and credential injection remain separate
work.

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
Guardian, SSH, or snapshots. The locally built images remain only as build cache
unless removed explicitly.

A separate launcher smoke test used a disposable Pi-Run home and the
source-built image. It reported `network=docker-offline`, ran Pi 1.1.0, and left
no test container after exit. This confirms launcher-to-Docker mode selection
and image startup; the smoke invocation used `pi --version` and therefore did
not itself attempt an outbound packet. Packet denial follows Docker's
`--network none` contract and the launch argument has deterministic coverage.

The restricted launcher was then smoke-tested with a disposable
Pi-Run home, the source-built runtime image, and the production egress image. It
reported `example.com:443`, passed sidecar readiness, and ran Pi 1.1.0 in the
shared restricted namespace. The sidecar, private runtime policy copy, and
disposable home were removed. This invocation also used `pi --version`, so its
value is lifecycle integration evidence; packet enforcement evidence remains
the earlier real Docker probe.

### Generalized TCP-rule probe

`experiments/docker-egress-tcp-rules/` is a disposable successor harness. Its
`--execute` path passed on the supported Docker Engine 26 host using a private
Docker network and local echo services. Exact hosts, domain suffixes, selected
ports, selected-port CIDRs, and all-port CIDRs succeeded. Adjacent ports, an
unlisted hostname, an IP literal through the proxy, direct hostname-rule bypass,
an adjacent CIDR address, UDP inside an allowed CIDR, and bypass after sidecar
termination all failed. The workload had no `NET_ADMIN` and could not see the
sidecar policy. This proves the generalized TCP mechanism, not production
launcher, resolver, SSH-configuration, or published-image integration.

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

For v0.7, product integration work stopped on OpenShell and Docker Sandboxes in
favor of the Docker-native sidecar pattern demonstrated by `agent-sandbox` and
`sandboxed-pi`.

The required direct-IP, private-network, IPv6, DNS-bypass, capability, policy,
and fail-closed probes passed on Pi-Run's supported Docker baseline. The initial
backend remained prerelease-only while its limitations and remaining
TUI/provider/credential behavior were evaluated.

Prerelease feedback rejected per-launch network mode and provider-host arguments
as the durable interface. The generalized TCP-rule harness then proved exact
hosts, domain suffixes, CIDRs, selected and unrestricted TCP ports, SSH-style
CONNECT, UDP denial, policy isolation, and fail-closed behavior on Docker Engine
26. Profile integration preserved those properties, and the generalized
profile-driven backend became stable in v0.7.2.

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
