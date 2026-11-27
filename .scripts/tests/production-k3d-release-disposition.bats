#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "temporary-fix disposition closes access and permits a guarded subsequent release" {
  prepare_candidate_release
  complete_candidate_release_with_start
  run bash .scripts/production-k3d.sh release-disposition "$VALUES" "$STATE" "$CANDIDATE" \
    temporary-fix "DISPOSITION-$HOLDER-temporary-fix"
  [ "$status" -eq 0 ]
  jq -e '.postCheckDisposition.choice == "temporary-fix"' "$STATE/backup-state.json" > /dev/null
  [ "$(jq -r '.status + "/" + .phase' "$STATE/backup-state.json")" = \
    "post-check-disposition/temporary-fix" ]
  [ "$(jq -r '.spec.holderIdentity' "$MOCK_LOG.lease")" = "$HOLDER" ]
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "backup"
      and .spec.replicas == 1' "$MOCK_LOG.deployments" > /dev/null
  jq -e 'all(.items[] | select(.metadata.name != "graphql"); .spec.replicas == 0)' \
    "$MOCK_LOG.deployments" > /dev/null

  local next_candidate=ghcr.io/dhhyi/recipe-db-releases@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$next_candidate" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -eq 0 ]
  jq -e --arg candidate "$next_candidate" --arg previous "$CANDIDATE" '
    .candidate.artifact == $candidate
    and .candidateHistory[-1].candidate.artifact == $previous
    and .candidateHistory[-1].postCheckDisposition.choice == "temporary-fix"
    and .candidateHistory[-1].readOnlyCheck.outcome == "passed"
    and .readOnlyCheck == null and .readOnlyCheckHistory == []
    and .migrationResult == null and .postCheckDisposition == null
  ' "$STATE/backup-state.json" > /dev/null
  CANDIDATE=$next_candidate
  complete_candidate_release_with_start
  jq -e '.status == "access-open" and .phase == "operator-reopened"' "$STATE/backup-state.json" > /dev/null
}

@test "migration recovery cannot discard public writes after a temporary-fix restaging" {
  prepare_candidate_release
  complete_candidate_release_with_start
  run bash .scripts/production-k3d.sh release-disposition "$VALUES" "$STATE" "$CANDIDATE" \
    temporary-fix "DISPOSITION-$HOLDER-temporary-fix"
  [ "$status" -eq 0 ]
  export MOCK_MIGRATIONS=true
  CANDIDATE=ghcr.io/dhhyi/recipe-db-releases@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  export MOCK_FAILED_MIGRATION=true
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  jq -e '.phase == "migration-failed" and .postCheckDisposition == null
    and .accessOpenedAt != null and .publicAccessMayHaveOpenedAt != null
    and any(.candidateHistory[]; .postCheckDisposition.choice == "temporary-fix")' \
    "$STATE/backup-state.json" > /dev/null
  local before confirmation calls
  before=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)
  calls=$(wc -l < "$MOCK_LOG")
  confirmation=$(jq -er '"CLEAR-AND-RESTORE-\(.backupVerification.backupId)-\(.candidate.revision)-ATTEMPT-1"' \
    "$STATE/backup-state.json")
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$STATE/package.json" "$STATE/package.tar.gz" "$HOLDER" "$confirmation"
  [ "$status" -ne 0 ]
  [[ $output == *"forbidden after any public reopening"* ]]
  [ "$before" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  sed -n "$((calls + 1)),\$p" "$MOCK_LOG" > "$MOCK_LOG.post-reopen-recovery"
  run ! grep -Eq 'restore-volume|delete pvc|create -f .*migration-claim' "$MOCK_LOG.post-reopen-recovery"
}

@test "operator may explicitly accept a partial failure without rollback or restore" {
  prepare_candidate_release
  complete_candidate_release_with_start
  run bash .scripts/production-k3d.sh release-disposition "$VALUES" "$STATE" "$CANDIDATE" \
    accept-partial-failure "DISPOSITION-$HOLDER-accept-partial-failure"
  [ "$status" -eq 0 ]
  jq -e '.postCheckDisposition.choice == "accept-partial-failure"' "$STATE/backup-state.json" > /dev/null
  [ "$(jq -r '.spec.holderIdentity' "$MOCK_LOG.lease")" = "$HOLDER" ]
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "production"' "$MOCK_LOG.deployments" > /dev/null
  jq -e --arg candidate "$CANDIDATE" '
    all(.items[]; .metadata.name == "graphql"
      or .spec.template.metadata.annotations["recipe-db/release"] == $candidate)
  ' "$MOCK_LOG.deployments" > /dev/null
}

@test "website failure blocks post-release capture and keeps the release operation" {
  prepare_candidate_release
  complete_candidate_release_with_start
  run bash .scripts/production-k3d.sh release-website-result "$VALUES" "$STATE" \
    "$CANDIDATE" failed "Changed feature did not work" "WEBSITE-$HOLDER-failed"
  [ "$status" -eq 0 ]
  [[ $output == *"no post-release backup"* ]]
  [ ! -e "$STATE/post-release-backup" ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.websiteCheck.outcome == "failed"' "$STATE/backup-state.json" > /dev/null

  run bash .scripts/production-k3d.sh release-backup-capture "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"requires a passed website check or explicit partial-failure acceptance"* ]]
  [ ! -e "$STATE/post-release-backup" ]
  [ -e "$MOCK_LOG.lease" ]

  run bash .scripts/production-k3d.sh release-disposition "$VALUES" "$STATE" "$CANDIDATE" \
    accept-partial-failure "DISPOSITION-$HOLDER-accept-partial-failure"
  [ "$status" -eq 0 ]
  printf '2\n' > "$FIXTURE_ROOT/tar-data/recipes/storage-version"
  printf '2\n' > "$FIXTURE_ROOT/tar-data/tags/storage-version"
  printf '2\n' > "$FIXTURE_ROOT/tar-data/images/storage-version"
  run bash .scripts/production-k3d.sh release-backup-capture "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  jq -e '.postCheckDisposition.choice == "accept-partial-failure"
    and .websiteCheck.outcome == "failed"
    and .postReleaseBackup.status == "captured"' "$STATE/backup-state.json" > /dev/null
  local post_id
  post_id=$(jq -r '.postReleaseBackup.backupId' "$STATE/backup-state.json")
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
      body:("Partial failure explicitly accepted; " + $candidate +
        " https://ghcr.io/v2/dhhyi/recipe-db-releases/manifests/" + $digest)}
  ' > "$MOCK_GITHUB_RELEASE_JSON"
  run bash .scripts/production-k3d.sh release-finalize "$VALUES" "$STATE" \
    "$CANDIDATE" v1 "PUBLISHED-$HOLDER-v1"
  [ "$status" -eq 0 ]
  [ ! -e "$STATE" ]
  [ ! -e "$MOCK_LOG.lease" ]
}
