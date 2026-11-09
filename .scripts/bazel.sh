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
  status=0
  "$mise_bin" exec -- bazelisk build \
    --subcommands --verbose_explanations --explain="$explain_log" "$@" || status=$?
  printf '\nBazel rebuild explanations (%s):\n' "$explain_log"
  cat "$explain_log"
  exit "$status"
fi

exec "$mise_bin" exec -- bazelisk "$@"
