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
    shift
    integration_service=false
    while (($#)); do
      case "$1" in
        --rm) shift ;;
        -e | --entrypoint) shift 2 ;;
        *)
          project=$1
          integration_service=true
          break
          ;;
      esac
    done
    printf '%s\n' "test stdout: $project"
    printf '%s\n' "test stderr: $project" >&2
    if [[ $integration_service == true ]]; then
      shift
      while (($#)) && [[ $1 != -c ]]; do shift; done
      [[ $# -ge 2 ]] || exit 98
      printf '%s: %s\n' "$project" "$2" >> "$INTEGRATION_LOG"
    fi
    exit "${RUN_STATUS:-0}"
    ;;
  *)
    echo "Unexpected Compose invocation: $*" >&2
    exit 99
    ;;
esac
