#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "candidate staging refuses cluster mutation when Pi credential retention fails" {
  prepare_captured_release
  local python
  python=$(command -v python3)
  cat > bin/python3 << EOF
#!/bin/sh
if [ "\${2:-}" = --file-request ]; then
  echo 'Pi credential write failed' >&2
  exit 1
fi
exec "$python" "\$@"
EOF
  chmod +x bin/python3
  export RECIPE_DB_RELEASE_SOCKET=/tmp/unused-release-test-socket
  : > "$MOCK_LOG"
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -ne 0 ]
  [[ $output == *"could not retain previous-release credentials on the Pi"* ]]
  jq -e '.status == "captured" and .phase == "captured"' "$STATE/backup-state.json" > /dev/null
  run ! grep -Eq ' apply | patch | scale | delete | create ' "$MOCK_LOG"
}

@test "release preflight validates mapped inputs without mutating the cluster" {
  local canonical="$FIXTURE_ROOT/canonical-values.yaml"
  jq '.secrets |= with_entries(.value = ("/etc/recipe-db/application-inputs/"+.key))' \
    "$VALUES" > "$canonical"
  jq '.secrets | to_entries | map({key:("/etc/recipe-db/application-inputs/"+.key),value:.value}) | from_entries' \
    "$VALUES" > "$FIXTURE_ROOT/input-map.json"
  export RECIPE_DB_RELEASE_INPUTS="$FIXTURE_ROOT/input-map.json"
  run bash .scripts/production-k3d.sh release-preflight "$canonical" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run ! grep -Eq ' apply | patch | scale | delete | create ' "$MOCK_LOG"
  printf 'invalid JSON\n' > "$FIXTURE_ROOT/auth-accounts.json"
  : > "$MOCK_LOG"
  run bash .scripts/production-k3d.sh release-preflight "$canonical" "$ARTIFACT"
  [ "$status" -ne 0 ]
  run ! grep -q '^kubectl ' "$MOCK_LOG"
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

@test "failed staging retains credentials without invalidating the captured upload inventory" {
  prepare_captured_release
  export MOCK_FOREIGN_HELM=true
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -ne 0 ]
  [[ $output == *"unowned Traefik HelmChartConfig"* ]]
  jq -e '.status == "captured" and .phase == "captured"' "$STATE/backup-state.json" > /dev/null
  [ -f "$STATE.previous-runtime-secret.json" ]
  [ "$(stat -c %a "$STATE.previous-runtime-secret.json")" = 600 ]
  [ ! -e "$STATE/previous-runtime-secret.json" ]
  prepare_recovery_package
  [ -s "$PACKAGE_MANIFEST" ]
  [ -s "$PACKAGE_ARCHIVE" ]
  export MOCK_FOREIGN_HELM=false
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$STATE" "$HOLDER" "EXIT-$HOLDER"
  [ "$status" -eq 0 ]
  [ ! -e "$STATE.previous-runtime-secret.json" ]
}

@test "staging refuses unsafe credential parents and links without following a predictable temporary path" {
  local parent parent_mode
  prepare_captured_release
  parent=$(dirname "$STATE")
  parent_mode=$(stat -c %a "$parent")
  printf 'unchanged' > "$FIXTURE_ROOT/credential-victim"
  ln -s "$FIXTURE_ROOT/credential-victim" "$STATE.previous-runtime-secret.next"
  export MOCK_FOREIGN_HELM=true
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -ne 0 ]
  [ "$(cat "$FIXTURE_ROOT/credential-victim")" = unchanged ]
  [ -f "$STATE.previous-runtime-secret.json" ]
  rm "$STATE.previous-runtime-secret.json"
  ln -s "$FIXTURE_ROOT/credential-victim" "$STATE.previous-runtime-secret.json"
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -ne 0 ]
  [[ $output == *"securely retained previous-release runtime credentials"* ]]
  [ "$(cat "$FIXTURE_ROOT/credential-victim")" = unchanged ]
  rm "$STATE.previous-runtime-secret.json"
  chmod 777 "$parent"
  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  chmod "$parent_mode" "$parent"
  [ "$status" -ne 0 ]
  [[ $output == *"not writable by other users"* ]]
  [ ! -e "$STATE.previous-runtime-secret.json" ]
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
  [[ $output == *"previous release is not serving reads behind the GraphQL maintenance barrier"* ]]
  [ "$(jq -r '.status + "/" + .phase' "$STATE/backup-state.json")" = "captured/captured" ]
  run ! grep -q 'apply -f .*staged-application.yml' "$MOCK_LOG"
}

@test "candidate staging rejects a backend left in backup mode" {
  prepare_captured_release
  jq '(.items[] | select(.metadata.name == "recipes").spec.template.spec.containers[0].env) |=
    ((. // [] | map(select(.name != "MODE"))) + [{name:"MODE",value:"backup"}])' \
    "$MOCK_LOG.deployments" > "$MOCK_LOG.deployments.next"
  mv "$MOCK_LOG.deployments.next" "$MOCK_LOG.deployments"

  run bash .scripts/production-k3d.sh release-stage "$VALUES" "$STATE" "$CANDIDATE" \
    verified-upload "VERIFIED-$HOLDER-verified-upload"
  [ "$status" -ne 0 ]
  [[ $output == *"previous release is not serving reads behind the GraphQL maintenance barrier"* ]]
  [ "$(jq -r '.status + "/" + .phase' "$STATE/backup-state.json")" = "captured/captured" ]
  run ! grep -q 'apply -f .*staged-application.yml' "$MOCK_LOG"
}
