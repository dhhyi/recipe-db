#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >> "$MOCK_LOG"
[[ "$1 $2 $3" == "compose --profile test" ]] || exit 99
shift 3
case "$1" in
  config) cat "$COMPOSE_CONFIG" ;;
  build) exit "${BUILD_STATUS:-0}" ;;
  ps) printf '%s' "${RUNNING_FIXTURES:-}" ;;
  up) exit "${UP_STATUS:-0}" ;;
  stop) exit "${STOP_STATUS:-0}" ;;
  run)
    printf '%s\n' "test stdout: $3"
    printf '%s\n' "test stderr: $3" >&2
    exit "${RUN_STATUS:-0}"
    ;;
  *)
    echo "Unexpected Compose invocation: $*" >&2
    exit 99
    ;;
esac
