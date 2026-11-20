#!/bin/sh
set -eu

project=$1
action=$2
case "$action" in
  check | test) ;;
  *)
    echo "Expected check or test action" >&2
    exit 2
    ;;
esac
script_path=$(realpath "$0")
workspace_root=$(cd -- "$(dirname -- "$script_path")/.." && pwd -P)
output=$(realpath -m "$3")
if [ "$#" -gt 3 ]; then
  input=$(realpath "$4")
fi

cd "$workspace_root"
if [ "$#" -gt 3 ]; then
  tar -xf "$input"
fi
mise run --raw in-devcontainer "$project" "$action"
touch "$output"
