#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.scripts/lib/project-metadata.sh
source "$root/.scripts/lib/project-metadata.sh"
failure_reason=''

fail() {
  failure_reason=$*
  printf 'Cutover backup preparation: %s\n' "$*" >&2
  exit 1
}

[[ $# == 5 ]] || fail 'usage: mise run prepare-cutover-backup-k3d <verified-backup-manifest> <verified-backup-archive> <retrieval-receipt> <cutover-release@sha256:digest> <new-absolute-result-directory>'
input_manifest=$1
input_archive=$2
retrieval_receipt=$3
candidate=$4
result_directory=$5
[[ $candidate =~ ^ghcr\.io/dhhyi/recipe-db-releases@sha256:[a-f0-9]{64}$ ]] \
  || fail 'cutover release must be an immutable recipe-db release artifact'
[[ $input_manifest == /* && $input_archive == /* && $retrieval_receipt == /* ]] \
  || fail 'backup inputs and retrieval receipt must be absolute paths'
[[ $(dirname "$input_manifest") == "$(dirname "$input_archive")" ]] \
  || fail 'backup manifest and archive must be together in a private directory'
[[ $(basename "$input_manifest") == "$(basename "${input_archive%.tar.gz}").manifest.json" ]] \
  || fail 'backup manifest must be the sibling manifest for the supplied archive'

check_private_file() {
  local path=$1 mode parent
  [[ -f $path && ! -L $path && $(realpath -e "$path") == "$path" ]] \
    || fail "input is not a canonical regular file: $path"
  [[ $(stat -c %u "$path") == "$EUID" ]] || fail "input is not owned by the current operator: $path"
  mode=$(stat -c %a "$path")
  (((8#$mode & 077) == 0)) || fail "input is accessible by group or others: $path"
  parent=$(dirname "$path")
  [[ $(stat -c %u "$parent") == "$EUID" ]] || fail "input directory is not owned by the current operator: $parent"
  mode=$(stat -c %a "$parent")
  (((8#$mode & 077) == 0)) || fail "input directory is accessible by group or others: $parent"
}

check_private_file "$input_manifest"
check_private_file "$input_archive"
check_private_file "$retrieval_receipt"
[[ $result_directory == /* && ! -e $result_directory && ! -L $result_directory ]] \
  || fail 'result directory must be a new absolute path'
result_parent=$(dirname "$result_directory")
[[ $(basename "$result_directory") != . && $(basename "$result_directory") != .. &&
$(realpath -e "$result_parent") == "$result_parent" ]] \
  || fail 'result directory parent must exist without symlink traversal'
[[ $(stat -c %u "$result_parent") == "$EUID" ]] \
  || fail 'result directory parent is not owned by the current operator'
parent_mode=$(stat -c %a "$result_parent")
(((8#$parent_mode & 077) == 0)) || fail 'result directory parent is accessible by group or others'
case "$result_directory/" in
  "$root/"* | "$HOME/.config/"* | /var/lib/rancher/*)
    fail 'results must be outside the checkout, operator configuration and runtime storage'
    ;;
esac
for tool in git jq k3d kubectl mise openssl oras python3 realpath sha256sum stat tar yq; do
  command -v "$tool" > /dev/null || fail "required tool not found: $tool"
done

backup_id=$(jq -er '.backupId | select(type == "string" and test("^backup-[0-9]+-[0-9]+$"))' "$input_manifest") \
  || fail 'backup manifest has no valid previous-release backup identity'
source_release=$(jq -er '.source.artifact |
  select(test("^ghcr[.]io/dhhyi/recipe-db-releases@sha256:[a-f0-9]{64}$"))' "$input_manifest") \
  || fail 'backup manifest does not identify an immutable previous release'
source_revision=$(jq -er '.source.revision |
  select(type == "string" and test("^[a-f0-9]{40}$"))' "$input_manifest") \
  || fail 'backup manifest does not identify its source revision'
jq -e '.source.target == "pi" and .source.cluster == "recipe-db-pi"
  and .source.context == "recipe-db-pi" and .source.namespace == "recipe-db"' \
  "$input_manifest" > /dev/null || fail 'backup package is not from the documented Pi production target'
[[ $candidate != "$source_release" ]] || fail 'cutover release must differ from the previous release'
archive_sha=$(jq -er '.archive.sha256 | select(test("^[a-f0-9]{64}$"))' "$input_manifest") \
  || fail 'backup manifest has no valid archive digest'
captured_at=$(jq -er '.capturedAt | select(type == "string" and length > 0)' "$input_manifest") \
  || fail 'backup manifest has no capture timestamp'
jq -e --arg id "$backup_id" --arg manifest "$input_manifest" --arg archive "$input_archive" \
  --arg artifact "$source_release" --arg revision "$source_revision" --arg capturedAt "$captured_at" '
  .backupId == $id and .manifest == $manifest and .archive == $archive
  and .maintenanceOperation.backupId == $id
  and .maintenanceOperation.status == "captured"
  and .maintenanceOperation.phase == "captured"
  and (.maintenanceOperation.uploadStatus == "verified-upload"
    or .maintenanceOperation.uploadStatus == "verified-unchanged")
  and .maintenanceOperation.capturedAt == $capturedAt
  and .maintenanceOperation.source.artifact == $artifact
  and .maintenanceOperation.source.revision == $revision
' "$retrieval_receipt" > /dev/null || fail 'retrieval receipt does not verify this exact final backup'
git -C "$root" cat-file -e "$source_revision^{commit}" 2> /dev/null \
  || fail 'previous release revision is unavailable in this checkout; fetch it before preparation'

mkdir -m 700 -- "$result_directory"
private="$result_directory/.private"
mkdir -m 700 -- "$private"
mkdir -m 700 -- "$private/logs" "$private/inputs"
started_at=$(date -u +%FT%TZ)
phase=preflight
run_id=$(openssl rand -hex 8)
source_cluster="recipe-db-rehearsal-${run_id:0:10}-s"
target_cluster="recipe-db-rehearsal-${run_id:0:10}-t"
port_offset=$((16#${run_id:0:4} % 8000))
source_http_port=$((20000 + port_offset))
target_http_port=$((28000 + port_offset))
source_api_port=$((30000 + port_offset))
target_api_port=$((38000 + port_offset))
accounts_file="$private/auth-accounts.json"
source_values="$private/source-values.yaml"
target_values="$private/target-values.yaml"
source_state="$private/source-restore-state"
target_state="$private/target-restore-state"
snapshot="$private/cutover-snapshot"
package_directory="$result_directory/cutover-backup"
candidate_revision=''
cutover_backup_id=''
private_data_removed=false
input_copies_removed=false
source_cluster_created=false
target_cluster_created=false
source_cluster_attempted=false
target_cluster_attempted=false
source_cluster_deleted=false
target_cluster_deleted=false
success=false

write_result() {
  local status=failed finished
  finished=$(date -u +%FT%TZ)
  [[ $success != true ]] || status=passed
  jq -n --arg status "$status" --arg phase "$phase" --arg reason "$failure_reason" \
    --arg started "$started_at" --arg finished "$finished" --arg sourceBackupId "$backup_id" \
    --arg sourceRelease "$source_release" --arg sourceRevision "$source_revision" \
    --arg sourceArchiveSha256 "$archive_sha" --arg cutoverRelease "$candidate" \
    --arg cutoverRevision "$candidate_revision" --arg cutoverBackupId "$cutover_backup_id" \
    --arg sourceCluster "$source_cluster" --arg targetCluster "$target_cluster" \
    --argjson sourceClusterCreated "$source_cluster_created" \
    --argjson targetClusterCreated "$target_cluster_created" \
    --argjson sourceClusterAttempted "$source_cluster_attempted" \
    --argjson targetClusterAttempted "$target_cluster_attempted" \
    --argjson sourceClusterDeleted "$source_cluster_deleted" \
    --argjson targetClusterDeleted "$target_cluster_deleted" \
    --argjson privateDataRemoved "$private_data_removed" \
    --argjson inputCopiesRemoved "$input_copies_removed" '
    {schemaVersion:1,status:$status,phase:$phase,startedAt:$started,finishedAt:$finished,
      failureReason:(if $reason == "" then null else $reason end),
      previousBackup:{backupId:$sourceBackupId,sourceRelease:$sourceRelease,
        sourceRevision:$sourceRevision,archiveSha256:$sourceArchiveSha256},
      cutoverBackup:{backupId:(if $cutoverBackupId == "" then null else $cutoverBackupId end),
        release:$cutoverRelease,revision:(if $cutoverRevision == "" then null else $cutoverRevision end)},
      clusters:{source:{name:$sourceCluster,creationAttempted:$sourceClusterAttempted,
          created:$sourceClusterCreated,deleted:$sourceClusterDeleted},
        target:{name:$targetCluster,creationAttempted:$targetClusterAttempted,
          created:$targetClusterCreated,deleted:$targetClusterDeleted}},
      cleanup:{privateDataRemoved:$privateDataRemoved,inputCopiesRemoved:$inputCopiesRemoved}}
  ' > "$result_directory/result.json" || return 1
  chmod 600 "$result_directory/result.json" || return 1
}

on_exit() {
  local status=$?
  trap - EXIT
  if [[ $status != 0 && -z $failure_reason ]]; then
    failure_reason="command failed during $phase (exit $status); preserve both clusters and investigate manually"
  fi
  if [[ $success == true ]]; then
    if rm -rf -- "$private"; then
      private_data_removed=true
      input_copies_removed=true
    else
      success=false
      status=1
      failure_reason='temporary private input data could not be removed; retain the result and investigate'
    fi
  fi
  if ! write_result; then
    status=1
    success=false
    failure_reason='result.json could not be persisted; inspect the result directory and retained clusters'
    write_result || printf 'Cutover backup preparation: could not write result.json\n' >&2
  fi
  if [[ $status != 0 ]]; then
    printf 'Cutover backup preparation stopped in phase %s; do not delete clusters automatically.\n' "$phase" >&2
    printf 'Inspect %s/result.json and the private logs under %s/.private/logs.\n' \
      "$result_directory" "$result_directory" >&2
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'failure_reason="interrupted by SIGINT"; exit 130' INT
trap 'failure_reason="interrupted by SIGTERM"; exit 143' TERM

run_production() {
  local log=$1
  shift
  mise run --raw production-k3d --release-sources-from-git "$@" > "$log" 2>&1
}

run_cluster_lifecycle() {
  local log=$1
  shift
  mise run --raw production-k3d "$@" > "$log" 2>&1
}

manifest="$private/inputs/$(basename "$input_manifest")"
archive="$private/inputs/$(basename "$input_archive")"
receipt="$private/inputs/$(basename "$retrieval_receipt")"
[[ $manifest != "$archive" && $manifest != "$receipt" && $archive != "$receipt" ]] \
  || fail 'backup inputs and receipt must have distinct filenames'
cp -- "$input_manifest" "$manifest"
cp -- "$input_archive" "$archive"
cp -- "$retrieval_receipt" "$receipt"
chmod 600 "$private/inputs/"*

openssl rand -base64 32 | tr -d '\n' > "$private/owner-token"
jq -n --rawfile token "$private/owner-token" \
  '{anonymous:{role:"anonymous"},tokens:[{id:"cutover-local-owner",secret:($token|rtrimstr("\n")),role:"owner"}],googleAccounts:{}}' \
  > "$accounts_file"
chmod 600 "$private/owner-token" "$accounts_file"

write_values() {
  local cluster=$1 http_port=$2 api_port=$3 output=$4 context local_values
  context="k3d-$cluster"
  local_values=$(yq -o=json '.' "$root/deploy/local.yaml")
  yq -o=json '.' "$root/deploy/local.yaml" \
    | jq --arg cluster "$cluster" --arg context "$context" \
      --arg origin "http://127.0.0.1:$http_port" --argjson httpPort "$http_port" \
      --argjson apiPort "$api_port" --arg accounts "$accounts_file" --arg id "$run_id" \
      --argjson local "$local_values" '
      .target="local" | .cluster=$cluster | .context=$context | .origin=$origin
      | .httpPort=$httpPort | .apiPort=$apiPort | .storageClass="local-path"
      | .infrastructure=$local.infrastructure
      | .runtime=(.runtime | del(.googleOAuthClientId))
      | del(.piStorage,.https,.volumes.redis)
      | .secrets={"auth-accounts.json":$accounts}
      | .rehearsalId=$id
    ' | yq -P '.' > "$output"
  chmod 600 "$output"
}

write_values "$source_cluster" "$source_http_port" "$source_api_port" "$source_values"
write_values "$target_cluster" "$target_http_port" "$target_api_port" "$target_values"

mkdir -m 700 -- "$private/previous-source"
git -C "$root" archive "$source_revision" | tar -xf - -C "$private/previous-source"
application_project_metadata_to_jsonl "$private/previous-source" "$private/previous-projects.jsonl"
python3 "$root/.scripts/validate-backup-package.py" "$manifest" "$archive" \
  "$private/previous-validation" "$private/previous-projects.jsonl" "$backup_id" \
  > "$private/previous-validation.json"

oras manifest fetch "$candidate" > "$private/candidate-manifest.json"
candidate_revision=$(jq -er '.annotations["org.opencontainers.image.revision"] |
  select(type == "string" and test("^[a-f0-9]{40}$"))' "$private/candidate-manifest.json") \
  || fail 'cutover release artifact has no immutable source revision'
[[ $candidate_revision != "$source_revision" ]] \
  || fail 'cutover release revision must differ from the previous release'
git -C "$root" cat-file -e "$candidate_revision^{commit}" 2> /dev/null \
  || fail 'cutover release revision is unavailable in this checkout; fetch it before preparation'
mkdir -m 700 -- "$private/cutover-source"
git -C "$root" archive "$candidate_revision" | tar -xf - -C "$private/cutover-source"
application_project_metadata_to_jsonl "$private/cutover-source" "$private/cutover-projects.jsonl"
run_production "$private/logs/cutover-render.log" render "$source_values" "$candidate"
python3 "$root/.scripts/validate-backup-package.py" "$manifest" "$archive" \
  "$private/cutover-validation" "$private/cutover-projects.jsonl" "$backup_id" \
  > "$private/cutover-validation.json"
jq -e --slurpfile previous "$private/previous-validation.json" '
  .backupId == $previous[0].backupId and .source == $previous[0].source
  and .contentFingerprint == $previous[0].contentFingerprint
' "$private/cutover-validation.json" > /dev/null \
  || fail 'cutover metadata changes the original backup identity or complete content'

phase=create-source-cluster
source_cluster_attempted=true
source_cluster_created=null
run_cluster_lifecycle "$private/logs/source-create.log" create-new "$source_values"
source_cluster_created=true
phase=import-final-previous-backup
run_production "$private/logs/source-restore.log" cutover-restore "$source_values" \
  "$manifest" "$archive" "$backup_id" "$source_state" "$candidate" "$snapshot" \
  "CUTOVER-RESTORE-$backup_id"
phase=verify-cutover-read-checks
run_production "$private/source-restore-status.json" restore-status "$source_values" "$source_state"
jq -e '.savedProgress.status == "awaiting-signoff"
  and .savedProgress.phase == "pending-signoff"
  and .savedProgress.writesMayHaveOpened == false
  and .savedProgress.readChecks.status == "passed"
  and .savedProgress.publicRoutesMayBeOpen == true
  and .writesMayHaveOpened == false
  and .lease.ownedByRestore == true and .lease.phase == "awaiting-signoff"
  and .observed.graphql.mode == "maintenance"
  and .observed.graphql.maintenanceQuery == true
  and .observed.publicRoutes.normalRoutesObserved == true' \
  "$private/source-restore-status.json" > /dev/null \
  || fail 'cutover restore did not complete read-only verification under the retained write barrier'

phase=package-cutover-backup
python3 "$root/.scripts/package-local-backup.py" "$snapshot" "$package_directory" \
  > "$private/cutover-package.json"
cutover_backup_id=$(jq -er '.backupId' "$private/cutover-package.json")
package_manifest="$package_directory/$(jq -er '.manifest' "$private/cutover-package.json")"
package_archive="$package_directory/$(jq -er '.archive' "$private/cutover-package.json")"
python3 "$root/.scripts/validate-backup-package.py" "$package_manifest" "$package_archive" \
  "$private/cutover-package-validation" "$private/cutover-projects.jsonl" "$cutover_backup_id" \
  > "$private/cutover-package-validation.json"
jq -e --arg artifact "$candidate" --arg cluster "$source_cluster" \
  --arg context "k3d-$source_cluster" --arg revision "$candidate_revision" \
  --arg originalId "$backup_id" '
  .source.target == "local" and .source.cluster == $cluster
  and .source.context == $context and .source.namespace == "recipe-db"
  and .source.artifact == $artifact and .source.revision == $revision
  and .backupId != $originalId
' "$private/cutover-package-validation.json" > /dev/null \
  || fail 'new package does not truthfully identify the cutover release and local capture'

phase=create-restore-rehearsal-cluster
target_cluster_attempted=true
target_cluster_created=null
run_cluster_lifecycle "$private/logs/target-create.log" create-new "$target_values"
target_cluster_created=true
phase=restore-cutover-backup
run_production "$private/logs/target-restore.log" restore "$target_values" \
  "$package_manifest" "$package_archive" "$cutover_backup_id" "$target_state" \
  "RESTORE-$cutover_backup_id"
phase=verify-restored-read-checks
run_production "$private/target-restore-status.json" restore-status "$target_values" "$target_state"
jq -e '.savedProgress.status == "awaiting-signoff"
  and .savedProgress.phase == "pending-signoff"
  and .savedProgress.writesMayHaveOpened == false
  and .savedProgress.readChecks.status == "passed"
  and .savedProgress.publicRoutesMayBeOpen == true
  and .writesMayHaveOpened == false
  and .lease.ownedByRestore == true and .lease.phase == "awaiting-signoff"
  and .observed.graphql.mode == "maintenance"
  and .observed.graphql.maintenanceQuery == true
  and .observed.publicRoutes.normalRoutesObserved == true' \
  "$private/target-restore-status.json" > /dev/null \
  || fail 'new package restore did not complete read-only verification under the retained write barrier'

phase=write-provenance
source_manifest_sha=$(sha256sum "$manifest" | cut -d ' ' -f 1)
new_manifest_sha=$(sha256sum "$package_manifest" | cut -d ' ' -f 1)
new_archive_sha=$(sha256sum "$package_archive" | cut -d ' ' -f 1)
jq -n --arg previousId "$backup_id" --arg previousManifestSha "$source_manifest_sha" \
  --arg previousArchiveSha "$archive_sha" --slurpfile previous "$manifest" \
  --arg verification "$(jq -er .maintenanceOperation.uploadStatus "$receipt")" \
  --arg cutoverId "$cutover_backup_id" --arg cutoverManifest "$(basename "$package_manifest")" \
  --arg cutoverArchive "$(basename "$package_archive")" \
  --arg cutoverManifestSha "$new_manifest_sha" --arg cutoverArchiveSha "$new_archive_sha" \
  --slurpfile cutover "$private/cutover-package-validation.json" \
  --arg createdAt "$(date -u +%FT%TZ)" '
  {schemaVersion:1,createdAt:$createdAt,
    previousBackup:{backupId:$previousId,manifestSha256:$previousManifestSha,
      archiveSha256:$previousArchiveSha,source:$previous[0].source,
      verifiedUploadStatus:$verification},
    cutoverBackup:{backupId:$cutoverId,manifest:$cutoverManifest,archive:$cutoverArchive,
      manifestSha256:$cutoverManifestSha,archiveSha256:$cutoverArchiveSha,
      source:$cutover[0].source}}
' > "$result_directory/provenance.json"
chmod 600 "$result_directory/provenance.json"

phase=verify-cleanup-ownership
run_cluster_lifecycle "$private/logs/source-verify.log" verify "$source_values"
run_cluster_lifecycle "$private/logs/target-verify.log" verify "$target_values"
phase=remove-successful-rehearsal-clusters
run_cluster_lifecycle "$private/logs/source-delete.log" delete "$source_values" \
  "DELETE-$source_cluster-AND-ALL-DATA"
source_cluster_deleted=true
run_cluster_lifecycle "$private/logs/target-delete.log" delete "$target_values" \
  "DELETE-$target_cluster-AND-ALL-DATA"
target_cluster_deleted=true
phase=complete
success=true
