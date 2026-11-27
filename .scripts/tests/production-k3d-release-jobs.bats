#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "candidate staging creates release-specific migrator Jobs suspended without resetting them" {
  local job_name
  prepare_captured_release
  export MOCK_RELEASE_LIFECYCLE=true MOCK_MIGRATIONS=true
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'kubectl .* create -f .*migration-' "$MOCK_LOG")" -eq 1 ]
  job_name=$(jq -r '.metadata.name' "$MOCK_LOG.migration-job.json")
  grep -q "kubectl .* create -f .*${job_name}.json" "$MOCK_LOG"
  run ! grep -Eq 'kubectl .* (apply|delete|patch) .*migration-' "$MOCK_LOG"
  jq -e '
    .metadata.name == (
      "migration-" + .metadata.annotations["recipe-db/revision"][0:12] + "-"
        + .spec.template.spec.containers[0].image[-40:]
    )
    and .metadata.labels["recipe-db/revision"] == .metadata.annotations["recipe-db/revision"]
    and .metadata.annotations["recipe-db/migration-service"] == "images"
    and .spec.suspend == true
    and .spec.activeDeadlineSeconds == 300
    and .spec.backoffLimit == 0
    and .spec.template.spec.restartPolicy == "Never"
    and .spec.template.spec.automountServiceAccountToken == false
    and .spec.template.spec.containers[0].image ==
      ("ghcr.io/dhhyi/recipe-db-migrator-images-1-to-2@sha256:" + ("c" * 64))
    and .spec.template.spec.volumes ==
      [{"name":"data","persistentVolumeClaim":{"claimName":"images"}}]
  ' "$MOCK_LOG.migration-job.json"
}

@test "candidate staging preserves an existing completed migrator Job" {
  prepare_captured_release
  export MOCK_RELEASE_LIFECYCLE=true MOCK_MIGRATIONS=true MOCK_COMPLETED_MIGRATION=true
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -eq 0 ]
  jq -e '.spec.suspend == false and .status.succeeded == 1' \
    "$MOCK_LOG.existing-migration-job.json"
  run ! grep -Eq 'kubectl .* (create -f|apply|delete|patch) .*migration-' "$MOCK_LOG"
}

@test "candidate staging accepts an existing Job with a controller-uid-only selector" {
  prepare_captured_release
  export MOCK_RELEASE_LIFECYCLE=true MOCK_MIGRATIONS=true MOCK_COMPLETED_MIGRATION=true
  export MOCK_SINGLE_KEY_MIGRATION_SELECTOR=true
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -eq 0 ]
  jq -e '.spec.selector.matchLabels == {"batch.kubernetes.io/controller-uid":"existing-migration-uid"}
    and .spec.template.metadata.labels["batch.kubernetes.io/job-name"] == .metadata.name
    and .spec.suspend == false and .status.succeeded == 1' \
    "$MOCK_LOG.existing-migration-job.json"
  run ! grep -Eq 'kubectl .* (create -f|apply|delete|patch) .*migration-' "$MOCK_LOG"
}

@test "candidate staging rejects an existing migrator Job with an extra init container" {
  prepare_captured_release
  export MOCK_RELEASE_LIFECYCLE=true MOCK_MIGRATIONS=true
  export MOCK_COMPLETED_MIGRATION=true MOCK_UNSAFE_MIGRATION=true
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -ne 0 ]
  [[ $output == *"existing migrator Job"* ]]
  jq -e '.spec.template.spec.initContainers == [{name:"unexpected",image:"untrusted"}]' \
    "$MOCK_LOG.existing-migration-job.json"
  run ! grep -Eq 'kubectl .* (create -f|apply|delete|patch) .*migration-' "$MOCK_LOG"
}
