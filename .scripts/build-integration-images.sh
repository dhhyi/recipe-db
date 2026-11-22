#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  echo "usage: build-integration-images.sh output-directory" >&2
  exit 2
fi

output_directory=$1
mkdir -p "$output_directory"
compose_arguments=(--profile development --profile test)
compose_config="$output_directory/compose-config.json"
bake_file="$output_directory/compose-bake.json"
build_metadata="$output_directory/integration-build-metadata.json"

docker compose "${compose_arguments[@]}" config --format json > "$compose_config"
mapfile -t external_services < <(
  jq -r '.services | to_entries as $services
    | [$services[] | select(.value.build != null) | .value.image] as $built_images
    | $services[]
    | select((.value.image | type) == "string" and .value.build == null
      and (.value.image as $image | $built_images | index($image) == null))
    | .key' "$compose_config" | LC_ALL=C sort
)
if ((${#external_services[@]})); then
  docker compose "${compose_arguments[@]}" pull "${external_services[@]}"
fi

docker compose --progress plain "${compose_arguments[@]}" build --print > "$bake_file"
docker buildx bake --file "$bake_file" --metadata-file "$build_metadata" --load \
  --progress plain --jobs "${COMPOSE_PARALLEL_LIMIT:-1}"
jq -e 'type == "object"' "$build_metadata" > /dev/null
