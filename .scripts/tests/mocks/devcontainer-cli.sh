#!/usr/bin/env bash
set -euo pipefail

printf 'devcontainer %s\n' "$*" >> "$MOCK_LOG"
case "$1" in
  up)
    if [[ -v UP_JSON ]]; then
      printf '%s\n' "$UP_JSON"
    else
      printf '%s\n' '{"containerId":"started-container"}'
    fi
    exit "${UP_STATUS:-0}"
    ;;
  exec)
    if [[ -n ${EXEC_GATE:-} ]]; then
      touch "$EXEC_GATE.started"
      while [[ ! -f "$EXEC_GATE.release" ]]; do
        sleep 0.05
      done
    fi
    printf '%s\n' 'command output'
    exit "${EXEC_STATUS:-0}"
    ;;
  *)
    echo "Unexpected devcontainer invocation: $*" >&2
    exit 99
    ;;
esac
