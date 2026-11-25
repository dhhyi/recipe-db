#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup
load production-k3d-restore-setup

@test "current tooling restores immutable older release sources without changing checkout" {
  restore_fixture
  export MOCK_SOURCE_REVISION="$MOCK_REVISION"
  printf '*\n' > .gitignore
  printf 'new tooling input\n' > message-bus/nats.conf
  git add -f .gitignore message-bus/nats.conf
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Separate tooling inputs'
  local tooling_revision
  tooling_revision=$(git rev-parse HEAD)

  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"metadata and templates must match"* ]]
  run bash .scripts/production-k3d.sh --release-sources-from-git restore "$VALUES" \
    "$RESTORE_MANIFEST" "$RESTORE_ARCHIVE" "$RESTORE_ID" "$RESTORE_STATE" \
    "RESTORE-$RESTORE_ID" 12884901888
  [ "$status" -eq 0 ]
  [ "$(git rev-parse HEAD)" = "$tooling_revision" ]
  [ "$(cat "$FIXTURE_ROOT/package-validation-limit")" = 12884901888 ]
  jq -e '.status == "awaiting-signoff" and .phase == "pending-signoff"
    and .import.status == "complete" and .readChecks.status == "passed"' \
    "$RESTORE_STATE/restore-state.json"
}

@test "historical restore renders a pinned release without optional storage helper inputs" {
  export MOCK_RESTORE_UNRELATED_INIT=true
  git rm -q .scripts/templates/storage-version-gate.sh.ytt .scripts/templates/storage-version-sidecar.sh.ytt
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Historical release without helper inputs'
  export MOCK_REVISION
  MOCK_REVISION=$(git rev-parse HEAD)
  export MOCK_SOURCE_REVISION="$MOCK_REVISION"
  restore_fixture
  printf '*\n' > .gitignore
  printf 'new tooling input\n' > message-bus/nats.conf
  git add -f .gitignore message-bus/nats.conf
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'New tooling inputs'

  run bash .scripts/production-k3d.sh --release-sources-from-git restore "$VALUES" \
    "$RESTORE_MANIFEST" "$RESTORE_ARCHIVE" "$RESTORE_ID" "$RESTORE_STATE" "RESTORE-$RESTORE_ID"
  [ "$status" -eq 0 ]
  grep -q "ytt .*source-$MOCK_REVISION/.scripts/templates/kubernetes-template.yml" "$MOCK_LOG"
  run ! grep -E '^ytt .*storage-version-(gate|sidecar)\.sh\.ytt' "$MOCK_LOG"
  jq -e '.status == "awaiting-signoff" and .phase == "pending-signoff"
    and .import.status == "complete" and .readChecks.status == "passed"' \
    "$RESTORE_STATE/restore-state.json"
  jq -e '.items[] | select(.metadata.name == "recipes") |
    .spec.template.spec.initContainers[0].env[0].value == "custom"' "$MOCK_LOG.restore-deployments"
}

@test "historical recovery preview requires matching sources or explicit immutable Git release sources" {
  restore_fixture
  export MOCK_SOURCE_REVISION="$MOCK_REVISION"
  printf '*\n' > .gitignore
  printf 'changed tooling metadata\n' > message-bus/nats.conf
  git add -f .gitignore message-bus/nats.conf
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Separate recovery tooling inputs'
  run bash .scripts/production-k3d.sh recovery-plan "$VALUES" \
    "$RESTORE_MANIFEST" "$RESTORE_ARCHIVE" "$RESTORE_ID" "$RESTORE_STATE"
  [ "$status" -ne 0 ]
  [[ $output == *"metadata and templates must match"* ]]
  printf '{"items":[]}\n' > "$MOCK_LOG.restore-deployments"
  run bash .scripts/production-k3d.sh --release-sources-from-git recovery-plan "$VALUES" \
    "$RESTORE_MANIFEST" "$RESTORE_ARCHIVE" "$RESTORE_ID" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  [[ $output == *"preview saved"* ]]
  [[ $output != *"metadata and templates must match"* && $output != *"Git release sources are limited"* ]]
}

@test "pending restore preview refuses to rewrite state while a recovery command claim is held" {
  restore_real_package_fixture
  set_value '.timeoutSeconds=8'
  run_restore
  [ "$status" -eq 0 ]
  cp "$RESTORE_STATE/restore-state.json" "$FIXTURE_ROOT/restore-state-before-preview.json"
  jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ)" '
    {apiVersion:"coordination.k8s.io/v1",kind:"Lease",
      metadata:{name:"recipe-db-recovery-command",namespace:"kube-system",
        labels:{"app.kubernetes.io/part-of":"recipe-db"}},
      spec:{holderIdentity:"other-recovery-command",leaseDurationSeconds:45,renewTime:$now}}' \
    > "$MOCK_LOG.recovery-command-lease"
  local alternate_id=backup-20261101123456-43
  restore_alternate_real_package "$alternate_id" "2026-11-01T12:34:56Z"

  run bash .scripts/production-k3d.sh recovery-plan "$VALUES" \
    "$RESTORE_ALT_MANIFEST" "$RESTORE_ALT_ARCHIVE" "$alternate_id" "$RESTORE_STATE"
  [ "$status" -ne 0 ]
  [[ $output == *"another recovery command is active"* ]]
  cmp "$FIXTURE_ROOT/restore-state-before-preview.json" "$RESTORE_STATE/restore-state.json"
}

@test "fresh Pi HTTPS restore creates retained storage before applying Traefik certificate infrastructure" {
  restore_fixture
  export MOCK_RETAINED_CLASS_MISSING=true
  export MOCK_SERVICE_TYPE=ClusterIP
  pi_https_restore_values
  set_value '.timeoutSeconds=1'
  run_restore 12884901888
  printf '%s\n' "$output"
  [ "$status" -ne 0 ]
  [ "$(cat "$FIXTURE_ROOT/package-validation-limit")" = 12884901888 ]
  [[ $output == *"restore ingress is not a safe LoadBalancer"* ]]
  local storage infrastructure inspection contact
  storage=$(awk '/create -f .*retained-storage-class.json/ {print NR; exit}' "$MOCK_LOG")
  inspection=$(awk '/delete pod recipe-db-storage-inspection/ {print NR; exit}' "$MOCK_LOG")
  infrastructure=$(awk '/apply -f .*infrastructure.yml/ {print NR; exit}' "$MOCK_LOG")
  contact=$(awk '/create secret generic recipe-db-acme-contact/ {print NR; exit}' "$MOCK_LOG")
  [ -n "$storage" ] && [ -n "$inspection" ] && [ -n "$infrastructure" ]
  [ "$storage" -lt "$inspection" ]
  [ "$inspection" -lt "$infrastructure" ]
  [ -n "$contact" ] && [ "$contact" -lt "$infrastructure" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  run ! grep -q 'exec -i restore-volume-' "$MOCK_LOG"
  export MOCK_ACME_CONTACT_ERROR=true
  RESTORE_STATE="$FIXTURE_ROOT/backups/contact-failure"
  rm "$MOCK_LOG.lease" "$MOCK_LOG.cluster-restore-state"
  : > "$MOCK_LOG"
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"ACME contact Secret could not be applied"* ]]
  [[ $output != *"unsafe-private-contact"* ]]
  [ -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'apply -f .*infrastructure.yml|exec -i restore-volume-' "$MOCK_LOG"
}

@test "Pi HTTPS restore rejects private application HTTP Service exposure" {
  restore_fixture
  pi_https_restore_values
  set_value '.timeoutSeconds=1'
  export MOCK_PRIVATE_HTTP=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore ingress is not a safe LoadBalancer"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  run ! grep -Eq 'restore-final-routes|exec -i restore-volume-' "$MOCK_LOG"
}

@test "Pi HTTPS restore rejects a private target port" {
  restore_fixture
  pi_https_restore_values
  set_value '.timeoutSeconds=1'
  export MOCK_TARGET_DRIFT=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore ingress is not a safe LoadBalancer"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  run ! grep -Eq 'restore-final-routes|exec -i restore-volume-' "$MOCK_LOG"
}

@test "Pi HTTPS restore rejects a non-TCP Service port" {
  restore_fixture
  pi_https_restore_values
  set_value '.timeoutSeconds=1'
  export MOCK_PROTOCOL_DRIFT=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore ingress is not a safe LoadBalancer"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  run ! grep -Eq 'restore-final-routes|exec -i restore-volume-' "$MOCK_LOG"
}

@test "restore imports only after ALL volumes are empty and exposes public reads after read-only checks" {
  restore_fixture
  set_value '.timeoutSeconds=8'
  run_restore
  [ "$status" -eq 0 ]
  [[ $output == *"awaiting operator sign-off"* ]]
  [ -e "$MOCK_LOG.guard-completion-ready" ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "awaiting-signoff" and .phase == "pending-signoff"
    and .import.status == "complete" and .readChecks.status == "passed"
    and .writesMayHaveOpened == false and .probeRecipeId == null' \
    "$RESTORE_STATE/restore-state.json"
  [ ! -e "$MOCK_LOG.restore-mutation-attempt" ]
  cmp "$FIXTURE_ROOT/tar-data/recipes/nested/data.bin" \
    "$FIXTURE_ROOT/imported/recipes/nested/data.bin"
  local checked imported last_check reads opening
  checked=$(grep -c 'exec restore-volume-.*-- sh -ec' "$MOCK_LOG")
  [ "$checked" -ge 11 ]
  imported=$(awk '/exec -i restore-volume-.*tar -xpkf/ {print NR; exit}' "$MOCK_LOG")
  last_check=$(awk '/exec restore-volume-typesense -- sh -ec/ {print NR; exit}' "$MOCK_LOG")
  [ "$last_check" -lt "$imported" ]
  reads=$(awk '/curl .*recipe\/old/ {n=NR} END {print n}' "$MOCK_LOG")
  opening=$(awk '/from-file=routes.yml=.*restore-final-routes/ {print NR; exit}' "$MOCK_LOG")
  [ "$reads" -lt "$opening" ]
  jq -e '.http.routers["restore-public-barrier"] == null' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "browse" and
    any(.spec.template.spec.containers[].env[]; .name == "GRAPHQL_URL"
      and .value == "http://traefik:3000/graphql"))' "$MOCK_LOG.restore-deployments"
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance"))' \
    "$MOCK_LOG.restore-deployments"
  [ "$(jq -r '.metadata.annotations["recipe-db/phase"]' "$MOCK_LOG.lease")" = awaiting-signoff ]
  run ! grep -Eq 'createRecipe|updateRecipe|deleteRecipe|recipe/probe' "$MOCK_LOG"
  run ! grep -q private-restore-token "$MOCK_LOG"
}

@test "restore rejects file permission changes after import" {
  restore_fixture
  export MOCK_RESTORE_METADATA_DRIFT=mode
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restored volume ownership or permissions differ: recipes"* ]]
  [ -e "$MOCK_LOG.imported" ]
  [ ! -e "$RESTORE_STATE/restore-state.json" ] \
    || ! jq -e '.import.status == "complete"' "$RESTORE_STATE/restore-state.json"
}

@test "restore rejects numeric ownership changes after import" {
  restore_fixture
  export MOCK_RESTORE_METADATA_DRIFT=owner
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restored volume ownership or permissions differ: recipes"* ]]
  [ -e "$MOCK_LOG.imported" ]
  [ ! -e "$RESTORE_STATE/restore-state.json" ] \
    || ! jq -e '.import.status == "complete"' "$RESTORE_STATE/restore-state.json"
}

@test "restore rejects a package revision that differs from its immutable source artifact" {
  restore_fixture
  printf 'different source artifact revision\n' > source-revision.txt
  git add -f source-revision.txt
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Different immutable source revision'
  export MOCK_SOURCE_REVISION
  MOCK_SOURCE_REVISION=$(git rev-parse HEAD)

  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"backup source revision differs from the immutable release artifact"* ]]
  [ ! -e "$MOCK_LOG.imported" ]
  [ ! -e "$RESTORE_STATE/restore-state.json" ]
}

@test "cutover restore imports the unchanged backup into candidate volumes and captures that release without opening writes" {
  restore_fixture
  export MOCK_CUTOVER_CAPTURE=true
  export MOCK_BACKUP=true
  local original_revision original_manifest_sha original_archive_sha candidate candidate_revision path
  printf '*\n' > .gitignore
  git add -f .gitignore
  git add -A
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Clean cutover fixture baseline'
  original_revision=$(git rev-parse HEAD)
  candidate="ghcr.io/dhhyi/recipe-db-releases@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  jq --arg revision "$original_revision" '
    .source += {target:"pi",cluster:"recipe-db-pi",context:"recipe-db-pi",namespace:"recipe-db"}
    | .source.revision=$revision | .contentFingerprint="original-content-fingerprint"
  ' "$RESTORE_MANIFEST" > "$FIXTURE_ROOT/cutover-package.json"
  mv "$FIXTURE_ROOT/cutover-package.json" "$RESTORE_MANIFEST"
  printf '\n# candidate release fixture\n' >> .scripts/templates/kubernetes-template.yml
  git add -f .scripts/templates/kubernetes-template.yml
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Candidate cutover release'
  candidate_revision=$(git rev-parse HEAD)
  export MOCK_SOURCE_REVISION="$original_revision" MOCK_REVISION="$candidate_revision"
  original_manifest_sha=$(sha256sum "$RESTORE_MANIFEST" | cut -d ' ' -f 1)
  original_archive_sha=$(sha256sum "$RESTORE_ARCHIVE" | cut -d ' ' -f 1)
  local cutover_state="$FIXTURE_ROOT/backups/cutover-restore"
  local cutover_snapshot="$FIXTURE_ROOT/backups/cutover-snapshot"
  chmod 700 "$FIXTURE_ROOT/backups"

  run bash .scripts/production-k3d.sh --release-sources-from-git cutover-restore "$VALUES" \
    "$RESTORE_MANIFEST" "$RESTORE_ARCHIVE" "$RESTORE_ID" "$cutover_state" \
    "$candidate" "$cutover_snapshot" "CUTOVER-RESTORE-$RESTORE_ID" 12884901888
  [ "$status" -eq 0 ]
  [ "$(cat "$FIXTURE_ROOT/package-validation-limits")" = $'12884901888\n12884901888' ]
  [ "$(sha256sum "$RESTORE_MANIFEST" | cut -d ' ' -f 1)" = "$original_manifest_sha" ]
  [ "$(sha256sum "$RESTORE_ARCHIVE" | cut -d ' ' -f 1)" = "$original_archive_sha" ]
  jq -e --arg candidate "$candidate" --arg revision "$candidate_revision" '
    .backupId == "backup-20261031123456-42"
    and .artifact == $candidate and .revision == $revision
    and .cutover.sourceRelease == "ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    and .cutover.sourceRevision != $revision
    and .status == "awaiting-signoff" and .phase == "pending-signoff"
    and .import.status == "complete" and .readChecks.status == "passed"
    and .writesMayHaveOpened == false
  ' "$cutover_state/restore-state.json"
  jq -e --arg candidate "$candidate" --arg revision "$candidate_revision" '
    .source.target == "local" and .source.cluster == "recipe-db-rehearsal"
    and .source.context == "k3d-recipe-db-rehearsal" and .source.artifact == $candidate
    and .source.revision == $revision and .backupId != "backup-20261031123456-42"
  ' "$cutover_snapshot/manifest.json"
  [ ! -e "$cutover_snapshot/backup-state.json" ]
  cmp "$FIXTURE_ROOT/tar-data/recipes/nested/data.bin" \
    "$FIXTURE_ROOT/imported/recipes/nested/data.bin"
  tar --numeric-owner -tvf "$FIXTURE_ROOT/recipes.tar" | grep -Fq "$(id -u)/$(id -g)"
  grep -Fq 'tar -xpkf - --numeric-owner' "$MOCK_LOG"
  for path in recipes/nested recipes/nested/data.bin; do
    [ "$(stat -c '%a:%Y' "$FIXTURE_ROOT/tar-data/$path")" = \
      "$(stat -c '%a:%Y' "$FIXTURE_ROOT/imported/$path")" ]
    [ "$(stat -c '%u:%g' "$FIXTURE_ROOT/tar-data/$path")" = \
      "$(stat -c '%u:%g' "$FIXTURE_ROOT/imported/$path")" ]
  done
  [ "$(stat -c '%a:%u:%g' "$FIXTURE_ROOT/tar-data/recipes")" = \
    "$(stat -c '%a:%u:%g' "$FIXTURE_ROOT/imported/recipes")" ]
  [ ! -e "$MOCK_LOG.restore-mutation-attempt" ]
  run ! grep -Eq 'createRecipe|updateRecipe|deleteRecipe|recipe/probe' "$MOCK_LOG"
  run ! grep -Eq 'apply -f .*backup-cleanup-job\.yml|patch job backup-cleanup|wait --for=condition=complete job/backup-cleanup' \
    "$MOCK_LOG"
  [ "$(jq -r '.metadata.annotations["recipe-db/phase"]' "$MOCK_LOG.lease")" = awaiting-signoff ]
  [ "$(wc -l < "$MOCK_LOG.forward-pids-traefik")" -eq 2 ]
  [ ! -e "$MOCK_LOG.traefik-forward-overlap" ]
  local forward_pid
  while IFS= read -r forward_pid; do
    run ! kill -0 "$forward_pid" 2> /dev/null
  done < "$MOCK_LOG.forward-pids-traefik"
  while IFS= read -r forward_pid; do
    run ! kill -0 "$forward_pid" 2> /dev/null
  done < "$MOCK_LOG.forward-pids-browse"
}

@test "cutover restore rejects a package revision that differs from its immutable source artifact" {
  restore_fixture
  printf '*\n' > .gitignore
  git add -f .gitignore
  git add -A
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Clean cutover fixture baseline'
  local original_revision source_revision candidate candidate_revision cutover_state cutover_snapshot
  original_revision=$(git rev-parse HEAD)
  printf 'different source artifact revision\n' > source-revision.txt
  git add -f source-revision.txt
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Different immutable source revision'
  source_revision=$(git rev-parse HEAD)
  printf '\n# candidate release fixture\n' >> .scripts/templates/kubernetes-template.yml
  git add -f .scripts/templates/kubernetes-template.yml
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Candidate cutover release'
  candidate_revision=$(git rev-parse HEAD)
  candidate="ghcr.io/dhhyi/recipe-db-releases@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  export MOCK_SOURCE_REVISION="$source_revision" MOCK_REVISION="$candidate_revision"
  jq --arg revision "$original_revision" '
    .source += {target:"pi",cluster:"recipe-db-pi",context:"recipe-db-pi",namespace:"recipe-db"}
    | .source.revision=$revision
  ' "$RESTORE_MANIFEST" > "$FIXTURE_ROOT/cutover-package.json"
  mv "$FIXTURE_ROOT/cutover-package.json" "$RESTORE_MANIFEST"
  cutover_state="$FIXTURE_ROOT/backups/cutover-restore"
  cutover_snapshot="$FIXTURE_ROOT/backups/cutover-snapshot"

  run bash .scripts/production-k3d.sh --release-sources-from-git cutover-restore "$VALUES" \
    "$RESTORE_MANIFEST" "$RESTORE_ARCHIVE" "$RESTORE_ID" "$cutover_state" \
    "$candidate" "$cutover_snapshot" "CUTOVER-RESTORE-$RESTORE_ID" 12884901888
  [ "$status" -ne 0 ]
  [[ $output == *"backup source revision differs from the immutable release artifact"* ]]
  [ ! -e "$MOCK_LOG.imported" ]
  [ ! -e "$cutover_state/restore-state.json" ]
  run ! grep -Fq "$candidate" "$MOCK_LOG"
  run ! grep -q '^kubectl' "$MOCK_LOG"
}

@test "restore accepts a valid empty dataset without creating an application record" {
  restore_fixture
  export MOCK_RESTORE_EMPTY=true
  run_restore
  [ "$status" -eq 0 ]
  jq -e '.status == "awaiting-signoff" and .import.status == "complete"
    and .readChecks.status == "passed" and .writesMayHaveOpened == false' \
    "$RESTORE_STATE/restore-state.json"
  grep -Fq 'searchRecipes' "$MOCK_LOG"
  grep -Fq 'http://127.0.0.1:18082/' "$MOCK_LOG"
  run ! grep -Eq 'createRecipe|updateRecipe|deleteRecipe|recipe/probe' "$MOCK_LOG"
  [ ! -e "$MOCK_LOG.restore-mutation-attempt" ]
}

@test "restore status reports pending progress lease maintenance and active public reads" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.savedProgress.status == "awaiting-signoff"
    and .savedProgress.import.status == "complete"
    and .savedProgress.readChecks.status == "passed"
    and .savedProgress.writesMayHaveOpened == false
    and .lease.present and .lease.ownedByRestore
    and .lease.phase == "awaiting-signoff"
    and .observed.graphql.mode == "maintenance"
    and .observed.graphql.maintenanceQuery == true
    and .observed.graphql.maintenanceVerified
    and .observed.publicRoutes.normalRoutesObserved
    and .writesMayHaveOpened == false' <<< "$output"
}

@test "restore status withholds reopening recommendation for a mismatched Lease" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local saved_lease_uid
  saved_lease_uid=$(jq -er .leaseUid "$RESTORE_STATE/restore-state.json")
  jq '.metadata.uid="replacement-lease-uid"' "$MOCK_LOG.lease" > "$MOCK_LOG.lease.next"
  mv "$MOCK_LOG.lease.next" "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.lease.present and .lease.holder != null
    and (.lease.ownedByRestore | not)
    and (.nextAction | contains("Inspect saved progress, actual access mode/routes, and Lease"))
    and (.nextAction | contains("Operator may approve reopening separately") | not)' <<< "$output"
  jq --arg uid "$saved_lease_uid" \
    '.metadata.uid=$uid | .metadata.annotations["recipe-db/phase"]="reopening"' \
    "$MOCK_LOG.lease" > "$MOCK_LOG.lease.next"
  mv "$MOCK_LOG.lease.next" "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.lease.ownedByRestore and .lease.phase == "reopening"
    and (.nextAction | contains("Inspect saved progress, actual access mode/routes, and Lease"))
    and (.nextAction | contains("Operator may approve reopening separately") | not)' <<< "$output"
}

@test "restore status reports possible write exposure when maintenance cannot be queried" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  export MOCK_RESTORE_HTTP_FAIL=true
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.observed.graphql.mode == "maintenance"
    and .observed.graphql.maintenanceQuery == null
    and .writesMayHaveOpened == true
    and (.nextAction | contains("Inspect this status and recent application writes"))' <<< "$output"
}

@test "restore status detects exposure recorded by another operator despite stale local phase" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  jq '.data["restore-state.json"] |= (fromjson | .writesMayHaveOpened=true |
    .status="reopening" | .phase="reopening" | tojson)' "$MOCK_LOG.cluster-restore-state" \
    > "$MOCK_LOG.cluster-restore-state.next"
  mv "$MOCK_LOG.cluster-restore-state.next" "$MOCK_LOG.cluster-restore-state"
  jq '(.items[] | select(.metadata.name == "graphql").spec.template.spec.containers[] |
    select(.name == "graphql").env[] | select(.name == "MODE").value)="production"' \
    "$MOCK_LOG.restore-deployments" > "$MOCK_LOG.restore-deployments.next"
  mv "$MOCK_LOG.restore-deployments.next" "$MOCK_LOG.restore-deployments"
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.savedProgress.status == "awaiting-signoff"
    and .savedStateMatchesCluster == false
    and .observed.graphql.mode == "production"
    and .observed.graphql.maintenanceQuery == false
    and .writesMayHaveOpened == true
    and (.nextAction | contains("Inspect this status and recent application writes"))' <<< "$output"
}

@test "restore status treats local and durable state mismatch as possible write exposure" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  jq '.data["restore-state.json"] |= (fromjson | .phase="inconsistent" | tojson)' \
    "$MOCK_LOG.cluster-restore-state" > "$MOCK_LOG.cluster-restore-state.next"
  mv "$MOCK_LOG.cluster-restore-state.next" "$MOCK_LOG.cluster-restore-state"
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.savedProgress.writesMayHaveOpened == false
    and .savedStateMatchesCluster == false
    and .observed.graphql.maintenanceVerified
    and .observed.publicRoutes.normalRoutesObserved
    and .writesMayHaveOpened == true
    and (.nextAction | contains("Inspect this status and recent application writes"))' <<< "$output"
}

@test "restore reopening refuses local state that differs from durable cluster state" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  jq '.writesMayHaveOpened=true' "$RESTORE_STATE/restore-state.json" \
    > "$RESTORE_STATE/restore-state.next"
  mv "$RESTORE_STATE/restore-state.next" "$RESTORE_STATE/restore-state.json"
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"local and durable restore state differ"* ]]
  [ ! -e "$MOCK_LOG.reopening" ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "restore status treats an unexpected public router as possible write exposure" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  export MOCK_RESTORE_ROUTE_UNEXPECTED=true
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.observed.publicRoutes.configuredRoutesMatchSaved
    and (.observed.publicRoutes.activeRoutesMatchConfiguration | not)
    and (.observed.publicRoutes.normalRoutesObserved | not)
    and .writesMayHaveOpened == true
    and (.nextAction | contains("Inspect this status and recent application writes"))' <<< "$output"
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"active public routers do not match"* ||
    $output == *"configured public routes differ"* ]]
  jq -e '.status == "awaiting-signoff" and .writesMayHaveOpened == false' \
    "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.reopening" ]
}

@test "restore reopening refuses a surviving shutdown guard" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  export MOCK_SURVIVING_RECOVERY_GUARD=true
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"shutdown guard to be terminated and removed"* ]]
  [ ! -e "$MOCK_LOG.reopening" ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "restore reopening preserves and refuses a retained legacy write-probe identity" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  jq '.probeRecipeId="legacy-probe-recipe"' "$RESTORE_STATE/restore-state.json" \
    > "$RESTORE_STATE/restore-state.next"
  mv "$RESTORE_STATE/restore-state.next" "$RESTORE_STATE/restore-state.json"
  jq --argjson state "$(cat "$RESTORE_STATE/restore-state.json")" \
    '.data["restore-state.json"]=($state|tojson)' "$MOCK_LOG.cluster-restore-state" \
    > "$MOCK_LOG.cluster-restore-state.next"
  mv "$MOCK_LOG.cluster-restore-state.next" "$MOCK_LOG.cluster-restore-state"
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"retained write-probe identity requires operator investigation"* ]]
  jq -e '.probeRecipeId == "legacy-probe-recipe"' "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.reopening" ]
}

@test "restore retains its barrier when local ingress is not a safe LoadBalancer" {
  restore_fixture
  set_value '.timeoutSeconds=1'
  export MOCK_SERVICE_TYPE=ClusterIP
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore ingress is not a safe LoadBalancer"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  run ! grep -Eq 'restore-final-routes|exec -i restore-volume-' "$MOCK_LOG"
}

@test "restore hardens historical default LoadBalancer and removes allocated NodePorts" {
  restore_fixture
  export MOCK_NODEPORT=true MOCK_SERVICE_TRANSIENT=true
  run_restore
  [ "$status" -eq 0 ]
  [ -e "$MOCK_LOG.ingress-nodeports-removed" ]
  [ "$(cat "$MOCK_LOG.service-check-count")" -ge 3 ]
  jq -e '.service.type == "LoadBalancer" and
    .service.spec.allocateLoadBalancerNodePorts == false and .deployment != null' "$MOCK_LOG.helm-values"
  local patch imports
  patch=$(awk '/patch service traefik --type=strategic --patch-file/ {print NR; exit}' "$MOCK_LOG")
  imports=$(awk '/exec -i restore-volume-.*tar -xpkf/ {print NR; exit}' "$MOCK_LOG")
  [ "$patch" -lt "$imports" ]
  jq -e '.status == "awaiting-signoff"' "$RESTORE_STATE/restore-state.json"
}

@test "restore fails closed if allocated NodePorts cannot be removed" {
  restore_fixture
  export MOCK_NODEPORT=true MOCK_INGRESS_PATCH_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore could not remove allocated ingress NodePorts"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  run ! grep -Eq 'restore-final-routes|exec -i restore-volume-' "$MOCK_LOG"
}

@test "restore never patches a LoadBalancer with unsafe exposure" {
  restore_fixture
  set_value '.timeoutSeconds=1'
  export MOCK_NODEPORT=true MOCK_EXTERNAL_IP=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore ingress is not a safe LoadBalancer"* ]]
  [ -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'patch service traefik|restore-final-routes|exec -i restore-volume-' "$MOCK_LOG"
}

@test "restore rechecks ingress before reopening and retains the barrier on drift" {
  restore_fixture
  set_value '.timeoutSeconds=8'
  export MOCK_SERVICE_DRIFT=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"ingress does not match the requested exposure without NodePorts"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  run ! grep -q 'restore-final-routes' "$MOCK_LOG"
}

@test "restore without Google imports and verifies before reopening without Redis or OAuth workloads" {
  restore_fixture
  jq 'del(.runtime.googleOAuthClientId, .secrets["google-oauth-client-secret"],
    .secrets["oauth2-cookie-secret"], .infrastructure.oauth2Proxy,
    .infrastructure.redis, .volumes.redis)' "$VALUES" > no-google.json
  mv no-google.json "$VALUES"
  run_restore
  [ "$status" -eq 0 ]
  jq -e '.status == "awaiting-signoff" and .readChecks.status == "passed"' \
    "$RESTORE_STATE/restore-state.json"

  run ! grep -Eq 'deployment/(redis|oauth2-proxy)|restore-volume-redis' "$MOCK_LOG"
  jq -e 'all(.items[]; .metadata.name != "redis" and .metadata.name != "oauth2-proxy")' \
    "$MOCK_LOG.restore-deployments"
  local reads opening
  reads=$(awk '/curl .*recipe\/old/ {n=NR} END {print n}' "$MOCK_LOG")
  opening=$(awk '/from-file=routes.yml=.*restore-final-routes/ {print NR; exit}' "$MOCK_LOG")
  [ "$reads" -lt "$opening" ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "restore reads production backends while GraphQL stays in maintenance" {
  export MOCK_RESTORE_STORAGE_HELPERS=true
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local reads transition rollout name container helper_transition
  reads=$(awk '/curl .*recipe\/old/ {print NR; exit}' "$MOCK_LOG")
  [ -n "$reads" ]
  for name in recipes images tags; do
    transition=$(awk -v name="$name" '$0 ~ "set env deployment/" name " MODE=production --containers=" {print NR; exit}' "$MOCK_LOG")
    rollout=$(awk -v name="$name" -v start="$transition" 'NR > start && $0 ~ "rollout status deployment/" name " " {print NR; exit}' "$MOCK_LOG")
    [ "$transition" -lt "$rollout" ] && [ "$rollout" -lt "$reads" ]
    for container in "$name" storage-version storage-version-gate; do
      helper_transition=$(awk -v name="$name" -v container="$container" \
        'index($0, "set env deployment/" name " MODE=production") && $NF == "--containers=" container {print NR; exit}' "$MOCK_LOG")
      [ -n "$helper_transition" ] && [ "$helper_transition" -lt "$rollout" ]
    done
  done
  jq -e '[.items[] | select(.metadata.name == "graphql") |
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance")] | all' \
    "$MOCK_LOG.restore-deployments"
  jq -e '[.items[] | select(.metadata.name == "recipes" or .metadata.name == "images" or .metadata.name == "tags") |
    .spec.template.spec |
    all((.containers[], .initContainers[] | select(.name != "unrelated"));
      all(.env[]? | select(.name == "MODE"); .value == "production")) and
    any(.initContainers[]; .name == "unrelated" and .env[0].value == "custom")] | all' \
    "$MOCK_LOG.restore-deployments"
}

@test "restore retains the barrier when a production backend rollout fails" {
  export MOCK_RESTORE_PRODUCTION_ROLLOUT_FAIL=true
  restore_fixture
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restored backends could not be switched to production"* ]]
  [ -e "$MOCK_LOG.lease" ]
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
  [ ! -e "$MOCK_LOG.probe-created" ]
}

@test "Google-enabled restore waits for Redis before starting OAuth and reopens only after verification" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local redis_ready oauth_start reads opening
  redis_ready=$(awk '/rollout status deployment\/redis / {print NR; exit}' "$MOCK_LOG")
  oauth_start=$(awk '/scale deployment\/oauth2-proxy / {print NR; exit}' "$MOCK_LOG")
  reads=$(awk '/curl .*recipe\/old/ {n=NR; exit} END {print n}' "$MOCK_LOG")
  opening=$(awk '/from-file=routes.yml=.*restore-final-routes/ {print NR; exit}' "$MOCK_LOG")
  [ -n "$redis_ready" ] && [ -n "$oauth_start" ]
  [ "$redis_ready" -lt "$oauth_start" ]
  [ "$oauth_start" -lt "$reads" ]
  [ "$reads" -lt "$opening" ]
  grep -q 'exec restore-volume-redis -- sh -ec' "$MOCK_LOG"
  [ -e "$MOCK_LOG.lease" ]
}

@test "Google-enabled restore refuses missing Redis or OAuth workloads before connecting" {
  restore_fixture
  local name
  for name in redis oauth2-proxy; do
    export MOCK_RESTORE_MISSING_WORKLOAD="$name"
    : > "$MOCK_LOG"
    run_restore
    [ "$status" -ne 0 ]
    [[ $output == *"release lacks required restore workloads"* ]]
    run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
    [ ! -e "$RESTORE_STATE" ]
  done
}

@test "restore validates package and runtime secrets before connecting or taking shared Lease" {
  restore_fixture
  export MOCK_RESTORE_PACKAGE_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"package validation failed"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  [ ! -e "$RESTORE_STATE" ]
  export MOCK_RESTORE_PACKAGE_FAIL=false
  rm -f auth-accounts.json
  run_restore
  [ "$status" -ne 0 ]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "restore identity confirmation and symlink inputs fail without mutation" {
  restore_fixture
  run bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" \
    "$RESTORE_ARCHIVE" "$RESTORE_ID" "$RESTORE_STATE" RESTORE-wrong
  [ "$status" -ne 0 ]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  ln -s "$RESTORE_ARCHIVE" package-link.tar
  run bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" \
    "$FIXTURE_ROOT/package-link.tar" "$RESTORE_ID" "$RESTORE_STATE" "RESTORE-$RESTORE_ID"
  [ "$status" -ne 0 ]
  [[ $output == *"without symlink traversal"* ]]
}

@test "restore refuses populated authoritative derived and external cache volumes without any import" {
  restore_fixture
  for name in recipes nats redis; do
    export MOCK_RESTORE_NONEMPTY="$name"
    RESTORE_STATE="$FIXTURE_ROOT/backups/nonempty-$name"
    run_restore
    [ "$status" -ne 0 ]
    [[ $output == *"populated; NOTHING will be wiped"* ]]
    jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
    [ -e "$MOCK_LOG.lease" ]
    run ! grep -Eq 'tar -xpk?f|delete pvc|delete pv|rm -rf /data' "$MOCK_LOG"
    rm "$MOCK_LOG.lease" "$MOCK_LOG.claims" "$MOCK_LOG.restore-pods" "$MOCK_LOG.cluster-restore-state"
    : > "$MOCK_LOG"
  done
}

@test "restore fails closed when the destination volume scan fails" {
  restore_fixture
  export MOCK_RESTORE_FIND_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"populated; NOTHING will be wiped"* ]]
  [ ! -e "$MOCK_LOG.imported" ]
  run ! grep -q 'exec -i restore-volume-' "$MOCK_LOG"
}

@test "restore shares kube-system Lease with deploy and backup and never steals a busy holder" {
  restore_fixture
  export MOCK_LOCK=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"cluster operation lock"* ]]
  [ ! -e "$RESTORE_STATE" ]
  grep -q -- '--namespace kube-system.*create -f .*recipe-db-deploy-lease.json' "$MOCK_LOG"
  run ! grep -Eq 'restore-volume-pod.json|apply -f .*application.yml|delete --raw' "$MOCK_LOG"
}

@test "restore refuses an existing deployment or released retained data without replacing it" {
  restore_fixture
  export MOCK_RESTORE_EXISTING=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"fresh deployment"* ]]
  [ ! -e "$RESTORE_STATE" ]
  run ! grep -Eq 'restore-volume-pod.json|apply -f .*application.yml' "$MOCK_LOG"
  export MOCK_RESTORE_EXISTING=false MOCK_RESTORE_RELEASED=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"released or unbound retained"* ]]
}

@test "restore import or verification failures retain durable barrier Lease and explicit recovery state" {
  restore_fixture
  export MOCK_RESTORE_IMPORT_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore FAILED; no success recorded"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and (.phase | startswith("import-"))' \
    "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"].entrypoints == ["web"]' "$MOCK_LOG.restore-routes"
  run ! grep -q 'restore-final-routes' "$MOCK_LOG"
}

@test "restore failed representative reads never reopen public ingress" {
  restore_fixture
  set_value '.timeoutSeconds=3'
  export MOCK_RESTORE_HTTP_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-reads"' "$RESTORE_STATE/restore-state.json"
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
}

@test "restore verifies restored full image and thumbnail bytes only on the private static ingress" {
  export MOCK_RESTORE_IMAGE=true
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  [ "$(grep -c 'curl .*18081/public/\(full\|thumb\)\.bin' "$MOCK_LOG")" -eq 2 ]
  jq -e '.status == "awaiting-signoff"' "$RESTORE_STATE/restore-state.json"
}

@test "failed read verification keeps GraphQL maintenance and permits an explicit read-only recheck" {
  local imports_before
  restore_fixture
  set_value '.timeoutSeconds=8'
  export MOCK_RESTORE_READ_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-reads"
    and .import.status == "complete" and .readChecks.status == "failed"
    and .writesMayHaveOpened == false' "$RESTORE_STATE/restore-state.json"
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance"))' \
    "$MOCK_LOG.restore-deployments"
  run ! grep -Eq 'createRecipe|updateRecipe|deleteRecipe|recipe/probe' "$MOCK_LOG"
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.observed.graphql.maintenanceVerified
    and .observed.publicRoutes.barrierConfigured
    and .observed.publicRoutes.barrierValidated
    and .observed.publicRoutes.activeRoutesMatchConfiguration
    and .writesMayHaveOpened == false
    and (.nextAction | contains("restore-recheck"))' <<< "$output"

  imports_before=$(grep -c -- 'exec -i restore-volume-.*tar -xpkf -' "$MOCK_LOG")
  unset MOCK_RESTORE_READ_FAIL
  run bash .scripts/production-k3d.sh restore-recheck "$VALUES" "$RESTORE_STATE" \
    "RECHECK-RESTORE-$RESTORE_ID"
  [ "$status" -eq 0 ]
  [[ $output == *"read-only recheck passed"* ]]
  jq -e '.status == "awaiting-signoff" and .readChecks.status == "passed"
    and any(.readChecks.attempts[]; .status == "failed")' "$RESTORE_STATE/restore-state.json"
  [ "$(grep -c -- 'exec -i restore-volume-.*tar -xpkf -' "$MOCK_LOG")" -eq "$imports_before" ]
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.recovery-command-lease" ]
}

@test "restore waits for actual Traefik route convergence and reblocks a failed cutover" {
  restore_fixture
  set_value '.timeoutSeconds=3'
  export MOCK_RESTORE_ROUTE_STALE=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output != *"awaiting operator sign-off"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-reads"' \
    "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
}

@test "restore loses shared Lease ownership mid-import without deleting another holder or opening clients" {
  restore_fixture
  export MOCK_RESTORE_LOCK_DRIFT=true
  run_restore
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  run ! grep -Eq 'delete --raw|restore-final-routes' "$MOCK_LOG"
}

@test "restore rejects changed release inputs but needs no owner token for read-only verification" {
  restore_fixture
  printf '# changed release metadata\n' >> .scripts/lib/project-metadata.sh
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"must match the immutable release"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  git checkout -- .scripts/lib/project-metadata.sh
  printf '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
  run_restore
  [ "$status" -eq 0 ]
  [[ $output == *"awaiting operator sign-off"* ]]
  [ ! -e "$MOCK_LOG.restore-mutation-attempt" ]
  jq -e '.status == "awaiting-signoff" and .readChecks.status == "passed"' \
    "$RESTORE_STATE/restore-state.json"
}

@test "restore rejects modified routing templates before connecting" {
  restore_fixture
  local template
  for template in \
    .scripts/templates/traefik-template.yml \
    .scripts/templates/browse-maintenance-template.lib.yml \
    .scripts/templates/service-template.lib.yml; do
    printf 'release route template\n' > "$template"
  done
  git add .scripts/templates
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Fixture route templates'
  MOCK_REVISION=$(git rev-parse HEAD)
  export MOCK_REVISION
  jq --arg revision "$MOCK_REVISION" '.source.revision=$revision' "$RESTORE_MANIFEST" \
    > "$RESTORE_MANIFEST.next"
  mv "$RESTORE_MANIFEST.next" "$RESTORE_MANIFEST"
  for template in \
    .scripts/templates/traefik-template.yml \
    .scripts/templates/browse-maintenance-template.lib.yml \
    .scripts/templates/service-template.lib.yml; do
    printf 'modified route template\n' >> "$template"
    run_restore
    [ "$status" -ne 0 ]
    [[ $output == *"must match the immutable release"* ]]
    git checkout -- "$template"
  done
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "restore refuses untracked routing templates before connecting" {
  restore_fixture
  printf 'untracked route template\n' > .scripts/templates/traefik-template.yml
  printf 'untracked route template\n' > .scripts/templates/browse-maintenance-template.lib.yml
  printf 'untracked route template\n' > .scripts/templates/service-template.lib.yml
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"untracked metadata or template inputs"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

restore_retained_fixture() {
  restore_fixture
  export RESTORE_HOLDER=restore-retained-42
  mkdir -p "$RESTORE_STATE"
  jq -n --arg holder "$RESTORE_HOLDER" --arg artifact "$ARTIFACT" \
    --arg sha "$(sha256sum "$VALUES" | cut -d ' ' -f 1)" --slurpfile config "$VALUES" '
    {version:1,holder:$holder,status:"recovery-required",artifact:$artifact,
      target:$config[0].target,cluster:$config[0].cluster,context:$config[0].context,
      namespace:$config[0].namespace,configSha256:$sha}' > "$RESTORE_STATE/restore-state.json"
  # production_config serializes with jq, so hash that same canonical representation.
  jq '.' "$VALUES" > canonical-values.json
  sha=$(sha256sum canonical-values.json)
  sha=${sha%% *}
  jq --arg sha "$sha" '.configSha256=$sha' "$RESTORE_STATE/restore-state.json" > state.next
  mv state.next "$RESTORE_STATE/restore-state.json"
  jq -n --arg holder "$RESTORE_HOLDER" --arg artifact "$ARTIFACT" '
    {metadata:{name:"recipe-db-deploy",namespace:"kube-system",uid:"lease-uid",resourceVersion:"42",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/operation":"restore","recipe-db/phase":"restore-import-recipes",
        "recipe-db/release":$artifact}},spec:{holderIdentity:$holder}}' > "$MOCK_LOG.lease"
  jq -n '{http:{routers:{"restore-public-barrier":{
    rule:"PathPrefix(`/`)",priority:2147482647,entrypoints:["web"],service:"restore-maintenance"}},
    services:{"restore-maintenance":{loadBalancer:{servers:[
      {url:"http://browse-maintenance.recipe-db.svc.cluster.local:80"}]}}}}}' > "$MOCK_LOG.restore-routes"
}

run_restore_abandon() {
  run bash .scripts/production-k3d.sh restore-abandon "$VALUES" "$RESTORE_STATE" \
    "$RESTORE_HOLDER" "ABANDON-$RESTORE_HOLDER-AFTER-ISOLATION"
}

@test "restore acquired Lease alone can recover but post-mutation Lease cannot use unconditional lock-recover" {
  restore_retained_fixture
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" "$RESTORE_HOLDER" "RECOVER-$RESTORE_HOLDER"
  [ "$status" -ne 0 ]
  [[ $output == *"restore-abandon with saved state"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq '.metadata.annotations["recipe-db/phase"]="acquired"' "$MOCK_LOG.lease" > lease.next
  mv lease.next "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" "$RESTORE_HOLDER" "RECOVER-$RESTORE_HOLDER"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "restore abandonment releases only an investigated isolated target while preserving data and public barrier" {
  restore_retained_fixture
  printf 'partial authoritative data\n' > partial-data
  run_restore_abandon
  [ "$status" -eq 0 ]
  [[ $output == *"data and public barrier preserved"* ]]
  [ ! -e "$MOCK_LOG.lease" ]
  [ "$(cat partial-data)" = "partial authoritative data" ]
  jq -e '.status == "abandoned" and .phase == "isolated-new-target-required"' \
    "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  run ! grep -Eq 'tar -xpk?f|delete pvc|delete pv|scale deployment|set env deployment' "$MOCK_LOG"
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"unresolved or abandoned restore state"* ]]
}

@test "restore abandonment rejects active writers helper Pods restartable Jobs and a missing public barrier" {
  restore_retained_fixture
  for flag in MOCK_ABANDON_WRITER MOCK_ABANDON_WORKER MOCK_ABANDON_JOB MOCK_ABANDON_BAD_BARRIER; do
    export "$flag=true"
    run_restore_abandon
    [ "$status" -ne 0 ]
    [ -e "$MOCK_LOG.lease" ]
    jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
    unset "$flag"
  done
  run ! grep -q 'delete --raw' "$MOCK_LOG"
}

@test "restore abandonment rejects wrong confirmation holder and changed target values before connecting" {
  restore_retained_fixture
  run bash .scripts/production-k3d.sh restore-abandon "$VALUES" "$RESTORE_STATE" \
    "$RESTORE_HOLDER" "RECOVER-$RESTORE_HOLDER"
  [ "$status" -ne 0 ]
  run bash .scripts/production-k3d.sh restore-abandon "$VALUES" "$RESTORE_STATE" \
    wrong-holder ABANDON-wrong-holder-AFTER-ISOLATION
  [ "$status" -ne 0 ]
  set_value '.timeoutSeconds=599'
  run_restore_abandon
  [ "$status" -ne 0 ]
  [[ $output == *"state, target values or holder mismatch"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  [ -e "$MOCK_LOG.lease" ]
}

@test "restore only permits ordinary deployment after a separate explicit reopening" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -eq 0 ]
  [[ $output == *"writes may now be open by explicit operator approval"* ]]
  jq -e '.status == "succeeded" and .phase == "operator-reopened"
    and .writesMayHaveOpened == true' "$RESTORE_STATE/restore-state.json"
  [ ! -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.restore-mutation-attempt" ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "failed restore-owned capture phase blocks reopening and deployment handoff" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local holder
  holder=$(jq -er .holder "$RESTORE_STATE/restore-state.json")
  jq '.metadata.annotations["recipe-db/phase"]="restore-backup-maintenance-failed"' \
    "$MOCK_LOG.lease" > "$MOCK_LOG.lease.next"
  mv "$MOCK_LOG.lease.next" "$MOCK_LOG.lease"

  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"reopening requires the exact pending-sign-off Lease phase"* ]]
  jq -e '.status == "awaiting-signoff" and .phase == "pending-signoff"
    and (.writesMayHaveOpened | not)' "$RESTORE_STATE/restore-state.json"
  jq -e --arg holder "$holder" '
    .spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "restore-backup-maintenance-failed"
  ' \
    "$MOCK_LOG.lease"

  export MOCK_LOCK=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"recipe-db-deploy cluster operation lock exists or cannot be acquired"* ]]
  jq -e --arg holder "$holder" '
    .spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "restore-backup-maintenance-failed"
  ' \
    "$MOCK_LOG.lease"
}

@test "failed reopening records possible writes and retains ownership behind maintenance" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  export MOCK_GRAPHQL_REOPEN_FAIL=true
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  jq -e '.status == "recovery-required" and .phase == "reopening"
    and .writesMayHaveOpened == true' "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.metadata.annotations["recipe-db/phase"] == "recovery-required"' "$MOCK_LOG.lease"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance"))' \
    "$MOCK_LOG.restore-deployments"
}

@test "uncertain production transition is reblocked and retains possible-write ownership" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  export MOCK_GRAPHQL_REOPEN_UNCERTAIN=true
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.reopen-mode-applied" ]
  jq -e '.status == "recovery-required" and .phase == "reopening"
    and .writesMayHaveOpened == true' "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.metadata.annotations["recipe-db/phase"] == "recovery-required"' "$MOCK_LOG.lease"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance"))' \
    "$MOCK_LOG.restore-deployments"
}

@test "restore full CLI consumes a real packaged opaque snapshot through the real validator with mocked cluster infrastructure" {
  restore_real_package_fixture
  run_restore 12884901888
  [ "$status" -eq 0 ]
  jq -e '.status == "awaiting-signoff" and .phase == "pending-signoff"' \
    "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.restore-mutation-attempt" ]
  cmp "$FIXTURE_ROOT/tar-data/tags/opaque.bin" \
    "$FIXTURE_ROOT/imported/tags/opaque.bin"
}

@test "separate local rehearsal restores the synthetic Pi backup package with read-only checks" {
  restore_real_package_fixture
  python3 - "$FIXTURE_ROOT" << 'PY'
import importlib.util
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "upload", root / "provisioning/files/backup-upload.py")
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)
snapshot = root / "capture"
package_root = root / "pi-package"
package_root.mkdir()
manifest = json.loads((snapshot / "manifest.json").read_text())
manifest["source"].update(target="pi", cluster="recipe-db-pi", context="explicit-pi")
(snapshot / "manifest.json").write_bytes(upload.json_bytes(manifest))
package = upload.create_package(
    snapshot, package_root, manifest, "pi-rehearsal", upload.DEFAULT_MAX_STAGING_BYTES)
for name in (package["manifest"], package["archive"]):
    (package_root / name).chmod(0o600)
(root / "pi-package-paths.json").write_text(json.dumps(package))
PY
  RESTORE_MANIFEST="$FIXTURE_ROOT/pi-package/$(jq -r .manifest "$FIXTURE_ROOT/pi-package-paths.json")"
  RESTORE_ARCHIVE="$FIXTURE_ROOT/pi-package/$(jq -r .archive "$FIXTURE_ROOT/pi-package-paths.json")"
  set_value '.timeoutSeconds=8'

  run_restore
  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output"
    return 1
  }
  jq -e --arg id "$RESTORE_ID" '
    .source.target == "pi" and .source.cluster == "recipe-db-pi" and .backupId == $id
  ' "$RESTORE_MANIFEST" > /dev/null
  jq -e '.status == "awaiting-signoff" and .import.status == "complete"
    and .readChecks.status == "passed" and .writesMayHaveOpened == false' \
    "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.restore-mutation-attempt" ]
}

@test "Lease phase updates reject a replacement UID even when holder is unchanged" {
  source .scripts/lib/cluster-operation-lock.sh
  work=$FIXTURE_ROOT
  cluster_operation_lock_holder=restore-holder
  cluster_operation_lock_expected_uid=old-lease-uid
  jq -n '{
    metadata:{name:"recipe-db-deploy",namespace:"kube-system",uid:"new-lease-uid",
      resourceVersion:"4",labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/phase":"awaiting-signoff"}},
    spec:{holderIdentity:"restore-holder"}
  }' > "$MOCK_LOG.lease"
  cp "$MOCK_LOG.lease" "$MOCK_LOG.lease-before-update"
  cluster_operation_lock_kubectl() {
    case "$1" in
      get) cat "$MOCK_LOG.lease" ;;
      replace) cp "${*: -1}" "$MOCK_LOG.lease" ;;
      *) return 1 ;;
    esac
  }

  run cluster_operation_lock_update restore-backup-capturing
  [ "$status" -ne 0 ]
  cmp "$MOCK_LOG.lease-before-update" "$MOCK_LOG.lease"

  cluster_operation_lock_expected_uid=new-lease-uid
  cluster_operation_lock_update restore-backup-capturing
  [ "$cluster_operation_lock_current_phase" = restore-backup-capturing ]
  jq -e '.metadata.uid == "new-lease-uid"
    and .metadata.annotations["recipe-db/phase"] == "restore-backup-capturing"
    and .spec.holderIdentity == "restore-holder"' "$MOCK_LOG.lease"
}

@test "Pi backup config identity normalizes private secret paths but not release inputs" {
  source .scripts/lib/production-config.sh
  local workstation_hash pi_hash changed_hash
  workstation_hash=$(production_backup_config_sha256 "$VALUES")
  set_value '.secrets."auth-accounts.json"="/etc/recipe-db/application-inputs/accounts-for-pi.json"'
  pi_hash=$(production_backup_config_sha256 "$VALUES")
  [ "$pi_hash" = "$workstation_hash" ]

  set_value '.origin="http://127.0.0.1:8081"'
  changed_hash=$(production_backup_config_sha256 "$VALUES")
  [ "$changed_hash" != "$workstation_hash" ]
}

@test "restore identity accepts mapped Pi secret paths but still binds config and storage" {
  source .scripts/lib/production-config.sh
  cat > "$FIXTURE_ROOT/saved-config.json" << 'JSON'
{"origin":"https://recipe.example.org","secrets":{"auth-accounts.json":"/workstation/accounts.json"}}
JSON
  cat > "$FIXTURE_ROOT/pi-config.json" << 'JSON'
{"origin":"https://recipe.example.org","secrets":{"auth-accounts.json":"/etc/recipe-db/application-inputs/accounts.json"}}
JSON
  local raw_hash normalized_hash
  raw_hash=$(sha256sum "$FIXTURE_ROOT/saved-config.json" | cut -d ' ' -f 1)
  normalized_hash=$(production_backup_config_sha256 "$FIXTURE_ROOT/saved-config.json")
  jq -n --arg config "$raw_hash" --arg normalized "$normalized_hash" '
    {configSha256:$config,backupConfigSha256:$normalized,
      restoreIdentity:{configSha256:$config,namespaceUid:"namespace-uid",
        volumes:[{name:"recipes",uid:"pvc-uid"}]}}
  ' > "$FIXTURE_ROOT/saved-restore.json"
  jq --arg config "$(sha256sum "$FIXTURE_ROOT/pi-config.json" | cut -d ' ' -f 1)" '
    {configSha256:$config,namespaceUid:"namespace-uid",
      volumes:[{name:"recipes",uid:"pvc-uid"}]}
  ' "$FIXTURE_ROOT/saved-restore.json" > "$FIXTURE_ROOT/actual-identity.json"

  production_restore_identity_matches "$FIXTURE_ROOT/saved-restore.json" \
    "$FIXTURE_ROOT/actual-identity.json" "$FIXTURE_ROOT/pi-config.json"
  jq '.restoreIdentity.volumes[0].uid="replacement-pvc"' "$FIXTURE_ROOT/saved-restore.json" \
    > "$FIXTURE_ROOT/changed-restore.json"
  run production_restore_identity_matches "$FIXTURE_ROOT/changed-restore.json" \
    "$FIXTURE_ROOT/actual-identity.json" "$FIXTURE_ROOT/pi-config.json"
  [ "$status" -ne 0 ]
  jq '.origin="http://recipe.example.org"' "$FIXTURE_ROOT/pi-config.json" \
    > "$FIXTURE_ROOT/changed-config.json"
  run production_restore_identity_matches "$FIXTURE_ROOT/saved-restore.json" \
    "$FIXTURE_ROOT/actual-identity.json" "$FIXTURE_ROOT/changed-config.json"
  [ "$status" -ne 0 ]
}

@test "restore-owned capture compares installed inputs with restored credentials" {
  cp "$BATS_TEST_DIRNAME/../lib/production-restore-backup.sh" .scripts/lib/
  mkdir -m 700 "$FIXTURE_ROOT/operator-inputs" "$FIXTURE_ROOT/input-work"
  printf 'accounts-from-restore\n' > "$FIXTURE_ROOT/operator-inputs/auth-accounts.json"
  printf 'oauth-client-from-restore' > "$FIXTURE_ROOT/operator-inputs/google-oauth-client-secret"
  printf 'cookie-from-restore' > "$FIXTURE_ROOT/operator-inputs/oauth2-cookie-secret"
  printf 'restore-contact@example.org' > "$FIXTURE_ROOT/operator-inputs/acme-account-email"
  python3 - "$FIXTURE_ROOT" << 'PY'
import base64, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
inputs = root / "operator-inputs"
runtime = {
    key: base64.b64encode((inputs / key).read_bytes()).decode()
    for key in ("auth-accounts.json", "google-oauth-client-secret", "oauth2-cookie-secret")
}
(root / "runtime-secret.json").write_text(json.dumps({
    "metadata": {"namespace": "recipe-db", "labels": {
        "app.kubernetes.io/part-of": "recipe-db"}},
    "data": runtime,
}))
(root / "acme-secret.json").write_text(json.dumps({
    "metadata": {"labels": {"app.kubernetes.io/part-of": "recipe-db"}},
    "data": {"email": base64.b64encode(
        (inputs / "acme-account-email").read_bytes()).decode()},
}))
PY
  cat > verify-inputs.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source .scripts/lib/production-restore-backup.sh
work=$FIXTURE_ROOT/input-work
namespace=recipe-db
operator_secret_keys=(auth-accounts.json google-oauth-client-secret oauth2-cookie-secret)
production_fail() { printf 'production: %s\n' "$*" >&2; exit 1; }
production_secrets() {
  local key
  for key in "${operator_secret_keys[@]}"; do
    cp "$FIXTURE_ROOT/operator-inputs/$key" "$work/$key"
  done
  cp "$FIXTURE_ROOT/operator-inputs/acme-account-email" "$work/acme-account-email"
}
kube() {
  case "$*" in
    "get secret recipe-db-runtime -o json") cat "$FIXTURE_ROOT/runtime-secret.json" ;;
    "--namespace kube-system get secret recipe-db-acme-contact -o json") cat "$FIXTURE_ROOT/acme-secret.json" ;;
    *) return 1 ;;
  esac
}
restore_backup_verify_inputs
EOF
  chmod 700 verify-inputs.sh
  run env FIXTURE_ROOT="$FIXTURE_ROOT" bash verify-inputs.sh
  [ "$status" -eq 0 ]

  printf 'different private credential' > "$FIXTURE_ROOT/operator-inputs/google-oauth-client-secret"
  run env FIXTURE_ROOT="$FIXTURE_ROOT" bash verify-inputs.sh
  [ "$status" -ne 0 ]
  [[ $output == *"installed backup inputs do not match the retained restored release"* ]]
  [[ $output != *"different private credential"* ]]
}

@test "restore-owned maintenance resumes across interrupted Lease and projection phases" {
  cp "$BATS_TEST_DIRNAME/../lib/production-restore-backup.sh" .scripts/lib/
  source .scripts/lib/production-restore-backup.sh

  run restore_backup_phase_is_allowed restore-backup-maintenance-resume \
    maintenance-pending restore-backup-upload-pending
  [ "$status" -eq 0 ]

  run restore_backup_phase_is_allowed restore-backup-maintenance-resume \
    upload-pending restore-backup-upload-pending
  [ "$status" -eq 0 ]

  run restore_backup_phase_is_allowed restore-backup-maintenance-resume \
    upload-pending restore-backup-upload-failed
  [ "$status" -eq 0 ]

  run restore_backup_phase_is_allowed restore-backup-maintenance-resume \
    maintenance-pending projection-refresh
  [ "$status" -eq 0 ]

  run restore_backup_phase_is_allowed restore-backup-maintenance-resume \
    capture restore-backup-capture-failed
  [ "$status" -ne 0 ]

  run restore_backup_phase_is_allowed restore-backup-upload-retry \
    capture restore-backup-capture-failed
  [ "$status" -eq 0 ]

  run restore_backup_phase_is_allowed restore-backup-upload-retry \
    capture copy-recipes
  [ "$status" -eq 0 ]

  run restore_backup_phase_is_allowed restore-backup-upload-retry \
    upload-pending copy-recipes
  [ "$status" -eq 0 ]

  run restore_backup_phase_is_allowed restore-backup-upload-retry \
    upload-pending restore-backup-capture-failed
  [ "$status" -eq 0 ]
}

@test "restore capture retries an interruption before snapshot preparation" {
  cp "$BATS_TEST_DIRNAME/../lib/production-restore-backup.sh" .scripts/lib/
  source .scripts/lib/production-restore-backup.sh

  run restore_backup_phase_is_allowed restore-backup-capture \
    capture restore-backup-capturing
  [ "$status" -eq 0 ]
}

@test "restore capture retry verifies reads against its retained Lease failure phase" {
  cp "$BATS_TEST_DIRNAME/../lib/production-restore-backup.sh" .scripts/lib/
  cat > load-operation.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source .scripts/lib/production-restore-backup.sh
target=pi
command=restore-backup-capture
namespace=recipe-db
cluster=recipe-db-pi
context=recipe-db-pi
work="$FIXTURE_ROOT/work"
mkdir -p "$work" "$FIXTURE_ROOT/etc" "$FIXTURE_ROOT/state/restore-captures/backup-20261101120000-1"
config_file="$FIXTURE_ROOT/etc/backup-values.yaml"
uploader_config="$FIXTURE_ROOT/uploader.json"
directory="$FIXTURE_ROOT/state/restore-captures/backup-20261101120000-1"
artifact=ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
revision=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '{}\n' > "$config_file"
printf '{"stateDirectory":"%s"}\n' "$FIXTURE_ROOT/state" > "$uploader_config"
printf '%s\n' "$artifact" > "$FIXTURE_ROOT/etc/backup-release-ref"
printf '{"storageClass":"local-path"}\n' > "$work/config.json"
config_hash=$(sha256sum "$work/config.json" | cut -d ' ' -f 1)
jq -n --arg hash "$config_hash" --arg artifact "$artifact" --arg revision "$revision" '{
  version:1,backupId:"backup-20261101120000-1",holder:"restore-holder",
  leaseUid:"lease-uid-1",status:"awaiting-signoff",phase:"pending-signoff",
  target:"pi",cluster:"recipe-db-pi",context:"recipe-db-pi",namespace:"recipe-db",
  configSha256:$hash,artifact:$artifact,revision:$revision,
  import:{status:"complete"},readChecks:{status:"passed"},
  writesMayHaveOpened:false,probeRecipeId:null
}' > "$FIXTURE_ROOT/restore-state.json"
jq -n --arg artifact "$artifact" '{
  metadata:{uid:"lease-uid-1",resourceVersion:"42",
    labels:{"app.kubernetes.io/part-of":"recipe-db"},
    annotations:{"recipe-db/phase":"restore-backup-capture-failed",
      "recipe-db/operation":"restore","recipe-db/release":$artifact}},
  spec:{holderIdentity:"restore-holder"}
}' > "$FIXTURE_ROOT/lease.json"
jq -n --rawfile state "$FIXTURE_ROOT/restore-state.json" '{
  metadata:{namespace:"recipe-db",labels:{"app.kubernetes.io/part-of":"recipe-db"}},
  data:{"restore-state.json":$state}
}' > "$FIXTURE_ROOT/configmap.json"
jq -n '{
  format:"recipe-db-restore-capture",formatVersion:1,
  restoreBackupId:"backup-20261101120000-1",restoreHolder:"restore-holder",
  restoreLeaseUid:"lease-uid-1",status:"capture-failed",phase:"capture"
}' > "$directory/restore-capture-state.json"
restore_backup_check_confirmations() { :; }
connect() { :; }
recovery_command_acquire() { :; }
kube() { cat "$FIXTURE_ROOT/configmap.json"; }
cluster_operation_lock_status() { cat "$FIXTURE_ROOT/lease.json"; }
production_backup_config_sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
production_storage_preflight() { :; }
pull_release() { :; }
render() { :; }
restore_backup_verify_inputs() { :; }
recovery_identity() { :; }
production_restore_identity_matches() { return 0; }
restore_backup_verify_pending_reads() { printf '%s\n' "$2" > "$FIXTURE_ROOT/read-phase"; }
restore_backup_load_operation "$config_file" "$uploader_config" "$directory" \
  backup-20261101120000-1 restore-holder lease-uid-1 \
  CAPTURE-RESTORE-backup-20261101120000-1-restore-holder
EOF
  chmod 700 load-operation.sh
  run env FIXTURE_ROOT="$FIXTURE_ROOT" bash load-operation.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$FIXTURE_ROOT/read-phase")" = restore-backup-capture-failed ]
}

@test "restore-owned completion records read evidence before the final Lease transition" {
  cp "$BATS_TEST_DIRNAME/../lib/production-restore-backup.sh" .scripts/lib/
  cat > completion-order.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source .scripts/lib/production-restore-backup.sh
work=$FIXTURE_ROOT
backup_id=backup-20261101120100-2
restore_backup_holder=restore-holder
restore_backup_progress() { printf 'progress:%s\n' "$*" >> "$MOCK_LOG.lifecycle"; }
restore_backup_set_lease_phase() { printf 'lease:%s\n' "$1" >> "$MOCK_LOG.lifecycle"; }
backup_restore_maintenance() { printf 'maintenance\n' >> "$MOCK_LOG.lifecycle"; }
restore_backup_verify_pending_reads() {
  printf 'verify:%s\n' "$2" >> "$MOCK_LOG.lifecycle"
  [[ ${RESTORE_READS_FAIL:-false} != true ]]
}
backup_reblock_graphql() { printf 'reblock\n' >> "$MOCK_LOG.lifecycle"; }
restore_backup_record_completion() { printf 'completion\n' >> "$MOCK_LOG.lifecycle"; }
restore_backup_finish_maintenance "$FIXTURE_ROOT/config.yaml" "$FIXTURE_ROOT/uploader-state"
EOF
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" bash completion-order.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG.lifecycle")" = $'progress:upload-verified maintenance-pending backup-20261101120100-2\nlease:restore-backup-maintenance-pending\nmaintenance\nlease:restore-backup-maintenance-pending\nverify:restore-backup-maintenance-pending\ncompletion\nlease:awaiting-signoff' ]

  : > "$MOCK_LOG.lifecycle"
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" RESTORE_READS_FAIL=true bash completion-order.sh
  [ "$status" -ne 0 ]
  run grep -Fxq 'reblock' "$MOCK_LOG.lifecycle"
  [ "$status" -eq 0 ]
  run grep -Fxq 'lease:awaiting-signoff' "$MOCK_LOG.lifecycle"
  [ "$status" -ne 0 ]
  run grep -Fxq 'completion' "$MOCK_LOG.lifecycle"
  [ "$status" -ne 0 ]
}

@test "restore-owned capture publishes one complete snapshot before maintenance and refuses recapture" {
  cp "$BATS_TEST_DIRNAME/../lib/production-restore-backup.sh" .scripts/lib/
  cat > capture-pipeline.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source .scripts/lib/production-config.sh
source .scripts/lib/cluster-operation-lock.sh
source .scripts/lib/production-restore-backup.sh
if [[ ${REUSE_STATE:-false} != true ]]; then
  rm -rf "$FIXTURE_ROOT/capture-work" "$FIXTURE_ROOT/work" "$FIXTURE_ROOT/etc"
  mkdir -m 700 -p "$FIXTURE_ROOT/capture-work" "$FIXTURE_ROOT/work" "$FIXTURE_ROOT/etc"
  cat > "$FIXTURE_ROOT/work/config.json" << 'CONFIG'
{"target":"pi","cluster":"recipe-db-pi","context":"explicit-pi","namespace":"recipe-db","storageClass":"recipe-db-retained","infrastructure":{"maintenance":"nginx:1.28"},"secrets":{"auth-accounts.json":"/secret/auth-accounts.json"}}
CONFIG
  printf '{"stateDirectory":"%s"}\n' "$FIXTURE_ROOT/capture-work" > "$FIXTURE_ROOT/uploader.json"
  printf '{}\n' > "$FIXTURE_ROOT/etc/backup-values.yaml"
  printf '%s\n' "$ARTIFACT" > "$FIXTURE_ROOT/etc/backup-release-ref"
  if [[ ${BACKUP_REFERENCE_DRIFT:-false} == true ]]; then
    printf '%s\n' 'wrong-release-reference' > "$FIXTURE_ROOT/etc/backup-release-ref"
  fi
  config_sha=$(production_backup_config_sha256 "$FIXTURE_ROOT/work/config.json")
  raw_config_sha=$(sha256sum "$FIXTURE_ROOT/work/config.json" | cut -d ' ' -f 1)
  restore_id=backup-20261101120000-1
  holder=restore-holder
  lease_uid=lease-uid-1
  restore_identity=$(jq -cn --arg config "$raw_config_sha" \
    '{configSha256:$config,namespace:"recipe-db",pvcs:[]}')
  mkdir -m 700 -p "$FIXTURE_ROOT/capture-work/restore-captures/$restore_id"
  jq -n --arg id "$restore_id" --arg holder "$holder" --arg uid "$lease_uid" \
    '{format:"recipe-db-restore-capture",formatVersion:1,restoreBackupId:$id,
      restoreHolder:$holder,restoreLeaseUid:$uid,status:"capture",phase:"capture"}' \
    > "$FIXTURE_ROOT/capture-work/restore-captures/$restore_id/restore-capture-state.json"
  jq -n --arg id "$restore_id" --arg holder "$holder" --arg uid "$lease_uid" \
    --arg configSha "$raw_config_sha" --arg backupConfigSha "$config_sha" \
    --arg artifact "$ARTIFACT" --arg revision "$MOCK_REVISION" \
    --argjson identity "$restore_identity" '
    {version:1,backupId:$id,holder:$holder,leaseUid:$uid,status:"awaiting-signoff",
      phase:"pending-signoff",target:"pi",cluster:"recipe-db-pi",context:"explicit-pi",
      namespace:"recipe-db",configSha256:$configSha,backupConfigSha256:$backupConfigSha,artifact:$artifact,
      revision:$revision,import:{status:"complete"},readChecks:{status:"passed"},
      writesMayHaveOpened:false,probeRecipeId:null,restoreIdentity:$identity}
  ' > "$FIXTURE_ROOT/restore-state.json"
  jq -n --arg ns recipe-db --slurpfile state "$FIXTURE_ROOT/restore-state.json" '
    {metadata:{namespace:$ns,labels:{"app.kubernetes.io/part-of":"recipe-db"}},
      data:{"restore-state.json":($state[0]|tojson)}}
  ' > "$FIXTURE_ROOT/restore-configmap.json"
  jq -n --arg uid "$lease_uid" --arg holder "$holder" --arg artifact "$ARTIFACT" '{
    metadata:{name:"recipe-db-deploy",uid:$uid,resourceVersion:"42",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/phase":"awaiting-signoff",
        "recipe-db/operation":"restore","recipe-db/release":$artifact}},
    spec:{holderIdentity:$holder}
  }' > "$FIXTURE_ROOT/lease.json"
  jq -n '{items:[{metadata:{name:"graphql"},
    spec:{template:{spec:{containers:[{name:"graphql",
      env:[{name:"MODE",value:"backup"}]}]}}}}]}' > "$FIXTURE_ROOT/deployments.json"
fi
if [[ ${LEASE_UID_DRIFT:-false} == true ]]; then
  jq '.metadata.uid="replacement-lease-uid"' "$FIXTURE_ROOT/lease.json" \
    > "$FIXTURE_ROOT/lease.next"
  mv "$FIXTURE_ROOT/lease.next" "$FIXTURE_ROOT/lease.json"
fi
work="$FIXTURE_ROOT/work"
command=${PIPELINE_ACTION:-restore-backup-capture}
target=pi
cluster=recipe-db-pi
context=explicit-pi
namespace=recipe-db
timeout=10
restore_backup_snapshot="$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/snapshot"
restore_backup_holder=restore-holder
restore_backup_restore_id=backup-20261101120000-1
restore_backup_state_directory="$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1"
root=$PWD
connect() { printf 'connect\n' >> "$MOCK_LOG.pipeline"; }
recovery_command_acquire() {
  printf 'claim\n' >> "$MOCK_LOG.pipeline"
  if [[ ${CLAIM_BUSY:-false} == true ]]; then
    printf 'claim-busy\n' >> "$MOCK_LOG.pipeline"
    return 1
  fi
}
kube() {
  case "$*" in
    "get configmap recipe-db-restore -o json") cat "$FIXTURE_ROOT/restore-configmap.json" ;;
    "get deployments -o json") cat "$FIXTURE_ROOT/deployments.json" ;;
    *) printf 'unexpected kube command: %s\n' "$*" >&2; return 1 ;;
  esac
}
pull_release() { revision=$MOCK_REVISION; }
render() { :; }
restore_backup_verify_inputs() { printf 'verify-inputs\n' >> "$MOCK_LOG.pipeline"; }
recovery_identity() {
  jq -cn --arg config "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" \
    '{configSha256:$config,namespace:"recipe-db",pvcs:[]}' > "$work/reset-identity.json"
}
cluster_operation_lock_status() { cat "$FIXTURE_ROOT/lease.json"; }
cluster_operation_lock_kubectl() {
  case "$1" in
    get) cat "$FIXTURE_ROOT/lease.json" ;;
    replace)
      cp "${@: -1}" "$FIXTURE_ROOT/lease.json"
      printf 'lease:%s\n' "$(jq -r '.metadata.annotations["recipe-db/phase"]' "$FIXTURE_ROOT/lease.json")" \
        >> "$MOCK_LOG.pipeline"
      ;;
    *) return 1 ;;
  esac
}
production_storage_preflight() {
  [[ $cluster_operation_lock_holder == restore-holder ]]
  printf 'storage-preflight\n' >> "$MOCK_LOG.pipeline"
}
restore_backup_verify_pending_reads() {
  printf 'reads:%s\n' "$2" >> "$MOCK_LOG.pipeline"
  [[ ${READS_FAIL:-false} != true ]]
}
restore_backup_check_timer() {
  printf 'check-timer\n' >> "$MOCK_LOG.pipeline"
  [[ ${TIMER_ENABLED:-false} != true ]]
}
restore_backup_prepare_snapshot() {
  backup_id=backup-20261101120100-2
  snapshot=$restore_backup_snapshot
  restore_backup_started=true
  mkdir -p "$(dirname "$snapshot")"
  mkdir -m 700 "$snapshot"
  printf 'prepare\n' >> "$MOCK_LOG.pipeline"
}
backup_reblock_graphql() { printf 'reblock-graphql\n' >> "$MOCK_LOG.pipeline"; }
backup_establish_barrier() {
  cluster_operation_lock_update barrier
  printf 'barrier\n' >> "$MOCK_LOG.pipeline"
}
backup_start_modes() { printf 'backup-modes\n' >> "$MOCK_LOG.pipeline"; }
backup_state_write() { printf 'backup-state:%s:%s\n' "$1" "$2" >> "$MOCK_LOG.pipeline"; }
backup_cleanup_job() {
  cluster_operation_lock_update cleanup
  printf 'cleanup\n' >> "$MOCK_LOG.pipeline"
}
backup_scale_zero() { printf 'scale-zero\n' >> "$MOCK_LOG.pipeline"; }
backup_capture() {
  local name
  for name in recipes images tags; do cluster_operation_lock_update "copy-$name"; done
  printf 'capture:%s:%s\n' "$1" "$snapshot" >> "$MOCK_LOG.pipeline"
}
backup_write_manifest() { printf 'manifest\n' >> "$MOCK_LOG.pipeline"; }
restore_backup_publish_snapshot() {
  printf 'publish:%s:%s\n' "$1" "$snapshot" >> "$MOCK_LOG.pipeline"
  [[ ${PUBLISH_FAIL:-false} != true ]]
}
restore_backup_verify_upload() { printf 'verified-upload:%s\n' "$1" >> "$MOCK_LOG.pipeline"; }
backup_restore_maintenance() {
  cluster_operation_lock_update projection-refresh
  printf 'restore-maintenance\n' >> "$MOCK_LOG.pipeline"
}
restore_backup_record_completion() {
  printf 'completion\n' >> "$MOCK_LOG.pipeline"
  restore_backup_progress complete maintenance "$backup_id"
}
pipeline_cleanup() {
  local result=$?
  if [[ $result -ne 0 && $restore_backup_started == true ]]; then
    if [[ $command == restore-backup-maintenance-resume &&
      $restore_backup_current_graphql_mode == maintenance ]]; then
      backup_reblock_graphql || true
    fi
    restore_backup_record_failure || true
  fi
}
trap pipeline_cleanup EXIT
if [[ $command == restore-backup-capture ]]; then
  restore_backup_capture "$FIXTURE_ROOT/etc/backup-values.yaml" "$FIXTURE_ROOT/uploader.json" \
    "$restore_backup_state_directory" "$restore_backup_restore_id" "$restore_backup_holder" \
    lease-uid-1 "CAPTURE-RESTORE-backup-20261101120000-1-restore-holder"
else
  restore_backup_maintenance_resume "$FIXTURE_ROOT/etc/backup-values.yaml" "$FIXTURE_ROOT/uploader.json" \
    "$restore_backup_state_directory" "$restore_backup_restore_id" "$restore_backup_holder" \
    lease-uid-1 "RESUME-MAINTENANCE-RESTORE-backup-20261101120000-1-restore-holder"
fi
EOF
  chmod 700 capture-pipeline.sh
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" bash capture-pipeline.sh
  [ "$status" -eq 0 ]
  grep -Fxq 'claim' "$MOCK_LOG.pipeline"
  grep -Fxq 'verify-inputs' "$MOCK_LOG.pipeline"
  grep -Fxq 'storage-preflight' "$MOCK_LOG.pipeline"
  [ "$(grep -n 'lease:restore-backup-capturing' "$MOCK_LOG.pipeline" | cut -d: -f1)" -lt \
    "$(grep -n 'check-timer' "$MOCK_LOG.pipeline" | cut -d: -f1)" ]
  [ "$(grep -n 'check-timer' "$MOCK_LOG.pipeline" | cut -d: -f1)" -lt \
    "$(grep -n '^barrier$' "$MOCK_LOG.pipeline" | cut -d: -f1)" ]
  [ "$(grep -n '^claim$' "$MOCK_LOG.pipeline" | cut -d: -f1)" -lt \
    "$(grep -n '^storage-preflight$' "$MOCK_LOG.pipeline" | cut -d: -f1)" ]
  grep -Fxq "capture:pending:$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/snapshot" \
    "$MOCK_LOG.pipeline"
  grep -Fxq "publish:$FIXTURE_ROOT/uploader.json:$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/snapshot" \
    "$MOCK_LOG.pipeline"
  [ "$(grep -n 'verified-upload:' "$MOCK_LOG.pipeline" | cut -d: -f1)" -lt \
    "$(grep -n 'restore-maintenance' "$MOCK_LOG.pipeline" | cut -d: -f1)" ]
  [ "$(grep -n 'completion' "$MOCK_LOG.pipeline" | cut -d: -f1)" -lt \
    "$(grep -n 'lease:awaiting-signoff' "$MOCK_LOG.pipeline" | cut -d: -f1)" ]
  jq -e '.status == "complete" and .phase == "maintenance"
    and .backupId == "backup-20261101120100-2"' \
    "$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/restore-capture-state.json"

  : > "$MOCK_LOG.pipeline"
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" REUSE_STATE=true CLAIM_BUSY=true \
    bash capture-pipeline.sh
  [ "$status" -ne 0 ]
  grep -Fxq 'claim-busy' "$MOCK_LOG.pipeline"
  run grep -Eq '^storage-preflight$|^capture:' "$MOCK_LOG.pipeline"
  [ "$status" -ne 0 ]

  : > "$MOCK_LOG.pipeline"
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" REUSE_STATE=true LEASE_UID_DRIFT=true \
    bash capture-pipeline.sh
  [ "$status" -ne 0 ]
  [[ $output == *"exact pending restore Lease is missing or changed"* ]]
  run grep -Eq '^storage-preflight$|^capture:' "$MOCK_LOG.pipeline"
  [ "$status" -ne 0 ]

  : > "$MOCK_LOG.pipeline"
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" BACKUP_REFERENCE_DRIFT=true \
    bash capture-pipeline.sh
  [ "$status" -ne 0 ]
  [[ $output == *"backup release inputs do not match the retained restored release"* ]]
  run grep -Eq '^storage-preflight$|^check-timer$|^capture:' "$MOCK_LOG.pipeline"
  [ "$status" -ne 0 ]

  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" bash capture-pipeline.sh
  [ "$status" -eq 0 ]
  : > "$MOCK_LOG.pipeline"
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" REUSE_STATE=true \
    PIPELINE_ACTION=restore-backup-maintenance-resume READS_FAIL=true bash capture-pipeline.sh
  [ "$status" -ne 0 ]
  grep -Fxq 'reblock-graphql' "$MOCK_LOG.pipeline"
  jq -e '.status == "maintenance-failed" and .phase == "maintenance-pending"' \
    "$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/restore-capture-state.json"
  jq -e '.metadata.annotations["recipe-db/phase"] == "restore-backup-maintenance-failed"' \
    "$FIXTURE_ROOT/lease.json"

  : > "$MOCK_LOG.pipeline"
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" TIMER_ENABLED=true \
    bash capture-pipeline.sh
  [ "$status" -ne 0 ]
  grep -Fxq 'check-timer' "$MOCK_LOG.pipeline"
  run grep -Eq '^barrier$|^capture:' "$MOCK_LOG.pipeline"
  [ "$status" -ne 0 ]

  : > "$MOCK_LOG.pipeline"
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" PUBLISH_FAIL=true bash capture-pipeline.sh
  [ "$status" -ne 0 ]
  [[ $output == *"upload failed; retain the exact Lease and snapshot"* ]]
  [ -d "$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/snapshot" ]
  run grep -Eq 'verified-upload:|restore-maintenance|completion|lease:awaiting-signoff' \
    "$MOCK_LOG.pipeline"
  [ "$status" -ne 0 ]

  : > "$MOCK_LOG.pipeline"
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" REUSE_STATE=true bash capture-pipeline.sh
  [ "$status" -ne 0 ]
  [[ $output == *"progress or retained Lease phase does not permit this action"* ]]
  run grep -q '^capture:' "$MOCK_LOG.pipeline"
  [ "$status" -ne 0 ]
}

@test "restore backup failure advances progress and exact Lease phase" {
  cp "$BATS_TEST_DIRNAME/../lib/production-restore-backup.sh" .scripts/lib/
  source .scripts/lib/production-restore-backup.sh

  work="$FIXTURE_ROOT/work"
  mkdir -p "$work"
  restore_backup_state_path="$FIXTURE_ROOT/restore-capture-state.json"
  restore_backup_started=true
  restore_backup_current_phase=awaiting-signoff
  restore_backup_holder=restore-holder
  restore_backup_lease_uid="lease-uid-1"
  restore_backup_artifact=ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  cluster_operation_lock_current_phase=awaiting-signoff
  command=restore-backup-capture
  jq -n '{
    format:"recipe-db-restore-capture",formatVersion:1,
    restoreBackupId:"backup-20261101120000-1",restoreHolder:"restore-holder",
    restoreLeaseUid:"lease-uid-1",status:"complete",phase:"maintenance",
    backupId:"backup-20261101120100-2"
  }' > "$restore_backup_state_path"
  jq -n --arg artifact "$restore_backup_artifact" '{
    metadata:{uid:"lease-uid-1",resourceVersion:"42",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/phase":"awaiting-signoff",
        "recipe-db/operation":"restore","recipe-db/release":$artifact}},
    spec:{holderIdentity:"restore-holder"}
  }' > "$FIXTURE_ROOT/lease.json"
  cluster_operation_lock_status() { cat "$FIXTURE_ROOT/lease.json"; }
  cluster_operation_lock_kubectl() {
    cp "${@: -1}" "$FIXTURE_ROOT/lease.json"
  }

  restore_backup_record_cleanup_failure 1
  jq -e '.status == "maintenance-failed" and .phase == "maintenance-pending"' \
    "$restore_backup_state_path"
  jq -e '.metadata.annotations["recipe-db/phase"] == "restore-backup-maintenance-failed"' \
    "$FIXTURE_ROOT/lease.json"
}

@test "recovery command release failure alone leaves verified restore ownership unchanged" {
  cp "$BATS_TEST_DIRNAME/../lib/production-restore-backup.sh" .scripts/lib/
  source .scripts/lib/production-restore-backup.sh

  work="$FIXTURE_ROOT/work"
  mkdir -p "$work"
  restore_backup_state_path="$FIXTURE_ROOT/restore-capture-state.json"
  restore_backup_started=true
  restore_backup_current_phase=awaiting-signoff
  restore_backup_holder=restore-holder
  restore_backup_lease_uid="lease-uid-1"
  restore_backup_artifact=ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  cluster_operation_lock_current_phase=awaiting-signoff
  command=restore-backup-capture
  jq -n '{
    format:"recipe-db-restore-capture",formatVersion:1,
    restoreBackupId:"backup-20261101120000-1",restoreHolder:"restore-holder",
    restoreLeaseUid:"lease-uid-1",status:"complete",phase:"maintenance",
    backupId:"backup-20261101120100-2"
  }' > "$restore_backup_state_path"
  jq -n --arg artifact "$restore_backup_artifact" '{
    metadata:{uid:"lease-uid-1",resourceVersion:"42",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/phase":"awaiting-signoff",
        "recipe-db/operation":"restore","recipe-db/release":$artifact}},
    spec:{holderIdentity:"restore-holder"}
  }' > "$FIXTURE_ROOT/lease.json"
  recovery_command_release() { return 1; }
  cluster_operation_lock_status() { cat "$FIXTURE_ROOT/lease.json"; }
  cluster_operation_lock_kubectl() {
    cp "${@: -1}" "$FIXTURE_ROOT/lease.json"
  }

  restore_backup_record_cleanup_failure 0
  run recovery_command_release
  [ "$status" -ne 0 ]
  jq -e '.status == "complete" and .phase == "maintenance"' "$restore_backup_state_path"
  jq -e '.metadata.annotations["recipe-db/phase"] == "awaiting-signoff"' \
    "$FIXTURE_ROOT/lease.json"
}

@test "restore-owned retry and resume retain the exact uploaded snapshot" {
  cp "$BATS_TEST_DIRNAME/../lib/production-restore-backup.sh" .scripts/lib/
  mkdir -p "$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/snapshot"
  chmod 700 "$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/snapshot"
  printf '{"stateDirectory":"%s"}\n' "$FIXTURE_ROOT/capture-work" > "$FIXTURE_ROOT/uploader.json"
  cat > "$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/restore-capture-state.json" << 'EOF'
{"format":"recipe-db-restore-capture","formatVersion":1,"restoreBackupId":"backup-20261101120000-1","restoreHolder":"restore-holder","restoreLeaseUid":"lease-uid-1","status":"in-progress","phase":"capture"}
EOF
  cat > "$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/snapshot/backup-state.json" << 'EOF'
{"backupId":"backup-20261101120100-2","status":"backup-mode","phase":"upload-pending","restoreOperation":{"backupId":"backup-20261101120000-1","holder":"restore-holder","leaseUid":"lease-uid-1"}}
EOF
  cat > retry-pipeline.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source .scripts/lib/production-restore-backup.sh
restore_backup_snapshot="$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/snapshot"
restore_backup_state_directory="$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1"
restore_backup_state_path="$restore_backup_state_directory/restore-capture-state.json"
restore_backup_holder=restore-holder
restore_backup_current_graphql_mode=maintenance
restore_backup_current_phase=restore-backup-maintenance-pending
command=restore-backup-upload-retry
restore_backup_load_operation() {
  if [[ $command == restore-backup-upload-retry ]]; then
    restore_backup_expected_phase=$(jq -er .phase "$restore_backup_state_directory/restore-capture-state.json")
    restore_backup_current_phase=copy-recipes
    restore_backup_phase_is_allowed "$command" "$restore_backup_expected_phase" \
      "$restore_backup_current_phase" || return 1
  fi
  printf 'load\n' >> "$MOCK_LOG.pipeline"
}
backup_load_state() {
  snapshot=$1
  backup_id=$(jq -er .backupId "$snapshot/backup-state.json")
  printf 'state:%s\n' "$snapshot" >> "$MOCK_LOG.pipeline"
}
restore_backup_progress() { printf 'progress:%s:%s:%s\n' "$1" "$2" "$3" >> "$MOCK_LOG.pipeline"; }
restore_backup_set_lease_phase() { printf 'lease:%s\n' "$1" >> "$MOCK_LOG.pipeline"; }
restore_backup_publish_snapshot() { printf 'publish:%s\n' "$snapshot" >> "$MOCK_LOG.pipeline"; }
restore_backup_verify_upload() { printf 'verify-upload:%s:%s\n' "$1" "$backup_id" >> "$MOCK_LOG.pipeline"; }
restore_backup_record_completion() { printf 'completion:%s\n' "$1" >> "$MOCK_LOG.pipeline"; }
production_fail() { printf 'production: %s\n' "$*" >&2; exit 1; }
restore_backup_upload_retry "$FIXTURE_ROOT/config.json" "$FIXTURE_ROOT/uploader.json" \
  "$restore_backup_state_directory" backup-20261101120000-1 restore-holder lease-uid-1 \
  "RETRY-UPLOAD-RESTORE-backup-20261101120000-1-restore-holder"
EOF
  chmod 700 retry-pipeline.sh
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" bash retry-pipeline.sh
  [ "$status" -eq 0 ]
  grep -Fxq "publish:$FIXTURE_ROOT/capture-work/restore-captures/backup-20261101120000-1/snapshot" \
    "$MOCK_LOG.pipeline"
  run grep -Eq '^capture:|^restore-maintenance' "$MOCK_LOG.pipeline"
  [ "$status" -ne 0 ]

  : > "$MOCK_LOG.pipeline"
  cat >> retry-pipeline.sh << 'EOF'
command=restore-backup-maintenance-resume
jq --arg id "${MOCK_RECORDED_BACKUP_ID:-backup-20261101120100-2}" \
  '.backupId=$id' "$restore_backup_state_path" > "$restore_backup_state_path.next"
mv "$restore_backup_state_path.next" "$restore_backup_state_path"
restore_backup_maintenance_resume "$FIXTURE_ROOT/config.json" "$FIXTURE_ROOT/uploader.json" \
  "$restore_backup_state_directory" backup-20261101120000-1 restore-holder lease-uid-1 \
  "RESUME-MAINTENANCE-RESTORE-backup-20261101120000-1-restore-holder"
EOF
  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" bash retry-pipeline.sh
  [ "$status" -eq 0 ]
  [ "$(grep -n 'completion:' "$MOCK_LOG.pipeline" | cut -d: -f1)" -lt \
    "$(grep -n 'lease:awaiting-signoff' "$MOCK_LOG.pipeline" | cut -d: -f1)" ]

  run env FIXTURE_ROOT="$FIXTURE_ROOT" MOCK_LOG="$MOCK_LOG" \
    MOCK_RECORDED_BACKUP_ID=backup-20261101120100-3 bash retry-pipeline.sh
  [ "$status" -ne 0 ]
  [[ $output == *"maintenance resume requires the exact recorded snapshot"* ]]
}

@test "restore verification retains and cleans up both port-forward processes" {
  export MOCK_RESTORE=true
  source .scripts/lib/production-restore.sh
  work=$FIXTURE_ROOT
  namespace='recipe-db'
  context=k3d-recipe-db-rehearsal
  timeout=10
  restore_forward deployment/traefik 3000 "$FIXTURE_ROOT/graphql-forward.log" || {
    cat "$FIXTURE_ROOT/graphql-forward.log"
    return 1
  }
  graphql_pid=$restore_forward_pid
  [ "$restore_graphql_port" = 18081 ]
  restore_forward service/browse 3000 "$FIXTURE_ROOT/browse-forward.log"
  browse_pid=$restore_browse_pid
  [ "$restore_browse_port" = 18082 ]
  [ -n "$graphql_pid" ]
  [ -n "$browse_pid" ]

  kill "$graphql_pid" "$browse_pid"
  wait "$graphql_pid" "$browse_pid" 2> /dev/null || true
  run kill -0 "$graphql_pid"
  [ "$status" -ne 0 ]
  run kill -0 "$browse_pid"
  [ "$status" -ne 0 ]
}

@test "pending restore can select another backup through preview reset and recovery restore" {
  restore_real_package_fixture
  set_value '.timeoutSeconds=8'
  run_restore
  [ "$status" -eq 0 ]
  local expected_backup_config
  expected_backup_config=$(jq -er .backupConfigSha256 "$RESTORE_STATE/restore-state.json")
  local pending_guard="recovery-guard-$RESTORE_ID"
  jq -e --arg name "$pending_guard" \
    'any(.items[]; .kind == "Job" and .metadata.name == $name)' "$MOCK_LOG.restore-guard"
  jq -e '.restoreGuardInventory | type == "object"' "$RESTORE_STATE/restore-state.json"
  jq -e --arg name "$pending_guard" '
    .items[] | select(.kind == "Job" and .metadata.name == $name)
    | .metadata += {uid:"pending-guard-job-uid",resourceVersion:"1"}
    | .status={active:1}' "$MOCK_LOG.restore-guard" > "$MOCK_LOG.expired-guard-job"
  jq -e --arg name "$pending_guard" '
    .items[] | select(.kind == "ConfigMap" and .metadata.name == $name)
    | .data.ready="true" | .data.expired="true"' \
    "$MOCK_LOG.restore-guard" > "$MOCK_LOG.expired-guard-configmap"
  jq -n --slurpfile job "$MOCK_LOG.expired-guard-job" '
    ($job[0]) as $job |
    {apiVersion:"v1",kind:"Pod",
      metadata:{name:($job.metadata.name + "-pod"),namespace:$job.metadata.namespace,
        uid:"pending-guard-pod-uid",labels:$job.spec.template.metadata.labels,
        ownerReferences:[{apiVersion:"batch/v1",kind:"Job",name:$job.metadata.name,
          uid:$job.metadata.uid,controller:true}]},
      spec:$job.spec.template.spec,status:{phase:"Running"}}' \
    > "$MOCK_LOG.expired-guard-pod"
  jq -er '.items[] | select(.kind == "Secret").stringData.routes | @base64d' \
    "$MOCK_LOG.restore-guard" > "$MOCK_LOG.restore-routes"
  jq '.items |= map(.spec.replicas=0 | .status.replicas=0 | .status.readyReplicas=0)' \
    "$MOCK_LOG.restore-deployments" > "$MOCK_LOG.restore-deployments.next"
  mv "$MOCK_LOG.restore-deployments.next" "$MOCK_LOG.restore-deployments"
  local alternate_id=backup-20261101123456-43
  restore_alternate_real_package "$alternate_id" "2026-11-01T12:34:56Z"
  run bash .scripts/production-k3d.sh recovery-plan "$VALUES" "$RESTORE_ALT_MANIFEST" \
    "$RESTORE_ALT_ARCHIVE" "$alternate_id" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  [[ $output == *"preview saved"* ]]
  jq -e --arg id "$alternate_id" '.backupId == $id and .status == "reset-planned"
    and .reset.pendingRestore == true
    and .reset.pendingRestoreState.status == "awaiting-signoff"' \
    "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.reopening" ]
  [ -e "$MOCK_LOG.expired-guard-job" ]
  run bash .scripts/production-k3d.sh recovery-reset "$VALUES" "$RESTORE_ALT_MANIFEST" \
    "$RESTORE_ALT_ARCHIVE" "$alternate_id" "$RESTORE_STATE" "RESET-$alternate_id"
  [ "$status" -eq 0 ]
  [[ $output == *"reset complete"* ]]
  [ ! -e "$MOCK_LOG.expired-guard-job" ]
  grep -Fq "delete job $pending_guard --preconditions=uid=pending-guard-job-uid" "$MOCK_LOG"
  for resource in configmap role rolebinding secret serviceaccount; do
    grep -Fq "delete $resource $pending_guard --preconditions=uid=expired-$resource-uid" "$MOCK_LOG"
  done
  local pending_guard_removal reset_wipe
  pending_guard_removal=$(awk -v guard="$pending_guard" \
    '$0 ~ ("delete job " guard " --preconditions=uid=pending-guard-job-uid") {
      print NR; exit
    }' "$MOCK_LOG")
  reset_wipe=$(awk -v after="$pending_guard_removal" \
    'NR > after {
      if (index($0, "exec restore-volume-") && index($0, "find /data -mindepth 1 -maxdepth 1 -exec rm -rf")) {
        print NR; exit
      }
    }' "$MOCK_LOG")
  [ -n "$pending_guard_removal" ]
  [ -n "$reset_wipe" ]
  [ "$pending_guard_removal" -lt "$reset_wipe" ]
  jq -e --arg id "$alternate_id" '.backupId == $id and .status == "reset-ready"
    and .reset.previousRestore.status == "awaiting-signoff"
    and .reset.pendingRestore == null' "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.reopening" ]
  jq '.writesMayHaveOpened=true | .publicRoutesMayBeOpen=true | del(.backupConfigSha256)' \
    "$RESTORE_STATE/restore-state.json" > "$RESTORE_STATE/restore-state.next"
  mv "$RESTORE_STATE/restore-state.next" "$RESTORE_STATE/restore-state.json"
  jq '.data["restore-state.json"] |=
    (fromjson | .writesMayHaveOpened=true | .publicRoutesMayBeOpen=true | del(.backupConfigSha256) | tojson)' \
    "$MOCK_LOG.cluster-restore-state" > "$MOCK_LOG.cluster-restore-state.next"
  mv "$MOCK_LOG.cluster-restore-state.next" "$MOCK_LOG.cluster-restore-state"
  export MOCK_RESTORE_READ_FAIL=true
  run bash .scripts/production-k3d.sh recovery-restore "$VALUES" "$RESTORE_STATE" \
    "$RESTORE_ALT_MANIFEST" "$RESTORE_ALT_ARCHIVE" "$alternate_id" "RESTORE-$alternate_id"
  [ "$status" -ne 0 ]
  jq -e --arg id "$alternate_id" --arg config "$expected_backup_config" \
    '.backupId == $id and .status == "recovery-required"
    and .backupConfigSha256 == $config
    and .phase == "verifying-reads" and .import.status == "complete"
    and .readChecks.status == "failed" and .writesMayHaveOpened == false
    and .publicRoutesMayBeOpen == false
    and .reset.exposureHistory[-1].writesMayHaveOpened == true
    and .reset.exposureHistory[-1].publicRoutesMayBeOpen == true' \
    "$RESTORE_STATE/restore-state.json"
  jq -e 'all(.items[]; (.spec.replicas // 0) == (.status.readyReplicas // 0))' \
    "$MOCK_LOG.restore-deployments"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.reopening" ]
  local imports_before
  imports_before=$(grep -c -- 'exec -i restore-volume-.*tar -xpkf -' "$MOCK_LOG")
  unset MOCK_RESTORE_READ_FAIL
  run bash .scripts/production-k3d.sh restore-recheck "$VALUES" "$RESTORE_STATE" \
    "RECHECK-RESTORE-$alternate_id"
  [ "$status" -eq 0 ]
  jq -e '.status == "awaiting-signoff" and .readChecks.status == "passed"
    and any(.readChecks.attempts[]; .status == "failed")' "$RESTORE_STATE/restore-state.json"
  [ "$(grep -c -- 'exec -i restore-volume-.*tar -xpkf -' "$MOCK_LOG")" -eq "$imports_before" ]
  local holder
  holder=$(jq -er .holder "$RESTORE_STATE/restore-state.json")
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$alternate_id-$holder"
  [ "$status" -eq 0 ]
  jq -e '.status == "succeeded" and .writesMayHaveOpened == true' \
    "$RESTORE_STATE/restore-state.json"
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "restore SIGTERM during read-only verification retains maintenance and recovery state" {
  restore_fixture
  export MOCK_RESTORE_PAUSE_READS=true
  bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" "$RESTORE_ARCHIVE" \
    "$RESTORE_ID" "$RESTORE_STATE" "RESTORE-$RESTORE_ID" > term-output 2>&1 &
  local pid=$! deadline=$((SECONDS + 20)) result
  while [[ ! -e $MOCK_LOG.reads-paused ]]; do
    if ! kill -0 "$pid" 2> /dev/null || ((SECONDS >= deadline)); then
      kill "$pid" 2> /dev/null || true
      wait "$pid" 2> /dev/null || true
      cat term-output
      return 1
    fi
    sleep 0.1
  done
  jq -e '.http.routers["restore-public-barrier"].entrypoints == ["web"]
    and .http.routers["graphql-internal"].entrypoints == ["rest-internal"]' "$MOCK_LOG.restore-routes"
  kill -TERM "$pid"
  if wait "$pid"; then result=0; else result=$?; fi
  [ "$result" -eq 143 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-reads"
    and .import.status == "complete" and .readChecks.status == "failed"
    and .writesMayHaveOpened == false' "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"].entrypoints == ["web"]' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance"))' \
    "$MOCK_LOG.restore-deployments"
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
}
