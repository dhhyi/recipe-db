#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
canonical_directory="$project_root/.generated/graphql"
canonical_schema="$canonical_directory/recipe-db.graphqls"
temporary_schema="$canonical_directory/.recipe-db.graphqls.$$"
mkdir -p "$canonical_directory"
trap 'rm -f "$temporary_schema"' EXIT HUP INT TERM

docker compose build graphql
docker run --rm --entrypoint /app/graphql \
  ghcr.io/dhhyi/recipe-db-graphql:latest print-schema > "$temporary_schema"
if [ ! -s "$temporary_schema" ]; then
  echo "GraphQL schema export produced an empty SDL" >&2
  exit 1
fi
mv -f "$temporary_schema" "$canonical_schema"
