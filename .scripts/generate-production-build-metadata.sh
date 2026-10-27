#!/bin/sh
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "usage: $0 <full-revision> <linux/amd64|linux/arm64> <output.json> [write-cache]" >&2
  exit 2
fi

revision=$1
platform=$2
output_file=$3
write_cache=${4:-false}
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
case "$platform" in
  linux/amd64 | linux/arm64) ;;
  *)
    echo "unsupported platform: $platform" >&2
    exit 1
    ;;
esac
case "$write_cache" in
  true | false) ;;
  *)
    echo "write-cache must be true or false" >&2
    exit 1
    ;;
esac

project_root=$(cd "$(dirname "$0")/.." && pwd)
. "$project_root/.scripts/lib/project-metadata.sh"
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
fragments="$temporary_directory/project-fragments.jsonl"
application_project_metadata_to_jsonl "$project_root" "$fragments"

architecture=${platform#linux/}
cache_suffix=
if [ "$architecture" = arm64 ]; then
  cache_suffix=-arm64
fi

jq -n \
  --slurpfile projects "$fragments" \
  --arg revision "$revision" \
  --arg platform "$platform" \
  --arg architecture "$architecture" \
  --arg cacheSuffix "$cache_suffix" \
  --argjson writeCache "$write_cache" '
  ($projects) as $applications
  | if ($applications | length) == 0 then
      error("no backend, api, or frontend projects were found")
    else
      {
        group: {
          default: {
            targets: ($applications | map(.name))
          }
        },
        target: (
          reduce $applications[] as $project ({};
            .[$project.name] = (
              {
                context: $project.buildInputs.context,
                dockerfile: $project.buildInputs.dockerfile,
                tags: ["ghcr.io/dhhyi/recipe-db-" + $project.name + ":sha-" + $revision + "-" + $architecture],
                platforms: [$platform],
                "cache-from": ["type=registry,ref=" + $project.buildInputs.cacheRepository + $cacheSuffix],
                args: $project.buildInputs.args,
                labels: (
                  {"org.opencontainers.image.revision": $revision}
                  + (if ($project.repository // "") | startswith("github:")
                     then {"org.opencontainers.image.source": "https://github.com/" + $project.repository[7:]}
                     else {}
                     end)
                )
              }
              + if $writeCache then {
                  "cache-to": ["type=registry,mode=max,ref=" + $project.buildInputs.cacheRepository + $cacheSuffix]
                } else {} end
            )
          )
        )
      }
    end
  ' > "$temporary_directory/metadata.json"

mkdir -p "$(dirname "$output_file")"
mv "$temporary_directory/metadata.json" "$output_file"
