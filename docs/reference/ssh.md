# SSH behavior reference

This reference records Pi-Run's detailed SSH storage, validation, and startup
behavior. For normal setup and commands, start with the
[SSH task guide](../ssh.md).

## Profile key storage

Profile credentials live under the data home printed by `pi-run home`:

```text
profiles/<profile>/credentials/ssh/
├── deploy@server.example.test
├── deploy@server.example.test.pub
└── known_hosts
```

The private filename is `user@host`; its public half appends `.pub`. New
credential directories use mode `0700`, private keys `0600`, and public keys
`0644`. Managed credentials must be regular, singly linked files under the
profile store; symbolic links, hard links, and unsafe permissions are refused.

Private keys are passphrase-free Ed25519 files. They are available through a
read-only credential-directory over-mount in the selected profile's running
container and are included in complete encrypted snapshots. Key-management
containers retain controlled write access. Creating a profile does not copy
credentials. Keep profiles out of source control and preserve snapshot recovery
secrets separately.

## Key-list states

`pi-run --profile <name> ssh-key list` performs local, networkless validation:

| State | Meaning |
| --- | --- |
| `valid` | The private key is usable and its public file matches. |
| `private-only` | A usable private key has no public file. Startup can use it, but `add` refuses the incomplete pair. |
| `public-only` | The private key is missing, so the entry cannot authenticate. |
| `mismatched-pair` / `invalid-public` | The files require inspection and are not overwritten automatically. |
| `invalid-or-encrypted-private` | The private key is invalid or requires a passphrase. |
| `ambiguous-host:…` | More than one stored target uses the same hostname. |
| `unsafe-entry` | A name, file type, link, or private-key permission is unsafe. |

An empty store reports “No SSH keys stored.” Listing prints fingerprints rather
than private contents. A valid local pair is not evidence of server installation
or connection success.

## Add behavior and target limits

`ssh-key add` runs a short-lived, interactive container with the selected
profile, host networking, and no workspace mount. It creates a new pair only
when neither half exists. A complete matching pair is reused; incomplete,
mismatched, encrypted, invalid, ambiguous, or unsafe entries stop the operation.

Pi-Run then makes one `ssh-copy-id` attempt with the public key and profile
`known_hosts`. OpenSSH handles host-key confirmation and account authentication.
Pi-Run does not disable host-key checking or store the account password. A failed
or uncertain attempt retains the pair and is never retried automatically.

Managed targets support ordinary hostname or IPv4 spelling and one account per
hostname. Host ambiguity checks are case-insensitive. This mechanism does not
provide key import, encrypted-key unlocking, aliases, ports in key names, IPv6
target naming, IP-to-DNS mapping, or remote revocation.

Listing and removal do not use container networking. Removal confirms, deletes
only the named local pair, preserves `known_hosts`, and succeeds without deleting
unrelated entries when the pair is absent. It never edits remote
`authorized_keys` or terminates connections.

## Restricted network inference

Before a restricted launch, the offline resolver inspects the managed SSH store.
Each complete, matching, unencrypted pair contributes an exact hostname TCP/22
rule; an IPv4 target contributes an exact `/32` TCP/22 rule. Rules are normalized,
deduplicated, reported as `ssh-tcp`, and frozen with model and manual rules.
Private material, public keys, comments, and fingerprints never enter policy
output.

Incomplete, invalid, encrypted, mismatched, linked, unsafely permissioned, or
hostname-ambiguous stores fail restricted resolution rather than granting
partial access. Removing a pair removes its derived rule on the next launch.
Host mode is unchanged and offline mode never applies derived access. IPv6
names, aliases, and nonstandard ports are not inferred.

## Startup OpenSSH configuration

At normal startup, every usable private key creates an entry in the runtime
user's temporary `~/.ssh/config`. Each entry supplies:

- the stored hostname and inferred remote user;
- the profile private-key path;
- `IdentitiesOnly yes`; and
- the profile's `known_hosts` path.

Startup reads credentials but does not connect, install keys, or modify the
store. A usable private key without a `.pub` file can still be configured.
Invalid or encrypted keys, unsafe credential objects, multiple identities for
one hostname, or an existing runtime `~/.ssh/config` stop startup rather than
being ignored or overwritten. Changes require a new Pi-Run container.

Inspect resolution without connecting:

```bash
ssh -G server.example.test | grep -E '^(user|hostname|identityfile|identitiesonly|userknownhostsfile) '
```

An explicit user supplied to SSH, a Git remote, or another client overrides the
inferred user and must identify the intended account.

## OpenSSH-based tools

Ordinary `ssh`, `scp`, and `sftp` use the generated configuration. Git SSH
remotes also use it unless their URL supplies a different user.

Ansible is installed in the runtime image and uses its OpenSSH connection plugin
by default. An inventory can use only the configured hostname:

```ini
[servers]
server.example.test
```

OpenSSH then resolves the inferred user and profile identity. An explicit
`ansible_user` overrides that user. Other Ansible connection methods need not
use this configuration.

## Diagnostic boundaries

- Use `ssh-key list` when normal startup rejects credentials; management
  containers skip startup SSH configuration.
- Distinguish local key validity, remote public-key installation, account
  selection, server policy, and host identity when diagnosing authentication.
- Generated profile-key entries use `IdentitiesOnly yes`, but deliberate client
  overrides can change identity selection.
- A complete managed credential implies exact-target TCP/22 reachability in
  restricted mode. It is still not user authorization to connect or perform work.
- Keep literal secrets out of commands, conversations, and published logs.

[SSH task guide](../ssh.md) · [Profiles](../profiles.md) ·
[Security and isolation](../security.md)
