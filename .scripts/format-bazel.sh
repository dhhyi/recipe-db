#!/bin/sh
set -eu

project=$1
script_path=$(realpath "$0")
workspace_root=$(cd -- "$(dirname -- "$script_path")/.." && pwd -P)
output=$(realpath -m "$2")
if [ "$#" -gt 2 ]; then
  input=$(realpath "$3")
fi

cd "$workspace_root"
if [ "$#" -gt 2 ]; then
  tar -xf "$input"
fi
mise run --raw in-devcontainer "$project" format
bash .scripts/bazel-artifacts.sh "$project" "$output" format
