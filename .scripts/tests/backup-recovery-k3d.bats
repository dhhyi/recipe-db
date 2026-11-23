#!/usr/bin/env bats
# Test-local lifecycle globals are intentionally reused across isolated Bats tests.
# shellcheck disable=SC2030,SC2031,SC2329

load test_helper

setup() {
  setup_fixture backup-recovery-k3d.sh
  mkdir -p .scripts/lib
  cp "$BATS_TEST_DIRNAME/../lib/rehearsal-k3d.sh" .scripts/lib/
  export FAKE_RCLONE_ROOT="$FIXTURE_ROOT/fake-remote"
  export result_directory="$FIXTURE_ROOT/results"
  sed -n '/^release_lifecycle() {/,/^}/p' .scripts/backup-recovery-k3d.sh > release-lifecycle-function.sh
  # shellcheck source=/dev/null
  source ./release-lifecycle-function.sh
}

@test "immutable-source lifecycle dispatch preserves arguments for renders backups releases and restores" {
  local driver="$FIXTURE_ROOT/driver with spaces.sh" operation
  bash() { printf '%s\n' "$@"; }
  for operation in render backup-run maintenance-enter backup-enter backup-capture backup-exit \
    release-stage release-migration-plan release-migration-next release-start release-reopen \
    release-readonly-result release-website-result release-backup-capture release-closeout \
    restore recovery-plan recovery-reset recovery-restore; do
    run release_lifecycle "$operation" "values with spaces.yaml" "immutable artifact"
    [ "$status" -eq 0 ]
    [ "$output" = "$driver"$'\n--release-sources-from-git\n'"$operation"$'\nvalues with spaces.yaml\nimmutable artifact' ]
  done
  # shellcheck disable=SC2016
  run grep -E 'bash "\$driver" (backup|release-|restore|recovery-)' .scripts/backup-recovery-k3d.sh
  [ "$status" -eq 1 ]
}

@test "normal source cluster deploy retains its current-checkout contract without immutable-source flag" {
  mkdir -p "$result_directory"
  local driver=driver.sh source_values=source.yaml release=immutable-release
  sed -n '/^phase=source-cluster/,/^graphql_at() {/p' .scripts/backup-recovery-k3d.sh \
    | sed '$d' > source-cluster-steps.sh
  run_logged() {
    shift
    "$@"
  }
  bash() { printf '%s\n' "$*" >> "$result_directory/driver-operations"; }
  docker() { printf 'disposable-source-container'; }
  mark() { return 0; }
  # shellcheck source=/dev/null
  source ./source-cluster-steps.sh
  [ "$(cat "$result_directory/driver-operations")" = $'driver.sh create source.yaml\ndriver.sh deploy source.yaml immutable-release' ]
}

@test "source preflight rejects current-metadata incompatibility before create while historical candidate uses immutable sources" {
  use_mise_tools
  mkdir -p "$result_directory/logs"
  export driver=driver.sh source_values=source.yaml target_values=candidate.yaml
  export release=matching-source-artifact candidate_release=historical-candidate-artifact
  cat > preflight-guards.sh << 'SH'
set -e
source ./release-lifecycle-function.sh
source_http_port=22000
target_http_port=22001
source_api_port=32000
target_api_port=32001
oras() {
  printf '{"annotations":{"org.opencontainers.image.revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n' > "${!#}"
}
bash() {
  case "$2" in
    render)
      printf 'ordinary-source-render\n' >> "$result_directory/driver-operations"
      [[ ${SOURCE_METADATA_COMPATIBLE:-true} == true ]] ;;
    --release-sources-from-git)
      [[ $3 == render && $4 == "$target_values" && $5 == "$candidate_release" ]]
      printf 'immutable-candidate-render\n' >> "$result_directory/driver-operations" ;;
    create | deploy) printf '%s\n' "$2" >> "$result_directory/driver-operations" ;;
    *) return 1 ;;
  esac
}
python3() { return 0; }
docker() { printf 'disposable-source-container'; }
mark() { return 0; }
SH
  sed -n '/^run_logged() {/,/^}/p' .scripts/backup-recovery-k3d.sh >> preflight-guards.sh
  sed -n "/^phase='release-preflight'/,/^graphql_at() {/p" .scripts/backup-recovery-k3d.sh \
    | sed '$d' >> preflight-guards.sh
  SOURCE_METADATA_COMPATIBLE=false run bash preflight-guards.sh
  [ "$status" -ne 0 ]
  [ "$(cat "$result_directory/driver-operations")" = ordinary-source-render ]
  : > "$result_directory/driver-operations"
  run bash preflight-guards.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$result_directory/driver-operations")" = $'ordinary-source-render\nimmutable-candidate-render\ncreate\ndeploy' ]
}

@test "k3d rehearsal rejects mutable artifacts before creating result files or invoking tools" {
  run bash .scripts/backup-recovery-k3d.sh ghcr.io/dhhyi/recipe-db-releases:latest \
    "$FIXTURE_ROOT/results"
  [ "$status" -ne 0 ]
  [[ $output == *"immutable recipe-db release artifact"* ]]
  [ ! -e "$FIXTURE_ROOT/results" ]
}

@test "complete rehearsal requires a distinct immutable candidate for a genuine failed release" {
  local release=ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  run bash .scripts/backup-recovery-k3d.sh "$release" "$result_directory"
  [ "$status" -ne 0 ]
  [[ $output == *"distinct immutable candidate release"* ]]
  run bash .scripts/backup-recovery-k3d.sh "$release" "$result_directory" "$release"
  [ "$status" -ne 0 ]
  [[ $output == *"distinct immutable candidate release"* ]]
  [ ! -e "$result_directory" ]
}

@test "synthetic source and target values satisfy the real token-only production configuration contract" {
  use_mise_tools
  mkdir -p deploy work secrets "$result_directory"
  cp "$BATS_TEST_DIRNAME/../../deploy/local.yaml" deploy/
  cp "$BATS_TEST_DIRNAME/../lib/production-config.sh" .scripts/
  local root="$FIXTURE_ROOT" work="$FIXTURE_ROOT/work"
  export accounts_file="$FIXTURE_ROOT/secrets/auth-accounts.json"
  printf '{"anonymous":{"role":"anonymous"},"tokens":[{"id":"owner","secret":"synthetic-token","role":"owner"}],"googleAccounts":{}}\n' > "$accounts_file"
  export oauth_client_secret="$FIXTURE_ROOT/secrets/google-oauth-client-secret"
  export oauth_cookie_secret="$FIXTURE_ROOT/secrets/oauth2-cookie-secret"
  # shellcheck source=/dev/null
  source .scripts/production-config.sh
  # shellcheck source=.scripts/lib/rehearsal-k3d.sh
  source .scripts/lib/rehearsal-k3d.sh
  local side values
  for side in s t; do
    values="$FIXTURE_ROOT/$side.yaml"
    rehearsal_write_values "$FIXTURE_ROOT" "recipe-db-rehearsal-regression-$side" \
      22001 32001 "$accounts_file" "$values"
    run production_config "$values" restore
    [ "$status" -eq 0 ]
    jq -e '.runtime.googleOAuthClientId == null and
      .secrets == {"auth-accounts.json":env.accounts_file} and
      .infrastructure.oauth2Proxy == null and .infrastructure.redis == null and
      .volumes.redis == null and .cluster == ("recipe-db-rehearsal-regression-" + $side)
      and .context == ("k3d-" + .cluster) and .origin == "http://127.0.0.1:22001"' \
      --arg side "$side" "$work/config.json"
  done
}

@test "synthetic log privacy verification needs only generated owner-token credentials" {
  mkdir -p "$result_directory/secrets" "$result_directory/logs"
  printf 'private-synthetic-owner-token\n' > "$result_directory/secrets/owner-token"
  printf '{"recipeId":"private-synthetic-record"}\n' > "$result_directory/test-record.json"
  printf 'safe diagnostic\n' > "$result_directory/logs/restore.log"
  # shellcheck disable=SC2016
  sed -n '/^python3 - "\$result_directory\/secrets"/,/^PY$/p' \
    .scripts/backup-recovery-k3d.sh > privacy-step.sh
  run bash privacy-step.sh
  [ "$status" -eq 0 ]
  cat "$result_directory/secrets/owner-token" >> "$result_directory/logs/restore.log"
  run bash privacy-step.sh
  [ "$status" -ne 0 ]
  [[ $output == *"synthetic credential or test data was written to a log"* ]]
}

@test "local fake rclone stores, reads and lists only its isolated remote files" {
  mkdir -p bin remote-source
  cp "$BATS_TEST_DIRNAME/fixtures/rclone-local" bin/rclone
  chmod +x bin/rclone
  printf 'package bytes\n' > remote-source/package.tar

  run bin/rclone mkdir fake-e2e:recipe-db-backups
  [ "$status" -eq 0 ]
  run bin/rclone copyto remote-source/package.tar fake-e2e:recipe-db-backups/package.tar
  [ "$status" -eq 0 ]
  run bin/rclone lsf fake-e2e:recipe-db-backups --files-only --format p
  [ "$status" -eq 0 ]
  [ "$output" = "package.tar" ]
  run bin/rclone cat fake-e2e:recipe-db-backups/package.tar
  [ "$status" -eq 0 ]
  [ "$output" = "package bytes" ]
  run bin/rclone copyto remote-source/package.tar fake-e2e:../outside
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURE_ROOT/outside" ]
}

@test "GraphQL reads retry transient routing failures but mutations never retry" {
  use_mise_tools
  sed -n '/^graphql_at() {/,/^}/p' .scripts/backup-recovery-k3d.sh > graphql-function.sh
  # shellcheck source=/dev/null
  source ./graphql-function.sh
  export request="$FIXTURE_ROOT/request.json"
  response="$FIXTURE_ROOT/response.json"
  printf '{"origin":"http://127.0.0.1"}\n' > values.json
  export curl_config="$FIXTURE_ROOT/curl.conf"
  curl() {
    printf '%s\n' "$@" > "$FIXTURE_ROOT/curl-arguments"
    printf '{"data":{}}\n' > "$response"
    printf '200'
  }
  graphql_at values.json 'query { tags { id } }'
  grep -Fxq -- '--retry' "$FIXTURE_ROOT/curl-arguments"
  grep -Fxq -- '--retry-max-time' "$FIXTURE_ROOT/curl-arguments"
  graphql_at values.json 'mutation { deleteRecipe(id: "test") }'
  run grep -Fx -- '--retry' "$FIXTURE_ROOT/curl-arguments"
  [ "$status" -eq 1 ]
}

@test "rehearsal retrieves uploaded packages from the deployment remote directory" {
  export archive_name=backup.tar.gz manifest_name=backup.manifest.json
  mkdir -p "$FAKE_RCLONE_ROOT/recipe-db-backups/k3d-e2e" "$result_directory/packages"
  printf 'archive\n' > "$FAKE_RCLONE_ROOT/recipe-db-backups/k3d-e2e/$archive_name"
  printf '{}\n' > "$FAKE_RCLONE_ROOT/recipe-db-backups/k3d-e2e/$manifest_name"
  # shellcheck disable=SC2016
  sed -n '/^cp "\$FAKE_RCLONE_ROOT/p' .scripts/backup-recovery-k3d.sh > retrieve.sh
  run bash retrieve.sh
  [ "$status" -eq 0 ]
  cmp "$FAKE_RCLONE_ROOT/recipe-db-backups/k3d-e2e/$archive_name" "$result_directory/packages/$archive_name"
  cmp "$FAKE_RCLONE_ROOT/recipe-db-backups/k3d-e2e/$manifest_name" "$result_directory/packages/$manifest_name"
}

@test "package validation stores data privately rather than in diagnostic logs" {
  export root="$FIXTURE_ROOT"
  export package_manifest=manifest.json archive=backup.tar.gz backup_id=test-backup
  mkdir -p "$result_directory/logs"
  # shellcheck disable=SC2016
  sed -n '/^python3 "\$root\/.scripts\/validate-backup-package.py"/,/package-validation.log/p' \
    .scripts/backup-recovery-k3d.sh > validate-step.sh
  python3() {
    printf '{"recipeId":"synthetic-recipe-id"}\n'
    printf 'safe validator diagnostic\n' >&2
  }
  # shellcheck source=/dev/null
  source ./validate-step.sh
  grep -q 'synthetic-recipe-id' "$result_directory/validated-package.json"
  [ "$(cat "$result_directory/logs/package-validation.log")" = 'safe validator diagnostic' ]
}

@test "recovery fault injection runs the real helper before failing or interrupting only the selected cluster" {
  use_mise_tools
  mkdir -p "$result_directory" bin
  export target_values="$FIXTURE_ROOT/target.json" driver="$FIXTURE_ROOT/fault-driver.sh"
  printf '{"context":"k3d-disposable-target"}\n' > "$target_values"
  sed -n '/^run_faulted_recovery() (/,/^)/p' .scripts/backup-recovery-k3d.sh > fault-function.sh
  # shellcheck source=/dev/null
  source ./fault-function.sh
  die() {
    printf '%s\n' "$*" >&2
    return 1
  }
  cat > bin/kubectl << 'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$result_directory/real-kubectl"
SH
  chmod +x bin/kubectl
  export PATH="$FIXTURE_ROOT/bin:$PATH"
  cat > "$driver" << 'SH'
#!/usr/bin/env bash
set -e
[[ $1 == --release-sources-from-git ]]
kubectl --context k3d-source exec restore-volume-recipes -- tar -xpkf - --numeric-owner -C /data
kubectl --context k3d-disposable-target get pods
kubectl --context k3d-disposable-target exec restore-volume-recipes -- tar -xpkf - --numeric-owner -C /data
printf 'unexpectedly reached\n' > "$result_directory/after-fault"
SH
  local fault
  for fault in fail term; do
    phase="restore-$fault"
    run run_faulted_recovery restore "$fault" "$result_directory/$fault.log"
    [ "$status" -eq 0 ]
    [ "$(cat "$result_directory/$phase.fault")" = "$fault" ]
    [ ! -e "$result_directory/after-fault" ]
  done
  [ "$(wc -l < "$result_directory/real-kubectl")" -eq 6 ]
}

@test "interrupted reset fault is injected only after the actual configured data wipe" {
  use_mise_tools
  mkdir -p "$result_directory" bin
  export target_values="$FIXTURE_ROOT/target.json" driver="$FIXTURE_ROOT/reset-driver.sh"
  printf '{"context":"k3d-disposable-target"}\n' > "$target_values"
  sed -n '/^run_faulted_recovery() (/,/^)/p' .scripts/backup-recovery-k3d.sh > fault-function.sh
  # shellcheck source=/dev/null
  source ./fault-function.sh
  die() {
    printf '%s\n' "$*" >&2
    return 1
  }
  cat > bin/kubectl << 'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$result_directory/real-kubectl"
SH
  chmod +x bin/kubectl
  export PATH="$FIXTURE_ROOT/bin:$PATH"
  cat > "$driver" << 'SH'
#!/usr/bin/env bash
set -e
[[ $1 == --release-sources-from-git ]]
kubectl --context k3d-disposable-target exec restore-volume-recipes -- sh -ec 'find /data -mindepth 1 -maxdepth 1 -print -quit'
kubectl --context k3d-disposable-target exec restore-volume-recipes -- sh -ec 'test -d /data && find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
printf 'unexpectedly reached\n' > "$result_directory/after-fault"
SH
  phase=interrupted-reset
  run run_faulted_recovery reset term "$result_directory/reset.log"
  [ "$status" -eq 0 ]
  [ "$(cat "$result_directory/$phase.fault")" = term ]
  [ ! -e "$result_directory/after-fault" ]
  [ "$(wc -l < "$result_directory/real-kubectl")" -eq 2 ]
}

@test "faulted recovery refuses a failure that happened before the requested injection" {
  use_mise_tools
  mkdir -p "$result_directory"
  export target_values="$FIXTURE_ROOT/target.json" driver="$FIXTURE_ROOT/early-failure.sh"
  printf '{"context":"k3d-disposable-target"}\n' > "$target_values"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$driver"
  sed -n '/^run_faulted_recovery() (/,/^)/p' .scripts/backup-recovery-k3d.sh > fault-function.sh
  # shellcheck source=/dev/null
  source ./fault-function.sh
  die() {
    printf '%s\n' "$*" >&2
    return 1
  }
  phase=early-failure
  run run_faulted_recovery restore fail "$result_directory/early.log"
  [ "$status" -ne 0 ]
  [[ $output == *"before the requested fault was injected"* ]]
  [ ! -e "$result_directory/$phase.fault" ]
}

@test "post-release capture fault skips capacity probes and fails only after a real archive copy" {
  use_mise_tools
  mkdir -p "$result_directory" bin
  export target_values="$FIXTURE_ROOT/target.json" driver="$FIXTURE_ROOT/backup-driver.sh"
  printf '{"context":"k3d-disposable-target"}\n' > "$target_values"
  sed -n '/^run_faulted_recovery() (/,/^)/p' .scripts/backup-recovery-k3d.sh > fault-function.sh
  # shellcheck source=/dev/null
  source ./fault-function.sh
  die() {
    printf '%s\n' "$*" >&2
    return 1
  }
  cat > bin/kubectl << 'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$result_directory/real-kubectl"
SH
  chmod +x bin/kubectl
  export PATH="$FIXTURE_ROOT/bin:$PATH"
  cat > "$driver" << 'SH'
#!/usr/bin/env bash
set -e
[[ $1 == --release-sources-from-git ]]
kubectl --context k3d-disposable-target exec backup-volume-recipes -- sh -ec 'set -o pipefail; tar -C /data -cf - . | wc -c'
kubectl --context k3d-disposable-target exec backup-volume-recipes -- tar -C /data -cf - .
printf 'unexpectedly reached\n' > "$result_directory/after-fault"
SH
  phase=failed-post-release-capture
  run run_faulted_recovery backup fail "$result_directory/backup.log"
  [ "$status" -eq 0 ]
  [ "$(cat "$result_directory/$phase.fault")" = fail ]
  [ ! -e "$result_directory/after-fault" ]
  [ "$(wc -l < "$result_directory/real-kubectl")" -eq 2 ]
}

@test "sentinel verification checks contents and PVC UID in app and kube-system namespaces" {
  use_mise_tools
  mkdir -p "$result_directory/logs"
  export target_values=target.json driver=driver.sh
  printf '{"infrastructure":{"maintenance":"maintenance@sha256:test"}}\n' > "$target_values"
  sed -n '/^sentinel_volume() {/,/^}/p' .scripts/backup-recovery-k3d.sh > sentinel-function.sh
  # shellcheck source=/dev/null
  source ./sentinel-function.sh
  bash() {
    printf '%s\n' "$*" >> "$result_directory/driver-calls"
    case " $* " in
      *" create -f "*)
        local manifest=${!#}
        jq -e 'if .kind == "PersistentVolumeClaim" then
            .spec.storageClassName == "local-path"
            and .metadata.labels["app.kubernetes.io/part-of"] == null
          else .spec.automountServiceAccountToken == false
            and .spec.volumes[0].persistentVolumeClaim.claimName == .metadata.name
          end' "$manifest" > /dev/null
        ;;
      *" logs "*) printf '%s\n' "${SENTINEL_CONTENT:-unrelated-storage-must-survive}" ;;
      *" get pvc "*) printf '{"metadata":{"uid":"%s"}}\n' "${SENTINEL_UID:-original-uid}" ;;
    esac
  }
  sentinel_volume recipe-db rehearsal-unrelated create
  sentinel_volume recipe-db rehearsal-unrelated verify
  sentinel_volume kube-system recipe-db-acme create
  sentinel_volume kube-system recipe-db-acme verify
  grep -q -- '--namespace recipe-db ' "$result_directory/driver-calls"
  grep -q -- '--namespace kube-system ' "$result_directory/driver-calls"
  SENTINEL_UID=replaced-uid run sentinel_volume kube-system recipe-db-acme verify
  [ "$status" -ne 0 ]
  SENTINEL_CONTENT=overwritten run sentinel_volume recipe-db rehearsal-unrelated verify
  [ "$status" -ne 0 ]
}

@test "preservation checks reject changed application PVC and PV identities before sentinel verification" {
  use_mise_tools
  mkdir -p "$result_directory"
  export target_values=target.json driver=driver.sh
  sed -n '/^verify_preserved_storage() {/,/^}/p' .scripts/backup-recovery-k3d.sh > preserved-function.sh
  # shellcheck source=/dev/null
  source ./preserved-function.sh
  printf '[{"name":"recipes","uid":"original","volume":"pv-original"}]\n' \
    > "$result_directory/recovery-before-pvcs.json"
  bash() {
    jq -nc --arg uid "${PVC_UID:-original}" --arg volume "${PV_NAME:-pv-original}" \
      '{items:[{metadata:{name:"recipes",uid:$uid},spec:{volumeName:$volume}}]}'
  }
  sentinel_volume() { printf '%s\n' "$*" >> "$result_directory/sentinel-calls"; }
  run verify_preserved_storage unchanged
  [ "$status" -eq 0 ]
  [ "$(cat "$result_directory/sentinel-calls")" = $'recipe-db rehearsal-unrelated verify\nkube-system recipe-db-acme verify' ]
  PVC_UID=replaced run verify_preserved_storage replaced
  [ "$status" -ne 0 ]
  PV_NAME=other-volume run verify_preserved_storage rebound
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$result_directory/sentinel-calls")" -eq 2 ]
}

@test "recovery isolation requires retained holder, stopped workers and every public barrier route" {
  use_mise_tools
  mkdir -p "$result_directory/state"
  export target_values="$FIXTURE_ROOT/target.json" driver=driver.sh
  printf '{"origin":"http://127.0.0.1:22000"}\n' > "$target_values"
  printf '{"status":"recovery-required","holder":"original"}\n' \
    > "$result_directory/state/restore-state.json"
  printf '{"items":[]}\n' > "$result_directory/pods.json"
  sed -n '/^verify_recovery_isolation() {/,/^}/p; /^verify_recovery_barrier() {/,/^}/p' \
    .scripts/backup-recovery-k3d.sh > isolation-function.sh
  # shellcheck source=/dev/null
  source ./isolation-function.sh
  die() {
    printf '%s\n' "$*" >&2
    return 1
  }
  bash() {
    case " $* " in
      *" get lease "*) printf '{"spec":{"holderIdentity":"%s"}}\n' "${LEASE_HOLDER:-original}" ;;
      *" get pods "*) cat "$result_directory/pods.json" ;;
    esac
  }
  curl() {
    if [[ ${BARRIER_FAIL:-false} == true && ${!#} == */graphql ]]; then
      printf 200
    else
      printf 503
    fi
  }
  run verify_recovery_isolation "$result_directory/state"
  [ "$status" -eq 0 ]
  LEASE_HOLDER=another-holder run verify_recovery_isolation "$result_directory/state"
  [ "$status" -ne 0 ]
  BARRIER_FAIL=true run verify_recovery_isolation "$result_directory/state"
  [ "$status" -ne 0 ]
  [[ $output == *"did not block /graphql"* ]]
  printf '{"items":[{"metadata":{"labels":{"app.kubernetes.io/part-of":"recipe-db"}},"status":{"phase":"Running"},"spec":{"volumes":[]}}]}\n' \
    > "$result_directory/pods.json"
  run verify_recovery_isolation "$result_directory/state"
  [ "$status" -ne 0 ]
  printf '{"items":[{"metadata":{},"status":{"phase":"Running"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"recipes"}}]}}]}\n' \
    > "$result_directory/pods.json"
  run verify_recovery_isolation "$result_directory/state"
  [ "$status" -ne 0 ]
}

@test "reset-again rehearsals refresh the consumed discard preview before every retry" {
  mkdir -p "$result_directory"
  local driver=driver.sh target_values=target.json package_manifest=manifest.json
  local archive=backup.tar backup_id=backup-test
  sed -n '/^phase=interrupted-reset-reset-again/,/^phase=reset-again-recovery-restore/p' \
    .scripts/backup-recovery-k3d.sh > retry-steps.sh
  run_logged() {
    shift
    "$@"
  }
  release_lifecycle() { printf '%s\n' "$1" >> "$result_directory/retry-operations"; }
  run_faulted_recovery() { return 0; }
  verify_recovery_isolation() { return 0; }
  verify_preserved_storage() { return 0; }
  mark() { return 0; }
  # shellcheck source=/dev/null
  source ./retry-steps.sh
  [ "$(cat "$result_directory/retry-operations")" = $'recovery-plan\nrecovery-reset\nrecovery-plan\nrecovery-reset\nrecovery-plan\nrecovery-reset' ]
}

@test "retained release captures maintenance and checks read-only data before reopening" {
  use_mise_tools
  mkdir -p "$result_directory/logs" "$result_directory/state"
  sed -n '/^phase=retained-release-preparation$/,/^phase=retained-failed-release$/p' \
    .scripts/backup-recovery-k3d.sh | sed '$d' > retained-release-steps.sh
  cat > retained-release-test.sh << 'SH'
set -e
target_values=target.yaml release=source candidate_release=candidate recipe_name=fixture
upload=upload.py
run_logged() { shift; "$@"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
mark() { :; }
sleep() { :; }
release_lifecycle() {
  local operation=$1
  shift
  printf '%s\n' "$operation" >> "$result_directory/operations"
  case "$operation" in
    maintenance-enter)
      [[ $3 == "$result_directory/state/maintenance" && ! -e $3 ]]
      mkdir "$3"
      printf '{"backupId":"backup-1-2","status":"maintenance-mode","phase":"maintenance-entered"}\n' > "$3/backup-state.json" ;;
    backup-capture)
      jq -e '.status == "maintenance-mode" and .phase == "maintenance-entered"' "$2/backup-state.json" > /dev/null
      printf '{"backupId":"backup-1-2","status":"captured","phase":"captured"}\n' > "$2/backup-state.json" ;;
    release-stage)
      jq -e '.status == "captured"' "$2/backup-state.json" > /dev/null
      [[ $4 == verified-upload && $5 == VERIFIED-backup-1-2-verified-upload ]] ;;
    release-migration-plan)
      printf '{"migrationResult":{"outcome":"no-migration-required"}}\n' > "$2/backup-state.json" ;;
    release-start)
      printf '{"status":"release-ready","phase":"ready"}\n' > "$2/backup-state.json" ;;
    release-readonly-result)
      [[ $4 == passed && $6 == READONLY-backup-1-2-passed ]]
      jq -e '.status == "release-ready" and .phase == "ready"' "$2/backup-state.json" > /dev/null
      grep -Fxq 'fixture-read' "$result_directory/operations"
      printf '{"readOnlyCheck":{"outcome":"passed"}}\n' > "$2/backup-state.json" ;;
    release-reopen)
      jq -e '.readOnlyCheck.outcome == "passed"' "$2/backup-state.json" > /dev/null ;;
    release-website-result) : ;;
    *) return 1 ;;
  esac
}
python3() {
  jq -e '.status == "captured" and .phase == "captured"' \
    "$result_directory/state/maintenance/backup-state.json" > /dev/null
  printf '{"backupId":"backup-1-2","status":"verified-upload"}\n' > "$result_directory/state/status.json"
}
verify_fixture_recipe() {
  printf 'fixture-read\n' >> "$result_directory/operations"
  [[ ${FAIL_READ:-false} != true ]]
}
source ./retained-release-steps.sh
SH
  run bash retained-release-test.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$result_directory/operations")" = $'maintenance-enter\nbackup-capture\nrelease-stage\nrelease-migration-plan\nrelease-start\nfixture-read\nrelease-readonly-result\nrelease-reopen\nfixture-read\nrelease-website-result' ]

  rm -rf "$result_directory/state/maintenance"
  : > "$result_directory/operations"
  FAIL_READ=true run bash retained-release-test.sh
  [ "$status" -ne 0 ]
  ! grep -Eq 'release-readonly-result|release-reopen' "$result_directory/operations"
}

@test "closeout recovery ownership checks require the exact retained UID holder operation and phase" {
  use_mise_tools
  mkdir -p "$result_directory"
  # shellcheck disable=SC2034
  local driver=driver.sh target_values=target.yaml release_holder=original-holder release_lease_uid=original-uid
  sed -n '/^verify_retained_recovery_lease() {/,/^}/p' .scripts/backup-recovery-k3d.sh > retained-function.sh
  # shellcheck source=/dev/null
  source ./retained-function.sh
  bash() {
    jq -nc --arg uid "${LEASE_UID:-original-uid}" --arg holder "${LEASE_HOLDER:-original-holder}" \
      --arg operation "${LEASE_OPERATION:-restore}" --arg phase "${LEASE_PHASE:-recovery-ready}" \
      '{metadata:{uid:$uid,annotations:{"recipe-db/operation":$operation,"recipe-db/phase":$phase}},
        spec:{holderIdentity:$holder}}'
  }
  run verify_retained_recovery_lease closeout recovery-ready
  [ "$status" -eq 0 ]
  LEASE_UID=recreated run verify_retained_recovery_lease closeout recovery-ready
  [ "$status" -ne 0 ]
  LEASE_HOLDER=another run verify_retained_recovery_lease closeout recovery-ready
  [ "$status" -ne 0 ]
  LEASE_OPERATION=backup run verify_retained_recovery_lease closeout recovery-ready
  [ "$status" -ne 0 ]
  LEASE_PHASE=unknown run verify_retained_recovery_lease closeout recovery-ready
  [ "$status" -ne 0 ]
  LEASE_PHASE=reset-ready run verify_retained_recovery_lease reset reset-ready
  [ "$status" -eq 0 ]
}

@test "deploy and backup-enter must both refuse without mutating retained recovery resources" {
  use_mise_tools
  mkdir -p "$result_directory/logs"
  local driver=driver.sh target_values=target.yaml release=source-release
  sed -n '/^verify_recovery_refusals() {/,/^}/p' .scripts/backup-recovery-k3d.sh > refusal-function.sh
  # shellcheck source=/dev/null
  source ./refusal-function.sh
  die() {
    printf '%s\n' "$*" >&2
    return 1
  }
  recovery_guard_snapshot() { printf '%s\n' "${GUARD_STATE:-unchanged}" > "$1"; }
  bash() {
    printf '%s\n' "$*" >> "$result_directory/deploy-calls"
    [[ ${ACCEPT_DEPLOY:-false} == true ]]
  }
  release_lifecycle() {
    printf '%s\n' "$*" >> "$result_directory/backup-calls"
    if [[ ${MUTATE_BACKUP:-false} == true ]]; then GUARD_STATE=mutated; fi
    [[ ${ACCEPT_BACKUP:-false} == true ]]
  }
  run verify_recovery_refusals closeout
  [ "$status" -eq 0 ]
  [ "$(cat "$result_directory/deploy-calls")" = 'driver.sh deploy target.yaml source-release' ]
  [ "$(cat "$result_directory/backup-calls")" = "backup-enter target.yaml source-release $result_directory/state/closeout-refused-backup" ]
  ACCEPT_DEPLOY=true run verify_recovery_refusals closeout
  [ "$status" -ne 0 ]
  ACCEPT_BACKUP=true run verify_recovery_refusals closeout
  [ "$status" -ne 0 ]
  MUTATE_BACKUP=true run verify_recovery_refusals closeout
  [ "$status" -ne 0 ]
}

@test "retained failed release requires its exact phase and a successful fixture read after the failure" {
  use_mise_tools
  mkdir -p "$result_directory/logs" "$result_directory/release-state"
  local driver=driver.sh target_values=target.yaml candidate_release=candidate recipe_name=fixture
  local release_state="$result_directory/release-state" release_holder=original-holder
  sed -n '/^phase=retained-failed-release$/,/^phase=retained-failed-release-closeout$/p' \
    .scripts/backup-recovery-k3d.sh | sed '$d' > failed-release-steps.sh
  run_faulted_recovery() {
    printf 'failure\n' >> "$result_directory/order"
    jq -nc --arg phase "${FAILED_PHASE:-post-release-backup-failed}" \
      '{status:"recovery-required",phase:$phase}' > "$release_state/backup-state.json"
  }
  verify_preserved_storage() { return 0; }
  bash() { printf '{"metadata":{"uid":"original-uid"},"spec":{"holderIdentity":"original-holder"}}\n'; }
  verify_fixture_recipe() {
    printf 'normal-read\n' >> "$result_directory/order"
    [[ ${READ_FAIL:-false} != true ]]
  }
  mark() { printf 'verified\n' >> "$result_directory/order"; }
  {
    printf 'set -e\n'
    declare -p result_directory driver target_values candidate_release recipe_name release_state release_holder
    declare -f run_faulted_recovery verify_preserved_storage bash verify_fixture_recipe mark
    printf 'source ./failed-release-steps.sh\n'
  } > failed-release-harness.sh
  run command bash failed-release-harness.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$result_directory/order")" = $'failure\nnormal-read\nverified' ]
  FAILED_PHASE=post-release-backup-recovery-required run command bash failed-release-harness.sh
  [ "$status" -ne 0 ]
  READ_FAIL=true run command bash failed-release-harness.sh
  [ "$status" -ne 0 ]
}
