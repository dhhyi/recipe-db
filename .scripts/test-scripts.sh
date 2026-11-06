#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "$0")/.."
if (($# > 1)); then
  printf 'usage: %s [group|suite]\n' "$0" >&2
  exit 2
fi

if (($# == 0)); then
  exec bats --print-output-on-failure .scripts/tests
fi

group=$1
manifest=.scripts/tests/groups.yaml
known_group=$(group="$group" yq 'has(strenv(group))' "$manifest")
if [[ "$known_group" == true ]]; then
  test_files=$(group="$group" yq -r '.[strenv(group)].tests[]' "$manifest")
  mapfile -t tests <<< "$test_files"
  exec bats --print-output-on-failure "${tests[@]}"
fi

known_suite=$(suite="$group" yq -r \
  '[to_entries[].value.tests[] | select(. == strenv(suite))] | length' "$manifest")
if [[ "$known_suite" != 1 ]]; then
  printf 'Unknown script test group or suite: %s\n' "$group" >&2
  exit 2
fi
exec bats --print-output-on-failure "$group"
