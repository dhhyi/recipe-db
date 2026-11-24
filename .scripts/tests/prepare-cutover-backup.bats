#!/usr/bin/env bats

# shellcheck disable=SC2030,SC2031

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
    "maintenanceOperation":{"backupId":info["backupId"],"packageBackupId":info["backupId"],
      "status":"captured","phase":"captured",
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
  RETRIEVAL_RECEIPT="$INPUT_DIRECTORY/maintenance-retrieval.json"
  mv "${input_files[2]}" "$RETRIEVAL_RECEIPT"
  chmod 600 "$INPUT_MANIFEST" "$INPUT_ARCHIVE" "$RETRIEVAL_RECEIPT"
  export RESULT_PARENT="$BATS_TEST_TMPDIR/results"
  mkdir -m 700 "$RESULT_PARENT"
  export RESULT_DIRECTORY="$RESULT_PARENT/result"
  export MOCK_LOG="$BATS_TEST_TMPDIR/operations.log"
  export MOCK_FAIL_ON=
  export MOCK_BAD_RESTORE_STATUS=
  : > "$MOCK_LOG"
  mkdir -m 700 bin
  export PATH="$FIXTURE_ROOT/bin:$PATH"
  cat > bin/getent << 'SH'
#!/usr/bin/env bash
[[ ${1-} == passwd ]] || exit 1
printf 'cutover-test:x:%s:%s::%s:/bin/bash\n' "$EUID" "$EUID" "$FIXTURE_ROOT/home"
SH
  cat > bin/openssl << 'SH'
#!/usr/bin/env bash
if [[ $* == "rand -hex 8" ]]; then printf 'deadbeef12345678\n'; else printf 'c2VjcmV0\n'; fi
SH
  cat > bin/oras << 'SH'
#!/usr/bin/env bash
if [[ ${MOCK_BLOCK_ON:-} == candidate-fetch ]]; then
  (
    trap 'touch "$MOCK_LOG.active-child-terminated"; exit 0' TERM HUP
    touch "$MOCK_LOG.active-child-started"
    while :; do sleep 0.1; done
  ) &
  child_pid=$!
  trap 'kill -TERM "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; touch "$MOCK_LOG.active-command-terminated"; exit 143' TERM
  trap 'kill -HUP "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; touch "$MOCK_LOG.active-command-terminated"; exit 129' HUP
  wait "$child_pid"
  exit $?
fi
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
if [[ ${MOCK_BLOCK_PRIVATE_CLEANUP:-false} == true &&
  $target == "$RESULT_DIRECTORY/.private" ]]; then
  (
    trap 'touch "$MOCK_LOG.active-child-terminated"; exit 0' TERM HUP
    touch "$MOCK_LOG.active-child-started"
    while :; do sleep 0.1; done
  ) &
  child_pid=$!
  trap 'kill -TERM "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; touch "$MOCK_LOG.active-command-terminated"' TERM
  trap 'kill -HUP "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; touch "$MOCK_LOG.active-command-terminated"' HUP
  wait "$child_pid"
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
cluster=$(yq -r '.cluster' "$values")
[[ $(yq -r '.target' "$values") == local &&
  ($cluster == recipe-db-rehearsal-*-s || $cluster == recipe-db-rehearsal-*-t) ]] || exit 97
if [[ ${MOCK_BLOCK_ON:-} == "$operation" &&
  ($operation != delete || -z ${MOCK_BLOCK_DELETE_NUMBER:-} ||
    $(grep -c '^delete$' "$MOCK_LOG") == "$MOCK_BLOCK_DELETE_NUMBER") ]]; then
  (
    trap 'touch "$MOCK_LOG.active-child-terminated"; exit 0' TERM HUP
    touch "$MOCK_LOG.active-child-started"
    while :; do sleep 0.1; done
  ) &
  child_pid=$!
  trap 'kill -TERM "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; touch "$MOCK_LOG.active-command-terminated"; exit 143' TERM
  trap 'kill -HUP "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; touch "$MOCK_LOG.active-command-terminated"; exit 129' HUP
  wait "$child_pid"
  exit $?
fi
if [[ ${MOCK_FAIL_ON:-} == "$operation" && $operation == create-new ]]; then
  touch "$MOCK_LOG.partial-cluster"
  exit 42
fi
if [[ $operation == delete && -n ${MOCK_FAIL_DELETE_NUMBER:-} &&
  $(grep -c '^delete$' "$MOCK_LOG") == "$MOCK_FAIL_DELETE_NUMBER" ]]; then
  exit 42
fi
[[ ${MOCK_FAIL_ON:-} != "$operation" ]] || exit 42
case "$operation" in
  cutover-restore)
    manifest=$1 archive=$2 id=$3 state=$4 candidate=$5 snapshot=$6
    jq -n --arg manifest "$manifest" --arg archive "$archive" --arg id "$id" \
      '{manifest:$manifest,archive:$archive,backupId:$id}' > "$MOCK_LOG.cutover-restore-inputs"
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
    jq -n --arg manifest "$manifest" --arg archive "$archive" --arg id "$id" \
      '{manifest:$manifest,archive:$archive,backupId:$id}' > "$MOCK_LOG.restore-inputs"
    mkdir -m 700 "$state"
    jq -n --arg id "$id" --arg candidate "$(jq -r .source.artifact "$manifest")" \
      --arg revision "$(jq -r .source.revision "$manifest")" '{
      backupId:$id,artifact:$candidate,revision:$revision,target:"local",
      status:"awaiting-signoff",phase:"pending-signoff",import:{status:"complete"},
      readChecks:{status:"passed"},writesMayHaveOpened:false,publicRoutesMayBeOpen:true}' \
      > "$state/restore-state.json"
    ;;
  restore-status)
    jq -nc --arg bad "$MOCK_BAD_RESTORE_STATUS" '{
      savedProgress:{status:"awaiting-signoff",phase:"pending-signoff",
        writesMayHaveOpened:false,readChecks:{status:"passed"},
        publicRoutesMayBeOpen:true},
      writesMayHaveOpened:false,
      lease:{present:true,ownedByRestore:true,phase:"awaiting-signoff"},
      observed:{graphql:{mode:"maintenance",maintenanceQuery:true},
        publicRoutes:{normalRoutesObserved:true}}
    } |
    if $bad == "routes" then .observed.publicRoutes.normalRoutesObserved=false
    elif $bad == "lease" then .lease.ownedByRestore=false
    elif $bad == "writes" then .writesMayHaveOpened=true
    else . end'
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

@test "unverified or mismatched retrieval receipts are rejected before creating clusters" {
  local invalid_receipt="$INPUT_DIRECTORY/invalid-retrieval.json" filter
  for filter in \
    '.maintenanceOperation.uploadStatus = "pending"' \
    '.maintenanceOperation.status = "failed"' \
    '.maintenanceOperation.phase = "in-progress"' \
    '.backupId = "backup-20261101123456-99"' \
    '.manifest = "/other/package.manifest.json"' \
    '.archive = "/other/package.tar.gz"' \
    '.maintenanceOperation.capturedAt = "2026-11-02T12:34:56Z"' \
    '.maintenanceOperation.source.artifact = "ghcr.io/dhhyi/recipe-db-releases@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' \
    '.maintenanceOperation.source.revision = "0000000000000000000000000000000000000000"'; do
    jq "$filter" "$RETRIEVAL_RECEIPT" > "$invalid_receipt"
    chmod 600 "$invalid_receipt"
    run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
      "$invalid_receipt" "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
    [ "$status" -ne 0 ]
    [[ $output == *"retrieval receipt does not verify this exact final backup"* ]]
    [ ! -e "$RESULT_DIRECTORY" ]
    [ ! -s "$MOCK_LOG" ]
  done
}

@test "unset HOME still protects the resolved operator configuration directory" {
  local operator_config="$FIXTURE_ROOT/home/.config"
  mkdir -p "$operator_config"
  chmod 700 "$FIXTURE_ROOT/home" "$operator_config"
  run env -u HOME bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
    "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" "$operator_config/result"
  [ "$status" -ne 0 ]
  [[ $output == *"results must be outside the checkout, operator configuration and runtime storage"* ]]
  [ ! -e "$operator_config/result" ]
  [ ! -s "$MOCK_LOG" ]
}

@test "symlinked HOME still protects the resolved operator configuration directory" {
  local operator_config="$FIXTURE_ROOT/home/.config"
  mkdir -p "$operator_config"
  chmod 700 "$FIXTURE_ROOT/home" "$operator_config"
  ln -s "$FIXTURE_ROOT/home" "$FIXTURE_ROOT/home-alias"
  run env HOME="$FIXTURE_ROOT/home-alias" bash .scripts/prepare-cutover-backup-k3d.sh \
    "$INPUT_MANIFEST" "$INPUT_ARCHIVE" "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" \
    "$operator_config/result"
  [ "$status" -ne 0 ]
  [[ $output == *"results must be outside the checkout, operator configuration and runtime storage"* ]]
  [ ! -e "$operator_config/result" ]
  [ ! -s "$MOCK_LOG" ]
}

@test "successful local preparation retains truthful package provenance and removes both clusters" {
  run env -u HOME bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
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
  python3 - "$MOCK_LOG.cutover-restore-inputs" "$MOCK_LOG.restore-inputs" \
    "$RESULT_DIRECTORY" "$INPUT_MANIFEST" "$INPUT_ARCHIVE" << 'PY'
import hashlib
import json
from pathlib import Path
import sys

source_input = json.loads(Path(sys.argv[1]).read_text())
target_input = json.loads(Path(sys.argv[2]).read_text())
result = Path(sys.argv[3])
assert Path(source_input["manifest"]).parent == result / ".private" / "inputs"
assert Path(source_input["archive"]).parent == result / ".private" / "inputs"
provenance = json.loads((result / "provenance.json").read_text())
assert source_input["backupId"] == provenance["previousBackup"]["backupId"]
assert hashlib.sha256(Path(sys.argv[4]).read_bytes()).hexdigest() == \
    provenance["previousBackup"]["manifestSha256"]
assert hashlib.sha256(Path(sys.argv[5]).read_bytes()).hexdigest() == \
    provenance["previousBackup"]["archiveSha256"]
target_manifest = Path(target_input["manifest"])
target_archive = Path(target_input["archive"])
assert target_manifest.parent == result / "cutover-backup"
assert target_archive.parent == result / "cutover-backup"
assert target_input["backupId"] != source_input["backupId"]
package = json.loads(target_manifest.read_text())
assert package["backupId"] == target_input["backupId"]
assert package["source"] == provenance["cutoverBackup"]["source"]
assert package["archive"]["sha256"] == hashlib.sha256(target_archive.read_bytes()).hexdigest()
operations = Path(sys.argv[1]).with_name("operations.log").read_text().splitlines()
assert operations.index("cutover-restore") < operations.index("restore")
PY
  run ! grep -q 'storage-version' "$RESULT_DIRECTORY/result.json"
}

@test "verified-unchanged receipt binds the previous package to the retained snapshot contents" {
  local operation_id receipt="$INPUT_DIRECTORY/unchanged-retrieval.json"
  local fingerprint captured_at baseline_id invalid_receipt result_directory index=0
  operation_id=$(jq -er .backupId "$INPUT_MANIFEST")
  fingerprint=$(jq -er .contentFingerprint "$INPUT_MANIFEST")
  captured_at=$(jq -er .capturedAt "$INPUT_MANIFEST")
  baseline_id="backup-20261102123456-999"
  jq --arg operationId "$operation_id" --arg fingerprint "$fingerprint" \
    --arg capturedAt "$captured_at" --arg baselineId "$baseline_id" '
    .maintenanceOperation.uploadStatus = "verified-unchanged"
    | .maintenanceOperation.backupId = $operationId
    | .maintenanceOperation.capturedAt = $capturedAt
    | .maintenanceOperation.contentFingerprint = $fingerprint
    | .maintenanceOperation.verifiedBaselineBackupId = $baselineId
  ' "$RETRIEVAL_RECEIPT" > "$receipt"
  chmod 600 "$receipt"
  export RESULT_DIRECTORY="$RESULT_PARENT/result-verified-unchanged"
  run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
    "$receipt" "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -eq 0 ]
  jq -e '.status == "passed"' "$RESULT_DIRECTORY/result.json"
  jq -e --arg operationId "$operation_id" --arg baselineId "$baseline_id" \
    --arg fingerprint "$fingerprint" '
    .maintenanceOperation.backupId == $operationId
    and .maintenanceOperation.packageBackupId == .previousBackup.backupId
    and .maintenanceOperation.capturedAt == .previousBackup.capturedAt
    and .maintenanceOperation.uploadStatus == "verified-unchanged"
    and .maintenanceOperation.verifiedBaselineBackupId == $baselineId
    and .maintenanceOperation.contentFingerprint == $fingerprint
  ' "$RESULT_DIRECTORY/provenance.json"
  for filter in \
    '.maintenanceOperation.backupId = "backup-20261102123456-2"' \
    '.maintenanceOperation.capturedAt = "2026-11-02T12:34:56Z"' \
    '.maintenanceOperation.verifiedBaselineBackupId = "invalid-id"' \
    'del(.maintenanceOperation.verifiedBaselineBackupId)' \
    'del(.maintenanceOperation.contentFingerprint)' \
    '.maintenanceOperation.contentFingerprint = "0000000000000000000000000000000000000000000000000000000000000000"'; do
    index=$((index + 1))
    invalid_receipt="$INPUT_DIRECTORY/unchanged-retrieval-invalid-$index.json"
    result_directory="$RESULT_PARENT/result-verified-unchanged-invalid-$index"
    jq "$filter" "$receipt" > "$invalid_receipt"
    chmod 600 "$invalid_receipt"
    export RESULT_DIRECTORY=$result_directory
    : > "$MOCK_LOG"
    run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
      "$invalid_receipt" "$CANDIDATE_RELEASE" "$result_directory"
    [ "$status" -ne 0 ]
    if [[ $filter == *contentFingerprint* ]]; then
      [[ $output == *"verified-unchanged retrieval does not match the retained final snapshot contents"* ]]
      jq -e '.status == "failed" and .phase == "preflight"
        and (.clusters.source.creationAttempted | not)
        and (.clusters.target.creationAttempted | not)' "$result_directory/result.json"
    else
      [[ $output == *"retrieval receipt does not verify this exact final backup"* ]]
      [ ! -e "$result_directory" ]
    fi
    [ ! -s "$MOCK_LOG" ]
  done
}

@test "failed second cluster deletion reports partial cleanup and preserves evidence" {
  export MOCK_FAIL_DELETE_NUMBER=2
  run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
    "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -ne 0 ]
  jq -e '.status == "failed" and .phase == "remove-successful-rehearsal-clusters"
    and .clusters.source.created and .clusters.source.deleted
    and .clusters.source.deletionAttempted
    and .clusters.target.created and .clusters.target.deletionAttempted
    and (.clusters.target.deleted == null)
    and .failureReason == "success cleanup stopped after the source cluster was deleted; target cluster deletion outcome is uncertain; no retry or recreation was attempted"
    and (.cleanup.privateDataRemoved | not) and (.cleanup.inputCopiesRemoved | not)' \
    "$RESULT_DIRECTORY/result.json"
  [ -d "$RESULT_DIRECTORY/.private/inputs" ]
  [ -f "$RESULT_DIRECTORY/.private/logs/source-delete.log" ]
  [ -f "$RESULT_DIRECTORY/.private/logs/target-delete.log" ]
  [ "$(find "$RESULT_DIRECTORY/cutover-backup" -type f | wc -l)" -eq 2 ]
  [ -f "$RESULT_DIRECTORY/provenance.json" ]
  [ "$(grep -c '^delete$' "$MOCK_LOG")" -eq 2 ]
}

@test "failed first cluster deletion stops without attempting the target or retrying" {
  export MOCK_FAIL_DELETE_NUMBER=1
  run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
    "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" "$RESULT_DIRECTORY"
  [ "$status" -ne 0 ]
  jq -e '.status == "failed" and .phase == "remove-successful-rehearsal-clusters"
    and .clusters.source.deletionAttempted and (.clusters.source.deleted == null)
    and .clusters.target.created and (.clusters.target.deletionAttempted | not)
    and (.clusters.target.deleted | not)
    and .failureReason == "success cleanup stopped with the source cluster deletion outcome uncertain; target cluster deletion was not attempted; no retry or recreation was attempted"
    and (.cleanup.privateDataRemoved | not)' "$RESULT_DIRECTORY/result.json"
  [ "$(grep -c '^delete$' "$MOCK_LOG")" -eq 1 ]
  [ "$(grep -c '^create-new$' "$MOCK_LOG")" -eq 2 ]
  [ -d "$RESULT_DIRECTORY/.private/inputs" ]
}

@test "preparation retains the source cluster when restore-status lacks barrier evidence" {
  local bad_status result_directory
  for bad_status in routes lease writes; do
    MOCK_BAD_RESTORE_STATUS=$bad_status
    result_directory="$RESULT_PARENT/result-$bad_status"
    : > "$MOCK_LOG"
    run bash .scripts/prepare-cutover-backup-k3d.sh "$INPUT_MANIFEST" "$INPUT_ARCHIVE" \
      "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" "$result_directory"
    [ "$status" -ne 0 ]
    jq -e '
      .status == "failed" and .phase == "verify-cutover-read-checks"
      and .clusters.source.created and (.clusters.source.deleted | not)
      and (.clusters.target.creationAttempted | not)
      and .failureReason != null
    ' "$result_directory/result.json"
    [ -d "$result_directory/.private/inputs" ]
    [ ! -e "$result_directory/cutover-backup" ]
  done
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

@test "SIGINT SIGTERM and SIGHUP stop active commands and report cluster state accurately" {
  local signal operation expected_status expected_phase expected_reason source_attempted source_created \
    source_deleted source_deletion_attempted result_directory pid deadline result output_log
  for signal in TERM INT HUP; do
    for operation in create-new cutover-restore candidate-fetch delete; do
      export MOCK_BLOCK_ON=$operation
      result_directory="$RESULT_PARENT/result-$operation-$signal"
      export RESULT_DIRECTORY=$result_directory
      rm -f "$MOCK_LOG.active-child-started" "$MOCK_LOG.active-child-terminated" \
        "$MOCK_LOG.active-command-terminated" "$MOCK_LOG.active-child-pid" \
        "$MOCK_LOG.preparation-pid"
      : > "$MOCK_LOG"
      output_log="$BATS_TEST_TMPDIR/interruption-$operation-$signal.log"
      python3 - "$MOCK_LOG.preparation-pid" bash .scripts/prepare-cutover-backup-k3d.sh \
        "$INPUT_MANIFEST" "$INPUT_ARCHIVE" "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" \
        "$result_directory" > "$output_log" 2>&1 << 'PY' &
import signal
import subprocess
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)
pid_file, *command = sys.argv[1:]
process = subprocess.Popen(command, start_new_session=True)
with open(pid_file, "w", encoding="ascii") as output:
    output.write(str(process.pid))
sys.exit(process.wait())
PY
      pid=$!
      deadline=$((SECONDS + 20))
      while [[ ! -e "$MOCK_LOG.active-child-started" ]]; do
        if ! kill -0 "$pid" 2> /dev/null || ((SECONDS >= deadline)); then
          if [[ -s "$MOCK_LOG.preparation-pid" ]]; then
            kill -TERM "$(cat "$MOCK_LOG.preparation-pid")" 2> /dev/null || true
          else
            kill -TERM "$pid" 2> /dev/null || true
          fi
          wait "$pid" 2> /dev/null || true
          cat "$output_log"
          return 1
        fi
        sleep 0.1
      done
      kill -s "$signal" "$(cat "$MOCK_LOG.preparation-pid")"
      if wait "$pid"; then result=0; else result=$?; fi
      case "$signal" in
        TERM) expected_status=143 ;;
        INT) expected_status=130 ;;
        HUP) expected_status=129 ;;
      esac
      [ "$result" -eq "$expected_status" ]
      [ -e "$MOCK_LOG.active-command-terminated" ]
      [ -e "$MOCK_LOG.active-child-terminated" ]
      source_attempted=true
      source_created=true
      source_deleted=false
      source_deletion_attempted=false
      case "$operation" in
        create-new)
          expected_phase=create-source-cluster
          source_created=null
          ;;
        cutover-restore)
          expected_phase=import-final-previous-backup
          ;;
        candidate-fetch)
          expected_phase=preflight
          source_attempted=false
          source_created=false
          ;;
        delete)
          expected_phase=remove-successful-rehearsal-clusters
          expected_reason='success cleanup stopped with the source cluster deletion outcome uncertain; target cluster deletion was not attempted; no retry or recreation was attempted'
          source_deleted=null
          source_deletion_attempted=true
          ;;
      esac
      if [[ $operation != delete ]]; then
        expected_reason="interrupted by SIG$signal"
      fi
      jq -e --arg phase "$expected_phase" \
        --arg reason "$expected_reason" \
        --argjson sourceAttempted "$source_attempted" \
        --argjson sourceCreated "$source_created" \
        --argjson sourceDeleted "$source_deleted" \
        --argjson sourceDeletionAttempted "$source_deletion_attempted" '
        .status == "failed" and .phase == $phase
        and .failureReason == $reason
        and .clusters.source.creationAttempted == $sourceAttempted
        and .clusters.source.created == $sourceCreated
        and .clusters.source.deletionAttempted == $sourceDeletionAttempted
        and .clusters.source.deleted == $sourceDeleted
        and (.cleanup.privateDataRemoved | not)' "$result_directory/result.json"
      [ -d "$result_directory/.private/inputs" ]
      if [[ $operation == delete ]]; then
        [ "$(grep -c '^delete$' "$MOCK_LOG")" -eq 1 ]
        jq -e '.clusters.target.created
          and (.clusters.target.deletionAttempted | not)
          and (.clusters.target.deleted | not)' "$result_directory/result.json"
      else
        run ! grep -q '^delete$' "$MOCK_LOG"
      fi
    done
  done
}

@test "interruption during second cluster deletion reports partial cleanup without retry or recreation" {
  local pid result_directory output_log deadline result
  export MOCK_BLOCK_ON=delete MOCK_BLOCK_DELETE_NUMBER=2
  result_directory="$RESULT_PARENT/result-second-delete-interrupted"
  export RESULT_DIRECTORY=$result_directory
  rm -f "$MOCK_LOG.active-child-started" "$MOCK_LOG.active-child-terminated" \
    "$MOCK_LOG.active-command-terminated" "$MOCK_LOG.preparation-pid"
  : > "$MOCK_LOG"
  output_log="$BATS_TEST_TMPDIR/interruption-second-delete.log"
  python3 - "$MOCK_LOG.preparation-pid" bash .scripts/prepare-cutover-backup-k3d.sh \
    "$INPUT_MANIFEST" "$INPUT_ARCHIVE" "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" \
    "$result_directory" > "$output_log" 2>&1 << 'PY' &
import signal
import subprocess
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)
pid_file, *command = sys.argv[1:]
process = subprocess.Popen(command, start_new_session=True)
with open(pid_file, "w", encoding="ascii") as output:
    output.write(str(process.pid))
sys.exit(process.wait())
PY
  pid=$!
  deadline=$((SECONDS + 30))
  while [[ ! -e "$MOCK_LOG.active-child-started" ]]; do
    if ! kill -0 "$pid" 2> /dev/null || ((SECONDS >= deadline)); then
      if [[ -s "$MOCK_LOG.preparation-pid" ]]; then
        kill -TERM "$(cat "$MOCK_LOG.preparation-pid")" 2> /dev/null || true
      else
        kill -TERM "$pid" 2> /dev/null || true
      fi
      wait "$pid" 2> /dev/null || true
      cat "$output_log"
      return 1
    fi
    sleep 0.1
  done
  kill -TERM "$(cat "$MOCK_LOG.preparation-pid")"
  if wait "$pid"; then result=0; else result=$?; fi
  [ "$result" -eq 143 ]
  [ -e "$MOCK_LOG.active-command-terminated" ]
  [ -e "$MOCK_LOG.active-child-terminated" ]
  jq -e '.status == "failed" and .phase == "remove-successful-rehearsal-clusters"
    and .failureReason == "success cleanup stopped after the source cluster was deleted; target cluster deletion outcome is uncertain; no retry or recreation was attempted"
    and .clusters.source.deleted
    and .clusters.target.deletionAttempted and (.clusters.target.deleted == null)
    and (.cleanup.privateDataRemoved | not) and (.cleanup.inputCopiesRemoved | not)' \
    "$result_directory/result.json"
  [ "$(grep -c '^delete$' "$MOCK_LOG")" -eq 2 ]
  [ "$(grep -c '^create-new$' "$MOCK_LOG")" -eq 2 ]
  [ -d "$result_directory/.private/inputs" ]
}

@test "SIGTERM during final private cleanup persists result and records completed cluster deletion" {
  local pid result_directory output_log deadline result
  export MOCK_BLOCK_PRIVATE_CLEANUP=true
  result_directory="$RESULT_PARENT/result-private-cleanup-interrupted"
  export RESULT_DIRECTORY=$result_directory
  rm -f "$MOCK_LOG.active-child-started" "$MOCK_LOG.active-child-terminated" \
    "$MOCK_LOG.active-command-terminated" "$MOCK_LOG.preparation-pid"
  : > "$MOCK_LOG"
  output_log="$BATS_TEST_TMPDIR/interruption-private-cleanup.log"
  python3 - "$MOCK_LOG.preparation-pid" bash .scripts/prepare-cutover-backup-k3d.sh \
    "$INPUT_MANIFEST" "$INPUT_ARCHIVE" "$RETRIEVAL_RECEIPT" "$CANDIDATE_RELEASE" \
    "$result_directory" > "$output_log" 2>&1 << 'PY' &
import signal
import subprocess
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)
pid_file, *command = sys.argv[1:]
process = subprocess.Popen(command, start_new_session=True)
with open(pid_file, "w", encoding="ascii") as output:
    output.write(str(process.pid))
sys.exit(process.wait())
PY
  pid=$!
  deadline=$((SECONDS + 30))
  while [[ ! -e "$MOCK_LOG.active-child-started" ]]; do
    if ! kill -0 "$pid" 2> /dev/null || ((SECONDS >= deadline)); then
      if [[ -s "$MOCK_LOG.preparation-pid" ]]; then
        kill -TERM -- "-$(cat "$MOCK_LOG.preparation-pid")" 2> /dev/null || true
      else
        kill -TERM "$pid" 2> /dev/null || true
      fi
      wait "$pid" 2> /dev/null || true
      cat "$output_log"
      return 1
    fi
    sleep 0.1
  done
  kill -TERM -- "-$(cat "$MOCK_LOG.preparation-pid")"
  if wait "$pid"; then result=0; else result=$?; fi
  [ "$result" -eq 143 ]
  [ -e "$MOCK_LOG.active-command-terminated" ]
  [ -e "$MOCK_LOG.active-child-terminated" ]
  [ ! -e "$result_directory/.private" ]
  jq -e '.status == "failed" and .phase == "complete"
    and .failureReason == "interrupted by SIGTERM during final cleanup"
    and .clusters.source.deleted and .clusters.target.deleted
    and .cleanup.privateDataRemoved and .cleanup.inputCopiesRemoved' \
    "$result_directory/result.json"
  [ "$(grep -c '^delete$' "$MOCK_LOG")" -eq 2 ]
}
