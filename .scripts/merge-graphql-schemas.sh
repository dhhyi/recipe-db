#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
canonical_schema="$project_root/.generated/graphql/recipe-db.graphqls"

if [ ! -s "$canonical_schema" ]; then
  echo "canonical GraphQL schema is missing or empty: .generated/graphql/recipe-db.graphqls" >&2
  exit 1
fi

for project_file in "$project_root"/*/.project.yaml; do
  [ -f "$project_file" ] || continue

  graphql_schema=$(mise exec -- yq -r \
    'select(documentIndex == 1) | .graphqlSchema // ""' \
    "$project_file")
  [ -n "$graphql_schema" ] || continue

  project_directory=${project_file%/.project.yaml}
  schema_path="$project_directory/$graphql_schema/recipe-db.graphqls"
  schema_directory=$(dirname "$schema_path")
  mkdir -p "$schema_directory"
  if [ -f "$schema_path" ] && cmp -s "$canonical_schema" "$schema_path"; then
    continue
  fi

  temporary_copy="$schema_directory/.recipe-db.graphqls.$$"
  trap 'rm -f "$temporary_copy"' EXIT HUP INT TERM
  cp "$canonical_schema" "$temporary_copy"
  mv -f "$temporary_copy" "$schema_path"
  trap - EXIT HUP INT TERM
  printf '%s\n' "Writing merged schema to ${schema_path#"$project_root"/}"
done
