#!/bin/sh
set -eu

project=$1
script_path=$(realpath "$0")
workspace_root=$(cd -- "$(dirname -- "$script_path")/.." && pwd -P)
output=$(realpath -m "$2")
cd "$workspace_root"
unformatted_exit_code=$(yq eval-all -r 'select(documentIndex == 1) | .format.unformattedExitCode // 3' "$project/.project.yaml")
if mise run --raw in-devcontainer "$project" format-check; then
  touch "$output"
else
  status=$?
  if [ "$status" -eq "$unformatted_exit_code" ]; then
    printf 'PROJECT_FORMAT_UNFORMATTED:%s\n' "$project" >&2
    exit 3
  fi
  exit "$status"
fi
