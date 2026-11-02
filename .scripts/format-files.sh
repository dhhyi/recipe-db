#!/usr/bin/env bash
set -euo pipefail

workspace_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$workspace_root"
project=$1
formatter_index=${2:-}
mode=${3:-}
if [[ $formatter_index == --* ]]; then
  mode=$formatter_index
  formatter_index=
fi
if [[ -n $formatter_index ]]; then
  patterns=$(yq -o=json eval-all "select(documentIndex == 1) | .format[$formatter_index].files" "$project/.project.yaml")
else
  patterns=$(yq -o=json eval-all 'select(documentIndex == 1) | [.format[]?.files[]?]' "$project/.project.yaml")
fi
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
if [[ $mode == --inputs ]]; then
  pathspecs=("$project/")
fi
file_list=$(mktemp)
trap 'rm -f "$file_list"' EXIT
git ls-files --cached --others --exclude-standard -z -- "${pathspecs[@]}" > "$file_list"
sort -zu "$file_list" -o "$file_list"
while IFS= read -r -d '' file; do
  [[ -f "$file" ]] || continue
  if [[ $mode == --shell || $mode == --inputs ]]; then
    jq -nrj --arg file "${file#"$project/"}" '($file | @sh) + " "'
  else
    printf '%s\0' "${file#"$project/"}"
  fi
done < "$file_list"
