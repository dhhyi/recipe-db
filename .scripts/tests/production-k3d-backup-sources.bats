#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

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
  run bash .scripts/production-k3d.sh --release-sources-from-git backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"snapshot path must be a new absolute directory"* ]]

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
    and all(.inventory[]; .storage.uid != null and (has("layout") | not))
  ' "$snapshot/manifest.json" > /dev/null
  jq -e '.stateVersion == 2 and .status == "captured" and .phase == "captured"' \
    "$snapshot/backup-state.json" > /dev/null
  jq -e --arg holder "$holder" '.spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "captured"' "$MOCK_LOG.lease" > /dev/null
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

@test "current tooling enters and captures backup from immutable older release sources" {
  export MOCK_BACKUP=true MOCK_RELEASE_LIFECYCLE=false MOCK_SOURCE_REVISION="$MOCK_REVISION"
  local snapshot="$FIXTURE_ROOT/backups/git-source"
  printf '*\n' > .gitignore
  printf 'new tooling input\n' > message-bus/nats.conf
  git add -f .gitignore message-bus/nats.conf
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Separate tooling inputs'

  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"metadata and templates must match"* ]]
  run bash .scripts/production-k3d.sh --release-sources-from-git backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh --release-sources-from-git backup-capture "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  jq -e --arg revision "$MOCK_SOURCE_REVISION" '.source.revision == $revision' "$snapshot/manifest.json"
}
