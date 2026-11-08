#!/usr/bin/env bats
# Test-local lifecycle globals are intentionally reused across isolated Bats tests.
# shellcheck disable=SC2030,SC2031

load test_helper

setup() {
  setup_fixture backup-recovery-k3d.sh
  export FAKE_RCLONE_ROOT="$FIXTURE_ROOT/fake-remote"
  export result_directory="$FIXTURE_ROOT/results"
}

@test "k3d rehearsal rejects mutable artifacts before creating result files or invoking tools" {
  run bash .scripts/backup-recovery-k3d.sh ghcr.io/dhhyi/recipe-db-releases:latest \
    "$FIXTURE_ROOT/results"
  [ "$status" -ne 0 ]
  [[ $output == *"immutable recipe-db release artifact"* ]]
  [ ! -e "$FIXTURE_ROOT/results" ]
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
  sed -n '/^write_values() {/,/^}/p' .scripts/backup-recovery-k3d.sh > write-values.sh
  # shellcheck source=/dev/null
  source ./write-values.sh
  local side values
  for side in s t; do
    values="$FIXTURE_ROOT/$side.yaml"
    write_values "recipe-db-rehearsal-regression-$side" 22001 32001 "$values"
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
