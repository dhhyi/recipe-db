#!/usr/bin/env bats

# Bats isolates each test's authentication settings in a subshell.
# shellcheck disable=SC2030,SC2031

load test_helper

@test "catalog retrieval validates bounded metadata and does not require a healthy baseline" {
  run python3 - << 'PY'
import importlib.util
import json
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("retrieve", ".scripts/retrieve-verified-backup.py")
retrieve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retrieve)
catalog = {
    "format": "recipe-db-backup-catalog", "formatVersion": 1, "deploymentId": "production",
    "checkedAt": "2026-01-02T00:00:00Z",
    "points": [{"backupId": "backup-20260101000000-1", "capturedAt": "2026-01-01T00:00:00Z",
                "source": {"artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64,
                           "revision": "b" * 40}}],
}
with patch.object(retrieve, "receive", return_value=json.dumps(catalog).encode()) as receive:
    assert retrieve.retrieve_catalog(None) == catalog
    assert receive.call_args.args[1] == ("catalog",)
for mutate in (
    lambda c: c.update(format="unknown"),
    lambda c: c.update(points=c["points"] * 2),
    lambda c: c["points"][0].update(source={"artifact": "mutable"}),
):
    invalid = json.loads(json.dumps(catalog))
    mutate(invalid)
    with patch.object(retrieve, "receive", return_value=json.dumps(invalid).encode()):
        try:
            retrieve.retrieve_catalog(None)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid catalog accepted")
assert retrieve.REMOTE.index('sys.argv[1] == "catalog"') < retrieve.REMOTE.index('tool["baseline_path"]')
PY
  [ "$status" -eq 0 ]
}

@test "catalog and destination are mutually exclusive before SSH begins" {
  run python3 .scripts/retrieve-verified-backup.py --catalog /tmp/not-used
  [ "$status" -ne 0 ]
  [[ $output == *"choose either DESTINATION or --catalog"* ]]
  run python3 .scripts/retrieve-verified-backup.py
  [ "$status" -ne 0 ]
  [[ $output == *"choose either DESTINATION or --catalog"* ]]
}

setup() {
  setup_fixture retrieve-verified-backup.py
  setup_mock_bin
  mkdir -p provisioning/files .mise/tasks
  cp "$BATS_TEST_DIRNAME/../../provisioning/files/backup-upload.py" provisioning/files/
  cp "$BATS_TEST_DIRNAME/../../.mise/tasks/validation.toml" .mise/tasks/
  printf '[task_config]\nincludes = [".mise/tasks/*.toml"]\n' > mise.toml
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT"
  export HOME="$FIXTURE_ROOT/home"
  mkdir -p "$HOME/.config/recipe-db/ssh" remote/state remote/drive
  export REMOTE_ROOT="$FIXTURE_ROOT/remote"
  export UPLOADER="$FIXTURE_ROOT/provisioning/files/backup-upload.py"
  export DESTINATION="$FIXTURE_ROOT/private download"
  export CASE=normal
  python3 - << 'PY'
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["REMOTE_ROOT"])
now = datetime.now(timezone.utc).replace(microsecond=0)
captured = now - timedelta(hours=2)
stem = "recipe-db-pi-" + captured.strftime("%Y%m%dT%H%M%SZ") + "-baseline-id"
archive = b"private backup fixture\n"
package = {
    "format": "recipe-db-backup", "formatVersion": 1,
    "deploymentId": "pi", "backupId": "baseline-id",
    "capturedAt": captured.isoformat(),
    "archive": {"name": stem + ".tar.gz", "sizeBytes": len(archive),
                "sha256": hashlib.sha256(archive).hexdigest()},
}
manifest = json.dumps(package).encode()
baseline = {
    "backupId": "baseline-id", "archive": stem + ".tar.gz",
    "manifest": stem + ".manifest.json", "archiveSizeBytes": len(archive),
    "manifestSizeBytes": len(manifest), "archiveSha256": hashlib.sha256(archive).hexdigest(),
    "manifestSha256": hashlib.sha256(manifest).hexdigest(),
    "capturedAt": captured.isoformat(),
    "lastUpload": (now - timedelta(hours=1)).isoformat(),
}
status = {"format": "recipe-db-backup-status", "status": "verified-upload",
          "lastCheck": now.isoformat(), "backupId": "baseline-id"}
config = {"deploymentId": "pi", "remote": "gdrive:RecipeDB Backups",
          "rcloneConfig": str(root / "rclone.conf"), "stateDirectory": str(root / "state"),
          "stagingDirectory": str(root / "must-not-be-created"),
          "captureCommand": "/usr/local/sbin/recipe-db-backup-capture"}
for path, value in ((root / "config.json", config), (root / "state/baseline.json", baseline),
                    (root / "state/status.json", status)):
    path.write_text(json.dumps(value))
    path.chmod(0o600)
(root / "rclone.conf").write_text("private-authorization-must-not-leak")
(root / "rclone.conf").chmod(0o600)
(root / "drive" / baseline["archive"]).write_bytes(archive)
(root / "drive" / baseline["manifest"]).write_bytes(manifest)
PY
  cat > bin/ssh << 'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import sys

args = sys.argv[1:]
home = Path.home() / ".config/recipe-db/ssh"
options = [
    "-T", "-i", str(home / "recipe-db-pi"),
    "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
    "-o", "UserKnownHostsFile=" + str(home / "known_hosts"),
    "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=3",
]
assert args[:len(options)] == options
args = args[len(options):]
root = Path(os.environ["REMOTE_ROOT"])
if args[:2] == ["-M", "-N"]:
    assert args[:3] == ["-M", "-N", "-S"]
    assert args[4:6] == ["-o", "ControlPersist=no"]
    assert args[6] in ("piadmin@recipe-pi.home", "operator@other-pi.home")
    control = Path(args[3])
    parent = os.getppid()
    assert control.parent.stat().st_mode & 0o777 == 0o700
    (root / "connection.json").write_text(json.dumps({
        "pid": os.getpid(), "parent": parent, "control": str(control), "closed": False,
    }))
    if os.environ.get("REQUIRE_TERMINAL") == "1":
        with open("/dev/tty", "rb+", buffering=0) as terminal:
            assert os.tcgetpgrp(terminal.fileno()) == os.getpgrp()
            terminal.write(b"Test SSH passphrase: ")
            assert terminal.readline().strip() == b"fixture-passphrase"
    connection = socket.socket(socket.AF_UNIX)
    connection.bind(str(control))
    connection.listen()

    def close(signum, frame):
        if os.environ["CASE"] == "cleanup-timeout":
            os.kill(parent, signal.SIGINT)
            return
        connection.close()
        control.unlink()
        (root / "connection.json").write_text(json.dumps({
            "pid": os.getpid(), "control": str(control), "closed": True,
        }))
        sys.exit(0)

    signal.signal(signal.SIGTERM, close)
    while True:
        signal.pause()
assert args[0] == "-S"
assert args[2:8] == [
    "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ProxyCommand=false",
]
connection = json.loads((root / "connection.json").read_text())
assert args[1] == connection["control"] and Path(args[1]).is_socket()
assert not connection["closed"]
args = args[8:]
assert args[0] in ("piadmin@recipe-pi.home", "operator@other-pi.home")
assert len(args) == 2
command = shlex.split(args[-1])
if command[-1:] == ["2>&1"]:
    command.pop()
    assert command.pop(0) == "LC_ALL=C"
    assert command == ["sudo", "-n", "-k", "python3", "-c", "pass"]
password_auth = os.environ.get("REQUIRE_SUDO_PASSWORD") == "1"
if command == ["sudo", "-n", "-k", "python3", "-c", "pass"]:
    if os.environ.get("DENY_SUDO") == "1":
        print("sudo: piadmin is not allowed to execute python3 as root")
        sys.exit(1)
    if password_auth:
        print("sudo: a password is required")
    sys.exit(1 if password_auth else 0)
if password_auth:
    assert command[:7] == ["sudo", "-S", "-k", "-p", "", "python3", "-c"]
    assert sys.stdin.buffer.readline() == b"fixture-sudo-password\n"
    if os.environ.get("REJECT_SUDO_PASSWORD") == "1":
        sys.exit(1)
    if os.environ.get("DENY_AFTER_AUTHENTICATION") == "1":
        print("sudo: piadmin is not allowed to execute python3 as root", file=sys.stderr)
        sys.exit(1)
    code_index = 7
else:
    assert command[:5] == ["sudo", "-n", "-k", "python3", "-c"]
    code_index = 5
assert len(command) in (code_index + 2, code_index + 3)
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps(command[code_index + 1:]) + "\n")
code = command[code_index].replace("/usr/local/sbin/recipe-db-backup-upload", os.environ["UPLOADER"])
code = code.replace("/etc/recipe-db/backup.json", str(root / "config.json"))
sys.exit(subprocess.run(["python3", "-c", code, *command[code_index + 1:]],
                        stdin=subprocess.DEVNULL).returncode)
PY
  cat > bin/rclone << 'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import signal
import sys

root = Path(os.environ["REMOTE_ROOT"])
args = sys.argv[1:]
assert args[0] == "cat"
assert args[1].startswith("gdrive:RecipeDB Backups/pi/")
assert args[2:] == [
    "--config", str(root / "rclone.conf"), "--log-level", "ERROR",
    "--log-file", "/dev/null", "--retries", "2", "--low-level-retries", "2",
    "--timeout", "5m", "--contimeout", "30s",
]
name = args[1].split("/")[-1]
assert "/" not in name and name not in ("rclone.conf", ".", "..")
data = (root / "drive" / name).read_bytes()
case = os.environ["CASE"]
if case == "corrupt":
    data = b"x" * len(data)
if case == "interrupted" and name.endswith(".tar.gz"):
    sys.stdout.buffer.write(data[:3])
    sys.exit(1)
if case in ("terminated", "hangup") and name.endswith(".tar.gz"):
    connection = json.loads((root / "connection.json").read_text())
    os.kill(connection["parent"], signal.SIGTERM if case == "terminated" else signal.SIGHUP)
    sys.exit(1)
if case == "oversized":
    data += b"extra"
if case == "changed-baseline" and name.endswith(".tar.gz"):
    path = root / "state/baseline.json"
    baseline = json.loads(path.read_text())
    baseline["archiveSha256"] = "0" * 64
    path.write_text(json.dumps(baseline))
if case == "failed-status" and name.endswith(".tar.gz"):
    path = root / "state/status.json"
    status = json.loads(path.read_text())
    status["status"] = "upload-failure"
    path.write_text(json.dumps(status))
sys.stdout.buffer.write(data)
PY
  chmod +x bin/ssh bin/rclone
}

edit_record() {
  python3 - "$1" "$2" "$3" << 'PY'
import json
from pathlib import Path
import sys
path = Path("remote/state") / (sys.argv[1] + ".json")
record = json.loads(path.read_text())
record[sys.argv[2]] = sys.argv[3]
path.write_text(json.dumps(record))
PY
}

assert_private_success() {
  [ "$status" -eq 0 ]
  RESULT="$output" python3 - << 'PY'
import json
import os
from pathlib import Path
import stat

root = Path(os.environ["REMOTE_ROOT"])
result = json.loads(os.environ["RESULT"])
baseline = json.loads((root / "state/baseline.json").read_text())
destination = Path(os.environ["DESTINATION"])
assert result["backupId"] == "baseline-id"
assert stat.S_IMODE(destination.stat().st_mode) == 0o700
assert sorted(path.name for path in destination.iterdir()) == sorted(
    baseline[field] for field in ("archive", "manifest"))
for field in ("archive", "manifest"):
    path = Path(result[field])
    assert path.is_absolute() and path == destination / baseline[field]
    assert path.read_bytes() == (root / "drive" / baseline[field]).read_bytes()
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
assert not (root / "must-not-be-created").exists()
assert (root / "rclone.conf").read_text() == "private-authorization-must-not-leak"
PY
  assert_connection_closed
}

assert_connection_closed() {
  python3 - << 'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["REMOTE_ROOT"])
connection = json.loads((root / "connection.json").read_text())
assert connection["closed"] or os.environ["CASE"] == "cleanup-timeout"
assert not Path(connection["control"]).parent.exists()
try:
    os.kill(connection["pid"], 0)
except ProcessLookupError:
    pass
else:
    raise AssertionError("SSH master remains alive")
PY
}

@test "streams the verified baseline privately with no Pi staging or credential transfer" {
  # Fish expands its own argv, not the surrounding Bash shell.
  # shellcheck disable=SC2016
  run --separate-stderr fish -c 'mise run --raw retrieve-verified-backup "$argv[1]"' -- "$DESTINATION"
  assert_private_success
  [ "$(wc -l < "$MOCK_LOG")" -eq 4 ]
  [[ $output != *private-authorization* ]]
}

terminal_retrieval() {
  export REQUIRE_TERMINAL=1
  run python3 - << 'PY'
import errno
import json
import os
import pty
import select
import signal
import time

pid, terminal = pty.fork()
if pid == 0:
    os.execlp("fish", "fish", "--interactive", "--no-config")
os.write(terminal, b'mise run --raw retrieve-verified-backup "$DESTINATION"; exit $status\n')
content, pending = bytearray(), bytearray()
finished = False
try:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if not select.select([terminal], [], [], 0.1)[0]:
            continue
        try:
            block = os.read(terminal, 65536)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
        if not block:
            break
        content.extend(block)
        pending.extend(block)
        for prompt, answer in (
            (b"Test SSH passphrase: ", b"fixture-passphrase\n"),
            (b"Pi sudo password (not SSH key passphrase): ", b"fixture-sudo-password\n"),
        ):
            if prompt in pending:
                _, _, pending = pending.partition(prompt)
                os.write(terminal, answer)
    else:
        raise AssertionError("task did not finish; terminal output: " + repr(content))
    _, status = os.waitpid(pid, 0)
    finished = True
    expected_sudo_prompts = int(os.environ.get("REQUIRE_SUDO_PASSWORD") == "1")
    assert content.count(b"Pi sudo password (not SSH key passphrase): ") == expected_sudo_prompts
    assert b"fixture-sudo-password" not in content
    if os.environ.get("REJECT_SUDO_PASSWORD") == "1" \
            or os.environ.get("DENY_AFTER_AUTHENTICATION") == "1":
        assert os.waitstatus_to_exitcode(status) != 0, repr(content)
        assert not os.path.exists(os.environ["DESTINATION"])
        print("authentication rejected")
        raise SystemExit(0)
    assert os.waitstatus_to_exitcode(status) == 0, repr(content)
    assert content.count(b"Test SSH passphrase: ") == 1, repr(content)
    text = content.decode()
    start = text.find('{"archive":')
    assert start >= 0, repr(content)
    result, _ = json.JSONDecoder().raw_decode(text[start:])
    print(json.dumps(result))
finally:
    if not finished:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(terminal)
PY
}

@test "documented task keeps SSH passphrase prompts in the terminal foreground" {
  terminal_retrieval
  assert_private_success
}

@test "separate sudo password travels only over SSH stdin without passwordless sudo" {
  export REQUIRE_SUDO_PASSWORD=1
  terminal_retrieval
  assert_private_success
  run ! grep -q fixture-sudo-password "$MOCK_LOG"
}

@test "rejected sudo password fails without creating a download or exposing the password" {
  export REQUIRE_SUDO_PASSWORD=1 REJECT_SUDO_PASSWORD=1
  terminal_retrieval
  [ "$status" -eq 0 ]
  [ "$output" = "authentication rejected" ]
  [ ! -e "$DESTINATION" ]
  run ! grep -q fixture-sudo-password "$MOCK_LOG"
}

@test "sudo policy denial after authentication fails without creating a download" {
  export REQUIRE_SUDO_PASSWORD=1 DENY_AFTER_AUTHENTICATION=1
  terminal_retrieval
  [ "$status" -eq 0 ]
  [ "$output" = "authentication rejected" ]
  [ ! -e "$DESTINATION" ]
  [ ! -s "$MOCK_LOG" ]
}

@test "sudo password authentication refuses noninteractive echoed input" {
  export REQUIRE_SUDO_PASSWORD=1
  run python3 -c 'import os; os.setsid(); os.execvp("python3", ["python3", ".scripts/retrieve-verified-backup.py", os.environ["DESTINATION"]])' < /dev/null
  [ "$status" -ne 0 ]
  [[ $output == *"sudo authentication requires an interactive terminal"* ]]
  [ ! -e "$DESTINATION" ]
}

@test "reported sudo permission denial fails without requesting a password" {
  export DENY_SUDO=1
  run python3 .scripts/retrieve-verified-backup.py "$DESTINATION" < /dev/null
  [ "$status" -ne 0 ]
  [[ $output == *"Pi sudo permission/policy check failed"* ]]
  [[ $output != *"Pi sudo password"* ]]
  [[ $output != *"requires an interactive terminal"* ]]
  [ ! -e "$DESTINATION" ]
  [ ! -s "$MOCK_LOG" ]
}

@test "verified-unchanged retrieves the baseline rather than the newer local capture" {
  edit_record status status verified-unchanged
  edit_record status backupId newer-local-capture
  run python3 .scripts/retrieve-verified-backup.py --pi operator@other-pi.home "$DESTINATION"
  assert_private_success
}

@test "rejects unhealthy overdue future and inconsistent status" {
  for value in upload-failure retention-failure overdue capture-failure; do
    edit_record status status "$value"
    run python3 .scripts/retrieve-verified-backup.py "$DESTINATION"
    [ "$status" -ne 0 ]
    [ ! -e "$DESTINATION" ]
  done
  edit_record status status verified-upload
  for value in 2000-01-01T00:00:00Z 2999-01-01T00:00:00Z invalid; do
    edit_record status lastCheck "$value"
    run python3 .scripts/retrieve-verified-backup.py "$DESTINATION"
    [ "$status" -ne 0 ]
    [ ! -e "$DESTINATION" ]
  done
}

@test "rejects mismatched status identity unsafe filenames and invalid baseline sizes" {
  edit_record status backupId different-id
  run python3 .scripts/retrieve-verified-backup.py "$DESTINATION"
  [ "$status" -ne 0 ]
  edit_record status backupId baseline-id
  cp remote/state/baseline.json remote/original-baseline.json
  for name in archive manifest archiveSizeBytes archiveSha256; do
    cp remote/original-baseline.json remote/state/baseline.json
    edit_record baseline "$name" ../unsafe
    run python3 .scripts/retrieve-verified-backup.py "$DESTINATION"
    [ "$status" -ne 0 ]
    [ ! -e "$DESTINATION" ]
  done
}

@test "corrupt oversized interrupted and changing downloads never become completed files" {
  cp remote/state/baseline.json remote/original-baseline.json
  cp remote/state/status.json remote/original-status.json
  for CASE in corrupt oversized interrupted changed-baseline failed-status terminated hangup cleanup-timeout; do
    export CASE
    cp remote/original-baseline.json remote/state/baseline.json
    cp remote/original-status.json remote/state/status.json
    run python3 .scripts/retrieve-verified-backup.py "$DESTINATION"
    [ "$status" -ne 0 ]
    if [[ $CASE == cleanup-timeout ]]; then
      [ -d "$DESTINATION" ]
      [[ $output == *"SSH connection cleanup timed out"* ]]
      [[ $output != *'{"archive":'* ]]
    else
      [ ! -e "$DESTINATION" ]
    fi
    [[ $output != *private-authorization* ]]
    assert_connection_closed
  done
}

@test "rejects a manifest inconsistent with the baseline even when its own hash matches" {
  python3 - << 'PY'
import hashlib
import json
from pathlib import Path
path = Path("remote/state/baseline.json")
baseline = json.loads(path.read_text())
manifest = Path("remote/drive") / baseline["manifest"]
document = json.loads(manifest.read_text())
document["archive"]["sizeBytes"] += 1
manifest.write_text(json.dumps(document))
baseline["manifestSizeBytes"] = manifest.stat().st_size
baseline["manifestSha256"] = hashlib.sha256(manifest.read_bytes()).hexdigest()
path.write_text(json.dumps(baseline))
PY
  run python3 .scripts/retrieve-verified-backup.py "$DESTINATION"
  [ "$status" -ne 0 ]
  [ ! -e "$DESTINATION" ]
}

@test "refuses existing destinations and symlinks including symlinked parents" {
  mkdir "$DESTINATION"
  printf 'preserve\n' > "$DESTINATION/existing"
  run python3 .scripts/retrieve-verified-backup.py "$DESTINATION"
  [ "$status" -ne 0 ]
  [ "$(cat "$DESTINATION/existing")" = preserve ]
  ln -s "$DESTINATION" link
  for target in link link/child; do
    run python3 .scripts/retrieve-verified-backup.py "$target"
    [ "$status" -ne 0 ]
    [ ! -e "$DESTINATION/child" ]
  done
}
