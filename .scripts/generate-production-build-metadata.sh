#!/bin/sh
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
  echo "usage: $0 <full-revision> <linux/amd64|linux/arm64> <output.json> [write-cache] [project-root]" >&2
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

script_root=$(cd "$(dirname "$0")/.." && pwd)
project_root=${5:-$script_root}
project_root=$(cd "$project_root" && pwd)
. "$script_root/.scripts/lib/project-metadata.sh"
if [ "$#" -lt 5 ]; then
  sh "$project_root/.scripts/sync-storage-version-templates.sh"
fi
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
project_fragments="$temporary_directory/project-fragments.jsonl"
migrator_fragments="$temporary_directory/migrator-fragments.jsonl"
application_project_metadata_to_jsonl "$project_root" "$project_fragments"
migrator_metadata_to_jsonl "$project_root" "$migrator_fragments"

source_url=https://github.com/dhhyi/recipe-db
if [ -f "$project_root/package.json" ]; then
  repository=$(mise exec -- yq -r '.repository // ""' "$project_root/package.json")
  case "$repository" in
    github:*) source_url="https://github.com/${repository#github:}" ;;
  esac
fi

architecture=${platform#linux/}
cache_suffix=
if [ "$architecture" = arm64 ]; then
  cache_suffix=-arm64
fi

jq -n \
  --slurpfile projects "$project_fragments" \
  --slurpfile migrators "$migrator_fragments" \
  --arg revision "$revision" \
  --arg platform "$platform" \
  --arg architecture "$architecture" \
  --arg cacheSuffix "$cache_suffix" \
  --arg sourceUrl "$source_url" \
  --arg projectRoot "$project_root" \
  --arg scriptRoot "$script_root" \
  --argjson writeCache "$write_cache" '
  ($projects) as $applications
  | ($migrators) as $migrationImages
  | (($applications | map(.name)) + ($migrationImages | map("migrator-" + .directory))) as $targetNames
  | if ($targetNames | length) != ($targetNames | unique | length) then
      error("application and migrator build target names must be unique")
    elif ($targetNames | length) == 0 then
      error("no backend, api, frontend, or migrator targets were found")
    else
      {
        group: {
          default: {
            targets: $targetNames
          }
        },
        target: (
          reduce $applications[] as $project ({};
            .[$project.name] = (
              {
                context: (
                  if $projectRoot == $scriptRoot
                  then $project.buildInputs.context
                  else $projectRoot + "/" + $project.buildInputs.context
                  end
                ),
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
          | reduce $migrationImages[] as $migrator (.;
            .["migrator-" + $migrator.directory] = (
              {
                context: (
                  if $projectRoot == $scriptRoot
                  then "migrators/" + $migrator.directory
                  else $projectRoot + "/migrators/" + $migrator.directory
                  end
                ),
                dockerfile: "Dockerfile",
                tags: ["ghcr.io/dhhyi/recipe-db-migrator-" + $migrator.directory + ":sha-" + $revision + "-" + $architecture],
                platforms: [$platform],
                "cache-from": ["type=registry,ref=ghcr.io/dhhyi/recipe-db-migrator-" + $migrator.directory + "-cache" + $cacheSuffix],
                args: {},
                labels: {
                  "org.opencontainers.image.revision": $revision,
                  "org.opencontainers.image.source": $sourceUrl,
                  "org.opencontainers.image.kind": "migrator",
                  "io.dhhyi.recipe-db.migration.service": $migrator.service,
                  "io.dhhyi.recipe-db.migration.from-version": ($migrator.fromVersion | tostring),
                  "io.dhhyi.recipe-db.migration.to-version": ($migrator.toVersion | tostring)
                }
              }
              + if $writeCache then {
                  "cache-to": ["type=registry,mode=max,ref=ghcr.io/dhhyi/recipe-db-migrator-" + $migrator.directory + "-cache" + $cacheSuffix]
                } else {} end
            )
          )
        )
      }
    end
  ' > "$temporary_directory/metadata.json"

mkdir -p "$(dirname "$output_file")"
mv "$temporary_directory/metadata.json" "$output_file"
