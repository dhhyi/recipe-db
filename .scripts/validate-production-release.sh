#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <release.json> <full-revision> [project-root]" >&2
  exit 2
fi

release_file=$1
revision=$2
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
if [ ! -f "$release_file" ]; then
  echo "release inventory does not exist: $release_file" >&2
  exit 1
fi

tool_root=$(cd "$(dirname "$0")/.." && pwd)
project_root=${3:-$tool_root}
. "$tool_root/.scripts/lib/project-metadata.sh"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
project_fragments="$temporary_directory/project-fragments.jsonl"
application_project_metadata_to_jsonl "$project_root" "$project_fragments"

schema_version=$(jq -r 'if type == "object" then .schemaVersion // "missing" else "invalid" end' "$release_file" 2> /dev/null || echo invalid)
if [ "$schema_version" != 1 ] && [ "$schema_version" != 2 ]; then
  echo "unsupported release schemaVersion: $schema_version (expected 1 or 2)" >&2
  exit 1
fi

if [ "$schema_version" = 1 ]; then
  if ! jq -e --arg revision "$revision" '
    type == "object"
    and (keys == ["images", "revision", "schemaVersion"])
    and .schemaVersion == 1
    and .revision == $revision
    and (.images | type == "object")
  ' "$release_file" > /dev/null; then
    echo "release inventory must contain schemaVersion 1, the requested revision, and an images object" >&2
    exit 1
  fi
else
  if ! jq -e --arg revision "$revision" '
    type == "object"
    and (keys == ["images", "migrations", "revision", "schemaVersion"])
    and .schemaVersion == 2
    and .revision == $revision
    and (.images | type == "object")
    and (.migrations | type == "array")
  ' "$release_file" > /dev/null; then
    echo "release inventory must contain schemaVersion 2, the requested revision, an images object, and a migrations array" >&2
    exit 1
  fi
  migration_fragments="$temporary_directory/migrator-fragments.jsonl"
  migrator_metadata_to_jsonl "$project_root" "$migration_fragments"
fi

if ! jq -e --slurpfile projects "$project_fragments" '
  (.images | keys | sort) ==
  ($projects | map(.name) | sort)
' "$release_file" > /dev/null; then
  echo "release inventory image membership does not match backend, api, and frontend projects" >&2
  exit 1
fi

if [ "$schema_version" = 2 ] && ! jq -e --slurpfile migrators "$migration_fragments" '
  (.migrations) as $entries
  | ($migrators) as $source
  | ($entries | length) == ($source | length)
    and all(range(0; $source | length);
      . as $index
      | ($source[$index]) as $manifest
      | ($entries[$index]) as $entry
      | ($entry | type == "object" and (keys == ["fromVersion", "image", "service", "timeoutSeconds", "toVersion"]))
        and $entry.service == $manifest.service
        and $entry.fromVersion == $manifest.fromVersion
        and $entry.toVersion == $manifest.toVersion
        and $entry.timeoutSeconds == $manifest.timeoutSeconds
        and ($entry.image | type == "string" and test("^ghcr\\.io/dhhyi/recipe-db-migrator-[a-z][a-z0-9-]*@sha256:[0-9a-f]{64}$"))
        and ($entry.image == ("ghcr.io/dhhyi/recipe-db-migrator-" + $manifest.directory + "@sha256:" + (($entry.image | split("@sha256:")[1]) // "")))
    )
' "$release_file" > /dev/null; then
  echo "release inventory migrations do not match validated migrator manifests and immutable image repositories" >&2
  exit 1
fi

if ! jq -e '
  all(.images | to_entries[];
    .value == ("ghcr.io/dhhyi/recipe-db-" + .key + "@sha256:" + ((.value | split("@sha256:") | .[1]) // ""))
    and ((.value | split("@sha256:") | .[1]) // "" | test("^[0-9a-f]{64}$"))
  )
' "$release_file" > /dev/null; then
  echo "every image must use its GHCR application repository and an immutable sha256 digest" >&2
  exit 1
fi
