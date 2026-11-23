#!/usr/bin/env bats

# Bats fixtures invoke sourced helpers indirectly, generate literal shell expressions, and isolate tests in subshells.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2218,SC2329

load test_helper

setup() {
  setup_fixture production-upgrade-rehearsal-k3d.sh
  chmod 700 "$BATS_TEST_TMPDIR"
  chmod 700 "$FIXTURE_ROOT"
  mkdir -p .scripts/lib
  mkdir -p .scripts/tests/fixtures
  mkdir -p deploy
  chmod 700 .scripts/lib
  cp "$BATS_TEST_DIRNAME/../lib/rehearsal-k3d.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../lib/project-metadata.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/fixtures/rclone-local" .scripts/tests/fixtures/
  cp "$BATS_TEST_DIRNAME/../../deploy/local.yaml" deploy/
  cp "$BATS_TEST_DIRNAME/../../deploy/pi.yaml" deploy/pi-values.yaml
  git init -q
  git config user.name "Rehearsal Test"
  git config user.email "rehearsal@example.invalid"
  git add .scripts
  git commit -qm "Test rehearsal fixture"

  export HOME="$FIXTURE_ROOT/home"
  mkdir -p "$HOME/.config/recipe-db/backup" "$HOME/.config/recipe-db/kubeconfig" \
    "$HOME/.config/recipe-db/deployment"
  cp deploy/pi-values.yaml "$HOME/.config/recipe-db/deployment/pi-values.yaml"
  chmod 700 "$HOME" "$HOME/.config/recipe-db/backup" "$HOME/.config/recipe-db/kubeconfig" \
    "$HOME/.config/recipe-db/deployment"
  export PACKAGE_DIRECTORY="$BATS_TEST_TMPDIR"
  export ARCHIVE="$PACKAGE_DIRECTORY/backup-123-456.tar.gz"
  export MANIFEST="$PACKAGE_DIRECTORY/backup-123-456.manifest.json"
  export SOURCE_RELEASE="ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  export CANDIDATE_RELEASE="ghcr.io/dhhyi/recipe-db-releases@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  export SOURCE_REVISION
  SOURCE_REVISION=$(git rev-parse HEAD)
  export ARCHIVE_SHA
  ARCHIVE_SHA=$(printf '%064d' 0 | tr 0 a)
  printf 'private test archive\n' > "$ARCHIVE"
  jq -n --arg release "$SOURCE_RELEASE" --arg revision "$SOURCE_REVISION" \
    --arg sha "$ARCHIVE_SHA" '{
      backupId:"backup-123-456",
      capturedAt:"2026-11-12T18:26:10Z",
      source:{target:"pi",cluster:"recipe-db-pi",context:"recipe-db-pi",
        namespace:"recipe-db",artifact:$release,revision:$revision},
      archive:{sha256:$sha}
    }' > "$MANIFEST"
  chmod 600 "$ARCHIVE" "$MANIFEST"
  printf '%s\n' "$SOURCE_RELEASE" > "$HOME/.config/recipe-db/backup/backup-release-ref"
  chmod 600 "$HOME/.config/recipe-db/backup/backup-release-ref"
  chmod 600 "$HOME/.config/recipe-db/deployment/pi-values.yaml"
  printf 'test kubeconfig\n' > "$HOME/.config/recipe-db/kubeconfig/pi.yaml"
  chmod 600 "$HOME/.config/recipe-db/kubeconfig/pi.yaml"
  export RESULT_DIRECTORY="$BATS_TEST_TMPDIR/result"
  export MOCK_KUBECTL_LOG="$FIXTURE_ROOT/kubectl.log"
  export MOCK_CONFIGMAP="$FIXTURE_ROOT/deployed-release.json"
  export MOCK_API_SERVER="https://127.0.0.1:6445"
  mkdir -m 700 bin
  export PATH="$FIXTURE_ROOT/bin:$PATH"
  for tool in curl k3d mise oras python3; do
    printf '#!/bin/sh\nexit 0\n' > "bin/$tool"
    chmod 700 "bin/$tool"
  done
  cat > bin/yq << 'SH'
#!/bin/sh
printf '[{"target":"pi","cluster":"recipe-db-pi","context":"recipe-db-pi","namespace":"recipe-db"}]\n'
SH
  chmod 700 bin/yq
  printf '#!/bin/sh\nprintf "deadbeef\\n"\n' > bin/openssl
  chmod 700 bin/openssl
  printf '#!/bin/sh\necho 17179869184\n' > bin/docker
  chmod 700 bin/docker
  cat > bin/kubectl << 'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_KUBECTL_LOG"
if [[ ${1-} == config && ${2-} == current-context ]]; then
  printf 'recipe-db-pi\n'
elif [[ ${1-} == config && ${2-} == view ]]; then
  printf '%s\n' "$MOCK_API_SERVER"
elif [[ " $* " == *" get configmap recipe-db-release "* ]]; then
  cat "$MOCK_CONFIGMAP"
else
  printf 'Unexpected kubectl call in preflight test\n' >&2
  exit 97
fi
SH
  chmod 700 bin/kubectl
  jq -n --arg release "$CANDIDATE_RELEASE" --arg revision "$SOURCE_REVISION" '{
    metadata:{namespace:"recipe-db",labels:{"app.kubernetes.io/part-of":"recipe-db"}},
    data:{artifact:$release,revision:$revision}
  }' > "$MOCK_CONFIGMAP"
}

load_scenario_functions() {
  local function_name
  : > "$FIXTURE_ROOT/scenario-functions.sh"
  for function_name in validate_release_inventory backup_storage_versions_from_manifest \
    source_storage_versions_from_projects \
    rehearsal_cluster_name \
    deployed_release_images_match_inventory \
    workload_image_inventory_matches_rendered verify_sample \
    run_migration_sequence successful_migration_outcome_is_valid \
    complete_recovery_state_is_verified delete_scenario_cluster capture_post_release_backup run_scenario \
    run_rehearsal_scenarios; do
    sed -n "/^${function_name}() {/,/^}/p" \
      .scripts/production-upgrade-rehearsal-k3d.sh >> "$FIXTURE_ROOT/scenario-functions.sh"
  done
  # shellcheck source=/dev/null
  source "$FIXTURE_ROOT/scenario-functions.sh"
}

@test "candidate backup captures uploads and validates exact migrated identity and versions" {
  local work="$FIXTURE_ROOT/work" fake_remote="$FIXTURE_ROOT/remote" run_id=123
  local root="$FIXTURE_ROOT" cluster_values=cluster.yaml
  local candidate="$CANDIDATE_RELEASE" candidate_revision="$SOURCE_REVISION"
  local candidate_worktree="$FIXTURE_ROOT/candidate" upload=uploader validator=validator
  local actual_versions='[{"service":"recipes","currentVersion":2,"requiredVersion":2}]'
  local phase='' post_backup_id='' post_backup_upload_status=not-run
  local mock_status=verified-upload
  local state="$work/uploader/successful-upgrade/maintenance"
  local remote="$fake_remote/recipe-db-backups/issue-251-$run_id-successful-upgrade"
  mkdir -p "$state" "$work/logs" "$remote"
  printf '{}\n' > "$work/successful-upgrade-backup-config.json"
  printf '{}\n' > "$state/backup-state.json"
  load_scenario_functions
  mark() { :; }
  die() {
    printf '%s\n' "$*" >&2
    exit 1
  }
  lifecycle() {
    printf '%s\n' "$*" >> "$work/calls"
  }
  application_project_metadata_to_jsonl() { printf '{}\n' > "$2"; }
  run_logged() {
    local log=$1
    shift
    if [[ $1 == python3 && $2 == -c ]]; then
      jq '.postReleaseBackup={backupId:"backup-123-456"}' "$state/backup-state.json" > "$state/next"
      mv "$state/next" "$state/backup-state.json"
      jq -n --arg status "$mock_status" \
        '{status:$status,backupId:"backup-123-456"}' > "$work/uploader/successful-upgrade/status.json"
      printf '{"backupId":"backup-123-456","manifest":"post.json","archive":"post.tar.gz"}\n' > "$work/uploader/successful-upgrade/baseline.json"
      jq -n --arg candidate "$candidate" --arg revision "$candidate_revision" '{
        source:{artifact:$candidate,revision:$revision},
        snapshotManifest:{inventory:[{service:"recipes",files:[{path:"storage-version",storageVersion:2}]}]}
      }' > "$remote/post.json"
      : > "$remote/post.tar.gz"
    elif [[ $1 == python3 && $2 == "$validator" ]]; then
      printf 'validate %s\n' "$*" >> "$work/calls"
    else
      "$@" > "$log"
    fi
  }
  capture_post_release_backup successful-upgrade candidate.yaml "$state" backup-111-222
  [ "$post_backup_id" = backup-123-456 ]
  [ "$post_backup_upload_status" = verified-upload ]
  grep -Fq 'release-website-result candidate.yaml' "$work/calls"
  grep -Fq 'release-backup-capture candidate.yaml' "$work/post-release-capture-command"
  grep -Fq "validate python3 validator $remote/post.json $remote/post.tar.gz" "$work/calls"
  mock_status=verified-unchanged
  run capture_post_release_backup successful-upgrade candidate.yaml "$state" backup-111-222
  [ "$status" -ne 0 ]
  [[ $output == *'not verified-upload'* ]]
}

@test "normal uploader dispatch invokes local capture adapter and uploads candidate snapshot" {
  local root="$FIXTURE_ROOT" work="$FIXTURE_ROOT/work" fake_remote="$FIXTURE_ROOT/remote"
  local run_id=123 cluster_values=cluster.yaml candidate="$CANDIDATE_RELEASE"
  local candidate_revision="$SOURCE_REVISION" candidate_worktree="$FIXTURE_ROOT/candidate"
  local upload="$BATS_TEST_DIRNAME/../../provisioning/files/backup-upload.py" validator=validator
  local actual_versions='[{"service":"recipes","currentVersion":2,"requiredVersion":2}]'
  local phase='' post_backup_id='' post_backup_upload_status=not-run
  local state="$work/uploader/successful-upgrade/maintenance"
  export DOCKER_HOST='unix:///tmp/rehearsal-test.sock' DOCKER_CONTEXT='rehearsal-test'
  export DOCKER_CONFIG="$FIXTURE_ROOT/docker config" XDG_RUNTIME_DIR="$FIXTURE_ROOT/runtime"
  mkdir -p "$state" "$work/logs" "$work/staging" "$fake_remote" "$work/fixture"
  rm "$FIXTURE_ROOT/bin/python3"
  cp "$BATS_TEST_DIRNAME/fixtures/rclone-local" "$FIXTURE_ROOT/bin/rclone"
  chmod 700 "$FIXTURE_ROOT/bin/rclone"
  export FAKE_RCLONE_ROOT="$fake_remote"
  printf '{}\n' > "$work/rclone.conf"
  chmod 600 "$work/rclone.conf"
  jq -n --arg state "$work/uploader/successful-upgrade" --arg staging "$work/staging" \
    --arg rclone "$work/rclone.conf" --arg capture "$work/unused" '{
      deploymentId:"issue-251-123-successful-upgrade",remote:"fake-e2e:recipe-db-backups",
      rcloneConfig:$rclone,stateDirectory:$state,stagingDirectory:$staging,
      captureCommand:$capture,captureTimeoutSeconds:600,maxStagingBytes:8589934592
    }' > "$work/successful-upgrade-backup-config.json"
  chmod 600 "$work/successful-upgrade-backup-config.json"
  jq -n --arg source "$SOURCE_RELEASE" --arg candidate "$candidate" --arg revision "$candidate_revision" '{
    backupId:"backup-111-222",status:"access-open",phase:"website-passed",
    source:{artifact:$source},candidate:{artifact:$candidate,revision:$revision},
    websiteCheck:{outcome:"passed"}
  }' > "$state/backup-state.json"
  python3 - "$work/fixture" "$candidate" "$candidate_revision" << 'PY'
import hashlib, io, json, pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1])
contents = {"nested/opaque.data": b"data", "storage-version": b"2\n"}
entries = []
with tarfile.open(root / "recipes.tar", "w") as archive:
    for name, data in sorted(contents.items()):
        info = tarfile.TarInfo(name)
        info.size = len(data)
        archive.addfile(info, io.BytesIO(data))
        entry = {"path": name, "sizeBytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        if name == "storage-version":
            entry["storageVersion"] = 2
        entries.append(entry)
data = (root / "recipes.tar").read_bytes()
manifest = {
    "format": "recipe-db-pvc-snapshot", "formatVersion": 1, "backupId": "backup-333-444",
    "capturedAt": "2026-11-19T12:00:00Z",
    "source": {"target": "local", "cluster": "fixture", "context": "fixture",
               "namespace": "recipe-db", "artifact": sys.argv[2], "revision": sys.argv[3]},
    "inventory": [{"service": "recipes", "role": "authoritative-read-only", "pvc": "recipes",
                   "archive": "recipes.tar", "sizeBytes": len(data), "fileCount": len(entries),
                   "sha256": hashlib.sha256(data).hexdigest(), "files": entries}],
}
(root / "manifest.json").write_text(json.dumps(manifest))
PY
  {
    printf '#!/bin/bash\nset -eu\n'
    printf '[[ $DOCKER_HOST == %q && $DOCKER_CONTEXT == %q && $DOCKER_CONFIG == %q && $XDG_RUNTIME_DIR == %q ]]\n' \
      "$DOCKER_HOST" "$DOCKER_CONTEXT" "$DOCKER_CONFIG" "$XDG_RUNTIME_DIR"
    printf 'printf "%%s\\n" "$*" >> %q\n' "$work/mise-calls"
    printf 'if [[ $4 == verify ]]; then exit 0; fi\n'
    printf '[[ $4 == --release-sources-from-git && $5 == release-backup-capture && $7 == %q && $8 == %q ]]\n' "$state" "$candidate"
    printf 'cp -a %q %q\n' "$work/fixture" "$state/post-release-backup"
    printf 'jq --arg path %q --arg artifact %q ' "$state/post-release-backup" "$candidate"
    printf '%q ' '.phase="post-release-backup-captured" | .postReleaseBackup={status:"captured",artifact:$artifact,backupId:"backup-333-444",snapshotPath:$path}'
    printf '%q > %q\n' "$state/backup-state.json" "$state/backup-state.next"
    printf 'mv %q %q\n' "$state/backup-state.next" "$state/backup-state.json"
  } > "$FIXTURE_ROOT/bin/mise"
  chmod 700 "$FIXTURE_ROOT/bin/mise"
  load_scenario_functions
  mark() { :; }
  die() {
    printf '%s\n' "$*" >&2
    return 1
  }
  lifecycle() { [[ $3 == release-website-result ]]; }
  application_project_metadata_to_jsonl() { printf '{}\n' > "$2"; }
  run_logged() {
    local log=$1
    shift
    if [[ $1 == python3 && $2 == "$validator" ]]; then
      printf 'validated %s\n' "$*" > "$log"
    else
      "$@" > "$log" 2>&1 || {
        cat "$log" >&2
        [[ ! -f $work/logs/post-release-capture.log ]] || cat "$work/logs/post-release-capture.log" >&2
        return 1
      }
    fi
  }
  capture_post_release_backup successful-upgrade candidate.yaml "$state" backup-111-222
  [ "$post_backup_id" = backup-333-444 ]
  [ "$post_backup_upload_status" = verified-upload ]
  jq -e '.captureTimeoutSeconds == 5400' "$work/successful-upgrade-backup-config.json"
  grep -Fq 'production-k3d verify cluster.yaml' "$work/mise-calls"
  grep -Fq 'release-backup-capture candidate.yaml' "$work/mise-calls"
  jq -e '.postReleaseBackup.uploadStatus == "verified-upload"' "$state/backup-state.json"
  jq -e '.status == "verified-upload" and .backupId == "backup-333-444"' \
    "$work/uploader/successful-upgrade/status.json"
}

@test "release inventory validation uses the schema-specific source CLI contract" {
  local checkout="$FIXTURE_ROOT/source-validator" release="$FIXTURE_ROOT/release.json"
  work="$FIXTURE_ROOT/work"
  mkdir -p "$checkout/.scripts" "$work/logs"
  printf '{}\n' > "$release"
  cat > "$checkout/.scripts/validate-production-release.sh" << 'SH'
#!/bin/sh
printf '%s\n' "$#" "$@" > "$VALIDATOR_ARGS_LOG"
SH
  chmod 700 "$checkout/.scripts/validate-production-release.sh"
  export VALIDATOR_ARGS_LOG="$FIXTURE_ROOT/validator-args"
  run_logged() {
    local log=$1
    shift
    "$@" > "$log" 2>&1
  }
  load_scenario_functions

  validate_release_inventory "$checkout" "$release" "$SOURCE_REVISION" 1 source
  [ "$(sed -n '1p' "$VALIDATOR_ARGS_LOG")" = 2 ]
  [ "$(sed -n '2p' "$VALIDATOR_ARGS_LOG")" = "$release" ]
  [ "$(sed -n '3p' "$VALIDATOR_ARGS_LOG")" = "$SOURCE_REVISION" ]

  validate_release_inventory "$checkout" "$release" "$SOURCE_REVISION" 2 candidate
  [ "$(sed -n '1p' "$VALIDATOR_ARGS_LOG")" = 3 ]
  [ "$(sed -n '2p' "$VALIDATOR_ARGS_LOG")" = "$release" ]
  [ "$(sed -n '3p' "$VALIDATOR_ARGS_LOG")" = "$SOURCE_REVISION" ]
  [ "$(sed -n '4p' "$VALIDATOR_ARGS_LOG")" = "$checkout" ]
}

@test "reads storage markers from the embedded snapshot manifest" {
  local manifest="$FIXTURE_ROOT/package.manifest.json" versions
  jq -n '{
    backupId:"backup-123-456",
    snapshotManifest:{inventory:[
      {service:"recipes",files:[
        {path:"storage-version",storageVersion:2},
        {path:"nested/opaque.data"}
      ]},
      {service:"images",files:[
        {path:"storage-version",storageVersion:1}
      ]}
    ]}
  }' > "$manifest"
  load_scenario_functions

  versions=$(backup_storage_versions_from_manifest "$manifest")
  [ "$versions" = '[{"service":"images","version":1},{"service":"recipes","version":2}]' ]
}

@test "historical source storage versions compare to actual backup markers" {
  local projects="$FIXTURE_ROOT/source-projects.jsonl"
  local manifest="$FIXTURE_ROOT/package.manifest.json" required actual
  load_scenario_functions
  cat > "$projects" << 'JSONL'
{"name":"recipes","storageVersion":{"value":2}}
{"name":"images","storageVersion":1}
JSONL
  jq -n '{
    backupId:"backup-123-456",
    snapshotManifest:{inventory:[
      {service:"recipes",files:[{path:"storage-version",storageVersion:2}]},
      {service:"images",files:[{path:"storage-version",storageVersion:1}]}
    ]}
  }' > "$manifest"

  required=$(source_storage_versions_from_projects "$projects")
  actual=$(backup_storage_versions_from_manifest "$manifest")
  [ "$required" = "$actual" ]
}

@test "isolated rehearsal cluster names fit k3d limits and remain suffix-distinct" {
  load_scenario_functions
  local success_cluster failure_cluster
  success_cluster=$(rehearsal_cluster_name 0123456789abcdef s)
  failure_cluster=$(rehearsal_cluster_name 0123456789abcdef f)

  [ "$success_cluster" = recipe-db-rehearsal-0123456789-s ]
  [ "$failure_cluster" = recipe-db-rehearsal-0123456789-f ]
  [ "${#success_cluster}" -eq 32 ]
  [ "${#failure_cluster}" -eq 32 ]
}

@test "live Deployment inventory rejects unaccounted regular and init containers" {
  use_mise_tools
  local work="$FIXTURE_ROOT/work" rendered="$FIXTURE_ROOT/rendered.yaml"
  local deployments="$FIXTURE_ROOT/deployments.json" changed="$FIXTURE_ROOT/changed.json"
  mkdir -p "$work"
  cat > "$rendered" << 'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: recipes
spec:
  template:
    spec:
      initContainers:
        - name: init
          image: example/init@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      containers:
        - name: recipes
          image: example/recipes@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        - name: helper
          image: example/helper@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
YAML
  yq -o=json eval-all '[select(.kind == "Deployment")]' "$rendered" \
    | jq 'map({
    name:.metadata.name,
    containers:([.spec.template.spec.containers[]? | {name,image}] | sort_by(.name)),
    initContainers:([.spec.template.spec.initContainers[]? | {name,image}] | sort_by(.name))
    }) | sort_by(.name)' > "$FIXTURE_ROOT/expected.json"
  jq -n --slurpfile inventory "$FIXTURE_ROOT/expected.json" '{
    items:[$inventory[0][] | {
      metadata:{name:.name},
      spec:{template:{spec:{
        containers:.containers,
        initContainers:.initContainers
      }}}
    }]
  }' > "$deployments"
  load_scenario_functions

  workload_image_inventory_matches_rendered "$deployments" "$rendered"
  jq '.items[0].spec.template.spec.containers +=
    [{name:"unaccounted",image:"example/unaccounted:latest"}]' "$deployments" > "$changed"
  if workload_image_inventory_matches_rendered "$changed" "$rendered"; then
    return 1
  fi
  jq '.items[0].spec.template.spec.initContainers +=
    [{name:"unaccounted",image:"example/unaccounted:latest"}]' "$deployments" > "$changed"
  if workload_image_inventory_matches_rendered "$changed" "$rendered"; then
    return 1
  fi
}

@test "application image inventory allows infrastructure Deployments" {
  local deployments="$FIXTURE_ROOT/deployments.json" release="$FIXTURE_ROOT/release.json"
  jq -n '{
    items:[
      {metadata:{name:"recipes"},spec:{template:{spec:{containers:[
        {name:"recipes",image:"ghcr.io/dhhyi/recipe-db-recipes@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
      ]}}}},
      {metadata:{name:"nats"},spec:{template:{spec:{containers:[
        {name:"nats",image:"nats:2-alpine@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
      ]}}}},
      {metadata:{name:"browse-maintenance"},spec:{template:{spec:{containers:[
        {name:"browse-maintenance",image:"nginx:stable-alpine@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}
      ]}}}}
    ]
  }' > "$deployments"
  jq -n '{
    images:{
      recipes:"ghcr.io/dhhyi/recipe-db-recipes@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  }' > "$release"
  load_scenario_functions

  deployed_release_images_match_inventory "$deployments" "$release"
  jq '.items[0].spec.template.spec.containers[0].image = "unexpected:latest"' \
    "$deployments" > "$FIXTURE_ROOT/mismatched.json"
  if deployed_release_images_match_inventory "$FIXTURE_ROOT/mismatched.json" "$release"; then
    return 1
  fi
}

@test "rejects a Pi identity that does not match the backup before any rehearsal cluster is created" {
  run bash .scripts/production-upgrade-rehearsal-k3d.sh "$MANIFEST" "$ARCHIVE" \
    verified-upload VERIFIED-backup-123-456-verified-upload \
    "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -ne 0 ]
  [[ $output == *"latest backup release/revision does not match the currently deployed release"* ]]
  [ -f "$RESULT_DIRECTORY/result.json" ]
  [ "$(stat -c %a "$RESULT_DIRECTORY/result.json")" = 600 ]
  jq -e '.status == "failed"
    and .deployedIdentity.matchesBackupSource == false
    and .backup.remoteUploadStatusIndependentlyVerified == false
    and .backup.operatorAttestedBaselineBackupId == "backup-123-456"
    and .cleanup.inputCopiesRemoved == false
    and .successfulUpgrade.migrationOutcome == "not-started"
    and .cleanup.activeCluster == ""' "$RESULT_DIRECTORY/result.json"
  [ -f "$MANIFEST" ]
  [ -f "$ARCHIVE" ]
  run grep -F 'get deployments' "$MOCK_KUBECTL_LOG"
  [ "$status" -ne 0 ]
}

@test "rejects a kubeconfig outside the documented loopback API tunnel" {
  export MOCK_API_SERVER="https://example.invalid:6445"
  run bash .scripts/production-upgrade-rehearsal-k3d.sh "$MANIFEST" "$ARCHIVE" \
    verified-upload VERIFIED-backup-123-456-verified-upload \
    "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -ne 0 ]
  [[ $output == *"does not use the documented loopback-only API tunnel endpoint"* ]]
  run grep -F 'get configmap recipe-db-release' "$MOCK_KUBECTL_LOG"
  [ "$status" -ne 0 ]
}

@test "requires an explicit matching uploader-status attestation before creating results" {
  run bash .scripts/production-upgrade-rehearsal-k3d.sh "$MANIFEST" "$ARCHIVE" \
    verified-unchanged VERIFIED-backup-123-456-verified-upload \
    "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -ne 0 ]
  [[ $output == *"exact VERIFIED-<backup-id>-<status> confirmation"* ]]
  [ ! -e "$RESULT_DIRECTORY" ]
}

@test "rejects backup copies accessible by group or others" {
  chmod 644 "$ARCHIVE"
  run bash .scripts/production-upgrade-rehearsal-k3d.sh "$MANIFEST" "$ARCHIVE" \
    verified-upload VERIFIED-backup-123-456-verified-upload \
    "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -ne 0 ]
  [[ $output == *"private input must not be accessible by group or others"* ]]
  [ ! -e "$RESULT_DIRECTORY" ]
}

@test "rejects result directories inside the source checkout" {
  local manifest_copy archive_copy
  manifest_copy="$FIXTURE_ROOT/$(basename "$MANIFEST")"
  archive_copy="$FIXTURE_ROOT/$(basename "$ARCHIVE")"
  cp -- "$MANIFEST" "$manifest_copy"
  cp -- "$ARCHIVE" "$archive_copy"
  chmod 600 "$manifest_copy" "$archive_copy"
  RESULT_DIRECTORY="$FIXTURE_ROOT/.rehearsal-result"
  run bash .scripts/production-upgrade-rehearsal-k3d.sh "$manifest_copy" "$archive_copy" \
    verified-upload VERIFIED-backup-123-456-verified-upload \
    "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -ne 0 ]
  [[ $output == *"results must be outside the checkout"* ]]
  [ ! -e "$RESULT_DIRECTORY" ]
}

@test "successful cleanup removes only the supplied backup copies" {
  local input_manifest="$BATS_TEST_TMPDIR/cleanup.manifest.json"
  local input_archive="$BATS_TEST_TMPDIR/cleanup.tar.gz"
  local unrelated="$BATS_TEST_TMPDIR/unrelated"
  printf 'manifest\n' > "$input_manifest"
  printf 'archive\n' > "$input_archive"
  printf 'keep\n' > "$unrelated"
  sed -n '/^remove_input_copies() {/,/^}/p' \
    .scripts/production-upgrade-rehearsal-k3d.sh > cleanup-function.sh
  # shellcheck disable=SC1091
  source cleanup-function.sh
  remove_input_copies
  [ ! -e "$input_manifest" ]
  [ ! -e "$input_archive" ]
  [ -f "$unrelated" ]
}

@test "success verification accepts explicit no-migration and completed migration outcomes" {
  local candidate="$CANDIDATE_RELEASE"
  local state="$BATS_TEST_TMPDIR/migration-state.json"
  sed -n '/^successful_migration_outcome_is_valid() {/,/^}/p' \
    .scripts/production-upgrade-rehearsal-k3d.sh > migration-outcome-function.sh
  # shellcheck disable=SC1091
  source migration-outcome-function.sh

  for outcome in no-migration-required migration-succeeded; do
    jq -n --arg candidate "$candidate" --arg outcome "$outcome" '
      {migrationResult:{artifact:$candidate,outcome:$outcome},
       migrationExecution:{versions:[{service:"recipes",currentVersion:1,requiredVersion:1}]}}
    ' > "$state"
    successful_migration_outcome_is_valid "$state" "$candidate"
  done

  jq '.migrationExecution.versions = []' "$state" > "$state.next"
  mv "$state.next" "$state"
  run successful_migration_outcome_is_valid "$state" "$candidate"
  [ "$status" -ne 0 ]

  jq 'del(.migrationExecution.versions)' "$state" > "$state.next"
  mv "$state.next" "$state"
  run successful_migration_outcome_is_valid "$state" "$candidate"
  [ "$status" -ne 0 ]

  jq -n --arg candidate "$candidate" '
    {migrationResult:{artifact:$candidate,outcome:"no-migration-required"},
      migrationExecution:{versions:[{service:"recipes",currentVersion:1,requiredVersion:1}]}}
  ' > "$state"
  jq '.migrationExecution.versions[0].currentVersion = 0' "$state" > "$state.next"
  mv "$state.next" "$state"
  run successful_migration_outcome_is_valid "$state" "$candidate"
  [ "$status" -ne 0 ]
}

@test "complete recovery result requires verified prior backup and aborted candidate" {
  local candidate="$CANDIDATE_RELEASE"
  local backup_id=backup-123-456
  local state="$BATS_TEST_TMPDIR/recovery-state.json"
  sed -n '/^complete_recovery_state_is_verified() {/,/^}/p' \
    .scripts/production-upgrade-rehearsal-k3d.sh > recovery-state-function.sh
  # shellcheck disable=SC1091
  source recovery-state-function.sh
  jq -n --arg candidate "$candidate" --arg backupId "$backup_id" '
    {status:"recovered",phase:"migration-recovered",
     migrationRecovery:{status:"verified",candidateAborted:true,abortedCandidate:$candidate},
     backupVerification:{backupId:$backupId}}
  ' > "$state"
  complete_recovery_state_is_verified "$state" "$candidate" "$backup_id"
  run complete_recovery_state_is_verified "$state" "$candidate" backup-987-654
  [ "$status" -ne 0 ]
}

@test "result reports only verified linked-data and recovery outcomes" {
  local result_directory="$BATS_TEST_TMPDIR/result"
  local phases_file="$BATS_TEST_TMPDIR/phases.json"
  local phase=complete failure_reason='' rehearsal_status=passed
  local started_at=2026-11-12T18:00:00Z started_epoch
  local backup_id=backup-123-456 source_release="$SOURCE_RELEASE"
  local source_revision="$SOURCE_REVISION" backup_archive_sha="$ARCHIVE_SHA"
  local backup_captured_at=2026-11-12T18:26:10Z backup_status=verified-upload
  local input_package_validation_status=passed candidate="$CANDIDATE_RELEASE"
  local candidate_revision="$SOURCE_REVISION" deployed_release="$SOURCE_RELEASE"
  local deployed_revision="$SOURCE_REVISION" deployed_image_inventory_verified=true
  local backup_storage_versions='[{"service":"recipes","version":1}]'
  local source_storage_versions='[{"service":"recipes","version":1}]'
  local backup_storage_versions_match_source=true live_storage_workloads_ready=true
  local source_package_status=verified-upload success_upgrade_status=passed
  local migration_outcome=no-migration-required failure_recovery_status=passed
  local post_backup_id=backup-456-789 post_backup_upload_status=verified-upload post_backup_restore_status=passed
  local cluster='' deleted_clusters=() source_worktree="$BATS_TEST_TMPDIR/source"
  local candidate_worktree="$BATS_TEST_TMPDIR/candidate"
  local source_worktree_created=false candidate_worktree_created=false
  local candidate_images='{}' candidate_migrations='[]' actual_versions='[{"service":"recipes","currentVersion":1,"requiredVersion":1}]'
  local sample_relations_verified=true
  local remote_status_independently_verified=false deployed_identity_verified=true
  local host_cpu_count=8 docker_memory_bytes=17179869184
  local available_disk_bytes_before=1000000000 available_disk_bytes_after=900000000
  local cleanup_status=passed private_data_removed=true input_copies_removed=true
  mkdir -m 700 "$result_directory"
  printf '["preflight","complete"]\n' > "$phases_file"
  started_epoch=$(date +%s)
  sed -n '/^write_result() {/,/^}/p' \
    .scripts/production-upgrade-rehearsal-k3d.sh > write-result-function.sh
  # shellcheck disable=SC1091
  source write-result-function.sh

  write_result true
  jq -e '.status == "passed" and .failureReason == null
    and .successfulUpgrade.migrationOutcome == "no-migration-required"
    and .successfulUpgrade.representativeRecipeLinkedDataVerified == true
    and .postReleaseBackup == {backupId:"backup-456-789",uploadStatus:"verified-upload",restoreResult:"passed"}
    and .failureRecovery.status == "passed"
    and .failureRecovery.verification != null
    and .failureRecovery.injectedFailure != null
    and .cleanup.inputCopiesRemoved == true
    and .cleanup.privateDataRemoved == true' "$result_directory/result.json"

  phase=successful-upgrade-delete-rehearsal-cluster
  rehearsal_status=cleanup-failed
  failure_reason='owned rehearsal cluster could not be deleted'
  cluster=recipe-db-rehearsal-owned
  cleanup_status=cleanup-failed
  private_data_removed=false
  input_copies_removed=false
  write_result false
  jq -e '.status == "cleanup-failed"
    and .failureReason == "owned rehearsal cluster could not be deleted"
    and .cleanup.status == "cleanup-failed"
    and .cleanup.activeCluster == "recipe-db-rehearsal-owned"
    and .cleanup.privateDataRemoved == false
    and .cleanup.inputCopiesRemoved == false' "$result_directory/result.json"

  rehearsal_status=failed
  phase=successful-upgrade-restore-production-backup
  failure_reason='candidate has not been verified'
  success_upgrade_status=not-started
  migration_outcome=not-started
  sample_relations_verified=false
  cleanup_status=not-run
  cluster=''
  failure_recovery_status=in-progress
  write_result false
  jq -e '.failureRecovery.status == "in-progress"
    and .failureRecovery.verification == null
    and .failureRecovery.injectedFailure != null' "$result_directory/result.json"

  failure_recovery_status=not-started
  write_result false
  jq -e '.status == "failed"
    and .failureReason == "candidate has not been verified"
    and .successfulUpgrade.representativeRecipeLinkedDataVerified == false
    and .failureRecovery.status == "not-started"
    and .failureRecovery.verification == null
    and .failureRecovery.injectedFailure == null' "$result_directory/result.json"
}

@test "historical rehearsal uses current infrastructure and preserves production storage sizing without integrations" {
  use_mise_tools
  mkdir -p work secrets
  cp "$BATS_TEST_DIRNAME/../lib/production-config.sh" .scripts/
  local root="$FIXTURE_ROOT" work="$FIXTURE_ROOT/work"
  local accounts_file="$FIXTURE_ROOT/secrets/auth-accounts.json"
  local source_values="$FIXTURE_ROOT/deploy/pi-values.yaml"
  local rehearsal_values="$FIXTURE_ROOT/values.yaml"
  local cluster_values="$FIXTURE_ROOT/cluster-values.yaml"
  local source_json="$FIXTURE_ROOT/source-values.json"
  local local_json="$FIXTURE_ROOT/local-values.json"
  printf '{"anonymous":{"role":"anonymous"},"tokens":[{"id":"owner","secret":"synthetic-token","role":"owner"}],"googleAccounts":{}}\n' \
    > "$accounts_file"
  chmod 600 "$accounts_file" "$source_values"
  # shellcheck disable=SC1091
  yq() {
    local original_path=$PATH
    PATH=${PATH#"$FIXTURE_ROOT/bin:"}
    command yq "$@"
    local status=$?
    PATH=$original_path
    return "$status"
  }
  yq -o=json '.' "$source_values" > "$source_json"
  yq -o=json '.' "$FIXTURE_ROOT/deploy/local.yaml" > "$local_json"
  # shellcheck source=.scripts/lib/rehearsal-k3d.sh
  source .scripts/lib/rehearsal-k3d.sh
  # shellcheck source=.scripts/lib/production-config.sh
  source .scripts/production-config.sh
  local source_worktree="$FIXTURE_ROOT/historical" candidate_worktree="$FIXTURE_ROOT"
  mkdir -p "$source_worktree/deploy"
  yq '.infrastructure.traefik |= sub(":v3[.][0-9]+[.][0-9]+@", ":v3@")' \
    deploy/local.yaml > "$source_worktree/deploy/local.yaml"
  local function_name
  for function_name in write_values write_cluster_values rehearsal_cluster_name; do
    sed -n "/^${function_name}() {/,/^}/p" \
      .scripts/production-upgrade-rehearsal-k3d.sh
  done > cluster-values-function.sh
  # shellcheck disable=SC1091
  source cluster-values-function.sh
  local run_id=a1b2c3d4e5f60718 http_port=22001 deployment_values="$source_values"
  local success_source_values success_candidate_values success_cluster_values
  mark() { :; }
  sed -n '/^success_source_values=/,/^mark$/p' \
    .scripts/production-upgrade-rehearsal-k3d.sh > prepare-values.sh
  # shellcheck disable=SC1091
  source prepare-values.sh
  rehearsal_values=$success_source_values
  cluster_values=$success_cluster_values
  local values
  for values in "$rehearsal_values" "$success_candidate_values"; do
    run production_config "$values" restore
    [ "$status" -eq 0 ]
    [ "$(jq -r '.rehearsalId // ""' "$work/config.json")" = '' ]
  done
  run production_config "$cluster_values" restore
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$cluster_values")" = 600 ]
  jq -e --arg accounts "$accounts_file" --slurpfile source "$source_json" \
    --slurpfile local "$local_json" '
    .target == "local"
    and .storageClass == "local-path"
    and .volumes == ($source[0].volumes | del(.redis))
    and .resources == $source[0].resources
    and .timeoutSeconds == $source[0].timeoutSeconds
    and .volumes.redis == null
    and .piStorage == null and .httpsStaging == null
    and .runtime.googleOAuthClientId == null
    and .runtime.trustedIssuer == $source[0].runtime.trustedIssuer
    and .infrastructure == $local[0].infrastructure
    and .secrets == {"auth-accounts.json":$accounts}
    and .rehearsalId == "a1b2c3d4e5f60718"
  ' "$work/config.json"
}

@test "representative restore sample requires populated cross-service relations" {
  local response="$FIXTURE_ROOT/response.json"
  local source_sample_file="$FIXTURE_ROOT/source-sample.json"
  local work="$FIXTURE_ROOT/work" sample_id=''
  local sample_relations_verified=false
  mkdir -p "$work"
  sed -n '/^take_sample() {/,/^}/p' \
    .scripts/production-upgrade-rehearsal-k3d.sh > sample-function.sh
  # shellcheck disable=SC1091
  source sample-function.sh
  graphql_at() {
    local variables=${3-}
    [[ -n $variables ]] || variables='{}'
    if [[ $2 == *searchRecipes* ]]; then
      jq -n '{data:{searchRecipes:{recipes:[{id:"incomplete"},{id:"complete"}],found:2}}}' > "$response"
    elif [[ $(jq -r .id <<< "$variables") == incomplete ]]; then
      jq -n '{data:{recipe:{id:"incomplete",image:{url:"full",thumbUrl:"thumb"},
        rating:{average:0,count:0},inspirations:[],tags:[]}}}' > "$response"
    else
      jq -n '{data:{recipe:{id:"complete",name:"Fixture",image:{url:"full",thumbUrl:"thumb"},
        rating:{average:5,count:1},inspirations:[{url:"source"}],
        tags:[{id:"tag",category:"Fixture",name:"Example"}]}}}' > "$response"
    fi
  }
  die() {
    printf '%s\n' "$*" >&2
    cat "$scenario_lifecycle_log" >&2
    return 1
  }
  take_sample values.yaml
  [ "$sample_id" = complete ]
  [ "$sample_relations_verified" = false ]
  jq -e '.id == "complete" and (.inspirations | length) == 1 and (.tags | length) == 1' \
    "$source_sample_file"
}

@test "candidate linked data is verified only after an exact matching read" {
  local response="$FIXTURE_ROOT/response.json"
  local source_sample_file="$FIXTURE_ROOT/source-sample.json"
  local work="$FIXTURE_ROOT/work" sample_relations_verified=false
  mkdir -p "$work"
  jq -Sc -n '{id:"complete",name:"Fixture",image:{url:"full",thumbUrl:"thumb"},
    rating:{average:5,count:1},inspirations:[{url:"source"}],
    tags:[{id:"tag",category:"Fixture",name:"Example"}]}' > "$source_sample_file"
  jq -n --slurpfile recipe "$source_sample_file" '{data:{recipe:$recipe[0]}}' \
    > "$FIXTURE_ROOT/candidate-response.json"
  load_scenario_functions
  graphql_at() { cp "$FIXTURE_ROOT/candidate-response.json" "$response"; }
  die() {
    printf '%s\n' "$*" >&2
    exit 1
  }

  verify_sample values.yaml candidate
  [ "$sample_relations_verified" = true ]

  sample_relations_verified=false
  jq '.data.recipe.name = "Changed"' "$FIXTURE_ROOT/candidate-response.json" \
    > "$FIXTURE_ROOT/mismatched-candidate-response.json"
  mv "$FIXTURE_ROOT/mismatched-candidate-response.json" "$FIXTURE_ROOT/candidate-response.json"
  run verify_sample values.yaml candidate
  [ "$status" -ne 0 ]
  [ "$sample_relations_verified" = false ]
}

@test "scenario composition exercises no-migration handoff and uncertain complete recovery" {
  use_mise_tools
  local work="$FIXTURE_ROOT/work" phases_file="$FIXTURE_ROOT/phases.json"
  root="$FIXTURE_ROOT"
  mkdir -p "$work/logs" "$work/state" "$work/uploader" "$work/packages" \
    "$work/candidate-artifact" "$FIXTURE_ROOT/source" "$FIXTURE_ROOT/candidate"
  printf '[]\n' > "$phases_file"
  jq -n '{schemaVersion:2,migrations:[]}' > "$work/candidate-artifact/release.json"
  source_worktree="$FIXTURE_ROOT/source"
  candidate_worktree="$FIXTURE_ROOT/candidate"
  mkdir -p "$root/.scripts" "$candidate_worktree/.scripts"
  printf 'current smoke script\n' > "$root/.scripts/smoke-production-k3d.sh"
  printf 'pinned smoke script\n' > "$candidate_worktree/.scripts/smoke-production-k3d.sh"
  candidate_revision=cccccccccccccccccccccccccccccccccccccccc
  candidate='ghcr.io/dhhyi/recipe-db-releases@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  source_release="$SOURCE_RELEASE"
  source_values="$FIXTURE_ROOT/source-values.yaml"
  candidate_values="$FIXTURE_ROOT/candidate-values.yaml"
  owner_token="$FIXTURE_ROOT/owner-token"
  printf 'synthetic\n' > "$owner_token"
  run_id=0123456789abcdef
  candidate_migration_count=0
  candidate_migrations='[]'
  phase=''
  failure_reason=''
  rehearsal_status=failed
  cleanup_status=not-run
  success_upgrade_status=not-started
  failure_recovery_status=not-started
  migration_outcome=not-started
  source_package_status=not-checked
  cluster=''
  cluster_created=false
  deleted_clusters=()
  lease_phase='candidate-staged'
  package_id=backup-test-123
  scenario_label=successful-upgrade
  export scenario_lifecycle_log="$work/lifecycle.log"
  load_scenario_functions

  yq() { printf '600\n'; }
  mark() {
    jq --arg phase "$phase" '. + [$phase]' "$phases_file" > "$phases_file.next"
    mv "$phases_file.next" "$phases_file"
  }
  die() {
    printf '%s\n' "$*" >&2
    cat "$scenario_lifecycle_log" >&2
    return 1
  }
  new_cluster() {
    cluster=$(rehearsal_cluster_name "$run_id" "$1")
    cluster_driver="$root"
    cluster_values="$2"
    cluster_created=true
  }
  take_sample() {
    sample_id=recipe-with-links
    jq -n '{id:"recipe-with-links",image:{url:"full",thumbUrl:"thumb"},
      rating:{average:5,count:1},inspirations:[{url:"source"}],tags:[{id:"tag"}]}' \
      > "$work/source-sample.json"
  }
  verify_sample() { printf 'verified %s\n' "$2" >> "$work/sample-checks.log"; }
  capture_post_release_backup() { printf 'post-release %s\n' "$*" >> "$scenario_lifecycle_log"; }
  prepare_fake_upload() {
    local label=$1 snapshot=$2
    mkdir -p "$work/uploader/$label" "$work/packages/$label"
    printf '{"status":"verified-upload"}\n' > "$work/uploader/$label/status.json"
    jq -n --arg id "$package_id" '{backupId:$id,manifest:"backup.manifest.json",archive:"backup.tar.gz"}' \
      > "$work/uploader/$label/baseline.json"
    printf 'manifest\n' > "$work/packages/$label/backup.manifest.json"
    printf 'archive\n' > "$work/packages/$label/backup.tar.gz"
  }
  run_logged() {
    local log=$1
    shift
    if [[ $* == *production-smoke* ]]; then
      jq -n --arg artifact "$candidate" '{success:true,artifact:$artifact}' \
        > "$work/success-smoke-result.json"
      return 0
    fi
    "$@" > "$log" 2>&1 || {
      cat "$log" >&2
      return 1
    }
  }
  lifecycle() {
    local checkout=$1 from_git=$2 operation
    shift 2
    operation=$1
    shift
    printf '%s %s %s\n' "$from_git" "$operation" "$*" >> "$scenario_lifecycle_log"
    case "$operation" in
      restore)
        [ ! -e "$5" ] || return 96
        mkdir -m 700 -- "$5"
        ;;
      backup-enter)
        [ ! -e "$3" ] || return 96
        mkdir -m 700 -- "$3"
        ;;
      release-migration-plan | delete)
        return 0
        ;;
      release-reopen)
        jq '.status="access-open" | .phase="operator-reopened"' "$2/backup-state.json" \
          > "$2/backup-state.next"
        mv "$2/backup-state.next" "$2/backup-state.json"
        return 0
        ;;
      backup-capture)
        [ -d "$2" ] || return 96
        printf '{"fixture":true}\n' > "$2/manifest.json"
        ;;
      release-stage)
        jq -n --arg candidate "$3" '
          {status:"candidate-staged",phase:"candidate-staged",candidate:{artifact:$candidate}}
        ' > "$2/backup-state.json"
        ;;
      release-migration-next)
        if [[ $scenario_label == failure-recovery ]]; then
          jq '.status="recovery-required" | .phase="migration-uncertain"
            | .migrationExecution.status="uncertain"' "$2/backup-state.json" \
            > "$2/backup-state.next"
          mv "$2/backup-state.next" "$2/backup-state.json"
          lease_phase='migration-uncertain'
          return 1
        fi
        local outcome=no-migration-required
        if ((candidate_migration_count > 0)); then
          outcome=migration-succeeded
        fi
        jq -n --arg candidate "$candidate" --arg outcome "$outcome" '
          {migrationResult:{artifact:$candidate,outcome:$outcome},
           migrationExecution:{versions:[{service:"recipes",currentVersion:2,requiredVersion:2}]}}
        ' > "$2/backup-state.json"
        ;;
      release-start)
        jq '.status="release-ready" | .phase="ready"' "$2/backup-state.json" \
          > "$2/backup-state.next"
        mv "$2/backup-state.next" "$2/backup-state.json"
        ;;
      release-migration-recover)
        jq -n --arg candidate "$3" --arg backupId "$6" '
          {status:"recovered",phase:"migration-recovered",
           migrationRecovery:{status:"verified",candidateAborted:true,abortedCandidate:$candidate},
           backupVerification:{backupId:$backupId}}
        ' > "$2/backup-state.json"
        ;;
      kubectl)
        if [[ " $* " == *" get deployments "* ]]; then
          printf '{"items":[]}\n'
        elif [[ " $* " == *" get lease recipe-db-deploy "* ]]; then
          jq -n --arg holder "$package_id" --arg source "$source_release" --arg phase "$lease_phase" '
            {spec:{holderIdentity:$holder},
             metadata:{annotations:{"recipe-db/release":$source,"recipe-db/phase":$phase}}}
          '
        elif [[ " $* " == *" replace -f "* ]]; then
          lease_phase=$(jq -r '.metadata.annotations["recipe-db/phase"]' "$6")
        else
          printf 'Unexpected mocked kubectl call: %s\n' "$*" >&2
          return 97
        fi
        ;;
      *)
        printf 'Unexpected mocked lifecycle operation: %s\n' "$operation" >&2
        return 97
        ;;
    esac
  }

  : > "$scenario_lifecycle_log"
  run_scenario successful-upgrade "$source_values" "$candidate_values"
  [ "$migration_outcome" = no-migration-required ]
  [ "$success_upgrade_status" = passed ]
  [ "$(cat "$candidate_worktree/.scripts/smoke-production-k3d.sh")" = 'pinned smoke script' ]
  [ "$cluster" = '' ]
  [ "$cluster_created" = false ]
  grep -Fq 'release-migration-next' "$scenario_lifecycle_log"
  grep -Fq 'release-reopen' "$scenario_lifecycle_log"
  grep -Fq 'false backup-capture' "$scenario_lifecycle_log"
  grep -Fq 'post-release successful-upgrade' "$scenario_lifecycle_log"

  : > "$scenario_lifecycle_log"
  scenario_label=failure-recovery
  run_scenario failure-recovery "$source_values" "$candidate_values"
  [ "$failure_recovery_status" = passed ]
  [ "$cluster" = '' ]
  [ "$cluster_created" = false ]
  grep -Fq 'release-migration-recover' "$scenario_lifecycle_log"
  run grep -F 'release-reopen' "$scenario_lifecycle_log"
  [ "$status" -ne 0 ]
}

@test "migration scenario composition executes the same guarded handoff" {
  use_mise_tools
  local work="$FIXTURE_ROOT/work" phases_file="$FIXTURE_ROOT/phases.json"
  root="$FIXTURE_ROOT"
  mkdir -p "$work/logs" "$work/state" "$work/uploader" "$work/packages" \
    "$work/candidate-artifact" "$FIXTURE_ROOT/source" "$FIXTURE_ROOT/candidate"
  printf '[]\n' > "$phases_file"
  jq -n '{schemaVersion:2,migrations:[{service:"recipes",fromVersion:1,toVersion:2,
    timeoutSeconds:1,image:"ghcr.io/dhhyi/recipe-db-migrations@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}' \
    > "$work/candidate-artifact/release.json"
  source_worktree="$FIXTURE_ROOT/source"
  candidate_worktree="$FIXTURE_ROOT/candidate"
  mkdir -p "$root/.scripts" "$candidate_worktree/.scripts"
  printf 'current smoke script\n' > "$root/.scripts/smoke-production-k3d.sh"
  printf 'pinned smoke script\n' > "$candidate_worktree/.scripts/smoke-production-k3d.sh"
  candidate_revision=cccccccccccccccccccccccccccccccccccccccc
  candidate='ghcr.io/dhhyi/recipe-db-releases@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  source_release="$SOURCE_RELEASE"
  source_values="$FIXTURE_ROOT/source-values.yaml"
  candidate_values="$FIXTURE_ROOT/candidate-values.yaml"
  owner_token="$FIXTURE_ROOT/owner-token"
  printf 'synthetic\n' > "$owner_token"
  run_id=0123456789abcdef
  candidate_migration_count=1
  candidate_migrations='[{"service":"recipes"}]'
  phase=''
  failure_reason=''
  rehearsal_status=failed
  cleanup_status=not-run
  success_upgrade_status=not-started
  failure_recovery_status=not-started
  migration_outcome=not-started
  source_package_status=not-checked
  cluster=''
  cluster_created=false
  deleted_clusters=()
  lease_phase='candidate-staged'
  package_id=backup-test-456
  scenario_label=successful-upgrade
  export scenario_lifecycle_log="$work/lifecycle.log"
  load_scenario_functions
  yq() { printf '600\n'; }
  mark() {
    jq --arg phase "$phase" '. + [$phase]' "$phases_file" > "$phases_file.next"
    mv "$phases_file.next" "$phases_file"
  }
  die() {
    printf '%s\n' "$*" >&2
    return 1
  }
  new_cluster() {
    cluster=$(rehearsal_cluster_name "$run_id" "$1")
    cluster_driver="$root"
    cluster_values="$2"
    cluster_created=true
  }
  take_sample() { sample_id=recipe-with-links; }
  verify_sample() { :; }
  capture_post_release_backup() { printf 'post-release %s\n' "$*" >> "$scenario_lifecycle_log"; }
  prepare_fake_upload() {
    local label=$1
    mkdir -p "$work/uploader/$label" "$work/packages/$label"
    printf '{"status":"verified-upload"}\n' > "$work/uploader/$label/status.json"
    jq -n --arg id "$package_id" '{backupId:$id,manifest:"backup.manifest.json",archive:"backup.tar.gz"}' \
      > "$work/uploader/$label/baseline.json"
    printf 'manifest\n' > "$work/packages/$label/backup.manifest.json"
    printf 'archive\n' > "$work/packages/$label/backup.tar.gz"
  }
  run_logged() {
    local log=$1
    shift
    if [[ $* == *production-smoke* ]]; then
      jq -n --arg artifact "$candidate" '{success:true,artifact:$artifact}' \
        > "$work/success-smoke-result.json"
      return 0
    fi
    "$@" > "$log" 2>&1 || {
      cat "$log" >&2
      return 1
    }
  }
  lifecycle() {
    local checkout=$1 from_git=$2 operation
    shift 2
    operation=$1
    shift
    printf '%s %s %s\n' "$from_git" "$operation" "$*" >> "$scenario_lifecycle_log"
    case "$operation" in
      restore)
        [ ! -e "$5" ] || return 96
        mkdir -m 700 -- "$5"
        ;;
      backup-enter)
        [ ! -e "$3" ] || return 96
        mkdir -m 700 -- "$3"
        ;;
      release-migration-plan | delete)
        return 0
        ;;
      release-reopen)
        jq '.status="access-open" | .phase="operator-reopened"' "$2/backup-state.json" \
          > "$2/backup-state.next"
        mv "$2/backup-state.next" "$2/backup-state.json"
        return 0
        ;;
      backup-capture)
        [ -d "$2" ] || return 96
        printf '{"fixture":true}\n' > "$2/manifest.json"
        ;;
      release-stage)
        jq -n --arg candidate "$3" '
          {status:"candidate-staged",phase:"candidate-staged",candidate:{artifact:$candidate}}
        ' > "$2/backup-state.json"
        ;;
      release-migration-next)
        jq -n --arg candidate "$candidate" '
          {migrationResult:{artifact:$candidate,outcome:"migration-succeeded"},
           migrationExecution:{versions:[{service:"recipes",currentVersion:2,requiredVersion:2}]}}
        ' > "$2/backup-state.json"
        ;;
      release-start)
        jq '.status="release-ready" | .phase="ready"' "$2/backup-state.json" \
          > "$2/backup-state.next"
        mv "$2/backup-state.next" "$2/backup-state.json"
        ;;
      kubectl)
        if [[ " $* " == *" get deployments "* ]]; then
          printf '{"items":[]}\n'
        else
          printf 'Unexpected mocked kubectl call: %s\n' "$*" >&2
          return 97
        fi
        ;;
      *)
        printf 'Unexpected mocked lifecycle operation: %s\n' "$operation" >&2
        return 97
        ;;
    esac
  }
  : > "$scenario_lifecycle_log"
  run_scenario successful-upgrade "$source_values" "$candidate_values"
  [ "$migration_outcome" = migration-succeeded ]
  [ "$success_upgrade_status" = passed ]
  [ "$(cat "$candidate_worktree/.scripts/smoke-production-k3d.sh")" = 'pinned smoke script' ]
  grep -Fq 'release-migration-next' "$scenario_lifecycle_log"
  grep -Fq 'release-reopen' "$scenario_lifecycle_log"
  grep -Fq 'false backup-capture' "$scenario_lifecycle_log"
  grep -Fq 'post-release successful-upgrade' "$scenario_lifecycle_log"
}

@test "scenario cluster deletion failure is cleanup-failed and retains ownership evidence" {
  local work="$FIXTURE_ROOT/work"
  mkdir -p "$work/logs"
  cluster=recipe-db-rehearsal-test-s
  cluster_created=true
  cluster_driver="$FIXTURE_ROOT/source"
  cluster_values="$FIXTURE_ROOT/source-values.yaml"
  cleanup_status=not-run
  rehearsal_status=failed
  phase=''
  failure_reason=''
  deleted_clusters=()
  load_scenario_functions
  lifecycle() { return 1; }
  if delete_scenario_cluster successful-upgrade; then
    return 1
  fi
  [ "$failure_reason" = "could not delete owned rehearsal cluster recipe-db-rehearsal-test-s" ]
  [ "$cleanup_status" = cleanup-failed ]
  [ "$rehearsal_status" = cleanup-failed ]
  [ "$cluster" = recipe-db-rehearsal-test-s ]
  [ "$cluster_created" = true ]
  [ "${#deleted_clusters[@]}" -eq 0 ]
}

@test "lifecycle uses current tooling and immutable Git sources for old release operations" {
  local root="$FIXTURE_ROOT" work="$FIXTURE_ROOT/work"
  local cluster_created=true cluster_check_count=0 cluster_values=cluster.yaml
  mkdir -p "$work/logs"
  sed -n '/^lifecycle() {/,/^}/p' \
    .scripts/production-upgrade-rehearsal-k3d.sh > lifecycle-function.sh
  # shellcheck disable=SC1091
  source lifecycle-function.sh
  mise() { printf '%s %s\n' "$PWD" "$*" >> "$work/calls"; }
  die() { return 1; }

  lifecycle /nonexistent/old-source false restore source.yaml
  lifecycle /nonexistent/old-source false backup-enter source.yaml
  lifecycle /nonexistent/old-source false backup-capture source.yaml
  lifecycle /nonexistent/old-candidate true release-stage candidate.yaml
  [ "$cluster_check_count" -eq 4 ]
  [ "$(grep -c 'production-k3d verify cluster.yaml' "$work/calls")" -eq 4 ]
  for operation in restore backup-enter backup-capture release-stage; do
    grep -Fq "$root run --raw production-k3d --release-sources-from-git $operation" "$work/calls"
  done
  mise() { return 1; }
  run lifecycle /nonexistent/old-source false restore source.yaml
  [ "$status" -ne 0 ]
}

@test "rehearsal restores candidate backup on a second cluster after upgrade" {
  local root="$FIXTURE_ROOT" work="$FIXTURE_ROOT/work"
  local backup_id=backup-123-456 source_revision="$SOURCE_REVISION"
  local source_release="$SOURCE_RELEASE" candidate="$CANDIDATE_RELEASE"
  local manifest=manifest.json archive=archive.tar.gz phase=''
  local fake_remote="$work/remote" run_id=123 post_backup_restore_status=not-run
  mkdir -p "$work/logs" "$work/state/failure-recovery" "$work/uploader/successful-upgrade"
  printf '{"backupId":"backup-789-123"}\n' > "$work/state/failure-recovery/backup-state.json"
  printf '{"backupId":"backup-999-888","manifest":"post.json","archive":"post.tar.gz"}\n' \
    > "$work/uploader/successful-upgrade/baseline.json"
  load_scenario_functions
  new_cluster() { printf 'create %s\n' "$*" >> "$work/steps"; }
  run_logged() {
    shift
    "$@"
  }
  lifecycle() {
    shift 2
    printf '%s\n' "$*" >> "$work/steps"
  }
  mark() { :; }
  run_scenario() { printf 'scenario %s\n' "$*" >> "$work/steps"; }
  verify_sample() { printf 'verify %s\n' "$*" >> "$work/steps"; }
  delete_scenario_cluster() { printf 'delete %s\n' "$*" >> "$work/steps"; }

  run_rehearsal_scenarios source.yaml candidate.yaml cluster.yaml post.yaml post-cluster.yaml
  [ "$(sed -n '1p' "$work/steps")" = 'create r cluster.yaml' ]
  grep -Fq "restore source.yaml manifest.json archive.tar.gz $backup_id $work/state/restore RESTORE-$backup_id" "$work/steps"
  [ "$(sed -n '3p' "$work/steps")" = 'scenario failure-recovery source.yaml candidate.yaml' ]
  grep -Fq "release-recovery-reopen source.yaml $work/state/failure-recovery $source_release OPEN-RECOVERY-backup-789-123-$source_revision" "$work/steps"
  [ "$(sed -n '5p' "$work/steps")" = 'verify source.yaml recovered-source' ]
  [ "$(sed -n '6p' "$work/steps")" = 'scenario successful-upgrade source.yaml candidate.yaml' ]
  [ "$(sed -n '7p' "$work/steps")" = 'delete complete' ]
  [ "$(sed -n '8p' "$work/steps")" = 'create p post-cluster.yaml' ]
  grep -Fq "restore post.yaml $fake_remote/recipe-db-backups/issue-251-$run_id-successful-upgrade/post.json $fake_remote/recipe-db-backups/issue-251-$run_id-successful-upgrade/post.tar.gz backup-999-888" "$work/steps"
  [ "$(sed -n '10p' "$work/steps")" = 'verify post.yaml post-release-restore' ]
  [ "$(sed -n '11p' "$work/steps")" = 'delete post-release' ]
  [ "$post_backup_restore_status" = passed ]
  [ "$(grep -c '^restore ' "$work/steps")" -eq 2 ]
}

@test "recovery removes only stopped candidate-only Deployments with server preconditions" {
  local work="$FIXTURE_ROOT/work" snapshot="$FIXTURE_ROOT/state"
  local namespace=recipe-db timeout=5
  mkdir -p "$work" "$snapshot"
  sed -n '/^release_recovery_remove_candidate_only_deployments() {/,/^}/p' \
    "$BATS_TEST_DIRNAME/../production-k3d.sh" > cleanup-function.sh
  # shellcheck disable=SC1091
  source cleanup-function.sh
  jq -n --arg candidate "$CANDIDATE_RELEASE" '{
    priorWorkloads:[{name:"graphql"}],
    candidate:{artifact:$candidate,workloads:[{name:"graphql"},{name:"pwa"}]}
  }' > "$snapshot/backup-state.json"
  jq -n --arg candidate "$CANDIDATE_RELEASE" '{items:[
    {metadata:{name:"graphql"}},
    {metadata:{name:"pwa",uid:"pwa-uid",resourceVersion:"123",
      labels:{"app.kubernetes.io/part-of":"recipe-db"}},
     spec:{replicas:0,template:{metadata:{annotations:{"recipe-db/release":$candidate}}}},
     status:{replicas:0,readyReplicas:0}}
  ]}' > "$work/live.json"
  production_fail() {
    printf '%s\n' "$*" >&2
    exit 1
  }
  backup_wait_pods_gone() {
    printf 'workers-gone %s\n' "$1" >> "$work/calls"
    [[ ${workers_present:-false} != true ]]
  }
  kube() {
    printf '%s\n' "$*" >> "$work/calls"
    case "$1" in
      get) cat "$work/live.json" ;;
      delete)
        jq -e '.preconditions == {uid:"pwa-uid",resourceVersion:"123"}' "$5" > /dev/null
        [[ ${delete_conflict:-false} != true ]]
        ;;
      wait) return 0 ;;
      *) return 97 ;;
    esac
  }

  release_recovery_remove_candidate_only_deployments
  grep -Fq 'delete --raw /apis/apps/v1/namespaces/recipe-db/deployments/pwa' "$work/calls"
  grep -Fq 'wait --for=delete deployment/pwa --timeout=5s' "$work/calls"
  [ "$(sed -n '2p' "$work/calls")" = 'workers-gone pwa' ]
  run grep -F 'deployment/graphql' "$work/calls"
  [ "$status" -ne 0 ]

  cp "$work/live.json" "$work/original.json"
  for change in '.items[1].spec.replicas=1' '.items[1].status.replicas=1' \
    '.items[1].metadata.labels["app.kubernetes.io/part-of"]="foreign"' \
    '.items[1].spec.template.metadata.annotations["recipe-db/release"]="other"' \
    '.items[1].metadata.name="untracked"' '.items[1].metadata.uid=""'; do
    jq "$change" "$work/original.json" > "$work/live.json"
    : > "$work/calls"
    run release_recovery_remove_candidate_only_deployments
    [ "$status" -ne 0 ]
    run grep -E '^delete|^wait' "$work/calls"
    [ "$status" -ne 0 ]
  done
  cp "$work/original.json" "$work/live.json"
  workers_present=true
  : > "$work/calls"
  run release_recovery_remove_candidate_only_deployments
  [ "$status" -ne 0 ]
  run grep '^delete' "$work/calls"
  [ "$status" -ne 0 ]
  workers_present=false
  delete_conflict=true
  : > "$work/calls"
  run release_recovery_remove_candidate_only_deployments
  [ "$status" -ne 0 ]
  run grep '^wait' "$work/calls"
  [ "$status" -ne 0 ]
}
