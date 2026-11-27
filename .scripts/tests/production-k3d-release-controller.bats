#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "workstation release writes authoritative Pi progress throughout the guarded lifecycle" {
  mkdir -p provisioning/files
  cp "$BATS_TEST_DIRNAME/../production-release.py" .scripts/
  cp "$BATS_TEST_DIRNAME/../retrieve-verified-backup.py" .scripts/
  cp "$BATS_TEST_DIRNAME/../../provisioning/files/backup-upload.py" provisioning/files/
  cp "$BATS_TEST_DIRNAME/../../provisioning/files/release-files.py" provisioning/files/
  printf '*\n' > .gitignore
  git add -f .gitignore .scripts/production-release.py .scripts/retrieve-verified-backup.py provisioning/files
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Include reviewed release tooling'
  export MOCK_REVISION MOCK_SOURCE_REVISION
  MOCK_SOURCE_REVISION=$(git rev-parse HEAD)
  git -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm 'Later application candidate'
  MOCK_REVISION=$(git rev-parse HEAD)
  git checkout --detach "$MOCK_SOURCE_REVISION" > /dev/null
  prepare_captured_release
  mock_github_release_api

  run python3 - "$STATE" "$CANDIDATE" << 'PY'
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

release = load("release", ".scripts/production-release.py")
files = load("files", "provisioning/files/release-files.py")
state_path, candidate = Path(sys.argv[1]), sys.argv[2]
release.STATE = str(state_path)
files.CHECKOUT = Path.cwd()
files.backup["maintenance_state_path"] = lambda config: state_path
config = {"stateDirectory":str(state_path.parent)}
values = Path(os.environ["VALUES"])
holder = json.loads((state_path/"backup-state.json").read_text())["backupId"]
operations = []

def remote(args, request):
    operations.append(request["operation"])
    return files.handle(request, config)

def command(action, *arguments):
    with tempfile.TemporaryDirectory(dir="/tmp") as temporary:
        directory = Path(temporary)
        canonical, mapped = directory/"values.yaml", directory/"inputs.json"
        canonical.write_bytes(values.read_bytes())
        inputs = release.parse_values(values)["secrets"]
        mapped.write_text(json.dumps({path:path for path in inputs.values()}))
        args = SimpleNamespace(action=action, arguments=list(arguments),
                               values=str(values), pi="piadmin@recipe-pi.home")
        with patch.object(release,"remote",side_effect=remote):
            assert release.run_controller(args,directory,canonical,mapped) == 0
    assert not (state_path.parent/"release-command.json").exists()

command("release-stage",candidate,"verified-upload",f"VERIFIED-{holder}-verified-upload")
assert json.loads((state_path/"backup-state.json").read_text())["phase"] == "candidate-staged"
assert state_path.with_name(state_path.name+".previous-runtime-secret.json").is_file()
command("release-migration-next",candidate)
command("release-start",candidate)
command("release-readonly-result",candidate,"passed","Read-only checks passed",
        f"READONLY-{holder}-passed")
command("release-reopen",candidate,f"OPEN-{holder}")
command("release-website-result",candidate,"passed","Checked website",f"WEBSITE-{holder}-passed")
reference = state_path.parent/"backup-release-ref"
reference.write_text(json.loads((state_path/"backup-state.json").read_text())["source"]["artifact"]+"\n")
reference.chmod(0o600)
state = json.loads((state_path/"backup-state.json").read_text())
with patch.object(files,"REFERENCE",reference), patch.object(
    files,"config_info",return_value={"configSha256":state["configSha256"]}
):
    files.handle({"operation":"align","holder":holder,"artifact":candidate,
                  "revision":state["toolingRevision"]},config)
assert state["candidate"]["revision"] != state["toolingRevision"]
for service in ("recipes","tags","images"):
    path = Path(os.environ["FIXTURE_ROOT"])/"tar-data"/service/"storage-version"
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text("2\n")
subprocess.run(["bash",".scripts/production-k3d.sh","--release-sources-from-git",
                "release-backup-capture",str(values),str(state_path),candidate],check=True)
state = json.loads((state_path/"backup-state.json").read_text())
state["postReleaseBackup"]["uploadStatus"] = "verified-upload"
files.backup["atomic_json"](state_path/"backup-state.json",state)
post_id = state["postReleaseBackup"]["backupId"]
command("release-backup-verify",candidate,"verified-upload",f"UPLOADED-{post_id}-verified-upload")
command("release-accept",candidate,f"ACCEPT-{holder}")
evidence = files.handle({"operation":"evidence"},config)
assert evidence["status"] == "release-accepted"
assert evidence["postReleaseBackup"]["status"] == "verified-upload"
Path(os.environ["MOCK_GITHUB_RELEASE_JSON"]).write_text(json.dumps({
    "tag_name":"v1","target_commitish":state["candidate"]["revision"],
    "draft":False,"prerelease":False,"published_at":"2026-11-17T12:00:00Z",
    "html_url":"https://github.com/dhhyi/recipe-db/releases/tag/v1",
    "body":candidate+" https://ghcr.io/v2/dhhyi/recipe-db-releases/manifests/"+candidate.split("@")[1],
}))
command("release-finalize",candidate,"v1",f"PUBLISHED-{holder}-v1")
assert not state_path.exists()
assert not state_path.with_name(state_path.name+".previous-runtime-secret.json").exists()
assert not Path(os.environ["MOCK_LOG"]+".lease").exists()
assert operations.index("retain") < operations.index("checkpoint")
assert operations.index("prune") < operations.index("finalize")
PY
  [ "$status" -eq 0 ]
}
