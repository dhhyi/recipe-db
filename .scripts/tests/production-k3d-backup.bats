#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "backup recovery resets and verifies both storage helper modes" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-helpers"
  jq '(.items[] | select(.metadata.name == "recipes").spec.template.spec) |=
    (.initContainers=[{name:"storage-version-gate",env:[{name:"MODE",value:"production"}]}] |
     .containers += [{name:"storage-version",env:[{name:"MODE",value:"production"}]}])' \
    "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"

  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  local mode container
  for mode in backup production; do
    for container in recipes storage-version storage-version-gate; do
      grep -Fq "set env deployment/recipes MODE=$mode --containers=$container" "$MOCK_LOG"
    done
  done
  jq -e '.items[] | select(.metadata.name == "recipes") | .spec.template.spec |
    all((.containers[], .initContainers[]); all(.env[]? | select(.name == "MODE"); .value == "production"))' \
    "$MOCK_LOG.deployments"
}

@test "backup uses the deploy Lease, GraphQL barrier, metadata-selected PVCs and read-only copies" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-success"

  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  [ -f "$snapshot/manifest.json" ]
  [ ! -e "$snapshot/backup-state.json" ]
  jq -e --arg artifact "$ARTIFACT" --arg revision "$MOCK_REVISION" '
    .format == "recipe-db-pvc-snapshot" and .formatVersion == 1
    and .source.artifact == $artifact and .source.revision == $revision
    and any(.inventory[]; .service == "tags" and .role == "cleanup-participant")
    and all(.inventory[]; (.sha256 | test("^[0-9a-f]{64}$")) and .sizeBytes > 0)
  ' "$snapshot/manifest.json" > /dev/null
  [ ! -e "$MOCK_LOG.lease" ]
  grep -q 'get --raw /api/v1/namespaces/recipe-db/pods?watch=true&resourceVersion=1&timeoutSeconds=600' "$MOCK_LOG"
  local barrier scale_normal backup_mode cleanup copy last_normal_stop
  barrier=$(grep -n 'set env deployment/graphql MODE=backup' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  scale_normal=$(grep -n 'scale deployment/recipes --replicas=0' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  backup_mode=$(grep -n 'set env deployment/recipes MODE=backup' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  last_normal_stop=$(awk -v limit="$backup_mode" 'NR < limit && /scale deployment\/(recipes|images|tags) --replicas=0/ {line=NR} END {print line}' "$MOCK_LOG")
  cleanup=$(grep -n 'wait --for=condition=complete job/backup-cleanup' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  copy=$(grep -n 'create -f .*copy-pod.json' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  [ "$barrier" -lt "$scale_normal" ]
  [ "$last_normal_stop" -lt "$backup_mode" ]
  [ "$backup_mode" -lt "$cleanup" ]
  [ "$cleanup" -lt "$copy" ]
  [ "$(grep -c 'create -f .*copy-pod.json' "$MOCK_LOG")" -eq 3 ]
  [ "$(grep -c ' MODE=production ' "$MOCK_LOG")" -ge 4 ]
  grep -q 'scale deployment/recipes --replicas=1' "$MOCK_LOG"
}

@test "backup refuses deployment contention before changing GraphQL or backends" {
  export MOCK_BACKUP=true MOCK_LOCK=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-locked"

  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"cannot be acquired"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -Eq 'set env|scale deployment' "$MOCK_LOG"
}

@test "backup cleanup exhaustion restores production and never publishes a snapshot" {
  export MOCK_BACKUP=true MOCK_CLEANUP_FAIL=true
  printf 'stale image purged before another cleanup operation failed' > "$FIXTURE_ROOT/tar-data/images/public/stale.png"
  local snapshot="$FIXTURE_ROOT/backups/snapshot-cleanup-failed"

  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"no complete snapshot was published"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$snapshot/recipes.tar" ]
  [ ! -e "$FIXTURE_ROOT/tar-data/images/public/stale.png" ]
  [ "$(grep -c 'wait --for=condition=complete job/backup-cleanup' "$MOCK_LOG")" -eq 1 ]
  [ ! -e "$MOCK_LOG.lease" ]
  grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
  jq -e '.status == "failed" and .phase == "safely-recovered"' \
    "$snapshot/backup-state.json" > /dev/null
}

@test "backup copy failure restores production and publishes no manifest" {
  export MOCK_BACKUP=true MOCK_COPY_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-copy-failed"

  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"no complete snapshot was published"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$MOCK_LOG.lease" ]
  jq -e '.status == "failed" and .phase == "safely-recovered"' \
    "$snapshot/backup-state.json" > /dev/null
}

@test "unsafe backup recovery preserves the GraphQL barrier, state and Lease" {
  export MOCK_BACKUP=true MOCK_CLEANUP_FAIL=true MOCK_RECOVERY_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-recovery-failed"

  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"GraphQL barrier and cluster Lease are retained"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ -f "$snapshot/backup-state.json" ]
  jq -e '.status == "recovery-required" and .phase == "recovery-required"' \
    "$snapshot/backup-state.json" > /dev/null
  jq -e '.metadata.annotations["recipe-db/phase"] == "recovery-required"' \
    "$MOCK_LOG.lease" > /dev/null
  grep -q 'set env deployment/graphql MODE=backup' "$MOCK_LOG"
  grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
}

@test "forced termination prevents capture and preserves actionable recovery state" {
  export MOCK_BACKUP=true MOCK_FORCED_TERMINATION=capture
  local snapshot="$FIXTURE_ROOT/backups/forced"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"force-killed"* ]]
  [ -e "$MOCK_LOG.cleaned" ]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -q 'copy-pod.json' "$MOCK_LOG"
}
