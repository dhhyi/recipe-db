#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

for project_file in */.project.yaml; do
  project=${project_file%/.project.yaml}
  value=$(mise exec -- yq -r \
    'select(documentIndex == 1) | .storageVersion.value // ""' "$project_file")
  [ -n "$value" ] || continue
  case "$value" in
    *[!0-9]* | 0 | "")
      echo "$project_file: storageVersion.value must be a positive integer" >&2
      exit 1
      ;;
  esac

  output=$(mise exec -- yq -r \
    'select(documentIndex == 1) | .storageVersion.file // ""' "$project_file")
  case "$output" in
    "" | /* | */ | *//* | ../* | */../* | */.. | . | ./* | */./* | */.)
      echo "$project_file: storageVersion.file must be a project-relative path without dot segments" >&2
      exit 1
      ;;
  esac
  if ! printf '%s\n' "$output" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
    echo "$project_file: storageVersion.file contains unsupported characters" >&2
    exit 1
  fi

  template="$temporary_directory/template"
  mise exec -- yq -r \
    'select(documentIndex == 1) | .storageVersion.template // ""' \
    "$project_file" > "$template"
  placeholder_count=$(grep -Fo '{{STORAGE_VERSION}}' "$template" | wc -l | tr -d ' ')
  if [ "$placeholder_count" -ne 1 ]; then
    echo "$project_file: storageVersion.template must contain exactly one {{STORAGE_VERSION}} placeholder" >&2
    exit 1
  fi

  output_directory="$project/$(dirname "$output")"
  mkdir -p "$output_directory"
  destination="$project/$output"
  if [ -d "$destination" ]; then
    echo "$project_file: storageVersion.file points to a directory" >&2
    exit 1
  fi
  generated=$(mktemp "$output_directory/.storage-version.XXXXXX")
  awk -v value="$value" '
    {
      gsub(/\{\{STORAGE_VERSION\}\}/, value)
      lines[NR] = $0
      if (length($0)) last_nonempty = NR
    }
    END {
      for (line = 1; line <= last_nonempty; line++) print lines[line]
    }
  ' "$template" > "$generated"
  if [ ! -f "$destination" ] || ! cmp -s "$generated" "$destination"; then
    mv -f "$generated" "$destination"
    echo "Generated $destination"
  else
    rm -f "$generated"
  fi
done
