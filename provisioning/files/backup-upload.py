#!/usr/bin/env python3
"""Package complete lifecycle snapshots and publish verified backup points."""

import argparse
from datetime import datetime, timedelta, timezone
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time


FORMAT = "recipe-db-pvc-snapshot"
PACKAGE_FORMAT = "recipe-db-backup"
STATUS_FORMAT = "recipe-db-backup-status"
DEFAULT_MAX_STAGING_BYTES = 8 * 1024**3
MAX_MANIFEST_BYTES = 64 * 1024**2
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
BACKUP_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
REMOTE_FILENAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$")
MAX_REMOTE_MANIFEST_BYTES = 128 * 1024**2
SAFE_RECOVERY_STATES = {("failed", "safely-recovered"), ("recovered", "safely-recovered")}


class BackupError(Exception):
    def __init__(self, status, code):
        super().__init__(code)
        self.status = status
        self.code = code


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def read_json(path, max_bytes=MAX_MANIFEST_BYTES):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > max_bytes:
        raise ValueError("invalid metadata file")
    return json.loads(path.read_text())


def lifecycle_state(snapshot):
    try:
        return read_json(Path(snapshot) / "backup-state.json")
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def safely_recovered(state):
    return isinstance(state, dict) and (state.get("status"), state.get("phase")) in SAFE_RECOVERY_STATES


def validate_timestamp(value):
    if not isinstance(value, str):
        raise ValueError("invalid timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("invalid timestamp")
    return parsed.astimezone(timezone.utc)


def validate_snapshot(snapshot):
    snapshot = Path(snapshot)
    if snapshot.is_symlink() or not snapshot.is_dir():
        raise ValueError("invalid snapshot directory")
    manifest_path = snapshot / "manifest.json"
    manifest = read_json(manifest_path)
    if manifest.get("format") != FORMAT or manifest.get("formatVersion") != 1:
        raise ValueError("unsupported snapshot format")
    if (snapshot / "backup-state.json").exists():
        raise ValueError("snapshot is incomplete")
    if not BACKUP_ID_PATTERN.fullmatch(manifest.get("backupId", "")):
        raise ValueError("invalid backup identity")
    source = manifest.get("source")
    if not isinstance(source, dict) or not all(
        isinstance(source.get(key), str) and source[key]
        for key in ("target", "cluster", "context", "namespace", "artifact", "revision")
    ):
        raise ValueError("invalid release identity")
    if source["target"] not in ("local", "pi") \
            or not re.fullmatch(r"ghcr[.]io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}", source["artifact"]) \
            or not re.fullmatch(r"[0-9a-f]{40}", source["revision"]):
        raise ValueError("invalid release identity")
    validate_timestamp(manifest.get("capturedAt"))
    inventory = manifest.get("inventory")
    if not isinstance(inventory, list) or not inventory:
        raise ValueError("empty snapshot inventory")
    expected_names = {"manifest.json"}
    seen_archives = set()
    for pvc in inventory:
        if not isinstance(pvc, dict):
            raise ValueError("invalid inventory")
        if not all(isinstance(pvc.get(key), str) and pvc[key]
                   for key in ("service", "role", "pvc")):
            raise ValueError("invalid inventory identity")
        archive_name = pvc.get("archive")
        if not isinstance(archive_name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.tar", archive_name):
            raise ValueError("invalid archive name")
        if archive_name in seen_archives:
            raise ValueError("duplicate archive name")
        seen_archives.add(archive_name)
        expected_names.add(archive_name)
        archive = snapshot / archive_name
        if archive.is_symlink() or not archive.is_file():
            raise ValueError("missing archive")
        archive_size = archive.stat().st_size
        if type(pvc.get("sizeBytes")) is not int or pvc["sizeBytes"] != archive_size:
            raise ValueError("archive size mismatch")
        if not HASH_PATTERN.fullmatch(pvc.get("sha256", "")):
            raise ValueError("invalid archive checksum")
        files = pvc.get("files")
        if type(pvc.get("fileCount")) is not int or pvc["fileCount"] < 0 \
                or not isinstance(files, list) or len(files) != pvc["fileCount"]:
            raise ValueError("invalid file inventory")
        expected_files = {}
        for entry in files:
            if not isinstance(entry, dict):
                raise ValueError("invalid file entry")
            name, size, digest = entry.get("path"), entry.get("sizeBytes"), entry.get("sha256")
            path = PurePosixPath(name) if isinstance(name, str) else None
            if path is None or path.is_absolute() or ".." in path.parts or str(path) != name or not name:
                raise ValueError("unsafe file path")
            if name in expected_files or type(size) is not int or size < 0 or not HASH_PATTERN.fullmatch(digest or ""):
                raise ValueError("invalid file entry")
            expected_files[name] = (size, digest)
        if list(expected_files) != sorted(expected_files):
            raise ValueError("unordered file inventory")
        observed = {}
        directories = set()
        try:
            with tarfile.open(archive, "r:") as source_tar:
                for member in source_tar:
                    name = member.name.removeprefix("./")
                    if name in ("", ".") and member.isdir():
                        continue
                    path = PurePosixPath(name)
                    if path.is_absolute() or ".." in path.parts or str(path) != name:
                        raise ValueError("unsafe archive path")
                    if member.isdir():
                        if name not in ("public", "manifests") or name in directories:
                            raise ValueError("unclassified archive directory")
                        directories.add(name)
                        continue
                    if not member.isfile() or name in observed:
                        raise ValueError("unsafe archive member")
                    stream = source_tar.extractfile(member)
                    if stream is None:
                        raise ValueError("unreadable archive member")
                    file_digest = hashlib.sha256()
                    size = 0
                    while block := stream.read(1024 * 1024):
                        file_digest.update(block)
                        size += len(block)
                    observed[name] = (size, file_digest.hexdigest())
        except tarfile.TarError as error:
            raise ValueError("invalid archive") from error
        if observed != expected_files or file_hash(archive) != pvc["sha256"]:
            raise ValueError("archive integrity mismatch")
        if directories and directories != {"public", "manifests"}:
            raise ValueError("incomplete image directories")
        if pvc["service"] == "images" and directories != {"public", "manifests"}:
            raise ValueError("image snapshot lacks storage directories")
        if pvc["service"] != "images" and directories:
            raise ValueError("unclassified archive directories")
    if {entry.name for entry in snapshot.iterdir()} != expected_names:
        raise ValueError("unexpected snapshot content")
    return manifest


def content_fingerprint(manifest):
    source = manifest["source"]
    content = {
        "format": manifest["format"],
        "formatVersion": manifest["formatVersion"],
        "artifact": source["artifact"],
        "revision": source["revision"],
        "inventory": [
            {
                "service": item["service"],
                "role": item["role"],
                "pvc": item["pvc"],
                "archive": item["archive"],
                "files": item["files"],
            }
            for item in sorted(manifest["inventory"], key=lambda item: item["archive"])
        ],
    }
    return hashlib.sha256(json_bytes(content)).hexdigest()


def add_bytes(tar, name, data):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o600
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    tar.addfile(info, io.BytesIO(data))


def create_package(snapshot, stage, manifest, deployment_id, max_bytes):
    snapshot = Path(snapshot)
    stage = Path(stage)
    capture_order = validate_timestamp(manifest["capturedAt"])
    stamp = capture_order.strftime("%Y%m%dT%H%M%SZ")
    backup_id = manifest["backupId"]
    prefix = f"recipe-db-{deployment_id}-{stamp}-{backup_id}"
    archive_name = prefix + ".tar.gz"
    metadata_name = prefix + ".manifest.json"
    archive_path = stage / archive_name
    source_manifest_bytes = (snapshot / "manifest.json").read_bytes()
    input_size = sum((snapshot / item["archive"]).stat().st_size for item in manifest["inventory"])
    if input_size * 2 + len(source_manifest_bytes) * 3 + input_size // 100 + 1024 * 1024 > max_bytes:
        raise BackupError("capture-failure", "staging-limit")
    free = shutil.disk_usage(stage).free
    if free < input_size * 2 + input_size // 100 + 64 * 1024**2:
        raise BackupError("capture-failure", "staging-space")
    try:
        with open(archive_path, "xb") as output:
            with gzip.GzipFile(filename="", fileobj=output, mode="wb", mtime=0, compresslevel=6) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as bundle:
                    add_bytes(bundle, "manifest.json", source_manifest_bytes)
                    for entry in sorted(manifest["inventory"], key=lambda item: item["archive"]):
                        source_path = snapshot / entry["archive"]
                        info = tarfile.TarInfo(entry["archive"])
                        info.size = source_path.stat().st_size
                        info.mode = 0o600
                        info.mtime = 0
                        info.uid = info.gid = 0
                        info.uname = info.gname = ""
                        with open(source_path, "rb") as stream:
                            bundle.addfile(info, stream)
    except OSError as error:
        raise BackupError("capture-failure", "staging-write") from error
    archive_size = archive_path.stat().st_size
    if archive_size > max_bytes:
        raise BackupError("capture-failure", "staging-limit")
    archive_digest = hashlib.sha256()
    with open(archive_path, "rb") as stream:
        while block := stream.read(1024 * 1024):
            archive_digest.update(block)
    archive_hash = archive_digest.hexdigest()
    package_manifest = {
        "format": PACKAGE_FORMAT,
        "formatVersion": 1,
        "deploymentId": deployment_id,
        "backupId": backup_id,
        "capturedAt": manifest["capturedAt"],
        "source": manifest["source"],
        "contentFingerprint": content_fingerprint(manifest),
        "snapshotManifest": manifest,
        "archive": {"name": archive_name, "sizeBytes": archive_size, "sha256": archive_hash},
    }
    metadata_path = stage / metadata_name
    try:
        metadata_path.write_bytes(json_bytes(package_manifest))
        os.chmod(metadata_path, 0o600)
    except OSError as error:
        raise BackupError("capture-failure", "staging-write") from error
    if input_size + len(source_manifest_bytes) + archive_size + metadata_path.stat().st_size > max_bytes:
        raise BackupError("capture-failure", "staging-limit")
    return {
        "archive": archive_name,
        "manifest": metadata_name,
        "archiveSha256": archive_hash,
        "manifestSha256": hashlib.sha256(metadata_path.read_bytes()).hexdigest(),
        "fingerprint": package_manifest["contentFingerprint"],
        "capturedAt": manifest["capturedAt"],
        "backupId": backup_id,
        "archiveSizeBytes": archive_size,
    }


def safe_config(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        raise ValueError("configuration must be a private regular file")
    config = read_json(path)
    for key in ("deploymentId", "remote", "rcloneConfig", "stateDirectory", "stagingDirectory"):
        if not isinstance(config.get(key), str) or not config[key]:
            raise ValueError("incomplete configuration")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", config["deploymentId"]):
        raise ValueError("invalid deployment")
    remote_name, remote_folder = config["remote"].split(":", 1) if ":" in config["remote"] else ("", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", remote_name) or not remote_folder \
            or remote_folder.startswith("/") or ".." in remote_folder.split("/"):
        raise ValueError("invalid remote")
    for key in ("rcloneConfig", "stateDirectory", "stagingDirectory", "captureCommand"):
        config[key] = str(absolute_path(config[key]))
    rclone_config = Path(config["rcloneConfig"])
    if rclone_config.is_symlink() or not rclone_config.is_file() or rclone_config.stat().st_mode & 0o077:
        raise ValueError("rclone configuration must be private")
    config["maxStagingBytes"] = int(config.get("maxStagingBytes", DEFAULT_MAX_STAGING_BYTES))
    if not 256 * 1024**2 <= config["maxStagingBytes"] <= 100 * 1024**3:
        raise ValueError("invalid staging limit")
    config["captureTimeoutSeconds"] = int(config.get("captureTimeoutSeconds", 5400))
    if not 60 <= config["captureTimeoutSeconds"] <= 7200:
        raise ValueError("invalid capture timeout")
    return config


def ensure_private_dir(path):
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or not path.is_dir():
        raise ValueError("invalid private directory")
    os.chmod(path, 0o700)
    return path


def atomic_json(path, value):
    path = Path(path)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".next", dir=path.parent)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(json_bytes(value))
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def absolute_path(value):
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("configuration paths must be absolute")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise ValueError("configuration paths must not traverse symlinks")
    return path


def status_path(config):
    return Path(config["stateDirectory"]) / "status.json"


def write_status(config, status, code, backup_id=None, last_upload=None):
    path = status_path(config)
    prior = {}
    if path.is_file() and not path.is_symlink():
        try:
            prior = read_json(path)
        except (OSError, ValueError, json.JSONDecodeError):
            pass
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    value = {
        "format": STATUS_FORMAT,
        "status": status,
        "code": code,
        "lastCheck": now,
        "lastUpload": last_upload if last_upload is not None else prior.get("lastUpload"),
        "backupId": backup_id,
    }
    atomic_json(path, value)
    return value


def rclone(config, *args, timeout=3600):
    command = [
        "rclone", *args, "--config", config["rcloneConfig"], "--log-level", "ERROR",
        "--log-file", "/dev/null", "--retries", "2", "--low-level-retries", "2",
        "--timeout", "5m", "--contimeout", "30s",
    ]
    try:
        subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        raise BackupError("upload-failure", "remote-operation") from error


def remote_base(config):
    return config["remote"].rstrip("/") + "/" + config["deploymentId"]


def remote_names(config):
    try:
        result = subprocess.run(
            ["rclone", "lsf", remote_base(config), "--files-only", "--format", "p",
             "--config", config["rcloneConfig"], "--log-level", "ERROR", "--log-file", "/dev/null"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            check=True, timeout=120, text=True,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise BackupError("upload-failure", "remote-list") from error
    return {line for line in result.stdout.splitlines() if REMOTE_FILENAME_PATTERN.fullmatch(line)}


def remote_hash(config, name, expected_size):
    if type(expected_size) is not int or expected_size < 0 \
            or expected_size > config["maxStagingBytes"]:
        raise BackupError("upload-failure", "invalid-remote-size")
    command = ["rclone", "cat", remote_base(config) + "/" + name,
               "--config", config["rcloneConfig"], "--log-level", "ERROR", "--log-file", "/dev/null"]
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError as error:
        raise BackupError("upload-failure", "remote-read") from error
    digest = hashlib.sha256()
    size = 0
    try:
        while block := process.stdout.read(1024 * 1024):
            size += len(block)
            if size > expected_size:
                process.kill()
                process.wait()
                raise BackupError("upload-failure", "remote-integrity")
            digest.update(block)
        result = process.wait(timeout=900)
    except (OSError, subprocess.SubprocessError) as error:
        process.kill()
        process.wait()
        raise BackupError("upload-failure", "remote-read") from error
    except BaseException:
        process.kill()
        process.wait()
        raise
    if result != 0 or size != expected_size:
        raise BackupError("upload-failure", "remote-integrity")
    return digest.hexdigest()


def read_remote_manifest(config, name):
    max_bytes = MAX_REMOTE_MANIFEST_BYTES
    command = ["rclone", "cat", remote_base(config) + "/" + name,
               "--config", config["rcloneConfig"], "--log-level", "ERROR", "--log-file", "/dev/null"]
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL)
        document = process.stdout.read(max_bytes + 1)
        if len(document) > max_bytes:
            process.kill()
            process.wait()
            return None
        if process.wait(timeout=120) != 0:
            return None
        return json.loads(document)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return None


def verify_baseline(config, baseline, names):
    if not isinstance(baseline, dict):
        return False
    archive_name, metadata_name = baseline.get("archive"), baseline.get("manifest")
    if not isinstance(archive_name, str) or not isinstance(metadata_name, str):
        return False
    if archive_name not in names or metadata_name not in names:
        return False
    try:
        if remote_hash(config, archive_name, baseline["archiveSizeBytes"]) != baseline["archiveSha256"]:
            return False
        if remote_hash(config, metadata_name, baseline["manifestSizeBytes"]) != baseline["manifestSha256"]:
            return False
        remote_manifest = read_remote_manifest(config, metadata_name)
        if not isinstance(remote_manifest, dict) or not isinstance(remote_manifest.get("archive"), dict):
            return False
        return (
            remote_manifest.get("format") == PACKAGE_FORMAT
            and remote_manifest.get("deploymentId") == config["deploymentId"]
            and remote_manifest.get("archive", {}).get("name") == archive_name
            and remote_manifest.get("contentFingerprint") == baseline.get("fingerprint")
        )
    except (KeyError, BackupError):
        return False


def complete_remote_points(config, names):
    points = []
    prefix = f"recipe-db-{config['deploymentId']}-"
    for name in sorted(names):
        if not name.startswith(prefix) or not name.endswith(".manifest.json"):
            continue
        document = read_remote_manifest(config, name)
        if not isinstance(document, dict) or document.get("format") != PACKAGE_FORMAT \
                or document.get("formatVersion") != 1 or document.get("deploymentId") != config["deploymentId"]:
            continue
        archive = document.get("archive")
        if not isinstance(archive, dict) \
                or not isinstance(archive.get("name"), str) \
                or not REMOTE_FILENAME_PATTERN.fullmatch(archive["name"]) \
                or archive["name"] not in names \
                or not isinstance(archive.get("sha256"), str) or not HASH_PATTERN.fullmatch(archive["sha256"]) \
                or type(archive.get("sizeBytes")) is not int or archive["sizeBytes"] < 0:
            continue
        snapshot_manifest = document.get("snapshotManifest")
        backup_id = document.get("backupId")
        try:
            captured = validate_timestamp(document["capturedAt"])
            stamp = captured.strftime("%Y%m%dT%H%M%SZ")
        except (KeyError, ValueError):
            continue
        expected_prefix = f"recipe-db-{config['deploymentId']}-{stamp}-{backup_id}"
        source = document.get("source")
        if not isinstance(backup_id, str) or not BACKUP_ID_PATTERN.fullmatch(backup_id) \
                or name != expected_prefix + ".manifest.json" \
                or archive["name"] != expected_prefix + ".tar.gz" \
                or not isinstance(document.get("contentFingerprint"), str) \
                or not HASH_PATTERN.fullmatch(document["contentFingerprint"]) \
                or not isinstance(source, dict) \
                or not re.fullmatch(r"ghcr[.]io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}",
                                    str(source.get("artifact", ""))) \
                or not re.fullmatch(r"[0-9a-f]{40}", str(source.get("revision", ""))) \
                or not isinstance(snapshot_manifest, dict) \
                or snapshot_manifest.get("format") != FORMAT \
                or snapshot_manifest.get("formatVersion") != 1 \
                or snapshot_manifest.get("backupId") != backup_id \
                or snapshot_manifest.get("capturedAt") != document.get("capturedAt") \
                or not isinstance(snapshot_manifest.get("inventory"), list) \
                or not snapshot_manifest["inventory"] \
                or snapshot_manifest.get("source") != source:
            continue
        manifest_bytes = json_bytes(document)
        try:
            manifest_hash = remote_hash(config, name, len(manifest_bytes))
            archive_hash = remote_hash(config, archive["name"], archive["sizeBytes"])
        except BackupError as error:
            raise BackupError("retention-failure", "remote-point-integrity") from error
        if manifest_hash != hashlib.sha256(manifest_bytes).hexdigest() \
                or archive_hash != archive["sha256"]:
            raise BackupError("retention-failure", "remote-point-integrity")
        points.append((captured, backup_id, archive["name"], name))
    return points


def prune(config, names, current_archive, current_manifest):
    points = complete_remote_points(config, names)
    points.sort(key=lambda point: (point[0], point[1]))
    for _, _, archive, manifest in points[:-30]:
        document = read_remote_manifest(config, manifest)
        if not isinstance(document, dict) or not isinstance(document.get("archive"), dict):
            raise BackupError("retention-failure", "remote-point-metadata")
        archive_metadata = document["archive"]
        if remote_hash(config, archive, archive_metadata["sizeBytes"]) != archive_metadata["sha256"]:
            raise BackupError("retention-failure", "remote-point-integrity")
        manifest_bytes = json_bytes(document)
        if remote_hash(config, manifest, len(manifest_bytes)) != hashlib.sha256(manifest_bytes).hexdigest():
            raise BackupError("retention-failure", "remote-point-integrity")
        rclone(config, "deletefile", remote_base(config) + "/" + manifest)
        rclone(config, "deletefile", remote_base(config) + "/" + archive)


def baseline_path(config):
    return Path(config["stateDirectory"]) / "baseline.json"


def clear_stale_staging(stage_root):
    for path in Path(stage_root).glob("publish-*"):
        if path.is_symlink() or not path.is_dir():
            continue
        shutil.rmtree(path)


def reconcile_stale_captures(state):
    captures = ensure_private_dir(Path(state) / "staging")
    for path in captures.glob("capture-*"):
        if path.is_symlink() or not path.is_dir():
            continue
        recovery_state = path / "backup-state.json"
        if not (recovery_state.exists() or recovery_state.is_symlink()) \
                or not safely_recovered(lifecycle_state(path)):
            preserved = ensure_private_dir(Path(state) / f"recovery-{path.name}")
            shutil.move(str(path), str(preserved / path.name))
            raise BackupError("restart-failure", "recovery-required")
        shutil.rmtree(path)


def preserve_unresolved_capture(snapshot, state):
    recovery_root = ensure_private_dir(Path(state) / f"recovery-{snapshot.name}")
    shutil.move(str(snapshot), str(recovery_root / snapshot.name))


def has_unresolved_recovery(state):
    for path in Path(state).glob("recovery-*"):
        if path.is_symlink() or not path.is_dir():
            return True
        records = list(path.rglob("backup-state.json"))
        if not records or any(not safely_recovered(lifecycle_state(record.parent)) for record in records):
            return True
    return False


def terminate_capture_process_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 10
    while True:
        process.poll()
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            break
        if time.monotonic() >= deadline:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            break
        time.sleep(0.1)
    process.wait()


def upload_snapshot(snapshot, config):
    ensure_private_dir(config["stateDirectory"])
    stage_root = ensure_private_dir(config["stagingDirectory"])
    baseline_file = baseline_path(config)
    try:
        manifest = validate_snapshot(snapshot)
        fingerprint = content_fingerprint(manifest)
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        write_status(config, "capture-failure", "invalid-snapshot")
        raise BackupError("capture-failure", "invalid-snapshot") from error
    baseline = None
    if baseline_file.is_file() and not baseline_file.is_symlink():
        try:
            baseline = read_json(baseline_file)
        except (OSError, ValueError, json.JSONDecodeError):
            baseline = None
    if not isinstance(baseline, dict):
        baseline = None
    try:
        rclone(config, "mkdir", remote_base(config))
        names = remote_names(config)
        if baseline and baseline.get("fingerprint") == fingerprint and verify_baseline(config, baseline, names):
            value = write_status(config, "verified-unchanged", "content-unchanged",
                                 manifest["backupId"], baseline.get("lastUpload"))
            return value["status"]
        with tempfile.TemporaryDirectory(prefix="publish-", dir=stage_root) as temporary:
            package = create_package(snapshot, temporary, manifest, config["deploymentId"],
                                     config["maxStagingBytes"])
            if package["archive"] in names or package["manifest"] in names:
                raise BackupError("upload-failure", "remote-name-collision")
            remote = remote_base(config)
            rclone(config, "copyto", str(Path(temporary) / package["archive"]),
                   remote + "/" + package["archive"])
            if remote_hash(config, package["archive"], package["archiveSizeBytes"]) != package["archiveSha256"]:
                raise BackupError("upload-failure", "archive-integrity")
            rclone(config, "copyto", str(Path(temporary) / package["manifest"]),
                   remote + "/" + package["manifest"])
            manifest_size = (Path(temporary) / package["manifest"]).stat().st_size
            if remote_hash(config, package["manifest"], manifest_size) != package["manifestSha256"]:
                raise BackupError("upload-failure", "manifest-integrity")
            last_upload = datetime.now(timezone.utc).isoformat(timespec="seconds")
            new_baseline = {
                "fingerprint": package["fingerprint"],
                "backupId": package["backupId"],
                "archive": package["archive"],
                "manifest": package["manifest"],
                "archiveSizeBytes": package["archiveSizeBytes"],
                "manifestSizeBytes": manifest_size,
                "archiveSha256": package["archiveSha256"],
                "manifestSha256": package["manifestSha256"],
                "capturedAt": package["capturedAt"],
                "lastUpload": last_upload,
            }
            atomic_json(baseline_file, new_baseline)
        try:
            prune(config, names | {package["archive"], package["manifest"]},
                  package["archive"], package["manifest"])
        except (BackupError, OSError, TypeError, ValueError, KeyError) as error:
            code = error.code if isinstance(error, BackupError) else "retention-metadata"
            write_status(config, "retention-failure", code,
                         manifest["backupId"], last_upload)
            raise BackupError("retention-failure", code) from error
        write_status(config, "verified-upload", "remote-readback",
                     manifest["backupId"], last_upload)
        return "verified-upload"
    except BackupError as error:
        prior_upload = None
        if baseline_file.is_file() and not baseline_file.is_symlink():
            try:
                prior_upload = read_json(baseline_file).get("lastUpload")
            except (OSError, ValueError, json.JSONDecodeError):
                pass
        if error.status != "retention-failure":
            write_status(config, error.status, error.code, manifest.get("backupId"), prior_upload)
        raise


def run_nightly(config):
    state = ensure_private_dir(config["stateDirectory"])
    lock_path = state / "run.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        os.close(lock_fd)
        write_status(config, "interrupted", "already-running")
        raise BackupError("interrupted", "already-running") from error
    try:
        try:
            reconcile_stale_captures(state)
        except BackupError as error:
            write_status(config, error.status, error.code)
            raise
        if has_unresolved_recovery(state):
            write_status(config, "restart-failure", "recovery-required")
            raise BackupError("restart-failure", "recovery-required")
        clear_stale_staging(config["stagingDirectory"])
        capture = Path(config["captureCommand"])
        if capture.is_symlink() or not capture.is_file() or not os.access(capture, os.X_OK):
            write_status(config, "capture-failure", "capture-command-unavailable")
            raise BackupError("capture-failure", "capture-command-unavailable")
        snapshots = ensure_private_dir(state / "staging")
        snapshot = snapshots / f"capture-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{os.getpid()}"
        try:
            process = subprocess.Popen(
                [str(capture), str(snapshot)], stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                env={
                    "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                    "KUBECONFIG": os.environ.get(
                        "KUBECONFIG", "/etc/recipe-db/backup-kubeconfig.yaml",
                    ),
                    "RECIPE_DB_BACKUP_MAX_SNAPSHOT_BYTES": str(
                        config["maxStagingBytes"] // 2,
                    ),
                },
                start_new_session=True,
            )
            try:
                result = process.wait(timeout=config["captureTimeoutSeconds"])
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                terminate_capture_process_group(process)
                raise
            if result:
                recovery_state = snapshot / "backup-state.json"
                if (recovery_state.exists() or recovery_state.is_symlink()) \
                        and not safely_recovered(lifecycle_state(snapshot)):
                    preserve_unresolved_capture(snapshot, state)
                    status = "restart-failure"
                else:
                    status = "capture-failure"
                write_status(config, status, "capture-command-failed")
                raise BackupError(status, "capture-command-failed")
            status = upload_snapshot(snapshot, config)
            shutil.rmtree(snapshot)
            return status
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            recovery_state = snapshot / "backup-state.json"
            if snapshot.exists() and (recovery_state.exists() or recovery_state.is_symlink()) \
                    and not safely_recovered(lifecycle_state(snapshot)):
                preserve_unresolved_capture(snapshot, state)
                write_status(config, "restart-failure", "recovery-required")
                raise BackupError("restart-failure", "recovery-required") from error
            write_status(config, "interrupted", "capture-interrupted")
            raise BackupError("interrupted", "capture-interrupted") from error
        finally:
            if snapshot.exists():
                shutil.rmtree(snapshot, ignore_errors=True)
    except KeyboardInterrupt as error:
        write_status(config, "interrupted", "process-interrupted")
        raise BackupError("interrupted", "process-interrupted") from error
    except (OSError, TypeError, ValueError) as error:
        write_status(config, "capture-failure", "local-operation")
        raise BackupError("capture-failure", "local-operation") from error
    finally:
        os.close(lock_fd)


def report_status(config):
    path = status_path(config)
    try:
        value = read_json(path)
    except (OSError, ValueError, json.JSONDecodeError):
        return {"format": STATUS_FORMAT, "status": "overdue", "code": "no-check-record",
                "lastCheck": None, "lastUpload": None, "backupId": None}
    if not value.get("lastCheck"):
        value["status"] = "overdue"
        value["code"] = "no-check-record"
    else:
        try:
            if datetime.now(timezone.utc) - validate_timestamp(value["lastCheck"]) > timedelta(hours=26):
                value["status"] = "overdue"
                value["code"] = "check-overdue"
        except ValueError:
            value["status"] = "capture-failure"
            value["code"] = "invalid-status-record"
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("nightly", "status"))
    parser.add_argument("--config", required=True)
    args = parser.parse_args()
    config = safe_config(args.config)
    def interrupt(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    ensure_private_dir(config["stateDirectory"])
    ensure_private_dir(config["stagingDirectory"])
    if args.action == "status":
        print(json.dumps(report_status(config), sort_keys=True))
        return 0
    run_nightly(config)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BackupError as error:
        print(f"backup: {error.status} ({error.code})", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        print("backup: operation failed (configuration-or-filesystem)", file=sys.stderr)
        sys.exit(1)
