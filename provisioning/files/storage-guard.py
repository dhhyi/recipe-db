#!/usr/bin/python3
"""Verify the provisioned USB root identity before k3s can start."""

import json
from pathlib import Path
import re
import subprocess
import sys


def validate_identity(expected_uuid, root, mounts, devices):
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", expected_uuid):
        raise ValueError("expected_root_uuid must be an explicit filesystem UUID")
    if not re.fullmatch(r"/srv/[a-zA-Z0-9_-]+", root):
        raise ValueError("data_root must be one direct directory beneath /srv")
    if len(mounts) != 5:
        raise ValueError("root and all four runtime paths must be checked")
    for mount in mounts:
        if mount.get("uuid", "").lower() != expected_uuid.lower() or mount.get("fstype") != "ext4":
            raise ValueError("root/runtime paths do not resolve to the expected ext4 filesystem")
    root_source = mounts[0]["source"].removeprefix("/dev/")
    candidates = []
    for disk in devices:
        for partition in disk.get("children", []):
            if partition.get("name") == root_source:
                candidates.append(disk)
    if len(candidates) != 1 or candidates[0].get("tran") != "usb":
        raise ValueError("root must be a partition on one identified USB device")


def inspect(expected_uuid, root, allow_missing=False):
    paths = ["/", root, root + "/k3s", root + "/storage", root + "/kubelet"]
    mounts = []
    for path in paths:
        if not allow_missing and not Path(path).is_dir():
            raise ValueError(f"required runtime directory is missing: {path}")
        if path != "/" and Path(path).exists() and Path(path).resolve() != Path(path):
            raise ValueError("runtime paths must not be symbolic links")
        # During initial preflight the directories need not exist yet.
        target = Path(path)
        while not target.exists():
            target = target.parent
        result = subprocess.run(
            ["findmnt", "--json", "--target", str(target), "--output", "SOURCE,FSTYPE,UUID"],
            check=True, capture_output=True, text=True,
        )
        entries = json.loads(result.stdout)["filesystems"]
        if len(entries) != 1:
            raise ValueError("ambiguous filesystem identity")
        mounts.append(entries[0])
    devices = json.loads(subprocess.run(
        ["lsblk", "--json", "--output", "NAME,TRAN"], check=True,
        capture_output=True, text=True,
    ).stdout)["blockdevices"]
    validate_identity(expected_uuid, root, mounts, devices)


def main():
    if len(sys.argv) not in (3, 4) or (len(sys.argv) == 4 and sys.argv[3] != "--preflight"):
        raise ValueError("usage: storage-guard EXPECTED_ROOT_UUID DATA_ROOT [--preflight]")
    inspect(sys.argv[1], sys.argv[2], allow_missing=len(sys.argv) == 4)
    print("Verified USB-backed ext4 root and runtime storage identity")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"recipe-db storage guard failed: {error}", file=sys.stderr)
        sys.exit(1)
