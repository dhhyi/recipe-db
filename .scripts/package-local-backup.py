#!/usr/bin/env python3
"""Package a locally captured snapshot without contacting a remote backup store."""

import importlib.util
import os
from pathlib import Path
import stat
import sys


ROOT = Path(__file__).resolve().parent.parent
UPLOAD_PATH = ROOT / "provisioning/files/backup-upload.py"
SPEC = importlib.util.spec_from_file_location("backup_upload", UPLOAD_PATH)
UPLOAD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPLOAD)


def private_directory(path, *, create=False):
    path = Path(path)
    if path.is_symlink() or not path.is_absolute():
        raise ValueError("directory must be an absolute non-symlink path")
    if create:
        path.mkdir(mode=0o700)
    resolved = path.resolve(strict=True)
    info = resolved.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError("directory must be private and owned by the current operator")
    return resolved


def package(snapshot, output, max_staging_bytes=UPLOAD.DEFAULT_MAX_STAGING_BYTES):
    max_staging_bytes = UPLOAD.validate_max_staging_bytes(max_staging_bytes)
    snapshot = private_directory(snapshot)
    output_parent = private_directory(Path(output).parent)
    output = output_parent / Path(output).name
    if os.path.lexists(output):
        raise ValueError("package output must be new")
    manifest = UPLOAD.validate_snapshot(snapshot)
    private_directory(output, create=True)
    return UPLOAD.create_package(
        snapshot, output, manifest, "recipe-db-cutover-local", max_staging_bytes
    )


if __name__ == "__main__":
    try:
        if len(sys.argv) not in (3, 4):
            raise ValueError("usage: package-local-backup.py ABS_SNAPSHOT_DIR ABS_NEW_PACKAGE_DIR [MAX_STAGING_BYTES]")
        import json
        max_staging_bytes = int(sys.argv[3]) if len(sys.argv) == 4 else UPLOAD.DEFAULT_MAX_STAGING_BYTES
        print(json.dumps(package(sys.argv[1], sys.argv[2], max_staging_bytes), sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError, UPLOAD.BackupError) as error:
        print(f"production: local backup packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
