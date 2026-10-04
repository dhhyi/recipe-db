#!/usr/bin/env bash
set -euo pipefail

project=$1
output=$(realpath -m "$2")
mode=$3
workspace_root=$(cd -- "$(dirname -- "$(realpath "$0")")/.." && pwd -P)
cd "$workspace_root"

file_list=$(mktemp)
trap 'rm -f "$file_list"' EXIT

if [[ "$mode" == format ]]; then
  git ls-files --cached --others --exclude-standard -z -- "$project/" > "$file_list"
  schema_directory=$(mise exec -- yq eval-all -r 'select(documentIndex == 1) | .graphqlSchema // ""' "$project/.project.yaml")
  if [[ -n "$schema_directory" ]]; then
    schema_file="$project/$schema_directory/recipe-db.graphqls"
    if [[ ! -f "$schema_file" ]]; then
      printf 'Missing generated GraphQL schema: %s\n' "$schema_file" >&2
      exit 1
    fi
    schema_file=$(realpath --relative-to="$workspace_root" "$schema_file")
    printf '%s\0' "$schema_file" >> "$file_list"
  fi
elif [[ "$mode" != generate ]]; then
  printf 'Unknown artifact mode: %s\n' "$mode" >&2
  exit 1
fi

patterns=$(mise exec -- yq eval-all -r 'select(documentIndex == 1) | .generate // [] | .[].output' "$project/.project.yaml")
if [[ -n "$patterns" ]]; then
  (
    cd "$project"
    project_root=$(pwd -P)
    shopt -s globstar nullglob dotglob
    while IFS= read -r pattern; do
      case "$pattern" in
        '' | /* | .. | ../* | */../* | */..)
          printf 'Invalid generated output glob: %s\n' "$pattern" >&2
          exit 1
          ;;
      esac
      IFS=
      # Expand the declared glob without splitting filenames on whitespace.
      # shellcheck disable=SC2206
      matches=($pattern)
      matched=false
      for file in "${matches[@]}"; do
        [[ -f "$file" ]] || continue
        case "$(realpath "$file")" in
          "$project_root"/*) ;;
          *)
            printf 'Generated output escapes project: %s\n' "$file" >&2
            exit 1
            ;;
        esac
        printf '%s/%s\0' "$project" "$file"
        matched=true
      done
      if [[ "$matched" == false ]]; then
        printf 'Generated output glob matched no files: %s/%s\n' "$project" "$pattern" >&2
        exit 1
      fi
    done <<< "$patterns"
  ) >> "$file_list"
fi

sort -zu "$file_list" -o "$file_list"
tar --null --verbatim-files-from -T "$file_list" -cf "$output"
