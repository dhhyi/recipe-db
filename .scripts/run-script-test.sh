#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  printf 'usage: %s SUITE\n' "$0" >&2
  exit 2
fi

workspace="${TEST_SRCDIR:+${TEST_SRCDIR}/${TEST_WORKSPACE:-}}"
if [[ -n "$workspace" && -d "$workspace" ]]; then
  cd -- "$workspace"
else
  cd -- "$(dirname -- "$0")/.."
fi
exec bats --print-output-on-failure "$1"
