#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture production-release.py
  use_mise_tools
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT:$BATS_TEST_DIRNAME/../.."
  mkdir -p provisioning/files
  cp "$BATS_TEST_DIRNAME/../retrieve-verified-backup.py" .scripts/
  cp "$BATS_TEST_DIRNAME/../../provisioning/files/backup-upload.py" provisioning/files/
  cp "$BATS_TEST_DIRNAME/../../provisioning/files/release-files.py" provisioning/files/
}

@test "workstation metadata adapter preserves Pi configuration and refuses mismatched private inputs" {
  run python3 - << 'PY'
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", ".scripts/production-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
    directory = Path(temporary)
    secret = directory / "operator-input"
    secret.write_bytes(b"test input")
    values = directory / "values.yaml"
    values.write_text(json.dumps({"target":"pi","secrets":{"auth-accounts.json":str(secret)}}))
    canonical = {"target":"pi","secrets":{"auth-accounts.json":"/etc/recipe-db/application-inputs/auth-accounts.json"}}
    info = {
        "fileProtocolVersion":1,"toolingRevision":"a"*40,
        "values":base64.b64encode(json.dumps(canonical).encode()).decode(),
        "inputs":{"auth-accounts.json":hashlib.sha256(secret.read_bytes()).hexdigest()},
        "helperSha256":hashlib.sha256(Path("provisioning/files/release-files.py").read_bytes()).hexdigest(),
        "publisherSha256":hashlib.sha256(Path("provisioning/files/backup-upload.py").read_bytes()).hexdigest(),
    }
    with patch.object(release,"remote",return_value=info), patch.object(
        release.subprocess,"check_output",return_value=("a"*40).encode()
    ):
        prepared,mapped = release.prepare_inputs(SimpleNamespace(values=str(values)),directory)
        assert json.loads(prepared.read_text()) == canonical
        assert json.loads(mapped.read_text())[canonical["secrets"]["auth-accounts.json"]] == str(secret)
        secret.write_bytes(b"different input")
        try:
            release.prepare_inputs(SimpleNamespace(values=str(values)),directory)
        except ValueError as error:
            assert "does not match" in str(error)
        else:
            raise AssertionError("mismatched input accepted")
PY
  [ "$status" -eq 0 ]
}

@test "relative workstation inputs resolve from each private home and remain content-bound" {
  run python3 - << 'PY'
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", ".scripts/production-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
    directory = Path(temporary)
    original_cwd = Path.cwd()
    homes = [directory / "home one", directory / "home two"]
    workdirs = [directory / "working-one", directory / "working-two"]
    for home in homes:
        input_path = home / ".config/recipe-db/deployment/auth-accounts.json"
        input_path.parent.mkdir(parents=True)
        input_path.write_bytes(b'{"accounts":[]}\n')
        config = home / ".config/recipe-db"
        (config / "backup").mkdir()
        (config / "provisioning").mkdir()
        (config / "backup/backup-values.yaml").write_text(json.dumps({
            "secrets": {"auth-accounts.json": "deployment/auth-accounts.json"},
        }))
        (config / "provisioning/inventory.yml").write_text('{"all":{}}')
        (config / "backup/backup-release-ref").write_text(
            "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64)
    for workdir in workdirs:
        workdir.mkdir()
    values = directory / "values.yaml"
    values.write_text(json.dumps({
        "target": "pi", "secrets": {"auth-accounts.json": "deployment/auth-accounts.json"},
    }))
    installed = {
        "target": "pi",
        "secrets": {"auth-accounts.json": "/etc/recipe-db/application-inputs/auth-accounts.json"},
    }
    info = {
        "fileProtocolVersion": 1, "toolingRevision": "a" * 40,
        "values": base64.b64encode(json.dumps(installed).encode()).decode(),
        "inputs": {"auth-accounts.json": hashlib.sha256(b'{"accounts":[]}\n').hexdigest()},
        "helperSha256": hashlib.sha256(Path("provisioning/files/release-files.py").read_bytes()).hexdigest(),
        "publisherSha256": hashlib.sha256(Path("provisioning/files/backup-upload.py").read_bytes()).hexdigest(),
    }
    try:
        for home, workdir in zip(homes, workdirs):
            os.chdir(workdir)
            with patch.dict(os.environ, {"HOME": str(home)}), \
                    patch.object(release, "remote", return_value=info), patch.object(
                        release.subprocess, "check_output", return_value=("a" * 40).encode()
                    ):
                canonical, mapped = release.prepare_inputs(
                    SimpleNamespace(values=str(values)), directory)
                expected = home / ".config/recipe-db/deployment/auth-accounts.json"
                assert json.loads(mapped.read_text())[installed["secrets"]["auth-accounts.json"]] == str(expected)
                assert json.loads(canonical.read_text()) == installed
                release.validate_operator_files(home / ".config/recipe-db")
        try:
            release.operator_input_path("deployment/missing/../auth-accounts.json", homes[0] / ".config/recipe-db")
        except ValueError as error:
            assert "missing or invalid" in str(error)
        else:
            raise AssertionError("missing intermediate directory accepted")
        secret = homes[0] / ".config/recipe-db/deployment/auth-accounts.json"
        secret.write_bytes(b"mismatched synthetic contents")
        with patch.dict(os.environ, {"HOME": str(homes[0])}), \
                patch.object(release, "remote", return_value=info), patch.object(
                    release.subprocess, "check_output", return_value=("a" * 40).encode()
                ):
            try:
                release.prepare_inputs(SimpleNamespace(values=str(values)), directory)
            except ValueError as error:
                assert "does not match" in str(error)
                assert "mismatched synthetic contents" not in str(error)
            else:
                raise AssertionError("mismatched input accepted")
            values.write_text(json.dumps({
                "target": "pi", "secrets": {"auth-accounts.json": "../../outside.json"},
            }))
            try:
                release.prepare_inputs(SimpleNamespace(values=str(values)), directory)
            except ValueError as error:
                assert "missing or invalid" in str(error)
            else:
                raise AssertionError("escaping relative input accepted")
    finally:
        os.chdir(original_cwd)
PY
  [ "$status" -eq 0 ]
}

@test "failed-release closeout archives only terminal isolation evidence and removes temporary Pi data" {
  run python3 - << 'PY'
import importlib.util
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

release = load("release", ".scripts/production-release.py")
files = load("files", "provisioning/files/release-files.py")
assert "release-closeout" in release.ACTIONS
with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
    base = Path(temporary)
    maintenance = base / "maintenance"
    maintenance.mkdir(mode=0o700)
    config = {"stateDirectory": str(base)}
    backup_id = "backup-20260101000000-1"
    state = {
        "backupId": backup_id, "source": {"artifact": "previous"},
        "configSha256": "config", "status": "recovery-required",
        "phase": "post-release-backup-failed",
    }
    state_path = maintenance / "backup-state.json"
    files.backup["atomic_json"](state_path, state)
    with patch.object(files.subprocess, "check_output", return_value=b"revision\n"):
        initial = files.handle({
            "operation": "begin", "token": "token", "revision": "revision",
            "action": "release-closeout",
        }, config)
    files.backup["atomic_json"](maintenance / "partial.json", {"private": "discard"})
    partial = maintenance / "post-release-backup"
    partial.mkdir(mode=0o700)
    (partial / "partial.tar").write_bytes(b"partial snapshot")
    credentials = base / "maintenance.previous-runtime-secret.json"
    files.backup["atomic_json"](credentials, {
        "backupId": backup_id, "source": state["source"], "data": {"private": "discard"},
    })
    closeout = {
        "ownershipReleased": False, "ownershipRetained": True, "leaseUid": "retained-lease-uid",
        "barrierVerified": True, "workersStopped": True,
        "holder": backup_id, "closedAt": "2026-01-02T00:00:00Z",
    }
    closed = dict(state, status="recovery-closed", phase="recovery-closed",
                  recoveryCloseout=closeout)
    for key in closeout:
        incomplete = dict(closed, recoveryCloseout={k: v for k, v in closeout.items() if k != key})
        assert not files.backup["safely_closed"](incomplete), key
        assert not files.backup["safely_recovered"](incomplete), key
    for phase in ("recovery-closeout-pending", "post-release-backup-failed", "unknown"):
        assert not files.backup["safely_closed"](dict(closed, phase=phase))
    for fields in ({"ownershipReleased": True}, {"ownershipRetained": False}, {"leaseUid": ""}):
        assert not files.backup["safely_closed"](
            dict(closed, recoveryCloseout=dict(closeout, **fields)))
    assert files.backup["maintenance_active"](config)
    files.handle({
        "operation": "checkpoint", "token": "token", "expected": initial["expected"],
        "state": closed,
    }, config)
    assert not files.backup["maintenance_active"](config)
    files.handle({"operation": "end", "token": "token"}, config)
    archived = base / "maintenance-history" / backup_id
    assert not maintenance.exists()
    assert not credentials.exists()
    assert not (base / "release-command.json").exists()
    assert list(archived.iterdir()) == [archived / "backup-state.json"]
    assert json.loads((archived / "backup-state.json").read_text()) == closed
    assert not files.backup["maintenance_active"](config)
PY
  [ "$status" -eq 0 ]
}

@test "remote catalog verifies each complete point without pruning or writing Pi files" {
  run python3 - << 'PY'
import hashlib
import importlib.util
from pathlib import Path
import tempfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("upload", "provisioning/files/backup-upload.py")
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)
with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
    config = {"deploymentId": "production", "stateDirectory": temporary}
    backup_id = "backup-20260101000000-1"
    stem = "recipe-db-production-20260101T000000Z-" + backup_id
    archive = b"synthetic archive"
    source = {"artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64,
              "revision": "b" * 40}
    document = {
        "format": upload.PACKAGE_FORMAT, "formatVersion": 1, "deploymentId": "production",
        "backupId": backup_id, "capturedAt": "2026-01-01T00:00:00Z", "source": source,
        "contentFingerprint": "c" * 64,
        "archive": {"name": stem + ".tar.gz", "sizeBytes": len(archive),
                    "sha256": hashlib.sha256(archive).hexdigest()},
        "snapshotManifest": {
            "format": upload.FORMAT, "formatVersion": 1, "backupId": backup_id,
            "capturedAt": "2026-01-01T00:00:00Z", "source": source, "inventory": [{}],
        },
    }
    remote = {stem + ".tar.gz": archive, stem + ".manifest.json": upload.json_bytes(document)}
    with patch.object(upload, "remote_names", return_value=list(remote)), \
         patch.object(upload, "read_remote_manifest", return_value=document), \
         patch.object(upload, "remote_hash",
                      side_effect=lambda config, name, size: hashlib.sha256(remote[name]).hexdigest()), \
         patch.object(upload, "prune", side_effect=AssertionError("catalog must not prune")):
        catalog = upload.verified_remote_catalog(config)
        assert catalog["points"] == [{
            "backupId": backup_id, "capturedAt": document["capturedAt"], "source": source,
        }]
        assert catalog["deploymentId"] == "production"
        assert list(Path(temporary).iterdir()) == []
        with patch.object(upload, "remote_hash", return_value="0" * 64):
            try:
                upload.verified_remote_catalog(config)
            except upload.BackupError:
                pass
            else:
                raise AssertionError("corrupt remote point accepted")
PY
  [ "$status" -eq 0 ]
}

@test "write-through checkpoints keep canonical Pi paths and recommendations contain no temporary paths" {
  run python3 - << 'PY'
import importlib.util
import json
from pathlib import Path
import shlex
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", ".scripts/production-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
    directory = Path(temporary)
    snapshot = directory/"maintenance"
    snapshot.mkdir()
    local_path = str(snapshot/"post-release-backup")
    (snapshot/"backup-state.json").write_text(json.dumps({"postReleaseBackup":{"snapshotPath":local_path}}))
    args = SimpleNamespace(token="token",values="/private/operator's values.yaml",pi="piadmin@recipe-pi.home")
    with release.Files(directory/"files.sock",args,snapshot,{"expected":"before"}) as server:
        with patch.object(release,"remote",return_value={"expected":"after"}) as remote:
            server.apply("checkpoint")
            assert remote.call_args.args[1]["state"]["postReleaseBackup"]["snapshotPath"] == release.STATE+"/post-release-backup"
            assert server.expected == "after"
        assert json.loads((snapshot/"backup-state.json").read_text())["postReleaseBackup"]["snapshotPath"] == local_path
    canonical = directory/"pi-values.yaml"
    line = "Next: "+shlex.join(["mise","run","production-k3d","--release-sources-from-git",
                              "release-start",str(canonical),str(snapshot),"candidate"])+"\n"
    result = release.recommendation(line,args,canonical,snapshot)
    assert str(directory) not in result
    assert shlex.split(result)[-2:] == [args.values,"candidate"]
    recovery = line.replace("release-start","release-migration-recover")
    assert "separately approved Pi recovery" in release.recommendation(recovery,args,canonical,snapshot)
PY
  [ "$status" -eq 0 ]
}

@test "controller writes through before success and stops its child before releasing a failed command claim" {
  run python3 - << 'PY'
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", ".scripts/production-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
controller = Path(".scripts/production-k3d.sh")
controller.write_text("""#!/bin/bash
set -euo pipefail
python3 - "$4/backup-state.json" <<'CHILD'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
state = json.loads(path.read_text())
state['phase'] = 'candidate-staged'
path.write_text(json.dumps(state))
CHILD
python3 .scripts/production-release.py --file-request checkpoint
""")
events = []
def remote(args, request):
    events.append(request)
    if request["operation"] == "begin":
        return {"expected":"before","state":{"phase":"captured"},
                "manifest":None,"retained":None,"postManifest":None}
    if request["operation"] == "checkpoint":
        assert request["expected"] == "before"
        assert request["state"]["phase"] == "candidate-staged"
        return {"expected":"after"}
    return {}

with patch.object(release, "remote", side_effect=remote), patch.object(
    release.subprocess, "check_output", return_value=("a"*40).encode()
):
    with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
        directory = Path(temporary)
        canonical, mapped = directory/"values.yaml", directory/"inputs.json"
        canonical.write_text("{}")
        mapped.write_text("{}")
        args = SimpleNamespace(action="release-stage", arguments=[],
                               values=str(canonical), pi="piadmin@recipe-pi.home")
        assert release.run_controller(args,directory,canonical,mapped) == 0
        assert [event["operation"] for event in events] == ["begin","checkpoint","end"]

    controller.write_text("""#!/bin/bash
printf '%s\\n' "$$" > controller.pid
printf 'Next: mise run production-k3d release-start /unexpected /unexpected candidate\\n'
sleep 60
""")
    events.clear()
    started = time.monotonic()
    with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
        directory = Path(temporary)
        try:
            release.run_controller(args,directory,canonical,mapped)
        except ValueError as error:
            assert "unexpected private cache paths" in str(error)
        else:
            raise AssertionError("invalid recommendation accepted")
    assert time.monotonic()-started < 15
    assert [event["operation"] for event in events] == ["begin","end"]
    try:
        os.kill(int(Path("controller.pid").read_text()),0)
    except ProcessLookupError:
        pass
    else:
        raise AssertionError("controller survived file-claim release")
PY
  [ "$status" -eq 0 ]
}

@test "missing system release prerequisites fail before SSH or maintenance" {
  run python3 - << 'PY'
from contextlib import redirect_stderr
import importlib.util
import io
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("release", ".scripts/production-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
for missing in ("openssl", "curl", "gh", "chezmoi"):
    connection = Mock()
    errors = io.StringIO()
    with patch.object(release.sys, "argv", ["release", "preflight", "/operator/values.yaml", "candidate"]), \
            patch.object(release.shutil, "which", side_effect=lambda tool: None if tool == missing else "/bin/"+tool), \
            patch.dict(release.ssh, {"ssh_session": connection}), redirect_stderr(errors):
        try:
            release.main()
        except SystemExit as error:
            assert error.code == 2
        else:
            raise AssertionError("missing prerequisite accepted")
    connection.assert_not_called()
    assert "missing workstation prerequisite: "+missing in errors.getvalue()
PY
  [ "$status" -eq 0 ]
}

@test "preflight refuses missing or malformed later backup alignment inputs" {
  run python3 - << 'PY'
import importlib.util
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location("release", ".scripts/production-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    for folder in ("backup","provisioning","deployment"):
        (directory/folder).mkdir()
    (directory/"deployment/auth-accounts.json").write_text('{"accounts":[]}')
    (directory/"backup/backup-values.yaml").write_text(
        '{"target":"pi","secrets":{"auth-accounts.json":"deployment/auth-accounts.json"}}')
    (directory/"provisioning/inventory.yml").write_text('{"all":{}}')
    reference = directory/"backup/backup-release-ref"
    try:
        release.validate_operator_files(directory)
    except FileNotFoundError:
        pass
    else:
        raise AssertionError("missing backup reference accepted")
    reference.write_text("mutable-tag")
    try:
        release.validate_operator_files(directory)
    except ValueError as error:
        assert "immutable" in str(error)
    else:
        raise AssertionError("mutable backup reference accepted")
    reference.write_text("ghcr.io/dhhyi/recipe-db-releases@sha256:"+"a"*64)
    release.validate_operator_files(directory)
    (directory/"backup/backup-values.yaml").write_text(
        '{"secrets":{"auth-accounts.json":"/home/vscode/.config/recipe-db/deployment/auth-accounts.json"}}')
    release.validate_operator_files(directory)
PY
  [ "$status" -eq 0 ]
}
