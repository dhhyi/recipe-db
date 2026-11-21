#!/usr/bin/env python3
"""Inventory one read-only PVC archive without interpreting its contents."""

import hashlib
import json
from pathlib import PurePosixPath
import re
import sys
import tarfile

MAX_FILES = 100_000
MAX_DIRECTORIES = 100_000


def validate(archive, require_storage_version=False, include_directories=False):
    members = set()
    files = set()
    inventory = []
    directories = []
    directory_metadata = []
    materialized_directories = set()
    storage_version = None
    with tarfile.open(archive, "r:") as source:
        for member in source:
            name = member.name.removeprefix("./")
            if not name or name.startswith("/") or member.pax_headers or member.mode & 0o7000 \
                    or not 0 <= member.uid < 2**32 - 1 or not 0 <= member.gid < 2**32 - 1:
                raise ValueError("unsafe archive metadata")
            if member.isdir():
                name = name.rstrip("/")
                if name in ("", "."):
                    name = "."
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name or str(path) != name \
                    or (member.isfile() and name == "."):
                raise ValueError("unsafe archive path")
            if name in members:
                raise ValueError("archive contains a duplicate path")
            members.add(name)
            for parent in path.parents:
                if str(parent) != ".":
                    if str(parent) in files:
                        raise ValueError("archive file is a parent directory")
                    materialized_directories.add(str(parent))
                    if len(materialized_directories) > MAX_DIRECTORIES:
                        raise ValueError("too many archive directories")
            if member.isdir():
                directory_metadata.append({"path": name, "mode": member.mode,
                                           "uid": member.uid, "gid": member.gid})
                if name == ".":
                    continue
                materialized_directories.add(name)
                if len(materialized_directories) > MAX_DIRECTORIES:
                    raise ValueError("too many archive directories")
                directories.append(name)
                continue
            if not member.isfile() or member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE):
                raise ValueError("archive contains a link or special file")
            if name in materialized_directories:
                raise ValueError("archive file is a parent directory")
            if len(inventory) >= MAX_FILES:
                raise ValueError("too many archive files")
            files.add(name)
            if name == "storage-version" and member.size > 64:
                raise ValueError("malformed storage-version marker")
            stream = source.extractfile(member)
            if stream is None:
                raise ValueError("archive file is unreadable")
            digest = hashlib.sha256()
            marker = bytearray()
            size = 0
            while block := stream.read(1024 * 1024):
                digest.update(block)
                size += len(block)
                if name == "storage-version":
                    marker.extend(block)
            entry = {"path": name, "sizeBytes": size, "sha256": digest.hexdigest()}
            if name == "storage-version":
                if not re.fullmatch(rb"[1-9][0-9]*\n", marker):
                    raise ValueError("malformed storage-version marker")
                storage_version = int(marker.strip())
                entry["storageVersion"] = storage_version
            inventory.append(entry)
    if require_storage_version and storage_version is None:
        raise ValueError("missing storage-version marker")
    inventory = sorted(inventory, key=lambda item: item["path"])
    if include_directories:
        return {"files": inventory, "directories": sorted(directories),
                "directoryMetadata": sorted(directory_metadata, key=lambda item: item["path"])}
    return inventory


def main():
    require_storage_version = False
    arguments = sys.argv[1:]
    if "--require-storage-version" in arguments:
        arguments.remove("--require-storage-version")
        require_storage_version = True
    include_directories = "--include-directories" in arguments
    if include_directories:
        arguments.remove("--include-directories")
    if len(arguments) != 1:
        raise ValueError("usage: validate-backup-snapshot.py [--require-storage-version] [--include-directories] ARCHIVE")
    print(json.dumps(validate(arguments[0], require_storage_version, include_directories)))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, tarfile.TarError) as error:
        print(f"production: snapshot validation failed: {error}", file=sys.stderr)
        sys.exit(1)
