#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "$0")/.."
if (($# > 1)); then
  printf 'usage: %s [group|suite]\n' "$0" >&2
  exit 2
fi

target=//:test_scripts
if (($# == 0)); then
  :
else
  selection=$1
  manifest=.scripts/tests/groups.yaml
  known_group=$(selection="$selection" yq 'has(strenv(selection))' "$manifest")
  if [[ "$known_group" == true ]]; then
    target="//:test_scripts_${selection}"
  else
    known_suite=$(suite="$selection" yq -r \
      '[to_entries[].value.tests[] | select(. == strenv(suite))] | length' "$manifest")
    if [[ "$known_suite" != 1 ]]; then
      printf 'Unknown script test group or suite: %s\n' "$selection" >&2
      exit 2
    fi
    suite_id=${selection#".scripts/tests/"}
    suite_id=${suite_id%.bats}
    suite_id=${suite_id//[^a-zA-Z0-9_-]/_}
    target="//:test_scripts_suite_$suite_id"
  fi
fi

mise run --raw generate-bazel-build
exec mise run --raw bazel test --test_output=errors "$target"
