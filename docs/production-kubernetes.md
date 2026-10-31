# Production Kubernetes deployment and local rehearsal

The production manifest renderer consumes the same project metadata and immutable multi-platform release inventory as production image publishing. It does not build images. A local, single-server k3d deployment is the first acceptance target; the Pi values file is a deployment contract, **not evidence of a validated Pi installation**. No real-cluster rehearsal or physical-device validation is implied by the presence of the scripts or their mocked regression tests.

## Prerequisites and boundaries

- For initial physical Pi setup, follow the [Windows/WSL USB bootstrap guide](raspberry-pi-bootstrap.md), then the [private host provisioning guide](raspberry-pi-provisioning.md). Bootstrap evidence and provisioning tooling are not completed Pi application acceptance.
- Run commands from the repository root, with an absolute values-file path. Examples below use `/home/runner/work/recipe-db/recipe-db`; substitute your actual absolute checkout path.
- Local rehearsal requires an x86-64 host, a running Docker daemon with **more than 8 GiB** assigned, available loopback ports 8080 and 6445, and access to GHCR. Leave enough disk space for images and the requested PVCs.
- The tool contract is k3d **5.8.3**, k3s **v1.35.5-k3s1**, kubectl **1.35.5**, ORAS **1.3.6**, and ytt **0.55.4**, plus Bash, jq, yq, curl and GNU `sha256sum` (and OpenSSL for the token-generation example). Repository mise configuration supplies the pinned tools. Docker is a host prerequisite.
- Use a published `ghcr.io/dhhyi/recipe-db-releases@sha256:<64 hex digits>` artifact, not a mutable tag or an individual application image. The driver validates the artifact shape, source, revision and complete image inventory.
- No development Compose generation or development authentication fixture is needed. Do not copy fixture credentials into production.

The local identity is deliberately narrow: target `local`, cluster `recipe-db-rehearsal`, context `k3d-recipe-db-rehearsal`, namespace `recipe-db`, origin `http://127.0.0.1:8080`, and a default 600-second wait timeout. A different configured `httpPort` is supported only with its matching loopback origin; set `apiPort` independently when its default is occupied. The driver checks managed container labels, node identity, k3s image, loopback-only port bindings and its freshly obtained explicit kubeconfig. It does not switch the user's default context. A URL responding on port 8080 is not sufficient.

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

#### Snapshot capture

The `backup`, `backup-enter`, `backup-exit`, `deploy`, and `storage-reattach` operations coordinate through the same `recipe-db-deploy` Lease in `kube-system`, outside the replaceable application namespace. They do not expire or automatically steal a Lease. Backup validates the explicit target/context, immutable release digest/revision, actual project container images, deployed runtime Secret, selected PVC identities, ownership and destination capacity. Backup and recovery require the release commit locally and unchanged metadata/template inputs relative to it; untracked inputs are refused, while unrelated checkout changes are allowed. This binds the authoritative inventory and cleanup definition to the release without fetching or executing another checkout. Preflight requires selected PVC requests plus 64 MiB staging headroom; because local-path requests do not enforce a quota, capture also measures each stopped PVC's exact tar byte count before copying and requires actual free space plus the same headroom. This includes sparse-file expansion and previously copied archives. It does not read the configured application secret files. The snapshot validator requires Python 3 with its standard library.

Run only during an approved maintenance window, from a trusted workstation with the explicit target values file and a private destination filesystem. This operation changes runtime modes, briefly stops backend workloads and transfers application data; do not point it at a live Pi or production cluster during development or tests.

```sh
VALUES="$PWD/.secrets/local-values.yaml"
RELEASE='ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-artifact-digest>'
SNAPSHOT="$PWD/.backups/recipe-db-$(date -u +%Y%m%dT%H%M%SZ)"
umask 077
mkdir -p "$PWD/.backups"
mise run production-k3d backup "$VALUES" "$RELEASE" "$SNAPSHOT"
```

The operation stops and drains the normal GraphQL Pods first, then raises the `MODE=backup` barrier before touching data backends. GraphQL drains active connections for at most 20 seconds, within Kubernetes' 30-second default termination grace period. A resource-versioned Pod watch must observe normal termination; a missing termination record, failed drain, OOM or SIGKILL prohibits capture. It stops normal backend/projection workloads before bringing up any authoritative backup-mode backend. The rendered `backup-cleanup` Job runs once: its existing worker retries each retryable operation once plus two retries, without repeating permanent failures or duplicating cleanup logic. Completed purges are not rolled back on failure.

After cleanup, all remaining data writers terminate before role-selected PVCs are exported with temporary read-only copy Pods. `.project.yaml` supplies both `backupRole` and `backupData` (SQLite, JSON or image-manifest layout). Capture rejects missing databases, undeclared files/directories, links, unsafe archive paths, and missing, corrupted or unselected image pairs. Recipes, ratings, inspirations, tags inventory/assignments, SQLite recovery sidecars and current image/thumbnail pairs are included. Derived/external caches, logs, container images, OS/k3s state and secrets are excluded. An empty image dataset still requires both owned storage directories. No archive is published if cleanup, termination or copy validation fails.

A complete snapshot is identified only by `manifest.json` (`format: recipe-db-pvc-snapshot`, `formatVersion: 1`). It records `backupId`, `startedAt`, `capturedAt`, `completedAt`, `source` (`target`, `cluster`, `context`, `namespace`, immutable `artifact`, `revision`) and `inventory`. Each inventory entry contains `service`, `role`, `pvc`, `archive`, `sizeBytes`, `fileCount`, `sha256` and `files`; each regular-file entry has its archive-relative `path`, `sizeBytes` and `sha256`. Archives are `<service>.tar`, with no secrets or outer packaging. Present SQLite `-wal`, `-shm` and `-journal` sidecars belong to their database. Downstream packaging must require the manifest, verify archive and file hashes, reject unsafe extraction paths, and preserve this versioned inventory. Staging directories are created privately, never overwritten or recursively removed by the lifecycle.

#### Verified remote packaging

The publisher consumes only that complete snapshot directory; it does not capture PVCs or infer service layouts. It rechecks the lifecycle manifest, every archive SHA-256, every regular-file size/hash, path safety and snapshot completeness before packaging. The uploaded `<deployment>-<capturedAt>-<backupId>.tar.gz` is an ordinary gzip-compressed tar containing `manifest.json` and the service `.tar` files in sorted order. Outer tar metadata is normalized (mtime, owner, group and mode) and the gzip timestamp is zero. Its sibling `.manifest.json` uses `format: recipe-db-backup`, `formatVersion: 1`, and records deployment/backup IDs, capture order, the original release identity and snapshot manifest, a content fingerprint, and the archive name, byte size and SHA-256. Restore tooling must verify this package manifest, archive hash and inner snapshot contract before extracting or restoring; only a matching complete archive/manifest pair is a restore point.

The change fingerprint includes snapshot format/version, immutable release artifact and revision, each service/role/PVC/archive identity, and sorted file paths, sizes and hashes. It deliberately excludes backup IDs and capture timestamps. A release-only change therefore publishes a new point, while repeated identical data can be skipped only after reading back and hashing both files from the prior verified remote point. A missing or corrupt remote baseline causes a new upload rather than a false unchanged result. Archive then manifest are copied as individual files with `rclone copyto` (never `sync`); the manifest is the final completion marker. Both files are read back and SHA-256 checked before the local baseline advances. Temporary packaging space is bounded by the configured `maxStagingBytes` (8 GiB by default); there is no local upload queue. A failed transfer preserves the prior baseline. Retention runs only after a verified upload, keeps the newest 30 complete points by `capturedAt`, and deletes only pairs whose deployment ID and manifest/archive identities verify. Pruning errors leave the verified new baseline intact and are reported separately.

The provisioning playbook installs rclone 1.75.2 from its versioned ARM64 package with a pinned SHA-256 and copies the root-only local kubeconfig to `/etc/recipe-db/backup-kubeconfig.yaml` under context `recipe-db-pi`. It installs a `recipe-db-backup.service` and local-time `02:15` timer with up to 15 minutes of jitter. `Persistent=false` means missed occurrences are skipped, not replayed as backlog snapshots. A service lock prevents overlapping runs; the two-hour service timeout bounds capture and publication. The timer is enabled by provisioning, but a missing `/etc/recipe-db/backup.json` prevents the service from running. The timer's presence or enabled state is not backup health.

An operator must create `/etc/recipe-db/backup.json` mode `0600`, containing `deploymentId`, `remote` (for example `gdrive:recipe-db-backups`), `rcloneConfig` (`/etc/recipe-db/rclone.conf`), `stateDirectory` (`/var/lib/recipe-db-backup`), `stagingDirectory` (`/var/lib/recipe-db-backup/work`), `captureCommand` (an absolute executable path), `captureTimeoutSeconds` and optionally `maxStagingBytes`. The capture command accepts exactly one argument: a new absolute destination directory. It must invoke the lifecycle child's `production-k3d backup` operation with the same explicit Pi values, context `recipe-db-pi`, and deployed immutable release, then return success only for a complete snapshot at that directory. Keep that checkout at `/opt/recipe-db`, at the matching release revision, and make its pinned Mise tools and private target configuration available to root's systemd process. The service supplies `KUBECONFIG=/etc/recipe-db/backup-kubeconfig.yaml`. Do not copy kubeconfigs, release credentials or deployment secrets into the snapshot. The publisher suppresses subprocess output and emits only stable status codes; it never prints rclone configuration, remote content or capture-command output.

Create and authorize the private rclone configuration interactively with the dedicated operator-owned Google account, then transfer it over an authenticated private channel to `/etc/recipe-db/rclone.conf` owned by root, mode `0600`. Never put OAuth tokens in the backup JSON, command arguments, source control or service logs. Follow rclone's private authorization/reauthorization procedure when access expires; replace the private config securely and verify the next status before treating uploads as healthy. Retain the protected account-recovery method separately from this device. A lost host credential can be reauthorized; it does not invalidate already verified Drive points.

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

The snapshot capture remains the lifecycle interface; remote upload and retention now consume it without changing its capture behavior. Archive encryption and archive restore remain separate work. Mocked tests are not a real-cluster or physical Pi rehearsal; no physical acceptance is claimed.

## Operator configuration and secrets

`deploy/local.yaml` and `deploy/pi.yaml` contain non-secret configuration and absolute **secret-file references**, not usable credentials. Copy the desired values under the gitignored repository-root `/.secrets` directory and edit the copy. That directory must not be committed, uploaded as an artifact, or included in diagnostics.

```sh
cd /home/runner/work/recipe-db/recipe-db
umask 077
mkdir -p .secrets
cp deploy/local.yaml .secrets/local-values.yaml
```

Provide these private operator-managed files, all readable only by the operator:

| Values key under `secrets` | Contents |
| --- | --- |
| `auth-accounts.json` | Valid configuration conforming to `graphql/auth-accounts.schema.json` |
| `graphql-ingress-secret` | 43 URL-safe base64 characters shared by ingress and GraphQL |
| `typesense-api-key` | Strong Typesense API key |
| `google-oauth-client-secret` | Actual Google OAuth client secret |
| `oauth2-cookie-secret` | Base64-encoded random 16-, 24- or 32-byte cookie key |

Cookie keys may use standard or URL-safe base64, with or without padding and with an optional trailing newline. The driver validates the decoded length and stages a newline-free URL-safe representation for OAuth2 Proxy without modifying the operator's file.

Set each corresponding value to its absolute path, and set `runtime.googleOAuthClientId` to the real, public Google client ID ending in `.apps.googleusercontent.com`. Keep the trusted issuer `https://accounts.google.com`. Configure the provider's authorized redirect URI for this origin's `/oauth2/callback`. Google browser login is not tested by the HTTP smoke. Do not disable auth or replace real provider settings with an anonymous-write policy to make a rehearsal pass.

For example, after securely provisioning the files:

```sh
cd /home/runner/work/recipe-db/recipe-db
ROOT="$PWD"
export ROOT
mise exec -- yq -i '
  .secrets."auth-accounts.json" = (strenv(ROOT) + "/.secrets/auth-accounts.json") |
  .secrets."graphql-ingress-secret" = (strenv(ROOT) + "/.secrets/graphql-ingress-secret") |
  .secrets."typesense-api-key" = (strenv(ROOT) + "/.secrets/typesense-api-key") |
  .secrets."google-oauth-client-secret" = (strenv(ROOT) + "/.secrets/google-oauth-client-secret") |
  .secrets."oauth2-cookie-secret" = (strenv(ROOT) + "/.secrets/oauth2-cookie-secret")
' "$ROOT/.secrets/local-values.yaml"
```

The smoke requires a separate private bearer-token file. Add that token as a uniquely identified principal in the operator's auth-accounts configuration. Under the **existing** policy the editor-capable role is named `owner`; `member` cannot manage recipes or images, and `editor` is not a valid role. Preserve the intended anonymous/member policy and existing accounts. The smoke does not create accounts or mint credentials automatically. It checks that the supplied token matches an explicit `owner` entry in the configured accounts file before making requests. The current GraphQL schema has no viewer/current-principal field; successful create/update/image/delete operations additionally verify the deployed policy actually authorizes the token. A local file match alone is not treated as proof of deployed authorization.

To add a dedicated smoke principal to an already valid accounts file, generate a new strong token without overwriting an existing token, then use file-based input rather than putting the token on the command line:

```sh
cd /home/runner/work/recipe-db/recipe-db
umask 077
(
  set -C
  openssl rand -hex 32 > "$PWD/.secrets/production-smoke-token"
) \
  && mise exec -- jq --rawfile token "$PWD/.secrets/production-smoke-token" '
  if any(.tokens[]; .id == "production-smoke") then
    error("production-smoke principal already exists; explicitly rotate it")
  else
    .tokens += [{id:"production-smoke", secret:($token | rtrimstr("\n")), role:"owner"}]
  end
' "$PWD/.secrets/auth-accounts.json" > "$PWD/.secrets/auth-accounts.next.json" \
  && mv "$PWD/.secrets/auth-accounts.next.json" "$PWD/.secrets/auth-accounts.json"
```

The account ID is stable and explicit; the token is not the ID. Revoke or rotate the dedicated credential after rehearsal, then redeploy to apply the updated accounts file. Do not print secret files, `kubectl get secrets`, raw manifests containing credentials, or unrestricted application/proxy logs into CI output. The smoke stores Authorization in a private curl config, never in curl arguments.

## Create, render, deploy and inspect

### Certificate-only HTTPS staging on the Pi

After rehearsal credential replacement, an operator may add this optional block to the private Pi values file. Keep `runtime.authMode: token-only`, `runtime.ingressMode: private-lan`, and the existing private LAN `origin`:

```yaml
httpsStaging:
  hostname: your-hostname.example.org
  acmeEnvironment: staging
```

This enables a separate Traefik HTTP entrypoint on Pi TCP 8081 and HTTPS on TCP 8443. Existing private LAN application HTTP on TCP 80 and internal GraphQL ingress remain unchanged. The HTTPS entrypoint serves only a fixed staging-check response at `/` for the configured hostname; application, OAuth, MCP, static, image, and infrastructure paths have no staging router and return 404.

Only after inspecting the deployed listeners, the operator forwards router TCP 80 to Pi TCP 8081 and router TCP 443 to Pi TCP 8443. The private host firewall also requires explicitly approved exceptions for these two destination ports and their Kubernetes DNAT paths. Do not forward to the application's Pi TCP 80, open SSH/Kubernetes/backend ports, flush nftables, or publish an unverified IPv6 record. This deployment command does not change the router or host firewall.

Traefik answers Let's Encrypt HTTP-01 challenges on the staging HTTP entrypoint; ordinary requests redirect to external HTTPS port 443. No Dynu API credential is needed. Begin with the ACME staging environment to test validation without production rate limits. Its test certificates are **not browser-trusted**: successful test issuance is not trusted-HTTPS acceptance. Change `acmeEnvironment` to `production` and redeploy to obtain the trusted certificate. Use the hostname, not the numeric IP, and do not bypass certificate validation for production acceptance.

ACME account keys and certificates persist in the private `recipe-db-acme` PVC in `kube-system`, using the owned retained Pi StorageClass. Traefik runs as UID/GID 65532, uses a single Recreate deployment, and initializes each environment's ACME file with mode 0600. Test and production use separate files; ordinary redeployments must not delete the claim. The claim is outside application backup capture: protect it separately as private recovery material or explicitly reissue after recovery, accounting for CA rate limits. Never publish ACME files, private keys, raw Secret data, or unrestricted proxy logs.

Traefik automatically renews certificates while DNS and inbound challenge access remain usable. Before acceptance, verify the trusted hostname/chain, root response, 404s for `/graphql`, `/mcp`, `/oauth2/callback`, `/design`, `/images`, and `/api`, HTTP redirects, private LAN browsing, retained state across redeployment, and actual renewal evidence. Inspect certificate expiry and ACME failure diagnostics locally without publishing credentials; successful initial issuance alone does not prove renewal. Certificate hostnames are public in certificate transparency logs.

To disable external staging, remove the two router forwards and their host firewall exceptions. Removing `httpsStaging` and redeploying also removes the staging listeners/routes; it deliberately retains the ACME PVC and the unexposed staging workload. This milestone is not Google-provider verification or full authenticated go-live. Those remain gated by the agreed protected route boundary and the deployment/authentication acceptance issues.

#### Explicit anonymous-only public preview

Accepted [#125](https://github.com/dhhyi/recipe-db/issues/125) permits a limited public preview under [#44](https://github.com/dhhyi/recipe-db/issues/44), separate from full authenticated launch [#123](https://github.com/dhhyi/recipe-db/issues/123). After private checks and explicit operator approval, set `httpsStaging.readOnlyPreview: true` with `acmeEnvironment: production`. Omission or `false` keeps certificate-only staging. This option requires `anonymous.role: anonymous`, `tokens: []` and `googleAccounts: {}` in the deployed policy; otherwise deployment fails before cluster mutation. Removing accepted tokens also revokes their private-LAN use. Keep the required GraphQL ingress and Typesense secrets: they authenticate internal services, not public users.

The dedicated HTTPS listener routes only GET/HEAD browsing and its read-only fragments, GET/HEAD `/design/` assets and `/public/` images, and `/graphql` GET/POST/OPTIONS. The read-only similarity continuation uses POST `/recipe/{id}/similar/more`; POST is not inherently a mutation. GraphQL's existing anonymous capability guards deny mutations and private ratings/comments. Public GraphQL still strips untrusted identity headers before injecting the private ingress token. The frontend's existing compression/maintenance handling and internal GraphQL routes remain unchanged.

There is no public catch-all frontend router: editor, MCP, OAuth, REST, dashboard, rating-write and tag-write paths are excluded. Browser URLs use the public HTTPS hostname; private application HTTP remains for anonymous LAN browsing, not privileged token rehearsal. Verify forbidden GraphQL operations and excluded routes leave data unchanged before enabling router forwarding. This preview is public exposure, **not** completion of Google verification, application backup/recovery, or the full launch checklist.

#### Controlled test-CA renewal rehearsal

Set `httpsStaging.renewalRehearsal: true` only with `acmeEnvironment: staging` and certificate-only routing. It enlarges Traefik's configured certificate duration to 8760 hours solely to move an existing test certificate into the renewal window. Traefik checks that window at startup and uses its normal renewal path; no clock change, live-file editing or certificate deletion is needed. The flag is rejected for production. Record the existing test certificate fingerprint/serial, observe renewal diagnostics and the replacement certificate, and verify account continuity and unchanged production ACME state. Initial issuance of an absent test certificate is not renewal evidence.

Exercise failure visibility while challenge access is unavailable, then restore operator-approved reachability and verify renewal. Remove the rehearsal flag immediately afterward and restore `acmeEnvironment: production`. An ordinary production deployment uses Traefik's default duration/renewal schedule. Never leave the enlarged window enabled: repeated starts could unnecessarily renew test certificates. A controlled test-CA rehearsal does not claim an observed scheduled production renewal; retain that explicit limitation and inspect the trusted production certificate's expiry and normal ACME diagnostics.

### Workstation-only token rehearsal on the Pi

For an initial private rehearsal without Google login, set `runtime.authMode: token-only`, `runtime.googleOAuthClientId: ""`, and `origin: http://127.0.0.1:8080` (matching `httpPort`). Omit the `google-oauth-client-secret` and `oauth2-cookie-secret` keys from `secrets`; the other three secret files remain required. The default auth mode remains `google`, with its existing credential requirements unchanged.

This explicit Pi-only option omits OAuth2 Proxy and Google callback/cookie routing. GraphQL still runs in production mode behind trusted ingress, strips untrusted identity headers and validates configured bearer tokens. Accounts must retain `anonymous.role: anonymous`, an empty `googleAccounts` map and at least one explicit owner token. Never elevate the credential-free role for testing. Generate separate strong, temporary owner tokens for operator/MCP clients in private files; revoke them after rehearsal.

Traefik becomes a ClusterIP service, not a LAN load balancer. Access the application with a loopback-only Kubernetes port-forward carried through the existing private API SSH tunnel:

```sh
mise exec -- kubectl --kubeconfig "$PWD/provisioning/.private/pi-kubeconfig.yaml" \
  --context recipe-db-pi -n kube-system port-forward --address 127.0.0.1 service/traefik 8080:80
```

Use the PR checkout's deploy command with `KUBECONFIG` set to that private kubeconfig and the `recipe-db-pi` context. Keep the port-forward and API tunnel running while testing; stop them afterward. This is an initial synthetic-data rehearsal, not browser Google-login, public HTTPS, backup or production-readiness acceptance. Browser writes requiring Google login are not validated by bearer GraphQL/MCP tests. Switching an existing Google deployment to token-only or activating public exposure is not part of this procedure.

### Home-LAN HTTP token rehearsal on the Pi

Accepted decision [#103](https://github.com/dhhyi/recipe-db/issues/103) makes private phone browsing part of [#45](https://github.com/dhhyi/recipe-db/issues/45). Keep the token-only account/secret requirements above, but explicitly set:

```yaml
runtime:
  authMode: token-only
  ingressMode: private-lan
  googleOAuthClientId: ""
  trustedIssuer: https://accounts.google.com
origin: http://recipe-pi.home
```

Use the Pi's actual private hostname (ending in `.home`, `.lan` or `.local`) or RFC 1918 IPv4 address, with HTTP port 80 and no explicit port suffix. `httpPort` remains the workstation-forwarding port, not the LAN listening port. The origin controls browser-write validation; use that configured origin for same-origin browser writes. A phone may need the private IPv4 address if it cannot resolve the hostname.

Deploy using the same private API tunnel and immutable release. Traefik becomes a k3s LoadBalancer on port 80 only, with NodePort allocation disabled; the internal REST entrypoint and HTTPS remain unexposed. The provisioned private-network firewall is a prerequisite: only its configured application networks may reach port 80, including forwarding rules; global IPv6 is not enabled. Do not configure router forwarding, UPnP, public DNS or public ingress. No API/SSH exposure changes are made. Setting `ingressMode: loopback` (or omitting it) restores the ClusterIP-only default after redeployment.

Anonymous browsing remains read-only. Bearer GraphQL/MCP writes are temporarily allowed on trusted-LAN HTTP at the operator's explicit request; HTTP does not protect tokens or recipe data against observers or intermediaries. Do not share these credentials, add an anonymous-owner bypass or assume browser Google login works.

Before any external staging/public access, replace **every rehearsal application secret**: operator/MCP/other bearer credentials, GraphQL ingress secret and Typesense API key; generate fresh Google client/cookie secrets when enabling OAuth. Update private recovery sources and roll dependent workloads consistently. Verify old bearer tokens fail, new credentials work and temporary HTTP/token-only exposure is removed. Preserve stable principal IDs where vote continuity is required. [#44](https://github.com/dhhyi/recipe-db/issues/44) owns HTTPS/external checks and this transition, [#68](https://github.com/dhhyi/recipe-db/issues/68) owns Google, [#52](https://github.com/dhhyi/recipe-db/issues/52) retains full access verification, [#43](https://github.com/dhhyi/recipe-db/issues/43) owns backup/recovery and [#104](https://github.com/dhhyi/recipe-db/issues/104) tracks measured operating limits. Private phone acceptance does not waive those requirements or complete [#17](https://github.com/dhhyi/recipe-db/issues/17).

Physical LAN execution on 2026-10-30 passed at the operator's private IPv4 origin without an application port-forward. The deployment completed with all 18 workloads Ready; Traefik exposed only LoadBalancer port 80, `allocateLoadBalancerNodePorts: false`, and no NodePorts. Direct LAN requests verified the five original demo recipe IDs/search results, ten image/thumbnail hashes, owner create/update/delete, denied anonymous/spoofed/invalid writes with unchanged state, private-route 404s and separate-token MCP initialization/listing. The temporary authorization-test recipe was removed without deleting demo records. LAN TCP probes found SSH/80 reachable and 443/6443/10250/30080 not reachable; this is selected workstation evidence, not all-interface/internet acceptance. Actual phone confirmation remains pending in #45. No secrets were rotated yet; replacement remains mandatory before external exposure.

### Physical rehearsal evidence

The operator subsequently confirmed on 2026-10-30 that the private page was visible and working on their phone after being directed to the Pi's private IPv4 origin on home Wi-Fi. This supersedes the pending-phone status above; detailed search/image checks remain the separately recorded direct-LAN tests. #45 remains open pending #42/PR review.

The first physical Pi token-only attempt on 2026-10-30 used artifact `ghcr.io/dhhyi/recipe-db-releases@sha256:2cae10efffe39c45c2e109690e0913b103a82734c389f16fe8339527d8e1c4fc` (source `de61f0894bf8d06b9788392e4d7011df02f4d40b`) with PR #102's deployment tooling. The initial attempt failed: Typesense reported `jemalloc: Unsupported system page size`, and the bundled Traefik chart required an `observability` object on the custom internal port. After the chart correction and an explicitly approved reboot using `kernel8.img`, the Pi reported 4096-byte pages and Typesense became Ready. Traefik 3.7.16 reconciled successfully with a ClusterIP service, no NodePorts or external IP, and no remaining service-load-balancer pod. Search rebuilt after ingress recovered, a repeated deployment completed successfully, and an anonymous GraphQL recipe-list query returned successfully through the loopback port-forward. This is not yet complete Pi acceptance; authenticated mutation, image, MCP and persistence checks are recorded separately below when verified.

The subsequent bounded physical Pi smoke passed through that same loopback ingress:

- Owner-bearer GraphQL create/read/update/delete; anonymous and spoofed-identity writes rejected, invalid bearer rejected, and the denied writes left the synthetic recipe unchanged.
- Image upload and anonymous image/thumbnail downloads with content hashes matching their URLs; indexed search and rendered browse results containing the synthetic recipe.
- Browse and both editor HTML entry points; design CSS/JavaScript redirects resolved successfully and HTMX was reachable. This does not validate interactive editor login/writes.
- MCP initialization, recipe read and authenticated recipe change using the separate MCP owner token; GraphQL confirmed the changed value.
- Backend, infrastructure, dashboard and OAuth paths returned 404 through application ingress.
- Recipes, images and Typesense pods were restarted, then the identical immutable release was reapplied. The recipe, MCP-written method and image URL/content survived; every application deployment ended Ready and the deployment operation lease was released.

The synthetic recipe was deleted afterward. Dependent image cleanup remains deferred under the normal backup-maintenance contract; no test reset was used. This was an ad-hoc, explicitly targeted Pi check, not execution of the guarded local-only k3d smoke. Host reboot with retained synthetic data, sustained-load/resource thresholds, off-device backup/restore, Google login and public HTTPS remain unverified. #45 stays open.

The operator subsequently chose to restore the default 16 KiB Pi kernel. `deploy/pi.yaml` now pins the official `typesense/typesense:29.0-arm64-lg-page16` image by digest; local amd64 values remain unchanged. Upstream documents this supported image variant in its [large-page build instructions](https://typesense.org/docs/guide/install-typesense.html#large-page-size-build). This supersedes the temporary 4 KiB workaround, not the application version. Restoring the host requires removing the manually added `kernel=kernel8.img` boot override and an approved reboot; do not restore an entire older boot-config backup, which could discard other settings. Reapply the Pi deployment with the updated image and verify the kernel page size, Typesense/search readiness and retained demo recipes/images. The earlier smoke evidence above used 4 KiB pages; post-transition acceptance is pending.

Post-transition recovery was then verified on the same day. The operator reported `16384` pages, kernel `6.18.50+rpt-rpi-2712` and active k3s; the API confirmed that kernel and the same Ready node. The exact pinned large-page image ran successfully, the immutable-release deployment completed, all 18 application deployments became Ready, and no deployment operation lease remained. All five previously imported demo recipe IDs, methods, ingredient names, inspirations and ratings survived; search indexed all five and browse rendered them. All ten image/thumbnail downloads matched their content hashes. This verifies retained demo data across the approved host reboot and image transition, not a backup restore or a repeat of every earlier authenticated smoke check.

Replace the digest placeholder with the actual **artifact** digest. Keep that same reference for the initial deployment, smoke reapply and evidence.

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

`create` reuses only a cluster that passes the managed-identity checks; it refuses an unrelated cluster using the reserved name. `deploy` applies namespaced configuration and operator secrets, initializes JetStream, and waits for readiness. `recipe-db-release` records the release artifact and source revision. Reapplying the identical artifact is intentional and should preserve PVC-backed data. `status` and smoke failure diagnostics report resource summaries, not credentials. All smoke Kubernetes operations use the driver's guarded `kubectl` interface with explicit context and namespace; no ambient kubeconfig is trusted.

The application objects live in `recipe-db`. The intentional infrastructure exception is the bundled Traefik `HelmChartConfig`, its route Secret, and its internal metadata Service in `kube-system`. There is **one** bundled Traefik with a file provider, not a second ingress controller or a parallel hand-maintained application route list. Routes, priorities, strip-prefix middleware, OAuth forward-auth, identity-header stripping and internal GraphQL ingress-token injection retain their project-metadata definitions. The internal metadata port is cluster-only; router/service discovery does not expose raw route configuration, middleware configuration, dashboards or credentials publicly.

`infrastructure.traefik` explicitly overrides the bundled controller's image via `HelmChartConfig` to the digest-pinned `traefik:v3` reference from the deployment values. The k3s-bundled Traefik 3.6.13 lacks the required `aliasHeadersStrategy` support; the override preserves the existing authentication header-alias sanitization and must stay at 3.7 or later. This upgrades the same bundled controller, not an additional ingress deployment.

The driver applies the two namespaces separately. Application secret checksums trigger workload replacement when credentials change. A separate route checksum in the bundled controller's pod annotations triggers a Traefik rollout when its file-provider configuration or ingress token changes; deployment waits for that exact checksum, not a previously ready controller. Identical inputs keep both checksums stable.

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

For a Pi deployment, copy `deploy/pi.yaml` to a private absolute values path, provide a real HTTPS origin, explicit Pi kubeconfig context, OAuth configuration, operator secrets and appropriately budgeted volume/resource sizes. Install the specified k3s version and establish the real device's networking/TLS separately. Render, deploy and status use the explicit Pi context; `create`, `verify`, guarded local `kubectl`, smoke and `delete` refuse to manage a Pi cluster. Rendered declarations alone do not validate ARM64 execution, memory/disk budgets or the physical USB device. Perform and record those acceptance checks before describing the Pi as production-ready.

Local k3d has **no host-directory persistence contract**. PVCs survive pod replacement and identical-release reapply, but deleting the cluster destroys its data. Export anything needed for investigation before deleting it. Deletion requires the exact cluster-specific confirmation:

```sh
cd /home/runner/work/recipe-db/recipe-db
mise run production-k3d delete "$PWD/.secrets/local-values.yaml" \
  DELETE-recipe-db-rehearsal-AND-ALL-DATA
```

There is no automatic teardown at the end of the smoke. Do not use the destructive command as a troubleshooting shortcut, and never treat k3d PVCs as a backup.

## Verification evidence

The earlier release-publication blocker is resolved. [Publish run 40515853280](https://github.com/dhhyi/recipe-db/actions/runs/40515853280) published and anonymously verified:

- Artifact: `ghcr.io/dhhyi/recipe-db-releases@sha256:e05612b6e79bba7005854ab9827e2525be1ba7d9cb9174b019fa9c54097a17eb`
- Source revision: `431f861ffb8912484f050b1bc744aba9667ea08f`
- This artifact predates the `MODE` runtime contract and is historical verification evidence only; it is not the release used by current templates.

On 2026-10-27, the full protocol smoke passed on an x86-64 Docker/k3d deployment with this real immutable release. All 11 phases completed, including private-path rejection, actual maintenance-page comparison, restored browse ingress, PVC-backed workload restarts, same-release reapplication, and retained recipe/image/search data. The test deleted only its own recipe and reported successful cleanup. The synthetic recipe name is a unique alphanumeric search token, avoiding Typesense's hyphenated-query interpretation. After restoring browse replicas, the smoke waits for ingress health as well as Kubernetes readiness.

After confirmed deletion, a newly created cluster passed the same complete smoke from empty volumes (`success: true`, `cleanupSucceeded: true`, 11 checks). Rotating only the disposable ingress secret and redeploying the identical release replaced the bundled Traefik pod and preserved successful authenticated GraphQL reads. The disposable cluster was then explicitly deleted and the k3d cluster list verified empty. Recreating empty volumes is not a backup-restoration test.

The operator explicitly authorized generated disposable-local owner and infrastructure credentials, including a non-production OAuth client placeholder. No production credentials, test fixture accounts, fabricated release inventory, or real Google browser login were used. This does not validate Google login, HTTPS, backup/restore, or physical Pi operation; those require separate verification.

The verified tools were k3d 5.8.3 with explicit server image `rancher/k3s:v1.35.5-k3s1`, kubectl 1.35.5, ORAS 1.3.6, ytt 0.55.4, Docker 29.8.2, jq 1.8.2, yq 4.54.1 and curl 8.18.0. The bundled controller used `traefik:v3.7.16@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65`. The k3d CLI's displayed default k3s version is not the selected server version.

Commands were the create/render/deploy/status/production-smoke commands above, using private values with `httpPort: 18080`, `apiPort: 16445` and `origin: http://127.0.0.1:18080` to avoid the running development stack. Full JSON results record the release, phase checks, cleanup status and exact client versions; secret values are excluded.

## Script regression checks

Mocks exercise guard ordering, HTTP protocol sequencing, private credential handling, PVC-derived restart selection, same-artifact reapply, bounded eventual search and failure cleanup. These checks do not substitute for the real rehearsal. Run repository script checks on the host (the script-tooling exception), not in an application devcontainer:

```sh
cd /home/runner/work/recipe-db/recipe-db
mise run test-scripts
mise exec -- bazelisk build --action_env=PATH --jobs=1 //:shellcheck
```
