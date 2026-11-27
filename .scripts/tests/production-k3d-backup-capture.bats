#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "capture archives unrecognized nested authoritative data without interpreting it" {
  export MOCK_BACKUP=true
  printf 'not a recognized application format\n' > "$FIXTURE_ROOT/tar-data/tags/tags.sqlite"
  mkdir -p "$FIXTURE_ROOT/tar-data/tags/nested" "$FIXTURE_ROOT/tar-data/tags/empty"
  printf '\000opaque data\n' > "$FIXTURE_ROOT/tar-data/tags/nested/data.bin"
  local snapshot="$FIXTURE_ROOT/backups/opaque"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  jq -e 'all(.inventory[]; has("layout") | not) and
    any(.inventory[] | select(.service == "tags").files[];
      .path == "nested/data.bin") and
    any(.inventory[] | select(.service == "tags").directories[]; . == "empty") and
    any(.inventory[] | select(.service == "tags").directoryMetadata[];
      .path == "empty" and (.mode | type == "number") and
      (.uid | type == "number") and (.gid | type == "number"))' "$snapshot/manifest.json"
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "captured snapshot passes the uploader's real validation and packaging boundary" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/publisher-boundary"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  mkdir -p provisioning/files "$FIXTURE_ROOT/package-stage"
  cp "$BATS_TEST_DIRNAME/../../provisioning/files/backup-upload.py" provisioning/files/
  run python3 - "$snapshot" "$FIXTURE_ROOT/package-stage" << 'PY'
import importlib.util
import pathlib
import sys

module_path = pathlib.Path("provisioning/files/backup-upload.py")
spec = importlib.util.spec_from_file_location("backup_upload", module_path)
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)
snapshot = pathlib.Path(sys.argv[1])
stage = pathlib.Path(sys.argv[2])
manifest = upload.validate_snapshot(snapshot)
package = upload.create_package(
    snapshot, stage, manifest, "pi-rehearsal", upload.DEFAULT_MAX_STAGING_BYTES)
assert (stage / package["manifest"]).is_file()
assert (stage / package["archive"]).is_file()
print(package["backupId"])
PY
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -r .backupId "$snapshot/manifest.json")" ]
}

@test "capture measures actual archive bytes instead of trusting unenforced PVC requests" {
  export MOCK_BACKUP=true
  export MOCK_ARCHIVE_BYTES
  MOCK_ARCHIVE_BYTES=$(df -Pk "$FIXTURE_ROOT/backups" \
    | awk 'NR == 2 {printf "%.0f\n", $4 * 1024 - 67108864 + 1}')
  local snapshot="$FIXTURE_ROOT/backups/insufficient-measured-space"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"measured archive capacity"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -q 'exec backup-copy-.*-- tar -C' "$MOCK_LOG"
}

@test "maintenance entry refuses insufficient capacity before blocking writes" {
  export MOCK_BACKUP=true
  yq -i '.volumes.recipes = "99999999Gi"' "$VALUES"
  local snapshot="$FIXTURE_ROOT/backups/maintenance"
  run bash .scripts/production-k3d.sh maintenance-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"snapshot filesystem needs selected PVC capacity"* ]]
  [ ! -e "$snapshot" ]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -Eq ' (scale|set env) deployment/' "$MOCK_LOG"
}

@test "capture respects the publisher staging bound before copying a PVC archive" {
  export MOCK_BACKUP=true RECIPE_DB_BACKUP_MAX_SNAPSHOT_BYTES=1
  local snapshot="$FIXTURE_ROOT/backups/staging-limit"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"snapshot exceeds configured staging limit"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$snapshot/recipes.tar" ]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -q 'exec backup-copy-.*-- tar -C' "$MOCK_LOG"
}
