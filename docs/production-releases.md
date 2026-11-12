# Production image releases

This guide explains the immutable GHCR release artifact produced by the `Publish` workflow for maintainers and operators validating release inventory and registry access. For the ten-step release outline, existing commands and steps that are not yet supported, use the [production release cookbook](production-release-cookbook.md).

**Table of contents**

- [Get and verify a release](#get-and-verify-a-release)
- [GHCR access and permissions](#ghcr-access-and-permissions)
- [Retry and recovery](#retry-and-recovery)

After the `Publish` workflow validates a commit on `main`, it publishes one immutable release inventory to GHCR. New inventories use schema version 2; existing schema-1 inventories remain valid for release, deployment, backup, and recovery operations. Schema 1 has no migration metadata, which does not establish that no migration is required. Production deployment is manual. Pull the inventory by its digest, not by the `sha-<revision>` discovery tag or an application's compatibility `latest` tag.

The inventory is `release.json`, pushed as an OCI artifact with artifact type `application/vnd.dhhyi.recipe-db.release.v1+json` and a JSON payload media type of `application/json`. The OCI artifact type is independent of the inventory's `schemaVersion`. In schema 2, `revision` is the full Git commit SHA, `images` contains exactly the backend, API, and frontend projects selected from `.project.yaml`, and `migrations` is a deterministic array derived from validated migrator manifests. Each image is an immutable repository digest whose index has runnable `linux/amd64` and `linux/arm64` manifests. Other non-runnable descriptors, such as attestations, may also be present.

```json
{
  "schemaVersion": 2,
  "revision": "<full-commit-SHA>",
  "images": {
    "<project-name>": "ghcr.io/dhhyi/recipe-db-<project-name>@sha256:<image-index-digest>"
  },
  "migrations": [
    {
      "service": "images",
      "fromVersion": 1,
      "toVersion": 2,
      "timeoutSeconds": 300,
      "image": "ghcr.io/dhhyi/recipe-db-migrator-images-1-to-2@sha256:<image-index-digest>"
    }
  ]
}
```

The example omits application entries and abbreviates SHAs/digests; the inventory contains the complete application membership and migration array (empty when no migrators are declared). Each migrator image reference and its service/version/timeout values must match the validated source manifest. Migrators are declared only as `migrators/<unique-safe-directory>/migration.json` with a regular sibling `Dockerfile`; the directory is the image-name suffix, not a transition selector. The manifest contains exactly `service`, `fromVersion`, `toVersion`, and `timeoutSeconds`: `service` matches `^[a-z][a-z0-9-]*$`, source and timeout are positive integers, target is at least 2 and exactly one greater than source. Repository validation requires an existing authoritative storage owner and rejects duplicate transitions or unsafe paths. Migrator images are self-contained and use `/data` for the one service data volume; they are not `.project.yaml` projects, are excluded from development/demo generation, and do not install dependencies or mount checkout scripts at runtime. Run `mise run test-migrator-packaging` to build and execute the isolated fixture image with external data and version-marker assertions; CI runs this standalone task separately from the ordinary script and project suites.

Published migrator indexes include the repository source and full revision metadata plus stable labels for artifact kind, service, source version, and target version. These labels support inventory and deliberate cleanup; they do not authorize automatic registry deletion. Do not automate source or image deletion. After accepted release closeout, consider those separate cleanup actions only when they cannot affect active releases, rehearsals, or immediate recovery; arbitrary historical-backup upgrades are not guaranteed.

The workflow publishes the artifact only after validating every application and migrator image and platform. The equivalent ORAS push is:

```sh
oras push \
  --artifact-type application/vnd.dhhyi.recipe-db.release.v1+json \
  --annotation org.opencontainers.image.source=https://github.com/dhhyi/recipe-db \
  --annotation "org.opencontainers.image.revision=$revision" \
  "ghcr.io/dhhyi/recipe-db-releases:sha-$revision" \
  release.json:application/json
```

## Get and verify a release

Use the exact `ghcr.io/dhhyi/recipe-db-releases@sha256:...` reference printed by the successful workflow. The `sha-<full-SHA>` tag is only a discovery aid:

```sh
revision=<full-commit-SHA>
oras manifest fetch --descriptor "ghcr.io/dhhyi/recipe-db-releases:sha-$revision"
oras pull ghcr.io/dhhyi/recipe-db-releases@sha256:<artifact-digest> --output release
jq -e --arg revision "$revision" \
  '(.schemaVersion == 1 or (.schemaVersion == 2 and (.migrations | type == "array")))
   and .revision == $revision and (.images | type == "object")' \
  release/release.json
```

In a checkout, `sh .scripts/validate-production-release.sh release/release.json "$revision"` additionally checks exact category-derived application membership, migration/source consistency, and immutable GHCR digest references. Pull either platform explicitly:

```sh
jq -r '(.images[]), (.migrations[]?.image)' release/release.json | while IFS= read -r image; do
  docker pull --platform linux/amd64 "$image"
  docker pull --platform linux/arm64 "$image"
done
```

Routine publication already performs these inventory and platform checks, verifies public access, and reuses a complete immutable artifact rather than overwriting it; use this procedure when independently inspecting an artifact. Candidate staging renders migrator Jobs suspended with no retries. Staging never activates them; migration selection and execution belong to the separate guarded release step.

The successful workflow verifies the inventory, both image platforms, and anonymous artifact/image access before reporting the exact artifact digest. Use that digest for deployment. For manual artifact inspection and validation details, see the workflow implementation and validation scripts.

## GHCR access and permissions

The workflow requires `packages: write` to publish the application images and release artifact. This alone does not make packages public. In the GitHub Packages settings, set every `ghcr.io/dhhyi/recipe-db-*` application package and `ghcr.io/dhhyi/recipe-db-releases` to public, and confirm anonymous pulls before relying on a release. Newly created packages may need to be made public manually; a failed anonymous verification must be fixed and the workflow rerun.

## Retry and recovery

Rerun the workflow for the same commit after correcting a failed build or registry permission. If a valid complete inventory already exists for that revision, the workflow verifies and reuses its digest rather than replacing it. A missing inventory tag allows publication to proceed, including the first push that creates the release package; authentication and network failures still abort the lookup. An invalid existing inventory fails closed for investigation. Incomplete staging image uploads do not create a release inventory.

Compatibility `latest` tags are updated only after the release inventory is complete and verified, and only while that revision is still the `main` head. GHCR updates each application's tag independently, not atomically; if a tag update fails partway through, rerun the workflow to finish it. Deployment inputs remain the artifact and image digests, not these tags. Digests do not prevent package deletion or guarantee indefinite registry retention.
