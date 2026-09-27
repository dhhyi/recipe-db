#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT

printed_type_defs="$temporary_directory/recipe-db.graphqls"
mise run --raw in-devcontainer graphql cargo run --release -- print-schema > "$printed_type_defs"

for project_file in "$project_root"/*/.project.yaml; do
  [ -f "$project_file" ] || continue

  graphql_schema=$(mise exec -- yq -r \
    'select(documentIndex == 1) | .graphqlSchema // ""' \
    "$project_file")
  [ -n "$graphql_schema" ] || continue

  project_directory=${project_file%/.project.yaml}
  schema_path="$project_directory/$graphql_schema/recipe-db.graphqls"
  mkdir -p "$(dirname "$schema_path")"
  printf '%s\n' "Writing merged schema to ${schema_path#"$project_root"/}"
  cp "$printed_type_defs" "$schema_path"
done
