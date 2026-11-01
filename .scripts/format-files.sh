#!/usr/bin/env bash
set -euo pipefail

workspace_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$workspace_root"
project=$1
patterns=$(yq -o=json eval-all 'select(documentIndex == 1) | .format.files' "$project/.project.yaml")
if ! jq -e 'type == "array" and length > 0 and all(.[];
  type == "string" and length > 0 and
  (startswith("/") | not) and (split("/") | index("..") | not))' <<< "$patterns" > /dev/null; then
  printf 'Invalid format.files for %s\n' "$project" >&2
  exit 2
fi
pathspecs=()
while IFS= read -r pattern; do
  pathspecs+=(":(glob)$project/$pattern")
done < <(jq -r '.[]' <<< "$patterns")
if [[ ${2:-} == --inputs ]]; then
  pathspecs=("$project/")
fi
while IFS= read -r -d '' file; do
  [[ -f "$file" ]] || continue
  if [[ ${2:-} == --shell || ${2:-} == --inputs ]]; then
    jq -nrj --arg file "${file#"$project/"}" '($file | @sh) + " "'
  else
    printf '%s\0' "${file#"$project/"}"
  fi
done < <(git ls-files --cached --others --exclude-standard -z -- "${pathspecs[@]}" | sort -zu)
