#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

prepare_captured_release() {
  export MOCK_BACKUP=true MOCK_RELEASE_LIFECYCLE=false
  STATE="$FIXTURE_ROOT/backups/release"
  CANDIDATE=ghcr.io/dhhyi/recipe-db-releases@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$STATE"
  [ "$status" -eq 0 ]
  HOLDER=$(jq -er .backupId "$STATE/backup-state.json")
  run bash .scripts/production-k3d.sh backup-capture "$VALUES" "$STATE"
  [ "$status" -eq 0 ]
  export MOCK_RELEASE_LIFECYCLE=true
}

prepare_candidate_release() {
  prepare_captured_release
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -eq 0 ]
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
    and .migrationExecution.transitions[0].status == "completed"' "$STATE/backup-state.json" > /dev/null
  export MOCK_COMPLETED_MIGRATION=false
}

complete_candidate_release_with_start() {
  local use_git_sources=${1:-false}
  local -a source_args=()
  [[ $use_git_sources != true ]] || source_args=(--release-sources-from-git)
  complete_candidate_release no-migration-required "$use_git_sources"
  run bash .scripts/production-k3d.sh "${source_args[@]}" release-start \
    "$VALUES" "$STATE" "$CANDIDATE"
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

@test "pinned tooling captures maintenance using the original release sources and existing guards" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/pinned-capture" old_revision holder
  local receipt="$FIXTURE_ROOT/legacy-identities.json"
  mkdir recipes
  printf 'old metadata\n' > recipes/.project.yaml
  # shellcheck disable=SC2016
  sed -i '/^application_project_metadata_to_jsonl() {/a\  cat "$1/recipes/.project.yaml" >> "$MOCK_LOG.metadata-source"' \
    .scripts/lib/project-metadata.sh
  printf '*\n' > .gitignore
  git add -f .gitignore recipes/.project.yaml .scripts/lib/project-metadata.sh
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Original fixture metadata'
  old_revision=$(git rev-parse HEAD)
  export MOCK_REVISION="$old_revision" MOCK_SOURCE_REVISION="$old_revision"

  jq -n --slurpfile values "$VALUES" '{
    format:"recipe-db-legacy-storage-identities",formatVersion:1,
    recordedAt:"2000-01-01T00:00:00Z",
    source:($values[0] | {target,cluster,context,namespace}),
    namespaceUids:{system:"system-namespace",application:"application-namespace"},
    pvcs:(["recipes","images","tags"] | map({
      name:.,uid:("claim-"+.),volumeName:("pv-"+.),volumeUid:("uid-pv-"+.)}))
  }' > "$receipt"
  chmod 600 "$receipt"
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  jq 'del(.stateVersion) | .selectedPVCs |= map(del(.storage))' \
    "$snapshot/backup-state.json" > legacy-state.json
  cp legacy-state.json "$snapshot/backup-state.json"
  printf 'new metadata\n' > recipes/.project.yaml
  printf 'new template input\n' > message-bus/nats.conf
  sed -i "s/a7e14347b604a35875ed0716c645d7b2436b6aac/$old_revision/" .scripts/production-k3d.sh
  git add -f recipes/.project.yaml message-bus/nats.conf .scripts/production-k3d.sh
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'New tooling inputs'
  MOCK_REVISION=$(git rev-parse HEAD)

  run bash .scripts/production-k3d.sh backup-capture "$VALUES" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"metadata and templates must match"* ]]
  printf '\n' >> .scripts/production-k3d.sh
  run bash .scripts/production-k3d.sh --release-sources-from-git backup-capture "$VALUES" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"require a clean tooling checkout"* ]]
  git restore .scripts/production-k3d.sh
  run bash .scripts/production-k3d.sh --release-sources-from-git backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"limited to render, backup-capture and guarded release operations"* ]]

  cp "$snapshot/backup-state.json" original-state.json
  jq --arg revision "$MOCK_REVISION" '.source.revision = $revision' \
    original-state.json > "$snapshot/backup-state.json"
  MOCK_SOURCE_REVISION=$MOCK_REVISION
  run bash .scripts/production-k3d.sh --release-sources-from-git backup-capture "$VALUES" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"maintenance state is not ready"* ]]
  MOCK_SOURCE_REVISION=$old_revision
  cp original-state.json "$snapshot/backup-state.json"
  run bash .scripts/production-k3d.sh --release-sources-from-git backup-capture "$VALUES" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"requires a pre-maintenance identity receipt"* ]]
  cp "$MOCK_LOG.lease" original-lease.json
  jq '.spec.holderIdentity = "other-holder"' original-lease.json > "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh --release-sources-from-git backup-capture "$VALUES" "$snapshot" "$receipt"
  [ "$status" -ne 0 ]
  [[ $output == *"maintenance Lease does not match saved state"* ]]
  cmp original-state.json "$snapshot/backup-state.json"
  cp original-lease.json "$MOCK_LOG.lease"

  jq '.selectedPVCs[0].pvc = "unexpected"' original-state.json > "$snapshot/backup-state.json"
  run bash .scripts/production-k3d.sh --release-sources-from-git backup-capture "$VALUES" "$snapshot" "$receipt"
  [ "$status" -ne 0 ]
  [[ $output == *"legacy maintenance PVC inventory does not match"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  cp original-state.json "$snapshot/backup-state.json"
  cp original-lease.json "$MOCK_LOG.lease"

  local drift
  for drift in MOCK_LEGACY_PVC_DRIFT MOCK_LEGACY_PV_DRIFT; do
    export "$drift=true"
    run bash .scripts/production-k3d.sh --release-sources-from-git backup-capture "$VALUES" "$snapshot" "$receipt"
    [ "$status" -ne 0 ]
    [[ $output == *"PVC or PV identity changed"* ]]
    [ ! -e "$snapshot/manifest.json" ]
    unset "$drift"
    cp original-state.json "$snapshot/backup-state.json"
    cp original-lease.json "$MOCK_LOG.lease"
  done
  cp "$receipt" original-receipt.json
  jq --arg time "$(jq -r .startedAt original-state.json)" '.recordedAt=$time' \
    original-receipt.json > "$receipt"
  run bash .scripts/production-k3d.sh --release-sources-from-git backup-capture "$VALUES" "$snapshot" "$receipt"
  [ "$status" -ne 0 ]
  [[ $output == *"pre-maintenance time"* ]]
  cp original-receipt.json "$receipt"
  cp original-state.json "$snapshot/backup-state.json"
  cp original-lease.json "$MOCK_LOG.lease"

  : > "$MOCK_LOG.metadata-source"
  run bash .scripts/production-k3d.sh --release-sources-from-git backup-capture "$VALUES" "$snapshot" "$receipt"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG.metadata-source")" = "old metadata" ]
  jq -e --arg revision "$old_revision" --arg artifact "$ARTIFACT" '
    .source.revision == $revision and .source.artifact == $artifact
    and (.inventory | length) == 3
    and all(.inventory[]; .storage.uid != null and .layout.kind != null)
  ' "$snapshot/manifest.json" > /dev/null
  jq -e '.stateVersion == 2 and .status == "captured" and .phase == "captured"' \
    "$snapshot/backup-state.json" > /dev/null
  jq -e --arg holder "$holder" '.spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "captured"' "$MOCK_LOG.lease" > /dev/null
}

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

@test "missing authoritative database refuses publication" {
  export MOCK_BACKUP=true
  rm "$FIXTURE_ROOT/tar-data/tags/tags.sqlite"
  local snapshot="$FIXTURE_ROOT/backups/missing"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
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
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"measured archive capacity"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -q 'exec backup-copy-.*-- tar -C' "$MOCK_LOG"
}

@test "capture respects the publisher staging bound before copying a PVC archive" {
  export MOCK_BACKUP=true RECIPE_DB_BACKUP_MAX_SNAPSHOT_BYTES=1
  local snapshot="$FIXTURE_ROOT/backups/staging-limit"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
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
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
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
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
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
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/image-drift"
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
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/metadata-drift"
  [ "$status" -ne 0 ]
  [[ $output == *"metadata and templates must match"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "backup refuses untracked metadata even if gitignored" {
  export MOCK_BACKUP=true
  mkdir extra-backend
  printf 'category: backend\n' > extra-backend/.project.yaml
  printf 'extra-backend/\n' > .gitignore
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/untracked-metadata"
  [ "$status" -ne 0 ]
  [[ $output == *"untracked metadata"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "backup permits unrelated checkout changes when release inputs are unchanged" {
  export MOCK_BACKUP=true
  printf 'unrelated documentation\n' > note.txt
  git add note.txt
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Unrelated checkout change'
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/same-inputs"
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
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"recovered backend state could not be verified"* ]]
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
}

@test "failed GraphQL reopen and reblock rollout falls back to stopping all GraphQL Pods" {
  export MOCK_BACKUP=true MOCK_GRAPHQL_REOPEN_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/reopen-failure"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
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

@test "candidate staging records an exact handoff and requires a separate guarded reopen" {
  local start_log nats_ready init_done graph_barrier
  prepare_candidate_release
  jq -e --arg candidate "$CANDIDATE" '
    .status == "candidate-staged" and .phase == "candidate-staged"
    and .candidate.artifact == $candidate
  ' "$STATE/backup-state.json" > /dev/null
  jq -e 'all(.items[]; .spec.replicas == 0)' "$MOCK_LOG.deployments" > /dev/null
  jq -e --arg holder "$HOLDER" --arg old "$ARTIFACT" '
    .spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/release"] == $old
    and .metadata.annotations["recipe-db/phase"] == "candidate-staged"
  ' "$MOCK_LOG.lease" > /dev/null

  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"requires a recorded migration or no-migration outcome"* ]]
  [ "$(jq '[.items[] | select(.spec.replicas > 0)] | length' "$MOCK_LOG.deployments")" -eq 0 ]

  export MOCK_LOCK_OWNER_CHANGE=true
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"release Lease does not match saved recovery state"* ]]
  export MOCK_LOCK_OWNER_CHANGE=false
  jq -e '.status == "candidate-staged" and .phase == "candidate-staged"' \
    "$STATE/backup-state.json" > /dev/null

  local other_candidate=ghcr.io/dhhyi/recipe-db-releases@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  run bash .scripts/production-k3d.sh release-migration-result "$VALUES" "$STATE" \
    "$other_candidate" no-migration-required "RECORD-no-migration-required-$HOLDER"
  [ "$status" -ne 0 ]
  [[ $output == *"manual migration outcome assertions are disabled"* ]]
  run bash .scripts/production-k3d.sh release-migration-result "$VALUES" "$STATE" \
    "$CANDIDATE" no-migration-required "RECORD-no-migration-required-$HOLDER"
  [ "$status" -ne 0 ]
  jq -e '.migrationResult == null' "$STATE/backup-state.json" > /dev/null
  complete_candidate_release no-migration-required
  jq -e '.migrationResult.outcome == "no-migration-required"' "$STATE/backup-state.json" > /dev/null
  jq -e 'all(.items[]; .spec.replicas == 0)' "$MOCK_LOG.deployments" > /dev/null

  start_log=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  nats_ready=$(awk -v start="$start_log" 'NR > start && /rollout status deployment\/nats / {print NR; exit}' "$MOCK_LOG")
  init_done=$(awk -v start="$start_log" 'NR > start && /wait --for=condition=complete job\/nats-init/ {print NR; exit}' "$MOCK_LOG")
  graph_barrier=$(awk -v start="$start_log" 'NR > start && /set env deployment\/graphql MODE=backup/ {print NR; exit}' "$MOCK_LOG")
  [ -n "$nats_ready" ] && [ -n "$init_done" ] && [ -n "$graph_barrier" ]
  [ "$nats_ready" -lt "$init_done" ] && [ "$init_done" -lt "$graph_barrier" ]
  jq -e '.status == "release-ready" and .phase == "ready"' "$STATE/backup-state.json" > /dev/null
  jq -e 'any(.items[]; .metadata.name == "graphql"
    and .spec.template.spec.containers[0].env[0].value == "backup")
    and all(.items[]; (.status.readyReplicas // 0) == (.spec.replicas // 0))' \
    "$MOCK_LOG.deployments" > /dev/null

  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" OPEN-wrong
  [ "$status" -ne 0 ]
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "backup"' "$MOCK_LOG.deployments" > /dev/null
  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -eq 0 ]
  jq -e '.status == "access-open" and .phase == "operator-reopened"' "$STATE/backup-state.json" > /dev/null

  run bash .scripts/production-k3d.sh release-disposition "$VALUES" "$STATE" "$CANDIDATE" \
    close-access "DISPOSITION-$HOLDER-close-access"
  [ "$status" -eq 0 ]
  jq -e '.postCheckDisposition.choice == "close-access"' "$STATE/backup-state.json" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "backup"' "$MOCK_LOG.deployments" > /dev/null
  [ -e "$MOCK_LOG.lease" ]
}

@test "candidate startup makes dependencies and the private projection route available before search readiness" {
  prepare_candidate_release
  export MOCK_SEARCH_DEPENDENCIES=true
  complete_candidate_release no-migration-required
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG.projection-port")" = 4000 ]
  local projection_ready search_ready projection_reset
  projection_ready=$(awk '/patch service graphql-projection .*"targetPort":4001/ {line=NR} END {print line}' "$MOCK_LOG")
  search_ready=$(awk '/rollout status deployment\/search / {line=NR} END {print line}' "$MOCK_LOG")
  projection_reset=$(awk '/patch service graphql-projection .*"targetPort":4000/ {line=NR} END {print line}' "$MOCK_LOG")
  [ "$projection_ready" -lt "$search_ready" ]
  [ "$search_ready" -lt "$projection_reset" ]
  jq -e '.status == "release-ready" and .phase == "ready"' "$STATE/backup-state.json" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql") |
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "backup")' \
    "$MOCK_LOG.deployments" > /dev/null
  [ -f "$MOCK_LOG.lease" ]
}

@test "candidate migration success is recorded but readiness failure retains the barrier and ownership" {
  local workload_changes
  complete_candidate_migration
  jq -e '.migrationResult.outcome == "migration-succeeded"' "$STATE/backup-state.json" > /dev/null

  export MOCK_RELEASE_ROLLOUT_FAIL=true
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  jq -e '.status == "recovery-required" and .phase == "interrupted"' "$STATE/backup-state.json" > /dev/null
  jq -e --arg holder "$HOLDER" '
    .spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "recovery-required"
  ' "$MOCK_LOG.lease" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.replicas == 1 and .spec.template.spec.containers[0].env[0].value == "backup"' \
    "$MOCK_LOG.deployments" > /dev/null
  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -ne 0 ]
  workload_changes=$(grep -c 'scale deployment/' "$MOCK_LOG")
  run bash .scripts/production-k3d.sh release-fallback-stage "$VALUES" "$STATE" "$CANDIDATE" \
    "FALLBACK-$HOLDER-MARKERS-1-UNCHANGED-FORMAT"
  [ "$status" -ne 0 ]
  [[ $output == *"fallback is limited to an interrupted, no-migration candidate start"* ]]
  [ "$(grep -c 'scale deployment/' "$MOCK_LOG")" -eq "$workload_changes" ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "migration planning deterministically reports complete adjacent paths without writing state" {
  export MOCK_MIGRATIONS=true MOCK_MULTI_MIGRATIONS=true
  prepare_candidate_release
  local before order
  before=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)

  run bash .scripts/production-k3d.sh release-migration-plan "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"Service images: current=1 required=3"* ]]
  [[ $output == *"Service recipes: current=1 required=2"* ]]
  order=$(printf '%s\n' "$output" | awk '/^  [0-9]+\./ { print $1, $2, $3 }')
  [ "$order" = "$(printf '1. images 1->2\n2. images 2->3\n3. recipes 1->2')" ]
  [[ $output == *"release-migration-next"* ]]
  [ "$before" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  run ! grep -Eq 'patch job migration-|create -f .*migration-claim.json' "$MOCK_LOG"
}

@test "migration planning rejects an incomplete path without recording or activating work" {
  export MOCK_MIGRATIONS=true MOCK_MULTI_MIGRATIONS=true MOCK_MISSING_MIGRATION=true
  prepare_candidate_release

  run bash .scripts/production-k3d.sh release-migration-plan "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"no unique migration path for images from version 2 to required version 3"* ]]
  jq -e '.migrationExecution == null and .migrationResult == null' \
    "$STATE/backup-state.json" > /dev/null
  run ! grep -Eq 'patch job migration-|create -f .*migration-claim.json' "$MOCK_LOG"
}

@test "migration status is observational and leaves asynchronous execution unchanged" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"release-migration-status"* ]]
  local before patches
  before=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)
  patches=$(grep -c 'patch job migration-' "$MOCK_LOG")

  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"asynchronous execution continues in Kubernetes"* ]]
  [ "$before" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  [ "$patches" -eq "$(grep -c 'patch job migration-' "$MOCK_LOG")" ]
}

@test "migration failure records a recovery barrier and blocks retry and startup" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  export MOCK_FAILED_MIGRATION=true

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"no retry or startup is authorized"* ]]
  jq -e '.status == "recovery-required" and .phase == "migration-failed"
    and .migrationExecution.status == "failed"
    and .migrationResult == null' "$STATE/backup-state.json" > /dev/null
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"migration is failed"* ]]
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "migration claim contention prevents an overlapping activation" {
  export MOCK_MIGRATIONS=true MOCK_MIGRATION_CLAIM_HELD=true
  prepare_candidate_release
  local before
  before=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"another migration command owns the atomic cluster claim"* ]]
  [ "$before" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  run ! grep -q 'patch job migration-' "$MOCK_LOG"
  [ -e "$MOCK_LOG.lease" ]
}

@test "migration planning rejects a staged Job with parallelism greater than one" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  local job_file
  for job_file in "$MOCK_LOG".migration-job*.json; do
    [[ -f $job_file ]] || continue
    jq '.spec.parallelism=2' "$job_file" > "$job_file.next"
    mv "$job_file.next" "$job_file"
  done

  run bash .scripts/production-k3d.sh release-migration-plan "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"staged migration Job"* && $output == *"does not match the candidate and pinned transition"* ]]
  run ! grep -Eq 'patch job migration-|create -f .*migration-claim.json' "$MOCK_LOG"
}

@test "migration planning rejects a staged Job with multiple completions" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  local job_file
  for job_file in "$MOCK_LOG".migration-job*.json; do
    [[ -f $job_file ]] || continue
    jq '.spec.completions=2' "$job_file" > "$job_file.next"
    mv "$job_file.next" "$job_file"
  done

  run bash .scripts/production-k3d.sh release-migration-plan "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"staged migration Job"* && $output == *"does not match the candidate and pinned transition"* ]]
  run ! grep -Eq 'patch job migration-|create -f .*migration-claim.json' "$MOCK_LOG"
}

@test "migration claim recovery requires exact confirmation and does not activate a Job" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  local holder="abandoned-$HOLDER"
  jq -n --arg candidate "$CANDIDATE" --arg holder "$holder" '{
    apiVersion:"coordination.k8s.io/v1",kind:"Lease",
    metadata:{name:"recipe-db-migration",namespace:"kube-system",
      uid:"abandoned-migration-claim",resourceVersion:"7",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/release":$candidate}},
    spec:{holderIdentity:$holder}
  }' > "$MOCK_LOG.migration-claim"

  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$CANDIDATE" "$holder" "RECOVER-wrong-holder"
  [ "$status" -ne 0 ]
  [[ $output == *"requires the exact holder"* ]]
  [ -f "$MOCK_LOG.migration-claim" ]

  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$CANDIDATE" "foreign-holder" "RECOVER-foreign-holder"
  [ "$status" -ne 0 ]
  [[ $output == *"claim identity does not match"* ]]
  [ -f "$MOCK_LOG.migration-claim" ]

  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$CANDIDATE" "$holder" "RECOVER-$holder"
  [ "$status" -eq 0 ]
  [[ $output == *"no migration state or Job was changed"* ]]
  [[ $output == *"release-migration-status"* ]]
  [ ! -e "$MOCK_LOG.migration-claim" ]
  run ! grep -q 'patch job migration-' "$MOCK_LOG"

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'patch job migration-' "$MOCK_LOG")" -eq 1 ]
}

@test "recovering a claim for a running Job cannot activate another migration" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  local patches holder="abandoned-$HOLDER"
  patches=$(grep -c 'patch job migration-' "$MOCK_LOG")
  jq -n --arg candidate "$CANDIDATE" --arg holder "$holder" '{
    apiVersion:"coordination.k8s.io/v1",kind:"Lease",
    metadata:{name:"recipe-db-migration",namespace:"kube-system",
      uid:"abandoned-running-migration-claim",resourceVersion:"9",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/release":$candidate}},
    spec:{holderIdentity:$holder}
  }' > "$MOCK_LOG.migration-claim"

  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$CANDIDATE" "$holder" "RECOVER-$holder"
  [ "$status" -eq 0 ]
  [[ $output == *"no migration state or Job was changed"* ]]
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"no other transition was activated"* ]]
  [ "$patches" -eq "$(grep -c 'patch job migration-' "$MOCK_LOG")" ]
}

@test "activation API uncertainty is recorded and never retried" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  export MOCK_MIGRATION_ACTIVATION_UNKNOWN=true MOCK_MIGRATION_ACTIVATION_OBSERVE_FAIL=true

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"migration execution for"* && $output == *"is uncertain"* ]]
  jq -e '.migrationExecution.status == "uncertain" and .migrationResult == null' \
    "$STATE/backup-state.json" > /dev/null
  local patches
  patches=$(grep -c 'patch job migration-' "$MOCK_LOG")

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"migration is uncertain"* ]]
  [ "$patches" -eq "$(grep -c 'patch job migration-' "$MOCK_LOG")" ]
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "a missing previously activated Job records an uncertain outcome" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  local job
  job=$(jq -r '.migrationExecution.transitions[0].job' "$STATE/backup-state.json")
  rm -f "$MOCK_LOG.migration-job.json" "$MOCK_LOG.migration-job-$job.json"

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"previously activated Job is missing"* ]]
  jq -e '.migrationExecution.status == "uncertain" and .migrationResult == null' \
    "$STATE/backup-state.json" > /dev/null
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
}

@test "a successful Job with a mismatched storage marker cannot record a handoff" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  export MOCK_COMPLETED_MIGRATION=true
  export MOCK_STORAGE_VERSIONS='{"recipes":1,"images":1,"ratings":1,"inspirations":1,"tags":1}'

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"actual target storage version was not confirmed"* ]]
  jq -e '.migrationExecution.status == "uncertain" and .migrationResult == null' \
    "$STATE/backup-state.json" > /dev/null
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
}

@test "deadline failure with a terminating worker keeps advancement blocked" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  export MOCK_FAILED_MIGRATION=true MOCK_MIGRATION_DEADLINE_EXCEEDED=true
  export MOCK_MIGRATION_WORKER_TERMINATING=true

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"conversion may have modified data"* ]]
  jq -e '.migrationExecution.status == "failed" and .migrationResult == null' \
    "$STATE/backup-state.json" > /dev/null
  run ! grep -q 'delete pods -l job-name=migration-' "$MOCK_LOG"
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "next repairs a saved migration handoff after the Lease update fails" {
  prepare_candidate_release
  export MOCK_MIGRATION_HANDOFF_LEASE_UPDATE_FAIL=true

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  jq -e '.migrationResult.outcome == "no-migration-required"' \
    "$STATE/backup-state.json" > /dev/null
  [ "$(jq -r '.metadata.annotations["recipe-db/phase"]' "$MOCK_LOG.lease")" != migration-result-recorded ]

  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"Lease handoff is not recorded"* ]]
  [[ $output == *"Next: mise run production-k3d release-migration-next"* ]]
  [[ $output != *"Next: mise run production-k3d release-start"* ]]

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"Lease handoff reconciled"* ]]
  [ "$(jq -r '.metadata.annotations["recipe-db/phase"]' "$MOCK_LOG.lease")" = migration-result-recorded ]
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
}

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

@test "candidate staging interruption preserves inspectable state and the original Lease" {
  prepare_captured_release
  export MOCK_FORCED_TERMINATION=true
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -ne 0 ]
  [[ $output == *"force-killed or failed its bounded drain"* ]]
  jq -e '.status == "recovery-required" and .phase == "interrupted"' "$STATE/backup-state.json" > /dev/null
  jq -e --arg holder "$HOLDER" --arg old "$ARTIFACT" '
    .spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "recovery-required"
    and .metadata.annotations["recipe-db/release"] == $old
  ' "$MOCK_LOG.lease" > /dev/null
  [ -e "$STATE/backup-state.json" ]
}

@test "candidate staging requires an explicit remote-backup verification acknowledgment" {
  local stage_start workloads_stopped runtime_secret routes_secret
  prepare_captured_release
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    overdue NOT-VERIFIED
  [ "$status" -ne 0 ]
  [[ $output == *"requires verified-upload or verified-unchanged"* ]]
  jq -e '.status == "captured" and .phase == "captured"' "$STATE/backup-state.json" > /dev/null
  [ -e "$MOCK_LOG.lease" ]
  stage_start=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-unchanged "VERIFIED-$HOLDER-verified-unchanged"
  [ "$status" -eq 0 ]
  workloads_stopped=$(awk -v start="$stage_start" \
    'NR > start && /scale deployment\/graphql --replicas=0/ {print NR; exit}' "$MOCK_LOG")
  runtime_secret=$(awk -v start="$stage_start" \
    'NR > start && /create secret generic recipe-db-runtime/ {print NR; exit}' "$MOCK_LOG")
  routes_secret=$(awk -v start="$stage_start" \
    'NR > start && /create secret generic recipe-db-routes/ {print NR; exit}' "$MOCK_LOG")
  [ "$workloads_stopped" -lt "$runtime_secret" ]
  [ "$workloads_stopped" -lt "$routes_secret" ]
}

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

@test "candidate staging rejects a lost GraphQL maintenance barrier" {
  prepare_captured_release
  jq '(.items[] | select(.metadata.name == "graphql").spec.template.spec.containers[0].env[]
    | select(.name == "MODE").value)="production"' \
    "$MOCK_LOG.deployments" > "$MOCK_LOG.deployments.next"
  mv "$MOCK_LOG.deployments.next" "$MOCK_LOG.deployments"

  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -ne 0 ]
  [[ $output == *"GraphQL maintenance access barrier is not active"* ]]
  [ "$(jq -r '.status + "/" + .phase' "$STATE/backup-state.json")" = "captured/captured" ]
  run ! grep -q 'apply -f .*staged-application.yml' "$MOCK_LOG"
}

@test "candidate staging rejects restarted storage workloads" {
  prepare_captured_release
  jq '(.items[] | select(.metadata.name == "recipes")) |=
    (.spec.replicas=1 | .status.readyReplicas=1)' \
    "$MOCK_LOG.deployments" > "$MOCK_LOG.deployments.next"
  mv "$MOCK_LOG.deployments.next" "$MOCK_LOG.deployments"

  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -ne 0 ]
  [[ $output == *"storage workloads restarted after maintenance capture"* ]]
  [ "$(jq -r '.status + "/" + .phase' "$STATE/backup-state.json")" = "captured/captured" ]
  run ! grep -q 'apply -f .*staged-application.yml' "$MOCK_LOG"
}

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
    and .migrationResult == null and .postCheckDisposition == null
  ' "$STATE/backup-state.json" > /dev/null
  CANDIDATE=$next_candidate
  complete_candidate_release_with_start
  jq -e '.status == "access-open" and .phase == "operator-reopened"' "$STATE/backup-state.json" > /dev/null
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
