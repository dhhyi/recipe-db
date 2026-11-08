# Production Kubernetes operations

This guide is the technical reference for maintainers and operators using Recipe DB's production Kubernetes deployment, backup, and recovery lifecycle. It covers safeguards, commands, and operational constraints rather than the routine release sequence; follow the [production release cookbook](production-release-cookbook.md) to publish and deploy a release, [production configuration and recovery](production-configuration.md) for private operator inputs, and the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md) for host setup and fresh-cluster restoration.

**Table of contents**

- [Prerequisites and boundaries](#prerequisites-and-boundaries)
  - [End-to-end backup and recovery rehearsal](#end-to-end-backup-and-recovery-rehearsal)
  - [Runtime mode](#runtime-mode)
  - [Backup cleanup Job](#backup-cleanup-job)
  - [Backup-participant development checklist](#backup-participant-development-checklist)
  - [Snapshot capture](#snapshot-capture)
  - [Verified remote packaging](#verified-remote-packaging)
  - [Fresh-deployment restore](#fresh-deployment-restore)
- [Operator configuration and secrets](#operator-configuration-and-secrets)
- [Create, render, deploy and inspect](#create-render-deploy-and-inspect)
  - [Certificate-only HTTPS staging on the Pi](#certificate-only-https-staging-on-the-pi)
    - [Explicit anonymous-only public preview](#explicit-anonymous-only-public-preview)
    - [Google sign-in on the existing HTTPS application](#google-sign-in-on-the-existing-https-application)
    - [Controlled test-CA renewal rehearsal](#controlled-test-ca-renewal-rehearsal)
  - [Workstation-only token rehearsal on the Pi](#workstation-only-token-rehearsal-on-the-pi)
  - [Home-LAN HTTP token rehearsal on the Pi](#home-lan-http-token-rehearsal-on-the-pi)
- [What the protocol smoke verifies](#what-the-protocol-smoke-verifies)
- [Storage, Pi adaptation and destructive deletion](#storage-pi-adaptation-and-destructive-deletion)
- [Script regression checks](#script-regression-checks)

## Prerequisites and boundaries

- For initial physical Pi setup, follow the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md). Provisioning and deployment success alone do not establish recovery or production acceptance.
- Run commands from the repository root, with an absolute values-file path. Examples below use `/home/runner/work/recipe-db/recipe-db`; substitute your actual absolute checkout path.
- Local rehearsal requires an x86-64 host, a running Docker daemon with **more than 8 GiB** assigned, available loopback ports 8080 and 6445, and access to GHCR. Leave enough disk space for images and the requested PVCs.
- The tool contract is k3d **5.8.3**, k3s **v1.35.5-k3s1**, kubectl **1.35.5**, ORAS **1.3.6**, and ytt **0.55.4**, plus Bash, jq, yq, curl and GNU `sha256sum` (and OpenSSL for the token-generation example). Repository mise configuration supplies the pinned tools. Docker is a host prerequisite.
- Use a published `ghcr.io/dhhyi/recipe-db-releases@sha256:<64 hex digits>` artifact, not a mutable tag or an individual application image. The driver validates the artifact shape, source, revision and complete image inventory.
- No development Compose generation or development authentication fixture is needed. Do not copy fixture credentials into production.

The default local identity is target `local`, cluster `recipe-db-rehearsal`, context `k3d-recipe-db-rehearsal`, namespace `recipe-db`, origin `http://127.0.0.1:8080`, and a default 600-second wait timeout. Additional isolated local clusters may use names prefixed `recipe-db-rehearsal-` and matching `k3d-<cluster>` contexts, which allows source and fresh-target recovery rehearsals to remain distinct. A different configured `httpPort` is supported only with its matching loopback origin; set `apiPort` independently when its default is occupied. The driver checks managed container labels, node identity, k3s image, loopback-only port bindings and its freshly obtained explicit kubeconfig. It does not switch the user's default context. A URL responding on port 8080 is not sufficient.

Local Traefik uses a LoadBalancer Service so k3s ServiceLB forwards the k3d load balancer's port 80 to Traefik. It allocates no NodePorts or external IPs; the managed k3d host bindings remain loopback-only. Pi loopback ingress remains ClusterIP, while explicit Pi private-LAN ingress uses a LoadBalancer. Deploy and restore verify the live Service matches the selected target before reporting success or reopening ingress.

### End-to-end backup and recovery rehearsal

The end-to-end runner creates two uniquely named, loopback-only k3d clusters, generates synthetic application credentials and records, captures the source PVCs, packages the snapshot, uploads it through a filesystem-backed fake `rclone` remote, and restores the verified package into a separately fresh target. It checks populated-target refusal without changing a marker, validates recipe/rating/inspiration/tag and image-pair reads, confirms a post-restore change reaches fresh search consumers, and cleans up its own records through the backup lifecycle. It uses owner-token authentication with Google sign-in disabled, matching `deploy/local.yaml` without OAuth2 Proxy or Redis. It never uses Google OAuth or Drive credentials, accesses the Pi, or contacts a real remote.

Use an immutable release artifact whose revision matches the checkout, after ensuring the host has the production-k3d prerequisites above:

```sh
mkdir -p "$PWD/.backups"
RESULT="$PWD/.backups/backup-recovery-$(date -u +%Y%m%dT%H%M%SZ)"
RELEASE='ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-artifact-digest>'
mise run production-backup-recovery-k3d "$RELEASE" "$RESULT"
```

The runner preserves both clusters and private diagnostics on success and failure; generated credentials and values are under `$RESULT/secrets`. Inspect the result JSON and logs before removing the result directory. To remove either cluster, use its saved values file with `production-k3d delete` and the exact `DELETE-<cluster>-AND-ALL-DATA` confirmation. Read-only checks wait through bounded route convergence; mutations are never automatically replayed. Restore waits for verified reads and a ready GraphQL route before its propagation probe, retaining blocked ingress and its recovery Lease if readiness fails. The other injected lifecycle, packaging, upload, and restore failure contracts are exercised by the `deploy` script regression group.

### Runtime mode

Production workloads set `MODE=production`. An absent `MODE` defaults to production; empty or unsupported values fail startup. `testing` enables isolated test resets. `backup` keeps production ingress protections, blocks application requests and writes, and enables private maintenance APIs.

### Backup cleanup Job

Recipe deletion leaves dependent data in place so the synchronous request does not cascade across services. The in-cluster cleanup Job later removes orphaned dependent data and, when configured, compacts historical images. It is suspended by default, uses the same immutable release as the workloads, and has no service-account token.

Each API/backend project declares a `backupRole` in `.project.yaml`; the schema requires it for those categories:

| Role | Meaning |
| --- | --- |
| `authoritative-read-only` | Provides the recipe ID inventory; its records are never purged. |
| `cleanup-participant` | Reports recipe references and purges its data for IDs absent from the authoritative inventory. |
| `derived-stateless` | Holds rebuildable derived state and is not included in cleanup. |
| `excluded-external-cache` | Is excluded because its cache keys or data are external to recipe ownership. |

`backupCompact: true` opts a cleanup participant into image compaction for surviving recipe IDs; it defaults to `false` and is currently used by `images`.

The maintenance API is private and available only in backup mode:

| Service | Route | Purpose |
| --- | --- | --- |
| recipes, images, ratings, inspirations, tags | `GET /maintenance/status` | Verify API version, service identity, and backup mode |
| recipes, images, ratings, inspirations, tags | `GET /maintenance/recipe-ids` | Enumerate authoritative or referenced recipe IDs |
| images, ratings, inspirations, tags | `POST /maintenance/recipes/purge` | Idempotently remove data owned by one absent recipe |
| images | `POST /maintenance/images/compact` | Keep only the manifest-selected current image and thumbnail |

Body-bearing routes require `application/json` and use `{"recipeId":"opaque-id"}`. Purges and compaction return `204`; ID lists are complete, distinct, and ordered. In production/testing these routes return `404` without touching stored data. Unsafe image state fails cleanup rather than guessing which outputs are current.

### Backup-participant development checklist

- Declare `backupRole` and, for captured storage, the complete `backupData` layout; keep caches and secrets outside authoritative data.
- Test exact maintenance routes through the real router, including supported trailing slashes and opaque IDs. Inventories must be complete, distinct and ordered; purge/compaction must tolerate retries.
- Keep maintenance private and backup-only, test resets testing-only, and denied operations non-mutating. Health probes remain available in every mode.
- Quiesce background writers and flush durable state before clean exit. Test every built container as PID 1 with SIGTERM and its image `STOPSIGNAL`, including wrappers and sidecars.
- Verify authoritative data survives same-release restart/restore. Derived services must rebuild from empty storage and fresh consumers, remain not-ready after failed rebuilding, and process subsequent changes.
- Keep credentials and application records out of diagnostic logs; store data-bearing manifests privately.
- Verify reads through actual routes, not rollout status alone. Bound readiness/convergence waits; never blindly replay mutations or reopen clients after failed recovery.

### Snapshot capture

The `backup`, `backup-enter`, `backup-exit`, `restore`, `deploy`, and `storage-reattach` operations coordinate through the same `recipe-db-deploy` Lease in `kube-system`, outside the replaceable application namespace. They do not expire or automatically steal a Lease. Backup validates the explicit target/context, immutable release digest/revision, actual project container images, deployed runtime Secret, selected PVC identities, ownership and destination capacity. Backup and recovery require the release commit locally and unchanged metadata/template inputs relative to it; untracked inputs are refused, while unrelated checkout changes are allowed. This binds the authoritative inventory and cleanup definition to the release without fetching or executing another checkout. Preflight requires selected PVC requests plus 64 MiB staging headroom; because local-path requests do not enforce a quota, capture also measures each stopped PVC's exact tar byte count before copying and requires actual free space plus the same headroom. This includes sparse-file expansion and previously copied archives. It does not read the configured application secret files. The snapshot validator requires Python 3 with its standard library.

Run only during an approved maintenance window, from a trusted workstation with the explicit target values file and a private destination filesystem. This operation changes runtime modes, briefly stops backend workloads and transfers application data; do not point it at a live Pi or production cluster during development or tests.

```sh
VALUES="$PWD/.secrets/local-values.yaml"
RELEASE='ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-artifact-digest>'
SNAPSHOT="$PWD/.backups/recipe-db-$(date -u +%Y%m%dT%H%M%SZ)"
umask 077
mkdir -p "$PWD/.backups"
mise run production-k3d backup "$VALUES" "$RELEASE" "$SNAPSHOT"
```

The operation stops and drains the normal GraphQL Pods first, then raises the `MODE=backup` barrier before touching data backends. GraphQL drains active connections for at most 20 seconds; backend and API Pods have a 120-second termination grace period as an upper bound; every service container must still exit cleanly on SIGTERM (as PID 1 it needs an explicit handler or `trap`). Image `STOPSIGNAL` overrides also apply: the nginx-based search readiness sidecar handles both TERM and QUIT. A resource-versioned Pod watch must observe normal termination; a missing termination record, failed drain, OOM or SIGKILL prohibits capture. It stops normal backend/projection workloads before bringing up any authoritative backup-mode backend. The rendered `backup-cleanup` Job runs once: its existing worker retries each retryable operation once plus two retries, without repeating permanent failures or duplicating cleanup logic. Completed purges are not rolled back on failure.

After cleanup, all remaining data writers terminate before role-selected PVCs are exported with temporary read-only copy Pods. `.project.yaml` supplies both `backupRole` and `backupData` (SQLite, JSON or image-manifest layout). Capture rejects missing databases, undeclared files/directories, links, unsafe archive paths, and missing, corrupted or unselected image pairs. Recipes, ratings, inspirations, tags inventory/assignments, SQLite recovery sidecars and current image/thumbnail pairs are included. Derived/external caches, logs, container images, OS/k3s state and secrets are excluded. An empty image dataset still requires both owned storage directories. No archive is published if cleanup, termination or copy validation fails.

A complete snapshot is identified only by `manifest.json` (`format: recipe-db-pvc-snapshot`, `formatVersion: 1`). It records `backupId`, `startedAt`, `capturedAt`, `completedAt`, `source` (`target`, `cluster`, `context`, `namespace`, immutable `artifact`, `revision`) and `inventory`. Each inventory entry contains `service`, `role`, `pvc`, `archive`, `sizeBytes`, `fileCount`, `sha256` and `files`; each regular-file entry has its archive-relative `path`, `sizeBytes` and `sha256`. Archives are `<service>.tar`, with no secrets or outer packaging. Present SQLite `-wal`, `-shm` and `-journal` sidecars belong to their database. Downstream packaging must require the manifest, verify archive and file hashes, reject unsafe extraction paths, and preserve this versioned inventory. Staging directories are created privately, never overwritten or recursively removed by the lifecycle.

### Verified remote packaging

The publisher consumes only that complete snapshot directory; it does not capture PVCs or infer service layouts. It rechecks the lifecycle manifest, every archive SHA-256, every regular-file size/hash, path safety and snapshot completeness before packaging. The uploaded `<deployment>-<capturedAt>-<backupId>.tar.gz` is an ordinary gzip-compressed tar containing `manifest.json` and the service `.tar` files in sorted order. Outer tar metadata is normalized (mtime, owner, group and mode) and the gzip timestamp is zero. Its sibling `.manifest.json` uses `format: recipe-db-backup`, `formatVersion: 1`, and records deployment/backup IDs, capture order, the original release identity and snapshot manifest, a content fingerprint, and the archive name, byte size and SHA-256. Restore tooling must verify this package manifest, archive hash and inner snapshot contract before extracting or restoring; only a matching complete archive/manifest pair is a restore point.

The change fingerprint includes snapshot format/version, immutable release artifact and revision, each service/role/PVC/archive identity, and sorted file paths, sizes and hashes. It deliberately excludes backup IDs and capture timestamps. A release-only change therefore publishes a new point, while repeated identical data can be skipped only after reading back and hashing both files from the prior verified remote point. A missing or corrupt remote baseline causes a new upload rather than a false unchanged result. Archive then manifest are copied as individual files with `rclone copyto` (never `sync`); the manifest is the final completion marker. Both files are read back and SHA-256 checked before the local baseline advances. Temporary packaging space is bounded by the configured `maxStagingBytes` (8 GiB by default); there is no local upload queue. A failed transfer preserves the prior baseline. Retention runs only after a verified upload, keeps the newest 30 complete points by `capturedAt`, and deletes only pairs whose deployment ID and manifest/archive identities verify. Pruning errors leave the verified new baseline intact and are reported separately.

The provisioning playbook installs rclone 1.75.2 from its versioned ARM64 package with a pinned SHA-256 and copies the root-only local kubeconfig to `/etc/recipe-db/backup-kubeconfig.yaml` under context `recipe-db-pi`. It installs a `recipe-db-backup.service` and local-time `02:15` timer with up to 15 minutes of jitter. `Persistent=false` means missed occurrences are skipped, not replayed as backlog snapshots. A service lock prevents overlapping runs; the two-hour service timeout bounds capture and publication. Base provisioning leaves the timer stopped and disabled. The timer's presence or enabled state is not backup health.

Prepare `backup.json` under `~/.config/recipe-db/backup/` and install it with `backup-configure.yml`; the playbook places it at `/etc/recipe-db/backup.json` mode `0600`. It must contain `deploymentId`, `remote` (for example `gdrive:recipe-db-backups`), `rcloneConfig` (`/etc/recipe-db/rclone.conf`), `stateDirectory` (`/var/lib/recipe-db-backup`), `stagingDirectory` (`/var/lib/recipe-db-backup/work`), `captureCommand` (`/usr/local/sbin/recipe-db-backup-capture`), `captureTimeoutSeconds` and optionally `maxStagingBytes`. The capture command accepts exactly one argument: a new absolute destination directory. It invokes the lifecycle child's `production-k3d backup` operation with the same explicit Pi values, context `recipe-db-pi`, and deployed immutable release, then returns success only for a complete snapshot at that directory. Keep that checkout at `/opt/recipe-db`, at the matching release revision, and make its pinned Mise tools and private target configuration available to root's systemd process. The service supplies `KUBECONFIG=/etc/recipe-db/backup-kubeconfig.yaml`. Do not copy kubeconfigs, release credentials or deployment secrets into the snapshot. The publisher suppresses subprocess output and emits only stable status codes; it never prints rclone configuration, remote content or capture-command output.

Canonical Ansible provisioning installs `/usr/local/sbin/recipe-db-backup-capture` and its isolated checksum-pinned Mise/capture tools without repository development hooks. Set `backup_capture_revision` in the private inventory to the deployed full commit to manage `/opt/recipe-db`; an empty value does not select or update a checkout. The command reads operator-installed `/etc/recipe-db/backup-values.yaml` and `/etc/recipe-db/backup-release-ref`, then invokes the guarded lifecycle. Use this managed command as `captureCommand`, rather than manually installing host tooling. The selected visible My Drive destination is `gdrive:RecipeDB Backups`. See [production configuration and recovery](production-configuration.md) for private file ownership and recovery. After restore and acceptance, run `backup-configure.yml` to install the operator-prepared recovery inputs and referenced application secrets; it records a private configuration-generation timestamp only after successful installation. Start and verify one explicit capture after that timestamp; only then run `backup-enable.yml`, which requires a verified status with a later `lastCheck` before enabling the timer.

Create and authorize `/etc/recipe-db/rclone.conf` interactively on the Pi with the dedicated operator-owned Google account; keep it root-owned, mode `0600`. Follow the [Drive authorization cookbook](google-drive-authorization.md), using the Desktop OAuth client stored in operator home and a private SSH browser tunnel. The authorized config stays on the Pi, where rclone refreshes its tokens. `backup-configure.yml` checks its permissions but never copies, replaces or retrieves it. Routine updates and application restores keep this authorization; a fresh host rebuild or lost/broken authorization requires interactive login. Never put OAuth tokens in operator home, chezmoi, backup JSON, command arguments, source control, application backups or service logs. Retain the protected account-recovery method separately from this device. Lost authorization does not invalidate already verified Drive points.

The design service hosts the backup OAuth homepage at `/design/backup/` and its privacy policy at `/design/backup/privacy.html` on the existing HTTPS origin. These are public, static informational pages, not backup, authorization or maintenance endpoints. Use their full HTTPS URLs in the dedicated desktop OAuth client's Google Branding settings, supply the operator's real support email, and complete any Google-required domain verification. Request only `https://www.googleapis.com/auth/drive.file` and create the backup folders through that client; files created separately in Drive are not automatically accessible under this scope. Review the published policy against the actual setup before authorizing access. Publishing the OAuth app does not make its Drive folders public or prove backup acceptance.

The publisher writes `/var/lib/recipe-db-backup/status.json` separately from `baseline.json`. `lastCheck` advances for each run; `lastUpload` advances only on a verified changed-data upload. Status distinguishes `verified-upload`, `verified-unchanged`, `capture-failure`, `upload-failure`, `restart-failure`, `interrupted`, `retention-failure` and `overdue`. Query with `sudo /usr/local/sbin/recipe-db-backup-upload status --config /etc/recipe-db/backup.json`; this reports the last check/upload independently and marks checks older than 26 hours overdue. A lifecycle recovery-required state is preserved under the private state directory and blocks another scheduled attempt until the lifecycle recovery procedure succeeds. A verified upload followed by pruning failure remains a verified baseline, with `retention-failure` visible as the latest status.

The host needs enough free space for both the lifecycle snapshot and package staging; the capture limit is at most half of `maxStagingBytes`, reserving the remainder for the package, and capture checks the measured archive size before writing each PVC. Packaging also preflights its input/output bound and requires twice the input size plus 1% and 64 MiB free space. Confirm disk capacity and measure real data growth before relying on the default 8 GiB cap. This does not protect against disk/device failure, malicious account access, Google Drive account deletion, or restore mistakes. No real Drive authorization/readback or physical Pi installation is claimed by mocked contract tests; operator acceptance remains separate.

Recovery stops any owned cleanup Job and waits for its worker Pods to disappear before restarting production backends. It restores prior production workload counts, restarts search for a complete baseline and browse for an empty HTML cache, and verifies backend counts, modes, readiness and container images before restoring GraphQL last. Search uses trusted ingress on private port 3000; during rebuilding only its internal GraphQL service is redirected to a backup-only, ingress-token-protected, query-only listener. Public GraphQL/MCP operations remain blocked; maintenance/reset APIs are never routed through this listener. The internal route returns to its normal port before GraphQL reopens. A failed recovery retains the barrier, Lease and durable state, and reports the primary and recovery failures.

For explicit maintainer operations, pass the same release and a new private state directory:

```sh
mise run production-k3d backup-enter "$VALUES" "$RELEASE" "$STATE_DIRECTORY"
mise run production-k3d backup-status "$VALUES" "$STATE_DIRECTORY"
# Copy the exact holder reported by status; first verify no operator/process is still active.
mise run production-k3d backup-exit "$VALUES" "$STATE_DIRECTORY" "$HOLDER" "EXIT-$HOLDER"
```

`backup-enter` performs the barrier, backend transition and cleanup, but no capture; successful entry deliberately keeps the Lease. `backup-exit` requires the original state directory and unchanged explicit values, exact holder and immutable release, and repeats safe recovery after an interrupted process/host. `backup-state.json` persists prior counts, selected PVC layouts, target/release and phase before workload mutation; shell traps are not its durability mechanism. Preserve that directory when recovery fails. `lock-status` exposes the surviving holder/phase; `lock-recover` requires `RECOVER-<holder>` for abandoned non-backup operations. It also permits a backup Lease still in `acquired` preflight, before any workload mutation, including an interruption before the state directory exists. The phase advances atomically before the first workload change; all later backup phases require `backup-exit`. Always verify the original process/operator has stopped before recovery; UID/resource-version deletion preconditions refuse a Lease that advances concurrently.

Pi deploy/backup/recovery requires `piStorage.node`, the verified `piStorage.expectedRootUuid`, and `piStorage.dataRoot` from the provisioning contract. Under the shared Lease, a temporary read-only host-inspection Pod runs the installed storage guard and verifies one ready ARM64 k3s node, USB/ext4 root identity, runtime directories and each existing PV path's filesystem. New claims use the owned `recipe-db-retained` StorageClass, with `Retain` set at creation and provisioning pinned to the configured node and data root. Stock `local-path` remains unchanged because StorageClass reclaim policies are immutable. Existing verified `local-path` claims preserve their immutable class during redeployment and reattachment; only their PV reclaim policy is upgraded to `Retain`. Namespace/application deletion therefore does not trigger deletion of those data directories. Missing, foreign, ambiguous or redirected storage is refused. Replace the checked-in UUID placeholder only with the verified operator value; no UUID is inferred.

After intentional namespace/PVC deletion, stop any previous operator, preserve the retained PVs and directories, and explicitly reserve compatible Released PVs before redeploying:

```sh
mise run production-k3d storage-reattach "$VALUES" "REATTACH-recipe-db-pi"
mise run production-k3d deploy "$VALUES" "$RELEASE"
```

Reattachment checks the old namespace/claim, requested capacity, node and guarded path, and changes the claim reference atomically without deleting PVs, PVCs or directories. Ordinary redeployments keep bound claims. Host reprovisioning does not format/remove application storage. Local k3d's explicitly confirmed whole-cluster deletion still destroys rehearsal data.

### Fresh-deployment restore

Restore is recovery at the backup's recorded immutable application release, not an upgrade or in-place repair. Use a newly provisioned, explicitly identified local k3d or Pi k3s target. Never deploy the normal application first: initialization populates databases and derived volumes, making that target unsuitable for restore. Existing or partially restored data must not be wiped, merged or overwritten to make a target pass.

Select a complete package and its sibling manifest from a verified restore point. For remote backups, use the Pi's private rclone authorization to download both files, then transfer only the backup files to a private local directory before invoking restore; a failed download is not a restore candidate. Keep backup contents, credentials and private command output out of CI artifacts/logs. Listing or byte size alone does not verify a downloaded backup.

If the original Pi is unavailable and no verified package was downloaded beforehand, provision the replacement Pi and [authorize Drive interactively there](google-drive-authorization.md#1-authorize-on-a-new-pi) before retrieving the backup. Recovery no longer depends on an authorized rclone config in the workstation or encrypted dotfiles.

Over verified private SSH, use `sudo rclone` on the Pi with `--config /etc/recipe-db/rclone.conf`. The remote directory is `remote` from the home directory's `backup/backup.json` followed by `/deploymentId`; this home file is still available when the replacement Pi has not yet received backup settings. Use only read-only listing and remote-to-local `rclone copyto` operations to retrieve the matching archive and manifest into a new root-only directory on the Pi. Give the authorized SSH operator ownership of only that download directory and those two files, retaining directory mode `0700` and file mode `0600`, then use `scp` to transfer them to a private workstation directory. Verify command success and package hashes before using them. Never transfer `rclone.conf`. Never run the backup publisher, `sync`, upload, delete or prune for recovery. Rclone may refresh authorization on the Pi during reads. Do not print private configuration, backup contents or remote listings in shared logs.

```sh
umask 077
VALUES="$PWD/.secrets/fresh-target-values.yaml"
PACKAGE_MANIFEST="$PWD/.backups/<complete-backup>.manifest.json"
PACKAGE_ARCHIVE="$PWD/.backups/<complete-backup>.tar.gz"
BACKUP_ID='<exact-backupId-from-manifest>'
STATE_DIRECTORY="$PWD/.backups/restore-<new-operation>"
mise run production-k3d restore "$VALUES" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" \
  "$BACKUP_ID" "$STATE_DIRECTORY" "RESTORE-$BACKUP_ID"
```

All file arguments are absolute. The values file explicitly selects target, context, namespace, storage and workstation-held secret inputs; confirmation binds the operation to the selected backup identity. Preserve the original package/manifest pair. Restore validates the supported package/snapshot formats, release identity, archive and file sizes/SHA-256 hashes, complete metadata-derived authoritative inventory and current image/thumbnail pairs. SQLite integrity checks run against private read-only copies with their recovery sidecars before target mutation. WAL validation conservatively rejects inconsistent salts/checksums, including stale previous-generation trailing frames; rejection is not permission to strip sidecars or repair a backup implicitly. Links, special files, duplicate entries and unsafe paths are refused. Validation stages only classified regular files privately, never extracts arbitrary paths into the target.

The recorded release artifact and every application image must remain available. The corresponding release commit and unchanged render inputs must be present locally, and all configured secret inputs must be supplied independently; secrets are not recovered from backup. The accounts file must include an explicit owner bearer token for the private create/update/delete propagation probe. The probe uses only its own new recipe, verifies search and browse changes, and removes that recipe before completion; an interrupted probe's identity is retained in recovery state. No mutable image tag, replacement release, application build or implicit upgrade substitutes for a missing prerequisite. Pi restore retains the provisioning/storage-identity safeguards above; this command does not provision or reimage a device.

After rendering the recorded release, restore applies the current target's Traefik Service exposure policy without changing application images or historical render inputs. For local and Pi private-LAN LoadBalancers it disables NodePort allocation and removes any already allocated NodePorts before importing data; Pi loopback remains ClusterIP. It checks the resulting Service again before reopening ingress.

The shared cluster-scoped Lease excludes deployment and capture. Fresh-target inspection refuses populated authoritative, derived and external-cache storage. Application writers remain stopped during data import. Public GraphQL remains blocked while the private trusted-ingress query route permits full search rebuilding. Browse's recorded image hardcodes `http://traefik/graphql`; restore must route that internal service alias to the private entrypoint without opening the public Traefik service, rather than relying on a `GRAPHQL_URL` environment override. NATS/consumers, Typesense, search/checkpoint, browse and external caches start fresh; upstream websites are not recovery prerequisites. Completion requires data verification, search readiness, representative reads and change propagation before application access reopens.

Cache expiry alone is not propagation evidence: browse's cache expires after one minute. The verification must establish that the fresh search and browse consumers acknowledged the probe's changes before reopening access.

A nonzero exit is never a partial success. After target mutation, preserve the private restore state directory and the Lease and leave access blocked. Inspect the saved phase, explicit target/context and `lock-status` before any operator action. Do not use `backup-exit`, ordinary deployment, a forced lock deletion or a second restore to open or overwrite a partial target. Stop any surviving operator process and isolate the failed target: stop all Deployments and restartable controllers, suspend Jobs/CronJobs, remove only stopped worker/helper Pods, and retain the public routing barrier. `restore-abandon` releases the exact retained Lease only after checking the saved target/configuration, workload isolation and routing barrier; it does not delete data or reopen access:

```sh
mise run production-k3d restore-abandon "$VALUES" "$STATE_DIRECTORY" \
  "$HOLDER" "ABANDON-$HOLDER-AFTER-ISOLATION"
```

Retain the failed target for investigation and select another genuinely fresh target for a new restore; abandonment does not make partial volumes reusable. Any destructive disposal requires separate explicit operator approval. Automated failure tests are not evidence of a live Pi recovery. The integrated disposable-k3d rehearsal belongs to #108, and operator-approved Drive/Pi acceptance to #107.

## Operator configuration and secrets

The [configuration and recovery guide](production-configuration.md) is authoritative for the private directory, operator-managed files, generated state, ephemeral credentials, and recovery boundaries. Production values reference private inputs by absolute path. Deploy and restore generate fresh GraphQL ingress and Typesense credentials, create the cluster Secrets, and remove temporary copies. They are never supplied by the operator or stored in the repository. Repository `.secrets/` files are for development and disposable local rehearsals, not production inputs.

Google OAuth uses a public client ID and operator-held client/cookie files. Keep the provider redirect URI aligned with the configured HTTPS origin. Do not disable authorization or weaken the account policy to make a rehearsal pass.

The local protocol smoke requires a private owner bearer-token file whose token is explicitly present in the configured account policy. It does not mint credentials or create accounts. Successful create/update/image/delete operations verify deployed authorization; a local file match alone is not evidence that the policy is active. Keep smoke credentials in the private operator directory and revoke temporary principals after use.

## Create, render, deploy and inspect

### Certificate-only HTTPS staging on the Pi

After rehearsal credential replacement, an operator may add this optional block to the private Pi values file. Keep `runtime.ingressMode: private-lan` and the existing private LAN `origin`; Google OAuth settings remain absent:

```yaml
httpsStaging:
  hostname: your-hostname.example.org
  acmeEnvironment: staging
```

Also add `secrets.acme-account-email` pointing to a private mode-0600 file containing a dedicated contact mailbox. HTTPS deployment requires and validates it. The address is stored only in a private `recipe-db-acme-contact` Secret in `kube-system`; manifests reference its key, not the address. Kubernetes expands that Secret-backed environment variable into Traefik's email argument. Contact changes roll Traefik consistently without publishing the value. This avoids Traefik 3.7.16's repeated empty-email account recreation on renewal/restart. An already stored email-less account is replaced on its next ACME interaction before the contact-bearing account is persisted; adding the setting does not retroactively rewrite live account files or prove scheduled production renewal. Keep the contact file in private recovery sources; never put its contents in issue evidence or unrestricted logs.

This enables a separate Traefik HTTP entrypoint on Pi TCP 8081 and HTTPS on TCP 8443. Existing private LAN application HTTP on TCP 80 and internal GraphQL ingress remain unchanged. The HTTPS entrypoint serves only a fixed staging-check response at `/` for the configured hostname; application, OAuth, MCP, static, image, and infrastructure paths have no staging router and return 404.

Only after inspecting the deployed listeners, the operator forwards router TCP 80 to Pi TCP 8081 and router TCP 443 to Pi TCP 8443. The private host firewall also requires explicitly approved exceptions for these two destination ports and their Kubernetes DNAT paths. Do not forward to the application's Pi TCP 80, open SSH/Kubernetes/backend ports, flush nftables, or publish an unverified IPv6 record. This deployment command does not change the router or host firewall.

Traefik answers Let's Encrypt HTTP-01 challenges on the staging HTTP entrypoint; ordinary requests redirect to external HTTPS port 443. No Dynu API credential is needed. Begin with the ACME staging environment to test validation without production rate limits. Its test certificates are **not browser-trusted**: successful test issuance is not trusted-HTTPS acceptance. Change `acmeEnvironment` to `production` and redeploy to obtain the trusted certificate. Use the hostname, not the numeric IP, and do not bypass certificate validation for production acceptance.

ACME account keys and certificates persist in the private `recipe-db-acme` PVC in `kube-system`, using the owned retained Pi StorageClass. Traefik runs as UID/GID 65532, uses a single Recreate deployment, and initializes each environment's ACME file with mode 0600. Test and production use separate files; ordinary redeployments must not delete the claim. The claim is outside application backup capture: protect it separately as private recovery material or explicitly reissue after recovery, accounting for CA rate limits. Never publish ACME files, private keys, raw Secret data, or unrestricted proxy logs.

Traefik automatically renews certificates while DNS and inbound challenge access remain usable. Before acceptance, verify the trusted hostname/chain, root response, 404s for `/graphql`, `/mcp`, `/oauth2/callback`, `/design`, `/images`, and `/api`, HTTP redirects, private LAN browsing, retained state across redeployment, and actual renewal evidence. Inspect certificate expiry and ACME failure diagnostics locally without publishing credentials; successful initial issuance alone does not prove renewal. Certificate hostnames are public in certificate transparency logs.

To disable external staging, remove the two router forwards and their host firewall exceptions. Removing `httpsStaging` and redeploying also removes the staging listeners/routes; it deliberately retains the ACME PVC and the unexposed staging workload. This milestone is not Google-provider verification or full authenticated go-live. Those remain gated by the deployment/authentication acceptance issues.

#### Explicit anonymous-only public preview

The public preview under [#44](https://github.com/dhhyi/recipe-db/issues/44) is separate from full authenticated launch [#123](https://github.com/dhhyi/recipe-db/issues/123). After private checks and explicit operator approval, set `httpsStaging.exposeApplication: true` with `acmeEnvironment: production`; leave the optional Google OAuth configuration absent for an anonymous-only preview. Omission or `false` of the exposure flag keeps certificate-only staging; application exposure still requires the production CA for trusted HTTPS. This setting controls routing only: it neither grants permissions nor restricts roles or token definitions. GraphQL validates and enforces the accounts policy.

For the approved anonymous-only preview, keep `anonymous.role: anonymous`, `tokens: []` and `googleAccounts: {}` in the accounts policy. Removing accepted tokens also revokes their private-LAN use. Deployment no longer enforces this preview policy: verify the effective capabilities and denied writes before public exposure, and obtain separate launch approval before granting privileges. Deploy and restore generate the internal GraphQL ingress and Typesense credentials; these authenticate services, not public users.

Read-only authorization comes entirely from the accounts policy, not a separate runtime mode. Remove the obsolete `runtime.readOnly` key and replace `httpsStaging.readOnlyPreview` with `httpsStaging.exposeApplication` in existing values; old keys are rejected rather than silently ignored. Removing `httpsStaging` and redeploying still accepts the anonymous-only policy, closes public listeners, and preserves private read-only browsing without reintroducing owner tokens.

The dedicated HTTPS listener reuses the existing browse, design, public-image, GraphQL, recipe-editor, image-editor and MCP routing rules and middleware, adding the configured hostname and TLS. Editors can load but cannot save; MCP can initialize and read but its mutation tools are denied by GraphQL's existing anonymous capability guards, as are private ratings/comments. Public GraphQL still strips untrusted identity headers before injecting the private ingress token. The frontend's existing compression/maintenance handling and internal GraphQL routes remain unchanged. HTTP method or UI availability is not the write boundary: authorization is.

Production mounts the reviewed `design/nginx.conf` as a ConfigMap. Its CSS/JS aliases and directory redirects are origin-relative, preserving HTTPS when nginx is behind Traefik's TLS termination and HTTP on the private origin. Check alias `Location` headers and actual browser asset loading: following an accidental HTTP redirect in a command-line client is not proof that an HTTPS browser will load the asset.

OAuth, backend REST, maintenance/reset and dashboard services remain excluded from public routing. Browse retains its existing fallback route; unknown URLs do not acquire a backend/admin router. Browser and MCP URLs use the public HTTPS hostname; private application HTTP remains for anonymous LAN browsing, not privileged token rehearsal. Verify forbidden GraphQL/MCP/editor writes and excluded interfaces leave data unchanged before enabling router forwarding. This preview is public exposure, **not** completion of Google verification, application backup/recovery, or the full launch checklist.

#### Google sign-in on the existing HTTPS application

For operator-approved Google verification under [#68 — Set up and verify real Google authentication before public go-live](https://github.com/dhhyi/recipe-db/issues/68), reuse the existing HTTPS application exposure and trusted certificate. No separate outer login gate is required: anonymous reads remain public and GraphQL alone enforces member/owner permissions.

With Google settings absent, anonymous reads and configured bearer tokens continue to work; the sign-in link is omitted. To enable Google login, add the complete optional configuration to the private Pi values:

```yaml
origin: https://your-hostname.example.org
runtime:
  ingressMode: private-lan
  googleOAuthClientId: YOUR-CLIENT-ID.apps.googleusercontent.com
  trustedIssuer: https://accounts.google.com
infrastructure:
  oauth2Proxy: quay.io/oauth2-proxy/oauth2-proxy:<reviewed-tag>@sha256:<reviewed-digest>
  redis: redis:<reviewed-tag>@sha256:<reviewed-digest>
volumes:
  redis: 256Mi
secrets:
  google-oauth-client-secret: /absolute/private/path/google-oauth-client-secret
  oauth2-cookie-secret: /absolute/private/path/oauth2-cookie-secret
httpsStaging:
  hostname: your-hostname.example.org
  acmeEnvironment: production
  exposeApplication: true
```

The origin must exactly match `https://` plus the configured hostname, without a port suffix. A Pi deployment with Google OAuth requires application exposure and the production CA; mismatched origins, test-CA certificates and certificate-only combinations are rejected before cluster access. Register this origin's `/oauth2/callback` in the Google web client. Use a fresh cookie key and the actual Google client secret. The client ID and both secret paths must be present together; partial or invalid configuration fails explicitly. Never put the downloaded credential JSON, secret values or session cookies into reports or Git.

This deploys OAuth2 Proxy alongside Redis and retains the existing ACME claim and listener layout. HTTPS reuses the existing optional-authentication GraphQL routers, preserving bearer-first priority without cookie fallback. It also exposes only `/oauth2/start`, `/oauth2/callback`, `/oauth2/sign_in` and `/oauth2/sign_out`, not `/oauth2/auth` or other proxy endpoints. Untrusted identity headers are stripped before authentication and trusted ingress injection. Backend REST, maintenance/reset and administrative routes remain private, with no new public ports or NodePorts. To disable Google login, remove the client ID, both OAuth secret paths, optional OAuth/Redis images, and `volumes.redis`, then redeploy; the deployment removes its owned OAuth workloads and routes without changing application exposure or GraphQL authorization.

Keep `anonymous.role: anonymous` and existing accounts intact. Google registration does not grant application privileges: configure only operator-approved normalized emails as `member` or `owner` in the private `googleAccounts` map. An empty map grants no Google account elevated access. Do not assign roles or enable bearer credentials merely to make a deployment check pass.

After deployment, verify real-browser login, callback and logout on the HTTPS hostname, Secure/HttpOnly/SameSite=Lax cookies, member/owner boundaries, denied accounts, bearer precedence and refresh/revocation behavior. Private LAN HTTP remains available but does not receive Secure login cookies; use HTTPS for authenticated browser verification. Automated rendering/routing tests are not evidence of real Google consent or refresh. To stop external access immediately, disable the existing router forwards and their firewall exceptions; this does not delete application data, Redis or ACME state.

#### Controlled test-CA renewal rehearsal

Set `httpsStaging.renewalRehearsal: true` only with `acmeEnvironment: staging` and certificate-only routing. It enlarges Traefik's configured certificate duration to 8760 hours solely to move an existing test certificate into the renewal window. Traefik checks that window at startup and uses its normal renewal path; no clock change, live-file editing or certificate deletion is needed. The flag is rejected for production. Record the existing test certificate fingerprint/serial, observe renewal diagnostics and the replacement certificate, and verify account continuity and unchanged production ACME state. Initial issuance of an absent test certificate is not renewal evidence.

Exercise failure visibility while challenge access is unavailable, then restore operator-approved reachability and verify renewal. Remove the rehearsal flag immediately afterward and restore `acmeEnvironment: production`. An ordinary production deployment uses Traefik's default duration/renewal schedule. Never leave the enlarged window enabled: repeated starts could unnecessarily renew test certificates. A controlled test-CA rehearsal does not claim an observed scheduled production renewal; retain that explicit limitation and inspect the trusted production certificate's expiry and normal ACME diagnostics.

Run `bash .scripts/check-public-https.sh your-hostname.example.org` from the trusted operator workstation to check public reachability, root HTTP 200, normal CA/hostname trust and at least 14 days of remaining validity. Success emits JSON; any failed check exits nonzero with an explicit diagnostic. An optional second whole-day argument changes the required margin (1–3650 days). Run it regularly, especially after DNS/router/firewall changes; this is an operator check, not an installed notification service. A failure needs investigation even if the browser still accepts a cached certificate.

Inspect Traefik's local ACME diagnostics for `Renewing ACME certificate` and `Error renewing ACME certificate` without publishing raw logs. Failed renewal can leave the currently valid certificate served, so HTTP 200 alone is not renewal success. Restore DNS/challenge reachability and retry under controlled operator supervision; do not repeatedly restart against the production CA or delete account/certificate state to bypass a failure.

For private ACME recovery, copy both environment files from the owned PVC into a mode-0700 operator directory with mode-0600 files while no renewal is writing them. Validate JSON and certificate/private-key correspondence locally, confirm repeated source copies agree, and protect this material separately from application backups. Before a real restore, stop the single Traefik writer, verify the selected cluster/PVC/node identity, preserve existing state, restore the exact files as UID/GID 65532 with mode 0600, then restart Traefik and verify normal trust and expiry. Rehearse the byte/permission-preserving restore in a separate private path without overwriting live state. If recovery material is absent or compromised, explicitly reissue using the chosen CA; account/key loss, authorization reachability and CA rate limits can delay recovery. Do not imply that the application snapshot contains the ACME PVC.

### Workstation-only token rehearsal on the Pi

For an initial private rehearsal without Google login, omit `runtime.googleOAuthClientId`, OAuth secret paths, OAuth/Redis images, and `volumes.redis`; set `origin: http://127.0.0.1:8080` (matching `httpPort`). The account policy is required; ingress and Typesense credentials are generated by deployment. This is the default configuration.

This configuration omits OAuth2 Proxy, Redis and Google callback/cookie routing. GraphQL still runs in production mode behind trusted ingress, strips untrusted identity headers and validates the accounts policy and configured bearer tokens. Deployment imposes no role or token-count requirements: define tokens only for the operations being rehearsed. Keep `anonymous.role: anonymous` and `googleAccounts: {}` for the approved rehearsal; never elevate the credential-free role for testing. For authenticated write rehearsals, generate separate strong, temporary owner tokens for operator/MCP clients in private files; revoke them afterward. Restore verification separately requires an owner token for its write probe.

Traefik becomes a ClusterIP service, not a LAN load balancer. Access the application with a loopback-only Kubernetes port-forward carried through the existing private API SSH tunnel:

```sh
mise exec -- kubectl --kubeconfig "$HOME/.config/recipe-db/kubeconfig/pi.yaml" \
  --context recipe-db-pi -n kube-system port-forward --address 127.0.0.1 service/traefik 8080:80
```

Use the production deploy command with the private values file and `recipe-db-pi` context. Keep the port-forward and API tunnel running while testing; stop them afterward. This is an initial synthetic-data rehearsal, not browser Google-login, public HTTPS, backup or production-readiness acceptance. Browser writes requiring Google login are not validated by bearer GraphQL/MCP tests. Enabling Google login or public exposure is not part of this procedure.

### Home-LAN HTTP token rehearsal on the Pi

Accepted decision [#103](https://github.com/dhhyi/recipe-db/issues/103) makes private phone browsing part of [#45](https://github.com/dhhyi/recipe-db/issues/45). Keep the account/secret requirements above, leave Google OAuth settings absent, and explicitly set:

```yaml
runtime:
  ingressMode: private-lan
  trustedIssuer: https://accounts.google.com
origin: http://recipe-pi.home
```

Use the Pi's actual private hostname (ending in `.home`, `.lan` or `.local`) or RFC 1918 IPv4 address, with HTTP port 80 and no explicit port suffix. `httpPort` remains the workstation-forwarding port, not the LAN listening port. The origin controls browser-write validation; use that configured origin for same-origin browser writes. A phone may need the private IPv4 address if it cannot resolve the hostname.

Deploy using the same private API tunnel and immutable release. Traefik becomes a k3s LoadBalancer on port 80 only, with NodePort allocation disabled; the internal REST entrypoint and HTTPS remain unexposed. The provisioned private-network firewall is a prerequisite: only its configured application networks may reach port 80, including forwarding rules; global IPv6 is not enabled. Do not configure router forwarding, UPnP, public DNS or public ingress. No API/SSH exposure changes are made. Setting `ingressMode: loopback` (or omitting it) restores the ClusterIP-only default after redeployment.

Anonymous browsing remains read-only. Bearer GraphQL/MCP writes are temporarily allowed on trusted-LAN HTTP at the operator's explicit request; HTTP does not protect tokens or recipe data against observers or intermediaries. Do not share these credentials, add an anonymous-owner bypass or assume browser Google login works.

Before external exposure, verify the intended account policy, actual authentication and HTTPS behavior, replace temporary bearer tokens, and remove temporary private-LAN access. Do not rotate or store ingress/Typesense credentials: each deployment/restore creates fresh values and rolls dependent workloads. External exposure requires explicit approval and completed deployment acceptance criteria.

```sh
cd /home/runner/work/recipe-db/recipe-db
VALUES="$PWD/.secrets/local-values.yaml"
RELEASE='ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-artifact-digest>'

mise run production-k3d create "$VALUES"
mise run production-k3d verify "$VALUES"
mise run production-k3d render "$VALUES" "$RELEASE" > "$PWD/.secrets/rendered.yaml"
mise run production-k3d deploy "$VALUES" "$RELEASE"
mise run production-k3d status "$VALUES"
mise run production-k3d kubectl "$VALUES" get configmap recipe-db-release -o json
mise run production-smoke "$VALUES" "$RELEASE" \
  "$PWD/.secrets/production-smoke-token" "$PWD/.secrets/production-smoke-result.json"
```

`create` reuses only a cluster that passes the managed-identity checks; it refuses an unrelated cluster using the reserved name. `deploy` applies namespaced configuration and operator secrets, initializes JetStream, and waits for readiness. Under the shared Lease, it removes an existing owned cleanup Job and waits for its workers to disappear before recreating the release-specific Job suspended; Kubernetes Job templates cannot be updated in place. An unowned Job or failed worker removal blocks deployment. `recipe-db-release` records the release artifact and source revision. Reapplying the identical artifact is intentional and should preserve PVC-backed data. `status` and smoke failure diagnostics report resource summaries, not credentials. All smoke Kubernetes operations use the driver's guarded `kubectl` interface with explicit context and namespace; no ambient kubeconfig is trusted.

The application objects live in `recipe-db`. The intentional infrastructure exception is the bundled Traefik `HelmChartConfig`, its route Secret, and its internal metadata Service in `kube-system`. There is **one** bundled Traefik with a file provider, not a second ingress controller or a parallel hand-maintained application route list. Routes, priorities, strip-prefix middleware, OAuth forward-auth, identity-header stripping and internal GraphQL ingress-token injection retain their project-metadata definitions. The internal metadata port is cluster-only; router/service discovery does not expose raw route configuration, middleware configuration, dashboards or credentials publicly.

`infrastructure.traefik` explicitly overrides the bundled controller's image via `HelmChartConfig` to the digest-pinned `traefik:v3` reference from the deployment values. The k3s-bundled Traefik 3.6.13 lacks the required `aliasHeadersStrategy` support; the override preserves the existing authentication header-alias sanitization and must stay at 3.7 or later. This upgrades the same bundled controller, not an additional ingress deployment.

The driver applies the two namespaces separately. Application secret checksums include the rendered manifests and trigger workload replacement when credentials or rendered configuration change, including OAuth provider settings generated by templates. A separate route checksum in the bundled controller's pod annotations triggers a Traefik rollout when its file-provider configuration or ingress token changes; deployment waits for that exact checksum, not a previously ready controller. Identical inputs keep both checksums stable.

Deployment and the local snapshot operation use the same cluster-scoped `recipe-db-deploy` Lease. An existing Lease blocks either operation rather than being silently stolen. The backup workflow retains its Lease and recovery state if production recovery is unsafe; do not use `lock-recover` to bypass that state. Inspect the selected cluster, `backup-state.json`, Lease and workload modes/counts, then complete safe production recovery before considering manual abandoned-lock recovery.

## What the protocol smoke verifies

The four positional arguments are an absolute values path, immutable artifact reference, absolute bearer-token-file path and absolute result-JSON path. The driver must verify the managed local cluster **before any HTTP request or mutation**. The smoke deliberately refuses Pi values and non-loopback origins.

The script uses HTTP protocols, not a browser automation suite:

The public static-asset route `/design/` serves the built Storybook; it does not expose the Storybook development server. The existing `/design/styles.css` and `/design/components.js` endpoints remain available.

1. Confirms the deployed ConfigMap artifact and revision, recording available exact client tool versions in JSON. Before its first HTTP request or recipe mutation, explicitly waits for the NATS rollout, `nats-init` Job completion, and every application's Deployment rollout. Search's index-readiness sidecar requires `/health` to report `ready: true`, not merely a listening process.
2. Creates one uniquely named recipe, reads it, updates it and reads the change. No test-only bulk-reset endpoints are used.
3. Uploads the existing JPEG fixture using GraphQL multipart Upload, reads image metadata through GraphQL, and verifies the returned public PNG and thumbnail content hashes against their URLs.
4. Waits within the configured deadline for the recipe in search, GraphQL browse data, and the actual server-rendered browse search response.
5. Checks browse, both editor HTML entry points, the Storybook page and its built JavaScript asset at `/design/`, design CSS and component JavaScript (including their same-origin hashed-asset redirects), plus the nonempty JavaScript runtime at `/design/htmx.min.js`.
6. Initializes MCP Streamable HTTP, sends its initialized notification and calls the allowed read-only `get_recipe` tool; no MCP write capability is assumed.
7. Asserts HTTP 404 for representative private REST, NATS, Typesense, monitoring and Kubernetes paths: `/recipes`, `/ratings`, `/inspirations`, `/search/reindex`, `/varz`, `/jsz`, `/collections`, `/metrics`, `/healthz` and `/api/v1/namespaces`. Also denies Traefik metadata/configuration endpoints, dashboard and `/oauth2/auth`. These use non-HTML requests, not maintenance-page fallbacks.
8. Saves browse's exact replica count, scales only browse to zero, and waits for browse HTML's maintenance 503, comparing its body with the actual bundled maintenance page rather than accepting an unrelated HTML error. GraphQL, an initialized MCP read, images, both editors and design assets must still work. It restores the original replicas on success **or failure**.
9. Discovers persistent Deployments from live PVC volume references, restarts each with bounded rollout waits, and reapplies the identical release. This covers the configured recipes, images, ratings, inspirations, image-inline, link-extract, NATS, Typesense, search and Redis persistence without a second application-name list. The own recipe, image bytes, search and browse must survive.
10. Deletes only the smoke-created recipe and verifies its absence.

An EXIT handler attempts deletion of that specific recipe after a failure and reports whether cleanup succeeded; it never deletes other records or the cluster. Interrupted or unreachable services can make cleanup impossible: inspect the record ID in the result and remove only that record once service is restored. The cluster remains available for diagnosis after both success and failure. Normal API deletion/eventual downstream cleanup semantics apply; this is not a whole-database reset or a storage leak/compaction test.

The JSON result contains `success`, `phase`, completed checks, artifact, revision, timestamps, own recipe ID, image URL/hash, cleanup status and available tool versions. Preserve it as rehearsal evidence only after checking it is suitable for publication. A failed exit is a failed rehearsal, even if some checks passed. This tests pod replacement and manifest reapplication, not cluster recreation, power-loss recovery, host reboot, physical USB reliability, TLS/browser OAuth, backup restoration or multi-node high availability.

## Storage, Pi adaptation and destructive deletion

Both values files use independent `ReadWriteOnce` PVCs. Local rehearsal uses the default k3s `local-path` storage class; new Pi claims use `recipe-db-retained` and the provisioned `/srv/recipe-db/storage` directory. Verified legacy Pi claims retain their existing `local-path` class and data directories. The target Pi uses the **same 128 GB USB device** for its OS and these directories; this plan does not require or imply a separate SSD, host bind mount, or custom `/mnt/ssd` mount.

The checked-in initial values request the following storage:

| PVC          | Initial request |
| ------------ | --------------- |
| recipes      | 1 GiB           |
| images       | 2 GiB           |
| ratings      | 256 MiB         |
| inspirations | 256 MiB         |
| image-inline | 256 MiB         |
| link-extract | 256 MiB         |
| NATS         | 1 GiB           |
| Typesense    | 1 GiB           |
| search       | 256 MiB         |
| Redis        | 256 MiB         |

| Container budget | CPU request | Memory request | Memory limit |
| --- | --- | --- | --- |
| Application/infrastructure default | 25m | 32 MiB | 512 MiB |
| Additional search index-readiness sidecar | 5m | 8 MiB | 32 MiB |

These are initial declarative settings, **not measured Pi sizing guarantees**, reserved physical capacity, or evidence that every workload fits the target device. Account separately for k3s, Traefik, OS, image storage and filesystem overhead; tune and measure against the actual 128 GB USB device.

For routine Pi releases, use the [production release cookbook](production-release-cookbook.md). For a new or rebuilt host, complete the [rebuild cookbook](raspberry-pi-rebuild.md) first. Render, deploy and status use the explicit Pi context; `create`, `verify`, guarded local `kubectl`, smoke and `delete` refuse to manage a Pi cluster. Rendered declarations alone do not validate ARM64 execution, memory/disk budgets or the physical USB device.

Local k3d has **no host-directory persistence contract**. PVCs survive pod replacement and identical-release reapply, but deleting the cluster destroys its data. Export anything needed for investigation before deleting it. Deletion requires the exact cluster-specific confirmation:

```sh
cd /home/runner/work/recipe-db/recipe-db
mise run production-k3d delete "$PWD/.secrets/local-values.yaml" \
  DELETE-recipe-db-rehearsal-AND-ALL-DATA
```

There is no automatic teardown at the end of the smoke. Do not use the destructive command as a troubleshooting shortcut, and never treat k3d PVCs as a backup.

## Script regression checks

Mocks exercise guard ordering, HTTP protocol sequencing, private credential handling, PVC-derived restart selection, same-artifact reapply, bounded eventual search and failure cleanup. These checks do not substitute for the real rehearsal. Run repository script checks on the host (the script-tooling exception), not in an application devcontainer:

```sh
cd /home/runner/work/recipe-db/recipe-db
mise run test-scripts
mise exec -- bazelisk build --action_env=PATH --jobs=1 //:shellcheck
```
