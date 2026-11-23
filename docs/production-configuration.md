# Production configuration and recovery

This guide is the source of truth for operator-held production inputs, their ownership, and recovery. It is for operators preparing a workstation, rebuilding a host, or restoring production; use the [production release cookbook](production-release-cookbook.md) for routine releases and backup-input updates, the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md) for host setup and fresh-cluster restoration, and [production Kubernetes operations](production-kubernetes.md) for lifecycle and recovery details.

**Table of contents**

- [Private workstation directory](#private-workstation-directory)
- [Ownership and lifecycle](#ownership-and-lifecycle)
- [Drive authorization](#drive-authorization)
- [Clean rebuild boundary](#clean-rebuild-boundary)

## Private workstation directory

Keep operator configuration outside the checkout in `~/.config/recipe-db/`. This is the private configuration root for operator-side file references and is authoritative for workstation Pi SSH access, including the dedicated key and verified host key. Restrict it to the operator (`umask 077`, directories mode `0700`, private files mode `0600`). The provisioning launcher bind-mounts this directory at `/home/vscode/.config/recipe-db`; that fixed path is only the container mount, not a workstation or Pi path. Create the private directory before starting the container.

Use paths relative to this root for operator-side references, regardless of the current directory or the YAML file's location:

- Deployment and backup `secrets` entries use paths such as `deployment/auth-accounts.json`.
- In `provisioning/inventory.yml`, set `operator_ssh_private_key` to a path such as `ssh/recipe-db-pi`; Ansible resolves it before SSH uses it.

Relative references must resolve inside the private configuration tree. Existing absolute references remain supported where their exact paths exist in the consuming environment; stale absolute paths are never rebased or searched for automatically. After restoring this configuration to a different home, separately update active private files and encrypted chezmoi sources as needed. The tools do not rewrite operator files.

For an existing inventory, adding `operator_ssh_private_key` alone does not override a legacy `ansible_ssh_private_key_file`. In the existing host's settings, replace the legacy key-file entry with the resolver wiring from [`provisioning/inventory.example.yml`](../provisioning/inventory.example.yml):

```yaml
operator_config_directory: "{{ lookup('ansible.builtin.env', 'HOME') }}/.config/recipe-db"
operator_ssh_private_key: ssh/recipe-db-pi
ansible_ssh_private_key_file: "{{ operator_ssh_private_key | operator_config_path(operator_config_directory) }}"
```

Keep the existing host, user, root UUID, networks, and other operator-specific settings; do not replace the inventory with the example. Adjust the key reference if the key has a different name.

```text
~/.config/recipe-db/
├── deployment/
│   ├── pi-values.yaml
│   ├── auth-accounts.json
│   ├── google-oauth-client-secret
│   ├── oauth2-cookie-secret
│   └── acme-account-email             # required for Pi production HTTPS
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

The backup inputs are operator-prepared. `backup.json` keeps its absolute Pi runtime paths: `/etc/recipe-db/rclone.conf`, `/var/lib/recipe-db-backup`, `/var/lib/recipe-db-backup/work`, and `/usr/local/sbin/recipe-db-backup-capture`. In `backup-values.yaml`, private `secrets` entries should use paths such as `deployment/auth-accounts.json`, naming direct files under the private configuration root. The explicit `backup-configure.yml` playbook resolves and copies the source files from the provisioning controller into root-only `/etc/recipe-db/`, then writes their Pi destinations as `/etc/recipe-db/application-inputs/<filename>`. The Pi never mounts operator home or the provisioning container.

`backup-release-ref` must be the immutable OCI release artifact reference `ghcr.io/dhhyi/recipe-db-releases@sha256:<64 lowercase hexadecimal characters>`; commit IDs and tags are not accepted.

`pi-values.yaml` begins as a private copy of [`deploy/pi.yaml`](../deploy/pi.yaml). It contains the Pi's immutable release/deployment settings and operator-held secret references, preferably relative paths such as `deployment/auth-accounts.json`. Pi deployment requires production HTTPS: `https.hostname` must be the hostname in `origin`, which must use the `https://` scheme. `auth-accounts.json` follows [`graphql/auth-accounts.schema.json`](../graphql/auth-accounts.schema.json). The Google client ID is public configuration in the values file; its client secret and OAuth cookie key are private inputs and remain optional. The ACME account email is required for certificate issuance and renewal.

`inventory.yml` is copied from [`provisioning/inventory.example.yml`](../provisioning/inventory.example.yml). Set its host, `operator_ssh_private_key` reference, measured root UUID, and narrowly scoped administrator/application networks. Keep `known_hosts` limited to the Pi host key verified during bootstrap. The kubeconfig is generated from the live Pi by `access.yml`; it is sensitive, disposable, and can be recreated after provisioning.

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
| `backup.json`, backup values, release reference and referenced application inputs | Pi under `/etc/recipe-db/` and operator recovery directory | Operator-managed recovery inputs; installed explicitly after fresh restore. Routine releases align only the reference after website checks, before the service's post-release backup and acceptance; application backup archives do not include them |
| `/etc/recipe-db/rclone.conf` | Pi-only Google Drive authorization state | Created interactively on the Pi; rclone refreshes its tokens there. Never copy it to/from operator home, chezmoi or application backups. Reauthorize after a fresh host rebuild or lost/broken authorization, not routine updates or application restores. |

Development `.secrets/` files are fixtures for local Compose and tests. They are not production inputs and must not be copied into this directory as production secrets.

The backup service and timer remain stopped and disabled after host provisioning or backup-input installation. Use the [production release cookbook](production-release-cookbook.md) to install inputs, verify a capture, and enable the schedule in the required order.

## Drive authorization

Your home directory stores the Google Drive client credentials, but not the authorization created when you sign in. That authorization stays on the Pi. When rebuilding, use the same Google account and client so you can access your existing backups.

Updates and application restores leave the Pi's Drive authorization unchanged. Rclone automatically renews its access tokens on the Pi; you do not need to sign in again for each backup.

Follow the [Google Drive authorization cookbook](google-drive-authorization.md) to authorize a new Pi or repair lost authorization.

## Clean rebuild boundary

Before erasing or replacing the boot device, independently verify an off-device application backup, its matching immutable release, all required private files, and the ability to authorize Drive with the dedicated client and account. Reimage destroys the Pi's authorization along with the OS and all on-device application data. Follow the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md), authorize Drive on the new Pi, then restore into the new cluster using the recorded release and the [production recovery procedure](production-kubernetes.md).
