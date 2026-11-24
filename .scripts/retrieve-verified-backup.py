#!/usr/bin/env python3
"""Retrieve a verified Pi Drive backup by baseline, ID, or read-only catalog."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import warnings


ROOT = Path(__file__).resolve().parent.parent
upload = runpy.run_path(str(ROOT / "provisioning/files/backup-upload.py"))
MAX_METADATA = upload["MAX_MANIFEST_BYTES"]
MAX_MAINTENANCE_METADATA = MAX_METADATA + 1024 * 1024


class AuthenticationError(Exception):
    pass


# Execute installed tooling, not a Pi checkout. Only selected metadata leaves the Pi.
REMOTE = """
import hashlib, json, runpy, subprocess, sys
try:
    tool = runpy.run_path("/usr/local/sbin/recipe-db-backup-upload")
    config = tool["safe_config"]("/etc/recipe-db/backup.json")
    if sys.argv[1] == "catalog":
        try:
            print(json.dumps(tool["verified_remote_catalog"](config)))
        except tool["BackupError"] as error:
            raise ValueError("remote catalog verification failed") from error
        sys.exit(0)
    maintenance_operation = None
    if sys.argv[1] in ("maintenance", "maintenance-package", "maintenance-snapshot"):
        state_path = tool["maintenance_state_path"](config)
        state = tool["lifecycle_state"](state_path)
        upload_status = tool["report_status"](config)
        if not isinstance(state, dict) or state.get("status") != "captured" \
                or state.get("phase") != "captured" \
                or not tool["BACKUP_ID_PATTERN"].fullmatch(str(state.get("backupId", ""))) \
                or not upload_status.get("maintenanceActive") \
                or upload_status.get("status") not in ("verified-upload", "verified-unchanged") \
                or upload_status.get("backupId") != state.get("backupId"):
            raise ValueError("no verified backup belongs to the retained maintenance operation")
        manifest_path = state_path / "manifest.json"
        if state_path.is_symlink() or manifest_path.is_symlink() or not manifest_path.is_file():
            raise ValueError("retained maintenance snapshot is unavailable")
        local_manifest = tool["read_json"](manifest_path)
        if not isinstance(local_manifest, dict) or not isinstance(state.get("source"), dict) \
                or local_manifest.get("backupId") != state["backupId"] \
                or local_manifest.get("source") != state.get("source") \
                or local_manifest.get("capturedAt") != state.get("capturedAt"):
            raise ValueError("retained maintenance snapshot identity changed")
        backup_id = state["backupId"]
        maintenance_operation = {
            "backupId": backup_id, "status": state["status"], "phase": state["phase"],
            "source": state["source"], "capturedAt": state["capturedAt"],
            "uploadStatus": upload_status["status"],
        }
        if upload_status["status"] == "verified-unchanged":
            snapshot_manifest = tool["validate_snapshot"](state_path)
            fingerprint = tool["content_fingerprint"](snapshot_manifest)
            baseline = tool["read_json"](tool["baseline_path"](config))
            names = tool["remote_names"](config)
            if not isinstance(baseline, dict) or baseline.get("fingerprint") != fingerprint \
                    or baseline.get("archive") not in names \
                    or baseline.get("manifest") not in names \
                    or (sys.argv[1] != "maintenance-snapshot"
                        and not tool["verify_baseline"](config, baseline, names)):
                raise ValueError("unchanged maintenance snapshot does not match the verified baseline")
            baseline_backup_id = baseline.get("backupId")
            if not tool["BACKUP_ID_PATTERN"].fullmatch(str(baseline_backup_id or "")):
                raise ValueError("verified baseline has an invalid backup identity")
            maintenance_operation.update(
                packageBackupId=backup_id,
                verifiedBaselineBackupId=baseline_backup_id,
                contentFingerprint=fingerprint,
            )
            if sys.argv[1] == "maintenance":
                print(json.dumps({
                    "deploymentId": config["deploymentId"],
                    "maintenanceOperation": maintenance_operation,
                    "maintenanceSnapshot": {
                        "manifest": snapshot_manifest,
                        "contentFingerprint": fingerprint,
                        "maxStagingBytes": config["maxStagingBytes"],
                    },
                }))
                sys.exit(0)
            if sys.argv[1] == "maintenance-snapshot":
                if len(sys.argv) != 4 or sys.argv[2] != backup_id:
                    raise ValueError("requested snapshot does not match the retained maintenance operation")
                archive_name = sys.argv[3]
                item = next((entry for entry in snapshot_manifest["inventory"]
                             if entry.get("archive") == archive_name), None)
                if item is None:
                    raise ValueError("requested snapshot archive is not in the retained operation")
                archive_path = state_path / archive_name
                if archive_path.is_symlink() or not archive_path.is_file() \
                        or archive_path.stat().st_size != item["sizeBytes"]:
                    raise ValueError("retained snapshot archive changed")
                with open(archive_path, "rb") as stream:
                    while block := stream.read(1024 * 1024):
                        sys.stdout.buffer.write(block)
                sys.exit(0)
            raise ValueError("unchanged maintenance package must be retrieved from the retained snapshot")
        maintenance_operation["packageBackupId"] = backup_id
        if sys.argv[1] == "maintenance":
            sys.argv = [sys.argv[0], "backup-id", backup_id]
        else:
            if sys.argv[1] != "maintenance-package" or len(sys.argv) != 5 \
                    or sys.argv[2] != backup_id:
                raise ValueError("requested backup does not match the retained maintenance operation")
            sys.argv = [sys.argv[0], "package", backup_id, *sys.argv[3:]]
    if sys.argv[1] in ("backup-id", "package"):
        backup_id = sys.argv[2]
        if not tool["BACKUP_ID_PATTERN"].fullmatch(backup_id):
            raise ValueError("invalid backup ID")
        try:
            names = tool["remote_names"](config)
            candidates = [name for name in names
                          if tool["remote_point_backup_id"](config, name) == backup_id]
            if len(candidates) != 1:
                raise ValueError("requested backup is missing, incomplete, or ambiguous")
            matches = tool["complete_remote_points"](
                config, names, backup_id=backup_id, verify_archive=False)
        except tool["BackupError"] as error:
            raise ValueError("requested backup verification failed") from error
        if len(matches) != 1 or matches[0][1] != backup_id \
                or matches[0][3] != candidates[0]:
            raise ValueError("requested backup is incomplete or invalid")
        _, _, archive_name, manifest_name = matches[0]
        package = tool["read_remote_manifest"](config, manifest_name)
        manifest_bytes = tool["json_bytes"](package)
        archive = package["archive"]
        baseline = {
            "backupId": backup_id,
            "archive": archive_name,
            "manifest": manifest_name,
            "archiveSizeBytes": archive["sizeBytes"],
            "manifestSizeBytes": len(manifest_bytes),
            "archiveSha256": archive["sha256"],
            "manifestSha256": hashlib.sha256(manifest_bytes).hexdigest(),
            "capturedAt": package["capturedAt"],
        }
        if maintenance_operation is not None:
            baseline["contentFingerprint"] = package.get("contentFingerprint")
        if sys.argv[1] == "backup-id":
            result = {"deploymentId": config["deploymentId"], "baseline": baseline}
            if maintenance_operation is not None:
                result["maintenanceOperation"] = maintenance_operation
            print(json.dumps(result))
        else:
            if len(sys.argv) != 5:
                raise ValueError("invalid package request")
            field, name = sys.argv[3:]
            if field not in ("manifest", "archive") or baseline[field] != name:
                raise ValueError("requested backup changed")
            subprocess.run(
                ["rclone", "cat", tool["remote_base"](config) + "/" + name,
                 "--config", config["rcloneConfig"], "--log-level", "ERROR",
                 "--log-file", "/dev/null", "--retries", "2",
                 "--low-level-retries", "2", "--timeout", "5m", "--contimeout", "30s"],
                stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                check=True, timeout=3600,
            )
    else:
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
    selected = args.backup_id is not None or args.maintenance
    remote_args = ("maintenance",) if args.maintenance else (
        ("backup-id", args.backup_id) if selected else ("metadata",))
    metadata_limit = MAX_MAINTENANCE_METADATA if args.maintenance else MAX_METADATA
    document = parse_json(receive(args, remote_args, metadata_limit))
    if not isinstance(document, dict):
        raise ValueError("invalid Pi metadata")
    if args.maintenance and "maintenanceSnapshot" in document:
        snapshot = document["maintenanceSnapshot"]
        operation = document.get("maintenanceOperation")
        manifest = snapshot.get("manifest") if isinstance(snapshot, dict) else None
        fingerprint = snapshot.get("contentFingerprint") if isinstance(snapshot, dict) else None
        operation_id = operation.get("backupId") if isinstance(operation, dict) else None
        baseline_id = operation.get("verifiedBaselineBackupId") \
            if isinstance(operation, dict) else None
        if not isinstance(document.get("deploymentId"), str) \
                or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", document["deploymentId"]) \
                or not isinstance(manifest, dict) \
                or not isinstance(fingerprint, str) \
                or not upload["HASH_PATTERN"].fullmatch(fingerprint) \
                or type(snapshot.get("maxStagingBytes")) is not int \
                or not 256 * 1024**2 <= snapshot["maxStagingBytes"] <= 100 * 1024**3 \
                or not isinstance(operation, dict) \
                or not isinstance(operation_id, str) \
                or not upload["BACKUP_ID_PATTERN"].fullmatch(operation_id) \
                or not isinstance(baseline_id, str) \
                or not upload["BACKUP_ID_PATTERN"].fullmatch(baseline_id) \
                or operation.get("packageBackupId") != operation_id \
                or operation.get("uploadStatus") != "verified-unchanged" \
                or operation.get("status") != "captured" \
                or operation.get("phase") != "captured" \
                or not isinstance(operation.get("source"), dict) \
                or operation.get("source") != manifest.get("source") \
                or operation.get("capturedAt") != manifest.get("capturedAt") \
                or operation.get("contentFingerprint") != fingerprint \
                or manifest.get("backupId") != operation_id \
                or upload["content_fingerprint"](manifest) != fingerprint:
            raise ValueError("invalid retained maintenance snapshot metadata")
        upload["validate_timestamp"](operation.get("capturedAt"))
        return document
    status, baseline = document.get("status"), document.get("baseline")
    deployment = document.get("deploymentId")
    if (not selected and not isinstance(status, dict)) or not isinstance(baseline, dict) \
            or not isinstance(deployment, str) \
            or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", deployment):
        raise ValueError("invalid Pi metadata")
    if not selected:
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
    if args.backup_id is not None and backup_id != args.backup_id:
        raise ValueError("Pi returned a different backup ID")
    if args.maintenance:
        operation = document.get("maintenanceOperation")
        upload_status = operation.get("uploadStatus") if isinstance(operation, dict) else None
        operation_identity_valid = isinstance(operation, dict) \
            and operation.get("packageBackupId") == backup_id
        if upload_status == "verified-upload":
            operation_identity_valid = operation_identity_valid \
                and operation.get("backupId") == backup_id \
                and operation.get("capturedAt") == baseline.get("capturedAt")
        elif upload_status == "verified-unchanged":
            operation_identity_valid = operation_identity_valid \
                and isinstance(operation.get("contentFingerprint"), str) \
                and upload["HASH_PATTERN"].fullmatch(operation["contentFingerprint"]) \
                and operation["contentFingerprint"] == baseline.get("contentFingerprint")
        else:
            operation_identity_valid = False
        if not operation_identity_valid \
                or operation.get("status") != "captured" \
                or operation.get("phase") != "captured" \
                or not isinstance(operation.get("source"), dict) \
                or not re.fullmatch(r"ghcr[.]io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}",
                                    str(operation["source"].get("artifact", ""))):
            raise ValueError("remote package is not tied to the retained maintenance operation")
    if not selected and status["status"] == "verified-upload" and status.get("backupId") != backup_id:
        raise ValueError("status and baseline backup identities differ")
    captured = upload["validate_timestamp"](baseline.get("capturedAt"))
    if not selected:
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


def retrieve_maintenance_snapshot(args, document, destination, directory):
    snapshot_metadata = document["maintenanceSnapshot"]
    manifest = snapshot_metadata["manifest"]
    snapshot = destination / ".snapshot"
    os.mkdir(snapshot.name, mode=0o700, dir_fd=directory)
    try:
        snapshot_directory = os.open(snapshot, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except BaseException:
        snapshot.rmdir()
        raise
    manifest_path = snapshot / "manifest.json"
    complete = False
    try:
        descriptor = os.open(
            "manifest.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600, dir_fd=snapshot_directory,
        )
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(upload["json_bytes"](manifest))
            stream.flush()
            os.fsync(stream.fileno())
        for item in manifest["inventory"]:
            archive_name = item.get("archive")
            if not isinstance(archive_name, str) \
                    or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.tar", archive_name) \
                    or type(item.get("sizeBytes")) is not int \
                    or item["sizeBytes"] <= 0 \
                    or not isinstance(item.get("sha256"), str) \
                    or not upload["HASH_PATTERN"].fullmatch(item["sha256"]):
                raise ValueError("invalid retained snapshot archive metadata")
            descriptor = os.open(
                archive_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600, dir_fd=snapshot_directory,
            )
            with os.fdopen(descriptor, "wb") as stream:
                size, digest = receive(
                    args,
                    ("maintenance-snapshot", manifest["backupId"], archive_name),
                    item["sizeBytes"], stream,
                )
                if size != item["sizeBytes"] or digest != item["sha256"]:
                    raise ValueError("retained snapshot archive size or SHA-256 mismatch")
                stream.flush()
                os.fsync(stream.fileno())
        verified_manifest = upload["validate_snapshot"](snapshot)
        if verified_manifest != manifest \
                or upload["content_fingerprint"](verified_manifest) \
                != snapshot_metadata["contentFingerprint"]:
            raise ValueError("retained snapshot differs from its verified metadata")
        current = metadata(args)
        if current.get("maintenanceOperation") != document["maintenanceOperation"] \
                or current.get("maintenanceSnapshot") != snapshot_metadata:
            raise ValueError("retained maintenance snapshot changed during retrieval")
        package = upload["create_package"](
            snapshot, destination, verified_manifest, document["deploymentId"],
            snapshot_metadata["maxStagingBytes"],
        )
        for name in (manifest_path.name, *(item["archive"] for item in manifest["inventory"])):
            (snapshot / name).unlink()
        snapshot.rmdir()
        complete = True
        operation = document["maintenanceOperation"]
        return {
            "backupId": package["backupId"],
            "manifest": str(destination / package["manifest"]),
            "archive": str(destination / package["archive"]),
            "maintenanceOperation": {
                key: operation[key] for key in
                ("backupId", "packageBackupId", "status", "phase", "source", "capturedAt",
                 "uploadStatus", "contentFingerprint", "verifiedBaselineBackupId")
            },
        }
    finally:
        if not complete:
            for path in destination.iterdir():
                if path.is_file() and not path.is_symlink():
                    path.unlink()
            for path in snapshot.iterdir():
                if path.is_file() and not path.is_symlink():
                    path.unlink()
            snapshot.rmdir()
        os.close(snapshot_directory)


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
    if "maintenanceOperation" in document \
            and package.get("source") != document["maintenanceOperation"].get("source"):
        raise ValueError("package source does not match the retained maintenance operation")


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
    directory = create_destination(destination)
    if args.maintenance and "maintenanceSnapshot" in document:
        try:
            return retrieve_maintenance_snapshot(args, document, destination, directory)
        except BaseException:
            try:
                destination.rmdir()
            except OSError:
                pass
            raise
        finally:
            os.close(directory)
    baseline = document["baseline"]
    selected_backup_id = args.backup_id
    if args.maintenance:
        selected_backup_id = baseline["backupId"]
    created = []
    complete = False
    try:
        for field in ("manifest", "archive"):
            descriptor = os.open(baseline[field] + ".partial",
                                 os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o600, dir_fd=directory)
            with os.fdopen(descriptor, "w+b") as stream:
                if args.maintenance:
                    remote_args = ("maintenance-package", baseline["backupId"],
                                   field, baseline[field])
                elif selected_backup_id is not None:
                    remote_args = ("package", selected_backup_id, field, baseline[field])
                else:
                    remote_args = (field, baseline[field])
                size, digest = receive(args, remote_args,
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
    return {
        "backupId": baseline["backupId"],
        "manifest": str(destination / baseline["manifest"]),
        "archive": str(destination / baseline["archive"]),
        **({"maintenanceOperation": document["maintenanceOperation"]}
           if args.maintenance else {}),
    }


@contextmanager
def ssh_session(args):
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
                yield
            finally:
                for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                    signal.signal(signum, signal.SIG_IGN)
                args.sudo_password = None
                if connection.poll() is None:
                    connection.terminate()
                    try:
                        connection.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        connection.kill()
                        connection.wait()
                        raise AuthenticationError(
                            "SSH connection cleanup timed out; check destination before retrying")


def retrieve_catalog(args):
    document = parse_json(receive(args, ("catalog",), MAX_METADATA))
    if not isinstance(document, dict) \
            or document.get("format") != "recipe-db-backup-catalog" \
            or document.get("formatVersion") != 1 \
            or not isinstance(document.get("deploymentId"), str) \
            or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", document["deploymentId"]) \
            or not isinstance(document.get("points"), list):
        raise ValueError("invalid remote backup catalog")
    upload["validate_timestamp"](document.get("checkedAt"))
    identities = set()
    for point in document["points"]:
        if not isinstance(point, dict) \
                or not isinstance(point.get("backupId"), str) \
                or not upload["BACKUP_ID_PATTERN"].fullmatch(point["backupId"]) \
                or point["backupId"] in identities \
                or not isinstance(point.get("source"), dict) \
                or not re.fullmatch(r"ghcr[.]io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}",
                                    str(point["source"].get("artifact", ""))) \
                or not re.fullmatch(r"[0-9a-f]{40}", str(point["source"].get("revision", ""))):
            raise ValueError("invalid remote backup catalog point")
        upload["validate_timestamp"](point.get("capturedAt"))
        identities.add(point["backupId"])
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", help="new directory under an existing symlink-free parent")
    parser.add_argument("--pi", default="piadmin@recipe-pi.home", help="SSH user@host for the Pi")
    parser.add_argument("--backup-id", help="retrieve this exact complete backup, independent of latest status")
    parser.add_argument("--maintenance", action="store_true",
                        help="retrieve the verified backup for the retained maintenance operation")
    parser.add_argument("--catalog", action="store_true",
                        help="verify off-device backup points and print metadata without saving packages")
    args = parser.parse_args()
    if args.catalog == (args.destination is not None):
        parser.error("choose either DESTINATION or --catalog")
    if args.catalog and args.backup_id is not None:
        parser.error("--backup-id cannot be combined with --catalog")
    if args.maintenance and (args.catalog or args.backup_id is not None):
        parser.error("--maintenance cannot be combined with --catalog or --backup-id")
    if args.backup_id is not None \
            and not upload["BACKUP_ID_PATTERN"].fullmatch(args.backup_id):
        parser.error("--backup-id must be a valid backup ID")
    if not re.fullmatch(r"[a-zA-Z0-9_][a-zA-Z0-9_.-]*@[a-zA-Z0-9][a-zA-Z0-9.-]*", args.pi):
        parser.error("--pi must be an SSH user@hostname")

    def interrupt(signum, frame):
        raise KeyboardInterrupt

    for signum in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupt)
    os.umask(0o077)
    with ssh_session(args):
        result = retrieve_catalog(args) if args.catalog else retrieve(args)
    print(json.dumps(result, sort_keys=True))


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
        print("backup retrieval: interrupted; check destination before retrying", file=sys.stderr)
        sys.exit(130)
