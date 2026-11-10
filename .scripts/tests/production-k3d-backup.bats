#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

@test "backup uses the deploy Lease, GraphQL barrier, metadata-selected PVCs and read-only copies" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-success"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
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

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"cannot be acquired"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -Eq 'set env|scale deployment' "$MOCK_LOG"
}

@test "backup cleanup exhaustion restores production and never publishes a snapshot" {
  export MOCK_BACKUP=true MOCK_CLEANUP_FAIL=true
  printf 'stale image purged before another cleanup operation failed' > "$FIXTURE_ROOT/tar-data/images/public/stale.png"
  local snapshot="$FIXTURE_ROOT/backups/snapshot-cleanup-failed"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
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

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
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

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
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

@test "manual backup enter status and exit preserve the durable lock and restore prior counts" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/manual"
  jq '(.items[] | select(.metadata.name == "tags")) |=
    (.spec.replicas=2 | .status.readyReplicas=2)' "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  [ -f "$MOCK_LOG.lease" ]
  [ ! -e "$snapshot/manifest.json" ]
  jq -e '.status == "backup-mode" and .phase == "maintenance-entered"' "$snapshot/backup-state.json"
  run ! grep -q 'copy-pod.json' "$MOCK_LOG"
  local holder
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  run bash .scripts/production-k3d.sh backup-status "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  [[ $output == *"$holder"* ]]
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" "$holder" "RECOVER-$holder"
  [ "$status" -ne 0 ]
  [ -f "$MOCK_LOG.lease" ]
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovered"' "$snapshot/backup-state.json"
  jq -e '.items[] | select(.metadata.name == "tags") | .spec.replicas == 2' "$MOCK_LOG.deployments"
}

@test "maintenance capture continues the saved operation and retains its lock and recovery state" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/maintenance-capture" holder
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  run bash .scripts/production-k3d.sh backup-capture "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  [ -f "$snapshot/manifest.json" ]
  [ -f "$snapshot/backup-state.json" ]
  jq -e '.stateVersion == 2 and .status == "captured" and .phase == "captured"' \
    "$snapshot/backup-state.json"
  jq -e --arg holder "$holder" '.spec.holderIdentity == $holder' "$MOCK_LOG.lease"
  jq -e 'all(.inventory[]; .storage.uid != null and .storage.volumeName != null
    and .storage.storageClassName == "local-path" and .layout.kind != null)' \
    "$snapshot/manifest.json"
  run ! grep -q ' MODE=production ' "$MOCK_LOG"
  grep -q 'scale deployment/recipes --replicas=0' "$MOCK_LOG"
  grep -q 'create -f .*copy-pod.json' "$MOCK_LOG"
  run bash .scripts/production-k3d.sh backup-status "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "forced termination prevents capture and preserves actionable recovery state" {
  export MOCK_BACKUP=true MOCK_FORCED_TERMINATION=capture
  local snapshot="$FIXTURE_ROOT/backups/forced"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"force-killed"* ]]
  [ -e "$MOCK_LOG.cleaned" ]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -q 'copy-pod.json' "$MOCK_LOG"
}

@test "missing authoritative database refuses publication" {
  export MOCK_BACKUP=true
  rm "$FIXTURE_ROOT/tar-data/tags/tags.sqlite"
  local snapshot="$FIXTURE_ROOT/backups/missing"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"missing authoritative database"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "capture measures actual archive bytes instead of trusting unenforced PVC requests" {
  export MOCK_BACKUP=true
  export MOCK_ARCHIVE_BYTES
  MOCK_ARCHIVE_BYTES=$(df -Pk "$FIXTURE_ROOT/backups" \
    | awk 'NR == 2 {printf "%.0f\n", $4 * 1024 - 67108864 + 1}')
  local snapshot="$FIXTURE_ROOT/backups/insufficient-measured-space"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"measured archive capacity"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -q 'exec backup-copy-.*-- tar -C' "$MOCK_LOG"
}

@test "capture respects the publisher staging bound before copying a PVC archive" {
  export MOCK_BACKUP=true RECIPE_DB_BACKUP_MAX_SNAPSHOT_BYTES=1
  local snapshot="$FIXTURE_ROOT/backups/staging-limit"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"snapshot exceeds configured staging limit"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$snapshot/recipes.tar" ]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -q 'exec backup-copy-.*-- tar -C' "$MOCK_LOG"
}

@test "projection failure retains the barrier Lease and recovery state" {
  export MOCK_BACKUP=true MOCK_PROJECTION_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/projection-failed"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"projection recovery failed"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$snapshot/backup-state.json"
  run ! grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
}

@test "manual recovery refuses changed target values and holders without touching workloads" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/recovery-identity" holder before
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  before=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" wrong EXIT-wrong
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq "$before" ]
  set_value '.timeoutSeconds=601'
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"original values"* ]]
  [ -e "$MOCK_LOG.lease" ]
  [ "$(wc -l < "$MOCK_LOG")" -eq "$before" ]
}

@test "projection refresh completes before the GraphQL client barrier is removed" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/projections"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  local refresh reopen
  refresh=$(awk '/rollout status deployment\/search / {line=NR} END {print line}' "$MOCK_LOG")
  reopen=$(awk '/set env deployment\/graphql MODE=production/ {print NR; exit}' "$MOCK_LOG")
  [ "$refresh" -lt "$reopen" ]
  grep -q '"targetPort":4001' "$MOCK_LOG"
  grep -q '"targetPort":4000' "$MOCK_LOG"
  jq -e '.inventory[] | select(.service == "tags") |
    any(.files[]; .path == "tags.sqlite-wal")' "$snapshot/manifest.json"
  jq -e 'all(.inventory[]; .service != "search" and .service != "browse")' "$snapshot/manifest.json"
}

@test "backup rejects image drift despite unchanged release annotations" {
  export MOCK_BACKUP=true
  jq '(.items[] | select(.metadata.name == "recipes").spec.template.spec.containers[0].image)="foreign:latest"' \
    "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/image-drift"
  [ "$status" -ne 0 ]
  [[ $output == *"container images do not match"* ]]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'scale deployment/|set env deployment/' "$MOCK_LOG"
}

@test "manual recovery refuses changed container digests before touching workloads" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/recovery-image-drift" holder before
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  jq '(.items[] | select(.metadata.name == "recipes").spec.template.spec.containers[0].image)="foreign:latest"' \
    "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  before=$(grep -Ec 'scale deployment/|set env deployment/' "$MOCK_LOG")
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"container images do not match"* ]]
  [ -e "$MOCK_LOG.lease" ]
  [ "$(grep -Ec 'scale deployment/|set env deployment/' "$MOCK_LOG")" -eq "$before" ]
}

@test "backup refuses modified release metadata before connecting or acquiring a Lease" {
  export MOCK_BACKUP=true
  printf '\n# changed classification\n' >> .scripts/lib/project-metadata.sh
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/metadata-drift"
  [ "$status" -ne 0 ]
  [[ $output == *"metadata and templates must match"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "backup refuses untracked metadata even if gitignored" {
  export MOCK_BACKUP=true
  mkdir extra-backend
  printf 'category: backend\n' > extra-backend/.project.yaml
  printf 'extra-backend/\n' > .gitignore
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/untracked-metadata"
  [ "$status" -ne 0 ]
  [[ $output == *"untracked metadata"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "backup permits unrelated checkout changes when release inputs are unchanged" {
  export MOCK_BACKUP=true
  printf 'unrelated documentation\n' > note.txt
  git add note.txt
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Unrelated checkout change'
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/same-inputs"
  [ "$status" -eq 0 ]
}

@test "acquired backup Lease can be explicitly recovered before any workload mutation" {
  jq -n '{metadata:{name:"recipe-db-deploy",namespace:"kube-system",uid:"lease-uid",resourceVersion:"42",
    labels:{"app.kubernetes.io/part-of":"recipe-db"},
    annotations:{"recipe-db/operation":"backup","recipe-db/phase":"acquired"}},
    spec:{holderIdentity:"backup-preflight"}}' > "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" backup-preflight RECOVER-backup-preflight
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'scale deployment/|set env deployment/' "$MOCK_LOG"
}

@test "recovered backend validation happens before GraphQL is reopened" {
  export MOCK_BACKUP=true MOCK_RECOVERY_DRIFT=true
  local snapshot="$FIXTURE_ROOT/backups/recovery-count-drift"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"recovered backend state could not be verified"* ]]
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
}

@test "failed GraphQL reopen and reblock rollout falls back to stopping all GraphQL Pods" {
  export MOCK_BACKUP=true MOCK_GRAPHQL_REOPEN_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/reopen-failure"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"stopping GraphQL to preserve the client barrier"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e 'any(.items[]; .metadata.name == "graphql" and .spec.replicas == 0)' "$MOCK_LOG.deployments"
  jq -e '.status == "recovery-required"' "$snapshot/backup-state.json"
}

@test "backup-exit stops cleanup workers before production backends resume" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/cleanup-interrupted" holder before stopped restored
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  [ -e "$MOCK_LOG.cleanup-job" ]
  before=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.cleanup-job" ]
  stopped=$(awk -v before="$before" 'NR > before && /get pods -l job-name=backup-cleanup/ {print NR; exit}' "$MOCK_LOG")
  restored=$(awk -v before="$before" 'NR > before && /set env deployment\/recipes MODE=production/ {print NR; exit}' "$MOCK_LOG")
  [ "$stopped" -lt "$restored" ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "backup-exit retains the barrier and Lease if cleanup workers cannot be deleted" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/cleanup-not-stopped" holder
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  export MOCK_CLEANUP_DELETE_FAIL=true
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"cleanup workers could not be stopped"* ]]
  [ -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'set env deployment/(recipes|graphql) MODE=production' "$MOCK_LOG"
}
