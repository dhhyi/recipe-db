#!/usr/bin/env bash
set -euo pipefail

if (($# != 2)); then
  echo "usage: prepare-integration-identities.sh build-directory identity-directory" >&2
  exit 2
fi

workspace_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$workspace_root"
build_directory=$1
identity_directory=$2
metadata_file=$(mktemp)
trap 'rm -f "$metadata_file"' EXIT

for project_file in */.project.yaml; do
  project=${project_file%/.project.yaml}
  yq eval-all -o=json 'select(documentIndex == 1)' "$project_file" \
    | jq -c --arg name "$project" '. + {name:$name}' >> "$metadata_file"
done

graph_file="$build_directory/integration-dependency-graph.json"
python3 .scripts/integration-dependencies.py \
  --metadata "$metadata_file" --schema .scripts/project-schema.json > "$graph_file"

platform=$(docker info --format '{{.OSType}}/{{.Architecture}}')
platform_os=${platform%/*}
platform_architecture=${platform#*/}
case "$platform_architecture" in
  aarch64) platform_architecture=arm64 ;;
  x86_64) platform_architecture=amd64 ;;
esac
platform="$platform_os/$platform_architecture"
if [[ "$platform_os" != linux ]]; then
  printf 'Unsupported integration execution platform: %s\n' "$platform" >&2
  exit 1
fi

python3 .scripts/integration-identities.py \
  --metadata "$metadata_file" \
  --graph "$graph_file" \
  --compose-config "$build_directory/compose-config.json" \
  --build-metadata "$build_directory/integration-build-metadata.json" \
  --platform "$platform" \
  --output-dir "$identity_directory"
