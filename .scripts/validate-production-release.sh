#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <release.json> <full-revision>" >&2
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

project_root=$(cd "$(dirname "$0")/.." && pwd)
. "$project_root/.scripts/lib/project-metadata.sh"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
fragments="$temporary_directory/project-fragments.jsonl"
application_project_metadata_to_jsonl "$project_root" "$fragments"

schema_version=$(jq -r 'if type == "object" then .schemaVersion // "missing" else "invalid" end' "$release_file" 2> /dev/null || echo invalid)
if [ "$schema_version" != 1 ]; then
  echo "unsupported release schemaVersion: $schema_version (expected 1)" >&2
  exit 1
fi

if ! jq -e --arg revision "$revision" '
  type == "object"
  and (keys == ["images", "revision", "schemaVersion"])
  and .revision == $revision
  and (.images | type == "object")
' "$release_file" > /dev/null; then
  echo "release inventory must contain schemaVersion 1, the requested revision, and an images object" >&2
  exit 1
fi

if ! jq -e --slurpfile projects "$fragments" '
  (.images | keys | sort) ==
  ($projects | map(.name) | sort)
' "$release_file" > /dev/null; then
  echo "release inventory image membership does not match backend, api, and frontend projects" >&2
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
