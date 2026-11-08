# Production configuration and recovery

This is the source of truth for operator-held production inputs, their ownership, and recovery. Use the [production release cookbook](production-release-cookbook.md) for routine releases and backup-input updates, the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md) for host setup and fresh-cluster restoration, and [production Kubernetes operations](production-kubernetes.md) for lifecycle and recovery details.

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
    └── rclone.conf
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
| SSH private key and verified host key | Operator directory | Required to provision/administer the Pi |
| USB root UUID, Pi hostname, allowed network CIDRs | Measured/operator-specific | Record in inventory; UUID must be measured again after changing the boot device |
| Pi kubeconfig | Generated from the running cluster | Runtime admin credential; do not treat as recoverable from a backup |
| Rendered Kubernetes manifests and checksums | Values + immutable release + deployment renderer | Derived at deployment; do not archive as configuration |
| GraphQL ingress token and Typesense API key | Generated during each production deploy/restore | Ephemeral cluster credentials. The operation creates and uses them, then deletes its private temporary copies. Do not configure, retain, or back them up. Each operation rotates them and rolls dependent workloads. |
| Kubernetes Secrets and application PVC data | Live cluster | Runtime state; restore through the documented backup/recovery workflow |
| ACME account and certificate files | Traefik's retained `recipe-db-acme` PVC | Runtime state, outside application backup capture. Protect separately or reissue after recovery. |
| `backup.json`, backup values, release reference, rclone authorization and referenced application inputs | Pi under `/etc/recipe-db/` and operator recovery directory | Operator-managed recovery inputs; installed explicitly after restore and acceptance; application backup archives do not include them |
| `rclone.conf` | Google Drive authorization state | Not derivable from OAuth client JSON. Preserve it securely or reauthorize interactively; never assume client JSON alone restores Drive access. |

Development `.secrets/` files are fixtures for local Compose and tests. They are not production inputs and must not be copied into this directory as production secrets.

The backup service and timer remain stopped and disabled after host provisioning or backup-input installation. Use the [production release cookbook](production-release-cookbook.md) to install inputs, verify a capture, and enable the schedule in the required order.

## Clean rebuild boundary

Before erasing or replacing the boot device, independently verify an off-device application backup, its matching immutable release, all required private files, and the ability to reauthorize Drive if needed. Reimage destroys both the OS and all on-device application data. Follow the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md), then restore into the new cluster using the recorded release and the [production recovery procedure](production-kubernetes.md).
