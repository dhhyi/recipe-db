#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture lib/production-restore.sh
  export FIXTURE_ROOT
  use_mise_tools
  setup_mock_bin
  cp "$BATS_TEST_DIRNAME/../validate-backup-snapshot.py" .scripts/
  mkdir -p work/validated data
  printf '{"volumes":{"recipes":"1Gi"}}\n' > work/config.json
  printf '{"name":"recipes","backupData":{"kind":"sqlite","file":"recipes.sqlite3"}}\n' > work/projects.jsonl
  printf '{"name":"recipes","uid":"stable-claim"}\n' > work/restore-pvc-identities.jsonl
  python3 - "$FIXTURE_ROOT/work" << 'PY'
import hashlib, io, json, pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1])
content = b"SQLite format 3\x00fixture\n"
with tarfile.open(root / "validated/recipes.tar", "w") as archive:
    item = tarfile.TarInfo("recipes.sqlite3")
    item.size = len(content)
    item.mode = 0o640
    item.uid, item.gid = 12345, 23456
    item.uname, item.gname = "root", "root"
    archive.addfile(item, io.BytesIO(content))
(root / "restore-manifest.json").write_text(json.dumps({"inventory":[{
    "service":"recipes", "archive":"recipes.tar",
    "files":[{"path":"recipes.sqlite3","sizeBytes":len(content),
              "sha256":hashlib.sha256(content).hexdigest()}]}]}))
PY
  cat > .scripts/restore-import-harness.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$FIXTURE_ROOT
work=$root/work
namespace=recipe-db
timeout=3
source "$root/.scripts/production-restore.sh"
restore_phase() { printf 'phase %s\n' "$*" >> "$MOCK_LOG"; }
backup_wait_pod_gone() { return 0; }
kube() {
  printf 'kube %s\n' "$*" >> "$MOCK_LOG"
  case "$*" in
    "get pvc recipes -o json")
      echo '{"metadata":{"uid":"stable-claim"},"status":{"phase":"Bound"}}' ;;
    "get pods -o json")
      jq -n --arg extra "${MOCK_EXTRA_MOUNT:-false}" '{items:[
        {metadata:{name:"restore-volume-recipes",labels:{"app.kubernetes.io/name":"restore-volume"}},
          spec:{volumes:[{persistentVolumeClaim:{claimName:"recipes"}}]}}] +
        (if $extra == "true" then [
          {metadata:{name:"unexpected-writer"},spec:{volumes:[
            {persistentVolumeClaim:{claimName:"recipes"}}]}}] else [] end)}' ;;
    "exec restore-volume-recipes -- sh -ec "*)
      [[ -z $(find "$root/data" -mindepth 1 -maxdepth 1 -print -quit) ]] ;;
    "exec -i restore-volume-recipes -- tar -xpkf - --numeric-owner -C /data")
      [[ ${MOCK_TRANSFER_FAIL:-false} != true ]] || return 1
      # The real helper runs as root. Check its exact numeric-owner command above,
      # then avoid changing ownership on the non-root regression-test host.
      tar -xpkf - --no-same-owner -C "$root/data" ;;
    "exec restore-volume-recipes -- sync") ;;
    "exec restore-volume-recipes -- tar -C /data -cf - .")
      tar -C "$root/data" -cf - . ;;
    "delete pod restore-volume-recipes "*) touch "$root/helper-deleted" ;;
    *) return 1 ;;
  esac
}
restore_import
EOF
}

@test "restore import preserves numeric ownership rather than mapping archived usernames in the helper image" {
  run bash .scripts/restore-import-harness.sh
  [ "$status" -eq 0 ]
  grep -q 'tar -xpkf - --numeric-owner -C /data' "$MOCK_LOG"
  [ "$(stat -c '%a' data/recipes.sqlite3)" = 640 ]
  [ -e helper-deleted ]
}

@test "restore import rejects another Pod mounted on the selected PVC before extracting any bytes" {
  export MOCK_EXTRA_MOUNT=true
  run bash .scripts/restore-import-harness.sh
  [ "$status" -ne 0 ]
  [ ! -e data/recipes.sqlite3 ]
  [ ! -e helper-deleted ]
  run ! grep -q 'exec -i' "$MOCK_LOG"
}

@test "restore import stops at transfer failure without verifying partial data or removing its helper" {
  export MOCK_TRANSFER_FAIL=true
  run bash .scripts/restore-import-harness.sh
  [ "$status" -ne 0 ]
  [ ! -e helper-deleted ]
  run ! grep -Eq 'tar -C /data -cf|delete pod' "$MOCK_LOG"
}

@test "restore import treats empty directories and dangling symlinks as populated data" {
  mkdir data/empty-directory
  run bash .scripts/restore-import-harness.sh
  [ "$status" -ne 0 ]
  [ -d data/empty-directory ]
  run ! grep -q 'exec -i' "$MOCK_LOG"
  rmdir data/empty-directory
  ln -s ../absent-target data/dangling-link
  : > "$MOCK_LOG"
  run bash .scripts/restore-import-harness.sh
  [ "$status" -ne 0 ]
  [ -L data/dangling-link ]
  [ ! -e data/recipes.sqlite3 ]
  run ! grep -q 'exec -i' "$MOCK_LOG"
}
