#!/bin/sh
set -eu

if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--list" ]; }; then
  echo "Usage: $0 [--list]" >&2
  exit 2
fi
list_only=false
if [ "$#" -eq 1 ]; then
  list_only=true
fi

project_root=$(cd "$(dirname "$0")/.." && pwd)
temporary_directory=$(mktemp -d)
cleanup() {
  while IFS= read -r staged_file; do
    rm -f "$staged_file"
  done < "$temporary_directory/staged-files"
  rm -rf "$temporary_directory"
}
trap cleanup 0
trap 'exit 1' 1 2 3 15

scanner="$project_root/.scripts/docker-base-images.awk"
external_scanner="$project_root/.scripts/external-image-references.awk"
rewriter="$project_root/.scripts/update-image-references.awk"
tab=$(printf '\t')
: > "$temporary_directory/inventory"
: > "$temporary_directory/static-references"
: > "$temporary_directory/dockerfiles"
: > "$temporary_directory/staged-files"

for project_file in "$project_root"/*/.project.yaml; do
  [ -f "$project_file" ] || continue
  dockerfile="$(dirname "$project_file")/Dockerfile"
  [ -f "$dockerfile" ] || continue
  project_name=$(basename "$(dirname "$project_file")")
  args_file="$temporary_directory/$project_name.args"
  mise exec -- yq eval-all -r \
    'select(documentIndex == 0) | .devcontainer.build.args // {} | to_entries | .[] | [.key, (.value | tostring)] | @tsv' \
    "$project_file" > "$args_file"
  awk -v mode=scan -v args_file="$args_file" -f "$scanner" "$dockerfile" \
    > "$temporary_directory/dockerfile-images"
  while IFS= read -r image; do
    printf '%s\t%s\n' "${dockerfile#"$project_root"/}" "$image" >> "$temporary_directory/inventory"
  done < "$temporary_directory/dockerfile-images"
  printf '%s\t%s\n' "${dockerfile#"$project_root"/}" "$args_file" >> "$temporary_directory/dockerfiles"
done

find "$project_root/.scripts/templates" -type f \( -name '*.yml' -o -name '*.yaml' \) -print \
  | sort > "$temporary_directory/template-files"
while IFS= read -r template; do
  awk -f "$external_scanner" "$template" > "$temporary_directory/template-images"
  while IFS= read -r image; do
    relative_template=${template#"$project_root"/}
    printf '%s\t%s\n' "$relative_template" "$image" >> "$temporary_directory/inventory"
    printf '%s\t%s\ttemplate\n' "$relative_template" "$image" >> "$temporary_directory/static-references"
  done < "$temporary_directory/template-images"
done < "$temporary_directory/template-files"

for deployment in "$project_root/deploy/local.yaml" "$project_root/deploy/pi.yaml"; do
  [ -f "$deployment" ] || continue
  mise exec -- yq eval -r '.infrastructure[] | select(tag == "!!str")' "$deployment" \
    > "$temporary_directory/deployment-images"
  while IFS= read -r image; do
    [ -n "$image" ] || continue
    relative_deployment=${deployment#"$project_root"/}
    printf '%s\t%s\n' "$relative_deployment" "$image" >> "$temporary_directory/inventory"
    printf '%s\t%s\tdeployment\n' "$relative_deployment" "$image" >> "$temporary_directory/static-references"
  done < "$temporary_directory/deployment-images"
done

sort -u "$temporary_directory/inventory" > "$temporary_directory/sorted-inventory"
cat "$temporary_directory/sorted-inventory"
if [ "$list_only" = true ]; then
  exit 0
fi

awk -F "$tab" '{
  image = $2
  sub(/@sha256:[[:xdigit:]]+$/, "", image)
  print image
}' "$temporary_directory/sorted-inventory" | sort -u > "$temporary_directory/images"

: > "$temporary_directory/digests"
while IFS= read -r image; do
  echo "Resolving $image" >&2
  inspection=$(docker buildx imagetools inspect "$image" --format '{{json .}}')
  digest=$(printf '%s\n' "$inspection" \
    | jq -er '.manifest.digest | select(test("^sha256:[0-9a-fA-F]{64}$"))')
  printf '%s\t%s\n' "$image" "$digest" >> "$temporary_directory/digests"
done < "$temporary_directory/images"

awk -F "$tab" -v digests_file="$temporary_directory/digests" '
  BEGIN {
    while ((getline entry < digests_file) > 0) {
      split(entry, fields, "\t")
      digests[fields[1]] = fields[2]
    }
    close(digests_file)
  }
  {
    image = $2
    lookup = image
    sub(/@sha256:[[:xdigit:]]+$/, "", lookup)
    if (!(lookup in digests)) {
      print "missing digest for " lookup > "/dev/stderr"
      exit 1
    }
    print image "\t" lookup "@" digests[lookup]
  }
' "$temporary_directory/static-references" | sort -u > "$temporary_directory/image-replacements"

stage_file() {
  source_file=$1
  kind=$2
  output_file=$(mktemp "$source_file.XXXXXX")
  printf '%s\n' "$output_file" >> "$temporary_directory/staged-files"
  cp -p "$source_file" "$output_file"
  if [ "$kind" = dockerfile ]; then
    args_file=$3
    awk -v mode=write -v args_file="$args_file" -v digest_file="$temporary_directory/digests" \
      -f "$scanner" "$source_file" > "$output_file"
  else
    awk -F "$tab" -v mode="$kind" -v replacements_file="$temporary_directory/image-replacements" \
      -f "$rewriter" "$source_file" > "$output_file"
  fi
  printf '%s\t%s\n' "$source_file" "$output_file" >> "$temporary_directory/staged-files-list"
}

: > "$temporary_directory/staged-files-list"
while IFS="$tab" read -r relative_file args_file; do
  [ -n "$relative_file" ] || continue
  stage_file "$project_root/$relative_file" dockerfile "$args_file"
done < "$temporary_directory/dockerfiles"

awk -F "$tab" '!seen[$1 FS $3]++ { print $1 "\t" $3 }' "$temporary_directory/static-references" \
  > "$temporary_directory/static-files"
while IFS="$tab" read -r relative_file kind; do
  [ -n "$relative_file" ] || continue
  stage_file "$project_root/$relative_file" "$kind"
done < "$temporary_directory/static-files"

while IFS="$tab" read -r source_file output_file; do
  [ -n "$source_file" ] || continue
  if ! cmp -s "$source_file" "$output_file"; then
    mv "$output_file" "$source_file"
    echo "Updated ${source_file#"$project_root"/}"
  fi
done < "$temporary_directory/staged-files-list"
