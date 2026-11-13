#!/usr/bin/env bash

restore_fixture() {
  export MOCK_RESTORE=true MOCK_BACKUP=false
  export RESTORE_ID=backup-20261031123456-42
  export RESTORE_MANIFEST="$FIXTURE_ROOT/backup-package.json" RESTORE_ARCHIVE="$FIXTURE_ROOT/package.tar"
  export RESTORE_STATE="$FIXTURE_ROOT/backups/restore"
  printf '{"anonymous":{"role":"anonymous"},"tokens":[{"id":"restore-owner","secret":"private-restore-token","role":"owner"}],"googleAccounts":{}}\n' > auth-accounts.json
  rm "$FIXTURE_ROOT/tar-data/recipes/recipes.sqlite3"
  python3 - "$FIXTURE_ROOT/tar-data/recipes/recipes.sqlite3" << 'PY'
import json, sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("CREATE TABLE recipes (id TEXT PRIMARY KEY, document TEXT NOT NULL)")
    db.execute("INSERT INTO recipes VALUES (?, ?)", ("old", json.dumps({"name":"Old"})))
PY
  if [[ ${MOCK_RESTORE_IMAGE:-false} == true ]]; then
    printf 'restored-full-image\n' > image-full
    printf 'restored-thumbnail\n' > image-thumb
    full_sha=$(sha256sum image-full)
    full_sha=${full_sha%% *}
    thumb_sha=$(sha256sum image-thumb)
    thumb_sha=${thumb_sha%% *}
    cp image-full "$FIXTURE_ROOT/tar-data/images/public/old-$full_sha.png"
    cp image-thumb "$FIXTURE_ROOT/tar-data/images/public/old-$thumb_sha-thumb.png"
    jq -n --arg full "/public/old-$full_sha.png" --arg thumb "/public/old-$thumb_sha-thumb.png" \
      --argjson size "$(stat -c '%s' image-full)" \
      '{recipeId:"old",url:$full,thumbUrl:$thumb,size:$size}' \
      > "$FIXTURE_ROOT/tar-data/images/manifests/old.json"
  fi
  : > restore-archives.jsonl
  for name in recipes images tags; do
    tar -C "$FIXTURE_ROOT/tar-data/$name" -cf "$FIXTURE_ROOT/$name.tar" .
    case "$name" in
      recipes) layout='{"kind":"sqlite","file":"recipes.sqlite3"}' ;;
      tags) layout='{"kind":"sqlite","file":"tags.sqlite"}' ;;
      images) layout='{"kind":"images"}' ;;
    esac
    python3 .scripts/validate-backup-snapshot.py "$FIXTURE_ROOT/$name.tar" "$layout" > "$name-files.json"
    jq -cn --arg name "$name" --slurpfile files "$name-files.json" \
      '{service:$name,archive:($name+".tar"),files:$files[0]}' >> restore-archives.jsonl
  done
  jq -n --arg id "$RESTORE_ID" --arg artifact "$ARTIFACT" --arg revision "$MOCK_REVISION" \
    --slurpfile archives restore-archives.jsonl \
    '{backupId:$id,source:{artifact:$artifact,revision:$revision},inventory:$archives}' > "$RESTORE_MANIFEST"
  printf 'package-fixture\n' > "$RESTORE_ARCHIVE"
  cat > .scripts/validate-backup-package.py << 'PY'
import json, os, pathlib, shutil, sys
if os.environ.get("MOCK_RESTORE_PACKAGE_FAIL") == "true":
    print("production: package validation failed", file=sys.stderr)
    sys.exit(1)
manifest, archive, output, projects, expected = sys.argv[1:]
package = json.loads(pathlib.Path(manifest).read_text())
assert package["backupId"] == expected
assert pathlib.Path(archive).is_file() and pathlib.Path(projects).is_file()
pathlib.Path(output).mkdir()
for item in package["inventory"]:
    shutil.copy(pathlib.Path(manifest).parent / item["archive"], pathlib.Path(output) / item["archive"])
print(json.dumps(package))
PY
  cat > bin/curl << 'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$MOCK_LOG"
if [[ ${MOCK_RESTORE_HTTP_FAIL:-false} == true ]]; then exit 1; fi
if [[ $* == *"api/http/routers"* ]]; then
  if [[ ${MOCK_RESTORE_ROUTE_STALE:-false} == true ]]; then
    echo '[{"name":"restore-public-barrier@file","status":"enabled"}]'
  else echo '[{"name":"graphql@file","status":"enabled"}]'; fi
  exit
fi
if [[ $* == *"/public/"* ]]; then
  url="${*: -1}"; name="${url##*/}"
  cat "$FIXTURE_ROOT/tar-data/images/public/$name"
  exit
fi
if [[ $* == *"18082"* ]]; then
  if [[ $* == *"recipe/old"* ]]; then echo Old; exit; fi
  if [[ -e $MOCK_LOG.probe-deleted ]]; then
    if [[ $* == *"--write-out"* ]]; then printf 404; exit; else exit 22; fi
  fi
  cat "$MOCK_LOG.probe-name"; exit
fi
file=
for argument in "$@"; do case "$argument" in @*) file="${argument#@}" ;; esac; done
query=$(jq -r .query "$file")
case "$query" in
  *"createRecipe"*)
    sequence=$(cat "$MOCK_LOG.stream-sequence" 2>/dev/null || echo 0)
    printf '%s\n' "$((sequence + 1))" > "$MOCK_LOG.stream-sequence"
    jq -r .variables.name "$file" > "$MOCK_LOG.probe-name"
    touch "$MOCK_LOG.probe-created"
    echo '{"data":{"createRecipe":{"id":"probe"}}}' ;;
  *"updateRecipe"*)
    sequence=$(cat "$MOCK_LOG.stream-sequence" 2>/dev/null || echo 0)
    printf '%s\n' "$((sequence + 1))" > "$MOCK_LOG.stream-sequence"
    jq -r .variables.name "$file" > "$MOCK_LOG.probe-name"
    echo '{"data":{"updateRecipe":{"id":"probe"}}}' ;;
  *"deleteRecipe"*)
    sequence=$(cat "$MOCK_LOG.stream-sequence" 2>/dev/null || echo 0)
    printf '%s\n' "$((sequence + 1))" > "$MOCK_LOG.stream-sequence"
    touch "$MOCK_LOG.probe-deleted"
    echo '{"data":{"deleteRecipe":true}}' ;;
  *"searchRecipes"*)
    if [[ ${MOCK_RESTORE_PAUSE_PROBE:-false} == true && -e $MOCK_LOG.probe-name ]]; then
      touch "$MOCK_LOG.probe-paused"
      sleep 2
    fi
    if [[ $* == *"restore-request"* && $(jq -r '.variables.options.q' "$file") == "*" ]]; then
      echo '{"data":{"searchRecipes":{"recipes":[{"id":"old","name":"Old"}],"found":1}}}'
    elif [[ -e $MOCK_LOG.probe-deleted || ${MOCK_RESTORE_PROPAGATION_FAIL:-false} == true ]]; then echo '{"data":{"searchRecipes":{"recipes":[]}}}'
    else jq -n --rawfile name "$MOCK_LOG.probe-name" '{data:{searchRecipes:{recipes:[{id:"probe",name:($name|rtrimstr("\n"))}]}}}'; fi ;;
  *"recipe(id"*)
    if [[ ${MOCK_RESTORE_IMAGE:-false} == true ]]; then
      jq '{data:{recipe:{id:"old",name:"Old",image:{url:.url,thumbUrl:.thumbUrl},rating:{count:0}}}}' \
        "$FIXTURE_ROOT/tar-data/images/manifests/old.json"
    else echo '{"data":{"recipe":{"id":"old","name":"Old","image":null,"rating":{"count":0}}}}'; fi ;;
  *) echo '{"data":{"recipes":[{"id":"old","name":"Old"}]}}' ;;
esac
EOF
  chmod +x bin/curl
}

run_restore() {
  run bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" \
    "$RESTORE_ARCHIVE" "$RESTORE_ID" "$RESTORE_STATE" "RESTORE-$RESTORE_ID"
}

restore_real_package_fixture() {
  restore_fixture
  cp "$BATS_TEST_DIRNAME/../validate-backup-package.py" .scripts/
  mkdir -p provisioning/files capture
  chmod 700 capture
  cp "$BATS_TEST_DIRNAME/../../provisioning/files/backup-upload.py" provisioning/files/
  rm "$FIXTURE_ROOT/tar-data/tags/tags.sqlite" "$FIXTURE_ROOT/tar-data/tags/tags.sqlite-wal"
  python3 - "$FIXTURE_ROOT/tar-data/tags/tags.sqlite" << 'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as database:
    database.execute("CREATE TABLE records (id TEXT PRIMARY KEY, value TEXT)")
PY
  python3 - "$FIXTURE_ROOT" "$RESTORE_ID" "$ARTIFACT" "$MOCK_REVISION" << 'PY'
import hashlib, importlib.util, json, pathlib, sys, tarfile
root, backup_id, artifact, revision = sys.argv[1:]
root = pathlib.Path(root)
spec = importlib.util.spec_from_file_location("upload", root / "provisioning/files/backup-upload.py")
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)
spec = importlib.util.spec_from_file_location("snapshot", root / ".scripts/validate-backup-snapshot.py")
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)
inventory = []
layouts = {"recipes":{"kind":"sqlite","file":"recipes.sqlite3"},
           "tags":{"kind":"sqlite","file":"tags.sqlite"}, "images":{"kind":"images"}}
for name, layout in layouts.items():
    archive = root / "capture" / f"{name}.tar"
    with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as output:
        output.add(root / "tar-data" / name, arcname=".")
    archive.chmod(0o600)
    files = snapshot.validate(archive, layout)
    inventory.append({"service":name,
                      "role":"authoritative-read-only" if name == "recipes" else "cleanup-participant",
                      "pvc":name, "archive":archive.name, "sizeBytes":archive.stat().st_size,
                      "sha256":hashlib.sha256(archive.read_bytes()).hexdigest(),
                      "fileCount":len(files), "files":files})
manifest = {"format":upload.FORMAT,"formatVersion":1,"backupId":backup_id,
            "capturedAt":"2026-10-31T12:34:56Z",
            "source":{"target":"local","cluster":"recipe-db-rehearsal",
                      "context":"k3d-recipe-db-rehearsal","namespace":"recipe-db",
                      "artifact":artifact,"revision":revision},"inventory":inventory}
path = root / "capture/manifest.json"
path.write_bytes(upload.json_bytes(manifest))
path.chmod(0o600)
package = upload.create_package(root / "capture", root, manifest, "local-fixture", upload.DEFAULT_MAX_STAGING_BYTES)
(root / package["archive"]).chmod(0o600)
(root / "real-package-paths.json").write_text(json.dumps(package))
PY
  RESTORE_MANIFEST="$FIXTURE_ROOT/$(jq -r .manifest real-package-paths.json)"
  RESTORE_ARCHIVE="$FIXTURE_ROOT/$(jq -r .archive real-package-paths.json)"
}
