# Production configuration and recovery

This guide is the source of truth for operator-held production inputs, their ownership, and recovery. It is for operators preparing a workstation, rebuilding a host, or restoring production; use the [production release cookbook](production-release-cookbook.md) for routine releases and backup-input updates, the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md) for host setup and fresh-cluster restoration, and [production Kubernetes operations](production-kubernetes.md) for lifecycle and recovery details.

**Table of contents**

- [Private workstation directory](#private-workstation-directory)
- [Ownership and lifecycle](#ownership-and-lifecycle)
- [Drive authorization](#drive-authorization)
- [Clean rebuild boundary](#clean-rebuild-boundary)

## Private workstation directory

Keep operator configuration outside the checkout in `~/.config/recipe-db/`. Restrict it to the operator (`umask 077`, directories mode `0700`, private files mode `0600`). The provisioning devcontainer bind-mounts this directory at `/home/vscode/.config/recipe-db`; create it before starting that container.

```text
~/.config/recipe-db/
├── deployment/
│   ├── pi-values.yaml
│   ├── auth-accounts.json
│   ├── google-oauth-client-secret
│   ├── oauth2-cookie-secret
│   └── acme-account-email             # only when HTTPS staging is configured
├── provisioning/
│   └── inventory.yml
├── ssh/
│   ├── recipe-db-pi                   # private SSH key
│   └── known_hosts                    # verified Pi host key
├── kubeconfig/
│   └── pi.yaml                        # generated cluster-admin credential
└── backup/
    ├── backup.json
    ├── backup-values.yaml
    ├── backup-release-ref
    └── drive-oauth-client.json         # dedicated Desktop OAuth client, not tokens
```

The backup inputs are operator-prepared. `backup.json` must use `/etc/recipe-db/rclone.conf`, `/var/lib/recipe-db-backup`, `/var/lib/recipe-db-backup/work`, and `/usr/local/sbin/recipe-db-backup-capture` for its rclone config, state, staging, and capture command paths. In `backup-values.yaml`, private `secrets` entries must point to direct files under `~/.config/recipe-db/deployment/`. The explicit `backup-configure.yml` playbook copies the files and referenced application inputs into root-only `/etc/recipe-db/`, then rewrites those values paths to `/etc/recipe-db/application-inputs/`. The Pi never mounts operator home.

`backup-release-ref` must be the immutable OCI release artifact reference `ghcr.io/dhhyi/recipe-db-releases@sha256:<64 lowercase hexadecimal characters>`; commit IDs and tags are not accepted.

`pi-values.yaml` begins as a private copy of [`deploy/pi.yaml`](../deploy/pi.yaml). It contains the Pi's immutable release/deployment settings and absolute paths to operator-held secret files. `auth-accounts.json` follows [`graphql/auth-accounts.schema.json`](../graphql/auth-accounts.schema.json). The Google client ID is public configuration in the values file; its client secret and OAuth cookie key are private inputs. The ACME email is needed only for the optional HTTPS configuration.

`inventory.yml` is copied from [`provisioning/inventory.example.yml`](../provisioning/inventory.example.yml). Set its host, SSH-key path, measured root UUID, and narrowly scoped administrator/application networks. Keep `known_hosts` limited to the Pi host key verified during bootstrap. The kubeconfig is generated from the live Pi by `access.yml`; it is sensitive, disposable, and can be recreated after provisioning.

## Ownership and lifecycle

| Item | Source/owner | Lifecycle |
| --- | --- | --- |
| Provisioning code, pinned tool versions/checksums, deployment templates, authorization schema | Repository | Authoritative; review changes in source control |
| Pi values file and auth-account policy | Operator directory | Authoritative private inputs; preserve across rebuilds |
| Google OAuth client secret and cookie key | Google/client and operator directory | Required only when Google sign-in is enabled; preserve securely |
| `backup/drive-oauth-client.json` | Google/client and operator directory | Dedicated backup Desktop OAuth client credentials; preserve encrypted with chezmoi. Separate from application sign-in credentials. |
| SSH private key and verified host key | Operator directory | Required to provision/administer the Pi |
| USB root UUID, Pi hostname, allowed network CIDRs | Measured/operator-specific | Record in inventory; UUID must be measured again after changing the boot device |
| Pi kubeconfig | Generated from the running cluster | Runtime admin credential; do not treat as recoverable from a backup |
| Rendered Kubernetes manifests and checksums | Values + immutable release + deployment renderer | Derived at deployment; do not archive as configuration |
| GraphQL ingress token and Typesense API key | Generated during each production deploy/restore | Ephemeral cluster credentials. The operation creates and uses them, then deletes its private temporary copies. Do not configure, retain, or back them up. Each operation rotates them and rolls dependent workloads. |
| Kubernetes Secrets and application PVC data | Live cluster | Runtime state; restore through the documented backup/recovery workflow |
| ACME account and certificate files | Traefik's retained `recipe-db-acme` PVC | Runtime state, outside application backup capture. Protect separately or reissue after recovery. |
| `backup.json`, backup values, release reference and referenced application inputs | Pi under `/etc/recipe-db/` and operator recovery directory | Operator-managed recovery inputs; installed explicitly after restore and acceptance; application backup archives do not include them |
| `/etc/recipe-db/rclone.conf` | Pi-only Google Drive authorization state | Created interactively on the Pi; rclone refreshes its tokens there. Never copy it to/from operator home, chezmoi or application backups. Reauthorize after a fresh host rebuild or lost/broken authorization, not routine updates or application restores. |

Development `.secrets/` files are fixtures for local Compose and tests. They are not production inputs and must not be copied into this directory as production secrets.

The backup service and timer remain stopped and disabled after host provisioning or backup-input installation. Use the [production release cookbook](production-release-cookbook.md) to install inputs, verify a capture, and enable the schedule in the required order.

## Drive authorization

The home directory holds the dedicated Desktop OAuth client JSON, not an authorized `rclone.conf`. Client credentials identify the application; interactive Google login grants access to the backup account. Preserve the same account, client, remote name, folder and `drive.file` scope when rebuilding. Keep the account access/recovery method independently off-device.

Routine configuration synchronization leaves `/etc/recipe-db/rclone.conf` untouched. The nightly backup's rclone process refreshes tokens in that file; its systemd service allows writes to the private `/etc/recipe-db` directory because rclone saves by replacing the file. Application restore does not restore or replace it.

### Authorize on a new Pi

Provision the host first. Before downloading a backup or configuring scheduled backups, connect from the workstation with a loopback-only OAuth tunnel:

```sh
ssh -i "$HOME/.config/recipe-db/ssh/recipe-db-pi" \
  -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:53682:127.0.0.1:53682 piadmin@recipe-pi.home
```

Use the verified host key and the host/user from the private inventory. On the Pi:

```sh
sudo systemctl stop recipe-db-backup.timer
sudo systemctl show --property=ActiveState --value recipe-db-backup.service
```

Continue only when the service is `inactive` or `failed`; wait for a running backup, do not kill it. In a private, unrecorded terminal:

```sh
sudo install -d -o root -g root -m 0700 /etc/recipe-db
sudo sh -c 'umask 077; exec rclone config --config /etc/recipe-db/rclone.conf'
```

Create the remote named in `backup/backup.json` (currently `gdrive`), select Google Drive, and enter the existing client ID and secret from `backup/drive-oauth-client.json` at the interactive prompts. Select `drive.file`, not full Drive access. Do not put client secrets or tokens in command arguments, chat, logs or screenshots.

Answer **Yes** to browser authorization, even though the Pi is headless. Open the displayed loopback URL in the workstation browser through the tunnel, sign in to the dedicated backup account and approve access. This [SSH-tunnel flow](https://rclone.org/remote_setup/#configuring-using-ssh-tunnel) keeps the authorized config on the Pi; do not use the alternative workstation-config-copy flow. Close the tunnel afterwards.

Check permissions on the Pi:

```sh
sudo stat -c '%U %G %a' /etc/recipe-db/rclone.conf
```

Expect `root root 600`. Privately confirm access to the existing backup folder before following the [release cookbook](production-release-cookbook.md#4-align-backup-capture-with-the-deployed-release) to configure, verify and enable backups. Do not create a different folder or widen the OAuth scope to make a check succeed.

### Reauthorize only when needed

Routine updates, retrying an application restore, and restoring an older application backup keep the Pi's current authorization. A freshly flashed Pi has no authorization and needs the step above. An expired access token alone does not require login: rclone uses its refresh token automatically. Missing/revoked authorization requires interactive reconnect.

First investigate publisher status: `upload-failure` with `remote-operation` can also mean a network or remote failure; an `overdue`/`check-overdue` check older than 26 hours can mean scheduling or capture failure. Neither alone proves that login is needed.

For an approved reconnect, stop the timer and wait for the backup service as above. Preserve the usable original and work on a new root-only directory on the Pi:

```sh
AUTH_DIRECTORY=$(sudo mktemp -d /etc/recipe-db/reauthorize.XXXXXXXX)
```

In the same Pi shell:

```sh
sudo install -o root -g root -m 0600 /etc/recipe-db/rclone.conf "$AUTH_DIRECTORY/rclone.conf"
sudo rclone config reconnect gdrive: --config "$AUTH_DIRECTORY/rclone.conf"
```

Use the same SSH tunnel and browser flow. Verify real access to an existing backup using that working config. If authorization or verification fails, leave the original untouched and report the failure. Do not revoke the original credentials for a rehearsal.

After operator approval, retain the prior config in the root-only rehearsal directory and atomically install the verified working file:

```sh
sudo install -o root -g root -m 0600 /etc/recipe-db/rclone.conf "$AUTH_DIRECTORY/previous.conf"
sudo chown root:root "$AUTH_DIRECTORY/rclone.conf"
sudo chmod 0600 "$AUTH_DIRECTORY/rclone.conf"
sudo mv -T "$AUTH_DIRECTORY/rclone.conf" /etc/recipe-db/rclone.conf
```

Verify the next backup before removing the prior config. On failure, keep the timer disabled and investigate; restore the prior file only if its authorization is still usable. After acceptance, remove only that rehearsal directory and its files, then re-enable the schedule using the release cookbook. No authorized copy is sent to the workstation.

### Remove former home copies

For an existing centralized setup, first confirm that the Pi's authorization works and that `drive-oauth-client.json` and independent Google account access are available. Then remove the former `backup/rclone.conf` from the home directory and from chezmoi's managed source using the operator's private dotfile workflow. Do not run an old chezmoi apply that recreates it. Do not copy the Pi's file back to home. This repository change does not itself remove files from your private home directory or dotfile repository.

## Clean rebuild boundary

Before erasing or replacing the boot device, independently verify an off-device application backup, its matching immutable release, all required private files, and the ability to authorize Drive with the dedicated client and account. Reimage destroys the Pi's authorization along with the OS and all on-device application data. Follow the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md), authorize Drive on the new Pi, then restore into the new cluster using the recorded release and the [production recovery procedure](production-kubernetes.md).
