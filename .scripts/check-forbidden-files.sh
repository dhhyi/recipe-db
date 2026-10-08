#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"

tracked_files=$(git ls-files)
status=0

forbidden_gitignores=""
for file in $(printf '%s\n' "$tracked_files" | grep -E '(^|/)\.gitignore$' || true); do
  if [ "$file" = ".gitignore" ]; then
    continue
  fi
  directory=${file%/.gitignore}
  if [ -f "$directory/.project.yaml" ]; then
    continue
  fi
  forbidden_gitignores="${forbidden_gitignores:+$forbidden_gitignores, }$file"
done
if [ -n "$forbidden_gitignores" ]; then
  echo "Forbidden .gitignore files found: $forbidden_gitignores" >&2
  status=1
fi

forbidden_prettierignores=""
for file in $(printf '%s\n' "$tracked_files" | grep -E '(^|/)\.prettierignore$' || true); do
  forbidden_prettierignores="${forbidden_prettierignores:+$forbidden_prettierignores, }$file"
done
if [ -n "$forbidden_prettierignores" ]; then
  echo "Forbidden files found: $forbidden_prettierignores" >&2
  status=1
fi

exit "$status"
