#!/usr/bin/env bash
set -euo pipefail

printf 'mise %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  'run --raw bazel-quality') exit "${BAZEL_STATUS:-0}" ;;
  'exec -- yq eval-all -r '*)
    if [[ "$*" == *'.check // ""'* ]]; then
      printf '%s\n' 'echo checked'
    elif [[ "$*" == *'.format // ""'* ]]; then
      printf '%s\n' 'echo formatted'
    elif [[ "$*" == *'.generate // [] | length'* ]]; then
      printf '%s\n' 0
    else
      echo "Unexpected yq invocation: $*" >&2
      exit 99
    fi
    ;;
  *)
    echo "Unexpected mise invocation: $*" >&2
    exit 99
    ;;
esac
