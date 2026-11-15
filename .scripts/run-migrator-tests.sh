#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd -P)
export LC_ALL=C
shopt -s nullglob
migrators=("$project_root"/migrators/*/)

if ((${#migrators[@]} == 0)); then
  echo "No migrators found."
  exit 0
fi

for migrator in "${migrators[@]}"; do
  test_script="${migrator}test-migrator.sh"
  if [[ ! -f "$test_script" ]]; then
    printf 'Missing required migrator test: %s\n' "${test_script#"$project_root"/}" >&2
    exit 1
  fi
  echo "::group::${test_script#"$project_root"/}"
  sh "$test_script"
  echo "::endgroup::"
done
