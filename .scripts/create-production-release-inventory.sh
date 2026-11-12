#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <full-revision> <output.json> [project-root]" >&2
  exit 2
fi

revision=$1
output_file=$2
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

script_root=$(cd "$(dirname "$0")/.." && pwd)
project_root=${3:-$script_root}
project_root=$(cd "$project_root" && pwd)
. "$script_root/.scripts/lib/project-metadata.sh"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
project_fragments="$temporary_directory/project-fragments.jsonl"
migrator_fragments="$temporary_directory/migrator-fragments.jsonl"
application_project_metadata_to_jsonl "$project_root" "$project_fragments"
migrator_metadata_to_jsonl "$project_root" "$migrator_fragments"
release_file="$temporary_directory/release.json"
jq -n --arg revision "$revision" '{schemaVersion: 2, revision: $revision, images: {}, migrations: []}' > "$release_file"

jq -r '.name' "$project_fragments" \
  | while IFS= read -r project; do
    image="ghcr.io/dhhyi/recipe-db-$project:sha-$revision"
    descriptor="$temporary_directory/$project-descriptor.json"
    if ! oras manifest fetch --descriptor "$image" > "$descriptor"; then
      echo "could not inspect published image index $image" >&2
      exit 1
    fi
    digest=$(jq -er '.digest | select(test("^sha256:[0-9a-f]{64}$"))' "$descriptor") || {
      echo "registry returned an invalid image digest for $image" >&2
      exit 1
    }
    jq --arg project "$project" --arg digest "ghcr.io/dhhyi/recipe-db-$project@$digest" \
      '.images[$project] = $digest' "$release_file" > "$temporary_directory/next.json"
    mv "$temporary_directory/next.json" "$release_file"
  done

jq -c '.' "$migrator_fragments" \
  | while IFS= read -r migration; do
    directory=$(printf '%s\n' "$migration" | jq -r '.directory')
    service=$(printf '%s\n' "$migration" | jq -r '.service')
    from_version=$(printf '%s\n' "$migration" | jq -r '.fromVersion')
    to_version=$(printf '%s\n' "$migration" | jq -r '.toVersion')
    timeout_seconds=$(printf '%s\n' "$migration" | jq -r '.timeoutSeconds')
    image="ghcr.io/dhhyi/recipe-db-migrator-$directory:sha-$revision"
    descriptor="$temporary_directory/migrator-$directory-descriptor.json"
    if ! oras manifest fetch --descriptor "$image" > "$descriptor"; then
      echo "could not inspect published migrator image index $image" >&2
      exit 1
    fi
    digest=$(jq -er '.digest | select(test("^sha256:[0-9a-f]{64}$"))' "$descriptor") || {
      echo "registry returned an invalid migrator image digest for $image" >&2
      exit 1
    }
    jq \
      --arg service "$service" \
      --argjson fromVersion "$from_version" \
      --argjson toVersion "$to_version" \
      --argjson timeoutSeconds "$timeout_seconds" \
      --arg image "ghcr.io/dhhyi/recipe-db-migrator-$directory@$digest" \
      '.migrations += [{
        service: $service,
        fromVersion: $fromVersion,
        toVersion: $toVersion,
        timeoutSeconds: $timeoutSeconds,
        image: $image
      }] | .migrations |= sort_by(.service, .fromVersion, .toVersion, .image)' \
      "$release_file" > "$temporary_directory/next.json"
    mv "$temporary_directory/next.json" "$release_file"
  done

sh "$script_root/.scripts/validate-production-release.sh" "$release_file" "$revision" "$project_root"
mkdir -p "$(dirname "$output_file")"
mv "$release_file" "$output_file"
