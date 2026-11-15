#!/usr/bin/env python3
"""Stream the Pi's verified Drive baseline into a new private local directory."""

import argparse
from datetime import datetime, timedelta, timezone
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import subprocess
import sys
import tempfile
import time
import warnings


ROOT = Path(__file__).resolve().parent.parent
upload = runpy.run_path(str(ROOT / "provisioning/files/backup-upload.py"))
MAX_METADATA = upload["MAX_MANIFEST_BYTES"]


class AuthenticationError(Exception):
    pass


# Execute installed tooling, not a Pi checkout. Only selected metadata leaves the Pi.
REMOTE = """
import json, runpy, subprocess, sys
try:
    tool = runpy.run_path("/usr/local/sbin/recipe-db-backup-upload")
    config = tool["safe_config"]("/etc/recipe-db/backup.json")
    path = tool["baseline_path"](config)
    baseline = tool["read_json"](path)
    status = tool["report_status"](config)
    if baseline != tool["read_json"](path):
        raise ValueError("baseline changed")
    if sys.argv[1] == "metadata":
        keys = ("backupId", "archive", "manifest", "archiveSizeBytes",
                "manifestSizeBytes", "archiveSha256", "manifestSha256",
                "capturedAt", "lastUpload")
        print(json.dumps({
            "deploymentId": config["deploymentId"],
            "status": {key: status.get(key) for key in
                       ("format", "status", "lastCheck", "backupId")},
            "baseline": {key: baseline[key] for key in keys},
        }))
    else:
        field, name = sys.argv[1:]
        if field not in ("manifest", "archive") or baseline[field] != name:
            raise ValueError("baseline changed")
        subprocess.run(
            ["rclone", "cat", tool["remote_base"](config) + "/" + name,
             "--config", config["rcloneConfig"], "--log-level", "ERROR",
             "--log-file", "/dev/null", "--retries", "2",
             "--low-level-retries", "2", "--timeout", "5m", "--contimeout", "30s"],
            stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=True, timeout=3600,
        )
except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
    print("backup retrieval: Pi metadata or Drive read failed", file=sys.stderr)
    sys.exit(1)
"""


def parse_json(content):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate metadata key")
            result[key] = value
        return result
    return json.loads(content, object_pairs_hook=unique)


def ssh_options():
    home = Path.home() / ".config/recipe-db/ssh"
    return [
        "ssh", "-T", "-i", str(home / "recipe-db-pi"),
        "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", f"UserKnownHostsFile={home / 'known_hosts'}",
        "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=3",
    ]


def ssh_command(args, command):
    return [
        *ssh_options(), "-S", args.control_path,
        "-o", "ControlMaster=no", "-o", "BatchMode=yes",
        # A lost master must fail, not create another authenticated connection.
        "-o", "ProxyCommand=false", args.pi, shlex.join(command),
    ]


def authenticate(args):
    command = ssh_command(args, ["sudo", "-n", "-k", "python3", "-c", "pass"])
    command[-1] = "LC_ALL=C " + command[-1] + " 2>&1"
    result = subprocess.run(
        command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True,
    )
    args.sudo_password = None
    if result.returncode == 1 and "sudo: a password is required" in result.stdout.splitlines():
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            args.sudo_password = getpass.getpass("Pi sudo password (not SSH key passphrase): ")
    elif result.returncode != 0:
        raise AuthenticationError("SSH connection or Pi sudo permission/policy check failed")


def receive(args, remote_args, limit, destination=None):
    digest, size, content = hashlib.sha256(), 0, bytearray()
    password = args.sudo_password
    sudo = ["sudo", "-n", "-k"] if password is None else ["sudo", "-S", "-k", "-p", ""]
    command = [*sudo, "python3", "-c", REMOTE, *remote_args]
    with subprocess.Popen(ssh_command(args, command),
                          stdin=subprocess.DEVNULL if password is None else subprocess.PIPE,
                          stdout=subprocess.PIPE) as process:
        try:
            if password is not None:
                process.stdin.write((password + "\n").encode())
                process.stdin.close()
            while block := process.stdout.read(min(1024 * 1024, limit - size + 1)):
                size += len(block)
                if size > limit:
                    raise ValueError("received data exceeds its expected size")
                digest.update(block)
                if destination is None:
                    content.extend(block)
                else:
                    destination.write(block)
            if process.wait() != 0:
                raise ValueError("SSH or remote operation failed")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    return (size, digest.hexdigest()) if destination is not None else bytes(content)


def metadata(args):
    document = parse_json(receive(args, ("metadata",), MAX_METADATA))
    if not isinstance(document, dict):
        raise ValueError("invalid Pi metadata")
    status, baseline = document.get("status"), document.get("baseline")
    deployment = document.get("deploymentId")
    if not isinstance(status, dict) or not isinstance(baseline, dict) \
            or not isinstance(deployment, str) \
            or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", deployment):
        raise ValueError("invalid Pi metadata")
    if status.get("format") != upload["STATUS_FORMAT"] \
            or status.get("status") not in ("verified-upload", "verified-unchanged"):
        raise ValueError("latest backup check is not healthy")
    checked = upload["validate_timestamp"](status.get("lastCheck"))
    age = datetime.now(timezone.utc) - checked
    if not timedelta(0) <= age <= timedelta(hours=26):
        raise ValueError("latest backup check is overdue or in the future")
    backup_id = baseline.get("backupId")
    if not isinstance(backup_id, str) or not upload["BACKUP_ID_PATTERN"].fullmatch(backup_id):
        raise ValueError("invalid baseline backup identity")
    if status["status"] == "verified-upload" and status.get("backupId") != backup_id:
        raise ValueError("status and baseline backup identities differ")
    captured = upload["validate_timestamp"](baseline.get("capturedAt"))
    uploaded = upload["validate_timestamp"](baseline.get("lastUpload"))
    if captured > uploaded or uploaded > checked:
        raise ValueError("inconsistent baseline timestamps")
    stem = f"recipe-db-{deployment}-{captured.strftime('%Y%m%dT%H%M%SZ')}-{backup_id}"
    if baseline.get("archive") != stem + ".tar.gz" \
            or baseline.get("manifest") != stem + ".manifest.json":
        raise ValueError("invalid baseline filenames")
    for field in ("manifest", "archive"):
        size, digest = baseline.get(field + "SizeBytes"), baseline.get(field + "Sha256")
        limit = MAX_METADATA if field == "manifest" else 100 * 1024**3
        if type(size) is not int or not 0 < size <= limit \
                or not isinstance(digest, str) or not upload["HASH_PATTERN"].fullmatch(digest):
            raise ValueError("invalid baseline size or hash")
    return document


def verify_manifest(content, document):
    package = parse_json(content)
    baseline = document["baseline"]
    if not isinstance(package, dict) or package.get("format") != upload["PACKAGE_FORMAT"] \
            or type(package.get("formatVersion")) is not int or package["formatVersion"] != 1 \
            or package.get("backupId") != baseline["backupId"] \
            or package.get("deploymentId") != document["deploymentId"] \
            or package.get("capturedAt") != baseline["capturedAt"] \
            or package.get("archive") != {
                "name": baseline["archive"],
                "sizeBytes": baseline["archiveSizeBytes"],
                "sha256": baseline["archiveSha256"],
            }:
        raise ValueError("package manifest does not match the verified baseline")


def create_destination(destination):
    parent = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in destination.parts[1:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=parent)
            os.close(parent)
            parent = child
        os.mkdir(destination.name, mode=0o700, dir_fd=parent)
        return os.open(destination.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                       dir_fd=parent)
    finally:
        os.close(parent)


def retrieve(args):
    if ".." in Path(args.destination).parts:
        raise ValueError("destination must not contain '..'")
    destination = Path(os.path.abspath(os.path.expanduser(args.destination)))
    document = metadata(args)
    baseline = document["baseline"]
    directory = create_destination(destination)
    created = []
    complete = False
    try:
        for field in ("manifest", "archive"):
            descriptor = os.open(baseline[field] + ".partial",
                                 os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=directory)
            with os.fdopen(descriptor, "w+b") as stream:
                size, digest = receive(args, (field, baseline[field]),
                                       baseline[field + "SizeBytes"], stream)
                if size != baseline[field + "SizeBytes"] or digest != baseline[field + "Sha256"]:
                    raise ValueError(f"{field} size or SHA-256 mismatch")
                if field == "manifest":
                    stream.seek(0)
                    verify_manifest(stream.read(), document)
                stream.flush()
                os.fsync(stream.fileno())
        if metadata(args)["baseline"] != baseline:
            raise ValueError("verified baseline changed during retrieval; retry")
        for field in ("manifest", "archive"):
            name = baseline[field]
            os.link(name + ".partial", name, src_dir_fd=directory,
                    dst_dir_fd=directory, follow_symlinks=False)
            created.append(name)
        os.fsync(directory)
        complete = True
    finally:
        if not complete:
            for name in created:
                os.unlink(name, dir_fd=directory)
        for field in ("manifest", "archive"):
            try:
                os.unlink(baseline[field] + ".partial", dir_fd=directory)
            except FileNotFoundError:
                pass
        os.close(directory)
        if not complete:
            destination.rmdir()
    print(json.dumps({
        "backupId": baseline["backupId"],
        "manifest": str(destination / baseline["manifest"]),
        "archive": str(destination / baseline["archive"]),
    }, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", help="new directory under an existing symlink-free parent")
    parser.add_argument("--pi", default="piadmin@recipe-pi.home", help="SSH user@host for the Pi")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*", args.pi):
        parser.error("--pi must be an SSH user@hostname")
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="recipe-db-ssh-", dir="/tmp") as directory:
        args.control_path = str(Path(directory) / "connection")
        with subprocess.Popen(
            [*ssh_options(), "-M", "-N", "-S", args.control_path,
             "-o", "ControlPersist=no", args.pi],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        ) as connection:
            try:
                while not Path(args.control_path).is_socket():
                    if connection.poll() is not None:
                        raise AuthenticationError("SSH connection setup failed")
                    time.sleep(0.1)
                authenticate(args)
                retrieve(args)
            finally:
                args.sudo_password = None
                if connection.poll() is None:
                    connection.terminate()
                    try:
                        connection.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        connection.kill()
                        connection.wait()
                        raise AuthenticationError("SSH connection cleanup timed out")


if __name__ == "__main__":
    try:
        main()
    except AuthenticationError as error:
        print(f"backup retrieval: {error}", file=sys.stderr)
        sys.exit(1)
    except (getpass.GetPassWarning, EOFError):
        print("backup retrieval: sudo authentication requires an interactive terminal; "
              "run mise run --raw retrieve-verified-backup DESTINATION", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError, KeyError):
        print("backup retrieval: failed; check Pi backup health, SSH/sudo access, "
              "destination and package integrity", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("backup retrieval: interrupted; no completed download", file=sys.stderr)
        sys.exit(130)
