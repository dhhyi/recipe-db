#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup
load production-k3d-restore-setup

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

@test "pending restore backup reads use web for public images and still reject an empty thumbnail" {
  export MOCK_RESTORE_IMAGE=true
  restore_fixture
  sed -n '/^restore_backup_verify_pending_reads() {/,/^}/p' \
    .scripts/production-k3d.sh > pending-read-function.sh
  cat > .scripts/production-k3d.sh << 'EOF'
#!/usr/bin/env bash
cat "$FIXTURE_ROOT/pending-status.json"
EOF
  jq -n --arg id "$RESTORE_ID" '{
    savedProgress:{backupId:$id,status:"awaiting-signoff",phase:"pending-signoff",
      import:{status:"complete"},readChecks:{status:"passed"}},
    lease:{ownedByRestore:true,phase:"restore-backup-capture-failed"},
    observed:{graphql:{mode:"maintenance",maintenanceQuery:true},
      publicRoutes:{normalRoutesObserved:true}},
    savedStateMatchesCluster:true,writesMayHaveOpened:false
  }' > pending-status.json
  mv bin/kubectl bin/kubectl-base
  cat > bin/kubectl << 'EOF'
#!/usr/bin/env bash
if [[ $* == *"port-forward "*"deployment/traefik "* ]]; then
  printf '%s\n' "${*: -1}" > "$MOCK_LOG.traefik-target"
fi
exec "$FIXTURE_ROOT/bin/kubectl-base" "$@"
EOF
  mv bin/curl bin/curl-base
  cat > bin/curl << 'EOF'
#!/usr/bin/env bash
if [[ $* == *"/public/"* && $(cat "$MOCK_LOG.traefik-target") != :8000 ]]; then
  printf 'curl: (22) The requested URL returned error: 404\n' >&2
  exit 22
fi
exec "$FIXTURE_ROOT/bin/curl-base" "$@"
EOF
  chmod +x bin/kubectl bin/curl
  cat > pending-reads.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source .scripts/lib/production-restore.sh
source pending-read-function.sh
root=$FIXTURE_ROOT
work="$FIXTURE_ROOT/pending-read-work"
mkdir -p "$work"
touch "$work/kubeconfig"
yq -o=json "$VALUES" > "$work/config.json"
jq -n '{data:{"restore-state.json":"{}"}}' > "$work/restore-backup-configmap.json"
context=$(jq -r .context "$work/config.json")
namespace=$(jq -r .namespace "$work/config.json")
timeout=8
restore_backup_restore_id=$RESTORE_ID
trap 'for pid in "${restore_forward_pid:-}" "${restore_browse_pid:-}"; do
  if [[ -n $pid ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
done' EXIT
restore_backup_verify_pending_reads "$VALUES" restore-backup-capture-failed "$work/status.json"
EOF

  run bash pending-reads.sh
  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output"
    return 1
  }
  grep -Fq '/public/full.bin' "$MOCK_LOG"
  grep -Fq '/public/thumb.bin' "$MOCK_LOG"
  [ ! -e "$MOCK_LOG.restore-mutation-attempt" ]

  : > "$FIXTURE_ROOT/tar-data/images/public/thumb.bin"
  run bash pending-reads.sh
  [ "$status" -ne 0 ]
  [ ! -s "$FIXTURE_ROOT/pending-read-work/restore-image.bin" ]
  [ ! -e "$MOCK_LOG.traefik-forward-overlap" ]
  local pid name
  for name in traefik browse; do
    while IFS= read -r pid; do
      run kill -0 "$pid" 2> /dev/null
      [ "$status" -ne 0 ]
    done < "$MOCK_LOG.forward-pids-$name"
  done
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
