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
operator_home=${HOME:-}
if [[ -z $operator_home ]]; then
  command -v getent > /dev/null || fail 'cannot determine operator home directory'
  passwd_entry=$(getent passwd "$EUID") || fail 'cannot determine operator home directory'
  IFS=: read -r _ _ _ _ _ operator_home _ <<< "$passwd_entry"
fi
[[ $operator_home == /* ]] || fail 'cannot determine operator home directory'
operator_home=$(realpath -m -- "$operator_home") \
  || fail 'cannot determine operator home directory'
operator_config_directory="$operator_home/.config"
case "$result_directory/" in
  "$root/"* | "$operator_config_directory/"* | /var/lib/rancher/*)
    fail 'results must be outside the checkout, operator configuration and runtime storage'
    ;;
esac
for tool in git jq k3d kubectl mise openssl oras python3 realpath sha256sum setsid stat tar yq; do
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
  and .maintenanceOperation.packageBackupId == $id
  and (.maintenanceOperation.backupId | type == "string" and test("^backup-[0-9]+-[0-9]+$"))
  and .maintenanceOperation.status == "captured"
  and .maintenanceOperation.phase == "captured"
  and (.maintenanceOperation.uploadStatus == "verified-upload"
    or .maintenanceOperation.uploadStatus == "verified-unchanged")
  and (.maintenanceOperation.maxStagingBytes | type == "number" and floor == .
    and . >= 268435456 and . <= 107374182400)
  and (.maintenanceOperation.capturedAt | type == "string" and length > 0)
  and (.maintenanceOperation.uploadStatus != "verified-upload"
    or (.maintenanceOperation.backupId == $id
      and .maintenanceOperation.capturedAt == $capturedAt))
  and (.maintenanceOperation.uploadStatus != "verified-unchanged"
    or (.maintenanceOperation.backupId == $id
      and .maintenanceOperation.capturedAt == $capturedAt
      and (.maintenanceOperation.verifiedBaselineBackupId |
        type == "string" and test("^backup-[0-9]+-[0-9]+$"))))
  and .maintenanceOperation.source.artifact == $artifact
  and .maintenanceOperation.source.revision == $revision
' "$retrieval_receipt" > /dev/null || fail 'retrieval receipt does not verify this exact final backup'
max_staging_bytes=$(jq -er '.maintenanceOperation.maxStagingBytes' "$retrieval_receipt")
archive_size=$(stat -c %s "$input_archive") \
  || fail 'cannot determine the retrieved archive size'
if ! [[ $archive_size =~ ^[0-9]+$ ]] || ((10#$archive_size > max_staging_bytes)); then
  fail 'retrieved archive exceeds the Pi configured staging limit'
fi
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
source_cluster_deletion_attempted=false
target_cluster_deletion_attempted=false
source_cluster_deleted=false
target_cluster_deleted=false
success=false
active_command_pid=''
active_command_starting=false
pending_signal=''
pending_signal_status=0
cleanup_signal=''
cleanup_signal_status=0

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
    --argjson sourceClusterDeletionAttempted "$source_cluster_deletion_attempted" \
    --argjson targetClusterDeletionAttempted "$target_cluster_deletion_attempted" \
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
          created:$sourceClusterCreated,deletionAttempted:$sourceClusterDeletionAttempted,
          deleted:$sourceClusterDeleted},
        target:{name:$targetCluster,creationAttempted:$targetClusterAttempted,
          created:$targetClusterCreated,deletionAttempted:$targetClusterDeletionAttempted,
          deleted:$targetClusterDeleted}},
      cleanup:{privateDataRemoved:$privateDataRemoved,inputCopiesRemoved:$inputCopiesRemoved}}
  ' > "$result_directory/result.json" || return 1
  chmod 600 "$result_directory/result.json" || return 1
}

on_exit() {
  local status=$?
  trap - EXIT
  trap 'record_cleanup_signal INT 130' INT
  trap 'record_cleanup_signal TERM 143' TERM
  trap 'record_cleanup_signal HUP 129' HUP
  if [[ $status != 0 && $phase == remove-successful-rehearsal-clusters ]]; then
    if [[ $source_cluster_deleted == true && $target_cluster_deleted == true ]]; then
      failure_reason="both rehearsal clusters were deleted before cleanup was interrupted; no retry or recreation was attempted"
    elif [[ $source_cluster_deleted == true && $target_cluster_deletion_attempted == true ]]; then
      failure_reason="success cleanup stopped after the source cluster was deleted; target cluster deletion outcome is uncertain; no retry or recreation was attempted"
    elif [[ $source_cluster_deleted == true ]]; then
      failure_reason="success cleanup stopped after the source cluster was deleted; target cluster deletion was not attempted; no retry or recreation was attempted"
    elif [[ $source_cluster_deletion_attempted == true ]]; then
      failure_reason="success cleanup stopped with the source cluster deletion outcome uncertain; target cluster deletion was not attempted; no retry or recreation was attempted"
    else
      failure_reason="success cleanup stopped before cluster deletion began; no retry or recreation was attempted"
    fi
  elif [[ $status != 0 && -z $failure_reason ]]; then
    failure_reason="command failed during $phase (exit $status); no automatic recovery, retry, recreation or cluster deletion was attempted"
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
  apply_cleanup_interruption
  if ! write_result; then
    status=1
    success=false
    failure_reason='result.json could not be persisted; inspect the result directory and retained clusters'
    write_result || printf 'Cutover backup preparation: could not write result.json\n' >&2
  fi
  trap '' INT TERM HUP
  if [[ -n $cleanup_signal ]]; then
    apply_cleanup_interruption
    write_result || {
      status=1
      success=false
      failure_reason='result.json could not be persisted; inspect the result directory and retained clusters'
      write_result || printf 'Cutover backup preparation: could not write result.json\n' >&2
    }
  fi
  if [[ $status != 0 ]]; then
    printf 'Cutover backup preparation stopped in phase %s; no automatic recovery, retry or recreation was attempted.\n' \
      "$phase" >&2
    printf 'Inspect the exact per-cluster state before taking operator action.\n' >&2
    printf 'Inspect %s/result.json and the private logs under %s/.private/logs.\n' \
      "$result_directory" "$result_directory" >&2
  fi
  exit "$status"
}

record_cleanup_signal() {
  if [[ -z $cleanup_signal ]]; then
    cleanup_signal=$1
    cleanup_signal_status=$2
  fi
}

apply_cleanup_interruption() {
  if [[ -n $cleanup_signal ]]; then
    success=false
    status=$cleanup_signal_status
    failure_reason="interrupted by SIG$cleanup_signal during final cleanup"
  fi
}

trap on_exit EXIT

interrupt_active_command() {
  local signal=$1 status=$2
  if [[ $active_command_starting == true && -z $active_command_pid ]]; then
    pending_signal=$signal
    pending_signal_status=$status
    return
  fi
  failure_reason="interrupted by SIG$signal"
  if [[ -n $active_command_pid ]]; then
    local forwarded_signal=$signal
    if [[ $signal == INT ]]; then
      # Bash starts asynchronous jobs with SIGINT ignored; use their cleanup signal.
      forwarded_signal=TERM
    fi
    kill -s "$forwarded_signal" -- "-$active_command_pid" 2> /dev/null || true
    wait "$active_command_pid" 2> /dev/null || true
    while kill -0 -- "-$active_command_pid" 2> /dev/null; do sleep 0.1; done
    active_command_pid=''
  fi
  exit "$status"
}
trap 'interrupt_active_command INT 130' INT
trap 'interrupt_active_command TERM 143' TERM
trap 'interrupt_active_command HUP 129' HUP

run_active_process() {
  local log=$1 output=$2 status signal
  shift 2
  set +m
  active_command_starting=true
  if [[ -n $output ]]; then
    setsid --wait "$@" > "$output" 2> "$log" &
  else
    setsid --wait "$@" > "$log" 2>&1 &
  fi
  active_command_pid=$!
  active_command_starting=false
  if [[ -n $pending_signal ]]; then
    signal=$pending_signal
    status=$pending_signal_status
    pending_signal=''
    interrupt_active_command "$signal" "$status"
  fi
  if wait "$active_command_pid"; then
    status=0
  else
    status=$?
  fi
  active_command_pid=''
  return "$status"
}

run_active_command() {
  local log=$1
  shift
  run_active_process "$log" '' "$@"
}

run_active_capture() {
  local output=$1 log=$2
  shift 2
  run_active_process "$log" "$output" "$@"
}

run_production() {
  local log=$1
  shift
  run_active_command "$log" mise run --raw production-k3d --release-sources-from-git "$@"
}

run_production_capture() {
  local output=$1 log=$2
  shift 2
  run_active_capture "$output" "$log" mise run --raw production-k3d --release-sources-from-git "$@"
}

run_cluster_lifecycle() {
  local log=$1
  shift
  run_active_command "$log" mise run --raw production-k3d "$@"
}

run_project_metadata() {
  local log=$1 source=$2 output=$3
  # shellcheck disable=SC2016
  run_active_command "$log" bash -c \
    'source "$1"; application_project_metadata_to_jsonl "$2" "$3"' \
    _ "$root/.scripts/lib/project-metadata.sh" "$source" "$output"
}

manifest="$private/inputs/$(basename "$input_manifest")"
archive="$private/inputs/$(basename "$input_archive")"
receipt="$private/inputs/$(basename "$retrieval_receipt")"
[[ $manifest != "$archive" && $manifest != "$receipt" && $archive != "$receipt" ]] \
  || fail 'backup inputs and receipt must have distinct filenames'
run_active_command "$private/logs/copy-manifest.log" cp -- "$input_manifest" "$manifest"
run_active_command "$private/logs/copy-archive.log" cp -- "$input_archive" "$archive"
run_active_command "$private/logs/copy-receipt.log" cp -- "$retrieval_receipt" "$receipt"
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
# shellcheck disable=SC2016
run_active_command "$private/logs/previous-source-extract.log" \
  bash -euo pipefail -c 'git -C "$1" archive "$2" | tar -xf - -C "$3"' \
  _ "$root" "$source_revision" "$private/previous-source"
run_project_metadata "$private/logs/previous-metadata.log" \
  "$private/previous-source" "$private/previous-projects.jsonl"
run_active_capture "$private/previous-validation.json" "$private/logs/previous-validation.log" \
  python3 "$root/.scripts/validate-backup-package.py" "$manifest" "$archive" \
  "$private/previous-validation" "$private/previous-projects.jsonl" "$backup_id" "$max_staging_bytes"
jq -e --arg fingerprint "$(jq -er .contentFingerprint "$manifest")" '
  .maintenanceOperation.uploadStatus != "verified-unchanged"
  or .maintenanceOperation.contentFingerprint == $fingerprint
' "$receipt" > /dev/null \
  || fail 'verified-unchanged retrieval does not match the retained final snapshot contents'

run_active_capture "$private/candidate-manifest.json" "$private/logs/candidate-manifest-fetch.log" \
  oras manifest fetch "$candidate"
candidate_revision=$(jq -er '.annotations["org.opencontainers.image.revision"] |
  select(type == "string" and test("^[a-f0-9]{40}$"))' "$private/candidate-manifest.json") \
  || fail 'cutover release artifact has no immutable source revision'
[[ $candidate_revision != "$source_revision" ]] \
  || fail 'cutover release revision must differ from the previous release'
git -C "$root" cat-file -e "$candidate_revision^{commit}" 2> /dev/null \
  || fail 'cutover release revision is unavailable in this checkout; fetch it before preparation'
mkdir -m 700 -- "$private/cutover-source"
# shellcheck disable=SC2016
run_active_command "$private/logs/cutover-source-extract.log" \
  bash -euo pipefail -c 'git -C "$1" archive "$2" | tar -xf - -C "$3"' \
  _ "$root" "$candidate_revision" "$private/cutover-source"
run_project_metadata "$private/logs/cutover-metadata.log" \
  "$private/cutover-source" "$private/cutover-projects.jsonl"
run_production "$private/logs/cutover-render.log" render "$source_values" "$candidate"
run_active_capture "$private/cutover-validation.json" "$private/logs/cutover-validation.log" \
  python3 "$root/.scripts/validate-backup-package.py" "$manifest" "$archive" \
  "$private/cutover-validation" "$private/cutover-projects.jsonl" "$backup_id" "$max_staging_bytes"
jq -e --slurpfile previous "$private/previous-validation.json" '
  .backupId == $previous[0].backupId and .source == $previous[0].source
  and .inventory == $previous[0].inventory
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
  "CUTOVER-RESTORE-$backup_id" "$max_staging_bytes"
phase=verify-cutover-read-checks
run_production_capture "$private/source-restore-status.json" "$private/logs/source-restore-status.log" \
  restore-status "$source_values" "$source_state"
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
run_active_capture "$private/cutover-package.json" "$private/logs/cutover-package.log" \
  python3 "$root/.scripts/package-local-backup.py" "$snapshot" "$package_directory" "$max_staging_bytes"
cutover_backup_id=$(jq -er '.backupId' "$private/cutover-package.json")
package_manifest="$package_directory/$(jq -er '.manifest' "$private/cutover-package.json")"
package_archive="$package_directory/$(jq -er '.archive' "$private/cutover-package.json")"
run_active_capture "$private/cutover-package-validation.json" \
  "$private/logs/cutover-package-validation.log" \
  python3 "$root/.scripts/validate-backup-package.py" "$package_manifest" "$package_archive" \
  "$private/cutover-package-validation" "$private/cutover-projects.jsonl" \
  "$cutover_backup_id" "$max_staging_bytes"

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
  "RESTORE-$cutover_backup_id" "$max_staging_bytes"
phase=verify-restored-read-checks
run_production_capture "$private/target-restore-status.json" "$private/logs/target-restore-status.log" \
  restore-status "$target_values" "$target_state"
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
run_active_capture "$private/source-manifest-sha256.txt" \
  "$private/logs/source-manifest-hash.log" sha256sum "$manifest"
run_active_capture "$private/cutover-manifest-sha256.txt" \
  "$private/logs/cutover-manifest-hash.log" sha256sum "$package_manifest"
run_active_capture "$private/cutover-archive-sha256.txt" \
  "$private/logs/cutover-archive-hash.log" sha256sum "$package_archive"
source_manifest_sha=$(cut -d ' ' -f 1 "$private/source-manifest-sha256.txt")
new_manifest_sha=$(cut -d ' ' -f 1 "$private/cutover-manifest-sha256.txt")
new_archive_sha=$(cut -d ' ' -f 1 "$private/cutover-archive-sha256.txt")
maintenance_backup_id=$(jq -er .maintenanceOperation.backupId "$receipt")
maintenance_captured_at=$(jq -er .maintenanceOperation.capturedAt "$receipt")
jq -n --arg previousId "$backup_id" --arg previousManifestSha "$source_manifest_sha" \
  --arg previousArchiveSha "$archive_sha" --slurpfile previous "$manifest" \
  --argjson maxStagingBytes "$max_staging_bytes" \
  --arg verification "$(jq -er .maintenanceOperation.uploadStatus "$receipt")" \
  --arg maintenanceBackupId "$maintenance_backup_id" \
  --arg maintenanceCapturedAt "$maintenance_captured_at" \
  --arg verifiedBaselineBackupId \
  "$(jq -r '.maintenanceOperation.verifiedBaselineBackupId // ""' "$receipt")" \
  --arg contentFingerprint \
  "$(jq -r '.maintenanceOperation.contentFingerprint // ""' "$receipt")" \
  --arg cutoverId "$cutover_backup_id" --arg cutoverManifest "$(basename "$package_manifest")" \
  --arg cutoverArchive "$(basename "$package_archive")" \
  --arg cutoverManifestSha "$new_manifest_sha" --arg cutoverArchiveSha "$new_archive_sha" \
  --slurpfile cutover "$private/cutover-package-validation.json" \
  --arg createdAt "$(date -u +%FT%TZ)" '
  {schemaVersion:1,createdAt:$createdAt,
    previousBackup:{backupId:$previousId,manifestSha256:$previousManifestSha,
      archiveSha256:$previousArchiveSha,capturedAt:$previous[0].capturedAt,
      source:$previous[0].source,
      verifiedUploadStatus:$verification},
    maintenanceOperation:{backupId:$maintenanceBackupId,packageBackupId:$previousId,
      capturedAt:$maintenanceCapturedAt,uploadStatus:$verification,
      maxStagingBytes:$maxStagingBytes} +
      (if $verification == "verified-unchanged" then
        {verifiedBaselineBackupId:$verifiedBaselineBackupId,contentFingerprint:$contentFingerprint}
       else {} end),
    cutoverBackup:{backupId:$cutoverId,manifest:$cutoverManifest,archive:$cutoverArchive,
      manifestSha256:$cutoverManifestSha,archiveSha256:$cutoverArchiveSha,
      source:$cutover[0].source}}
' > "$result_directory/provenance.json"
chmod 600 "$result_directory/provenance.json"

phase=verify-cleanup-ownership
run_cluster_lifecycle "$private/logs/source-verify.log" verify "$source_values"
run_cluster_lifecycle "$private/logs/target-verify.log" verify "$target_values"
phase=remove-successful-rehearsal-clusters
source_cluster_deletion_attempted=true source_cluster_deleted=null
run_cluster_lifecycle "$private/logs/source-delete.log" delete "$source_values" \
  "DELETE-$source_cluster-AND-ALL-DATA"
source_cluster_deleted=true target_cluster_deletion_attempted=true target_cluster_deleted=null
run_cluster_lifecycle "$private/logs/target-delete.log" delete "$target_values" \
  "DELETE-$target_cluster-AND-ALL-DATA"
target_cluster_deleted=true phase=complete success=true
