#!/bin/sh
set -eu

script_path=$(realpath "$0")
workspace_root=$(cd "$(dirname "$script_path")/.." && pwd -P)
cd "$workspace_root"
mise run --raw "$@"
