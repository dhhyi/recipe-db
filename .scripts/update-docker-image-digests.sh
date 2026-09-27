#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
temporary_directory=$(mktemp -d)
output_file=
# Remove lookup data and any unfinished Dockerfile copy on exit or interruption.
trap 'rm -rf "$temporary_directory"; [ -z "$output_file" ] || rm -f "$output_file"' 0
trap 'exit 1' 1 2 3 15

# List external images, recording each named stage after its FROM line.
# shellcheck disable=SC2016
scan_awk='
{
  if (toupper($1) == "FROM" && NF >= 2) {
    image = $2
    if (tolower(image) != "scratch" && !stages[tolower(image)]) {
      sub(/@sha256:[[:xdigit:]]+$/, "", image)
      print image
    }
    if (toupper($3) == "AS") stages[tolower($4)] = 1
  }
}'

# Replace image tokens using digests resolved before any Dockerfile is changed.
# shellcheck disable=SC2016
write_awk='
BEGIN {
  while ((getline entry < digest_file) > 0) {
    split(entry, fields, "\t")
    digests[fields[1]] = fields[2]
  }
  close(digest_file)
}
{
  if (toupper($1) == "FROM" && NF >= 2) {
    image = $2
    if (tolower(image) != "scratch" && !stages[tolower(image)]) {
      # Remove an existing pin, keeping the tag for the registry lookup.
      sub(/@sha256:[[:xdigit:]]+$/, "", image)
      if (!(image in digests)) exit 1
      # Rebuild only the image token, preserving spacing and any AS alias.
      match($0, /^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+/)
      prefix = substr($0, 1, RLENGTH)
      $0 = prefix image "@" digests[image] substr($0, RLENGTH + length($2) + 1)
    }
    if (toupper($3) == "AS") stages[tolower($4)] = 1
  }
  print
}'

# Collect unique external base images from projects with production Dockerfiles.
: > "$temporary_directory/images"
for project_file in "$project_root"/*/.project.yaml; do
  [ -f "$project_file" ] || continue
  dockerfile="$(dirname "$project_file")/Dockerfile"
  [ -f "$dockerfile" ] || continue
  awk "$scan_awk" "$dockerfile" >> "$temporary_directory/images"
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
  awk -v digest_file="$temporary_directory/digests" "$write_awk" "$dockerfile" > "$output_file"
  if ! cmp -s "$dockerfile" "$output_file"; then
    mv "$output_file" "$dockerfile"
    echo "Updated $dockerfile"
  fi
  rm -f "$output_file"
  output_file=
done
