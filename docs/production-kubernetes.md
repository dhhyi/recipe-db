# Production Kubernetes deployment and local rehearsal

The production manifest renderer consumes the same project metadata and immutable multi-platform release inventory as production image publishing. It does not build images. A local, single-server k3d deployment is the first acceptance target; the Pi values file is a deployment contract, **not evidence of a validated Pi installation**. No real-cluster rehearsal or physical-device validation is implied by the presence of the scripts or their mocked regression tests.

## Prerequisites and boundaries

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

#### Manual cleanup procedure

The Job performs cleanup only; it does not acquire the `recipe-db-deploy` operation lock, change runtime modes, stop writers, or create a snapshot. Keep the lock and GraphQL client barrier until services have returned to production. Do not run these commands unless an exclusive backup window is already established.

1. Acquire the shared operation lock, enable the GraphQL client barrier, switch backends to backup mode, and wait until no other writers can access the data volumes.
2. Render the same immutable release used by the workloads, recreate the suspended cleanup Job, and resume it:

```sh
VALUES="$PWD/.secrets/local-values.yaml"
RELEASE='ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-artifact-digest>'
mise run production-k3d render "$VALUES" "$RELEASE" > "$PWD/.secrets/backup-rendered.yaml"
mise exec -- yq -o=yaml \
  'select(.kind == "Job" and .metadata.name == "backup-cleanup")' \
  "$PWD/.secrets/backup-rendered.yaml" > "$PWD/.secrets/backup-cleanup-job.yaml"
mise run production-k3d kubectl "$VALUES" delete job backup-cleanup --ignore-not-found --wait
mise run production-k3d kubectl "$VALUES" apply -f "$PWD/.secrets/backup-cleanup-job.yaml"
mise run production-k3d kubectl "$VALUES" patch job backup-cleanup --type=merge \
  -p '{"spec":{"suspend":false}}'
mise run production-k3d kubectl "$VALUES" wait --for=condition=complete \
  job/backup-cleanup --timeout=600s
mise run production-k3d kubectl "$VALUES" logs job/backup-cleanup
```

3. Continue to snapshot only after the Job succeeds. On failure, skip the snapshot and recover the workloads; cleanup already completed is idempotent and may be retried.
4. Return services to production, confirm normal readiness, then release the client barrier and operation lock.

The final command prints a private machine-readable summary that may contain recipe IDs. Delete and recreate completed Jobs before another run. This repository provides no end-to-end command for lock management, mode transitions, snapshot capture, upload, or retention.

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

Deployment uses the `recipe-db-deploy` Kubernetes Lease as coordination groundwork for backup/restore operations. An existing Lease blocks deployment rather than being silently stolen. This is **not** a complete backup locking protocol, transactional deployment, snapshot mechanism or proof that a backup is safe. Investigate an abandoned Lease and its owner before any manual recovery; do not automatically delete it to make deployment proceed.

## What the protocol smoke verifies

The four positional arguments are an absolute values path, immutable artifact reference, absolute bearer-token-file path and absolute result-JSON path. The driver must verify the managed local cluster **before any HTTP request or mutation**. The smoke deliberately refuses Pi values and non-loopback origins.

The script uses HTTP protocols, not a browser automation suite:

1. Confirms the deployed ConfigMap artifact and revision, recording available exact client tool versions in JSON. Before its first HTTP request or recipe mutation, explicitly waits for the NATS rollout, `nats-init` Job completion, and every application's Deployment rollout. Search's index-readiness sidecar requires `/health` to report `ready: true`, not merely a listening process.
2. Creates one uniquely named recipe, reads it, updates it and reads the change. No test-only bulk-reset endpoints are used.
3. Uploads the existing JPEG fixture using GraphQL multipart Upload, reads image metadata through GraphQL, and verifies the returned public PNG and thumbnail content hashes against their URLs.
4. Waits within the configured deadline for the recipe in search, GraphQL browse data, and the actual server-rendered browse search response.
5. Checks browse, both editor HTML entry points, design CSS and component JavaScript, including their same-origin hashed-asset redirects, plus the nonempty JavaScript runtime at `/design/htmx.min.js`.
6. Initializes MCP Streamable HTTP, sends its initialized notification and calls the allowed read-only `get_recipe` tool; no MCP write capability is assumed.
7. Asserts HTTP 404 for representative private REST, NATS, Typesense, monitoring and Kubernetes paths: `/recipes`, `/ratings`, `/inspirations`, `/search/reindex`, `/varz`, `/jsz`, `/collections`, `/metrics`, `/healthz` and `/api/v1/namespaces`. Also denies Traefik metadata/configuration endpoints, dashboard and `/oauth2/auth`. These use non-HTML requests, not maintenance-page fallbacks.
8. Saves browse's exact replica count, scales only browse to zero, and waits for browse HTML's maintenance 503, comparing its body with the actual bundled maintenance page rather than accepting an unrelated HTML error. GraphQL, an initialized MCP read, images, both editors and design assets must still work. It restores the original replicas on success **or failure**.
9. Discovers persistent Deployments from live PVC volume references, restarts each with bounded rollout waits, and reapplies the identical release. This covers the configured recipes, images, ratings, inspirations, image-inline, link-extract, NATS, Typesense, search and Redis persistence without a second application-name list. The own recipe, image bytes, search and browse must survive.
10. Deletes only the smoke-created recipe and verifies its absence.

An EXIT handler attempts deletion of that specific recipe after a failure and reports whether cleanup succeeded; it never deletes other records or the cluster. Interrupted or unreachable services can make cleanup impossible: inspect the record ID in the result and remove only that record once service is restored. The cluster remains available for diagnosis after both success and failure. Normal API deletion/eventual downstream cleanup semantics apply; this is not a whole-database reset or a storage leak/compaction test.

The JSON result contains `success`, `phase`, completed checks, artifact, revision, timestamps, own recipe ID, image URL/hash, cleanup status and available tool versions. Preserve it as rehearsal evidence only after checking it is suitable for publication. A failed exit is a failed rehearsal, even if some checks passed. This tests pod replacement and manifest reapplication, not cluster recreation, power-loss recovery, host reboot, physical USB reliability, TLS/browser OAuth, backup restoration or multi-node high availability.

## Storage, Pi adaptation and destructive deletion

Both values files use independent `ReadWriteOnce` PVCs and the default k3s `local-path` storage class. On a Pi the default provisioner directory is `/var/lib/rancher/k3s/storage`. The target Pi uses the **same 128 GB USB device** for its OS and this directory; this plan does not require or imply a separate SSD, host bind mount, or custom `/mnt/ssd` mount.

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
