#!/bin/sh
set -eu

project=$1
script_path=$(realpath "$0")
workspace_root=$(cd -- "$(dirname -- "$script_path")/.." && pwd -P)
output=$(realpath -m "$2")

cd "$workspace_root"
mise run --raw in-devcontainer "$project" generate
bash .scripts/bazel-artifacts.sh "$project" "$output" generate
