#!/bin/sh
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 <full-revision> [inventory-output.json]" >&2
  exit 2
fi

revision=$1
case "$revision" in
  *[!0-9a-f]* | "")
    echo "revision must be a full lowercase Git commit SHA" >&2
    exit 1
    ;;
esac
if [ "${#revision}" -ne 40 ]; then
  echo "revision must be a full 40-character Git commit SHA" >&2
  exit 1
fi

project_root=$(cd "$(dirname "$0")/.." && pwd)
. "$project_root/.scripts/lib/release-validation.sh"
anonymous_directory=$(mktemp -d)
trap 'rm -rf "$anonymous_directory"' EXIT
mkdir -p "$anonymous_directory/docker" "$anonymous_directory/home"
printf '{}\n' > "$anonymous_directory/docker/config.json"
release_tag="ghcr.io/dhhyi/recipe-db-releases:sha-$revision"
descriptor="$anonymous_directory/descriptor.json"
error_file="$anonymous_directory/error.log"

if ! oras manifest fetch --descriptor "$release_tag" > "$descriptor" 2> "$error_file"; then
  if grep -Eq 'status code 404|404 Not Found|MANIFEST_UNKNOWN' "$error_file" \
    || grep -Fxq "Error response from registry: failed to find \"$release_tag\": $release_tag: not found" "$error_file"; then
    echo "absent"
    exit 0
  fi
  cat "$error_file" >&2
  echo "could not check existing release inventory $release_tag" >&2
  exit 1
fi

digest=$(jq -er '.digest | select(test("^sha256:[0-9a-f]{64}$"))' "$descriptor") || {
  echo "registry returned an invalid release artifact digest for $release_tag" >&2
  exit 1
}
artifact_reference="ghcr.io/dhhyi/recipe-db-releases@$digest"
manifest="$anonymous_directory/artifact-manifest.json"
if ! mise exec -- env HOME="$anonymous_directory/home" DOCKER_CONFIG="$anonymous_directory/docker" \
  oras manifest fetch "$artifact_reference" > "$manifest"; then
  echo "could not anonymously fetch release artifact $artifact_reference" >&2
  exit 1
fi
if ! jq -e --arg revision "$revision" '
  .artifactType == "application/vnd.dhhyi.recipe-db.release.v1+json"
  and .annotations["org.opencontainers.image.source"] == "https://github.com/dhhyi/recipe-db"
  and .annotations["org.opencontainers.image.revision"] == $revision
  and any(.layers[]?; .mediaType == "application/json")
' "$manifest" > /dev/null; then
  echo "release artifact $artifact_reference has invalid type, annotations, or payload media type" >&2
  exit 1
fi

pull_directory="$anonymous_directory/pulled"
mkdir "$pull_directory"
if ! mise exec -- env HOME="$anonymous_directory/home" DOCKER_CONFIG="$anonymous_directory/docker" \
  oras pull "$artifact_reference" --output "$pull_directory" >&2; then
  echo "could not anonymously pull release artifact $artifact_reference" >&2
  exit 1
fi
release_file="$pull_directory/release.json"
sh "$project_root/.scripts/validate-production-release.sh" "$release_file" "$revision"
verify_release_images_anonymously "$release_file" "$revision" "$project_root"
echo "Verified anonymous release artifact $artifact_reference" >&2
if [ "$#" -eq 2 ]; then
  cp "$release_file" "$2"
fi
echo "found:$digest"
