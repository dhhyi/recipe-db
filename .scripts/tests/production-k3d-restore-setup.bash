#!/usr/bin/env bash

restore_fixture() {
  export MOCK_RESTORE=true MOCK_BACKUP=false
  export RESTORE_ID=backup-20261031123456-42
  export RESTORE_MANIFEST="$FIXTURE_ROOT/backup-package.json" RESTORE_ARCHIVE="$FIXTURE_ROOT/package.tar"
  export RESTORE_STATE="$FIXTURE_ROOT/backups/restore"
  printf '1\n' > "$FIXTURE_ROOT/tar-data/images/storage-version"
  printf '{"anonymous":{"role":"anonymous"},"tokens":[{"id":"restore-owner","secret":"private-restore-token","role":"owner"}],"googleAccounts":{}}\n' > auth-accounts.json
  rm -rf "$FIXTURE_ROOT/tar-data/recipes"
  mkdir -p "$FIXTURE_ROOT/tar-data/recipes/nested"
  printf '\000opaque recipe volume data\n' \
    > "$FIXTURE_ROOT/tar-data/recipes/nested/data.bin"
  if [[ ${MOCK_RESTORE_IMAGE:-false} == true ]]; then
    printf 'restored-full-image\n' > image-full
    printf 'restored-thumbnail\n' > image-thumb
    cp image-full "$FIXTURE_ROOT/tar-data/images/public/full.bin"
    cp image-thumb "$FIXTURE_ROOT/tar-data/images/public/thumb.bin"
  fi
  : > restore-archives.jsonl
  for name in recipes images tags; do
    tar -C "$FIXTURE_ROOT/tar-data/$name" -cf "$FIXTURE_ROOT/$name.tar" .
    python3 .scripts/validate-backup-snapshot.py "$FIXTURE_ROOT/$name.tar" > "$name-files.json"
    jq -cn --arg name "$name" --slurpfile files "$name-files.json" \
      '{service:$name,archive:($name+".tar"),files:$files[0]}' >> restore-archives.jsonl
  done
  jq -n --arg id "$RESTORE_ID" --arg artifact "$ARTIFACT" --arg revision "$MOCK_REVISION" \
    --arg capturedAt "2026-10-31T12:34:56Z" \
    --slurpfile archives restore-archives.jsonl \
    '{backupId:$id,capturedAt:$capturedAt,source:{artifact:$artifact,revision:$revision},inventory:$archives}' \
    > "$RESTORE_MANIFEST"
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
  previous=
  for argument in "$@"; do
    if [[ $previous == --output ]]; then output=$argument; fi
    previous=$argument
  done
  cat "$FIXTURE_ROOT/tar-data/images/public/$name" > "$output"
  printf 200
  exit
fi
if [[ $* == *"18082"* ]]; then
  previous=
  for argument in "$@"; do
    if [[ $previous == --dump-header ]]; then printf 'ETag: "cached"\r\n' > "$argument"; fi
    previous=$argument
  done
  echo Old; exit
fi
file=
for argument in "$@"; do case "$argument" in @*) file="${argument#@}" ;; esac; done
query=$(jq -r .query "$file")
case "$query" in
  *"mutation"* | *"createRecipe"* | *"updateRecipe"* | *"deleteRecipe"*)
    touch "$MOCK_LOG.restore-mutation-attempt"
    echo '{"errors":[{"message":"restore verification must be read-only"}]}' ;;
  *"query { maintenance }"*)
    mode=$(jq -r '[.items[] | select(.metadata.name == "graphql") |
      .spec.template.spec.containers[] | select(.name == "graphql") |
      .env[]? | select(.name == "MODE") | .value][0] // "backup"' \
      "$MOCK_LOG.restore-deployments")
    if [[ $mode == maintenance ]]; then
      echo '{"data":{"maintenance":true}}'
    else echo '{"data":{"maintenance":false}}'; fi ;;
  *"maintenance"*"recipes"*)
    if [[ ${MOCK_RESTORE_PAUSE_READS:-false} == true ]]; then
      touch "$MOCK_LOG.reads-paused"
      sleep 2
    fi
    if [[ ${MOCK_RESTORE_READ_FAIL:-false} == true ]]; then
      echo '{"errors":[{"message":"synthetic read check failure"}]}'
    elif [[ ${MOCK_RESTORE_EMPTY:-false} == true ]]; then
      echo '{"data":{"maintenance":true,"recipes":[]}}'
    else echo '{"data":{"maintenance":true,"recipes":[{"id":"old","name":"Old"}]}}'; fi ;;
  *"searchRecipes"*)
    if [[ $(jq -r '.variables.options.filter_by // empty' "$file") == 'id:=`old`' ]]; then
      echo '{"data":{"searchRecipes":{"recipes":[{"id":"old","name":"Old"}],"found":1}}}'
    else echo '{"data":{"searchRecipes":{"recipes":[],"found":0}}}'; fi ;;
  *"recipe(id"*)
    if [[ ${MOCK_RESTORE_IMAGE:-false} == true ]]; then
      echo '{"data":{"recipe":{"id":"old","name":"Old","image":{"url":"/public/full.bin","thumbUrl":"/public/thumb.bin"},"rating":{"count":0}}}}'
    else echo '{"data":{"recipe":{"id":"old","name":"Old","image":null,"rating":{"count":0}}}}'; fi ;;
  *) echo '{"data":{"recipes":[{"id":"old","name":"Old"}]}}' ;;
esac
EOF
  chmod +x bin/curl
}

pi_https_restore_values() {
  export MOCK_PI=true MOCK_LAN=true MOCK_HTTPS=true
  set_value '.target="pi" | .cluster="recipe-db-pi" | .context="explicit-pi" |
    .storageClass="recipe-db-retained" |
    .timeoutSeconds=8 |
    .piStorage={node:"recipe-db-pi",expectedRootUuid:"02f61d5e-92cb-4f9c-a781-099d97795020",dataRoot:"/srv/recipe-db"} |
    .origin="https://recipes.example.org" |
    .https={hostname:"recipes.example.org"} |
    .secrets."acme-account-email"=(.secrets."auth-accounts.json" | sub("auth-accounts.json$"; "acme-account-email"))'
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
  rm -rf "$FIXTURE_ROOT/tar-data/tags"
  mkdir -p "$FIXTURE_ROOT/tar-data/tags"
  printf '\000opaque nested service data\n' \
    > "$FIXTURE_ROOT/tar-data/tags/opaque.bin"
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
for name in ("recipes", "tags", "images"):
    archive = root / "capture" / f"{name}.tar"
    with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as output:
        output.add(root / "tar-data" / name, arcname=".")
    archive.chmod(0o600)
    files = snapshot.validate(archive)
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

restore_alternate_real_package() {
  local backup_id=$1 captured_at=$2
  python3 - "$FIXTURE_ROOT" "$backup_id" "$captured_at" << 'PY'
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
manifest = json.loads((snapshot / "manifest.json").read_text())
manifest["backupId"] = sys.argv[2]
manifest["capturedAt"] = sys.argv[3]
(snapshot / "manifest.json").write_bytes(upload.json_bytes(manifest))
package = upload.create_package(
    snapshot, root, manifest, "local-fixture", upload.DEFAULT_MAX_STAGING_BYTES)
for name in (package["manifest"], package["archive"]):
    (root / name).chmod(0o600)
(root / "alternate-package-paths.json").write_text(json.dumps(package))
PY
  export RESTORE_ALT_MANIFEST="$FIXTURE_ROOT/$(jq -r .manifest alternate-package-paths.json)"
  export RESTORE_ALT_ARCHIVE="$FIXTURE_ROOT/$(jq -r .archive alternate-package-paths.json)"
}
