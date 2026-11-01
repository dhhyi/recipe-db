#!/bin/sh
set -eu

command=$1
count=$2
shift 2
original=$(pwd -P)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
mkdir "$temporary/project"

index=0
for file in "$@"; do
  index=$((index + 1))
  [ "$index" -gt "$count" ] || continue
  mkdir -p "$temporary/project/$(dirname -- "$file")"
  cp -L -- "$file" "$temporary/project/$file"
done

# Reuse installed dependencies, never link formatter source inputs.
for directory in node_modules deps .pnpm-store; do
  if [ -d "$original/$directory" ] && [ ! -e "$temporary/project/$directory" ]; then
    ln -s "$original/$directory" "$temporary/project/$directory"
  fi
done

run_formatter() {
  cd "$temporary/project"
  fish -c "$command" -- "$@"
}

files_count=$#
remaining=$count
while [ "$remaining" -gt 0 ]; do
  # Rotate the selected files to the end, then discard the copy-input list.
  first=$1
  shift
  set -- "$@" "$first"
  remaining=$((remaining - 1))
done
discard=$((files_count - count))
# The formatter arguments are resolved files; copy inputs must not reach it.
shift "$discard"
if ! run_formatter "$@"; then
  echo "Formatter/tool failed while checking formatting" >&2
  exit 2
fi
result=0
for file in "$@"; do
  if ! cmp -s -- "$original/$file" "$temporary/project/$file"; then
    printf 'Unformatted file: %s\n' "$file" >&2
    result=3
  fi
done
exit "$result"
