# SSH access

Pi-Run gives each profile a dedicated SSH identity without mounting your
workstation's complete `.ssh` directory. Managed key pairs and the profile's
host-key database travel with encrypted profile snapshots.

Having a credential makes remote authentication possible; it does not authorize
a task. Tell Pi the exact host, account, intended effect, and limits before
remote work.

## Manage profile SSH keys

Run these commands in your **host terminal**. Replace `default` with the profile
you intend to use and `deploy@server.example.test` with the real account and
host.

### Add a dedicated key

```bash
pi-run --profile default ssh-key add deploy@server.example.test
```

Pi-Run creates a passphrase-free Ed25519 key pair when one does not already
exist, stores it in the selected profile, and makes one interactive
`ssh-copy-id` attempt. OpenSSH may ask you to verify the server fingerprint and
authenticate to the account. Verify an unknown fingerprint independently before
accepting it.

On the next restricted launch, every complete matching managed pair
automatically permits its exact hostname on TCP/22. An IPv4 target permits only
that address as a `/32` on TCP/22. Startup reports their count as `ssh-tcp`
without printing the target inventory; `pi-run ssh-key list` shows it explicitly.
`profile.json` manual rules are unnecessary for standard SSH. Host mode already
has broad network access, while offline mode remains network-none.
Credential presence supplies authentication and reachability, not authorization
for a remote task.

If installation fails, the local pair remains available for inspection and a
later explicit retry. Pi-Run does not silently regenerate or overwrite an
incomplete, invalid, encrypted, or mismatched pair.

### Check the stored identity

```bash
pi-run --profile default ssh-key list
```

The list shows local state and a SHA256 fingerprint without printing private-key
contents or contacting the server. `valid` means the local pair matches; it does
not prove that the server accepts the key.

Restart Pi-Run after adding a key. At startup, Pi-Run creates temporary OpenSSH
configuration for valid profile keys. Inside the running container, inspect the
resolved identity without connecting:

```bash
ssh -G server.example.test | grep -E '^(user|identityfile|identitiesonly|userknownhostsfile) '
```

After remote access is explicitly authorized, ordinary OpenSSH tools can use the
stored hostname:

```bash
ssh server.example.test
```

The same configuration applies to `scp`, `sftp`, Git SSH remotes, and tools that
use OpenSSH. Ansible is not bundled; when supplied separately with its OpenSSH
connection plugin, it can use the configured hostname.

### Remove local key files

```bash
pi-run --profile default ssh-key remove deploy@server.example.test
```

Removal asks for confirmation and deletes only that profile's local private and
public files. It preserves `known_hosts`. The corresponding derived TCP/22 rule
disappears on the next restricted launch; an active policy remains frozen.

**Removing the local pair does not revoke the public key on the server.** Remove
its remote `authorized_keys` entry through a separate, explicitly authorized
procedure, and keep another recovery route before removing your only working
identity.

## Essential boundaries

- Profile private keys are unencrypted and readable inside the selected run.
  Their credential directory is mounted read-only during normal sessions; key
  management uses separate controlled containers. Keep profiles private and use
  [encrypted snapshots](snapshots.md) for backup.
- Pi-Run keeps host-key checking enabled and never stores an account password.
- A valid matching pair grants exact-host TCP/22 reachability in restricted
  mode, but does not prove remote authorization or successful authentication.
- Nonstandard SSH ports, aliases, and additional destinations still need manual
  network rules.
- Host networking can reach real systems, and Guardian does not review
  [every possible action](guardian.md#understand-the-coverage-first).
- Deleting local credentials does not close existing connections or revoke
  remote access.

## Troubleshoot

- **Key rejected during add or startup:** run `ssh-key list` and address the
  reported entry rather than replacing unrelated credentials or weakening file
  permissions.
- **Authentication fails:** verify the intended account, remote installation,
  and server policy; inspect `ssh -G` before opening a connection.
- **Host key changed:** stop and verify server identity independently. Do not
  disable host-key checking to silence the warning.
- **Helper unavailable:** check `pi-run version` and the selected runtime image.

For storage layouts, validation states, target limitations, startup behavior,
and detailed failure semantics, see the
[SSH behavior reference](reference/ssh.md).

[Documentation index](index.md) · [Profiles](profiles.md) · [Security](security.md)
