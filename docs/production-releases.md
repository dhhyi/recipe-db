# Production image releases

After the `Publish` workflow validates a commit on `main`, it publishes one immutable release inventory to GHCR. Production deployment is manual. Pull the inventory by its digest, not by the `sha-<revision>` discovery tag or an application image's compatibility `latest` tag.

The inventory is `release.json`, pushed as an OCI artifact with artifact type `application/vnd.dhhyi.recipe-db.release.v1+json` and a JSON payload media type of `application/json`. Its `schemaVersion` is `1`; `revision` is the full Git commit SHA; `images` contains exactly the backend, API, and frontend projects selected from `.project.yaml`, each addressed by an application repository digest. Each digest identifies an index with runnable `linux/amd64` and `linux/arm64` manifests. Other non-runnable descriptors, such as attestations, may also be present.

```json
{
  "schemaVersion": 1,
  "revision": "<full-commit-SHA>",
  "images": {
    "<project-name>": "ghcr.io/dhhyi/recipe-db-<project-name>@sha256:<image-index-digest>"
  }
}
```

The workflow publishes the artifact only after validating every image and platform. The equivalent ORAS push is:

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
  '.schemaVersion == 1 and .revision == $revision and (.images | type == "object")' \
  release/release.json
```

In a checkout, `sh .scripts/validate-production-release.sh release/release.json "$revision"` additionally checks exact category-derived membership and immutable GHCR digest references. Pull either platform explicitly:

```sh
jq -r '.images[]' release/release.json | while IFS= read -r image; do
  docker pull --platform linux/amd64 "$image"
  docker pull --platform linux/arm64 "$image"
done
```

To confirm anonymous access, run the ORAS and Docker commands with empty credentials:

```sh
export HOME="$(mktemp -d)"
export DOCKER_CONFIG="$(mktemp -d)"
printf '{}\n' > "$DOCKER_CONFIG/config.json"
```

The workflow also pulls each image platform and the artifact anonymously before treating publication as complete. It logs the verified image digests and exact release-artifact digest. Native AMD64 and ARM64 runners also start the production `design` image and check its `/health` endpoint.

## GHCR access and permissions

The workflow requires `packages: write` to publish the application images and release artifact. This alone does not make packages public. In the GitHub Packages settings, set every `ghcr.io/dhhyi/recipe-db-*` application package and `ghcr.io/dhhyi/recipe-db-releases` to public, and confirm anonymous pulls before relying on a release. Newly created packages may need to be made public manually; a failed anonymous verification must be fixed and the workflow rerun.

## Retry and recovery

Rerun the workflow for the same commit after correcting a failed build or registry permission. If a valid complete inventory already exists for that revision, the workflow verifies and reuses its digest rather than replacing it. A missing inventory tag allows publication to proceed, including the first push that creates the release package; authentication and network failures still abort the lookup. An invalid existing inventory fails closed for investigation. Incomplete staging image uploads do not create a release inventory.

Compatibility `latest` tags are updated only after the release inventory is complete and verified, and only while that revision is still the `main` head. GHCR updates each application's tag independently, not atomically; if a tag update fails partway through, rerun the workflow to finish it. Deployment inputs remain the artifact and image digests, not these tags. Digests do not prevent package deletion or guarantee indefinite registry retention.
