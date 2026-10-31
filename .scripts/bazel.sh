#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "$0")/.."

mise_bin=$(command -v mise)
tool_paths=$("$mise_bin" env --paths)
PATH="${tool_paths//$'\n'/:}:$(dirname -- "$mise_bin"):/usr/local/bin:/usr/bin:/bin"
export PATH

if [[ ${1:-} == build ]]; then
  sh .scripts/bazel-quality-identity.sh host
fi

exec "$mise_bin" exec -- bazelisk "$@"
