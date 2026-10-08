#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
temporary_directory=$(mktemp -d)
output_file=
# Remove lookup data and any unfinished Dockerfile copy on exit or interruption.
trap 'rm -rf "$temporary_directory"; [ -z "$output_file" ] || rm -f "$output_file"' 0
trap 'exit 1' 1 2 3 15

scanner="$project_root/.scripts/docker-base-images.awk"

# Collect unique external base images from projects with production Dockerfiles.
: > "$temporary_directory/images"
for project_file in "$project_root"/*/.project.yaml; do
  [ -f "$project_file" ] || continue
  dockerfile="$(dirname "$project_file")/Dockerfile"
  [ -f "$dockerfile" ] || continue
  args_file="$temporary_directory/$(basename "$(dirname "$project_file")").args"
  mise exec -- yq eval-all -r \
    'select(documentIndex == 0) | .devcontainer.build.args // {} | to_entries | .[] | [.key, (.value | tostring)] | @tsv' \
    "$project_file" > "$args_file"
  awk -v mode=scan -v args_file="$args_file" -f "$scanner" "$dockerfile" >> "$temporary_directory/images"
done
sort -u "$temporary_directory/images" > "$temporary_directory/unique-images"

# Finish all registry lookups before touching any Dockerfile.
: > "$temporary_directory/digests"
while IFS= read -r image; do
  echo "Resolving $image"
  digest=$(docker buildx imagetools inspect "$image" --format '{{json .}}' \
    | jq -er '.manifest.digest | select(test("^sha256:[0-9a-fA-F]{64}$"))')
  printf '%s\t%s\n' "$image" "$digest" >> "$temporary_directory/digests"
done < "$temporary_directory/unique-images"

# Preserve file permissions and replace only Dockerfiles whose contents changed.
for project_file in "$project_root"/*/.project.yaml; do
  [ -f "$project_file" ] || continue
  dockerfile="$(dirname "$project_file")/Dockerfile"
  [ -f "$dockerfile" ] || continue
  output_file=$(mktemp "$dockerfile.XXXXXX")
  cp -p "$dockerfile" "$output_file"
  args_file="$temporary_directory/$(basename "$(dirname "$project_file")").args"
  awk -v mode=write -v args_file="$args_file" -v digest_file="$temporary_directory/digests" \
    -f "$scanner" "$dockerfile" > "$output_file"
  if ! cmp -s "$dockerfile" "$output_file"; then
    mv "$output_file" "$dockerfile"
    echo "Updated $dockerfile"
  fi
  rm -f "$output_file"
  output_file=
done
