#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "$0")/.."

mise_bin=$(command -v mise)
tool_paths=$("$mise_bin" env --paths)
PATH="${tool_paths//$'\n'/:}:$(dirname -- "$mise_bin"):/usr/local/bin:/usr/bin:/bin"
export PATH

if [[ ${1:-} == build && -n ${BAZEL_DIAGNOSTICS_DIR:-} ]]; then
  shift
  diagnostics_dir=$BAZEL_DIAGNOSTICS_DIR
  mkdir -p "$diagnostics_dir"
  explain_log=$(mktemp "$diagnostics_dir/$(date +%F-%H%M%S)-bazel-explain.XXXXXX.log")
  exec "$mise_bin" exec -- bazelisk build \
    --verbose_explanations --explain="$explain_log" "$@"
fi

exec "$mise_bin" exec -- bazelisk "$@"
