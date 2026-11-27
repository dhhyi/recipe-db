# Bats supplies status and output through run.
# shellcheck disable=SC2030,SC2031,SC2153,SC2154

prepare_captured_release() {
  export MOCK_BACKUP=true MOCK_RELEASE_LIFECYCLE=false
  STATE="$FIXTURE_ROOT/backups/maintenance"
  CANDIDATE=ghcr.io/dhhyi/recipe-db-releases@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  run bash .scripts/production-k3d.sh maintenance-enter "$VALUES" "$ARTIFACT" "$STATE"
  [ "$status" -eq 0 ]
  HOLDER=$(jq -er .backupId "$STATE/backup-state.json")
  run bash .scripts/production-k3d.sh backup-capture "$VALUES" "$STATE"
  [ "$status" -eq 0 ]
  jq -n --arg id "$HOLDER" '{backupId:$id,status:"verified-upload"}' > "$FIXTURE_ROOT/backups/status.json"
  run bash .scripts/production-k3d.sh maintenance-restore "$VALUES" "$STATE"
  [ "$status" -eq 0 ]
  export MOCK_RELEASE_LIFECYCLE=true
}

prepare_candidate_release() {
  prepare_captured_release
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -eq 0 ]
}

prepare_recovery_package() {
  local package_paths
  mkdir -p provisioning/files recovery-package
  cp "$BATS_TEST_DIRNAME/../../provisioning/files/backup-upload.py" provisioning/files/
  cp "$BATS_TEST_DIRNAME/../validate-backup-package.py" .scripts/
  package_paths=$(
    python3 - "$STATE" "$FIXTURE_ROOT/recovery-package" << 'PY'
import importlib.util
import json
import pathlib
import sys

state = pathlib.Path(sys.argv[1])
stage = pathlib.Path(sys.argv[2])
module_path = pathlib.Path("provisioning/files/backup-upload.py")
spec = importlib.util.spec_from_file_location("backup_upload", module_path)
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)
manifest_path = state / "manifest.json"
manifest = json.loads(manifest_path.read_text())
result = upload.create_package(state, stage, manifest, "rehearsal",
                               upload.DEFAULT_MAX_STAGING_BYTES)
print(json.dumps({"manifest": str(stage / result["manifest"]),
                  "archive": str(stage / result["archive"])}))
PY
  )
  PACKAGE_MANIFEST=$(jq -r .manifest <<< "$package_paths")
  PACKAGE_ARCHIVE=$(jq -r .archive <<< "$package_paths")
  chmod 600 "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE"
}

complete_candidate_release() {
  local outcome=$1 use_git_sources=${2:-false}
  local -a source_args=()
  [[ $use_git_sources != true ]] || source_args=(--release-sources-from-git)
  [ "$outcome" = no-migration-required ]
  run bash .scripts/production-k3d.sh "${source_args[@]}" release-migration-plan \
    "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"release-migration-next"* ]]
  run bash .scripts/production-k3d.sh "${source_args[@]}" release-migration-next \
    "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  jq -e '.migrationResult.outcome == "no-migration-required"
    and .migrationExecution.status == "no-migration-required"' "$STATE/backup-state.json" > /dev/null
}

complete_candidate_migration() {
  export MOCK_MIGRATIONS=true MOCK_COMPLETED_MIGRATION=false
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"release-migration-status"* ]]
  export MOCK_COMPLETED_MIGRATION=true
  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"completion is not yet acknowledged"* ]]
  export MOCK_STORAGE_VERSIONS='{"recipes":1,"images":2,"ratings":1,"inspirations":1,"tags":1}'
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  jq -e '.migrationResult.outcome == "migration-succeeded"
    and .migrationExecution.status == "migration-succeeded"
    and .migrationExecution.transitions[0].status == "completed"
    and all(.migrationExecution.versions[]; .currentVersion == .requiredVersion)' \
    "$STATE/backup-state.json" > /dev/null
  export MOCK_COMPLETED_MIGRATION=false
}

prepare_published_migration_release() {
  export MOCK_MIGRATIONS=true MOCK_MULTI_MIGRATIONS=true MOCK_COMPLETED_MIGRATION=false
  export MOCK_STORAGE_VERSIONS='{"recipes":2,"images":2,"ratings":1,"inspirations":1,"tags":2}'
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  export MOCK_COMPLETED_MIGRATION=true
  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  export MOCK_STORAGE_VERSIONS='{"recipes":3,"images":2,"ratings":1,"inspirations":1,"tags":2}'
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Read-only migration candidate checks passed" \
    "READONLY-$HOLDER-passed"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -eq 0 ]

  printf '3\n' > "$FIXTURE_ROOT/tar-data/recipes/storage-version"
  printf '2\n' > "$FIXTURE_ROOT/tar-data/images/storage-version"
  printf '2\n' > "$FIXTURE_ROOT/tar-data/tags/storage-version"
  run bash .scripts/production-k3d.sh release-website-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Checked completed migration release" "WEBSITE-$HOLDER-passed"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-backup-capture "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  local post_id
  post_id=$(jq -er '.postReleaseBackup.backupId' "$STATE/backup-state.json")
  jq '.postReleaseBackup.uploadStatus="verified-upload"' \
    "$STATE/backup-state.json" > "$STATE/backup-state.next"
  mv "$STATE/backup-state.next" "$STATE/backup-state.json"
  run bash .scripts/production-k3d.sh release-backup-verify "$VALUES" "$STATE" \
    "$CANDIDATE" verified-upload "UPLOADED-$post_id-verified-upload"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-accept "$VALUES" "$STATE" \
    "$CANDIDATE" "ACCEPT-$HOLDER"
  [ "$status" -eq 0 ]

  mock_github_release_api
  jq -n --arg revision "$MOCK_REVISION" --arg candidate "$CANDIDATE" \
    --arg digest "${CANDIDATE##*@}" '
    {tag_name:"v1",target_commitish:$revision,draft:false,prerelease:false,
      published_at:"2026-11-10T12:00:00Z",
      html_url:"https://github.com/dhhyi/recipe-db/releases/tag/v1",
      body:("Completed migration; " + $candidate +
        " https://ghcr.io/v2/dhhyi/recipe-db-releases/manifests/" + $digest)}
  ' > "$MOCK_GITHUB_RELEASE_JSON"
}

migration_job_count() {
  local count=0 job
  for job in "$MOCK_LOG".migration-job*.json; do
    [[ -f $job ]] && ((count += 1))
  done
  printf '%s\n' "$count"
}

complete_candidate_release_with_start() {
  local use_git_sources=${1:-false}
  local -a source_args=()
  [[ $use_git_sources != true ]] || source_args=(--release-sources-from-git)
  complete_candidate_release no-migration-required "$use_git_sources"
  run bash .scripts/production-k3d.sh "${source_args[@]}" release-start \
    "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh "${source_args[@]}" release-readonly-result \
    "$VALUES" "$STATE" "$CANDIDATE" passed "Synthetic read-only checks passed" \
    "READONLY-$HOLDER-passed"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh "${source_args[@]}" release-reopen \
    "$VALUES" "$STATE" "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -eq 0 ]
}

create_two_release_revisions() {
  export MOCK_SOURCE_REVISION
  MOCK_SOURCE_REVISION=$(git rev-parse HEAD)
  git -c user.name=Test -c user.email=test@example.invalid \
    commit --allow-empty -qm 'Candidate fixture revision'
  export MOCK_REVISION
  MOCK_REVISION=$(git rev-parse HEAD)
}

mock_github_release_api() {
  export MOCK_GITHUB_RELEASE_JSON="$FIXTURE_ROOT/github-release.json"
  export MOCK_CURL_FAIL=false
  cat > bin/curl << 'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$MOCK_LOG"
[[ $MOCK_CURL_FAIL != true ]] || exit 22
case "${*: -1}" in
  *"/releases?"*)
    jq '[{tag_name:.tag_name,draft:.draft,prerelease:.prerelease}]' "$MOCK_GITHUB_RELEASE_JSON"
    ;;
  *) cat "$MOCK_GITHUB_RELEASE_JSON" ;;
esac
EOF
  chmod +x bin/curl
}
