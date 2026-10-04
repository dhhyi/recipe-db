#!/bin/sh
set -eu

project=$1
script_path=$(realpath "$0")
workspace_root=$(cd -- "$(dirname -- "$script_path")/.." && pwd -P)
output=$(realpath -m "$2")

cd "$workspace_root"
mise run --raw in-devcontainer "$project" format
{
  git ls-files --cached --others --exclude-standard -z -- "$project/"
  if [ -f "$project/recipe-db.graphqls" ]; then
    printf '%s\0' "$project/recipe-db.graphqls"
  fi
  case $project in
    browse) find "$project/src" -type f -name '*_templ.go' -print0 ;;
    images-edit) find "$project/src/Api" -type f -name '*.elm' -print0 ;;
    demo-data) find "$project/graphql_client" -type f -name '*.py' -print0 ;;
  esac
} | tar --null -T - -cf "$output"
