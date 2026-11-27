#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "$0")/.."

mise_bin=$(command -v mise)
if [[ ! -f BUILD.bazel ]]; then
  "$mise_bin" run --raw generate-bazel-build >&2
fi
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

if [[ ${1:-} == test ]]; then
  test_args=()
  for variable in TEST_AUTH_INGRESS TEST_AUTH_LIFECYCLE; do
    if [[ -n ${!variable+x} ]]; then
      test_args+=(--test_env="$variable=${!variable}")
    fi
  done
  shift
  exec "$mise_bin" exec -- bazelisk test \
    --test_env=PATH \
    --action_env=PATH \
    "${test_args[@]}" "$@"
fi

exec "$mise_bin" exec -- bazelisk "$@"
