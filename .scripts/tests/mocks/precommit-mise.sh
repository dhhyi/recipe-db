#!/usr/bin/env bash
set -euo pipefail

printf 'mise %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  'run --raw generate-bazel-build' | 'run --raw create-intranet') ;;
  'exec -- yq eval-all -r '*)
    if [[ "$*" == *'.check // ""'* ]]; then
      printf '%s\n' 'echo checked'
    elif [[ "$*" == *'.format.check // ""'* ]]; then
      printf '%s\n' 'echo formatted'
    elif [[ "$*" == *'.generate // [] | length'* ]]; then
      printf '%s\n' 0
    else
      echo "Unexpected yq invocation: $*" >&2
      exit 99
    fi
    ;;
  'run --raw bazel build --action_env=PATH --jobs=1 '*)
    if [[ "$*" == *'_format_check' && ${UNFORMATTED:-false} == true && ! -f applied ]]; then
      printf 'PROJECT_FORMAT_UNFORMATTED:%s\n' "${*: -1:1}" | sed 's|//:||;s|_format_check||'
      exit 1
    fi
    exit "${BAZEL_STATUS:-0}"
    ;;
  'run --raw in-devcontainer '*)
    touch applied
    exit "${APPLY_STATUS:-0}"
    ;;
  *)
    echo "Unexpected mise invocation: $*" >&2
    exit 99
    ;;
esac
