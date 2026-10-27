#!/usr/bin/env bash
set -euo pipefail

printf 'mise %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  'run --raw generate-bazel-build' | 'run --raw create-intranet') ;;
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
  'exec -- bazelisk build --action_env=PATH --jobs=1 '*)
    for project in example other; do
      if [[ "$*" == *"//:${project}_format"* ]]; then
        mkdir -p bazel-bin
        tar -cf "bazel-bin/$project-format.tar" --files-from /dev/null
      fi
    done
    exit "${BAZEL_STATUS:-0}"
    ;;
  *)
    echo "Unexpected mise invocation: $*" >&2
    exit 99
    ;;
esac
