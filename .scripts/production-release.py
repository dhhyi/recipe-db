#!/usr/bin/env python3
"""Run guarded Pi release commands locally with write-through private metadata."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import uuid


ROOT = Path(__file__).resolve().parent.parent
ssh = runpy.run_path(str(ROOT / ".scripts/retrieve-verified-backup.py"))
STATE = "/var/lib/recipe-db-backup/maintenance"
LIMIT = 256 * 1024**2
ACTIONS = {
    "release-stage", "release-migration-plan", "release-migration-next", "release-migration-status",
    "release-migration-recover-claim", "release-start", "release-reopen",
    "release-website-result", "release-disposition", "release-backup-verify",
    "release-accept", "release-finalize",
}


def remote(args, request):
    password = args.sudo_password
    sudo = ["sudo", "-n", "-k"] if password is None else ["sudo", "-S", "-k", "-p", ""]
    command = [*sudo, "/usr/local/sbin/recipe-db-release-files"]
    content = (json.dumps(request, separators=(",", ":")) + "\n").encode()
    if password is not None:
        content = (password + "\n").encode() + content
    result = subprocess.run(
        ssh["ssh_command"](args, command), input=content, stdout=subprocess.PIPE,
        check=True, timeout=60,
    )
    if len(result.stdout) > LIMIT:
        raise ValueError("private metadata response exceeds its limit")
    return json.loads(result.stdout)


def parse_values(path):
    result = subprocess.run(
        ["yq", "-o=json", "eval-all", "[.]", str(path)],
        check=True, stdout=subprocess.PIPE,
    )
    documents = json.loads(result.stdout)
    if len(documents) != 1 or not isinstance(documents[0], dict):
        raise ValueError("values must contain one object")
    return documents[0]


def prepare_inputs(args, directory):
    info = remote(args, {"operation": "info"})
    if info.get("fileProtocolVersion") != 1:
        raise ValueError("install the reviewed release prerequisites before maintenance")
    for field, path in (
        ("helperSha256", ROOT / "provisioning/files/release-files.py"),
        ("publisherSha256", ROOT / "provisioning/files/backup-upload.py"),
    ):
        if info.get(field) != hashlib.sha256(path.read_bytes()).hexdigest():
            raise ValueError("installed release helper/publisher differs from this reviewed checkout")
    revision = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).decode().strip()
    if info.get("toolingRevision") != revision:
        raise ValueError("workstation and managed Pi tooling revisions differ; prepare them before maintenance")
    canonical = directory / "pi-values.yaml"
    canonical.write_bytes(base64.b64decode(info["values"], validate=True))
    local_values, pi_values = parse_values(args.values), parse_values(canonical)
    inputs = local_values.pop("secrets")
    pi_inputs = pi_values.pop("secrets")
    if local_values != pi_values or inputs.keys() != pi_inputs.keys():
        raise ValueError("workstation values differ from the retained Pi configuration")
    mapping = {}
    for key, path in inputs.items():
        source = Path(path)
        if not source.is_absolute() or not source.is_file() \
                or hashlib.sha256(source.read_bytes()).hexdigest() != info["inputs"][key]:
            raise ValueError(f"workstation input does not match the installed Pi input: {key}")
        mapping[pi_inputs[key]] = str(source)
    mapped = directory / "inputs.json"
    mapped.write_text(json.dumps(mapping))
    return canonical, mapped


def request_file(operation):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.connect(os.environ["RECIPE_DB_RELEASE_SOCKET"])
        connection.sendall((json.dumps({"operation": operation}) + "\n").encode())
        with connection.makefile("rb") as stream:
            response = json.loads(stream.readline(LIMIT + 1))
    if "error" in response:
        raise ValueError(response["error"])


def recommendation(line, args, canonical, snapshot):
    prefix = "mise run production-k3d "
    if prefix not in line:
        return line
    before, command = line.split(prefix, 1)
    tokens = shlex.split(command)
    if tokens and tokens[0] == "--release-sources-from-git":
        tokens.pop(0)
    if not tokens or tokens[0] not in ACTIONS:
        return before + "Use the cookbook's separately approved Pi recovery procedure.\n"
    if tokens[1:3] != [str(canonical), str(snapshot)]:
        raise ValueError("release recommendation contains unexpected private cache paths")
    return before + shlex.join([
        "mise", "run", "--raw", "production-release", "--pi", args.pi,
        tokens[0], args.values, *tokens[3:],
    ]) + "\n"


class Files(socketserver.UnixStreamServer):
    def __init__(self, path, args, snapshot, initial):
        super().__init__(str(path), FileRequest)
        self.args, self.snapshot = args, snapshot
        self.token, self.expected = args.token, initial["expected"]
        self.finalized = False

    def apply(self, operation):
        if operation not in {"checkpoint", "retain", "prune", "finalize"}:
            raise ValueError("unsupported private file operation")
        request = {"operation": operation, "token": self.token, "expected": self.expected}
        if operation == "checkpoint":
            state = json.loads((self.snapshot / "backup-state.json").read_text())
            post = state.get("postReleaseBackup")
            if post:
                post["snapshotPath"] = STATE + "/post-release-backup"
            request["state"] = state
        if operation == "retain":
            request["retained"] = json.loads(
                self.snapshot.with_name(self.snapshot.name + ".previous-runtime-secret.json").read_text()
            )
        result = remote(self.args, request)
        if operation == "checkpoint":
            self.expected = result["expected"]
        if operation == "finalize":
            self.finalized = True
        return {}


class FileRequest(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            request = json.loads(self.rfile.readline(1024))
            result = self.server.apply(request["operation"])
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            result = {"error": str(error)}
        self.wfile.write((json.dumps(result) + "\n").encode())


def run_controller(args, directory, canonical, mapped):
    args.token = uuid.uuid4().hex
    revision = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).decode().strip()
    initial = remote(args, {"operation": "begin", "token": args.token,
                            "revision": revision, "action": args.action,
                            "arguments": args.arguments})
    if initial.get("finalized"):
        print("Release publication cleanup completed; temporary Pi state and command claim removed.")
        return 0
    snapshot = directory / "maintenance"
    snapshot.mkdir(mode=0o700)
    state = initial["state"]
    if state.get("postReleaseBackup"):
        state["postReleaseBackup"]["snapshotPath"] = str(snapshot / "post-release-backup")
    for key, destination in (
        ("state", snapshot / "backup-state.json"),
        ("manifest", snapshot / "manifest.json"),
        ("retained", snapshot.with_name(snapshot.name + ".previous-runtime-secret.json")),
        ("postManifest", snapshot / "post-release-backup/manifest.json"),
    ):
        if initial[key] is not None:
            destination.parent.mkdir(exist_ok=True, mode=0o700)
            destination.write_text(json.dumps(initial[key]))
    server = Files(directory / "files.sock", args, snapshot, initial)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    environment = dict(os.environ, RECIPE_DB_RELEASE_SOCKET=str(server.server_address),
                       RECIPE_DB_RELEASE_INPUTS=str(mapped))
    child = None
    try:
        with subprocess.Popen(
            ["bash", str(ROOT / ".scripts/production-k3d.sh"), "--release-sources-from-git",
             args.action, str(canonical), str(snapshot), *args.arguments],
            env=environment, stdout=subprocess.PIPE, text=True, start_new_session=True,
        ) as child:
            try:
                for line in child.stdout:
                    print(recommendation(line, args, canonical, snapshot), end="", flush=True)
                return child.wait()
            except (KeyboardInterrupt, OSError, ValueError, subprocess.SubprocessError):
                ssh["upload"]["terminate_capture_process_group"](child)
                raise
    finally:
        server.shutdown()
        server.server_close()
        worker.join()
        if not server.finalized and (child is None or child.poll() is not None):
            remote(args, {"operation": "end", "token": args.token})


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--file-request":
        request_file(sys.argv[2])
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pi", default="piadmin@recipe-pi.home")
    parser.add_argument("action", choices=sorted(ACTIONS | {"preflight", "status", "evidence"}))
    parser.add_argument("values", help="absolute workstation values file")
    parser.add_argument("arguments", nargs="*")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*", args.pi) \
            or not Path(args.values).is_absolute():
        parser.error("use an explicit SSH user@hostname and absolute workstation values")
    for tool in (
        "git", "ssh", "jq", "yq", "ytt", "oras", "kubectl", "bash", "openssl", "curl",
        "awk", "base64", "basename", "cat", "chmod", "cp", "cut", "date", "dirname",
        "find", "grep", "head", "mkdir", "mktemp", "mv", "realpath", "rm", "rmdir",
        "sed", "sha256sum", "sleep", "sort", "stat", "tar", "tr", "wc", "xargs",
    ):
        if shutil.which(tool) is None:
            parser.error(f"missing workstation prerequisite: {tool}; install documented system tools and run mise install")

    def interrupt(signum, frame):
        raise KeyboardInterrupt

    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupt)
    os.umask(0o077)
    with ssh["ssh_session"](args), tempfile.TemporaryDirectory(
        prefix="recipe-db-release-", dir="/tmp",
    ) as temporary:
        directory = Path(temporary)
        canonical, mapped = prepare_inputs(args, directory)
        if args.action in {"status", "evidence"}:
            if args.arguments:
                parser.error("status/evidence take no additional arguments")
            print(json.dumps(remote(args, {"operation": args.action}), indent=2))
            return 0
        if args.action == "preflight":
            if len(args.arguments) != 1:
                parser.error("preflight requires the immutable candidate artifact")
            subprocess.run(
                ["bash", str(ROOT / ".scripts/production-k3d.sh"), "--release-sources-from-git",
                 "release-preflight", str(canonical), *args.arguments],
                env=dict(os.environ, RECIPE_DB_RELEASE_INPUTS=str(mapped)), check=True,
            )
            print("Release preflight passed; no release or maintenance operation was started.")
            return 0
        return run_controller(args, directory, canonical, mapped)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError,
            ssh["AuthenticationError"], EOFError) as error:
        print(f"release: {error}; inspect Pi state and command claims before retrying", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("release: interrupted; inspect Pi state and command claims before retrying", file=sys.stderr)
        sys.exit(130)
