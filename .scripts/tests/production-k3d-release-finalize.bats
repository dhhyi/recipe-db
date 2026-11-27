#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "accepted-release alignment status inspection preserves state Lease and access barrier" {
  prepare_captured_release
  jq --arg candidate "$CANDIDATE" --arg revision "$MOCK_REVISION" '
    .status="release-accepted" | .phase="operator-accepted" |
    .candidate={artifact:$candidate,revision:$revision} |
    .websiteCheck={outcome:"passed"} |
    .postReleaseBackup={artifact:$candidate,revision:$revision,status:"verified-upload"}
  ' "$STATE/backup-state.json" > accepted.json
  mv accepted.json "$STATE/backup-state.json"
  jq '.metadata.annotations["recipe-db/phase"]="release-accepted"' \
    "$MOCK_LOG.lease" > lease.next
  mv lease.next "$MOCK_LOG.lease"
  cp "$STATE/backup-state.json" before-state.json
  cp "$MOCK_LOG.lease" before-lease.json
  cp "$MOCK_LOG.deployments" before-deployments.json
  : > "$MOCK_LOG"

  run bash .scripts/production-k3d.sh backup-status "$VALUES" "$STATE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e --arg candidate "$CANDIDATE" --arg holder "$HOLDER" '
    .state.status == "release-accepted" and .state.candidate.artifact == $candidate
    and .lease.spec.holderIdentity == $holder
    and .lease.metadata.annotations["recipe-db/phase"] == "release-accepted"'
  cmp "$STATE/backup-state.json" before-state.json
  cmp "$MOCK_LOG.lease" before-lease.json
  cmp "$MOCK_LOG.deployments" before-deployments.json
  run grep -Eq ' (apply|patch|delete|scale|set) ' "$MOCK_LOG"
  [ "$status" -eq 1 ]

  yq -i '.timeoutSeconds = 599' "$VALUES"
  run bash .scripts/production-k3d.sh backup-status "$VALUES" "$STATE"
  [ "$status" -ne 0 ]
  [[ $output == *"recovery state does not match the explicit target and original values"* ]]
  cmp "$STATE/backup-state.json" before-state.json
  cmp "$MOCK_LOG.lease" before-lease.json
  cmp "$MOCK_LOG.deployments" before-deployments.json
}

@test "changed release requires uploaded storage markers and publication before cleanup" {
  prepare_candidate_release
  complete_candidate_release_with_start
  printf '2\n' > "$FIXTURE_ROOT/tar-data/recipes/storage-version"
  printf '2\n' > "$FIXTURE_ROOT/tar-data/tags/storage-version"
  printf '2\n' > "$FIXTURE_ROOT/tar-data/images/storage-version"
  run bash .scripts/production-k3d.sh release-website-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Checked changed public recipe feature" "WEBSITE-$HOLDER-passed"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-backup-capture "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e --arg candidate "$CANDIDATE" '
    .source.artifact == $candidate
    and all(.inventory[]; any(.files[];
      .path == "storage-version" and .storageVersion == 2))
  ' "$STATE/post-release-backup/manifest.json" > /dev/null
  local post_id
  post_id=$(jq -r '.postReleaseBackup.backupId' "$STATE/backup-state.json")
  jq '.postReleaseBackup.uploadStatus="verified-upload"' \
    "$STATE/backup-state.json" > "$STATE/backup-state.next"
  mv "$STATE/backup-state.next" "$STATE/backup-state.json"
  run bash .scripts/production-k3d.sh release-backup-verify "$VALUES" "$STATE" \
    "$CANDIDATE" verified-unchanged "UPLOADED-$post_id-verified-unchanged"
  [ "$status" -ne 0 ]
  [[ $output == *"requires post-release verified-upload"* ]]
  [ -e "$MOCK_LOG.lease" ]

  run bash .scripts/production-k3d.sh release-backup-verify "$VALUES" "$STATE" \
    "$CANDIDATE" verified-upload "UPLOADED-$post_id-verified-upload"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-accept "$VALUES" "$STATE" \
    "$CANDIDATE" "ACCEPT-$HOLDER"
  [ "$status" -eq 0 ]
  jq -e '.status == "release-accepted" and .postReleaseBackup.status == "verified-upload"' \
    "$STATE/backup-state.json" > /dev/null

  mock_github_release_api
  jq -n --arg tag v1 --arg revision "$MOCK_REVISION" --arg candidate "$CANDIDATE" \
    --arg digest "${CANDIDATE##*@}" '
    {tag_name:$tag,target_commitish:$revision,draft:false,prerelease:false,
      published_at:"2026-11-10T12:00:00Z",
      html_url:"https://github.com/dhhyi/recipe-db/releases/tag/v1",
      body:("Website checks passed; backup verified; " + $candidate +
        " https://ghcr.io/v2/dhhyi/recipe-db-releases/manifests/" + $digest)}
  ' > "$MOCK_GITHUB_RELEASE_JSON"
  export MOCK_CURL_FAIL=true
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -ne 0 ]
  [[ $output == *"temporary state and Lease are retained"* ]]
  [ -e "$STATE/backup-state.json" ]
  [ -e "$STATE/post-release-backup/manifest.json" ]
  [ -e "$MOCK_LOG.lease" ]

  export MOCK_CURL_FAIL=false
  jq '.tag_name="v9" | .html_url="https://github.com/dhhyi/recipe-db/releases/tag/v9"' \
    "$MOCK_GITHUB_RELEASE_JSON" > "$MOCK_GITHUB_RELEASE_JSON.next"
  mv "$MOCK_GITHUB_RELEASE_JSON.next" "$MOCK_GITHUB_RELEASE_JSON"
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v9 "PUBLISHED-$HOLDER-v9"
  [ "$status" -ne 0 ]
  [[ $output == *"release numbers are not contiguous"* ]]
  [ -e "$STATE/post-release-backup/manifest.json" ]
  [ -e "$MOCK_LOG.lease" ]
  jq '.tag_name="v1" | .html_url="https://github.com/dhhyi/recipe-db/releases/tag/v1"' \
    "$MOCK_GITHUB_RELEASE_JSON" > "$MOCK_GITHUB_RELEASE_JSON.next"
  mv "$MOCK_GITHUB_RELEASE_JSON.next" "$MOCK_GITHUB_RELEASE_JSON"
  export MOCK_REAL_FIND
  MOCK_REAL_FIND=$(command -v find)
  cat > bin/find << 'EOF'
#!/usr/bin/env bash
if [[ ${MOCK_FINALIZE_INTERRUPT:-false} == true ]]; then
  kill -TERM "$PPID"
  exit 143
fi
exec "$MOCK_REAL_FIND" "$@"
EOF
  chmod +x bin/find
  export MOCK_FINALIZE_INTERRUPT=true
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -eq 143 ]
  jq -e '.status == "release-published" and .phase == "published-cleanup-pending"
    and .publishedRelease.tag == "v1"' "$STATE/backup-state.json" > /dev/null
  jq -e '.metadata.annotations["recipe-db/phase"] == "release-published"' \
    "$MOCK_LOG.lease" > /dev/null
  [ -e "$STATE/post-release-backup/manifest.json" ]

  export MOCK_FINALIZE_INTERRUPT=false MOCK_CURL_FAIL=true
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -ne 0 ]
  [ -e "$STATE/post-release-backup/manifest.json" ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.phase == "published-cleanup-pending"' "$STATE/backup-state.json" > /dev/null

  export MOCK_CURL_FAIL=false
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -eq 0 ]
  [ ! -e "$STATE" ]
  [ ! -e "$MOCK_LOG.lease" ]
  local confirmation deletion
  confirmation=$(awk '/^curl / {line=NR} END {print line}' "$MOCK_LOG")
  deletion=$(awk '/delete --raw \/apis\/coordination.k8s.io\/v1\/namespaces\/kube-system\/leases\/recipe-db-deploy/ {line=NR} END {print line}' \
    "$MOCK_LOG")
  [ "$confirmation" -lt "$deletion" ]
}

@test "release finalization removes only verified completed and unused migration Jobs" {
  prepare_published_migration_release
  local job_file job_name activation_marker
  job_name=$(jq -er '.migrationExecution.transitions[] | select(.status == "completed") | .job' \
    "$STATE/backup-state.json")
  job_file="$MOCK_LOG.migration-job.json"
  if [[ $(jq -er '.metadata.name' "$job_file") != "$job_name" ]]; then
    job_file="$MOCK_LOG.migration-job-$job_name.json"
  fi
  cp "$job_file" "$job_file.original"
  jq '.metadata.annotations["recipe-db/release"]="ghcr.io/dhhyi/recipe-db-releases@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"' \
    "$job_file" > "$job_file.next"
  mv "$job_file.next" "$job_file"
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -ne 0 ]
  [[ $output == *"does not match the release and revision"* ]]
  [ "$(migration_job_count)" -eq 4 ]
  [ ! -e "$MOCK_LOG.finalize-delete-count" ]

  mv "$job_file.original" "$job_file"
  cp "$job_file" "$job_file.original"
  jq '.metadata.annotations["recipe-db/revision"]="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    "$job_file" > "$job_file.next"
  mv "$job_file.next" "$job_file"
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -ne 0 ]
  [[ $output == *"does not match the release and revision"* ]]
  [ "$(migration_job_count)" -eq 4 ]
  [ ! -e "$MOCK_LOG.finalize-delete-count" ]

  mv "$job_file.original" "$job_file"
  activation_marker="$MOCK_LOG.migration-activated-$job_name"
  cp "$job_file" "$job_file.uncertain-original"
  mv "$activation_marker" "$activation_marker.uncertain"
  jq '.spec.suspend=false | .status={}' "$job_file" > "$job_file.next"
  mv "$job_file.next" "$job_file"
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -ne 0 ]
  [[ $output == *"failed, active, or uncertain"* ]]
  [ "$(migration_job_count)" -eq 4 ]
  mv "$job_file.uncertain-original" "$job_file"
  mv "$activation_marker.uncertain" "$activation_marker"

  export MOCK_FAILED_MIGRATION=true
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -ne 0 ]
  [[ $output == *"failed, active, or uncertain"* ]]
  [ "$(migration_job_count)" -eq 4 ]
  unset MOCK_FAILED_MIGRATION

  export MOCK_FINALIZE_ACTIVE_WORKER=true
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -ne 0 ]
  [[ $output == *"active or uncertain workers"* ]]
  [ "$(migration_job_count)" -eq 4 ]
  unset MOCK_FINALIZE_ACTIVE_WORKER

  export MOCK_FINALIZE_DELETE_FAIL=true
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -ne 0 ]
  [[ $output == *"release state and Lease are retained"* ]]
  [ "$(migration_job_count)" -eq 4 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.migrationJobsCleanup.status == "pending"' "$STATE/backup-state.json" > /dev/null
  unset MOCK_FINALIZE_DELETE_FAIL

  jq -n --arg candidate "ghcr.io/dhhyi/recipe-db-releases@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" '
    {metadata:{name:"migration-other-release",
      annotations:{"recipe-db/release":$candidate,
        "recipe-db/revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
      spec:{suspend:true},status:{}}
  ' > "$MOCK_LOG.foreign-migration-job.json"
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -eq 0 ]
  [ "$(migration_job_count)" -eq 0 ]
  [ -e "$MOCK_LOG.foreign-migration-job.json" ]
  [ "$(grep -c ' delete job migration-' "$MOCK_LOG")" -eq 5 ]
  grep -q '^oras blob fetch --output .* ghcr.io/dhhyi/recipe-db-releases@sha256:' "$MOCK_LOG"
  run grep -Eq '^oras (delete|manifest delete|blob delete) ' "$MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "release finalization resumes interrupted migration Job cleanup with its Lease retained" {
  prepare_published_migration_release
  export MOCK_FINALIZE_INTERRUPT_AFTER_DELETE=true
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -eq 143 ]
  [ "$(migration_job_count)" -eq 3 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e --arg candidate "$CANDIDATE" --arg revision "$MOCK_REVISION" '
    .status == "release-published" and .phase == "published-cleanup-pending"
    and .migrationJobsCleanup.artifact == $candidate
    and .migrationJobsCleanup.revision == $revision
    and .migrationJobsCleanup.status == "pending"
  ' "$STATE/backup-state.json" > /dev/null

  unset MOCK_FINALIZE_INTERRUPT_AFTER_DELETE
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -eq 0 ]
  [ "$(migration_job_count)" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
  [ ! -e "$STATE" ]
}
