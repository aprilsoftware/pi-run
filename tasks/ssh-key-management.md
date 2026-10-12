# SSH key management for transparent Ansible authentication

## Status and goal

This document describes the agreed solution direction, not implemented behavior.

The goal is to make SSH authentication easy inside Pi-Run: Ansible should use the
selected profile's credentials without private-key paths or key-selection
settings in inventory, playbooks, or command-line arguments.

An SSH agent and compatibility with the existing host-agent interface are not
requirements; the design starts from straightforward Ansible authentication.

## Selected approach: ordinary OpenSSH configuration

Use existing private-key files directly. Pi-Run reads the remote username and
hostname from each `user@host` filename and prepares OpenSSH configuration inside
the container. SSH supplies both the username and the matching private key.
For passphrase-free automation keys, no SSH agent is needed.

The profile is already mounted at `/profile`, and OpenSSH is already bundled;
no new credential mount or package is needed.

### Credential layout

```text
/profile/credentials/ssh/
├── deploy@server.example.test
├── deploy@server.example.test.pub
└── known_hosts
```

The private-key filename is `user@host`. The corresponding `.pub` file supports
fingerprinting and public-key deployment; it is not the private identity used by
this direct-file approach. `known_hosts` records trusted server host keys.

Other credential directories, such as Git or TLS credentials, are not included.

### Automatic client configuration

For `deploy@server.example.test`, Pi-Run would prepare this entry in the runtime
user's `~/.ssh/config`:

```sshconfig
Host server.example.test
    User deploy
    IdentityFile /profile/credentials/ssh/deploy@server.example.test
    IdentitiesOnly yes
    UserKnownHostsFile /profile/credentials/ssh/known_hosts
```

Thus `ssh server.example.test` uses `deploy` and the matching private key without
an explicit username or `-i` argument. `IdentitiesOnly yes` prevents implicitly
offering unrelated agent identities. A `%r@%h` lookup rule alone would not infer
the username; the generated `User` directive is essential.

Each startup generates entries from the stored keys, regardless of whether their
public keys have been installed remotely. There is no installation-status flag
that gates configuration. A server can still reject a locally configured key if
its matching public key is absent from the remote account's `authorized_keys`.

If several filenames specify different users for the same hostname, Pi-Run must
require an explicit selection rather than silently choose one. The selection
mechanism remains to be defined before supporting such ambiguous targets.

Configuration is prepared after privilege dropping, as the mapped runtime user.
It belongs to the container's ephemeral home, not the persistent credentials.
Existing runtime configuration must not be overwritten silently; conflict
handling must be specified when implementing the startup increment.

## How Ansible uses it

Ansible's standard OpenSSH connection uses ordinary SSH client configuration.
Inventory supplies the destination, without repeating the username from the key:

```ini
[servers]
server.example.test
```

The generated SSH entry supplies `deploy` and its key. No `ansible_user`,
`--private-key`, `ansible_private_key_file`, or key-specific SSH arguments are
needed when relying on this configuration. An explicitly configured Ansible
remote user overrides SSH's default and should not conflict with the inferred
user. The same setup works for OpenSSH-based `ssh`, `scp`, and `sftp`.

The hostname passed to SSH must match the generated entry. An inventory alias
whose `ansible_host` is the matching hostname can work, but connecting to an IP
address when the key is named after a DNS hostname requires additional mapping.
Alias/IP mapping is not part of the initial solution.

## Credential management behavior

Stored-file management commands and syntax remain to be proposed separately.

- **List:** show stored target names and public-key fingerprints, and report
  incomplete or invalid pairs without displaying private-key contents.
- **Add:** for an explicit `user@host` target, create a passphrase-free Ed25519 key
  pair if absent, or reuse the existing pair without overwriting it. Then use
  `ssh-copy-id` to install the public key on that remote account, as in the
  prototype. SSH prompts for the account password when needed; Pi-Run does not
  store it. This explicit operation makes the target ready for key authentication
  when installation succeeds. Existing-key import, if wanted, is separate future
  scope rather than a requirement for this operation.
- **Remove:** remove only the named local key pair. Preserve `known_hosts` and
  unrelated credentials. Local deletion does not revoke remote authorization.

If public-key installation fails, retain the local pair and report the failure.
Running add again reuses that pair and retries installation: local existence must
not skip copying, unlike the prototype. Do not retry the remote operation
silently. A failed copy does not exclude the key from startup configuration.

Local configuration and remote authorization are independent. For example, an
incorrect password during installation leaves a stored key and a generated SSH
entry, but the server rejects that key until its public key is installed.
Startup and listing never connect to targets or deploy keys.

New target entries are generated on the next Pi-Run startup. Automatic refresh of
already-running containers is outside the initial scope. For an existing entry,
SSH reads the selected file when authenticating; removing that file prevents
subsequent file-based authentication, but already-established or multiplexed SSH
connections may continue to work.

## Preconditions and safety boundaries

- Unattended direct-file authentication requires passphrase-free keys. The
  prototype generated such keys, but existing real keys were not inspected to
  determine whether they are encrypted. Encrypted keys need a separate unlocking
  mechanism; an SSH agent remains an alternative if that becomes a requirement.
- Successful key authentication requires the public key to be authorized on the
  target. Add performs installation explicitly; startup configuration does not
  create accounts, install keys, or revoke `authorized_keys` entries.
- Host-key verification remains enabled. Reuse the profile's `known_hosts`;
  unknown or changed host keys require deliberate trust handling, not bypasses.
- New private keys should be mode `0600`, and managed credential directories
  should be private. Do not broadly rewrite permissions on existing data.
- Reject unsafe target names and paths in management operations. Do not follow
  links outside the intended credential directory or scan unrelated credentials.
- Credential availability does not authorize remote access or administrative work.

## Incremental implementation plan

1. **Automatic SSH lookup:** infer users from filenames, prepare per-host runtime
   configuration, and test username/identity resolution. Proposed files:
   `docker/entrypoint.sh`, a new `tests/ssh-credentials-test.sh`, and `README.md`.
   No new dependencies; estimate 150–250 added/removed handwritten lines.
   No credential modifications or remote connections.
2. **Stored-key listing:** add read-only inventory and incomplete-pair reporting.
3. **Add:** implement create/reuse plus interactive public-key installation,
   preserving the pair on failure and supporting explicit retries.
4. **Remove:** implement narrowly targeted local removal with clear reporting.
5. **Integration and cleanup:** validate Ansible usage, update runtime skills,
   and separately scope removal of obsolete host-agent controls.

Each implementation increment requires its own concrete proposal and approval.
No new `sshAgent: profile` setting or agent startup is part of this solution.

## Validation and remaining evidence

Use disposable profiles, runtime homes, and generated keys for tests. Check Bash
syntax and ShellCheck; verify inferred usernames, matching private-key paths,
restrictive identity selection, ambiguous-host handling, safe runtime-config
handling, and unchanged credentials/known-hosts during startup. Use a local
failing `ProxyCommand` for no-network SSH lookup checks.

For add, use isolated fixtures to verify generation, existing-pair reuse,
interactive password handling, failure reporting, key retention, and explicit
retry behavior. No startup entry should depend on remote installation status.

When a suitable environment is available, test real container startup as the
mapped non-root user and Ansible's OpenSSH connection against an explicitly
supplied disposable target, without username or key-path options. Docker and
Ansible were unavailable in the investigation environment, so those checks
remain outstanding.

Reference: [OpenSSH ssh_config](https://man.openbsd.org/ssh_config).
