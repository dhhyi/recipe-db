#!/usr/bin/env python3
"""Validate a selected local backup pair before privately staging its snapshot."""

import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import tarfile


ROOT = Path(__file__).resolve().parent.parent


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


upload = load_module("backup_upload", ROOT / "provisioning/files/backup-upload.py")
snapshot = load_module("backup_snapshot", ROOT / ".scripts/validate-backup-snapshot.py")
MAX_BYTES = upload.DEFAULT_MAX_STAGING_BYTES
MAX_METADATA = upload.MAX_MANIFEST_BYTES
MAX_FILES = 100_000
MAX_SERVICES = 256
DATA_ROLES = {"authoritative-read-only", "cleanup-participant"}
OTHER_ROLES = {"derived-stateless", "excluded-external-cache"}


def private_file(value, limit):
    path = upload.absolute_path(value)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 \
            or info.st_uid != os.geteuid() or info.st_nlink != 1 or info.st_size > limit:
        raise ValueError("input must be a bounded private regular file")
    return path


def parse_json(content):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result
    return json.loads(content, object_pairs_hook=unique_object)


def read_json(path):
    return parse_json(path.read_bytes())


def projects_from(path):
    projects = {}
    for line in path.read_text().splitlines():
        item = parse_json(line)
        name, role, category = item.get("name"), item.get("backupRole"), item.get("category")
        if not isinstance(name, str) or not upload.NAME_PATTERN.fullmatch(name) \
                or name in projects or len(projects) >= MAX_SERVICES \
                or category not in ("api", "backend", "frontend"):
            raise ValueError("invalid or duplicate project classification")
        if category == "frontend":
            projects[name] = (None, None)
            continue
        if role not in DATA_ROLES | OTHER_ROLES:
            raise ValueError("unclassified API or backend project")
        layout = item.get("backupData")
        if role in DATA_ROLES:
            if not isinstance(layout, dict) or layout.get("kind") not in ("sqlite", "json", "images"):
                raise ValueError("missing authoritative project layout")
            if layout["kind"] != "images" and (not isinstance(layout.get("file"), str)
                    or not upload.NAME_PATTERN.fullmatch(layout["file"])):
                raise ValueError("invalid authoritative database filename")
        projects[name] = (role, layout)
    expected = {name: value for name, value in projects.items() if value[0] in DATA_ROLES}
    if sum(role == "authoritative-read-only" for role, _ in expected.values()) != 1 \
            or not any(role == "cleanup-participant" for role, _ in expected.values()):
        raise ValueError("requires one authoritative source and cleanup participants")
    return expected


def check_manifest(package, archive, backup_id, projects):
    if not isinstance(package, dict) or package.get("format") != upload.PACKAGE_FORMAT \
            or type(package.get("formatVersion")) is not int or package["formatVersion"] != 1:
        raise ValueError("unsupported package format")
    if not upload.BACKUP_ID_PATTERN.fullmatch(backup_id) or package.get("backupId") != backup_id:
        raise ValueError("backup identity mismatch")
    deployment = package.get("deploymentId")
    if not isinstance(deployment, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", deployment):
        raise ValueError("invalid deployment identity")
    captured = upload.validate_timestamp(package.get("capturedAt"))
    name = f"recipe-db-{deployment}-{captured.strftime('%Y%m%dT%H%M%SZ')}-{backup_id}.tar.gz"
    identity = package.get("archive")
    if not isinstance(identity, dict) or identity.get("name") != name or archive.name != name:
        raise ValueError("archive name mismatch")
    size, digest = identity.get("sizeBytes"), identity.get("sha256")
    if type(size) is not int or not 0 < size <= MAX_BYTES or size != archive.stat().st_size \
            or not isinstance(digest, str) or not upload.HASH_PATTERN.fullmatch(digest) \
            or upload.file_hash(archive) != digest:
        raise ValueError("archive size or checksum mismatch")
    manifest = package.get("snapshotManifest")
    if not isinstance(manifest, dict) or manifest.get("format") != upload.FORMAT \
            or type(manifest.get("formatVersion")) is not int or manifest["formatVersion"] != 1 \
            or manifest.get("backupId") != backup_id \
            or manifest.get("source") != package.get("source") \
            or manifest.get("capturedAt") != package.get("capturedAt"):
        raise ValueError("embedded snapshot identity mismatch")
    source = manifest.get("source")
    if not isinstance(source, dict) or not all(isinstance(source.get(key), str) and source[key]
            for key in ("target", "cluster", "context", "namespace", "artifact", "revision")) \
            or source["target"] not in ("local", "pi") \
            or not re.fullmatch(r"ghcr[.]io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}", source["artifact"]) \
            or not re.fullmatch(r"[0-9a-f]{40}", source["revision"]):
        raise ValueError("invalid release identity")
    inventory = manifest.get("inventory")
    if not isinstance(inventory, list) or not 0 < len(inventory) <= MAX_SERVICES:
        raise ValueError("invalid snapshot inventory")
    expected = {"manifest.json": None}
    services, claims = set(), set()
    total_files = 0
    for item in inventory:
        service, role, claim = item["service"], item["role"], item["pvc"]
        if service not in projects or service in services or role != projects[service][0] \
                or claim != service or claim in claims:
            raise ValueError("snapshot dataset classification mismatch")
        services.add(service)
        claims.add(claim)
        name, size = item["archive"], item["sizeBytes"]
        if name != service + ".tar" \
                or name in expected or type(size) is not int or not 0 < size <= MAX_BYTES:
            raise ValueError("invalid snapshot archive")
        files = item["files"]
        if not isinstance(files, list) or type(item["fileCount"]) is not int or len(files) != item["fileCount"]:
            raise ValueError("invalid file inventory")
        total_files += len(files)
        if total_files > MAX_FILES:
            raise ValueError("too many snapshot files")
        expected[name] = size
    if services != set(projects):
        raise ValueError("incomplete authoritative dataset")
    if upload.content_fingerprint(manifest) != package.get("contentFingerprint"):
        raise ValueError("content fingerprint mismatch")
    if sum(size or 0 for size in expected.values()) + archive.stat().st_size + MAX_METADATA > MAX_BYTES:
        raise ValueError("staging limit exceeded")
    return manifest, expected


class BoundedReader:
    def __init__(self, source, limit):
        self.source, self.remaining = source, limit

    def read(self, size=-1):
        if size < 0 or size > MAX_METADATA:
            raise ValueError("unbounded archive read")
        data = self.source.read(size)
        self.remaining -= len(data)
        if self.remaining < 0:
            raise ValueError("expanded archive limit exceeded")
        return data


def bundle_pass(archive, manifest, expected, output=None):
    seen = set()
    limit = sum(size or 0 for size in expected.values()) + MAX_METADATA + 1024 * len(expected) + 1024 * 1024
    with gzip.open(archive, "rb") as compressed:
        bounded = BoundedReader(compressed, limit)
        with tarfile.open(fileobj=bounded, mode="r|") as bundle:
            for member in bundle:
                name = member.name
                if not member.isreg() or member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE) \
                        or member.pax_headers or member.mode & 0o7000 \
                        or name not in expected or name in seen:
                    raise ValueError("unsafe, duplicate or unexpected package member")
                seen.add(name)
                size = expected[name]
                if (size is not None and member.size != size) \
                        or (size is None and not 0 <= member.size <= MAX_METADATA):
                    raise ValueError("package member size mismatch")
                stream = bundle.extractfile(member)
                if name == "manifest.json":
                    content = stream.read(MAX_METADATA + 1)
                    if len(content) != member.size or parse_json(content) != manifest:
                        raise ValueError("embedded snapshot manifest differs")
                elif output is not None:
                    descriptor = os.open(output / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                    with os.fdopen(descriptor, "wb") as destination:
                        remaining = member.size
                        while remaining:
                            block = stream.read(min(1024 * 1024, remaining))
                            if not block:
                                raise ValueError("truncated package member")
                            destination.write(block)
                            remaining -= len(block)
                else:
                    while stream.read(1024 * 1024):
                        pass
            while block := bundle.fileobj.read(1024 * 1024):
                if block.strip(b"\x00"):
                    raise ValueError("unexpected trailing package data")
        while block := bounded.read(1024 * 1024):
            if block.strip(b"\x00"):
                raise ValueError("unexpected trailing package data")
    if seen != set(expected):
        raise ValueError("incomplete package")


def check_inner_bounds(archive):
    names = set()
    total = json_total = 0
    with open(archive, "rb") as raw, tarfile.open(
            fileobj=BoundedReader(raw, archive.stat().st_size), mode="r|") as source:
        for member in source:
            name = member.name.removeprefix("./")
            if name in ("", "."):
                name = "."
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name \
                    or (name not in ("", ".") and str(path) != name) or name in names \
                    or len(names) >= MAX_FILES + 3 or member.pax_headers \
                    or member.mode & 0o7000 \
                    or not 0 <= member.uid < 2**32 - 1 or not 0 <= member.gid < 2**32 - 1:
                raise ValueError("unsafe or duplicate snapshot path")
            names.add(name)
            if member.isdir():
                if name not in ("", ".", "public", "manifests"):
                    raise ValueError("unexpected snapshot directory")
            elif member.isreg() and member.type in (tarfile.REGTYPE, tarfile.AREGTYPE):
                total += member.size
                if name.endswith(".json"):
                    json_total += member.size
                if total > MAX_BYTES or member.size < 0 \
                        or json_total > MAX_METADATA:
                    raise ValueError("snapshot content limit exceeded")
            else:
                raise ValueError("unsafe snapshot member")
        while block := source.fileobj.read(1024 * 1024):
            if block.strip(b"\x00"):
                raise ValueError("unexpected trailing snapshot data")


def validate(package_path, archive_path, output_path, projects_path, backup_id):
    package_path = private_file(package_path, MAX_METADATA)
    archive = private_file(archive_path, MAX_BYTES)
    projects_path = private_file(projects_path, MAX_METADATA)
    output = upload.absolute_path(output_path)
    parent = output.parent.stat()
    if os.path.lexists(output) or not stat.S_ISDIR(parent.st_mode) or parent.st_mode & 0o077 \
            or parent.st_uid != os.geteuid():
        raise ValueError("output must be new inside a private directory")
    package = read_json(package_path)
    projects = projects_from(projects_path)
    manifest, expected = check_manifest(package, archive, backup_id, projects)
    if package_path.name != archive.name.removesuffix(".tar.gz") + ".manifest.json":
        raise ValueError("package manifest name mismatch")
    bundle_pass(archive, manifest, expected)
    required = sum(size or 0 for size in expected.values()) + MAX_METADATA
    if shutil.disk_usage(output.parent).free < required:
        raise ValueError("insufficient staging space")
    output.mkdir(mode=0o700)
    try:
        bundle_pass(archive, manifest, expected, output)
        descriptor = os.open(output / "manifest.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as destination:
            destination.write(upload.json_bytes(manifest))
        for item in manifest["inventory"]:
            check_inner_bounds(output / item["archive"])
        validated = upload.validate_snapshot(output)
        for item in validated["inventory"]:
            observed = snapshot.validate(output / item["archive"], projects[item["service"]][1])
            if observed != item["files"]:
                raise ValueError("authoritative file inventory mismatch")
        return validated
    except BaseException:
        shutil.rmtree(output)
        raise


def main():
    if len(sys.argv) != 6:
        raise ValueError("usage: validate-backup-package.py ABS_PACKAGE_MANIFEST ABS_ARCHIVE ABS_NEW_OUTPUT_DIR ABS_PROJECTS_JSONL EXPECTED_BACKUP_ID")
    print(json.dumps(validate(*sys.argv[1:]), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, AttributeError, OSError, EOFError, tarfile.TarError) as error:
        print(f"production: backup package validation failed: {error}", file=sys.stderr)
        sys.exit(1)
