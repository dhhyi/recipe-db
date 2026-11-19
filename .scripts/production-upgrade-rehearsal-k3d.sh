#!/usr/bin/env bash
# GraphQL operation strings intentionally keep their variables literal.
# shellcheck disable=SC2016
set -Eeuo pipefail
set +x
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
upload="$root/provisioning/files/backup-upload.py"
validator="$root/.scripts/validate-backup-package.py"
# shellcheck source=.scripts/lib/rehearsal-k3d.sh
source "$root/.scripts/lib/rehearsal-k3d.sh"
# shellcheck source=.scripts/lib/project-metadata.sh
source "$root/.scripts/lib/project-metadata.sh"

die() {
  failure_reason=$*
  printf 'Upgrade rehearsal: %s\n' "$failure_reason" >&2
  exit 1
}

[[ $# == 6 ]] || die 'usage: mise run production-upgrade-rehearsal-k3d <backup-manifest> <backup-archive> <verified-upload|verified-unchanged> <VERIFIED-backup-id-status> <candidate-release@sha256:digest> <new-absolute-result-directory>'
input_manifest=$1
input_archive=$2
backup_status=$3
backup_confirmation=$4
candidate=$5
result_directory=$6
[[ $candidate =~ ^ghcr\.io/dhhyi/recipe-db-releases@sha256:[a-f0-9]{64}$ ]] \
  || die 'candidate must be an immutable recipe-db release artifact'
[[ $input_manifest == /* && $input_archive == /* ]] \
  || die 'backup manifest and archive paths must be absolute'

check_private_file() {
  local path=$1 mode
  [[ -f $path && ! -L $path && $(realpath -e "$path") == "$path" ]] \
    || die "required private input is not a regular canonical file: $path"
  [[ $(stat -c %u "$path") == "$EUID" ]] || die "private input is not owned by the current user: $path"
  mode=$(stat -c %a "$path")
  (((8#$mode & 077) == 0)) || die "private input must not be accessible by group or others: $path"
  local parent
  parent=$(dirname "$path")
  [[ $(stat -c %u "$parent") == "$EUID" ]] || die "private input directory is not owned by the current user: $parent"
  mode=$(stat -c %a "$parent")
  (((8#$mode & 077) == 0)) || die "private input directory must not be accessible by group or others: $parent"
}

check_private_file "$input_manifest"
check_private_file "$input_archive"
[[ $(dirname "$input_manifest") == "$(dirname "$input_archive")" ]] \
  || die 'backup manifest and archive must be in the same private directory'
[[ $(basename "$input_manifest") == "$(basename "${input_archive%.tar.gz}").manifest.json" ]] \
  || die 'backup manifest must be the sibling manifest for the supplied archive'

[[ $result_directory == /* && ! -e $result_directory && ! -L $result_directory ]] \
  || die 'result directory must be a new absolute path'
result_parent=$(dirname "$result_directory")
result_name=$(basename "$result_directory")
[[ $result_name != . && $result_name != .. && $(realpath -e "$result_parent") == "$result_parent" ]] \
  || die 'result directory parent must exist without symlink traversal'
[[ $(stat -c %u "$result_parent") == "$EUID" ]] \
  || die 'result directory parent must be owned by the current user'
parent_mode=$(stat -c %a "$result_parent")
(((8#$parent_mode & 077) == 0)) \
  || die 'result directory parent must not be accessible by group or others'
[[ $(dirname "$input_manifest") == "$result_parent" &&
$(dirname "$input_archive") == "$result_parent" ]] \
  || die 'copy the backup pair into the private result parent; successful runs remove only those copies'
case "$result_directory/" in
  "$root/"* | "$HOME/.config/"* | /var/lib/rancher/*)
    die 'results must be outside the checkout, operator configuration and runtime storage'
    ;;
esac
for tool in curl docker git jq k3d kubectl mise openssl oras python3 sha256sum stat yq; do
  command -v "$tool" > /dev/null || die "required tool not found: $tool"
done

backup_id=$(jq -er '.backupId | select(type == "string" and test("^backup-[0-9]+-[0-9]+$"))' "$input_manifest") \
  || die 'backup manifest has no valid backup ID'
source_release=$(jq -er '.source.artifact |
  select(test("^ghcr[.]io/dhhyi/recipe-db-releases@sha256:[a-f0-9]{64}$"))' "$input_manifest") \
  || die 'backup manifest does not identify an immutable recipe-db source release'
source_revision=$(jq -er '.source.revision |
  select(type == "string" and test("^[a-f0-9]{40}$"))' "$input_manifest") \
  || die 'backup manifest does not identify its source revision'
jq -e '.source.target == "pi" and .source.cluster == "recipe-db-pi"
  and .source.context == "recipe-db-pi" and .source.namespace == "recipe-db"' \
  "$input_manifest" > /dev/null || die 'backup package is not from the documented Pi production target'
[[ $candidate != "$source_release" ]] || die 'candidate must differ from the backup source release'
[[ $backup_status == verified-upload || $backup_status == verified-unchanged ]] \
  || die 'backup status must be the current Pi uploader result: verified-upload or verified-unchanged'
[[ $backup_confirmation == "VERIFIED-$backup_id-$backup_status" ]] \
  || die 'backup status requires the exact VERIFIED-<backup-id>-<status> confirmation after checking the Pi baseline'
backup_archive_sha=$(jq -er '.archive.sha256 | select(test("^[a-f0-9]{64}$"))' "$input_manifest") \
  || die 'backup manifest has no valid archive digest'
backup_captured_at=$(jq -er '.capturedAt | select(type == "string" and length > 0)' "$input_manifest") \
  || die 'backup manifest has no capture timestamp'

reference_file="$HOME/.config/recipe-db/backup/backup-release-ref"
check_private_file "$reference_file"
mapfile -t release_references < "$reference_file"
[[ ${#release_references[@]} == 1 && ${release_references[0]} == "$source_release" ]] \
  || die 'backup source release does not match the documented local backup-release-ref'
git -C "$root" cat-file -e "$source_revision^{commit}" 2> /dev/null \
  || die 'backup source revision is not available in this checkout; fetch it before rehearsing'

mkdir -m 700 -- "$result_directory"
work="$result_directory/.private"
mkdir -m 700 -- "$work"
started_at=$(date -u +%FT%TZ)
started_epoch=$(date +%s)
phase=preflight
failure_reason=''
rehearsal_status=failed
remote_status_independently_verified=false
cleanup_status=not-run
private_data_removed=false
input_copies_removed=false
cluster_created=false
cluster=''
cluster_driver=''
cluster_values=''
source_worktree=''
candidate_worktree=''
source_worktree_created=false
candidate_worktree_created=false
run_id=$(openssl rand -hex 8)
port_offset=$((16#${run_id:0:4} % 8000))
http_port=$((20000 + port_offset))
api_port=$((30000 + port_offset))
source_sample_file="$work/source-sample.json"
request="$work/request.json"
response="$work/response.json"
curl_config="$work/curl.conf"
owner_token="$work/owner-token"
accounts_file="$work/auth-accounts.json"
fake_remote="$work/fake-remote"
fake_bin="$work/bin"
phases_file="$result_directory/.phases.json"
deleted_clusters=()
cluster_check_count=0
actual_versions='[]'
candidate_images='{}'
candidate_revision=''
candidate_migrations='[]'
candidate_migration_count=0
sample_relations_verified=false
source_package_status='not-checked'
input_package_validation_status=not-run
success_upgrade_status=not-started
migration_outcome=not-started
failure_recovery_status=not-started
post_backup_id=''
post_backup_upload_status=not-run
post_backup_restore_status=not-run

deployed_release=''
deployed_revision=''
deployed_identity_verified=false
deployed_image_inventory_verified=false
backup_storage_versions='[]'
source_storage_versions='[]'
backup_storage_versions_match_source=false
live_storage_workloads_ready=false
host_cpu_count=0
docker_memory_bytes=0
available_disk_bytes_before=0
available_disk_bytes_after=0
printf '[]\n' > "$phases_file"

# shellcheck disable=SC2329
remove_input_copies() {
  rm -- "$input_manifest" "$input_archive" \
    && [[ ! -e $input_manifest && ! -e $input_archive ]]
}

# These functions are reached indirectly through the EXIT trap.
# shellcheck disable=SC2329
write_result() {
  local success=$1 finished elapsed cluster_name retained_worktrees result_status
  result_status=failed
  [[ $success != true ]] || result_status=passed
  [[ $success == true ]] || result_status=$rehearsal_status
  finished=$(date -u +%FT%TZ)
  elapsed=$(($(date +%s) - started_epoch))
  cluster_name=$cluster
  retained_worktrees=$(jq -nc --arg source "$source_worktree" --arg candidate "$candidate_worktree" \
    --argjson sourceCreated "$source_worktree_created" --argjson candidateCreated "$candidate_worktree_created" '
      [(if $sourceCreated then $source else empty end),
       (if $candidateCreated then $candidate else empty end)]')
  jq -n --arg status "$result_status" \
    --arg phase "$phase" --arg failure "$failure_reason" \
    --arg started "$started_at" --arg finished "$finished" --argjson elapsed "$elapsed" \
    --arg backupId "$backup_id" --arg backupRelease "$source_release" \
    --arg backupRevision "$source_revision" --arg backupArchiveSha256 "$backup_archive_sha" \
    --arg backupCapturedAt "$backup_captured_at" \
    --arg backupStatus "$backup_status" \
    --arg inputPackageStatus "$input_package_validation_status" \
    --arg candidate "$candidate" --arg candidateRevision "$candidate_revision" \
    --arg deployedRelease "$deployed_release" --arg deployedRevision "$deployed_revision" \
    --argjson deployedImagesVerified "$deployed_image_inventory_verified" \
    --argjson backupStorageVersions "$backup_storage_versions" \
    --argjson sourceStorageVersions "$source_storage_versions" \
    --argjson backupStorageMatchesSource "$backup_storage_versions_match_source" \
    --argjson liveStorageWorkloadsReady "$live_storage_workloads_ready" \
    --arg sourcePackageStatus "$source_package_status" \
    --arg successUpgradeStatus "$success_upgrade_status" \
    --arg migrationOutcome "$migration_outcome" \
    --argjson sampleRelationsVerified "$sample_relations_verified" \
    --arg failureRecoveryStatus "$failure_recovery_status" \
    --arg postBackupId "$post_backup_id" --arg postBackupUploadStatus "$post_backup_upload_status" \
    --arg postBackupRestoreStatus "$post_backup_restore_status" \
    --arg currentCluster "$cluster_name" --argjson deletedClusters "$(printf '%s\n' "${deleted_clusters[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    --argjson candidateImages "$candidate_images" --argjson candidateMigrations "$candidate_migrations" \
    --argjson actualVersions "$actual_versions" --argjson remoteStatusVerified "$remote_status_independently_verified" \
    --argjson deployedIdentityVerified "$deployed_identity_verified" \
    --argjson cpuCount "$host_cpu_count" --argjson dockerMemoryBytes "$docker_memory_bytes" \
    --argjson diskBefore "$available_disk_bytes_before" --argjson diskAfter "$available_disk_bytes_after" \
    --arg cleanupStatus "$cleanup_status" --argjson privateDataRemoved "$private_data_removed" \
    --argjson inputCopiesRemoved "$input_copies_removed" \
    --argjson retainedWorktrees "$retained_worktrees" \
    --slurpfile phases "$phases_file" \
    '{schemaVersion:1,status:$status,phase:$phase,
      startedAt:$started,finishedAt:$finished,elapsedSeconds:$elapsed,
      failureReason:(if $failure == "" then null else $failure end),
      backup:{backupId:$backupId,capturedAt:$backupCapturedAt,
        sourceRelease:$backupRelease,sourceRevision:$backupRevision,
        archiveSha256:$backupArchiveSha256,operatorProvided:true,
        remoteUploadStatusIndependentlyVerified:$remoteStatusVerified,
        operatorReportedUploadStatus:$backupStatus,
        operatorAttestedBaselineBackupId:$backupId,
        packageValidation:$inputPackageStatus,
        rehearsalCaptureStatus:$sourcePackageStatus},
      deployedIdentity:{release:$deployedRelease,revision:$deployedRevision,
        matchesBackupSource:$deployedIdentityVerified,
        imagesMatchSourceArtifact:$deployedImagesVerified},
      storageVersionEvidence:{backup:$backupStorageVersions,
        sourceRequirements:$sourceStorageVersions,
        backupMatchesSourceRequirements:$backupStorageMatchesSource,
        liveStatefulWorkloadsReadyAtSourceRelease:$liveStorageWorkloadsReady,
        liveMarkersDirectlyRead:false},
      candidate:{artifact:$candidate,revision:$candidateRevision,
        images:$candidateImages,migrations:$candidateMigrations,
        migratorImages:[$candidateMigrations[]?.image]},
      successfulUpgrade:{status:$successUpgradeStatus,migrationOutcome:$migrationOutcome,
        representativeRecipeLinkedDataVerified:$sampleRelationsVerified,
        actualStorageVersions:$actualVersions},
      postReleaseBackup:{backupId:(if $postBackupId == "" then null else $postBackupId end),
        uploadStatus:$postBackupUploadStatus,restoreResult:$postBackupRestoreStatus},
      failureRecovery:{status:$failureRecoveryStatus,
        verification:(if $failureRecoveryStatus == "passed"
          then "guarded complete recovery; internal data/readiness checks; public barrier remained closed"
          else null end),
        injectedFailure:(if $failureRecoveryStatus == "in-progress"
          or $failureRecoveryStatus == "passed"
          then "synthetic missing-job-after-activation-intent; no candidate migration was executed"
          else null end)},
      cleanup:{status:$cleanupStatus,activeCluster:$currentCluster,
        deletedClusters:$deletedClusters,retainedWorktrees:$retainedWorktrees,
        privateDataRemoved:$privateDataRemoved,inputCopiesRemoved:$inputCopiesRemoved},
      capacity:{hostCpuCount:$cpuCount,dockerMemoryBytes:$dockerMemoryBytes,
        availableDiskBytesBefore:$diskBefore,availableDiskBytesAfter:$diskAfter},
      phases:$phases[0]}' > "$result_directory/result.json" \
    && chmod 600 "$result_directory/result.json"
}

# shellcheck disable=SC2329
finish() {
  local status=$?
  trap - EXIT ERR INT TERM
  set +e
  if ((status == 0)); then
    phase=cleanup
    if $cluster_created; then
      if lifecycle "$cluster_driver" false delete "$cluster_values" \
        "DELETE-$cluster-AND-ALL-DATA" > "$work/logs/cluster-delete.log" 2>&1; then
        cluster_created=false
        deleted_clusters+=("$cluster")
      else
        status=1
        rehearsal_status=cleanup-failed
        cleanup_status=cleanup-failed
        failure_reason='owned rehearsal cluster could not be deleted; diagnostics are retained'
      fi
    fi
  fi
  if ((status == 0)); then
    if $source_worktree_created; then
      if git -C "$root" worktree remove --force "$source_worktree" \
        > "$work/logs/source-worktree-remove.log" 2>&1; then
        source_worktree_created=false
      else
        status=1
        rehearsal_status=cleanup-failed
        cleanup_status=cleanup-failed
      fi
    fi
    if $candidate_worktree_created; then
      if git -C "$root" worktree remove --force "$candidate_worktree" \
        > "$work/logs/candidate-worktree-remove.log" 2>&1; then
        candidate_worktree_created=false
      else
        status=1
        rehearsal_status=cleanup-failed
        cleanup_status=cleanup-failed
      fi
    fi
    if ((status != 0)); then
      failure_reason='a rehearsal worktree could not be removed; diagnostics are retained'
    fi
  fi
  if ((status == 0)); then
    phase=cleanup
    cleanup_status=passed
    rehearsal_status=passed
    if remove_input_copies; then
      input_copies_removed=true
    else
      status=1
      rehearsal_status=cleanup-failed
      cleanup_status=cleanup-failed
      failure_reason='private backup input copies could not be removed'
    fi
  fi
  if ((status == 0)); then
    rm -rf -- "$work"
    if [[ ! -e $work && ! -L $work ]]; then
      private_data_removed=true
      phase=complete
    else
      status=1
      rehearsal_status=cleanup-failed
      cleanup_status=cleanup-failed
      failure_reason='private rehearsal data could not be removed'
    fi
  fi
  if ((status != 0)); then
    if [[ $rehearsal_status != cleanup-failed ]]; then
      cleanup_status=preserved-for-investigation
      [[ $rehearsal_status == interrupted ]] || rehearsal_status=failed
    fi
    write_result false || true
  else
    if ! write_result true; then
      status=1
      rehearsal_status=cleanup-failed
      failure_reason='private result.json could not be written'
      cleanup_status=cleanup-failed
      write_result false || true
    fi
  fi
  if ((status == 0)); then
    rm -f -- "$phases_file" || {
      status=1
      rehearsal_status=cleanup-failed
      failure_reason='temporary phase record could not be removed'
      cleanup_status=cleanup-failed
      private_data_removed=false
      write_result false || true
    }
  fi
  if ((status == 0)); then
    printf 'Upgrade rehearsal passed. Private result: %s/result.json\n' "$result_directory"
  else
    printf 'Upgrade rehearsal stopped during %s. Private evidence retained at %s\n' \
      "$phase" "$result_directory" >&2
    if $cluster_created; then
      printf 'Inspect the owned local target: (cd %q && mise run --raw production-k3d status %q)\n' \
        "$cluster_driver" "$cluster_values" >&2
      printf 'After inspection, remove only that target: (cd %q && mise run --raw production-k3d delete %q %q)\n' \
        "$cluster_driver" "$cluster_values" "DELETE-$cluster-AND-ALL-DATA" >&2
    fi
    if $source_worktree_created; then
      printf 'After cluster cleanup, remove retained source worktree: git -C %q worktree remove --force %q\n' \
        "$root" "$source_worktree" >&2
    fi
    if $candidate_worktree_created; then
      printf 'After cluster cleanup, remove retained candidate worktree: git -C %q worktree remove --force %q\n' \
        "$root" "$candidate_worktree" >&2
    fi
    printf 'This private evidence directory may contain production backup data; keep it private and inspect before removal.\n' >&2
    if [[ -e $input_manifest || -e $input_archive ]]; then
      printf 'After review, remove only the supplied private backup copies: rm -f -- %q %q\n' \
        "$input_manifest" "$input_archive" >&2
    fi
    printf 'After review, remove only this run-owned evidence directory: rm -rf -- %q\n' \
      "$result_directory" >&2
  fi
  exit "$status"
}

trap finish EXIT
trap 'failure_reason="command failed at line $LINENO during $phase"; printf "Upgrade rehearsal command failed at line %s during %s\n" "$LINENO" "$phase" >&2' ERR
trap 'rehearsal_status=interrupted; failure_reason="interrupted by SIGINT during $phase"; exit 130' INT
trap 'rehearsal_status=interrupted; failure_reason="interrupted by SIGTERM during $phase"; exit 143' TERM
mkdir -m 700 -- "$work/logs" "$work/packages" "$work/state" \
  "$work/uploader" "$fake_remote" "$fake_bin"
export FAKE_RCLONE_ROOT=$fake_remote
cp "$root/.scripts/tests/fixtures/rclone-local" "$fake_bin/rclone"
chmod 700 "$fake_bin/rclone"
export PATH="$fake_bin:$PATH"

manifest="$work/packages/$(basename "$input_manifest")"
archive="$work/packages/$(basename "$input_archive")"
cp -- "$input_manifest" "$manifest"
cp -- "$input_archive" "$archive"
chmod 600 "$manifest" "$archive"

mark() {
  jq --arg phase "$phase" '. + [$phase]' "$phases_file" > "$phases_file.next"
  mv "$phases_file.next" "$phases_file"
}

run_logged() {
  local log=$1
  shift
  "$@" > "$log" 2>&1 || {
    failure_reason="$phase failed; private diagnostics retained"
    printf 'Upgrade rehearsal failed during %s; private log retained\n' "$phase" >&2
    return 1
  }
}

lifecycle() {
  local checkout=$1 from_git=$2
  shift 2
  if $cluster_created; then
    cluster_check_count=$((cluster_check_count + 1))
    if ! (cd "$root" && mise run --raw production-k3d verify "$cluster_values") \
      > "$work/logs/cluster-ownership-$cluster_check_count.log" 2>&1; then
      die "owned rehearsal cluster identity changed before $*; no further operation was attempted"
    fi
    checkout=$root
    case "$1" in
      restore | backup-enter | backup-capture) from_git=true ;;
    esac
  fi
  if [[ $from_git == true ]]; then
    (cd "$checkout" && mise run --raw production-k3d --release-sources-from-git "$@")
  else
    (cd "$checkout" && mise run --raw production-k3d "$@")
  fi
}

create_worktree() {
  local revision=$1 destination=$2 label=$3
  git -C "$root" worktree add --detach "$destination" "$revision" \
    > "$work/logs/$label-worktree.log" 2>&1
  if [[ $label == source ]]; then
    source_worktree_created=true
  else
    candidate_worktree_created=true
  fi
  run_logged "$work/logs/$label-mise-install.log" \
    bash -c 'cd "$1" && mise install' _ "$destination"
  [[ -z $(git -C "$destination" status --porcelain --untracked-files=all) ]] \
    || die "$label release worktree is not clean after pinned-tool installation"
}

validate_release_inventory() {
  local checkout=$1 release_file=$2 revision=$3 schema_version=$4 label=$5
  case "$schema_version" in
    1)
      run_logged "$work/logs/$label-release-validation.log" \
        bash -c 'cd "$1" && sh .scripts/validate-production-release.sh "$2" "$3"' \
        _ "$checkout" "$release_file" "$revision"
      ;;
    2)
      run_logged "$work/logs/$label-release-validation.log" \
        bash -c 'cd "$1" && sh .scripts/validate-production-release.sh "$2" "$3" "$1"' \
        _ "$checkout" "$release_file" "$revision"
      ;;
    *)
      die "$label release inventory uses unsupported schema version $schema_version"
      ;;
  esac
}

backup_storage_versions_from_manifest() {
  local manifest=$1
  jq -c '
    [.snapshotManifest.inventory[] as $pvc | $pvc.files[]
      | select(.path == "storage-version")
      | {service:$pvc.service,version:.storageVersion}] | sort_by(.service)
  ' "$manifest"
}

deployed_release_images_match_inventory() {
  local deployments=$1 release_file=$2
  jq -e --slurpfile release "$release_file" '
    . as $actual |
    all($release[0].images | to_entries[];
      . as $expected |
      [$actual.items[] | select(.metadata.name == $expected.key)
        | .spec.template.spec.containers[] | select(.name == $expected.key) | .image]
      == [$expected.value])
  ' "$deployments" > /dev/null
}

workload_image_inventory_matches_rendered() {
  local deployments=$1 rendered=$2 expected="$work/rendered-deployment-images.json"
  local actual="$work/live-deployment-images.json"
  yq -o=json eval-all '[select(.kind == "Deployment")]' "$rendered" \
    | jq 'map({
      name:.metadata.name,
      containers:([.spec.template.spec.containers[]? | {name,image}] | sort_by(.name)),
      initContainers:([.spec.template.spec.initContainers[]? | {name,image}] | sort_by(.name))
    }) | sort_by(.name)' > "$expected" || return 1
  jq '
    [.items[] | {
      name: .metadata.name,
      containers:([.spec.template.spec.containers[]? | {name, image}] | sort_by(.name)),
      initContainers:([.spec.template.spec.initContainers[]? | {name, image}] | sort_by(.name))
    }] | sort_by(.name)
  ' "$deployments" > "$actual" || return 1
  jq -e --slurpfile expected "$expected" '. == $expected[0]' "$actual" > /dev/null
}

graphql_at() {
  local values=$1 query=$2 variables=${3:-'{}'} origin status
  local retry=()
  [[ $query != query* ]] || retry=(--retry 5 --retry-delay 2 --retry-max-time 30 --retry-connrefused)
  origin=$(yq -r '.origin' "$values")
  jq -n --arg query "$query" --argjson variables "$variables" \
    '{query:$query,variables:$variables}' > "$request"
  status=$(curl --silent --show-error --connect-timeout 5 --max-time 30 \
    "${retry[@]}" --config "$curl_config" --header 'Content-Type: application/json' \
    --data-binary "@$request" --output "$response" --write-out '%{http_code}' "$origin/graphql")
  [[ $status == 200 ]] && jq -e '(.errors // [] | length) == 0 and .data != null' \
    "$response" > /dev/null
}

take_sample() {
  local values=$1 deadline candidate_id found_sample=false recipe_ids="$work/recipe-ids.txt"
  local search='query($options: JSON!) { searchRecipes(options: $options) { recipes { id } found } }'
  local recipe='query($id: ID!) { recipe(id: $id) { id name method image { url thumbUrl } inspirations { url } rating { average count } tags { id category name } } }'
  local variables
  variables=$(jq -nc '{options:{q:"*",query_by:"name",per_page:100}}')
  deadline=$((SECONDS + 600))
  while ((SECONDS < deadline)); do
    if graphql_at "$values" "$search" "$variables" \
      && jq -e '(.data.searchRecipes.recipes | length) > 0' "$response" > /dev/null; then
      break
    fi
    sleep 2
  done
  jq -e '(.data.searchRecipes.recipes | length) > 0' "$response" > /dev/null \
    || die 'restored production backup contains no recipe for read-only compatibility verification'
  jq -r '.data.searchRecipes.recipes[].id' "$response" > "$recipe_ids"
  while IFS= read -r candidate_id; do
    graphql_at "$values" "$recipe" "$(jq -nc --arg id "$candidate_id" '{id:$id}')" \
      || die "could not read restored recipe $candidate_id"
    jq -e --arg id "$candidate_id" '
      .data.recipe.id == $id
      and (.data.recipe.image.url | type == "string" and length > 0)
      and (.data.recipe.image.thumbUrl | type == "string" and length > 0)
      and (.data.recipe.rating.average | type == "number")
      and (.data.recipe.rating.count | type == "number" and . > 0)
      and (.data.recipe.inspirations | type == "array" and length > 0
        and all(.[]; .url | type == "string" and length > 0))
      and (.data.recipe.tags | type == "array" and length > 0
        and all(.[]; (.id | type == "string" and length > 0)
          and (.category | type == "string" and length > 0)
          and (.name | type == "string" and length > 0)))
    ' "$response" > /dev/null || continue
    sample_id=$candidate_id
    found_sample=true
    break
  done < "$recipe_ids"
  $found_sample || die 'no restored recipe has populated image, rating, inspiration and tag relations for compatibility verification'
  jq -Sc '.data.recipe' "$response" > "$source_sample_file"
}

verify_sample() {
  local values=$1 label=$2 recipe
  recipe='query($id: ID!) { recipe(id: $id) { id name method image { url thumbUrl } inspirations { url } rating { average count } tags { id category name } } }'
  sample_id=$(jq -er .id "$source_sample_file")
  graphql_at "$values" "$recipe" "$(jq -nc --arg id "$sample_id" '{id:$id}')" \
    || die "$label could not read the representative restored recipe"
  jq -e --arg id "$sample_id" '.data.recipe.id == $id' "$response" > /dev/null \
    || die "$label lost the representative restored recipe"
  jq -Sc '.data.recipe' "$response" > "$work/$label-sample.json"
  cmp -s "$source_sample_file" "$work/$label-sample.json" \
    || die "$label changed the representative recipe across the release"
  sample_relations_verified=true
}

write_values() {
  local cluster_name=$1 port=$2 output=$3
  rehearsal_write_values "$root" "$cluster_name" "$port" "$((port + 10000))" \
    "$accounts_file" "$output" "$deployment_values"
}

write_cluster_values() {
  local operational_values=$1 output=$2
  REHEARSAL_ID="$run_id" yq '.rehearsalId = strenv(REHEARSAL_ID)' \
    "$operational_values" > "$output"
  chmod 600 "$output"
}

rehearsal_cluster_name() {
  local rehearsal_id=$1 suffix=$2
  printf 'recipe-db-rehearsal-%s-%s' "${rehearsal_id:0:10}" "$suffix"
}

new_cluster() {
  local suffix=$1 values=$2 expected_cluster
  cluster=$(rehearsal_cluster_name "$run_id" "$suffix")
  expected_cluster=$cluster
  cluster_driver=$root
  cluster_values=$values
  if ! run_logged "$work/logs/$suffix-create.log" lifecycle "$root" false create-new "$values"; then
    if grep -Fq 'fresh rehearsal creation refuses a pre-existing cluster' "$work/logs/$suffix-create.log"; then
      cluster=''
    elif lifecycle "$root" false verify "$values" \
      > "$work/logs/$suffix-create-ownership-check.log" 2>&1; then
      cluster_created=true
    else
      cluster=''
      printf 'No cleanup attempted for unverified cluster %s; inspect its identity before any removal.\n' \
        "$expected_cluster" >&2
    fi
    die "could not create isolated rehearsal cluster $expected_cluster"
  fi
  cluster_created=true
}

prepare_fake_upload() {
  local label=$1 source_snapshot=$2 deployment_id capture quoted
  deployment_id="issue-251-$run_id-$label"
  capture="$work/$label-capture-existing-snapshot"
  quoted=$(printf '%s' "$source_snapshot" | jq -Rr '@sh')
  printf '#!/bin/sh\nset -eu\n[ "$#" -eq 1 ] || exit 2\nmkdir -m 700 -- "$1"\ncp -a -- %s/. "$1/"\n' \
    "$quoted" > "$capture"
  chmod 700 "$capture"
  printf '{}\n' > "$work/$label-rclone.conf"
  jq -n --arg config "$work/$label-rclone.conf" --arg state "$work/uploader/$label" \
    --arg staging "$work/uploader/staging-$label" --arg capture "$capture" \
    --arg deployment "$deployment_id" '{
      deploymentId:$deployment,remote:"fake-e2e:recipe-db-backups",
      rcloneConfig:$config,stateDirectory:$state,stagingDirectory:$staging,
      captureCommand:$capture,captureTimeoutSeconds:600,maxStagingBytes:8589934592
    }' > "$work/$label-backup-config.json"
  chmod 600 "$work/$label-backup-config.json"
  mkdir -m 700 -p -- "$work/uploader/$label" "$work/uploader/staging-$label"
  run_logged "$work/logs/$label-upload.log" \
    python3 "$upload" nightly --config "$work/$label-backup-config.json"
  jq -e '.status == "verified-upload"' "$work/uploader/$label/status.json" > /dev/null \
    || die "$label rehearsal snapshot was not verified by the fake remote"
  local package_id archive_name manifest_name
  package_id=$(jq -er .backupId "$work/uploader/$label/baseline.json")
  archive_name=$(jq -er .archive "$work/uploader/$label/baseline.json")
  manifest_name=$(jq -er .manifest "$work/uploader/$label/baseline.json")
  mkdir -m 700 -- "$work/packages/$label"
  cp -- "$fake_remote/recipe-db-backups/$deployment_id/$archive_name" "$work/packages/$label/$archive_name"
  cp -- "$fake_remote/recipe-db-backups/$deployment_id/$manifest_name" "$work/packages/$label/$manifest_name"
  local package_archive="$work/packages/$label/$archive_name"
  local package_manifest="$work/packages/$label/$manifest_name"
  jq -e --arg release "$source_release" --arg revision "$source_revision" \
    '.source.artifact == $release and .source.revision == $revision' \
    "$package_manifest" > /dev/null || die "$label rehearsal package does not match the old release"
  local projects="$work/$label-projects.jsonl"
  application_project_metadata_to_jsonl "$source_worktree" "$projects"
  python3 "$validator" "$package_manifest" "$package_archive" \
    "$work/$label-validated-package" "$projects" "$package_id" \
    > "$work/$label-validated-package.json" 2> "$work/logs/$label-package-validation.log"
}

run_migration_sequence() {
  local values=$1 state=$2 timeout migration_timeout deadline iteration execution_status
  timeout=$(yq -r '.timeoutSeconds' "$values")
  [[ $timeout =~ ^[1-9][0-9]*$ && $timeout -le 3600 ]] \
    || die 'local release timeout is invalid or exceeds the supported bound'
  migration_timeout=$(jq '[.migrations[].timeoutSeconds] | add // 0' "$work/candidate-artifact/release.json")
  deadline=$((SECONDS + migration_timeout + timeout * 3))
  iteration=0
  while ((SECONDS < deadline)); do
    iteration=$((iteration + 1))
    run_logged "$work/logs/migration-next-$iteration.log" lifecycle "$candidate_worktree" true \
      release-migration-next "$values" "$state" "$candidate"
    if jq -e '.migrationResult.outcome == "migration-succeeded"
      or .migrationResult.outcome == "no-migration-required"' "$state/backup-state.json" > /dev/null; then
      return 0
    fi
    execution_status=$(jq -er '.migrationExecution.status' "$state/backup-state.json")
    [[ $execution_status != failed && $execution_status != uncertain ]] \
      || die "candidate migration entered the guarded $execution_status state"
    run_logged "$work/logs/migration-status-$iteration.log" lifecycle "$candidate_worktree" true \
      release-migration-status "$values" "$state" "$candidate"
    sleep 10
  done
  die 'sequential candidate migration exceeded its manifest-derived bounded wait; inspect retained state'
}

successful_migration_outcome_is_valid() {
  local state=$1 expected_candidate=$2
  jq -e --arg candidate "$expected_candidate" '
    .migrationResult.artifact == $candidate
    and (.migrationResult.outcome == "no-migration-required"
      or .migrationResult.outcome == "migration-succeeded")
    and (.migrationExecution.versions | type == "array" and length > 0)
    and all(.migrationExecution.versions[];
      .currentVersion == .requiredVersion)
  ' "$state" > /dev/null
}

complete_recovery_state_is_verified() {
  local state=$1 expected_candidate=$2 expected_backup_id=$3
  jq -e --arg candidate "$expected_candidate" --arg backupId "$expected_backup_id" '
    .status == "recovered" and .phase == "migration-recovered"
    and .migrationRecovery.status == "verified"
    and .migrationRecovery.candidateAborted == true
    and .migrationRecovery.abortedCandidate == $candidate
    and .backupVerification.backupId == $backupId
  ' "$state" > /dev/null
}

delete_scenario_cluster() {
  local label=$1
  phase="$label-delete-rehearsal-cluster"
  if ! lifecycle "$cluster_driver" false delete "$cluster_values" "DELETE-$cluster-AND-ALL-DATA" \
    > "$work/logs/$label-cluster-delete.log" 2>&1; then
    cleanup_status=cleanup-failed
    rehearsal_status=cleanup-failed
    failure_reason="could not delete owned rehearsal cluster $cluster"
    printf 'Upgrade rehearsal: %s\n' "$failure_reason" >&2
    return 1
  fi
  cluster_created=false
  deleted_clusters+=("$cluster")
  cluster=''
  mark
}

capture_post_release_backup() {
  local label=$1 candidate_values=$2 state=$3 package_id=$4
  local package_manifest package_archive
  phase=post-release-backup-capture
  run_logged "$work/logs/post-release-website-result.log" lifecycle "$candidate_worktree" true \
    release-website-result "$candidate_values" "$state" "$candidate" passed \
    'Local rehearsal smoke checks passed' "WEBSITE-$package_id-passed"
  run_logged "$work/logs/post-release-capture.log" lifecycle "$candidate_worktree" true \
    release-backup-capture "$candidate_values" "$state" "$candidate"
  post_backup_id=$(jq -er '.postReleaseBackup.backupId |
    select(type == "string" and test("^backup-[0-9]+-[0-9]+$"))' "$state/backup-state.json") \
    || die 'post-release capture did not record a valid backup ID'
  mark
  phase=post-release-backup-upload
  post_backup_upload_status=failed
  run_logged "$work/logs/post-release-upload.log" python3 "$upload" release-upload \
    --config "$work/$label-backup-config.json"
  post_backup_upload_status=$(jq -er '.status' "$work/uploader/$label/status.json")
  jq -e --arg id "$post_backup_id" \
    '.status == "verified-upload" and .backupId == $id' "$work/uploader/$label/status.json" > /dev/null \
    || die 'post-release backup was not verified-upload for the captured backup ID'
  jq -e --arg id "$post_backup_id" \
    '.backupId == $id' "$work/uploader/$label/baseline.json" > /dev/null \
    || die 'post-release upload baseline does not identify the captured backup'
  package_manifest=$(jq -er .manifest "$work/uploader/$label/baseline.json")
  package_archive=$(jq -er .archive "$work/uploader/$label/baseline.json")
  package_manifest="$fake_remote/recipe-db-backups/issue-251-$run_id-$label/$package_manifest"
  package_archive="$fake_remote/recipe-db-backups/issue-251-$run_id-$label/$package_archive"
  mark
  phase=post-release-backup-validation
  jq -e --arg release "$candidate" --arg revision "$candidate_revision" \
    '.source.artifact == $release and .source.revision == $revision' "$package_manifest" > /dev/null \
    || die 'post-release package does not identify the candidate release'
  jq -e --argjson actual "$actual_versions" --argjson backup "$(backup_storage_versions_from_manifest "$package_manifest")" '
    ($actual | length) > 0
    and ([ $actual[] | {service,version:.currentVersion} ] | sort_by(.service)) == $backup
  ' > /dev/null <<< '{}' || die 'post-release package storage versions do not match the migrated candidate'
  application_project_metadata_to_jsonl "$candidate_worktree" "$work/post-release-projects.jsonl"
  run_logged "$work/logs/post-release-package-validation.log" python3 "$validator" \
    "$package_manifest" "$package_archive" "$work/post-release-validated-package" \
    "$work/post-release-projects.jsonl" "$post_backup_id"
  mark
}

run_scenario() {
  local label=$1 source_values=$2 candidate_values=$3
  local state package_id smoke_script_backup
  local package_manifest package_archive migration_digest migration_image job lease transition
  state="$work/state/$label"
  if [[ $label == successful-upgrade ]]; then
    mkdir -m 700 -p -- "$work/uploader/$label"
    state="$work/uploader/$label/maintenance"
  fi
  take_sample "$source_values"

  phase="$label-capture-maintenance-snapshot"
  run_logged "$work/logs/$label-maintenance-enter.log" lifecycle "$source_worktree" false \
    backup-enter "$source_values" "$source_release" "$state"
  run_logged "$work/logs/$label-maintenance-capture.log" lifecycle "$source_worktree" false \
    backup-capture "$source_values" "$state"
  [[ -s $state/manifest.json ]] || die "$label maintenance snapshot has no complete manifest"
  prepare_fake_upload "$label" "$state"
  source_package_status=$(jq -r '.status' "$work/uploader/$label/status.json")
  mark

  phase="$label-stage-candidate"
  package_id=$(jq -er .backupId "$work/uploader/$label/baseline.json")
  run_logged "$work/logs/$label-stage.log" lifecycle "$candidate_worktree" true \
    release-stage "$candidate_values" "$state" "$candidate" verified-upload \
    "VERIFIED-$package_id-verified-upload"
  jq -e --arg candidate "$candidate" \
    '.status == "candidate-staged" and .phase == "candidate-staged"
      and .candidate.artifact == $candidate' "$state/backup-state.json" > /dev/null \
    || die "$label candidate staging state does not match the immutable candidate"
  lifecycle "$candidate_worktree" false kubectl "$candidate_values" get deployments -o json \
    > "$work/$label-staged-deployments.json"
  jq -e 'all(.items[]; (.spec.replicas // 0) == 0 and (.status.replicas // 0) == 0)' \
    "$work/$label-staged-deployments.json" > /dev/null \
    || die "$label candidate staging left a workload running"
  mark

  if [[ $label == successful-upgrade ]]; then
    phase=successful-upgrade-sequential-migration
    run_logged "$work/logs/success-migration-plan.log" lifecycle "$candidate_worktree" true \
      release-migration-plan "$candidate_values" "$state" "$candidate"
    run_migration_sequence "$candidate_values" "$state"
    successful_migration_outcome_is_valid "$state/backup-state.json" "$candidate" \
      || die 'candidate migration outcome was not explicitly verified against actual storage markers'
    migration_outcome=$(jq -er '.migrationResult.outcome' "$state/backup-state.json")
    actual_versions=$(jq -c '.migrationExecution.versions' "$state/backup-state.json")
    mark
    phase=successful-upgrade-start-and-reopen-local-route
    run_logged "$work/logs/success-start.log" lifecycle "$candidate_worktree" true \
      release-start "$candidate_values" "$state" "$candidate"
    jq -e '.status == "release-ready" and .phase == "ready"' "$state/backup-state.json" \
      > /dev/null || die 'candidate did not reach guarded release-ready state'
    run_logged "$work/logs/success-reopen.log" lifecycle "$candidate_worktree" true \
      release-reopen "$candidate_values" "$state" "$candidate" "OPEN-$package_id"
    verify_sample "$candidate_values" successful-upgrade
    smoke_script_backup="$work/$label-smoke-script.original"
    cp --preserve=mode "$candidate_worktree/.scripts/smoke-production-k3d.sh" \
      "$smoke_script_backup"
    # Use the current harness without leaving the pinned candidate worktree dirty.
    if ! cp --preserve=mode "$root/.scripts/smoke-production-k3d.sh" \
      "$candidate_worktree/.scripts/smoke-production-k3d.sh"; then
      cp --preserve=mode "$smoke_script_backup" \
        "$candidate_worktree/.scripts/smoke-production-k3d.sh" \
        || die 'could not restore the pinned candidate smoke harness'
      die 'could not stage the current smoke harness in the candidate worktree'
    fi
    if ! run_logged "$work/logs/success-smoke.log" \
      bash -c 'cd "$1" && mise run --raw production-smoke "$2" "$3" "$4" "$5" --release-state "$6"' \
      _ "$candidate_worktree" "$candidate_values" "$candidate" "$owner_token" \
      "$work/success-smoke-result.json" "$state"; then
      cp --preserve=mode "$smoke_script_backup" \
        "$candidate_worktree/.scripts/smoke-production-k3d.sh" \
        || die 'could not restore the pinned candidate smoke harness after failure'
      rm -f -- "$smoke_script_backup"
      return 1
    fi
    cp --preserve=mode "$smoke_script_backup" \
      "$candidate_worktree/.scripts/smoke-production-k3d.sh" \
      || die 'could not restore the pinned candidate smoke harness'
    rm -f -- "$smoke_script_backup"
    jq -e --arg artifact "$candidate" \
      '.success == true and .artifact == $artifact' "$work/success-smoke-result.json" > /dev/null \
      || die 'local candidate route and production smoke checks did not pass'
    verify_sample "$candidate_values" successful-upgrade-after-smoke
    jq -e '(.migrationResult.outcome == "no-migration-required"
      or .migrationResult.outcome == "migration-succeeded")
      and .status == "access-open" and .phase == "operator-reopened"' \
      "$state/backup-state.json" > /dev/null \
      || die 'successful local route checks changed the recorded release outcome'
    success_upgrade_status=passed
    mark
    capture_post_release_backup "$label" "$candidate_values" "$state" "$package_id"
  else
    phase=injected-uncertain-migration-and-complete-recovery
    run_logged "$work/logs/failure-migration-plan.log" lifecycle "$candidate_worktree" true \
      release-migration-plan "$candidate_values" "$state" "$candidate"
    if ((candidate_migration_count > 0)); then
      migration_image=$(jq -er '.migrations[0].image' "$work/candidate-artifact/release.json")
      migration_digest=${migration_image##*@sha256:}
      job="migration-${candidate_revision:0:12}-${migration_digest:24:40}"
      transition=$(jq -c --arg job "$job" '.migrations[0] + {job:$job}' \
        "$work/candidate-artifact/release.json")
    else
      migration_digest=$(printf '%064d' 0 | tr 0 a)
      migration_image="ghcr.io/dhhyi/recipe-db-migrations@sha256:$migration_digest"
      job="migration-${candidate_revision:0:12}-${migration_digest:24:40}"
      transition=$(jq -nc --arg image "$migration_image" --arg job "$job" \
        '{service:"recipes",fromVersion:1,toVersion:2,timeoutSeconds:1,image:$image,job:$job}')
    fi
    jq --arg candidate "$candidate" --arg revision "$candidate_revision" \
      --argjson transition "$transition" \
      --arg plannedAt "$(date -u +%FT%TZ)" \
      '
      .migrationExecution={candidate:$candidate,revision:$revision,plannedAt:$plannedAt,
        versions:[],currentIndex:0,status:"activation-intent",
        transitions:[$transition + {status:"activation-intent"}]}
    ' "$state/backup-state.json" > "$state/backup-state.next"
    mv "$state/backup-state.next" "$state/backup-state.json"
    lease="$work/$label-deploy-lease.json"
    lifecycle "$candidate_worktree" false kubectl "$candidate_values" \
      --namespace kube-system get lease recipe-db-deploy -o json > "$lease"
    jq -e --arg holder "$package_id" --arg source "$source_release" '
      .spec.holderIdentity == $holder
      and .metadata.annotations["recipe-db/release"] == $source
      and .metadata.annotations["recipe-db/phase"] == "candidate-staged"
    ' "$lease" > /dev/null || die 'failure injection found an unexpected operation Lease'
    if ((candidate_migration_count > 0)); then
      lifecycle "$candidate_worktree" false kubectl "$candidate_values" get job "$job" -o json \
        > "$work/$label-migration-job.json"
      jq -e --arg image "$migration_image" --arg revision "$candidate_revision" '
        .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
        and .metadata.labels["recipe-db/revision"] == $revision
        and .metadata.labels["recipe-db/migration"] == "staged"
        and .spec.suspend == true and (.status.active // 0) == 0
        and .spec.template.spec.containers[0].image == $image
      ' "$work/$label-migration-job.json" > /dev/null \
        || die 'failure injection refused a non-suspended or mismatched candidate Job'
      lifecycle "$candidate_worktree" false kubectl "$candidate_values" \
        delete job "$job" --wait=true --timeout=60s \
        > "$work/logs/$label-migration-job-delete.log" 2>&1
    fi
    jq '.metadata.annotations["recipe-db/phase"]="migration-activation-intent"' \
      "$lease" > "$lease.next"
    mv "$lease.next" "$lease"
    lifecycle "$candidate_worktree" false kubectl "$candidate_values" \
      --namespace kube-system replace -f "$lease" > "$work/logs/$label-lease-update.log" 2>&1
    if lifecycle "$candidate_worktree" true release-migration-next \
      "$candidate_values" "$state" "$candidate" \
      > "$work/logs/failure-migration-next.log" 2>&1; then
      die 'injected missing migration Job was not recorded as uncertain'
    fi
    jq -e '.status == "recovery-required" and .phase == "migration-uncertain"
      and .migrationExecution.status == "uncertain"' "$state/backup-state.json" \
      > /dev/null || die 'missing migration Job did not reach the guarded uncertain state'
    lifecycle "$candidate_worktree" false kubectl "$candidate_values" \
      --namespace kube-system get lease recipe-db-deploy -o json > "$lease"
    jq -e '.metadata.annotations["recipe-db/phase"] == "migration-uncertain"' \
      "$lease" > /dev/null || die 'uncertain migration did not retain the operation Lease'
    failure_recovery_status=in-progress
    package_manifest=$(jq -er .manifest "$work/uploader/$label/baseline.json")
    package_archive=$(jq -er .archive "$work/uploader/$label/baseline.json")
    package_manifest="$work/packages/$label/$package_manifest"
    package_archive="$work/packages/$label/$package_archive"
    run_logged "$work/logs/failure-migration-recover.log" lifecycle "$candidate_worktree" true \
      release-migration-recover "$candidate_values" "$state" "$candidate" \
      "$package_manifest" "$package_archive" "$package_id" \
      "CLEAR-AND-RESTORE-$package_id-$candidate_revision-ATTEMPT-1"
    complete_recovery_state_is_verified "$state/backup-state.json" "$candidate" "$package_id" \
      || die 'complete recovery did not verify restoration or abort the candidate'
    failure_recovery_status=passed
    mark
  fi

}

run_rehearsal_scenarios() {
  local source_values=$1 candidate_values=$2 values=$3 restore_values=$4 restore_cluster_values=$5 package_id
  phase=restore-production-backup
  new_cluster r "$values"
  run_logged "$work/logs/restore.log" lifecycle "$root" true \
    restore "$source_values" "$manifest" "$archive" "$backup_id" "$work/state/restore" "RESTORE-$backup_id"
  mark

  run_scenario failure-recovery "$source_values" "$candidate_values"
  phase=reopen-recovered-source
  package_id=$(jq -er .backupId "$work/state/failure-recovery/backup-state.json")
  run_logged "$work/logs/recovery-reopen.log" lifecycle "$root" true \
    release-recovery-reopen "$source_values" "$work/state/failure-recovery" "$source_release" \
    "OPEN-RECOVERY-$package_id-$source_revision"
  verify_sample "$source_values" recovered-source
  mark

  run_scenario successful-upgrade "$source_values" "$candidate_values"
  delete_scenario_cluster complete || die "$failure_reason"

  phase=post-release-backup-restore
  post_backup_restore_status=failed
  new_cluster p "$restore_cluster_values"
  package_id=$(jq -er .backupId "$work/uploader/successful-upgrade/baseline.json")
  local remote="$fake_remote/recipe-db-backups/issue-251-$run_id-successful-upgrade"
  local post_manifest post_archive
  post_manifest="$remote/$(jq -er .manifest "$work/uploader/successful-upgrade/baseline.json")"
  post_archive="$remote/$(jq -er .archive "$work/uploader/successful-upgrade/baseline.json")"
  run_logged "$work/logs/post-release-restore.log" lifecycle "$root" true \
    restore "$restore_values" "$post_manifest" "$post_archive" "$package_id" \
    "$work/state/post-release-restore" "RESTORE-$package_id"
  verify_sample "$restore_values" post-release-restore
  post_backup_restore_status=passed
  mark
  delete_scenario_cluster post-release || die "$failure_reason"
}

phase=release-and-package-preflight
host_cpu_count=$(getconf _NPROCESSORS_ONLN)
docker_memory_bytes=$(docker info --format '{{.MemTotal}}')
available_disk_bytes_before=$(df -B1 --output=avail "$result_directory" | awk 'NR == 2 {print $1}')
[[ $docker_memory_bytes =~ ^[0-9]+$ && $docker_memory_bytes -gt 8589934592 ]] \
  || die 'Docker must have more than 8 GiB RAM for this rehearsal'
[[ $available_disk_bytes_before =~ ^[0-9]+$ && $available_disk_bytes_before -gt 0 ]] \
  || die 'could not measure free space on the private rehearsal filesystem'
kubeconfig="$HOME/.config/recipe-db/kubeconfig/pi.yaml"
check_private_file "$kubeconfig"
deployment_values="$HOME/.config/recipe-db/deployment/pi-values.yaml"
check_private_file "$deployment_values"
yq -o=json eval-all '[.]' "$deployment_values" > "$work/pi-values-documents.json"
jq -e 'length == 1 and .[0].target == "pi"
  and .[0].cluster == "recipe-db-pi"
  and .[0].context == "recipe-db-pi"
  and .[0].namespace == "recipe-db"' "$work/pi-values-documents.json" > /dev/null \
  || die 'private deployment values are not the documented Pi production configuration'
[[ $(KUBECONFIG="$kubeconfig" kubectl config current-context) == recipe-db-pi ]] \
  || die 'documented production kubeconfig is not on the recipe-db-pi context'
pi_api_server=$(KUBECONFIG="$kubeconfig" kubectl config view --minify \
  -o 'jsonpath={.clusters[0].cluster.server}')
[[ $pi_api_server == https://127.0.0.1:6445 ]] \
  || die 'Pi kubeconfig does not use the documented loopback-only API tunnel endpoint'
KUBECONFIG="$kubeconfig" kubectl --context recipe-db-pi --namespace recipe-db \
  --request-timeout=10s get configmap recipe-db-release -o json \
  > "$work/deployed-release.json" 2> "$work/logs/deployed-release-read.log" \
  || die 'could not read the deployed release identity; establish the documented Pi API connection and retry'
deployed_release=$(jq -er '.data.artifact |
  select(test("^ghcr[.]io/dhhyi/recipe-db-releases@sha256:[a-f0-9]{64}$"))' \
  "$work/deployed-release.json") || die 'deployed release identity is missing or malformed'
deployed_revision=$(jq -er '.data.revision |
  select(type == "string" and test("^[a-f0-9]{40}$"))' "$work/deployed-release.json") \
  || die 'deployed revision identity is missing or malformed'
jq -e --arg release "$source_release" --arg revision "$source_revision" '
  .metadata.namespace == "recipe-db"
  and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
  and .data.artifact == $release and .data.revision == $revision
' "$work/deployed-release.json" > /dev/null \
  || die 'latest backup release/revision does not match the currently deployed release; stop for investigation'
KUBECONFIG="$kubeconfig" kubectl --context recipe-db-pi --namespace recipe-db \
  --request-timeout=10s get deployments -o json \
  > "$work/deployed-workloads.json" 2> "$work/logs/deployed-workloads-read.log" \
  || die 'could not read deployed workload identities from the Pi'
jq -e --arg release "$source_release" '
  (.items | length) > 0
  and all(.items[];
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .spec.template.metadata.annotations["recipe-db/release"] == $release)
' "$work/deployed-workloads.json" > /dev/null \
  || die 'Pi workloads do not all match the release recorded by the latest backup'
deployed_identity_verified=true
mark
run_logged "$work/logs/candidate-manifest.log" oras manifest fetch "$candidate" \
  --output "$work/candidate-manifest.json"
candidate_revision=$(jq -er '.annotations["org.opencontainers.image.revision"] |
  select(test("^[a-f0-9]{40}$"))' "$work/candidate-manifest.json") \
  || die 'candidate artifact does not carry an immutable source revision'
git -C "$root" cat-file -e "$candidate_revision^{commit}" 2> /dev/null \
  || die 'candidate revision is not available in this checkout; fetch it before rehearsing'
[[ $candidate_revision != "$source_revision" ]] || die 'candidate revision matches the backup source revision'
run_logged "$work/logs/candidate-pull.log" oras pull "$candidate" --output "$work/candidate-artifact"
jq -e --arg revision "$candidate_revision" '
  .schemaVersion == 2 and .revision == $revision and (.migrations | type == "array")
' "$work/candidate-artifact/release.json" > /dev/null \
  || die 'candidate release metadata does not match the immutable artifact'
candidate_migrations=$(jq -c '.migrations' "$work/candidate-artifact/release.json")
candidate_migration_count=$(jq 'length' <<< "$candidate_migrations")
candidate_images=$(jq -c '.images' "$work/candidate-artifact/release.json")
[[ $backup_archive_sha == "$(sha256sum "$archive" | cut -d ' ' -f1)" ]] \
  || die 'private backup archive hash differs from its manifest'
mark

phase=private-release-worktrees
source_worktree="$work/source"
candidate_worktree="$work/candidate"
create_worktree "$source_revision" "$source_worktree" source
create_worktree "$candidate_revision" "$candidate_worktree" candidate
validate_release_inventory "$candidate_worktree" "$work/candidate-artifact/release.json" \
  "$candidate_revision" 2 candidate
application_project_metadata_to_jsonl "$source_worktree" "$work/source-projects.jsonl"
phase=source-artifact-and-storage-preflight
run_logged "$work/logs/source-manifest.log" oras manifest fetch "$source_release" \
  --output "$work/source-manifest.json"
jq -e --arg revision "$source_revision" \
  '.annotations["org.opencontainers.image.revision"] == $revision' \
  "$work/source-manifest.json" > /dev/null \
  || die 'source release artifact does not carry the backup revision'
run_logged "$work/logs/source-pull.log" oras pull "$source_release" \
  --output "$work/source-artifact"
source_schema_version=$(jq -er '.schemaVersion | select(. == 1 or . == 2)' \
  "$work/source-artifact/release.json") \
  || die 'source release inventory uses an unsupported schema version'
jq -e --arg revision "$source_revision" --argjson schema "$source_schema_version" '
  .schemaVersion == $schema and .revision == $revision and (.images | type == "object")
' "$work/source-artifact/release.json" > /dev/null \
  || die 'source release inventory does not match the backup revision'
validate_release_inventory "$source_worktree" "$work/source-artifact/release.json" \
  "$source_revision" "$source_schema_version" source
run_logged "$work/logs/source-render.log" \
  bash -c 'cd "$1" && mise run --raw production-k3d render "$2" "$3" > "$4"' \
  _ "$source_worktree" "$deployment_values" "$source_release" "$work/source-rendered.yml"
deployed_release_images_match_inventory \
  "$work/deployed-workloads.json" "$work/source-artifact/release.json" \
  || die 'live Pi workloads do not match the source release image inventory'
workload_image_inventory_matches_rendered \
  "$work/deployed-workloads.json" "$work/source-rendered.yml" \
  || die 'live Pi Deployment containers do not exactly match the source-rendered workload inventory'
deployed_image_inventory_verified=true
source_storage_versions=$(jq -sc '
  [.[] | select(.storageVersion != null)
    | {service:.name,version:.storageVersion.value}] | sort_by(.service)
' "$work/source-projects.jsonl")
backup_storage_versions=$(backup_storage_versions_from_manifest "$manifest")
jq -e --argjson source "$source_storage_versions" \
  --argjson backup "$backup_storage_versions" '
  ($source | length) > 0 and $backup == $source
' "$manifest" > /dev/null \
  || die 'backup storage-version markers do not match the previous release requirements'
backup_storage_versions_match_source=true
while IFS= read -r service; do
  jq -e --arg service "$service" --arg release "$source_release" '
    [.items[] | select(.metadata.name == $service)] as $found |
    ($found | length) == 1
    and ($found[0].spec.replicas // 0) > 0
    and ($found[0].status.observedGeneration // 0) >= $found[0].metadata.generation
    and ($found[0].status.updatedReplicas // 0) == $found[0].spec.replicas
    and ($found[0].status.readyReplicas // 0) == $found[0].spec.replicas
    and ($found[0].status.availableReplicas // 0) == $found[0].spec.replicas
    and $found[0].spec.template.metadata.annotations["recipe-db/release"] == $release
  ' "$work/deployed-workloads.json" > /dev/null \
    || die "live stateful workload $service is not ready on the backup source release"
done < <(jq -r '.[].service' <<< "$source_storage_versions")
live_storage_workloads_ready=true
mark
run_logged "$work/logs/production-package-validation.log" python3 "$validator" \
  "$manifest" "$archive" "$work/production-package-validation" "$work/source-projects.jsonl" "$backup_id"
input_package_validation_status=passed
mark

phase=synthetic-local-credentials
openssl rand -base64 32 | tr -d '\n' > "$owner_token"
jq -n --rawfile token "$owner_token" \
  '{anonymous:{role:"anonymous"},tokens:[{id:"issue-251-owner",secret:($token|rtrimstr("\n")),role:"owner"}],googleAccounts:{}}' \
  > "$accounts_file"
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$owner_token")" > "$curl_config"
chmod 600 "$owner_token" "$accounts_file" "$curl_config"
mark

phase=ports-and-values-preflight
python3 - "$http_port" "$api_port" << 'PY'
import socket
import sys

for value in sys.argv[1:]:
    with socket.socket() as listener:
        try:
            listener.bind(("127.0.0.1", int(value)))
        except OSError:
            print("selected rehearsal port is unavailable", file=sys.stderr)
            raise SystemExit(1)
PY
success_source_values="$work/success-source-values.yaml"
success_candidate_values="$work/success-candidate-values.yaml"
success_cluster_values="$work/success-cluster-values.yaml"
post_restore_values="$work/post-restore-values.yaml"
post_restore_cluster_values="$work/post-restore-cluster-values.yaml"
write_values "$(rehearsal_cluster_name "$run_id" r)" \
  "$http_port" "$success_source_values"
write_cluster_values "$success_source_values" "$success_cluster_values"
write_values "$(rehearsal_cluster_name "$run_id" r)" \
  "$http_port" "$success_candidate_values"
write_values "$(rehearsal_cluster_name "$run_id" p)" \
  "$http_port" "$post_restore_values"
write_cluster_values "$post_restore_values" "$post_restore_cluster_values"
mark

run_rehearsal_scenarios "$success_source_values" "$success_candidate_values" \
  "$success_cluster_values" "$post_restore_values" "$post_restore_cluster_values"

phase=complete
available_disk_bytes_after=$(df -B1 --output=avail "$result_directory" | awk 'NR == 2 {print $1}')
mark
exit 0
