# Production Kubernetes operations

This guide is the technical reference for maintainers and operators using Recipe DB's production Kubernetes deployment, backup, and recovery lifecycle. It covers safeguards, commands, and operational constraints rather than the routine release sequence; use the [production release cookbook](production-release-cookbook.md) for the ten-step release outline and its current limitations, [production configuration and recovery](production-configuration.md) for private operator inputs, and the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md) for host setup and fresh-cluster restoration.

**Table of contents**

- [Release capability inventory](#release-capability-inventory)
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
  - [Production HTTPS on the Pi](#production-https-on-the-pi)
    - [Google sign-in on the existing HTTPS application](#google-sign-in-on-the-existing-https-application)
  - [Local HTTP rehearsal](#local-http-rehearsal)
  - [Bundled Traefik configuration](#bundled-traefik-configuration)
  - [Check Traefik after a K3s upgrade](#check-traefik-after-a-k3s-upgrade)
  - [Deployment behavior](#deployment-behavior)
- [What the protocol smoke verifies](#what-the-protocol-smoke-verifies)
- [Storage, Pi adaptation and destructive deletion](#storage-pi-adaptation-and-destructive-deletion)
- [Script regression checks](#script-regression-checks)

## Release capability inventory

The release lifecycle and local rehearsal tools cover separate guarded operations; a production release still requires operator-led execution and acceptance. The production-backup rehearsal makes no Pi changes, is not a machine-enforced production gate, and does not replace the independent guards in the lifecycle commands. Use the [release cookbook](production-release-cookbook.md) for the sequence, current evidence limits and operator exceptions.

| Release step | Available today | Still missing |
| --- | --- | --- |
| 1. Prepare the candidate | Immutable application releases, matching source revisions, declared storage versions, and schema-2 inventories with validated, digest-pinned migrator images. | None; per-candidate rehearsal evidence is tracked in step 2. |
| 2. Test and rehearse | Synthetic same-release backup and fresh-target recovery; a private workstation runner for exact production-backup upgrade and complete-recovery scenarios. | A passing result for the exact proposed candidate and selected backup; this remains operator-run and is not produced by CI. |
| 3. Enter maintenance | Pi uploader disables the scheduled timer, then `backup-enter` blocks application operations and retains recovery state. | Continuing the full release safely. |
| 4. Capture a backup | The existing backup service continues the retained operation, validates the snapshot and verifies remote readback without reopening access. | Integration with the release result. |
| 5. Stage the candidate | `release-stage` validates the candidate checkout, applies it with all Deployments stopped under the retained Lease, and stages its migrator Jobs suspended. | Remote-backup verification is an explicit operator precondition; the command records the operator's attestation. Staging does not execute migrations. |
| 6. Run migrations | `release-migration-plan`, `release-migration-next` and `release-migration-status` discover and validate storage transitions, activate at most one suspended Job per invocation, and reconcile only confirmed completion. `release-migration-recover-claim` releases only an explicitly confirmed abandoned command claim; it does not alter migration execution. `release-migration-recover` clears and restores the exact complete pre-migration backup after explicit destructive approval; `release-recovery-reopen` is separate. A verified migration or no-migration result leaves the candidate stopped. | No automatic recovery or general rollback; guarded recovery is operator-directed, requires the matching previous immutable release and stopped storage workers, and applies only before reopening. |
| 7. Start the candidate | `release-start` requires the recorded handoff, starts GraphQL in backup mode, and waits for candidate readiness without reopening access. | Migration execution and readiness checks beyond deployment rollouts. |
| 8. Reopen access | `release-reopen` is a separate operator-confirmed action; `backup-exit` remains old-release recovery only. | None for the guarded reopen operation. |
| 9. Check the website | Manual website checks followed by `release-disposition` record close-access, temporary-fix, or accept-partial-failure. | Website acceptance criteria and release/backup closeout. |
| 10. Align backups | Input installation, verified capture and guarded timer enablement. | Integration with the release result. |

Maintenance keeps a cluster-wide operation lock, so standalone backup and deployment commands cannot simply be chained after entry. The guarded `release-*` commands continue that retained operation; they keep the original release identity and Lease until later closeout. The stage command's typed backup confirmation is an operator attestation, not a remote verification mechanism. Schema-2 release inventories carry migrators as a deterministic array; schema-1 inventories remain accepted for existing operations but cannot establish that no migration is needed. `release-stage` creates only missing release-specific migration Jobs, with pinned images, one intended service PVC mounted at `/data`, declared deadlines, no retries, and service-account token mounting disabled. It leaves them suspended. If an identical Job already exists, staging leaves its execution status and suspend state untouched; conflicting Jobs fail closed, and obsolete Jobs are not automatically removed. Planning reads actual version markers through read-only PVC probes and validates the whole adjacent-version path before execution. An atomic cluster claim prevents overlapping migration commands; each `next` invocation activates or reconciles at most one transition, while `status` is observational only. If a client exits while holding the command claim, recovery requires confirmation that the old command has stopped and deletes only the exact holder's Lease; it does not alter the Job or migration state. Completion requires the same Job to report success, worker Pods to be gone, and actual storage versions to match. Failed, missing or uncertain executions never authorize retry or startup. The Pi uploader's maintenance continuation reuses the retained operation; the timer remains disabled and access stays blocked after verified upload. See [snapshot capture](#snapshot-capture) for the lifecycle and recovery safeguards.

The migrator declaration and image-packaging contract, schema-1/2 inventory details, and `mise run test-migrator-packaging` are documented in [production image releases](production-releases.md). Do not automatically delete migrator images; retain images needed by active releases, rehearsals, and immediate recovery.

For the completed marker-only version-1 rollout, `release-fallback-stage` can stage the exact original release after an interrupted no-migration candidate start. It requires the retained recovery state and Lease, an explicit marker/format confirmation, a ready GraphQL backup barrier and clean shutdown of the other workloads. It leaves access blocked and storage unchanged. If any guard fails, stop and inspect rather than restoring over populated storage.

Older releases may not contain the lifecycle commands needed to continue or recover the rollout. Switch the same clean operator checkout once to the approved rollout-tooling revision. For an existing maintenance state, `mise run production-k3d --release-sources-from-git backup-capture ...` can capture the original release; use the same option for `release-stage` and every subsequent guarded `release-*` invocation. Capture normally requires version 2 state with saved PVC storage identities. The explicit Git-source handoff recognizes unversioned state from revision `a7e14347b604a35875ed0716c645d7b2436b6aac` only, with an independently recorded pre-maintenance identity receipt as described below. It checks the original inventory, PVC and PV identities, namespace identities and receipt time before upgrading state. This explicit mode requires a clean tooling checkout, materializes each artifact's exact source revision from local Git objects into temporary files, and uses that revision's metadata and templates, not the tooling checkout's versions. Staging records `toolingRevision`; continuation refuses a different tooling revision or omission of the option. Fallback uses the same pinned tools to render/start the exact previous artifact, so it does not switch back to obsolete tools. No second checkout or worktree is created; temporary source exports are removed when the command exits. Normal invocations retain their existing checkout/release checks. This one-time handoff was exercised under [#265: Prepare and rehearse the one-time storage-version rollout](https://github.com/dhhyi/recipe-db/issues/265); keep it for recovery of the identified legacy state, not routine releases.

The isolated production-backup rehearsal also uses Git-source mode for `restore`, `backup-enter`, `backup-capture` and guarded release operations so current lifecycle fixes apply while application artifacts remain pinned. This does not enable the legacy-state exception for other releases.

For that exact legacy release, record identities **before** `backup-enter`, from the original release checkout and with the explicit target kubeconfig. Set `VALUES`, `KUBECONFIG` and `EVIDENCE` to absolute paths; `EVIDENCE` must be a new private directory outside the future snapshot and outside the operator checkout. Run this Bash command with the pinned tools available:

```bash
(
  set -euo pipefail
  umask 077
  mkdir -m 700 "$EVIDENCE"
  source .scripts/lib/project-metadata.sh
  application_project_metadata_to_jsonl "$PWD" "$EVIDENCE/projects.jsonl"
  context=$(yq -r '.context' "$VALUES")
  namespace=$(yq -r '.namespace' "$VALUES")
  kubectl --kubeconfig "$KUBECONFIG" --context "$context" get namespace kube-system -o json > "$EVIDENCE/system.json"
  kubectl --kubeconfig "$KUBECONFIG" --context "$context" get namespace "$namespace" -o json > "$EVIDENCE/namespace.json"
  kubectl --kubeconfig "$KUBECONFIG" --context "$context" --namespace "$namespace" get pvc -o json > "$EVIDENCE/pvcs.json"
  kubectl --kubeconfig "$KUBECONFIG" --context "$context" get pv -o json > "$EVIDENCE/pvs.json"
  yq -o=json "$VALUES" > "$EVIDENCE/values.json"
  jq -en --arg recordedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile values "$EVIDENCE/values.json" --slurpfile projects "$EVIDENCE/projects.jsonl" \
    --slurpfile system "$EVIDENCE/system.json" --slurpfile application "$EVIDENCE/namespace.json" \
    --slurpfile claims "$EVIDENCE/pvcs.json" --slurpfile volumes "$EVIDENCE/pvs.json" '
  {format:"recipe-db-legacy-storage-identities",formatVersion:1,recordedAt:$recordedAt,
   source:($values[0] | {target,cluster,context,namespace}),
   namespaceUids:{system:$system[0].metadata.uid,application:$application[0].metadata.uid},
   pvcs:[$projects[] | select(.backupRole == "authoritative-read-only" or .backupRole == "cleanup-participant") |
     .name as $name | [$claims[0].items[] | select(.metadata.name == $name)] as $claim |
     if ($claim | length) != 1 then error("missing PVC") else
       [$volumes[0].items[] | select(.metadata.name == $claim[0].spec.volumeName)] as $pv |
       if ($pv | length) != 1 then error("missing PV") else
         {name:$name,uid:$claim[0].metadata.uid,volumeName:$pv[0].metadata.name,volumeUid:$pv[0].metadata.uid}
       end
     end]}' > "$EVIDENCE/identities.json"
)
```

Verify the receipt exists and is mode `0600`; keep it unchanged. Wait until the next UTC second before entering maintenance, because its `recordedAt` must strictly precede the state's `startedAt`. After switching to clean tooling, capture with `mise run production-k3d --release-sources-from-git backup-capture "$VALUES" "$STATE" "$EVIDENCE/identities.json"`. The file must remain operator-owned, private, non-symlinked and outside the snapshot. Missing evidence, replaced PVCs/PVs or namespaces, or receipts recorded at/after maintenance entry are refused. The receipt is trusted operator evidence, not cryptographic proof of its recording time; never manufacture one from already-entered legacy maintenance.

Archive format versions do not describe service data versions, and removing migration source must not prevent recovery of supported older backups. Existing [fresh-deployment restore](#fresh-deployment-restore) restores the backup's recorded release into empty storage; it is not an in-place rollback. Recovery from a failed or uncertain migration remains separate from the guarded migration executor.

Kubernetes runs one shared, read-only init container before each storage-backed service, including when backup or restore restarts the normal workloads. It compares the PVC's `storage-version` marker with the version declared by that release; a missing marker is accepted only for an empty production data root. A shared sidecar waits for the backend's successful `/health` response after fresh initialization, then publishes and synchronizes the declared marker. Backup and restore set both containers to backup mode and the sidecar never writes or changes a marker. The Pod stays unready until the marker and its directory have been synchronized. Docker Compose has no compatibility gate or marker publication. Existing unversioned production storage must not be used with these builds: Kubernetes startup fails closed, with no deployment-time bypass. Subsequent storage-format changes use the sequential migration lifecycle in [#262: Discover and execute release migrations sequentially](https://github.com/dhhyi/recipe-db/issues/262).

Detailed findings and delivery ownership are tracked in [#143: Define a release process with better gates](https://github.com/dhhyi/recipe-db/issues/143) and [#246: Inventory the current release process and start the release cookbook](https://github.com/dhhyi/recipe-db/issues/246), rather than repeated here.

## Prerequisites and boundaries

- For initial physical Pi setup, follow the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md). Provisioning and deployment success alone do not establish recovery or production acceptance.
- Run commands from the repository root, with an absolute values-file path. Examples below use `/home/runner/work/recipe-db/recipe-db`; substitute your actual absolute checkout path.
- Local rehearsal requires an x86-64 host, a running Docker daemon with **more than 8 GiB** assigned, available loopback ports 8080 and 6445, and access to GHCR. Leave enough disk space for images and the requested PVCs.
- The tool contract is k3d **5.8.3**, k3s **v1.35.10-k3s1**, kubectl **1.35.5**, ORAS **1.3.6**, and ytt **0.55.4**, plus Bash, jq, yq, curl and GNU `sha256sum` (and OpenSSL for the token-generation example). Repository mise configuration supplies the pinned tools. Docker is a host prerequisite.
- Pi provisioning pins the same K3s patch version and its ARM64 binary checksum in [`provisioning/group_vars/pi.yml`](../provisioning/group_vars/pi.yml). Changing an existing Pi's version requires a verified backup and explicit `allow_k3s_upgrade=true` for the reviewed preflight and provisioning commands; the default remains `false`, and downgrades are refused. Treat this as separate infrastructure maintenance, not an application deployment. Ordinary provisioning disables scheduled backups; follow the [backup configuration and activation sequence](#verified-remote-packaging) afterward.
- Use a published `ghcr.io/dhhyi/recipe-db-releases@sha256:<64 hex digits>` artifact, not a mutable tag or an individual application image. The driver validates the artifact shape, source, revision and complete image inventory.
- No development Compose generation or development authentication fixture is needed. Do not copy fixture credentials into production.

The default local identity is target `local`, cluster `recipe-db-rehearsal`, context `k3d-recipe-db-rehearsal`, namespace `recipe-db`, origin `http://127.0.0.1:8080`, and a default 600-second wait timeout. Additional isolated local clusters may use names prefixed `recipe-db-rehearsal-` and matching `k3d-<cluster>` contexts, which allows source and fresh-target recovery rehearsals to remain distinct. A different configured `httpPort` is supported only with its matching loopback origin; set `apiPort` independently when its default is occupied. The driver checks managed container labels, node identity, k3s image, loopback-only port bindings and its freshly obtained explicit kubeconfig. It does not switch the user's default context. A URL responding on port 8080 is not sufficient.

Local Traefik uses a LoadBalancer Service so k3s ServiceLB forwards the k3d load balancer's port 80 to Traefik. It allocates no NodePorts or external IPs; the managed k3d host bindings remain loopback-only. Pi uses the same Traefik LoadBalancer shape. Deploy and restore verify the live Service is a safe LoadBalancer before reporting success or reopening ingress.

### End-to-end backup and recovery rehearsal

The end-to-end runner creates two uniquely named, loopback-only k3d clusters, generates synthetic application credentials and records, captures the source PVCs, packages the snapshot, uploads it through a filesystem-backed fake `rclone` remote, and restores the verified package into a separately fresh target. It also exercises existing-cluster reset, failed-release closeout and interrupted recovery while checking that unrelated application-namespace and `kube-system` ACME storage are preserved. It validates restored reads and propagation and cleans up its own records through the backup lifecycle. It uses owner-token authentication with Google sign-in disabled, matching `deploy/local.yaml` without OAuth2 Proxy or Redis. It never uses Google OAuth or Drive credentials, accesses the Pi, or contacts a real remote.

Use an immutable release artifact whose revision matches the checkout and a distinct immutable candidate for the retained failed-release scenario, after ensuring the host has the production-k3d prerequisites above. On the workstation in fish:

```fish
mkdir -p "$PWD/.backups"
set -g RESULT "$PWD/.backups/backup-recovery-"(date -u +%Y%m%dT%H%M%SZ)
set -g RELEASE 'ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-artifact-digest>'
set -g CANDIDATE 'ghcr.io/dhhyi/recipe-db-releases@sha256:<different-64-hex-artifact-digest>'
mise run production-backup-recovery-k3d "$RELEASE" "$RESULT" "$CANDIDATE"
```

The runner preserves both clusters and private diagnostics on success and failure; generated credentials and values are under `$RESULT/secrets`. Inspect the result JSON and logs before removing the result directory. To remove either cluster, use its saved values file with `production-k3d delete` and the exact `DELETE-<cluster>-AND-ALL-DATA` confirmation. Read-only checks wait through bounded route convergence; mutations are never automatically replayed. Restore waits for verified reads and a ready GraphQL route before its propagation probe, retaining blocked ingress and its recovery Lease if readiness fails. The other injected lifecycle, packaging, upload, and restore failure contracts are exercised by the `deploy` script regression group.

The [release cookbook](production-release-cookbook.md#rehearse-the-deployed-backup-upgrade) defines the production-backup upgrade rehearsal. Unlike this synthetic runner, it reads the live Pi release identity, consumes a private production backup, runs both upgrade and complete-recovery scenarios on disposable local clusters, and removes its owned clusters and temporary data on success. Its Pi uploader status remains an operator attestation, not an independently queried remote verification; the private result records that limitation. A passing run against the exact release and backup is required before treating that candidate's upgrade path as rehearsed. The operator may exceptionally proceed without a passing result when urgent, but must report the outcome accurately; this does not waive any production lifecycle guard.

### Runtime mode

Production workloads set `MODE=production`. An absent `MODE` defaults to production; empty or unsupported values fail startup. `testing` enables isolated test resets. `backup` keeps production ingress protections, blocks application requests and writes, and enables private maintenance APIs. GraphQL also supports `maintenance`, which preserves reads while rejecting every mutation with a service-unavailable error; other services do not use this mode.

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
| images | `POST /maintenance/images/compact` | Keep the union of normal and thumbnail files referenced by every collection entry |

Body-bearing routes require `application/json` and use `{"recipeId":"opaque-id"}`. Purges and compaction return `204`; ID lists are complete, distinct, and ordered. In production/testing these routes return `404` without touching stored data. Unsafe image state fails cleanup rather than guessing which outputs are current.

### Backup-participant development checklist

- Declare `backupRole` and an integer `storageVersion` for captured storage; keep caches and secrets outside data volumes. Backup tooling treats each volume as opaque and does not require service-specific layout metadata.
- Keep `<data-root>/storage-version` as a positive decimal integer followed by one newline. The shared Kubernetes init container checks marker type, contents, readability and compatibility before containers start; an absent marker is allowed only for an empty production root. The shared sidecar waits for `/health`, publishes a fresh production marker, and keeps the Pod unready until publication succeeds. Services own initialization and data validation only; they never read or write markers. Backup mode never initializes storage or publishes markers. Compose does not run gates or marker publication. Reset, purge and compaction preserve an existing marker.
- Services validate their data after startup and report data they cannot use. Storage-format changes must update the owning service's migration and behavior tests; backup tooling verifies only archive safety, inventory integrity and copying.
- Test exact maintenance routes through the real router, including supported trailing slashes and opaque IDs. Inventories must be complete, distinct and ordered; purge/compaction must tolerate retries.
- Keep maintenance private and backup-only, test resets testing-only, and denied operations non-mutating. Health probes remain available in every mode.
- Quiesce background writers and flush durable state before clean exit. Test every built container as PID 1 with SIGTERM and its image `STOPSIGNAL`, including wrappers and sidecars.
- Verify authoritative data survives same-release restart/restore. Derived services must rebuild from empty storage and fresh consumers, remain not-ready after failed rebuilding, and process subsequent changes.
- Keep credentials and application records out of diagnostic logs; store data-bearing manifests privately.
- Verify reads through actual routes, not rollout status alone. Bound readiness/convergence waits; never blindly replay mutations or reopen clients after failed recovery.

### Snapshot capture

The `backup-run`, `backup-enter`, `backup-capture`, `backup-exit`, `restore`, `deploy`, and `storage-reattach` operations coordinate through the same `recipe-db-deploy` Lease in `kube-system`, outside the replaceable application namespace. They do not expire or automatically steal a Lease. Backup validates the explicit target/context, immutable release digest/revision, actual project container images, deployed runtime Secret, selected PVC identities, ownership and destination capacity. Backup and recovery require the release commit locally and unchanged metadata/template inputs relative to it; untracked inputs are refused, while unrelated checkout changes are allowed. This binds the authoritative inventory and cleanup definition to the release without fetching or executing another checkout. Preflight requires selected PVC requests plus 64 MiB staging headroom; because local-path requests do not enforce a quota, capture also measures each stopped PVC's exact tar byte count before copying and requires actual free space plus the same headroom. This includes sparse-file expansion and previously copied archives. It does not read the configured application secret files. The snapshot validator requires Python 3 with its standard library.

For a Pi release, use the uploader's maintenance path rather than chaining standalone lifecycle commands. `maintenance-enter` disables and stops `recipe-db-backup.timer`, refuses an active backup service, and runs `backup-enter`; the operation lock, application barrier and recovery state remain. Starting `recipe-db-backup.service` then runs `backup-capture` under that same Lease, validates the completed snapshot and uploads it. The service verifies remote readback before reporting `verified-upload` or `verified-unchanged`; it leaves the captured state, lock, barrier and disabled timer intact. A later service start retries upload from the retained snapshot without capturing again. Candidate staging retains the original runtime credentials in a private file beside the operation directory before replacing the runtime Secret; its parent must be operator-owned and not writable by other users. That file is not part of the snapshot or upload inventory. Complete migration recovery requires that backup-ID/source-bound copy and matching operator configuration; it never infers previous credentials from the staged Secret. Successful release finalization or `backup-exit` removes the retained credential file; uploader archival moves any remaining copy into that operation's private history rather than leaving it for a later operation. Separately approved recovery reopening is terminal only after ownership release is recorded; the uploader then reports maintenance inactive and can archive the operation before the next capture. The release cookbook gives the operator commands and success checks. Recovery-required status must be resolved using the original state directory and explicit holder confirmation; do not start a fresh operation or release the Lease.

Run only during an approved maintenance window, from a trusted workstation with the explicit target values file and a private destination filesystem. This operation changes runtime modes, briefly stops backend workloads and transfers application data; do not point it at a live Pi or production cluster during development or tests.

```sh
VALUES="$PWD/.secrets/local-values.yaml"
RELEASE='ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-artifact-digest>'
SNAPSHOT="$PWD/.backups/recipe-db-$(date -u +%Y%m%dT%H%M%SZ)"
umask 077
mkdir -p "$PWD/.backups"
mise run production-k3d backup-run "$VALUES" "$RELEASE" "$SNAPSHOT"
```

The operation stops and drains the normal GraphQL Pods first, then raises the `MODE=backup` barrier before touching data backends. GraphQL drains active connections for at most 20 seconds; backend and API Pods have a 120-second termination grace period as an upper bound; every service container must still exit cleanly on SIGTERM (as PID 1 it needs an explicit handler or `trap`). Image `STOPSIGNAL` overrides also apply: the nginx-based search readiness sidecar handles both TERM and QUIT. A resource-versioned Pod watch must observe normal termination; a missing termination record, failed drain, OOM or SIGKILL prohibits capture. It stops normal backend/projection workloads before bringing up any authoritative backup-mode backend. The rendered `backup-cleanup` Job runs once: its existing worker retries each retryable operation once plus two retries, without repeating permanent failures or duplicating cleanup logic. Completed purges are not rolled back on failure.

After cleanup, all remaining data writers terminate before role-selected PVCs are exported with temporary read-only copy Pods. `.project.yaml` supplies `backupRole` and `storageVersion`. Capture archives each complete volume and inventories regular files by relative path, size and SHA-256; it does not inspect application formats or decide whether a service can use its data. It validates marker syntax when present, includes the marker bytes in the inventory, and never creates or upgrades one. Unversioned archives remain recognizable for recovery compatibility. Links, special files, duplicate or unsafe paths, and incomplete or corrupt copies are rejected. Derived/external caches, logs, container images, OS/k3s state and secrets are excluded. No archive is published if cleanup, termination or copy validation fails.

A complete snapshot is identified only by `manifest.json` (`format: recipe-db-pvc-snapshot`, `formatVersion: 1`). It records `backupId`, `startedAt`, `capturedAt`, `completedAt`, `source` (`target`, `cluster`, `context`, `namespace`, immutable `artifact`, `revision`) and `inventory`. Each inventory entry contains `service`, `role`, `pvc`, `storage`, `archive`, `sizeBytes`, `fileCount`, `sha256`, `files`, `directories` and `directoryMetadata`; `storage` records the selected PVC identity and capacity. Each regular-file entry has its archive-relative `path`, `sizeBytes` and `sha256`; `directories` lists archive-relative directory paths, including empty directories. `directoryMetadata` records each explicit directory's path, mode and numeric ownership, including the archive root. Historical snapshots may omit these directory fields. Archives are `<service>.tar`, with no secrets or outer packaging. The publisher verifies archive and file hashes and rejects unsafe paths, links and special files. Staging directories are created privately, never overwritten or recursively removed by the lifecycle.

### Verified remote packaging

The publisher consumes only that complete snapshot directory; it does not capture PVCs or infer service layouts. It rechecks the lifecycle manifest, every archive SHA-256, every regular-file size/hash, path safety and snapshot completeness before packaging. Capture and publication reject snapshots exceeding 100,000 regular files across all volumes or 100,000 directories in one volume, including implicit parent directories, as well as archive members with special permission bits, extended headers or invalid numeric ownership; restore applies the same limits and rules. The uploaded `<deployment>-<capturedAt>-<backupId>.tar.gz` is an ordinary gzip-compressed tar containing `manifest.json` and the service `.tar` files in sorted order. Outer tar metadata is normalized (mtime, owner, group and mode) and the gzip timestamp is zero. Its sibling `.manifest.json` uses `format: recipe-db-backup`, `formatVersion: 1`, and records deployment/backup IDs, capture order, the original release identity and snapshot manifest, a content fingerprint, and the archive name, byte size and SHA-256. Restore verifies package integrity and generic file inventories before importing complete volumes; historical `layout` metadata is accepted only for package-integrity compatibility and is ignored during restoration.

The change fingerprint includes snapshot format/version, immutable release artifact and revision, each service/role/PVC/archive identity, sorted file paths, sizes and hashes, and directory paths, modes and numeric ownership when recorded. It deliberately excludes backup IDs and capture timestamps. A release-only change therefore publishes a new point, while repeated identical data can be skipped only after reading back and hashing both files from the prior verified remote point. A missing or corrupt remote baseline causes a new upload rather than a false unchanged result. Archive then manifest are copied as individual files with `rclone copyto` (never `sync`); the manifest is the final completion marker. Both files are read back and SHA-256 checked before the local baseline advances. Temporary packaging space is bounded by the configured `maxStagingBytes` (8 GiB by default); there is no local upload queue. A failed transfer preserves the prior baseline. Retention runs only after a verified upload, keeps the newest 30 complete points by `capturedAt`, and deletes only pairs whose deployment ID and manifest/archive identities verify. Pruning errors leave the verified new baseline intact and are reported separately.

The provisioning playbook installs rclone 1.75.2 from its versioned ARM64 package with a pinned SHA-256 and copies the root-only local kubeconfig to `/etc/recipe-db/backup-kubeconfig.yaml` under context `recipe-db-pi`. It installs a `recipe-db-backup.service` and local-time `02:15` timer with up to 15 minutes of jitter. `Persistent=false` means missed occurrences are skipped, not replayed as backlog snapshots. A service lock prevents overlapping runs; the two-hour service timeout bounds capture and publication. Base provisioning leaves the timer stopped and disabled. The timer's presence or enabled state is not backup health.

Prepare `backup.json` under `~/.config/recipe-db/backup/` and install it with `backup-configure.yml`; the playbook places it at `/etc/recipe-db/backup.json` mode `0600`. It must contain `deploymentId`, `remote` (for example `gdrive:recipe-db-backups`), `rcloneConfig` (`/etc/recipe-db/rclone.conf`), `stateDirectory` (`/var/lib/recipe-db-backup`), `stagingDirectory` (`/var/lib/recipe-db-backup/work`), `captureCommand` (`/usr/local/sbin/recipe-db-backup-capture`), `captureTimeoutSeconds` and optionally `maxStagingBytes`. Ordinary capture passes one argument: a new absolute destination directory. It invokes the lifecycle child's `production-k3d backup-run` operation with the same explicit Pi values, context `recipe-db-pi`, and deployed immutable release, then returns success only for a complete snapshot at that directory. Keep the clean tooling checkout at `/opt/recipe-db` and use the Ansible-managed isolated Mise environment; the wrapper loads application metadata from the backed-up release's own Git revision. The service supplies `KUBECONFIG=/etc/recipe-db/backup-kubeconfig.yaml`. Do not copy kubeconfigs, release credentials or deployment secrets into the snapshot. The publisher suppresses subprocess output and emits only stable status codes; it never prints rclone configuration, remote content or capture-command output.

Canonical Ansible provisioning installs `/usr/local/sbin/recipe-db-backup-capture` and its isolated checksum-pinned Mise/capture tools without repository development hooks. Set `backup_capture_revision` in the private inventory to the reviewed full tooling commit to manage `/opt/recipe-db`; an empty value does not select or update a checkout. Outside a release this normally matches the deployed revision; the release cookbook prepares candidate tooling separately before downtime. The command reads operator-installed `/etc/recipe-db/backup-values.yaml` and `/etc/recipe-db/backup-release-ref`, then invokes the guarded lifecycle. Use this managed command as `captureCommand`, rather than manually installing host tooling. The selected visible My Drive destination is `gdrive:RecipeDB Backups`. See [production configuration and recovery](production-configuration.md) for private file ownership and recovery. After restore and acceptance, run `backup-configure.yml` to install the operator-prepared recovery inputs and referenced application secrets; it records a private configuration-generation timestamp only after successful installation. Start and verify one explicit capture after that timestamp; only then run `backup-enable.yml`, which requires a verified status with a later `lastCheck` before enabling the timer.

The focused [checkout-maintenance playbook](../provisioning/maintain-checkout.yml) reuses the provisioning checkout task without unrelated host provisioning. It requires an explicit full `checkout_revision` and an idle backup service, and leaves the timer disabled. During retained maintenance it additionally requires `checkout_maintenance_holder` to match the saved operation, preserves any recorded tooling pin, and refuses an active process or retained workstation file claim. Ordinary provisioning still refuses retained maintenance. The managed wrapper uses Git release sources: the tooling checkout remains pinned while backup metadata comes from the immutable artifact's own revision.

For routine releases, follow the [release cookbook](production-release-cookbook.md). Before maintenance, `release-prepare.yml` installs the managed tools, publisher and bounded private metadata helper. Normal release control stays on the workstation; the Pi state remains authoritative and each progress update is written through atomically, guarded by a private command claim and a state comparison. After explicit reopening and website checks, `release-backup-align.yml` checks the exact holder and candidate before changing only the backup reference and configuration-generation timestamp. Private values and application inputs remain unchanged. The existing `recipe-db-backup.service` then captures the candidate, uploads and reads it back through its shared backup implementation. Failed uploads retry without recapture. Acceptance, publication and finalization follow remote verification; only then may the timer be enabled. Previous-release state and retained credentials survive until finalization. No workstation archive transfer or separate manual capture/upload sequence is required.

Create and authorize `/etc/recipe-db/rclone.conf` interactively on the Pi with the dedicated operator-owned Google account; keep it root-owned, mode `0600`. Follow the [Drive authorization cookbook](google-drive-authorization.md), using the Desktop OAuth client stored in operator home and a private SSH browser tunnel. The authorized config stays on the Pi, where rclone refreshes its tokens. `backup-configure.yml` checks its permissions but never copies, replaces or retrieves it. Routine updates and application restores keep this authorization; a fresh host rebuild or lost/broken authorization requires interactive login. Never put OAuth tokens in operator home, chezmoi, backup JSON, command arguments, source control, application backups or service logs. Retain the protected account-recovery method independently of the Pi and workstation. Lost authorization does not invalidate already verified Drive points.

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

Restore is recovery at the backup's recorded immutable application release, not an upgrade or in-place repair. It requires an explicitly identified local k3d or Pi k3s target with empty application storage. On a newly provisioned target, never deploy the normal application first: initialization populates databases and derived volumes. Restore itself never wipes, merges or overwrites existing data.

For an existing cluster, including a healthy idle site, a retained failed-release operation, or a failed restore, follow the [existing-cluster restore cookbook](production-existing-cluster-restore.md). It separates failed-release closeout, explicitly approved application-data reset, and the unchanged empty-storage restore. Use that cookbook when restore reports that storage is not empty; do not bypass the check. This preserves the Pi, K3s, HTTPS state, configuration and backup authorization. Use the [Pi rebuild cookbook](raspberry-pi-rebuild.md) instead when the host is lost or its integrity or disk is suspect.

To retrieve the current verified backup for a workstation rehearsal, run this from your workstation checkout, including from fish. Choose a **new** destination directory under an existing parent with no symlink components:

```sh
mkdir -p "$HOME/.local/share/recipe-db"
mise run --raw retrieve-verified-backup "$HOME/.local/share/recipe-db/rehearsal-backup"
```

The command uses the operator SSH key and verified host keys under `~/.config/recipe-db/ssh/`, connecting to `piadmin@recipe-pi.home` by default; pass `--pi user@hostname` to select another Pi. Keep `--raw`: SSH may request the key's passphrase, and Mise must leave the command in the terminal foreground for that prompt. One authenticated SSH connection is shared across all steps and closed on success or failure, so the key needs unlocking only once. Its temporary control socket is kept in a private local directory; no key passphrase is saved. If sudo requires authentication, a separate `Pi sudo password` prompt requests the Pi login password, not the SSH key passphrase. The password stays in process memory for this invocation and is sent only through encrypted SSH standard input, never command arguments or files. The Pi must already have the configured backup uploader, Python 3, rclone, working Drive authorization and sudo permission.

Success prints JSON containing `backupId` and absolute `manifest` and `archive` paths. The command requires a healthy, non-overdue uploader check, selects the exact verified baseline (including for `verified-unchanged`), and streams both files from Drive through SSH without staging backup files on the Pi or copying authorization. It verifies baseline hashes, manifest identity and archive size/hash, then rechecks backup health and baseline identity before publishing the local pair. If the baseline changes, rerun the command. No manual backup-ID confirmation is needed.

The destination has mode `0700` and files have mode `0600`. Existing destinations and destination symlinks are refused; failed or interrupted transfers are not published as completed downloads. This retrieves an existing backup only: it does not capture, upload, delete, prune, restore or start a rehearsal. Drive reads may refresh the Pi's authorization. Keep these production-data files private and out of shared logs and CI artifacts.

For a selected historical restore point, first inspect the complete remote points with `--catalog`, then retrieve the exact ID directly to a new private workstation directory. This option does not require the latest uploader status to be healthy or recent, and never falls back to another point:

```fish
mise run --raw retrieve-verified-backup --catalog
set -l BACKUP_ID '<exact-backupId-from-catalog>'
mkdir -p "$HOME/.local/share/recipe-db/rehearsals"
and mise run --raw retrieve-verified-backup --backup-id "$BACKUP_ID" \
  "$HOME/.local/share/recipe-db/rehearsals/backup-$BACKUP_ID"
```

The selected package's identity and manifest are checked, and the archive and manifest are streamed over the existing authenticated SSH connection and verified before publication. Missing, ambiguous, incomplete, changed or corrupt points fail without leaving a download. Backup files are never staged on the Pi; only read-only Drive access is used, which may refresh authorization.

If the original Pi is unavailable and no verified package was downloaded beforehand, provision the replacement Pi and [authorize Drive interactively there](google-drive-authorization.md#1-authorize-on-a-new-pi) before retrieving the backup. Recovery no longer depends on an authorized rclone config in the workstation or encrypted dotfiles.

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

All file arguments are absolute. The values file explicitly selects target, context, namespace, storage and workstation-held secret inputs; confirmation binds the operation to the selected backup identity. Preserve the original package/manifest pair. Restore validates the supported package/snapshot formats, release identity, archive and file sizes/SHA-256 hashes, and complete metadata-derived authoritative inventory. It treats each volume as opaque, accepts historical `layout` metadata only while verifying package integrity, and ignores it when restoring. Links, special files, duplicate entries and unsafe paths are refused. Validation stages complete volume archives privately, never extracts arbitrary paths into the target; application services validate their own data after startup.

The recorded release artifact and every application image must remain available. The corresponding release commit and unchanged render inputs must be present locally, and all configured secret inputs must be supplied independently; secrets are not recovered from backup. The accounts file must include an explicit owner bearer token for the private create/update/delete propagation probe. The probe uses only its own new recipe, verifies search and browse changes, and removes that recipe before completion; an interrupted probe's identity is retained in recovery state. No mutable image tag, replacement release, application build or implicit upgrade substitutes for a missing prerequisite. Pi restore retains the provisioning/storage-identity safeguards above; this command does not provision or reimage a device.

After rendering the recorded release, restore applies the Traefik LoadBalancer exposure policy without changing application images or historical render inputs. It disables NodePort allocation and removes any already allocated NodePorts before importing data. It checks the resulting Service again before reopening ingress.

The shared cluster-scoped Lease excludes deployment and capture. Fresh-target inspection refuses populated authoritative, derived and external-cache storage. Application writers remain stopped during data import. Public GraphQL remains blocked while the private trusted-ingress query route permits full search rebuilding. Browse's recorded image hardcodes `http://traefik/graphql`; restore must route that internal service alias to the private entrypoint without opening the public Traefik service, rather than relying on a `GRAPHQL_URL` environment override. NATS, Typesense, search/checkpoint, browse and external caches start fresh; upstream websites are not recovery prerequisites. Completion requires successful service startup, search readiness, representative black-box reads and observable change propagation before application access reopens. The read check inspects images for up to ten recipes in ID order and requires HTTP 200 and nonempty bodies for both image URLs; if none in that sample has an image, image delivery is not checked. Relative image URLs and absolute URLs on the configured origin are checked through private ingress; off-origin URLs are rejected rather than contacted.

On a fresh Pi, restore runs the guarded storage preflight and creates the retained StorageClass before applying Traefik infrastructure. HTTPS needs this class for its separate ACME certificate PVC and the private ACME contact Secret, which deploy and restore both install before starting Traefik.

Cache expiry alone is not propagation evidence: browse's cache expires after one minute. Before reopening access, the verification requires an ETag on priming responses, observes changed browse results before the primed entry can expire and waits separately for search convergence. If priming needed retries, the check lets any possibly cached response expire before priming a fresh entry. If search convergence takes long enough that the observed cache may have expired, the check waits until its expiry and primes a fresh entry before verifying another update and deletion. Search deletion is verified using the index's matching count.

A nonzero exit is never a partial success. After target mutation, preserve the private restore state directory and the Lease and leave access blocked. Inspect the saved phase, explicit target/context and `lock-status` before any operator action. Do not use `backup-exit`, ordinary deployment, a forced lock deletion or a second restore to open or overwrite a partial target. Stop any surviving operator process and isolate the failed target: stop all Deployments and restartable controllers, suspend Jobs/CronJobs, remove only stopped worker/helper Pods, and retain the public routing barrier. `restore-abandon` releases the exact retained Lease only after checking the saved target/configuration, workload isolation and routing barrier; it does not delete data or reopen access:

```sh
mise run production-k3d restore-abandon "$VALUES" "$STATE_DIRECTORY" \
  "$HOLDER" "ABANDON-$HOLDER-AFTER-ISOLATION"
```

Abandonment does not make partial volumes reusable. Collect any investigation evidence by hand before discarding data, then either select another genuinely fresh target or follow the separately confirmed [existing-cluster reset procedure](production-existing-cluster-restore.md). Automated failure tests are not evidence of a live Pi recovery. The integrated disposable-k3d rehearsal belongs to #108, and operator-approved Drive/Pi acceptance to #107.

### Failed migration recovery

`release-migration-recover` is a separate, destructive recovery for a failed or uncertain step-6 migration under the original release operation. It requires the exact retained target/context, `recipe-db-deploy` Lease, migration failure state, candidate identity and remotely verified complete pre-migration backup. The supplied package must match the retained coordinated snapshot manifest, original release, and every service in its inventory. The previous immutable release, pinned images, current configuration and matching runtime credentials must all be available before storage can be cleared. Before clearing, the command makes the cluster pull every previous-release workload and infrastructure image with `imagePullPolicy: Always`; an unavailable image fails preflight while application data remains untouched.

The command refuses standalone restore's fresh-target guards only for this exact lifecycle operation. It validates existing application ownership and exact bound PVCs, checks all current storage users are terminated and no remaining Pod mounts a configured application PVC, and retains the original Lease throughout. It then installs a private route barrier on every configured public HTTP/HTTPS entrypoint, preserving internal routes, clears only entries under the configured owned PVC data roots, verifies every destination is empty, and runs the normal complete import, rebuild, read, propagation and readiness checks against the previous release. It does not replace PVCs, delete credentials/configuration/backups, stamp storage versions, resume migrations, or preserve the failed dataset. The candidate is recorded as aborted.

Failure/interruption stops application and recovery workers, attempts to restore the public barrier, and retains inspectable phase state and Lease ownership. A second attempt is permitted only after workers are confirmed stopped and the complete backup and ownership are revalidated; it clears every configured destination again before importing. A partial import is never merged or resumed. If termination or barrier safety is uncertain, status recommends inspection rather than retry. A successful recovery leaves GraphQL in backup mode and public routes blocked. Only the separate `release-recovery-reopen` command, with the exact previous artifact and a second operator confirmation, restores normal ingress and releases the Lease. This path is not a general overwrite option or post-reopening rollback; never use it after public writes resume. The production procedure and exact commands are in the [release cookbook](production-release-cookbook.md#recover-a-failed-or-uncertain-migration).

## Operator configuration and secrets

The [configuration and recovery guide](production-configuration.md) is authoritative for the private directory, operator-managed files, generated state, ephemeral credentials, and recovery boundaries. Production values reference private inputs by absolute path. Deploy and restore generate fresh GraphQL ingress and Typesense credentials, create the cluster Secrets, and remove temporary copies. They are never supplied by the operator or stored in the repository. Repository `.secrets/` files are for development and disposable local rehearsals, not production inputs.

Google OAuth uses a public client ID and operator-held client/cookie files. Keep the provider redirect URI aligned with the configured HTTPS origin. Do not disable authorization or weaken the account policy to make a rehearsal pass.

The local protocol smoke requires a private owner bearer-token file whose token is explicitly present in the configured account policy. It does not mint credentials or create accounts. Successful create/update/image/delete operations verify deployed authorization; a local file match alone is not evidence that the policy is active. Keep smoke credentials in the private operator directory and revoke temporary principals after use.

## Create, render, deploy and inspect

### Production HTTPS on the Pi

Every Pi values file requires an HTTPS origin matching the configured hostname. The `https` object contains only the hostname:

```yaml
origin: https://your-hostname.example.org
runtime:
  trustedIssuer: https://accounts.google.com
https:
  hostname: your-hostname.example.org
secrets:
  acme-account-email: deployment/acme-account-email
```

Store the dedicated ACME contact mailbox in a private mode-0600 file. HTTPS deployment validates it and stores the address only in the private `recipe-db-acme-contact` Secret in `kube-system`; manifests reference the Secret key, not the address. Contact changes roll Traefik consistently. Keep the contact file in private recovery sources; never put its contents in issue evidence or unrestricted logs.

Pi always uses the Let's Encrypt production CA and serves the application on HTTPS. HTTP-01 challenges use Pi TCP 8081; ordinary HTTP requests redirect to HTTPS on TCP 8443. The Pi deployment renders a Traefik Service exposing only those two ports. Its internal web entrypoint remains available through the `recipe-db-internal` ClusterIP Service on port 80, targeting Traefik port 8000. The firewall template removes private-LAN TCP 80/443 application allowances; keep `application_networks` for discovery, and use the existing `public_https_enabled` opt-in for the public HTTPS firewall and Kubernetes DNAT rules. Forward router TCP 80 to Pi TCP 8081 and router TCP 443 to Pi TCP 8443 only after inspecting the deployed listeners. Do not forward to Pi TCP 80, open SSH/Kubernetes/backend ports, flush nftables, or publish an unverified IPv6 record. These source changes do not alter the live Pi, router or host firewall; deployment does not change the router or host firewall, and the separately approved cutover procedure governs live changes.

The existing application routes—including browse, design, PWA, public images, GraphQL, editors, and MCP—use the configured hostname and production TLS. `/pwa/` serves the public manifest and icons. OAuth remains optional; when configured, only `/oauth2/start`, `/oauth2/callback`, `/oauth2/sign_in`, and `/oauth2/sign_out` are exposed. Bearer-authenticated GraphQL requests retain priority over cookie-authenticated requests. Public GraphQL strips untrusted identity headers before injecting the private ingress token. Backend REST, maintenance/reset, and administration interfaces remain private.

Authorization comes from the accounts policy, not an HTTPS exposure flag. For anonymous-only access, keep `anonymous.role: anonymous`, `tokens: []`, and `googleAccounts: {}`; GraphQL enforces permissions. Deployment does not impose a role or token-count policy. Editors and MCP can load/read according to the policy but cannot exceed GraphQL's existing capability guards. The internal GraphQL routes and backend listeners remain unchanged.

Traefik automatically renews certificates while DNS and inbound challenge access remain usable. ACME account keys and certificates persist in the private `recipe-db-acme` PVC in `kube-system`, using the owned retained Pi StorageClass. Traefik runs as UID/GID 65532, uses a single Recreate deployment, and initializes `/data/acme-production.json` with mode 0600. The claim is outside application backup capture: protect it separately as private recovery material or explicitly reissue after recovery, accounting for CA rate limits. Never publish ACME files, private keys, raw Secret data, or unrestricted proxy logs.

Before acceptance, verify the trusted hostname/chain, application routes, HTTP redirect, excluded backend/admin paths, retained ACME state across redeployment, and renewal diagnostics. Inspect certificate expiry and ACME failures locally without publishing credentials; successful initial issuance alone does not prove renewal. Certificate hostnames are public in certificate transparency logs.

Existing `https-staging` placeholder resources are no longer rendered, but ordinary deployment does not automatically delete resources already applied to a live cluster. Their cleanup belongs to the dedicated cutover procedure in #398. To stop external access immediately, disable the existing router forwards and their firewall exceptions; this does not delete application data or ACME state.

#### Google sign-in on the existing HTTPS application

For operator-approved Google verification under [#68 — Set up and verify real Google authentication before public go-live](https://github.com/dhhyi/recipe-db/issues/68), reuse the existing HTTPS application exposure and trusted certificate. No separate outer login gate is required: anonymous reads remain public and GraphQL alone enforces member/owner permissions.

With Google settings absent, anonymous reads and configured bearer tokens continue to work; the sign-in link is omitted. To enable Google login, add the complete optional configuration to the private Pi values:

```yaml
origin: https://your-hostname.example.org
runtime:
  googleOAuthClientId: YOUR-CLIENT-ID.apps.googleusercontent.com
  trustedIssuer: https://accounts.google.com
infrastructure:
  oauth2Proxy: quay.io/oauth2-proxy/oauth2-proxy:<reviewed-tag>@sha256:<reviewed-digest>
  redis: redis:<reviewed-tag>@sha256:<reviewed-digest>
volumes:
  redis: 256Mi
secrets:
  google-oauth-client-secret: deployment/google-oauth-client-secret
  oauth2-cookie-secret: deployment/oauth2-cookie-secret
https:
  hostname: your-hostname.example.org
```

The origin must exactly match `https://` plus the configured hostname, without a port suffix. The production CA and application HTTPS routes are always enabled on Pi, with or without Google settings. Register this origin's `/oauth2/callback` in the Google web client. Use a fresh cookie key and the actual Google client secret. The client ID and both secret paths must be present together; partial or invalid configuration fails explicitly. Never put the downloaded credential JSON, secret values or session cookies into reports or Git.

This deploys OAuth2 Proxy alongside Redis and retains the existing ACME claim and listener layout. HTTPS reuses the existing optional-authentication GraphQL routers, preserving bearer-first priority without cookie fallback. It also exposes only `/oauth2/start`, `/oauth2/callback`, `/oauth2/sign_in` and `/oauth2/sign_out`, not `/oauth2/auth` or other proxy endpoints. Untrusted identity headers are stripped before authentication and trusted ingress injection. Backend REST, maintenance/reset and administrative routes remain private, with no new public ports or NodePorts. To disable Google login, remove the client ID, both OAuth secret paths, optional OAuth/Redis images, and `volumes.redis`, then redeploy; the deployment removes its owned OAuth workloads and routes without changing application exposure or GraphQL authorization.

Keep `anonymous.role: anonymous` and existing accounts intact. Google registration does not grant application privileges: configure only operator-approved normalized emails as `member` or `owner` in the private `googleAccounts` map. An empty map grants no Google account elevated access. Do not assign roles or enable bearer credentials merely to make a deployment check pass.

After deployment, verify real-browser login, callback and logout on the HTTPS hostname, Secure/HttpOnly/SameSite=Lax cookies, member/owner boundaries, denied accounts, bearer precedence and refresh/revocation behavior. The supported Pi application path is HTTPS; private-LAN application HTTP is removed from the new baseline. These source changes do not retire a listener on an already deployed Pi; live changes belong to the separately approved cutover. Automated rendering/routing tests are not evidence of real Google consent or refresh. To stop external access immediately, disable the existing router forwards and their firewall exceptions; this does not delete application data, Redis or ACME state.

Inspect Traefik's local ACME diagnostics for `Renewing ACME certificate` and `Error renewing ACME certificate` without publishing raw logs. Failed renewal can leave the currently valid certificate served, so HTTP 200 alone is not renewal success. Restore DNS/challenge reachability and retry under controlled operator supervision; do not repeatedly restart against the production CA or delete account/certificate state to bypass a failure.

#### HTTPS certificate operations and recovery

For private ACME recovery, copy `/data/acme-production.json` from the owned PVC into a mode-0700 operator directory with a mode-0600 file while no renewal is writing it. Validate the JSON and certificate/private-key correspondence locally, confirm repeated source copies agree, and protect this material separately from application backups. Before a real restore, stop the single Traefik writer, verify the selected cluster/PVC/node identity, preserve existing state, restore the exact file as UID/GID 65532 with mode 0600, then restart Traefik and verify normal trust and expiry. Rehearse the byte/permission-preserving restore in a separate private path without overwriting live state. If recovery material is absent or compromised, explicitly reissue; account/key loss, authorization reachability and CA rate limits can delay recovery. Do not imply that the application snapshot contains the ACME PVC.

### Local HTTP rehearsal

Local rehearsals remain HTTP-only and use target `local` with `deploy/local.yaml`; do not add `https` or Pi HTTPS settings to local values. The production configuration validator rejects those settings on local targets. Continue to use the managed local k3d workflows for isolated rehearsals and interactive inspection; Pi application access uses its configured public HTTPS hostname.

### Bundled Traefik configuration

The application objects live in `recipe-db`. The intentional infrastructure exception is the bundled Traefik `HelmChartConfig`, its route Secret, and its internal metadata Service in `kube-system`. There is **one** bundled Traefik with a file provider, not a second ingress controller or a parallel hand-maintained application route list. Routes, priorities, strip-prefix middleware, OAuth forward-auth, identity-header stripping and internal GraphQL ingress-token injection retain their project-metadata definitions. The internal metadata port is cluster-only; router/service discovery does not expose raw route configuration, middleware configuration, dashboards or credentials publicly.

`infrastructure.traefik` overrides the bundled controller's image via `HelmChartConfig` to the digest-pinned reference from the deployment values. Use the image's explicit patch version in the tag, such as `traefik:v3.7.16@sha256:...`: the bundled chart reads the tag for compatibility checks and interprets `v3` as 3.0, even when the digest identifies a newer image. The digest updater preserves tags and does not discover newer Traefik versions; when upgrading Traefik, update the tag in both deployment values and the Compose source template, then verify that the resolved digest identifies that version. Traefik 3.7 or later is required for authentication header-alias sanitization. This upgrades the same bundled controller, not an additional ingress deployment.

When selecting or upgrading k3s or Traefik, verify that the k3s-bundled Traefik chart accepts the configured image version and that the version supports the configured features. Chart version checks do not inspect the digest. Test the combination in a rehearsal before production: k3s v1.35.6's bundled chart rejects Traefik 3.7.16, whereas the chart bundled with v1.35.10 accepts it.

Existing private deployment and backup values using a generic Traefik tag must be updated to the verified explicit version of the same pinned image before deploying or restoring. Preserve the digest and all other settings; coordinate the Pi's installed backup inputs through the documented backup-configuration procedure, never during retained maintenance. Historical release templates also consume the supplied private values, so this is required when restoring older releases.

### Check Traefik after a K3s upgrade

K3s updates its desired Traefik chart separately from the running controller. A healthy existing controller, a ready node, or a completed Helm job does not prove that the new chart was installed. An install job can exit successfully after skipping an upgrade because its expected release revision does not match the current revision.

With the Pi API tunnel open and `VALUES` and `KUBECONFIG` set as in the [release cookbook](production-release-cookbook.md#prepare-the-workstation), run these read-only checks on the workstation in fish:

```fish
set -g PI_CONTEXT (mise exec -- yq -er '.context' "$VALUES")
and test -n "$PI_CONTEXT"
```

Stop if either command fails. Use that context for all checks:

```fish
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get helmchart traefik traefik-crd -o json \
  | mise exec -- jq '[.items[] | {name: .metadata.name, chart: .spec.chart,
      job: .status.jobName, conditions: .status.conditions}]'
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get deployment traefik -o json \
  | mise exec -- jq '{chart: .metadata.labels["helm.sh/chart"],
      images: [.spec.template.spec.containers[] | select(.name == "traefik") | .image]}'
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system rollout status deployment/traefik --timeout=60s
```

Verify the installed CRD chart version without printing the release's other contents:

```fish
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get secrets -l owner=helm,name=traefik-crd,status=deployed -o json \
  | mise exec -- jq -er '.items | if length == 1 then .[0].data.release else error("expected one deployed release") end' \
  | base64 -d | base64 -d | gzip -dc \
  | mise exec -- jq -es 'if length == 1 and .[0].info.status == "deployed"
      then {status: .[0].info.status, chart: .[0].chart.metadata.version}
      else error("invalid deployed release") end'
```

Stop if this command fails or does not print exactly one deployed chart version. If the HelmCharts report `helm-install-traefik` and `helm-install-traefik-crd` as their jobs, inspect both statuses and logs locally:

```fish
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get job helm-install-traefik helm-install-traefik-crd
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get pods -l 'job-name in (helm-install-traefik,helm-install-traefik-crd)'
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system logs job/helm-install-traefik
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system logs job/helm-install-traefik-crd
```

Compare each chart archive named by its HelmChart with the installed chart: the Deployment label for Traefik, and the deployed release version for its CRDs. The Deployment label uses `_` where the archive version uses `+`. Require both versions to match and the rollout to be ready; also compare the Deployment's image tag and digest with the intended private values. Check each HelmChart's named job and its logs for failures or a skipped upgrade, including a release-revision mismatch. If a job has multiple Pods or retries, inspect their individual logs too; the job log command may select only one Pod. Keep logs private. If a job has another name, inspect the job reported by that HelmChart instead. If either job or its outcome cannot be established, the chart versions differ, or the image or rollout is wrong, stop and investigate; do not treat the K3s upgrade as complete or retry blindly.

These checks do not prove application routing or authentication. Check the website and sign-in as described in the [release cookbook](production-release-cookbook.md#9-check-the-normal-website), without recording a release result at this stage. Verify a fresh backup before re-enabling scheduled backups.

### Deployment behavior

The driver applies the two namespaces separately. Application secret checksums include the rendered manifests and trigger workload replacement when credentials or rendered configuration change, including OAuth provider settings generated by templates. A separate route checksum in the bundled controller's pod annotations triggers a Traefik rollout when its file-provider configuration or ingress token changes; deployment waits for that exact checksum, not a previously ready controller. Identical inputs keep both checksums stable.

Deployment and the local snapshot operation use the same cluster-scoped `recipe-db-deploy` Lease. An existing Lease blocks either operation rather than being silently stolen. The backup workflow retains its Lease and recovery state if production recovery is unsafe; do not use `lock-recover` to bypass that state. Inspect the selected cluster, `backup-state.json`, Lease and workload modes/counts, then complete safe production recovery before considering manual abandoned-lock recovery.

## What the protocol smoke verifies

The four positional arguments are an absolute values path, immutable artifact reference, absolute bearer-token-file path and absolute result-JSON path. The driver must verify the managed local cluster **before any HTTP request or mutation**. The smoke deliberately refuses Pi values and non-loopback origins.

The script uses HTTP protocols, not a browser automation suite:

The public static-asset route `/design/` serves the built Storybook; it does not expose the Storybook development server. The existing `/design/styles.css` and `/design/components.js` endpoints remain available. `/pwa/manifest.webmanifest` and its PNG icons are public static assets; verify that ingress preserves the manifest's `application/manifest+json` and the icons' `image/png` content types.

1. Confirms the deployed ConfigMap artifact and revision, recording available exact client tool versions in JSON. Before its first HTTP request or recipe mutation, explicitly waits for the NATS rollout, `nats-init` Job completion, and every application's Deployment rollout. Search's index-readiness sidecar requires `/health` to report `ready: true`, not merely a listening process.
2. Creates one uniquely named recipe, reads it, updates it and reads the change. No test-only bulk-reset endpoints are used.
3. Uploads the existing JPEG fixture using GraphQL multipart Upload, reads image metadata through GraphQL, and verifies the returned public PNG and thumbnail content hashes against their URLs.
4. Waits within the configured deadline for the recipe in search, GraphQL browse data, and the actual server-rendered browse search response.
5. Checks browse, both editor HTML entry points, the Storybook page and its built JavaScript asset at `/design/`, design CSS and component JavaScript (including their same-origin hashed-asset redirects), plus the nonempty JavaScript runtime at `/design/htmx.min.js`. Requires `/pwa/manifest.webmanifest` to return HTTP 200 with `application/manifest+json`, then requires every same-origin PNG icon URL in the manifest to return HTTP 200 with `image/png`.
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
mise run --raw bazel build --action_env=PATH --jobs=1 //:shellcheck
mise run test-migrations-k3d
```

Use the supported Bazel wrapper shown above: it generates `BUILD.bazel` if missing but does not refresh an existing file. Run `mise run --raw generate-bazel-build` when current rules are required; direct Bazelisk invocation bypasses this safeguard.

`test-migrations-k3d` builds a synthetic worker and uses a uniquely named disposable cluster to verify read-only PVC inspection, suspended/activated Jobs, asynchronous execution, sequential exclusion and Kubernetes deadlines. It deletes only its own cluster and test image; on failure it retains logs for diagnosis. It uses no production values or data.
