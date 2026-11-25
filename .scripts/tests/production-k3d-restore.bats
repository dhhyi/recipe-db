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
