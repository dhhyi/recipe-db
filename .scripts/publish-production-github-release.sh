#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s <40-character revision> <immutable release artifact> <operator-authored notes file> <acceptance evidence file>\n' "$0" >&2
  exit 2
}

[[ $# = 4 ]] || usage
revision=$1
artifact=$2
notes_file=$3
acceptance_file=$4
[[ $revision =~ ^[0-9a-f]{40}$ ]] || usage
[[ $artifact =~ ^ghcr\.io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}$ ]] || usage
[[ -f $notes_file && ! -L $notes_file && -r $notes_file ]] || usage
[[ -f $acceptance_file && ! -L $acceptance_file && -r $acceptance_file ]] || usage

jq -e --arg revision "$revision" --arg artifact "$artifact" '
  .status == "release-accepted" and .phase == "operator-accepted"
  and .candidate.revision == $revision and .candidate.artifact == $artifact
  and (.acceptedAt | type == "string" and length > 0)
  and (
    .websiteCheck.outcome == "passed"
    or (.websiteCheck.outcome == "failed"
      and .postCheckDisposition.choice == "accept-partial-failure")
  )
  and .postReleaseBackup.artifact == $artifact
  and .postReleaseBackup.revision == $revision
  and .postReleaseBackup.status == "verified-upload"
  and (.postReleaseBackup.storageVersions | type == "array" and length > 0
    and all(.[]; (.service | type == "string" and length > 0)
      and (.version | type == "number" and . > 0)))
' "$acceptance_file" > /dev/null || {
  printf 'release: candidate-bound operator acceptance and verified-upload evidence are required before publication\n' >&2
  exit 1
}

notes=$(< "$notes_file")
[[ -n $notes && $notes == *"$artifact"* ]] || {
  printf 'release: operator notes must include the exact immutable artifact reference\n' >&2
  exit 1
}
artifact_link="https://ghcr.io/v2/dhhyi/recipe-db-releases/manifests/${artifact##*@}"
[[ $notes == *"$artifact_link"* ]] || {
  printf 'release: operator notes must link directly to the immutable OCI artifact digest\n' >&2
  exit 1
}
for heading in 'Accepted gates' 'Website checks' 'Backup result' \
  'Storage versions/migrations' 'Release features'; do
  [[ $notes == *"$heading"* ]] || {
    printf 'release: operator notes must record %s\n' "$heading" >&2
    exit 1
  }
done

command -v gh > /dev/null || {
  printf 'release: GitHub CLI is required\n' >&2
  exit 1
}
releases=$(gh release list --repo dhhyi/recipe-db --limit 1000 \
  --json tagName,isDraft,isPrerelease,publishedAt) || {
  printf 'release: could not inspect published GitHub releases\n' >&2
  exit 1
}
latest=$(jq -er '
  [.[] | select(.isDraft == false and .isPrerelease == false)] as $published |
  if all($published[]; .tagName | test("^v[1-9][0-9]*$"))
  then ([$published[].tagName | ltrimstr("v") | tonumber] | max // 0)
  else error("release tags are not a complete sequential vN series")
  end
' <<< "$releases") || {
  printf 'release: existing releases do not follow the sequential vN contract\n' >&2
  exit 1
}

if ((latest > 0)); then
  expected=$(jq -cn --argjson max "$latest" '[range(1; $max + 1)]')
  actual=$(jq -c '[.[] | select(.isDraft == false and .isPrerelease == false)
    | .tagName | ltrimstr("v") | tonumber] | sort' <<< "$releases")
  [[ $actual == "$expected" ]] || {
    printf 'release: existing release numbers are not contiguous\n' >&2
    exit 1
  }
  tag="v$latest"
  current=$(gh release view "$tag" --repo dhhyi/recipe-db \
    --json tagName,targetCommitish,body,url,isDraft,isPrerelease) || {
    printf 'release: could not inspect the latest GitHub Release\n' >&2
    exit 1
  }
  if [[ $(jq -r .targetCommitish <<< "$current") == "$revision" ]] \
    && [[ $(jq -r .isDraft <<< "$current") == false ]] \
    && [[ $(jq -r .isPrerelease <<< "$current") == false ]] \
    && [[ $(jq -r .body <<< "$current") == *"$artifact"* ]] \
    && [[ $(jq -r .body <<< "$current") == *"$artifact_link"* ]]; then
    printf '%s %s\n' "$tag" "$(jq -r .url <<< "$current")"
    exit 0
  fi
fi

next=$((latest + 1))
tag="v$next"
gh release create "$tag" --repo dhhyi/recipe-db --target "$revision" \
  --title "Recipe DB $tag" --notes-file "$notes_file"
published=$(gh release view "$tag" --repo dhhyi/recipe-db \
  --json tagName,targetCommitish,body,url,isDraft,isPrerelease)
jq -e --arg tag "$tag" --arg revision "$revision" --arg artifact "$artifact" \
  --arg artifactLink "$artifact_link" '
  .tagName == $tag and .targetCommitish == $revision
  and .isDraft == false and .isPrerelease == false
  and (.body | contains($artifact) and contains($artifactLink))
' <<< "$published" > /dev/null || {
  printf 'release: GitHub did not confirm the expected published release\n' >&2
  exit 1
}
printf '%s %s\n' "$tag" "$(jq -r .url <<< "$published")"
