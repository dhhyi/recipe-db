#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <full-revision> <output.json>" >&2
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

project_root=$(cd "$(dirname "$0")/.." && pwd)
. "$project_root/.scripts/lib/project-metadata.sh"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
fragments="$temporary_directory/project-fragments.jsonl"
application_project_metadata_to_jsonl "$project_root" "$fragments"
release_file="$temporary_directory/release.json"
jq -n --arg revision "$revision" '{schemaVersion: 1, revision: $revision, images: {}}' > "$release_file"

jq -r '.name' "$fragments" \
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

sh "$project_root/.scripts/validate-production-release.sh" "$release_file" "$revision"
mkdir -p "$(dirname "$output_file")"
mv "$release_file" "$output_file"
