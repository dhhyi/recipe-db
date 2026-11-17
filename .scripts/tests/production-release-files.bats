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
