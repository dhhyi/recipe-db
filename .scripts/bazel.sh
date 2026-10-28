#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "$0")/.."

mise_bin=$(command -v mise)
tool_paths=$("$mise_bin" env --paths)
PATH="${tool_paths//$'\n'/:}:$(dirname -- "$mise_bin"):/usr/local/bin:/usr/bin:/bin"
export PATH

exec "$mise_bin" exec -- bazelisk "$@"
