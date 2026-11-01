#!/bin/sh
set -eu

project=$1
script_path=$(realpath "$0")
workspace_root=$(cd -- "$(dirname -- "$script_path")/.." && pwd -P)
output=$(realpath -m "$2")
cd "$workspace_root"
if mise run --raw in-devcontainer "$project" format-check; then
  touch "$output"
else
  status=$?
  if [ "$status" -eq 3 ]; then
    printf 'PROJECT_FORMAT_UNFORMATTED:%s\n' "$project" >&2
  fi
  exit "$status"
fi
