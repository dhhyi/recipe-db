#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "marker-only fallback stages the previous release across the checkout handoff" {
  printf '*\n' > .gitignore
  git add -f .gitignore
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Ignore generated fixture files'
  create_two_release_revisions
  prepare_captured_release
  git checkout --detach "$MOCK_REVISION" > /dev/null
  run bash .scripts/production-k3d.sh --release-sources-from-git release-stage \
    "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -eq 0 ]
  complete_candidate_release no-migration-required true

  for service in recipes images ratings inspirations tags; do
    mkdir -p "$FIXTURE_ROOT/tar-data/$service"
    printf '1\n' > "$FIXTURE_ROOT/tar-data/$service/storage-version"
  done
  local marker_before marker_after
  marker_before=$(find "$FIXTURE_ROOT/tar-data" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)

  export MOCK_RELEASE_RECIPES_ROLLOUT_FAIL=true
  run bash .scripts/production-k3d.sh --release-sources-from-git release-start \
    "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  jq -e '.status == "recovery-required" and .phase == "interrupted"' \
    "$STATE/backup-state.json" > /dev/null
  [ "$(cat "$MOCK_LOG.projection-port")" = 4001 ]
  export MOCK_RELEASE_RECIPES_ROLLOUT_FAIL=false

  local workload_changes
  workload_changes=$(grep -c 'scale deployment/' "$MOCK_LOG")
  run bash .scripts/production-k3d.sh --release-sources-from-git release-fallback-stage \
    "$VALUES" "$STATE" "$CANDIDATE" \
    "FALLBACK-$HOLDER"
  [ "$status" -ne 0 ]
  [[ $output == *"fallback requires FALLBACK-<holder>-MARKERS-1-UNCHANGED-FORMAT confirmation"* ]]
  [ "$(grep -c 'scale deployment/' "$MOCK_LOG")" -eq "$workload_changes" ]

  run bash .scripts/production-k3d.sh --release-sources-from-git release-fallback-stage \
    "$VALUES" "$STATE" "$CANDIDATE" \
    "FALLBACK-$HOLDER-MARKERS-1-UNCHANGED-FORMAT"
  [ "$status" -eq 0 ]
  jq -e --arg old "$ARTIFACT" --arg failed "$CANDIDATE" --arg revision "$MOCK_SOURCE_REVISION" '
    .status == "candidate-staged" and .phase == "candidate-staged"
    and .candidate.artifact == $old and .candidate.revision == $revision
    and .fallback.kind == "marker-only-version-1"
    and .fallback.originalRelease == $old and .fallback.failedCandidate == $failed
    and any(.candidateHistory[]; .postCheckDisposition.choice == "temporary-fix")
    and .postCheckDisposition == null
  ' "$STATE/backup-state.json" > /dev/null
  jq -e 'all(.items[]; .spec.replicas == 0)' "$MOCK_LOG.deployments" > /dev/null
  jq -e --arg holder "$HOLDER" --arg old "$ARTIFACT" '
    .spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/release"] == $old
    and .metadata.annotations["recipe-db/phase"] == "candidate-staged"
  ' "$MOCK_LOG.lease" > /dev/null

  CANDIDATE=$ARTIFACT
  complete_candidate_release_with_start true
  jq -e '.status == "access-open" and .candidate.artifact == .source.artifact' \
    "$STATE/backup-state.json" > /dev/null
  marker_after=$(find "$FIXTURE_ROOT/tar-data" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
  [ "$marker_after" = "$marker_before" ]
}

@test "pinned tooling continues immutable release sources without switching back to obsolete tools" {
  create_two_release_revisions
  prepare_captured_release
  printf '*\n' > .gitignore
  git add -f .gitignore
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Separate tooling revision'
  local tooling_revision
  tooling_revision=$(git rev-parse HEAD)

  printf '\n' >> .scripts/production-k3d.sh
  run bash .scripts/production-k3d.sh --release-sources-from-git release-stage \
    "$VALUES" "$STATE" "$CANDIDATE" verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -ne 0 ]
  [[ $output == *"require a clean tooling checkout"* ]]
  git restore .scripts/production-k3d.sh

  run bash .scripts/production-k3d.sh --release-sources-from-git release-stage \
    "$VALUES" "$STATE" "$CANDIDATE" verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -eq 0 ]
  jq -e --arg revision "$tooling_revision" '.toolingRevision == $revision' \
    "$STATE/backup-state.json" > /dev/null
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"requires its pinned tooling revision"* ]]
  run bash .scripts/production-k3d.sh --release-sources-from-git release-migration-plan \
    "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh --release-sources-from-git release-migration-next \
    "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  export MOCK_RELEASE_RECIPES_ROLLOUT_FAIL=true
  run bash .scripts/production-k3d.sh --release-sources-from-git release-start \
    "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  export MOCK_RELEASE_RECIPES_ROLLOUT_FAIL=false
  run bash .scripts/production-k3d.sh --release-sources-from-git release-fallback-stage \
    "$VALUES" "$STATE" "$CANDIDATE" "FALLBACK-$HOLDER-MARKERS-1-UNCHANGED-FORMAT"
  [ "$status" -eq 0 ]
  [ "$(git rev-parse HEAD)" = "$tooling_revision" ]
  run bash .scripts/production-k3d.sh --release-sources-from-git release-migration-plan \
    "$VALUES" "$STATE" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh --release-sources-from-git release-migration-next \
    "$VALUES" "$STATE" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh --release-sources-from-git release-start \
    "$VALUES" "$STATE" "$ARTIFACT"
  [ "$status" -eq 0 ]
  jq -e --arg holder "$HOLDER" '.spec.holderIdentity == $holder' "$MOCK_LOG.lease" > /dev/null
}
