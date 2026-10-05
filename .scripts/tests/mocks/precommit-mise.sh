#!/usr/bin/env bash
set -euo pipefail

printf 'mise %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  'run --raw generate-bazel-build') ;;
  'exec -- bazelisk build --action_env=PATH --jobs=1 //:shellcheck //:test_scripts')
    exit "${BAZEL_STATUS:-0}"
    ;;
  *)
    echo "Unexpected mise invocation: $*" >&2
    exit 99
    ;;
esac
