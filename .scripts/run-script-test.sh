#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)); then
  printf 'usage: %s SUITE\n' "$0" >&2
  exit 2
fi

if [[ -n ${TEST_SRCDIR:-} && -n ${TEST_WORKSPACE:-} ]]; then
  workspace="${TEST_SRCDIR}/${TEST_WORKSPACE}"
  if [[ -d "$workspace" ]]; then
    temporary=$(mktemp -d)
    trap 'rm -rf -- "$temporary"' EXIT
    cp -RL "$workspace"/. "$temporary"/
    cd -- "$temporary"
    exec bats --print-output-on-failure "$1"
  fi
fi

cd -- "$(dirname -- "$0")/.."
exec bats --print-output-on-failure "$1"
