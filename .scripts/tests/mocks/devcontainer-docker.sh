#!/usr/bin/env bash
set -euo pipefail

printf 'docker %s\n' "$*" >> "$MOCK_LOG"
case "$1" in
  ps)
    if [[ ${PS_STATUS:-0} != 0 ]]; then
      echo "Docker discovery failed" >&2
      exit "$PS_STATUS"
    fi
    if [[ ${2:-} == -a ]]; then
      printf '%s' "${STOPPED_CONTAINER:-}"
    else
      printf '%s' "${RUNNING_CONTAINER:-}"
    fi
    ;;
  stop | rm) exit "${CLEANUP_STATUS:-0}" ;;
  *)
    echo "Unexpected docker invocation: $*" >&2
    exit 99
    ;;
esac
