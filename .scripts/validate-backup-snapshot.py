#!/usr/bin/env python3
"""Inventory one read-only PVC archive without interpreting its contents."""

import hashlib
import json
from pathlib import PurePosixPath
import re
import sys
import tarfile


def validate(archive, require_storage_version=False):
    members = set()
    inventory = []
    storage_version = None
    with tarfile.open(archive, "r:") as source:
        for member in source:
            name = member.name.removeprefix("./")
            if member.isdir():
                name = name.rstrip("/")
                if name in ("", "."):
                    continue
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name or str(path) != name \
                    or (member.isfile() and name == "."):
                raise ValueError("unsafe archive path")
            if name in members:
                raise ValueError("archive contains a duplicate path")
            members.add(name)
            if member.isdir():
                continue
            if not member.isfile() or member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE):
                raise ValueError("archive contains a link or special file")
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
    return sorted(inventory, key=lambda item: item["path"])


def main():
    require_storage_version = False
    arguments = sys.argv[1:]
    if "--require-storage-version" in arguments:
        arguments.remove("--require-storage-version")
        require_storage_version = True
    if len(arguments) != 1:
        raise ValueError("usage: validate-backup-snapshot.py [--require-storage-version] ARCHIVE")
    print(json.dumps(validate(arguments[0], require_storage_version)))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, tarfile.TarError) as error:
        print(f"production: snapshot validation failed: {error}", file=sys.stderr)
        sys.exit(1)
