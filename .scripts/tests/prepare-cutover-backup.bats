#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture prepare-cutover-backup-k3d.sh
  chmod 700 "$BATS_TEST_TMPDIR"
  mkdir -p .scripts/lib provisioning/files deploy
  cp "$BATS_TEST_DIRNAME/../package-local-backup.py" .scripts/
  cp "$BATS_TEST_DIRNAME/../validate-backup-package.py" .scripts/
  cp "$BATS_TEST_DIRNAME/../validate-backup-snapshot.py" .scripts/
  cp "$BATS_TEST_DIRNAME/../../provisioning/files/backup-upload.py" provisioning/files/
  cp "$BATS_TEST_DIRNAME/../../deploy/local.yaml" deploy/
  cat > .scripts/lib/project-metadata.sh << 'SH'
application_project_metadata_to_jsonl() {
  cp "$FIXTURE_ROOT/projects.jsonl" "$2"
  chmod 600 "$2"
}
SH
  cat > projects.jsonl << 'JSONL'
{"name":"recipes","category":"backend","backupRole":"authoritative-read-only"}
{"name":"images","category":"api","backupRole":"cleanup-participant"}
{"name":"inspirations","category":"api","backupRole":"cleanup-participant"}
{"name":"ratings","category":"api","backupRole":"cleanup-participant"}
{"name":"tags","category":"api","backupRole":"cleanup-participant"}
JSONL
  export FIXTURE_ROOT
  git init -q
  git config user.name "Cutover Test"
  git config user.email "cutover@example.invalid"
  printf '*\n' > .gitignore
  git add -f .gitignore .scripts/prepare-cutover-backup-k3d.sh .scripts/package-local-backup.py \
    .scripts/validate-backup-package.py .scripts/validate-backup-snapshot.py \
    .scripts/lib/project-metadata.sh provisioning/files/backup-upload.py deploy/local.yaml projects.jsonl
  git commit -qm "Cutover fixture baseline"
  export SOURCE_REVISION
  SOURCE_REVISION=$(git rev-parse HEAD)
  printf 'candidate release revision\n' > candidate.txt
  git add -f candidate.txt
  git commit -qm "Cutover candidate fixture"
  export CANDIDATE_REVISION
  CANDIDATE_REVISION=$(git rev-parse HEAD)
  export PREVIOUS_RELEASE="ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  export CANDIDATE_RELEASE="ghcr.io/dhhyi/recipe-db-releases@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  export INPUT_DIRECTORY="$BATS_TEST_TMPDIR/input"
  mkdir -m 700 "$INPUT_DIRECTORY"
  export INPUT_MANIFEST INPUT_ARCHIVE RETRIEVAL_RECEIPT
  python3 - "$INPUT_DIRECTORY" "$PREVIOUS_RELEASE" "$SOURCE_REVISION" << 'PY'
import hashlib
import importlib.util
import io
import json
from datetime import datetime, timezone
from pathlib import Path
import sys
import tarfile

directory = Path(sys.argv[1])
release, revision = sys.argv[2:]
spec = importlib.util.spec_from_file_location("upload", "provisioning/files/backup-upload.py")
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)
captured = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
source = {"target":"pi","cluster":"recipe-db-pi","context":"recipe-db-pi",
          "namespace":"recipe-db","artifact":release,"revision":revision}
roles = {"recipes":"authoritative-read-only","images":"cleanup-participant",
         "inspirations":"cleanup-participant","ratings":"cleanup-participant",
         "tags":"cleanup-participant"}
inventory = []
snapshot = directory / "snapshot"
snapshot.mkdir(mode=0o700)
for service, role in roles.items():
    data = b"1\n"
    archive = service + ".tar"
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as bundle:
        member = tarfile.TarInfo("storage-version")
        member.size, member.mode, member.uid, member.gid, member.mtime = len(data), 0o640, 1001, 1002, 0
        bundle.addfile(member, io.BytesIO(data))
    archive_bytes = output.getvalue()
    (snapshot / archive).write_bytes(archive_bytes)
    (snapshot / archive).chmod(0o600)
    file_entry = {"path":"storage-version","sizeBytes":len(data),
                  "sha256":hashlib.sha256(data).hexdigest(),"storageVersion":1}
    inventory.append({"service":service,"role":role,"pvc":service,"archive":archive,
        "sizeBytes":len(archive_bytes),"sha256":hashlib.sha256(archive_bytes).hexdigest(),
        "fileCount":1,"files":[file_entry]})
manifest = {"format":upload.FORMAT,"formatVersion":1,"backupId":"backup-20261101123456-1",
            "capturedAt":captured,"source":source,"inventory":inventory}
(snapshot / "manifest.json").write_bytes(upload.json_bytes(manifest))
(snapshot / "manifest.json").chmod(0o600)
package = directory / "package"
package.mkdir(mode=0o700)
info = upload.create_package(snapshot, package, manifest, "pi", upload.DEFAULT_MAX_STAGING_BYTES)
receipt = {"backupId":info["backupId"],"manifest":str(package / info["manifest"]),
    "archive":str(package / info["archive"]),
    "maintenanceOperation":{"backupId":info["backupId"],"status":"captured","phase":"captured",
      "uploadStatus":"verified-upload","capturedAt":captured,"source":{
        "artifact":release,"revision":revision}}}
(package / "retrieval.json").write_text(json.dumps(receipt))
(package / "retrieval.json").chmod(0o600)
PY
  mapfile -t input_files < <(
    python3 - "$INPUT_DIRECTORY" << 'PY'
import json
from pathlib import Path
import sys
path = Path(sys.argv[1]) / "package" / "retrieval.json"
receipt = json.loads(path.read_text())
print(receipt["manifest"])
print(receipt["archive"])
print(path)
PY
  )
  INPUT_MANIFEST=${input_files[0]}
  INPUT_ARCHIVE=${input_files[1]}
  RETRIEVAL_RECEIPT=${input_files[2]}
  chmod 600 "$INPUT_MANIFEST" "$INPUT_ARCHIVE" "$RETRIEVAL_RECEIPT"
  export RESULT_PARENT="$BATS_TEST_TMPDIR/results"
  mkdir -m 700 "$RESULT_PARENT"
  export RESULT_DIRECTORY="$RESULT_PARENT/result"
  export MOCK_LOG="$BATS_TEST_TMPDIR/operations.log"
  export MOCK_FAIL_ON=
  : > "$MOCK_LOG"
  mkdir -m 700 bin
  export PATH="$FIXTURE_ROOT/bin:$PATH"
  cat > bin/openssl << 'SH'
#!/usr/bin/env bash
if [[ $* == "rand -hex 8" ]]; then printf 'deadbeef12345678\n'; else printf 'c2VjcmV0\n'; fi
SH
  cat > bin/oras << 'SH'
#!/usr/bin/env bash
printf '{"annotations":{"org.opencontainers.image.revision":"%s"}}\n' "$CANDIDATE_REVISION"
SH
  cat > bin/k3d << 'SH'
#!/usr/bin/env bash
exit 0
SH
  export REAL_RM REAL_CHMOD
  REAL_RM=$(command -v rm)
  REAL_CHMOD=$(command -v chmod)
  cat > bin/rm << 'SH'
#!/usr/bin/env bash
target=
for argument in "$@"; do target=$argument; done
if [[ ${MOCK_FAIL_PRIVATE_CLEANUP:-false} == true &&
  $target == "$RESULT_DIRECTORY/.private" ]]; then
  exit 1
fi
exec "$REAL_RM" "$@"
SH
  cat > bin/chmod << 'SH'
#!/usr/bin/env bash
if [[ ${MOCK_FAIL_RESULT_CHMOD:-false} == true && $# == 2 &&
  $1 == 600 && $2 == "$RESULT_DIRECTORY/result.json" ]]; then
  exit 1
fi
exec "$REAL_CHMOD" "$@"
SH
  cat > bin/kubectl << 'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > bin/mise << 'SH'
#!/usr/bin/env bash
if [[ ${1-} == exec ]]; then
  shift 2
  exec "$@"
fi
[[ ${1-} == run && ${2-} == --raw && ${3-} == production-k3d ]] || exit 96
shift 3
if [[ ${1-} == --release-sources-from-git ]]; then shift; fi
operation=$1
values=$2
shift 2
printf '%s\n' "$operation" >> "$MOCK_LOG"
if [[ ${MOCK_SIGNAL_ON:-} == "$operation" ]]; then
  kill -TERM "$PPID"
  exit 0
fi
if [[ ${MOCK_FAIL_ON:-} == "$operation" && $operation == create-new ]]; then
  touch "$MOCK_LOG.partial-cluster"
  exit 42
fi
[[ ${MOCK_FAIL_ON:-} != "$operation" ]] || exit 42
case "$operation" in
  cutover-restore)
    manifest=$1 archive=$2 id=$3 state=$4 candidate=$5 snapshot=$6
    cluster=$(yq -r '.cluster' "$values")
    context=$(yq -r '.context' "$values")
    source_release=$(jq -r '.source.artifact' "$manifest")
    source_revision=$(jq -r '.source.revision' "$manifest")
    mkdir -m 700 "$state"
    jq -n --arg id "$id" --arg candidate "$candidate" --arg revision "$CANDIDATE_REVISION" \
      --arg cluster "$cluster" --arg context "$context" --arg source "$source_release" \
      --arg sourceRevision "$source_revision" '{
      backupId:$id,artifact:$candidate,revision:$revision,target:"local",cluster:$cluster,
      context:$context,status:"awaiting-signoff",phase:"pending-signoff",
      import:{status:"complete"},readChecks:{status:"passed"},
      writesMayHaveOpened:false,publicRoutesMayBeOpen:true,
      cutover:{sourceRelease:$source,sourceRevision:$sourceRevision}}' > "$state/restore-state.json"
    python3 "$FIXTURE_ROOT/build-snapshot.py" "$snapshot" "$candidate" \
      "$CANDIDATE_REVISION" "$cluster" "$context"
    ;;
  restore)
    manifest=$1 archive=$2 id=$3 state=$4
    mkdir -m 700 "$state"
    jq -n --arg id "$id" --arg candidate "$(jq -r .source.artifact "$manifest")" \
      --arg revision "$(jq -r .source.revision "$manifest")" '{
      backupId:$id,artifact:$candidate,revision:$revision,target:"local",
      status:"awaiting-signoff",phase:"pending-signoff",import:{status:"complete"},
      readChecks:{status:"passed"},writesMayHaveOpened:false,publicRoutesMayBeOpen:true}' \
      > "$state/restore-state.json"
    ;;
  restore-status)
    printf '{"status":"awaiting-signoff","phase":"pending-signoff","writesMayHaveOpened":false,"readChecks":{"status":"passed"},"publicRoutesMayBeOpen":true}\n'
    ;;
  *) ;;
esac
SH
  cat > build-snapshot.py << 'PY'
import hashlib, io, json, os, sys, tarfile
from pathlib import Path
import importlib.util
snapshot = Path(sys.argv[1])
artifact, revision, cluster, context = sys.argv[2:]
snapshot.mkdir(mode=0o700)
spec = importlib.util.spec_from_file_location("upload", ".scripts/../provisioning/files/backup-upload.py")
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)
roles = {"recipes":"authoritative-read-only","images":"cleanup-participant",
         "inspirations":"cleanup-participant","ratings":"cleanup-participant",
         "tags":"cleanup-participant"}
inventory=[]
for service, role in roles.items():
    data=b"1\n"
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode="w",format=tarfile.USTAR_FORMAT) as bundle:
        member=tarfile.TarInfo("storage-version")
        member.size=len(data)
        member.mode,member.uid,member.gid,member.mtime=0o640,1001,1002,0
        bundle.addfile(member,io.BytesIO(data))
    raw=stream.getvalue()
    name=service+".tar"
    (snapshot/name).write_bytes(raw)
    (snapshot/name).chmod(0o600)
    inventory.append({"service":service,"role":role,"pvc":service,"archive":name,
      "sizeBytes":len(raw),"sha256":hashlib.sha256(raw).hexdigest(),"fileCount":1,
      "files":[{"path":"storage-version","sizeBytes":len(data),
        "sha256":hashlib.sha256(data).hexdigest(),"storageVersion":1}]})
manifest={"format":upload.FORMAT,"formatVersion":1,"backupId":"backup-20261101123456-2",
  "capturedAt":"2026-11-01T12:34:56Z",
  "source":{"target":"local","cluster":cluster,"context":context,"namespace":"recipe-db",
    "artifact":artifact,"revision":revision},"inventory":inventory}
(snapshot/"manifest.json").write_bytes(upload.json_bytes(manifest))
(snapshot/"manifest.json").chmod(0o600)
PY
  chmod 700 bin/*
  chmod 700 build-snapshot.py
  git add -f build-snapshot.py
  git commit -qm 'Add test snapshot fixture'
}

@test "successful local preparation retains truthful package provenance and removes both clusters" {
  run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
    "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  if [ "$status" -ne 0 ] && [ -f "$RESULT_DIRECTORY/.private/logs/source-restore.log" ]; then
    cat "$RESULT_DIRECTORY/.private/logs/source-restore.log"
  fi
  [ "$status" -eq 0 ]
  jq -e --arg release "$CANDIDATE_RELEASE" '
    .status == "passed" and .phase == "complete"
    and .cutoverBackup.release == $release
    and .clusters.source.created and .clusters.target.created
    and .clusters.source.deleted and .clusters.target.deleted
    and .cleanup.privateDataRemoved and .cleanup.inputCopiesRemoved
  ' "$RESULT_DIRECTORY/result.json"
  [ ! -e "$RESULT_DIRECTORY/.private" ]
  [ -f "$RESULT_DIRECTORY/provenance.json" ]
  [ "$(find "$RESULT_DIRECTORY/cutover-backup" -type f | wc -l)" -eq 2 ]
  jq -e --arg source "$PREVIOUS_RELEASE" --arg candidate "$CANDIDATE_RELEASE" '
    .previousBackup.source.artifact == $source
    and .cutoverBackup.source.target == "local"
    and .cutoverBackup.source.artifact == $candidate
    and .previousBackup.backupId != .cutoverBackup.backupId
  ' "$RESULT_DIRECTORY/provenance.json"
  [ -f "$INPUT_MANIFEST" ] && [ -f "$INPUT_ARCHIVE" ] && [ -f "$RETRIEVAL_RECEIPT" ]
  [ "$(grep -c '^delete$' "$MOCK_LOG")" -eq 2 ]
  run ! grep -q 'storage-version' "$RESULT_DIRECTORY/result.json"
}

@test "failed second restore preserves both clusters and private input copies for operator investigation" {
  MOCK_FAIL_ON=restore
  run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
    "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -ne 0 ]
  jq -e '.status == "failed" and .clusters.source.created and .clusters.target.created
    and (.clusters.source.deleted | not) and (.clusters.target.deleted | not)
    and (.cleanup.privateDataRemoved | not) and (.cleanup.inputCopiesRemoved | not)' \
    "$RESULT_DIRECTORY/result.json"
  [ -d "$RESULT_DIRECTORY/.private/inputs" ]
  [ -f "$INPUT_MANIFEST" ] && [ -f "$INPUT_ARCHIVE" ] && [ -f "$RETRIEVAL_RECEIPT" ]
  run ! grep -q '^delete$' "$MOCK_LOG"
}

@test "failed partial cluster creation is reported as unknown and retained for investigation" {
  MOCK_FAIL_ON=create-new
  run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
    "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -ne 0 ]
  [ -f "$MOCK_LOG.partial-cluster" ]
  jq -e '.status == "failed"
    and .clusters.source.creationAttempted
    and .clusters.source.created == null
    and (.clusters.source.deleted | not)
    and (.clusters.target.creationAttempted | not)' "$RESULT_DIRECTORY/result.json"
  [ -d "$RESULT_DIRECTORY/.private" ]
}

@test "private cleanup failure returns nonzero and records failed cleanup" {
  export MOCK_FAIL_PRIVATE_CLEANUP=true
  run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
    "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -ne 0 ]
  jq -e '.status == "failed" and .clusters.source.deleted and .clusters.target.deleted
    and (.cleanup.privateDataRemoved | not) and (.cleanup.inputCopiesRemoved | not)' \
    "$RESULT_DIRECTORY/result.json"
  [ -d "$RESULT_DIRECTORY/.private/inputs" ]
}

@test "result persistence failure returns nonzero" {
  export MOCK_FAIL_RESULT_CHMOD=true
  run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
    "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -ne 0 ]
  jq -e '.status == "failed" and .failureReason == "result.json could not be persisted; inspect the result directory and retained clusters"' \
    "$RESULT_DIRECTORY/result.json"
}

@test "SIGTERM records interruption and retains private state without deleting clusters" {
  export MOCK_SIGNAL_ON=create-new
  run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
    "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -eq 143 ]
  jq -e '.status == "failed" and .phase == "create-source-cluster"
    and .failureReason == "interrupted by SIGTERM"
    and .clusters.source.creationAttempted and .clusters.source.created == null
    and (.clusters.source.deleted | not)
    and (.cleanup.privateDataRemoved | not)' "$RESULT_DIRECTORY/result.json"
  [ -d "$RESULT_DIRECTORY/.private/inputs" ]
  run ! grep -q '^delete$' "$MOCK_LOG"
}
