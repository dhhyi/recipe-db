#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "complete recovery failure retains diagnostics and requires a fresh retry approval" {
  export MOCK_MIGRATIONS=true MOCK_MULTI_MIGRATIONS=true
  set_value '.timeoutSeconds=8'
  printf '{"anonymous":{"role":"anonymous"},"tokens":[{"role":"owner","secret":"recovery-test-token"}],"googleAccounts":{}}\n' \
    > auth-accounts.json
  python3 - "$FIXTURE_ROOT/tar-data/recipes/recipes.sqlite3" "$FIXTURE_ROOT/tar-data/tags/tags.sqlite" << 'PY'
import pathlib, sqlite3, sys

for name in sys.argv[1:]:
    pathlib.Path(name).unlink()
with sqlite3.connect(sys.argv[1]) as database:
    database.execute("CREATE TABLE recipes (id TEXT PRIMARY KEY, document TEXT NOT NULL)")
    database.execute(
        "INSERT INTO recipes VALUES (?, ?)",
        ("fixture-recipe", '{"name":"Recovery fixture recipe"}'),
    )
with sqlite3.connect(sys.argv[2]) as database:
    database.execute("CREATE TABLE tags (name TEXT PRIMARY KEY)")
PY
  local image_full_sha image_thumb_sha image_full_path image_thumb_path
  printf 'recovery-image-full\n' > "$FIXTURE_ROOT/recovery-image-full"
  printf 'recovery-image-thumbnail\n' > "$FIXTURE_ROOT/recovery-image-thumbnail"
  image_full_sha=$(sha256sum "$FIXTURE_ROOT/recovery-image-full" | cut -d ' ' -f 1)
  image_thumb_sha=$(sha256sum "$FIXTURE_ROOT/recovery-image-thumbnail" | cut -d ' ' -f 1)
  image_full_path="fixture-recipe-$image_full_sha.png"
  image_thumb_path="fixture-recipe-$image_thumb_sha-thumb.png"
  cp "$FIXTURE_ROOT/recovery-image-full" "$FIXTURE_ROOT/tar-data/images/public/$image_full_path"
  cp "$FIXTURE_ROOT/recovery-image-thumbnail" "$FIXTURE_ROOT/tar-data/images/public/$image_thumb_path"
  jq -n --arg full "/public/$image_full_path" --arg thumb "/public/$image_thumb_path" \
    --argjson size "$(stat -c '%s' "$FIXTURE_ROOT/recovery-image-full")" \
    '{recipeId:"fixture-recipe",url:$full,thumbUrl:$thumb,size:$size}' \
    > "$FIXTURE_ROOT/tar-data/images/manifests/fixture-recipe.json"
  export MOCK_RESTORE_IMAGE_JSON
  MOCK_RESTORE_IMAGE_JSON=$(jq -c '{url,thumbUrl}' \
    "$FIXTURE_ROOT/tar-data/images/manifests/fixture-recipe.json")
  rm -f "$FIXTURE_ROOT/tar-data/tags/tags.sqlite-wal"
  for service in recipes images tags; do
    printf '1\n' > "$FIXTURE_ROOT/tar-data/$service/storage-version"
  done
  # Match the source workloads created by the recovery renderer.
  jq '
    ([.items[] | select(.metadata.name == "graphql")][0]) as $template |
    .items += (["nats", "typesense", "browse-maintenance", "redis", "oauth2-proxy"] |
      map(. as $name | $template |
        .metadata.name = $name |
        .spec.template.spec.containers[0].name = $name |
        .spec.template.spec.containers[0].image = "infrastructure"))
  ' "$MOCK_LOG.deployments" > "$MOCK_LOG.deployments.next"
  mv "$MOCK_LOG.deployments.next" "$MOCK_LOG.deployments"
  prepare_candidate_release
  export STATE
  prepare_recovery_package
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  local images_job recipes_first_job recipes_second_job
  images_job=$(jq -er '.migrationExecution.transitions[0].job' "$STATE/backup-state.json")
  recipes_first_job=$(jq -er '.migrationExecution.transitions[1].job' "$STATE/backup-state.json")
  recipes_second_job=$(jq -er '.migrationExecution.transitions[2].job' "$STATE/backup-state.json")

  export MOCK_COMPLETED_MIGRATION=true MOCK_MIGRATION_RESULT_JOB="$images_job"
  export MOCK_STORAGE_VERSIONS='{"recipes":1,"images":2,"ratings":1,"inspirations":1,"tags":1}'
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]

  export MOCK_MIGRATION_RESULT_JOB="$recipes_first_job"
  export MOCK_STORAGE_VERSIONS='{"recipes":2,"images":2,"ratings":1,"inspirations":1,"tags":1}'
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  jq -e '.migrationExecution.transitions[0].status == "completed"
    and .migrationExecution.transitions[1].status == "completed"
    and .migrationExecution.currentIndex == 2
    and any(.migrationExecution.versions[];
      .service == "recipes" and .currentVersion == 2 and .requiredVersion == 3)' \
    "$STATE/backup-state.json" > /dev/null

  export MOCK_COMPLETED_MIGRATION=false MOCK_MIGRATION_RESULT_JOB="$recipes_second_job"
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  export MOCK_FAILED_MIGRATION=true MOCK_MIGRATION_RESULT_JOB="$recipes_second_job"
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  jq -e '.migrationExecution.failedTransition.service == "recipes"
    and .migrationExecution.transitions[0].status == "completed"
    and .migrationExecution.transitions[1].status == "completed"
    and .migrationExecution.transitions[2].status == "failed"' \
    "$STATE/backup-state.json" > /dev/null
  touch "$MOCK_LOG.migration-worker-deleted"
  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | sed -n 's/^Recovery approval scope: //p' > recovery-scope.json
  jq -e --slurpfile state "$STATE/backup-state.json" --slurpfile config "$VALUES" '
    $state[0] as $state |
    .target == $state.source.target and .cluster == $state.source.cluster
    and .context == $state.source.context and .namespace == $state.source.namespace
    and .backupId == $state.backupVerification.backupId
    and .previousRelease == $state.source.artifact and .previousRevision == $state.source.revision
    and ([.storage[].pvc] | sort) == ($config[0].volumes | keys | sort)
    and all(.storage[]; . as $entry |
      .root == "/data" and all($state.selectedPVCs[] | select(.pvc == $entry.pvc);
        .storage.uid == $entry.uid and .storage.volumeName == $entry.pv))
  ' recovery-scope.json > /dev/null
  [[ $output != *"recovery-test-token"* ]]

  local before_active_job active_confirmation
  before_active_job=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)
  export MOCK_FAILED_MIGRATION=false MOCK_COMPLETED_MIGRATION=false
  active_confirmation=$(jq -er '
    "CLEAR-AND-RESTORE-\(.backupVerification.backupId)-\(.candidate.revision)-ATTEMPT-\((((.migrationRecovery.attempts // []) | map(.number) | max) // 0) + 1)"
  ' "$STATE/backup-state.json")
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "$active_confirmation"
  [ "$status" -ne 0 ]
  [[ $output == *"migration Jobs must be suspended or terminal with no active workers before recovery"* ]]
  [ "$before_active_job" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  run ! grep -Eq 'create -f .*restore-volume-pod|exec restore-volume-|delete pvc' "$MOCK_LOG"
  [ ! -e "$MOCK_LOG.migration-claim" ]
  export MOCK_FAILED_MIGRATION=true

  local before_missing_archive
  before_missing_archive=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE.missing" "$HOLDER" \
    "$active_confirmation"
  [ "$status" -ne 0 ]
  [[ $output == *"recovery requires the verified complete backup manifest and archive"* ]]
  [ "$before_missing_archive" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  run ! grep -Eq 'create -f .*restore-volume-pod|exec restore-volume-|delete pvc' "$MOCK_LOG"
  [ ! -e "$MOCK_LOG.migration-claim" ]

  export MOCK_RESTORE=true MOCK_RESTORE_IMPORT_FAIL=false
  cp "$MOCK_LOG.deployments" "$MOCK_LOG.restore-deployments"
  : > "$MOCK_LOG.restore-pods"
  local revision
  revision=$(jq -er .candidate.revision "$STATE/backup-state.json")
  local credential_checksum
  credential_checksum=$(sha256sum "$STATE.previous-runtime-secret.json" | cut -d ' ' -f 1)
  printf '{"kind":"Pod","metadata":{"name":"graphql-node-lost","namespace":"recipe-db","labels":{"app.kubernetes.io/part-of":"recipe-db","app.kubernetes.io/name":"graphql"}},"spec":{"containers":[{"name":"graphql"}]},"status":{"phase":"Failed","reason":"NodeLost","containerStatuses":[]}}\n' \
    > "$MOCK_LOG.restore-pods"
  local node_lost_calls
  node_lost_calls=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-1"
  [ "$status" -ne 0 ]
  [[ $output == *"requires stopped workloads and terminated workers"* ]]
  jq -e '.phase == "migration-failed"' "$STATE/backup-state.json" > /dev/null
  [ ! -e "$MOCK_LOG.migration-claim" ]
  sed -n "$((node_lost_calls + 1)),\$p" "$MOCK_LOG" > node-lost-calls.log
  run ! grep -Eq 'delete pod|create -f .*restore-volume-pod|exec restore-volume-' node-lost-calls.log
  : > "$MOCK_LOG.restore-pods"
  mv "$STATE.previous-runtime-secret.json" "$STATE.previous-runtime-secret.saved"
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-1"
  [ "$status" -ne 0 ]
  [[ $output == *"securely retained previous-release runtime credentials"* ]]
  mv "$STATE.previous-runtime-secret.saved" "$STATE.previous-runtime-secret.json"
  cp auth-accounts.json auth-accounts.saved
  printf '{"anonymous":{"role":"anonymous"},"tokens":[{"role":"owner","secret":"changed-test-token"}],"googleAccounts":{}}\n' \
    > auth-accounts.json
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-1"
  [ "$status" -ne 0 ]
  [[ $output == *"credentials do not match the previous-release configuration"* ]]
  mv auth-accounts.saved auth-accounts.json
  cp "$PACKAGE_ARCHIVE" "$PACKAGE_ARCHIVE.saved"
  printf 'not a complete backup archive\n' > "$PACKAGE_ARCHIVE"
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-1"
  [ "$status" -ne 0 ]
  mv "$PACKAGE_ARCHIVE.saved" "$PACKAGE_ARCHIVE"
  run ! grep -Eq 'create -f .*restore-volume-pod|exec restore-volume-|delete pvc' "$MOCK_LOG"
  jq -e '.phase == "migration-failed"' "$STATE/backup-state.json" > /dev/null
  export MOCK_IMAGE_INDEX_FAIL=true
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-1"
  [ "$status" -ne 0 ]
  grep -q 'oras manifest fetch ghcr.io/dhhyi/recipe-db-' "$MOCK_LOG"
  run ! grep -Eq 'delete pvc|restore-volume' "$MOCK_LOG"
  jq -e '.phase == "migration-failed" and .migrationExecution.status == "failed"' \
    "$STATE/backup-state.json" > /dev/null
  export MOCK_IMAGE_INDEX_FAIL=false
  export MOCK_RESTORE_IMAGE_PULL_FAIL=true
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-1"
  [ "$status" -ne 0 ]
  [[ $output == *"previous-release workload image could not be pulled before storage clearing"* ]]
  run ! grep -Eq 'create -f .*restore-volume-pod|exec restore-volume-' "$MOCK_LOG"
  jq -e '.status == "recovery-required" and .phase == "migration-recovery-failed"
    and .migrationRecovery.attempts[-1].number == 1
    and (.migrationRecovery.failureReason | contains("previous-release workload image"))' \
    "$STATE/backup-state.json" > /dev/null
  [ ! -e "$MOCK_LOG.migration-claim" ]
  [ "$credential_checksum" = "$(sha256sum "$STATE.previous-runtime-secret.json" | cut -d ' ' -f 1)" ]
  export MOCK_RESTORE_IMAGE_PULL_FAIL=false MOCK_RESTORE_IMPORT_FAIL=true MOCK_RESTORE_CLEANUP_UNSAFE=true
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-2"
  [ "$status" -ne 0 ]
  jq -e '.status == "recovery-required" and .phase == "migration-recovery-failed"
    and .migrationRecovery.status == "failed"
    and .migrationRecovery.safeToRetry == false
    and .migrationRecovery.attempts[-1].number == 2
    and (.migrationRecovery.failureReason | contains("complete backup import failed"))' \
    "$STATE/backup-state.json" > /dev/null
  jq -e 'all(.items[]; .spec.replicas == 0)' "$MOCK_LOG.restore-deployments" > /dev/null
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes" > /dev/null
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[0].env[]?;
      .name == "MODE" and .value == "backup"))' "$MOCK_LOG.restore-deployments" > /dev/null
  [ -e "$MOCK_LOG.lease" ]
  [ "$(jq -r '.metadata.annotations["recipe-db/phase"]' "$MOCK_LOG.lease")" = \
    "migration-recovery-failed" ]

  for worker in active terminating; do
    printf '%s\n' "$worker" > "$MOCK_LOG.lingering-worker"
    run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
    [ "$status" -eq 0 ]
    [[ $output == *"A retry is not recommended"* ]]
    [[ $output != *"CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-3"* ]]
    run bash .scripts/production-k3d.sh release-migration-recover \
      "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
      "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-3"
    [ "$status" -ne 0 ]
    [[ $output == *"requires every other worker to have terminated"* ]]
  done
  rm "$MOCK_LOG.lingering-worker"
  export MOCK_RESTORE_CLEANUP_UNSAFE=false
  cp "$STATE/backup-state.json" "$MOCK_LOG.unsafe-recovery-state"
  cp "$MOCK_LOG.lease" "$MOCK_LOG.unsafe-recovery-lease"
  jq '.items[] | select(.kind == "Job")
    | .metadata.uid="guard-job-uid" | .metadata.resourceVersion="7"
    | .status={active:1}' "$MOCK_LOG.restore-guard" > "$MOCK_LOG.expired-guard-job"
  jq '{apiVersion:"v1",kind:"Pod",metadata:{
      name:(.metadata.name + "-pod"),namespace:.metadata.namespace,uid:"guard-pod-uid",
      labels:.spec.template.metadata.labels,ownerReferences:[{
        apiVersion:"batch/v1",kind:"Job",name:.metadata.name,uid:.metadata.uid,controller:true}]},
      spec:.spec.template.spec,status:{phase:"Running"}}' \
    "$MOCK_LOG.expired-guard-job" > "$MOCK_LOG.expired-guard-pod"
  jq '.items[] | select(.kind == "ConfigMap") | .data.ready="true" | .data.expired="true"' \
    "$MOCK_LOG.restore-guard" > "$MOCK_LOG.expired-guard-configmap"
  for resource in job pod configmap; do
    cp "$MOCK_LOG.expired-guard-$resource" "$MOCK_LOG.expired-guard-$resource.saved"
  done
  local guard_status_calls
  guard_status_calls=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"complete migration recovery failed"* ]]
  [[ $output == *"CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-3"* ]]
  [ -f "$MOCK_LOG.expired-guard-job" ]
  jq -e '.status.active == 1' "$MOCK_LOG.expired-guard-job" > /dev/null
  for bad_guard in unowned unexpired job-drift pod-drift wrong-job pvc active terminating node-lost; do
    case "$bad_guard" in
      unowned)
        jq '.metadata.labels["recipe-db/restore-holder"]="other-backup"' \
          "$MOCK_LOG.expired-guard-job.saved" > "$MOCK_LOG.expired-guard-job"
        ;;
      unexpired)
        jq '.data.expired="false"' "$MOCK_LOG.expired-guard-configmap.saved" \
          > "$MOCK_LOG.expired-guard-configmap"
        ;;
      job-drift)
        jq '.spec.template.spec.containers[0].command=["sh","-ec","exit 0"]' \
          "$MOCK_LOG.expired-guard-job.saved" > "$MOCK_LOG.expired-guard-job"
        ;;
      pod-drift)
        jq '.spec.containers[0].command=["sh","-ec","exit 0"]' \
          "$MOCK_LOG.expired-guard-pod.saved" > "$MOCK_LOG.expired-guard-pod"
        ;;
      wrong-job)
        jq '.metadata.ownerReferences[0].uid="other-job-uid"' \
          "$MOCK_LOG.expired-guard-pod.saved" > "$MOCK_LOG.expired-guard-pod"
        ;;
      pvc)
        jq '.spec.volumes=[{persistentVolumeClaim:{claimName:"recipes"}}]' \
          "$MOCK_LOG.expired-guard-pod.saved" > "$MOCK_LOG.expired-guard-pod"
        ;;
      active | terminating) printf '%s\n' "$bad_guard" > "$MOCK_LOG.lingering-worker" ;;
      node-lost)
        printf '{"metadata":{"name":"lost-worker"},"spec":{"containers":[{"name":"worker"}]},"status":{"phase":"Failed","reason":"NodeLost"}}\n' \
          >> "$MOCK_LOG.restore-pods"
        ;;
    esac
    run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
    [ "$status" -eq 0 ]
    [[ $output == *"A retry is not recommended"* ]]
    [[ $output != *"CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-3"* ]]
    for resource in job pod configmap; do
      cp "$MOCK_LOG.expired-guard-$resource.saved" "$MOCK_LOG.expired-guard-$resource"
    done
    rm -f "$MOCK_LOG.lingering-worker"
    : > "$MOCK_LOG.restore-pods"
  done
  sed -n "$((guard_status_calls + 1)),\$p" "$MOCK_LOG" > "$MOCK_LOG.expired-guard-status"
  run ! grep -Eq ' (apply|delete|patch|scale|set|create) ' "$MOCK_LOG.expired-guard-status"
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-2"
  [ "$status" -ne 0 ]
  [ -f "$MOCK_LOG.expired-guard-job" ]
  cmp "$STATE/backup-state.json" "$MOCK_LOG.unsafe-recovery-state"
  local claim_holder
  claim_holder=interrupted-recovery-command
  jq -n --arg holder "$claim_holder" --arg candidate "$CANDIDATE" '{
    metadata:{name:"recipe-db-migration",namespace:"kube-system",uid:"claim-uid",resourceVersion:"1",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},annotations:{"recipe-db/release":$candidate}},
    spec:{holderIdentity:$holder}}' > "$MOCK_LOG.migration-claim"
  jq '.phase = "migration-recovery-import-images"
    | .migrationRecovery.status = "in-progress"
    | .migrationRecovery.phase = "import-images"
    | .migrationRecovery.leaseTransition = {
        from:"migration-recovery-clearing-application-data",to:"migration-recovery-import-images"}
    | del(.migrationRecovery.safeToRetry, .migrationRecovery.failureReason, .migrationRecovery.failedAt)' \
    "$STATE/backup-state.json" > "$STATE/backup-state.next"
  mv "$STATE/backup-state.next" "$STATE/backup-state.json"
  jq '.metadata.annotations["recipe-db/phase"] = "migration-recovery-clearing-application-data"' \
    "$MOCK_LOG.lease" > "$MOCK_LOG.lease.next"
  mv "$MOCK_LOG.lease.next" "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"migration recovery is still claimed by $claim_holder"* ]]
  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$CANDIDATE" "$claim_holder" "RECOVER-$claim_holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.migration-claim" ]
  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"interrupted during migration-recovery-import-images"* ]]
  [[ $output == *"interrupted recovery phase update"* ]]
  [[ $output == *"CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-3"* ]]
  local before
  before=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-2"
  [ "$status" -ne 0 ]
  [[ $output == *"recovery requires fresh CLEAR-AND-RESTORE"* ]]
  [ "$before" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]

  cp "$MOCK_LOG.unsafe-recovery-state" "$STATE/backup-state.json"
  cp "$MOCK_LOG.unsafe-recovery-lease" "$MOCK_LOG.lease"
  jq '.migrationRecovery.safeToRetry = "false"' "$STATE/backup-state.json" > "$STATE/backup-state.next"
  mv "$STATE/backup-state.next" "$STATE/backup-state.json"
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-3"
  [ "$status" -ne 0 ]
  cp "$MOCK_LOG.unsafe-recovery-state" "$STATE/backup-state.json"
  export MOCK_RESTORE_IMPORT_FAIL=false
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-3"
  [ "$status" -eq 0 ]
  [[ $output == *"complete recovery verified"* ]]
  [ ! -e "$MOCK_LOG.expired-guard-job" ]
  [ ! -e "$MOCK_LOG.expired-guard-pod" ]
  jq -e '.status == "recovered" and .phase == "migration-recovered"
    and .migrationRecovery.status == "verified"
    and .migrationRecovery.candidateAborted == true
    and .migrationRecovery.leaseTransition.to == "migration-recovered"
    and [.migrationRecovery.attempts[].number] == [1,2,3]' \
    "$STATE/backup-state.json" > /dev/null
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  [ ! -e "$MOCK_LOG.migration-claim" ]
  jq -e '.items[] | select(.kind == "Role") |
    all(.rules[]; (.verbs | index("create")) == null and (.resources | index("secrets")) == null)
    and any(.rules[]; .resources == ["deployments/scale"] and (.resourceNames | index("graphql")) != null)' \
    "$MOCK_LOG.restore-guard" > /dev/null
  [ -e "$MOCK_LOG.lease" ]
  python3 - "$FIXTURE_ROOT/imported/recipes/recipes.sqlite3" << 'PY'
import sqlite3, sys

with sqlite3.connect(sys.argv[1]) as database:
    assert database.execute("SELECT id, document FROM recipes").fetchone() == (
        "fixture-recipe",
        '{"name":"Recovery fixture recipe"}',
    )
PY
  cmp "$FIXTURE_ROOT/recovery-image-full" \
    "$FIXTURE_ROOT/imported/images/public/$image_full_path"
  cmp "$FIXTURE_ROOT/recovery-image-thumbnail" \
    "$FIXTURE_ROOT/imported/images/public/$image_thumb_path"
  jq -e --arg full "/public/$image_full_path" --arg thumb "/public/$image_thumb_path" \
    --argjson size "$(stat -c '%s' "$FIXTURE_ROOT/recovery-image-full")" '
      .recipeId == "fixture-recipe" and .url == $full and .thumbUrl == $thumb and .size == $size
    ' "$FIXTURE_ROOT/imported/images/manifests/fixture-recipe.json" > /dev/null
  for service in recipes images tags; do
    [ "$(cat "$FIXTURE_ROOT/imported/$service/storage-version")" = 1 ]
  done
  cp "$MOCK_LOG.lease" "$MOCK_LOG.recovered-lease"
  jq --arg phase "$(jq -er .migrationRecovery.leaseTransition.from "$STATE/backup-state.json")" \
    '.metadata.annotations["recipe-db/phase"]=$phase' \
    "$MOCK_LOG.lease" > "$MOCK_LOG.lease.next"
  mv "$MOCK_LOG.lease.next" "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"completion phase update was interrupted"* ]]
  [[ $output == *"A retry is not recommended"* ]]
  [[ $output != *"Next: mise run production-k3d release-recovery-reopen"* ]]
  mv "$MOCK_LOG.recovered-lease" "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"release-recovery-reopen"* ]]
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"migration commands require a staged candidate"* ]]
  local before_reopen
  before_reopen=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)
  cp "$MOCK_LOG.lease" "$MOCK_LOG.before-reopen-lease"
  jq '.metadata.annotations["recipe-db/phase"]="migration-recovery-failed"' \
    "$MOCK_LOG.lease" > "$MOCK_LOG.lease.next"
  mv "$MOCK_LOG.lease.next" "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -ne 0 ]
  [[ $output == *"Lease phase does not match the saved lifecycle state"* ]]
  mv "$MOCK_LOG.before-reopen-lease" "$MOCK_LOG.lease"
  export MOCK_SURVIVING_RECOVERY_GUARD=true
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -ne 0 ]
  [[ $output == *"shutdown guard to be terminated and removed"* ]]
  [ "$before_reopen" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  export MOCK_SURVIVING_RECOVERY_GUARD=false
  export MOCK_MIGRATION_CLAIM_HELD=true
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -ne 0 ]
  [[ $output == *"another migration command owns the atomic cluster claim"* ]]
  [ "$before_reopen" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes" > /dev/null
  export MOCK_MIGRATION_CLAIM_HELD=false
  jq '.metadata.annotations["recipe-db/phase"]="migration-reopened"' "$MOCK_LOG.lease" \
    > "$MOCK_LOG.terminal-lease"
  export MOCK_REOPEN_CLOSEOUT_KILL=true
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -eq 137 ]
  kill "$(cat "$MOCK_LOG.latest-forward-pid")"
  jq -e '.status == "recovered" and .phase == "migration-reopened"
    and .migrationRecovery.status == "reopened"
    and .migrationRecovery.ownershipReleasedAt == null' "$STATE/backup-state.json" > /dev/null
  [ ! -e "$MOCK_LOG.lease" ]
  [ -e "$MOCK_LOG.migration-claim" ]
  export MOCK_REOPEN_CLOSEOUT_KILL=false
  local closeout_calls closeout_holder
  closeout_calls=$(wc -l < "$MOCK_LOG")
  closeout_holder=$(jq -er .spec.holderIdentity "$MOCK_LOG.migration-claim")
  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output == *"terminal recovery closeout is claimed"* && $output == *"RECOVER-$closeout_holder"* ]]
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -ne 0 ]
  [[ $output == *"another migration command owns the atomic cluster claim"* ]]
  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$ARTIFACT" "$closeout_holder" "RECOVER-wrong"
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.migration-claim" ]
  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$ARTIFACT" "$closeout_holder" "RECOVER-$closeout_holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.migration-claim" ]
  cp "$STATE/backup-state.json" "$MOCK_LOG.interrupted-closeout-state"
  for drift in phase holder; do
    jq --arg drift "$drift" '
      if $drift == "phase" then .metadata.annotations["recipe-db/phase"]="migration-reopening"
      else .spec.holderIdentity="foreign-operation" end' \
      "$MOCK_LOG.terminal-lease" > "$MOCK_LOG.lease"
    run bash .scripts/production-k3d.sh release-recovery-reopen \
      "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
    [ "$status" -ne 0 ]
    [ -e "$MOCK_LOG.lease" ]
    cmp "$STATE/backup-state.json" "$MOCK_LOG.interrupted-closeout-state"
    rm "$MOCK_LOG.lease"
  done
  export MOCK_SURVIVING_RECOVERY_GUARD=true
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -ne 0 ]
  cmp "$STATE/backup-state.json" "$MOCK_LOG.interrupted-closeout-state"
  export MOCK_SURVIVING_RECOVERY_GUARD=false
  cp "$MOCK_LOG.restore-deployments" "$MOCK_LOG.closeout-deployments-saved"
  jq '(.items[] | select(.metadata.name == "graphql").spec.template.spec.containers[].env[] |
    select(.name == "MODE").value)="backup"' "$MOCK_LOG.restore-deployments" \
    > "$MOCK_LOG.restore-deployments.next"
  mv "$MOCK_LOG.restore-deployments.next" "$MOCK_LOG.restore-deployments"
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -ne 0 ]
  [[ $output == *"production workloads are not compatible and ready"* ]]
  cmp "$STATE/backup-state.json" "$MOCK_LOG.interrupted-closeout-state"
  mv "$MOCK_LOG.closeout-deployments-saved" "$MOCK_LOG.restore-deployments"
  cp "$MOCK_LOG.restore-routes" "$MOCK_LOG.closeout-routes-saved"
  jq '.http.routers.graphql.rule="PathPrefix(`/drift`)"' "$MOCK_LOG.restore-routes" \
    > "$MOCK_LOG.restore-routes.next"
  mv "$MOCK_LOG.restore-routes.next" "$MOCK_LOG.restore-routes"
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -ne 0 ]
  [[ $output == *"public routes differ from the previous release"* ]]
  cmp "$STATE/backup-state.json" "$MOCK_LOG.interrupted-closeout-state"
  mv "$MOCK_LOG.closeout-routes-saved" "$MOCK_LOG.restore-routes"
  jq '.migrationRecovery.candidateAborted=false' "$STATE/backup-state.json" > "$STATE/backup-state.next"
  mv "$STATE/backup-state.next" "$STATE/backup-state.json"
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -ne 0 ]
  [ ! -e "$MOCK_LOG.migration-claim" ]
  cp "$MOCK_LOG.interrupted-closeout-state" "$STATE/backup-state.json"
  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output == *"reconcile already reopened ownership"* ]]
  export MOCK_CLOSEOUT_CLAIM_KILL=true
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -eq 137 ]
  kill "$(cat "$MOCK_LOG.latest-forward-pid")"
  cmp "$STATE/backup-state.json" "$MOCK_LOG.interrupted-closeout-state"
  [ -e "$MOCK_LOG.migration-claim" ]
  [ ! -e "$MOCK_LOG.lease" ]
  export MOCK_CLOSEOUT_CLAIM_KILL=false
  closeout_holder=$(jq -er .spec.holderIdentity "$MOCK_LOG.migration-claim")
  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output == *"RECOVER-$closeout_holder"* ]]
  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$ARTIFACT" "$closeout_holder" "RECOVER-$closeout_holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.migration-claim" ]
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -eq 0 ]
  [[ $output == *"no application or storage changes were made"* ]]
  jq -e '.migrationRecovery.ownershipReleasedAt | type == "string"' "$STATE/backup-state.json" > /dev/null
  [ ! -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.migration-claim" ]
  cp "$MOCK_LOG.terminal-lease" "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.migration-claim" ]
  sed -n "$((closeout_calls + 1)),\$p" "$MOCK_LOG" > "$MOCK_LOG.closeout-only"
  run ! grep -Eq 'restore-volume|delete pvc|scale deployment|set env deployment|patch service|apply -f|create secret' \
    "$MOCK_LOG.closeout-only"
  python3 - "$STATE" "$MOCK_LOG.interrupted-closeout-state" << 'PY'
import importlib.util, json, pathlib, shutil, sys

spec = importlib.util.spec_from_file_location("upload", "provisioning/files/backup-upload.py")
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)
state = pathlib.Path(sys.argv[1])
directory = pathlib.Path("uploader-closeout").resolve()
directory.mkdir(mode=0o700)
config = {"stateDirectory": str(directory)}
maintenance = directory / "maintenance"
maintenance.mkdir(mode=0o700)
shutil.copyfile(sys.argv[2], maintenance / "backup-state.json")
assert upload.report_status(config)["maintenanceActive"] is True
upload.archive_recovered_maintenance(config)
assert maintenance.exists()
shutil.copyfile(state / "backup-state.json", maintenance / "backup-state.json")
credential = directory / "maintenance.previous-runtime-secret.json"
shutil.copyfile(str(state) + ".previous-runtime-secret.json", credential)
credential.chmod(0o600)
assert upload.report_status(config)["maintenanceActive"] is False
upload.archive_recovered_maintenance(config)
backup_id = json.loads((state / "backup-state.json").read_text())["backupId"]
assert not maintenance.exists()
assert (directory / "maintenance-history" / backup_id / "backup-state.json").exists()
assert (directory / "maintenance-history" / (backup_id + ".previous-runtime-secret.json")).exists()
PY
  local reopened_state
  reopened_state=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)
  local reopened_call_count
  reopened_call_count=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-4"
  [ "$status" -ne 0 ]
  [ "$reopened_state" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  sed -n "$((reopened_call_count + 1)),\$p" "$MOCK_LOG" > "$MOCK_LOG.reopened-attempt"
  run ! grep -Eq 'create -f .*restore-volume-pod|exec restore-volume-|delete pvc' \
    "$MOCK_LOG.reopened-attempt"
}
