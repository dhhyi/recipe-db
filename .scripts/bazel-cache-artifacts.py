#!/usr/bin/env python3
"""Select, validate, and stage bounded Bazel disk-cache workflow artifacts."""

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import resource
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parent.parent
FORMAT = "recipe-db-bazel-disk-cache"
FORMAT_VERSION = 2
WORKFLOW = ".github/workflows/publish.yaml"
JOB = "quality-checks"
UPLOAD_STEP = "upload Bazel cache snapshot"
ARTIFACT_PREFIX = "bazel-cache-v2"
TRUSTED_COPILOT_ACTOR = (198982749, "Copilot", "Bot")
MAIN_ARTIFACT_PATTERN = re.compile(r"bazel-cache-v2-main-r([1-9]\d*)-a([1-9]\d*)")
PR_ARTIFACT_PATTERN = re.compile(r"bazel-cache-v2-pr-([1-9]\d*)-r([1-9]\d*)-a([1-9]\d*)")
LEGACY_MAIN_ARTIFACT_PATTERN = re.compile(r"bazel-cache-v1-main-r([1-9]\d*)-a([1-9]\d*)")
LEGACY_PR_ARTIFACT_PATTERN = re.compile(r"bazel-cache-v1-pr-([1-9]\d*)-r([1-9]\d*)-a([1-9]\d*)")
MAIN_ARTIFACT_RETENTION = 5
MAX_ARCHIVE_BYTES = 8 * 1024**3
MAX_EXPANDED_BYTES = 12 * 1024**3
MAX_FILES = 500_000
MAX_FILE_BYTES = 2 * 1024**3
MAX_METADATA_BYTES = 1024**2
WORKFLOW_RUNS_PAGE_SIZE = 20
MAX_ACTION_RESULT_BYTES = 64 * 1024**2
MAX_TREE_EXPANDED_BYTES = 64 * 1024**2
MAX_ACTION_LOG_RECORD_BYTES = 16 * 1024**2
MAX_ACTION_LOG_CHUNK_BYTES = 64 * 1024
API_READ_ATTEMPTS = 3
EMPTY_DIGEST = hashlib.sha256(b"").hexdigest()


class Invalid(ValueError):
    pass


class ApiFailure(RuntimeError):
    pass


def parse_json(data):
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise Invalid("duplicate JSON key")
            result[key] = value
        return result

    return json.loads(data, object_pairs_hook=unique_object)


def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        if offset == len(data):
            raise Invalid("truncated protobuf varint")
        byte = data[offset]
        offset += 1
        if shift == 63 and byte > 1:
            raise Invalid("overflowing protobuf varint")
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise Invalid("invalid protobuf varint")


def fields(data):
    result = {}
    offset = 0
    while offset < len(data):
        tag, offset = varint(data, offset)
        number, wire = tag >> 3, tag & 7
        if not 0 < number < 2**29:
            raise Invalid("invalid protobuf field number")
        if wire == 0:
            value, offset = varint(data, offset)
        elif wire in (1, 2, 5):
            size, offset = varint(data, offset) if wire == 2 else (8 if wire == 1 else 4, offset)
            end = offset + size
            if end > len(data):
                raise Invalid("truncated protobuf field")
            value, offset = data[offset:end], end
        else:
            raise Invalid("unsupported protobuf wire type")
        result.setdefault(number, []).append((wire, value))
    return result


def one(message, number, wire, default=None):
    values = message.get(number, [])
    if not values:
        return default
    if len(values) != 1 or values[0][0] != wire:
        raise Invalid(f"malformed protobuf field {number}")
    return values[0][1]


def text(value):
    try:
        return value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Invalid("invalid UTF-8 in cache metadata") from error


def safe_relative_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or str(path) != value \
            or any(part in ("", ".", "..") for part in value.split("/")) \
            or "\\" in value or "\x00" in value:
        raise Invalid("unsafe cache output path")
    return path


def safe_symlink_target(path, target):
    if not target or target.startswith("/") or "\\" in target or "\x00" in target:
        raise Invalid("unsafe cache output symlink")
    parts = list(path.parent.parts)
    for part in target.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                raise Invalid("escaping cache output symlink")
            parts.pop()
        else:
            parts.append(part)


def validate_symlink_graph(symlinks):
    resolved = {}

    def follow(parts, active):
        current = []
        for part in parts:
            if part in ("", "."):
                continue
            if part == "..":
                if not current:
                    raise Invalid("escaping output symlink graph")
                current.pop()
                continue
            current.append(part)
            candidate = "/".join(current)
            if candidate in symlinks:
                current = list(resolve(candidate, active))
        return tuple(current)

    def resolve(path, active):
        if path in active:
            raise Invalid("cyclic output symlink")
        if path in resolved:
            return resolved[path]
        if len(active) >= 256:
            raise Invalid("output symlink graph exceeds depth limit")
        active = active | {path}
        parent = PurePosixPath(path).parent.parts
        resolved[path] = follow((*parent, *symlinks[path].split("/")), active)
        return resolved[path]

    for path in symlinks:
        resolve(path, frozenset())


def read_digest(data):
    message = fields(data)
    if set(message) - {1, 2}:
        raise Invalid("unsupported Digest fields")
    digest = text(one(message, 1, 2, b""))
    size = one(message, 2, 0, 0)
    if not re.fullmatch(r"[0-9a-f]{64}", digest) or size >= 2**63:
        raise Invalid("malformed SHA-256 Digest")
    return digest, size


def cache_files(root):
    if root.is_symlink() or not root.is_dir():
        raise Invalid(f"not a cache directory: {root}")
    count = 0
    total = 0
    files = {"ac": {}, "cas": {}}
    directories = set()

    def failed(error):
        raise Invalid(f"cannot enumerate cache: {error}")

    for directory, dirs, names in os.walk(root, followlinks=False, onerror=failed):
        for name in dirs + names:
            count += 1
            if count > MAX_FILES:
                raise Invalid("cache snapshot exceeds file-count limit")
            path = Path(directory) / name
            relative = path.relative_to(root).parts
            if path.is_symlink():
                raise Invalid(f"cache contains a symlink: {path}")
            if relative[0] == "tmp":
                if len(relative) == 1 and not path.is_dir():
                    raise Invalid("invalid temporary cache layout")
                if not (path.is_dir() or path.is_file()):
                    raise Invalid("invalid temporary cache entry")
                continue
            if relative[0] not in files:
                raise Invalid(f"unsupported cache layout: {path}")
            if len(relative) == 1 and path.is_dir():
                directories.add("/".join(relative))
                continue
            if len(relative) == 2 and path.is_dir() \
                    and re.fullmatch(r"[0-9a-f]{2}", relative[1]):
                directories.add("/".join(relative))
                continue
            if len(relative) != 3 or not path.is_file() \
                    or not re.fullmatch(r"[0-9a-f]{64}", relative[2]) \
                    or relative[1] != relative[2][:2]:
                raise Invalid(f"unsupported digest cache path: {path}")
            info = path.stat(follow_symlinks=False)
            total += info.st_size
            if total > MAX_EXPANDED_BYTES or info.st_size > MAX_FILE_BYTES:
                raise Invalid("cache snapshot exceeds file or expansion limits")
            digest = relative[2]
            if relative[0] == "cas":
                hasher = hashlib.sha256()
                with path.open("rb") as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        hasher.update(block)
                if hasher.hexdigest() != digest:
                    raise Invalid(f"CAS digest mismatch: {path}")
            files[relative[0]][digest] = (path, info.st_size)
    if not files["ac"] and not files["cas"]:
        return files
    if not files["ac"]:
        raise Invalid("snapshot contains no action results")
    validate_action_results(files)
    return files


def referenced_blob(files, digest, size):
    if size == 0 and digest == EMPTY_DIGEST:
        return
    blob = files["cas"].get(digest)
    if blob is None or blob[1] != size:
        raise Invalid(f"missing or wrong-size referenced blob {digest}")


def validate_tree(files, digest, size, output_path, seen, symlinks, budget, depth=0):
    if depth > 256:
        raise Invalid("cache output tree exceeds depth limit")
    referenced_blob(files, digest, size)
    blob = files["cas"].get(digest)
    if blob is None:
        raise Invalid("empty tree blob is not valid")
    if blob[1] > MAX_ACTION_RESULT_BYTES:
        raise Invalid("Tree exceeds metadata limit")
    budget["bytes"] += blob[1]
    if budget["bytes"] > MAX_TREE_EXPANDED_BYTES:
        raise Invalid("cache output tree exceeds expanded-byte limit")
    tree = fields(blob[0].read_bytes())
    if set(tree) - {1, 2}:
        raise Invalid("unsupported Tree fields")
    root = one(tree, 1, 2)
    if root is None:
        raise Invalid("Tree lacks a root directory")
    directory_map = {}
    for wire, directory in tree.get(2, []):
        if wire != 2:
            raise Invalid("malformed Tree child")
        if len(directory) > MAX_ACTION_RESULT_BYTES:
            raise Invalid("Tree child exceeds metadata limit")
        child_digest = hashlib.sha256(directory).hexdigest()
        if child_digest in directory_map:
            raise Invalid("duplicate Tree child directory")
        directory_map[child_digest] = directory
    root_digest = hashlib.sha256(root).hexdigest()
    visited = set()
    validate_directory(files, fields(root), output_path, seen, depth, directory_map,
                       visited, {root_digest}, symlinks, budget, len(root))
    if visited != set(directory_map):
        raise Invalid("Tree contains an unreferenced child directory")


def validate_directory(files, directory, output_path, seen, depth, directory_map,
                       visited=None, active=None, symlinks=None, budget=None,
                       directory_size=0):
    if depth > 256:
        raise Invalid("cache output tree exceeds depth limit")
    visited = visited if visited is not None else set()
    active = active if active is not None else set()
    symlinks = symlinks if symlinks is not None else {}
    budget = budget if budget is not None else {"nodes": 0, "bytes": 0}
    budget["bytes"] += directory_size
    if budget["bytes"] > MAX_TREE_EXPANDED_BYTES:
        raise Invalid("cache output tree exceeds expanded-byte limit")
    if set(directory) - {1, 2, 3, 5}:
        raise Invalid("unsupported Directory fields")
    if 5 in directory:
        fields(one(directory, 5, 2))
    for field, kind in ((1, "file"), (2, "directory"), (3, "symlink")):
        for wire, content in directory.get(field, []):
            if wire != 2:
                raise Invalid("malformed output tree node")
            item = fields(content)
            name = text(one(item, 1, 2, b""))
            if not name or "/" in name or "\\" in name:
                raise Invalid("invalid output tree node name")
            path = safe_relative_path(f"{output_path}/{name}" if output_path else name)
            key = str(path)
            if key in seen:
                raise Invalid("duplicate output tree path")
            budget["nodes"] += 1
            budget["bytes"] += len(key.encode("utf-8"))
            if budget["nodes"] > MAX_FILES:
                raise Invalid("cache output tree exceeds expanded-node limit")
            if budget["bytes"] > MAX_TREE_EXPANDED_BYTES:
                raise Invalid("cache output tree exceeds expanded-byte limit")
            seen.add(key)
            if kind == "file":
                if set(item) - {1, 2, 4, 6}:
                    raise Invalid("unsupported output file fields")
                executable = one(item, 4, 0, 0)
                if executable not in (0, 1):
                    raise Invalid("invalid output executable bit")
                digest_data = one(item, 2, 2)
                if digest_data is None:
                    raise Invalid("output tree file lacks a digest")
                referenced_blob(files, *read_digest(digest_data))
                if 6 in item:
                    fields(one(item, 6, 2))
            elif kind == "directory":
                if set(item) - {1, 2}:
                    raise Invalid("unsupported output directory fields")
                digest_data = one(item, 2, 2)
                if digest_data is None:
                    raise Invalid("output directory lacks a digest")
                digest, size = read_digest(digest_data)
                raw = directory_map.get(digest)
                if raw is None:
                    raise Invalid(f"missing output directory in Tree {digest}")
                if len(raw) != size or hashlib.sha256(raw).hexdigest() != digest:
                    raise Invalid("output directory digest mismatch")
                if len(raw) > MAX_ACTION_RESULT_BYTES:
                    raise Invalid("output directory exceeds metadata limit")
                if digest in active:
                    raise Invalid("cyclic output directory tree")
                visited.add(digest)
                validate_directory(files, fields(raw), key, seen, depth + 1, directory_map,
                                   visited, active | {digest}, symlinks, budget, len(raw))
            else:
                if set(item) - {1, 2, 4}:
                    raise Invalid("unsupported output symlink fields")
                target = text(one(item, 2, 2, b""))
                safe_symlink_target(path, target)
                symlinks[key] = target
                if 4 in item:
                    fields(one(item, 4, 2))


def validate_action_result(files, data):
    result = fields(data)
    if set(result) - {2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}:
        raise Invalid("unsupported ActionResult fields")
    if one(result, 4, 0, 0) != 0:
        raise Invalid("unsuccessful ActionResult")
    seen = set()
    symlinks = {}
    tree_budget = {"nodes": 0, "bytes": 0}
    for wire, output in result.get(2, []):
        if wire != 2:
            raise Invalid("malformed OutputFile")
        item = fields(output)
        if set(item) - {1, 2, 4, 5, 7}:
            raise Invalid("unsupported OutputFile fields")
        path = safe_relative_path(text(one(item, 1, 2, b"")))
        if "" in seen or str(path) in seen:
            raise Invalid("duplicate ActionResult output")
        seen.add(str(path))
        executable = one(item, 4, 0, 0)
        if executable not in (0, 1):
            raise Invalid("invalid output executable bit")
        digest_data = one(item, 2, 2)
        digest = None
        size = None
        if digest_data is not None:
            digest, size = read_digest(digest_data)
        inline = one(item, 5, 2)
        if digest_data is None and inline is None:
            raise Invalid("OutputFile lacks content")
        if inline is not None:
            if digest is not None and (
                hashlib.sha256(inline).hexdigest() != digest or len(inline) != size
            ):
                raise Invalid("inline output digest mismatch")
        else:
            referenced_blob(files, digest, size)
        if 7 in item:
            fields(one(item, 7, 2))
    for wire, output in result.get(3, []):
        if wire != 2:
            raise Invalid("malformed OutputDirectory")
        item = fields(output)
        if set(item) - {1, 3, 4, 5}:
            raise Invalid("unsupported OutputDirectory fields")
        raw_path = text(one(item, 1, 2, b""))
        path = safe_relative_path(raw_path) if raw_path else None
        if ("" in seen) or (path is None and seen):
            raise Invalid("overlapping ActionResult outputs")
        if str(path) in seen:
            raise Invalid("duplicate ActionResult output")
        seen.add(str(path) if path is not None else "")
        digest_data = one(item, 3, 2)
        if digest_data is None:
            raise Invalid("OutputDirectory lacks a digest")
        digest, size = read_digest(digest_data)
        validate_tree(
            files, digest, size, str(path) if path is not None else "", seen,
            symlinks, tree_budget,
        )
        if 4 in item and one(item, 4, 0) not in (0, 1):
            raise Invalid("malformed OutputDirectory sorted flag")
        if 5 in item:
            root_digest, root_size = read_digest(one(item, 5, 2))
            tree_blob = files["cas"].get(digest)
            if tree_blob is None:
                raise Invalid("missing OutputDirectory Tree")
            root = one(fields(tree_blob[0].read_bytes()), 1, 2)
            if root is None or hashlib.sha256(root).hexdigest() != root_digest \
                    or len(root) != root_size:
                raise Invalid("OutputDirectory root digest mismatch")
    for field in (10, 11, 12):
        for wire, output in result.get(field, []):
            if wire != 2:
                raise Invalid("malformed OutputSymlink")
            item = fields(output)
            if set(item) - {1, 2, 4}:
                raise Invalid("unsupported OutputSymlink fields")
            path = safe_relative_path(text(one(item, 1, 2, b"")))
            if "" in seen or str(path) in seen:
                raise Invalid("duplicate ActionResult output")
            seen.add(str(path))
            target = text(one(item, 2, 2, b""))
            safe_symlink_target(path, target)
            symlinks[str(path)] = target
            if 4 in item:
                fields(one(item, 4, 2))
    for raw, hashed in ((5, 6), (7, 8)):
        inline = one(result, raw, 2)
        digest_data = one(result, hashed, 2)
        if inline is not None and digest_data is not None:
            raise Invalid("ambiguous inline and digest output stream")
        if digest_data is not None:
            referenced_blob(files, *read_digest(digest_data))
    if 9 in result:
        fields(one(result, 9, 2))
    validate_symlink_graph(symlinks)


def validate_action_results(files):
    count = 0
    for digest, (path, size) in files["ac"].items():
        count += 1
        if size > MAX_ACTION_RESULT_BYTES:
            raise Invalid("ActionResult exceeds metadata limit")
        try:
            validate_action_result(files, path.read_bytes())
        except (Invalid, UnicodeError) as error:
            raise Invalid(f"invalid ActionResult {digest}: {error}") from error
        if count > MAX_FILES:
            raise Invalid("ActionResult count exceeds limit")


def make_manifest(args, archive):
    event = parse_json(Path(args.event_path).read_bytes())
    pr = event.get("pull_request") if args.event_name == "pull_request" else None
    if pr is not None and pr.get("head", {}).get("sha") != args.commit:
        raise Invalid("verified source revision differs from the pull request head")
    identity = {
        "format": FORMAT,
        "formatVersion": FORMAT_VERSION,
        "repository": args.repository,
        "workflow": WORKFLOW,
        "job": JOB,
        "runId": int(args.run_id),
        "runAttempt": int(args.run_attempt),
        "event": args.event_name,
        "builtCommit": args.commit,
        "sourceCommit": args.commit,
        "producerHeadSha": args.commit,
        "baseCommit": pr.get("base", {}).get("sha") if pr is not None else None,
        "pullRequest": None,
        "compatibility": {
            "bazelVersion": (ROOT / ".bazelversion").read_text().strip(),
            "os": platform.system().lower(),
            "architecture": normalize_arch(platform.machine()),
            "digest": "sha256",
        },
        "archive": {
            "file": archive.name,
            "sizeBytes": archive.stat().st_size,
            "sha256": file_hash(archive),
        },
    }
    if pr is not None:
        if int(args.pr_number) != int(pr["number"]):
            raise Invalid("PR number does not match the workflow event")
        identity["pullRequest"] = {
            "number": int(args.pr_number),
            "head": args.commit,
            "base": pr["base"]["sha"],
        }
    return identity


def normalize_arch(value):
    return {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}.get(
        value.lower(), value.lower()
    )


def file_hash(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def snapshot(source, archive):
    started = time.monotonic()
    checked = cache_files(source)
    if not checked["ac"]:
        raise Invalid("cache contains no action results")
    if archive.exists() or archive.is_symlink():
        raise Invalid("snapshot archive already exists")
    archive.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with tarfile.open(archive, "w:") as output:
        for kind in ("ac", "cas"):
            for digest, (path, _) in checked[kind].items():
                descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                try:
                    info = os.fstat(descriptor)
                    if not stat.S_ISREG(info.st_mode):
                        raise Invalid("cache file changed type during snapshot")
                    entry = tarfile.TarInfo(f"{kind}/{digest[:2]}/{digest}")
                    entry.size = info.st_size
                    entry.mode = 0o600
                    entry.mtime = 0
                    with os.fdopen(os.dup(descriptor), "rb") as stream:
                        output.addfile(entry, stream)
                finally:
                    os.close(descriptor)
                count += 1
    if archive.stat().st_size > MAX_ARCHIVE_BYTES:
        archive.unlink()
        raise Invalid("snapshot archive exceeds archive-size limit")
    return {"files": count, "sizeBytes": archive.stat().st_size,
            "seconds": round(time.monotonic() - started, 3)}


def reject_tar_extensions(archive):
    archive_size = archive.stat().st_size
    offset = 0
    members = 0
    with archive.open("rb") as stream:
        while offset < archive_size:
            header = stream.read(512)
            if len(header) != 512:
                raise Invalid("truncated snapshot archive header")
            if header == b"\0" * 512:
                return
            typeflag = header[156:157]
            if typeflag not in (b"\0", b"0"):
                raise Invalid("snapshot archive contains an extension or unsupported record")
            size_field = header[124:136].strip(b"\0 ")
            if any(byte < ord("0") or byte > ord("7") for byte in size_field):
                raise Invalid("snapshot archive has an invalid member size")
            member_size = int(size_field or b"0", 8)
            padded_size = ((member_size + 511) // 512) * 512
            offset += 512 + padded_size
            if offset > archive_size:
                raise Invalid("truncated snapshot archive member")
            members += 1
            if members > MAX_FILES:
                raise Invalid("snapshot archive exceeds member-count limit")
            stream.seek(offset)


def unpack_snapshot(archive, destination):
    if archive.stat().st_size > MAX_ARCHIVE_BYTES:
        raise Invalid("snapshot archive exceeds archive-size limit")
    reject_tar_extensions(archive)
    if destination.exists() or destination.is_symlink():
        raise Invalid("cache destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".bazel-cache-stage-", dir=destination.parent))
    count = 0
    members = 0
    total = 0
    try:
        with tarfile.open(archive, "r:") as source:
            for member in source:
                name = member.name
                path = PurePosixPath(name)
                if path.is_absolute() or str(path) != name or any(
                    part in ("", ".", "..") for part in path.parts
                ) or "\\" in name:
                    raise Invalid("unsafe snapshot archive path")
                if len(path.parts) != 3 or path.parts[0] not in ("ac", "cas") \
                        or not re.fullmatch(r"[0-9a-f]{2}", path.parts[1]) \
                        or not re.fullmatch(r"[0-9a-f]{64}", path.parts[2]) \
                        or path.parts[1] != path.parts[2][:2] or member.pax_headers:
                    raise Invalid("unsupported snapshot archive layout")
                target = stage.joinpath(*path.parts)
                members += 1
                if members > MAX_FILES:
                    raise Invalid("snapshot archive exceeds member-count limit")
                if not member.isfile() or member.issym() or member.islnk():
                    raise Invalid("snapshot archive contains a link or special file")
                count += 1
                total += member.size
                if count > MAX_FILES or total > MAX_EXPANDED_BYTES \
                        or member.size > MAX_FILE_BYTES:
                    raise Invalid("snapshot archive exceeds file or expansion limits")
                target.parent.mkdir(parents=True, exist_ok=True)
                stream = source.extractfile(member)
                if stream is None:
                    raise Invalid("snapshot archive member is unreadable")
                digest = hashlib.sha256()
                remaining = member.size
                with target.open("xb") as output:
                    while remaining:
                        block = stream.read(min(1024 * 1024, remaining))
                        if not block:
                            raise Invalid("truncated snapshot archive member")
                        output.write(block)
                        digest.update(block)
                        remaining -= len(block)
                    if stream.read(1):
                        raise Invalid("snapshot archive member exceeds declared size")
                if path.parts[0] == "cas" and digest.hexdigest() != path.parts[-1]:
                    raise Invalid("CAS digest mismatch in snapshot archive")
                if path.parts[0] == "ac" and not re.fullmatch(r"[0-9a-f]{64}", path.parts[-1]):
                    raise Invalid("invalid ActionResult archive path")
        if not cache_files(stage)["ac"]:
            raise Invalid("snapshot contains no action results")
        stage.rename(destination)
        return {"files": count, "expandedBytes": total}
    finally:
        if stage.exists():
            shutil.rmtree(stage)


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        if urllib.parse.urlparse(new_url).scheme != "https":
            raise ApiFailure("GitHub redirected a download away from HTTPS")
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        if redirected is not None \
                and urllib.parse.urlparse(request.full_url).netloc \
                != urllib.parse.urlparse(new_url).netloc:
            redirected.remove_header("Authorization")
        return redirected


def opener(token):
    return urllib.request.build_opener(SafeRedirectHandler()).open


def api_request(url, token, accept="application/vnd.github+json"):
    return urllib.request.Request(
        url, headers={"Accept": accept, "Authorization": "Bearer " + token,
                      "X-GitHub-Api-Version": "2022-11-28"}
    )


def preflight_zip(path):
    with path.open("rb") as stream:
        stream.seek(0, os.SEEK_END)
        size = stream.tell()
        tail_size = min(size, 65_557)
        stream.seek(-tail_size, os.SEEK_END)
        tail = stream.read(tail_size)
        offset = tail.rfind(b"PK\x05\x06")
        if offset < 0 or len(tail) < offset + 22:
            raise Invalid("workflow artifact has no ZIP directory")
        entries = struct.unpack_from("<H", tail, offset + 10)[0]
        directory_size = struct.unpack_from("<I", tail, offset + 12)[0]
        if entries == 0xFFFF or directory_size == 0xFFFFFFFF:
            absolute_eocd = size - tail_size + offset
            locator_offset = absolute_eocd - 20
            if locator_offset < 0:
                raise Invalid("truncated ZIP64 locator")
            stream.seek(locator_offset)
            locator = stream.read(20)
            if locator[:4] != b"PK\x06\x07":
                raise Invalid("invalid ZIP64 locator")
            zip64_offset = struct.unpack_from("<Q", locator, 8)[0]
            stream.seek(zip64_offset)
            zip64 = stream.read(56)
            if len(zip64) != 56 or zip64[:4] != b"PK\x06\x06":
                raise Invalid("invalid ZIP64 directory")
            entries = struct.unpack_from("<Q", zip64, 32)[0]
            directory_size = struct.unpack_from("<Q", zip64, 40)[0]
        if entries != 2 or directory_size > 1024 * 1024:
            raise Invalid("workflow artifact directory exceeds member limits")


def validate_zip_members(archive):
    infos = archive.infolist()
    if len(infos) != 2:
        raise Invalid("workflow artifact must contain exactly a snapshot and manifest")
    names = set()
    total = 0
    for info in infos:
        path = PurePosixPath(info.filename)
        mode = info.external_attr >> 16
        if path.is_absolute() or str(path) != info.filename \
                or any(part in ("", ".", "..") for part in path.parts) \
                or "\\" in info.filename or info.is_dir() \
                or (mode & 0o170000) not in (0, 0o100000):
            raise Invalid("unsafe workflow artifact path or file type")
        if info.filename in names:
            raise Invalid("duplicate workflow artifact member")
        names.add(info.filename)
        total += info.file_size
        if info.file_size > MAX_ARCHIVE_BYTES or total > MAX_ARCHIVE_BYTES:
            raise Invalid("workflow artifact exceeds expansion limit")
    if names != {"manifest.json", "snapshot.tar"}:
        raise Invalid("workflow artifact has unexpected files")
    return {info.filename: info for info in infos}


def request_json(url, token):
    for attempt in range(API_READ_ATTEMPTS):
        try:
            with opener(token)(api_request(url, token), timeout=30) as response:
                data = response.read(MAX_METADATA_BYTES + 1)
                if len(data) > MAX_METADATA_BYTES:
                    raise ApiFailure("GitHub API response exceeds metadata limit")
                return parse_json(data)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            if error.code not in (429, 500, 502, 503, 504) or attempt + 1 == API_READ_ATTEMPTS:
                raise ApiFailure(f"GitHub API returned HTTP {error.code}") from error
        except (urllib.error.URLError, TimeoutError, http.client.HTTPException,
                ConnectionError) as error:
            if attempt + 1 == API_READ_ATTEMPTS:
                raise ApiFailure("GitHub API request failed after bounded retries") from error
        time.sleep(0.2 * (2 ** attempt))


def request_file(url, token, destination, maximum):
    for attempt in range(API_READ_ATTEMPTS):
        try:
            with opener(token)(api_request(url, token), timeout=90) as response:
                content_length = response.headers.get("Content-Length")
                if content_length and int(content_length) > maximum:
                    raise Invalid("download exceeds archive-size limit")
                received = 0
                with destination.open("xb") as output:
                    while True:
                        block = response.read(1024 * 1024)
                        if not block:
                            break
                        received += len(block)
                        if received > maximum:
                            raise Invalid("download exceeds archive-size limit")
                        output.write(block)
                return received
        except urllib.error.HTTPError as error:
            if error.code in (404, 410):
                return None
            if error.code not in (429, 500, 502, 503, 504) or attempt + 1 == API_READ_ATTEMPTS:
                raise ApiFailure(f"artifact download returned HTTP {error.code}") from error
        except (urllib.error.URLError, TimeoutError, http.client.HTTPException,
                ConnectionError) as error:
            if attempt + 1 == API_READ_ATTEMPTS:
                raise ApiFailure("artifact download failed after bounded retries") from error
        if destination.exists():
            destination.unlink()
        time.sleep(0.2 * (2 ** attempt))


def request_delete(url, token):
    request = api_request(url, token)
    request.method = "DELETE"
    try:
        with opener(token)(request, timeout=30):
            return True
    except urllib.error.HTTPError as error:
        if error.code in (404, 410):
            return False
        if error.code in (500, 502, 503, 504):
            artifact_url = url.rsplit("/", 1)[0] + "/" + urllib.parse.quote(
                url.rsplit("/", 1)[1], safe=""
            )
            try:
                if request_json(artifact_url, token) is None:
                    return False
            except ApiFailure as check_error:
                raise ApiFailure("artifact deletion outcome is unknown; existence check failed") \
                    from check_error
            raise ApiFailure("artifact deletion outcome is unknown; artifact still exists") from error
        raise ApiFailure(f"artifact deletion returned HTTP {error.code}") from error
    except (urllib.error.URLError, TimeoutError, http.client.HTTPException,
            ConnectionError) as error:
        artifact_url = url.rsplit("/", 1)[0] + "/" + urllib.parse.quote(
            url.rsplit("/", 1)[1], safe=""
        )
        try:
            if request_json(artifact_url, token) is None:
                return False
        except ApiFailure as check_error:
            raise ApiFailure("artifact deletion outcome is unknown; existence check failed") \
                from check_error
        raise ApiFailure("artifact deletion outcome is unknown; artifact still exists") from error


def paginated(url, token, key, page_size=100):
    page = 1
    while True:
        separator = "&" if "?" in url else "?"
        result = request_json(f"{url}{separator}per_page={page_size}&page={page}", token)
        if result is None:
            return
        entries = result.get(key, [])
        yield from entries
        if len(entries) < page_size:
            return
        page += 1


def api_base(repository):
    return "https://api.github.com/repos/" + urllib.parse.quote(repository, safe="/")


def run_history(base_sha):
    try:
        output = subprocess.check_output(
            ["git", "rev-list", "--first-parent", base_sha], cwd=ROOT, text=True, stderr=subprocess.DEVNULL
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        raise Invalid("cannot determine first-parent history") from error
    return {sha: index for index, sha in enumerate(output.splitlines())}


def run_matches_scope(run, scope, pr_number):
    if scope == "main":
        return run.get("event") == "push" and run.get("head_branch") == "main"
    return run.get("event") == "pull_request"


def rank_runs(runs, scope, pr_number, history, max_run_number=None):
    candidates = []
    for run in runs:
        if not run_matches_scope(run, scope, pr_number):
            continue
        if scope == "main":
            sha = run.get("head_sha")
            if sha not in history:
                continue
            distance = history[sha]
            candidates.append((distance, int(run["run_number"]), int(run.get("run_attempt", 1)), run))
        else:
            run_number = int(run["run_number"])
            attempt = int(run.get("run_attempt", 1))
            if max_run_number is not None and run_number > max_run_number:
                continue
            candidates.append((0, run_number, attempt, run))
    if scope == "main":
        candidates.sort(key=lambda item: (item[0], -item[1], -item[2]))
    else:
        candidates.sort(key=lambda item: (-item[1], -item[2]))
    return [entry[3] for entry in candidates]


def pr_attempt_is_eligible(run, attempt, current_run, current_run_number, current_attempt):
    if int(run["id"]) == current_run:
        return attempt < current_attempt
    return int(run["run_number"]) < current_run_number


def artifacts_for_run(base, token, run):
    url = f"{base}/actions/runs/{run['id']}/artifacts"
    artifacts = list(paginated(url, token, "artifacts"))
    def attempt(artifact):
        match = re.search(r"-a(\d+)$", artifact.get("name", ""))
        return int(match.group(1)) if match else 0
    return sorted(artifacts, key=attempt, reverse=True)


def producer_attempt(base, token, run, attempt):
    return request_json(
        f"{base}/actions/runs/{run['id']}/attempts/{attempt}", token
    )


def jobs_for_attempt(base, token, run_id, attempt):
    return list(paginated(
        f"{base}/actions/runs/{run_id}/attempts/{attempt}/jobs", token, "jobs"
    ))


def resolve_pr_association(base, token, repository, head_sha, requested_pr, repository_id=None):
    encoded_sha = urllib.parse.quote(head_sha, safe="")
    pulls = request_json(f"{base}/commits/{encoded_sha}/pulls", token)
    if not isinstance(pulls, list):
        raise Invalid("commit-to-PR association metadata is unavailable")
    eligible = {}
    for pull in pulls:
        if not isinstance(pull, dict) or type(pull.get("number")) is not int:
            continue
        base_metadata = pull.get("base")
        base_repository = base_metadata.get("repo") if isinstance(base_metadata, dict) else None
        if isinstance(base_repository, dict) \
                and base_repository.get("full_name") == repository \
                and (repository_id is None or base_repository.get("id") == repository_id):
            eligible[pull["number"]] = pull
    if not eligible:
        raise Invalid(f"commit-to-PR association is missing for PR #{requested_pr}")
    if len(eligible) != 1:
        raise Invalid(f"commit-to-PR association is ambiguous for PR #{requested_pr}")
    if requested_pr not in eligible:
        raise Invalid(f"commit-to-PR association identifies another PR, not PR #{requested_pr}")
    return eligible[requested_pr]


def cleanup_artifact_identity(artifact, detail, jobs, repository, repository_id,
                              base=None, token=None):
    if not isinstance(detail, dict):
        raise Invalid("artifact producer metadata is missing")
    name = artifact.get("name", "")
    main_match = MAIN_ARTIFACT_PATTERN.fullmatch(name) \
        or LEGACY_MAIN_ARTIFACT_PATTERN.fullmatch(name)
    pr_match = PR_ARTIFACT_PATTERN.fullmatch(name) \
        or LEGACY_PR_ARTIFACT_PATTERN.fullmatch(name)
    if main_match:
        scope, run_id, attempt = "main", int(main_match.group(1)), int(main_match.group(2))
        pr_number = None
    elif pr_match:
        scope, pr_number, run_id, attempt = (
            "pr", int(pr_match.group(1)), int(pr_match.group(2)), int(pr_match.group(3))
        )
    else:
        raise Invalid("unrecognized Bazel cache artifact identity")

    workflow_run = artifact.get("workflow_run")
    run_repository = detail.get("repository")
    if type(artifact.get("id")) is not int or artifact["id"] <= 0 \
            or not isinstance(workflow_run, dict) \
            or type(workflow_run.get("id")) is not int \
            or workflow_run["id"] != run_id \
            or type(workflow_run.get("repository_id")) is not int \
            or workflow_run["repository_id"] != repository_id \
            or not isinstance(run_repository, dict) \
            or run_repository.get("full_name") != repository \
            or run_repository.get("id") != repository_id \
            or type(detail.get("workflow_id")) is not int \
            or detail["workflow_id"] <= 0 \
            or detail.get("path") != WORKFLOW or detail.get("name") != "Publish" \
            or int(detail.get("id", -1)) != run_id \
            or int(detail.get("run_attempt", -1)) != attempt \
            or int(detail.get("run_number", 0)) <= 0 \
            or not isinstance(detail.get("head_sha"), str) \
            or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", detail["head_sha"]) \
            or workflow_run.get("event") != detail.get("event") \
            or workflow_run.get("head_sha") != detail.get("head_sha") \
            or workflow_run.get("head_branch") != detail.get("head_branch") \
            or detail.get("head_sha") != workflow_run.get("head_sha") \
            or detail.get("head_branch") != workflow_run.get("head_branch"):
        raise Invalid("artifact producer metadata mismatch")
    if scope == "main":
        head_repository = detail.get("head_repository")
        if detail.get("event") != "push" or detail.get("head_branch") != "main" \
                or not isinstance(head_repository, dict) \
                or head_repository.get("full_name") != repository \
                or head_repository.get("id") != repository_id:
            raise Invalid("main artifact has an invalid producer scope")
    else:
        if detail.get("event") != "pull_request":
            raise Invalid("PR artifact has an invalid producer event")
        if base is None or token is None:
            raise Invalid("commit-to-PR identity verifier is unavailable")
        resolve_pr_association(
            base, token, repository, detail.get("head_sha", ""), pr_number, repository_id
        )
    matching_job = next((job for job in jobs if job.get("name") == JOB), None)
    if matching_job is None or not any(
        step.get("name") == UPLOAD_STEP and step.get("conclusion") == "success"
        for step in matching_job.get("steps", [])
    ):
        raise Invalid("producer did not complete the cache upload step")
    return {
        "artifact": artifact,
        "id": artifact["id"],
        "scope": scope,
        "pr": pr_number,
        "runNumber": int(detail["run_number"]),
        "attempt": attempt,
        "runId": run_id,
    }


def cleanup_artifacts(base, token, repository):
    failures = []
    identities = []
    unresolved_main = False
    try:
        repository_data = request_json(base, token)
        if not isinstance(repository_data, dict) \
                or repository_data.get("full_name") != repository \
                or type(repository_data.get("id")) is not int \
                or repository_data["id"] <= 0:
            raise Invalid("repository identity could not be verified")
        artifacts = paginated(f"{base}/actions/artifacts", token, "artifacts")
        for artifact in artifacts:
            name = artifact.get("name", "") if isinstance(artifact, dict) else ""
            if not name.startswith(("bazel-cache-v1-", f"{ARTIFACT_PREFIX}-")):
                continue
            main_candidate = name.startswith(("bazel-cache-v1-main-", f"{ARTIFACT_PREFIX}-main-"))
            if artifact.get("expired"):
                continue
            try:
                match = MAIN_ARTIFACT_PATTERN.fullmatch(name) \
                    or PR_ARTIFACT_PATTERN.fullmatch(name) \
                    or LEGACY_MAIN_ARTIFACT_PATTERN.fullmatch(name) \
                    or LEGACY_PR_ARTIFACT_PATTERN.fullmatch(name)
                if not match:
                    raise Invalid("unrecognized Bazel cache artifact identity")
                run_id = int(match.group(1)) if main_candidate else int(match.group(2))
                attempt = int(match.group(2)) if main_candidate else int(match.group(3))
                run = producer_attempt(base, token, {"id": run_id}, attempt)
                jobs = jobs_for_attempt(base, token, run_id, attempt)
                identities.append(cleanup_artifact_identity(
                    artifact, run, jobs, repository, repository_data["id"], base, token
                ))
            except (ApiFailure, Invalid, TypeError, ValueError) as error:
                if main_candidate:
                    unresolved_main = True
                failures.append(f"artifact={name}: {error}")
                print(f"cleanup: identity-error artifact={name}: {error}", file=sys.stderr)

        merged_prs = {}
        for identity in identities:
            if identity["scope"] != "pr" or identity["pr"] in merged_prs:
                continue
            pr_number = identity["pr"]
            try:
                pull = request_json(f"{base}/pulls/{pr_number}", token)
                pull_base = pull.get("base") if isinstance(pull, dict) else None
                pull_repository = pull_base.get("repo") if isinstance(pull_base, dict) else None
                if not isinstance(pull, dict) or int(pull.get("number", -1)) != pr_number \
                        or not isinstance(pull_repository, dict) \
                        or pull_repository.get("full_name") != repository \
                        or pull_repository.get("id") != repository_data["id"]:
                    raise Invalid("pull request repository identity could not be verified")
                merged_prs[pr_number] = (
                    pull.get("state") == "closed" and bool(pull.get("merged_at"))
                )
            except (ApiFailure, Invalid, TypeError, ValueError) as error:
                failures.append(f"pull-request={pr_number}: {error}")
                print(f"cleanup: pull-request-error pr={pr_number}: {error}", file=sys.stderr)

        main_artifacts = sorted(
            (item for item in identities if item["scope"] == "main"),
            key=lambda item: (item["runNumber"], item["attempt"], item["runId"]),
            reverse=True,
        )
        delete = []
        if unresolved_main:
            print("cleanup: main-retention skipped; an artifact identity could not be verified")
        else:
            delete.extend(main_artifacts[MAIN_ARTIFACT_RETENTION:])
        delete.extend(
            item for item in identities
            if item["scope"] == "pr" and merged_prs.get(item["pr"]) is True
        )

        deleted = 0
        already_gone = 0
        for identity in delete:
            try:
                removed = request_delete(
                    f"{base}/actions/artifacts/{identity['id']}", token
                )
                if removed:
                    deleted += 1
                    print(f"cleanup: deleted artifact={identity['artifact']['name']}")
                else:
                    already_gone += 1
                    print(f"cleanup: already-gone artifact={identity['artifact']['name']}")
            except ApiFailure as error:
                failures.append(f"artifact={identity['artifact']['name']}: {error}")
                print(f"cleanup: deletion-error artifact={identity['artifact']['name']}: {error}",
                      file=sys.stderr)

        if failures:
            print(f"cleanup: incomplete; {len(failures)} identity or service errors",
                  file=sys.stderr)
            return 1
        print(f"cleanup: complete retained-main={min(len(main_artifacts), MAIN_ARTIFACT_RETENTION)} "
              f"deleted={deleted} already-gone={already_gone}")
        return 0
    except (ApiFailure, Invalid) as error:
        print(f"cleanup: API-error {error}; cleanup incomplete", file=sys.stderr)
        return 1


def verify_producer(run, detail, jobs, manifest, artifact_name, scope, pr_number,
                    repository, associated_pr=None, expected_head=None):
    expected_scope = "main" if scope == "main" else f"pr-{pr_number}"
    expected_prefix = f"{ARTIFACT_PREFIX}-{expected_scope}-r{run['id']}-a{detail['run_attempt']}"
    if artifact_name != expected_prefix:
        raise Invalid("artifact name does not match producer identity")
    run_repository = run.get("repository")
    detail_repository = detail.get("repository")
    if not isinstance(run_repository, dict) or not isinstance(detail_repository, dict) \
            or run_repository.get("full_name") != repository \
            or detail_repository.get("full_name") != repository \
            or type(run_repository.get("id")) is not int \
            or run_repository.get("id") <= 0 \
            or detail_repository.get("id") != run_repository.get("id") \
            or type(run.get("workflow_id")) is not int \
            or run.get("workflow_id") <= 0 \
            or detail.get("workflow_id") != run.get("workflow_id") \
            or detail.get("path") != WORKFLOW or detail.get("name") != "Publish" \
            or detail.get("event") != run.get("event") \
            or detail.get("run_number") != run.get("run_number") \
            or detail.get("head_sha") != run.get("head_sha") \
            or int(detail.get("id", -1)) != int(run["id"]) \
            or int(detail.get("run_attempt", -1)) != int(artifact_name.rsplit("-a", 1)[1]):
        raise Invalid("artifact producer metadata mismatch")
    if manifest.get("repository") != repository or manifest.get("workflow") != WORKFLOW \
            or manifest.get("job") != JOB or manifest.get("runId") != int(run["id"]) \
            or manifest.get("runAttempt") != int(detail["run_attempt"]) \
            or manifest.get("event") != detail.get("event"):
        raise Invalid("manifest identity does not match GitHub run metadata")
    matching_job = next((job for job in jobs if job.get("name") == JOB), None)
    if matching_job is None or not any(
        step.get("name") == UPLOAD_STEP and step.get("conclusion") == "success"
        for step in matching_job.get("steps", [])
    ):
        raise Invalid("producer did not complete the cache upload step")
    if scope == "main":
        if manifest.get("pullRequest") is not None \
                or manifest.get("builtCommit") != detail.get("head_sha") \
                or manifest.get("sourceCommit") != detail.get("head_sha") \
                or manifest.get("producerHeadSha") != detail.get("head_sha") \
                or manifest.get("baseCommit") is not None \
                or detail.get("event") != "push" \
                or detail.get("head_branch") != "main":
            raise Invalid("main artifact has an invalid producer scope")
    else:
        pull_request = manifest.get("pullRequest")
        associated_base = associated_pr.get("base") if isinstance(associated_pr, dict) else None
        associated_repository = associated_base.get("repo") if isinstance(associated_base, dict) else None
        if not isinstance(pull_request, dict) or not isinstance(associated_pr, dict) \
                or pull_request.get("number") != pr_number \
                or pull_request.get("head") != detail.get("head_sha") \
                or manifest.get("builtCommit") != detail.get("head_sha") \
                or manifest.get("sourceCommit") != detail.get("head_sha") \
                or manifest.get("producerHeadSha") != detail.get("head_sha") \
                or pull_request.get("base") != manifest.get("baseCommit") \
                or int(associated_pr.get("number", -1)) != pr_number \
                or not isinstance(associated_repository, dict) \
                or associated_repository.get("full_name") != repository \
                or associated_repository.get("id") != run_repository["id"]:
            raise Invalid("PR artifact source or commit-to-PR identity mismatch")
        if expected_head is not None and pull_request.get("head") != expected_head:
            raise Invalid("PR artifact is not for the final PR head")


def validate_compatibility(manifest):
    compatibility = manifest.get("compatibility")
    current = {
        "bazelVersion": (ROOT / ".bazelversion").read_text().strip(),
        "os": platform.system().lower(),
        "architecture": normalize_arch(platform.machine()),
        "digest": "sha256",
    }
    if manifest.get("format") != FORMAT or manifest.get("formatVersion") != FORMAT_VERSION \
            or compatibility != current:
        raise Invalid("snapshot format or compatibility mismatch")


def validate_manifest(manifest):
    expected_keys = {
        "format", "formatVersion", "repository", "workflow", "job", "runId",
        "runAttempt", "event", "builtCommit", "sourceCommit", "producerHeadSha",
        "baseCommit", "pullRequest", "compatibility", "archive",
    }
    if not isinstance(manifest, dict) or set(manifest) != expected_keys \
            or type(manifest.get("formatVersion")) is not int \
            or type(manifest.get("runId")) is not int \
            or type(manifest.get("runAttempt")) is not int \
            or manifest["runId"] <= 0 or manifest["runAttempt"] <= 0 \
            or not isinstance(manifest.get("repository"), str) \
            or not isinstance(manifest.get("builtCommit"), str) \
            or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", manifest["builtCommit"]):
        raise Invalid("malformed snapshot manifest")
    if any(not isinstance(manifest.get(key), str)
           or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", manifest[key])
           for key in ("sourceCommit", "producerHeadSha")):
        raise Invalid("malformed snapshot source identity")
    archive = manifest.get("archive")
    if not isinstance(archive, dict) or set(archive) != {"file", "sizeBytes", "sha256"} \
            or archive.get("file") != "snapshot.tar" \
            or type(archive.get("sizeBytes")) is not int \
            or not 0 < archive["sizeBytes"] <= MAX_ARCHIVE_BYTES \
            or not isinstance(archive.get("sha256"), str) \
            or not re.fullmatch(r"[0-9a-f]{64}", archive["sha256"]):
        raise Invalid("malformed snapshot archive metadata")
    if manifest.get("event") == "pull_request":
        pull_request = manifest.get("pullRequest")
        if not isinstance(pull_request, dict) \
                or set(pull_request) != {"number", "head", "base"} \
                or type(pull_request.get("number")) is not int \
                or pull_request["number"] <= 0 \
                or any(not isinstance(pull_request.get(key), str)
                       or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", pull_request[key])
                       for key in ("head", "base")) \
                or manifest.get("baseCommit") != pull_request.get("base"):
            raise Invalid("malformed PR snapshot identity")
    elif manifest.get("pullRequest") is not None or manifest.get("baseCommit") is not None:
        raise Invalid("non-PR snapshot has a PR identity")
    if manifest.get("builtCommit") != manifest.get("sourceCommit") \
            or manifest.get("builtCommit") != manifest.get("producerHeadSha"):
        raise Invalid("snapshot source and producer head revisions differ")
    validate_compatibility(manifest)


def download_candidate(base, token, artifact, cache_path, repository,
                      run, scope, pr_number, expected_head=None,
                      require_trusted_writer=False):
    with tempfile.TemporaryDirectory(prefix="bazel-artifact-") as directory:
        root = Path(directory)
        zipped = root / "artifact.zip"
        artifact_id = int(artifact["id"])
        if artifact_id <= 0:
            raise Invalid("artifact has an invalid ID")
        received = request_file(f"{base}/actions/artifacts/{artifact_id}/zip", token,
                                zipped, MAX_ARCHIVE_BYTES)
        if received is None:
            return "artifact disappeared before download"
        if type(artifact.get("size_in_bytes")) is int \
                and received != artifact["size_in_bytes"]:
            raise Invalid("workflow artifact size differs from GitHub metadata")
        preflight_zip(zipped)
        if not zipfile.is_zipfile(zipped):
            raise Invalid("workflow artifact is not a ZIP archive")
        with zipfile.ZipFile(zipped) as archive:
            infos = validate_zip_members(archive)
            manifest_info = infos["manifest.json"]
            if manifest_info.file_size > MAX_METADATA_BYTES:
                raise Invalid("manifest exceeds metadata limit")
            manifest_data = archive.read(manifest_info)
            actual_manifest = parse_json(manifest_data)
            validate_manifest(actual_manifest)
            snapshot_info = infos["snapshot.tar"]
            archive_identity = actual_manifest.get("archive")
            if not isinstance(archive_identity, dict) \
                    or archive_identity.get("file") != "snapshot.tar" \
                    or archive_identity.get("sizeBytes") != snapshot_info.file_size \
                    or snapshot_info.file_size > MAX_ARCHIVE_BYTES:
                raise Invalid("snapshot archive size does not match manifest")
            snapshot_file = root / "snapshot.tar"
            hasher = hashlib.sha256()
            with archive.open(snapshot_info) as source, snapshot_file.open("xb") as output:
                copied = 0
                while True:
                    block = source.read(1024 * 1024)
                    if not block:
                        break
                    copied += len(block)
                    if copied > MAX_ARCHIVE_BYTES:
                        raise Invalid("snapshot archive exceeds archive-size limit")
                    output.write(block)
                    hasher.update(block)
            if copied != snapshot_info.file_size \
                    or archive_identity.get("sha256") != hasher.hexdigest():
                raise Invalid("snapshot archive size or digest mismatch")
        attempt = int(artifact["name"].rsplit("-a", 1)[1])
        detail = producer_attempt(base, token, run, attempt)
        if detail is None:
            return "producer attempt metadata disappeared"
        jobs = jobs_for_attempt(base, token, run["id"], attempt)
        associated_pr = None
        if scope == "pr":
            if expected_head is not None \
                    and actual_manifest.get("pullRequest", {}).get("head") != expected_head:
                raise Invalid("PR artifact is not for the final PR head")
            associated_pr = resolve_pr_association(
                base, token, repository, detail.get("head_sha", ""), pr_number,
                run.get("repository", {}).get("id"),
            )
        verify_producer(run, detail, jobs, actual_manifest, artifact["name"], scope,
                        pr_number, repository, associated_pr, expected_head)
        if require_trusted_writer and not trusted_pr_writer(
            base, token, run, detail, repository, pr_number
        ):
            raise Invalid("PR artifact producer is not an eligible same-repository writer")
        if cache_path.exists():
            raise Invalid("cache destination already exists")
        restore_started = time.monotonic()
        stats = unpack_snapshot(snapshot_file, cache_path)
        stats["restoreSeconds"] = round(time.monotonic() - restore_started, 3)
        stats["peakRssBytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024
        stats["artifactBytes"] = received
        stats["snapshotBytes"] = snapshot_info.file_size
        identity = ""
        if scope == "pr":
            pr_identity = actual_manifest["pullRequest"]
            identity = f" head={pr_identity['head']} base-context={pr_identity['base']}"
        print(f"cache: restored scope={scope} pr={pr_number or 'none'} "
              f"producer run={run['id']} attempt={attempt} "
              f"source={actual_manifest['sourceCommit']}{identity} stats={json.dumps(stats)}")
        return None


def trusted_pr_writer(base, token, run, detail, repository, pr_number):
    actor = run.get("actor")
    detail_actor = detail.get("actor")
    actor_identity = trusted_actor_identity(actor)
    detail_identity = trusted_actor_identity(detail_actor)
    if actor_identity is None or detail_identity is None:
        print(f"cache: trust-rejected pr={pr_number}: producer actor identity metadata is missing or malformed")
        return False
    actor_id, login, actor_type = actor_identity
    if actor_identity != detail_identity:
        print(f"cache: trust-rejected pr={pr_number}: producer actor identity is inconsistent")
        return False
    head_repo = detail.get("head_repository")
    producer_repo = detail.get("repository")
    if not isinstance(head_repo, dict) or not isinstance(producer_repo, dict) \
            or producer_repo.get("full_name") != repository \
            or type(producer_repo.get("id")) is not int or producer_repo["id"] <= 0 \
            or type(head_repo.get("id")) is not int \
            or head_repo.get("full_name") != repository \
            or head_repo["id"] != producer_repo["id"]:
        print(f"cache: trust-rejected pr={pr_number}: recorded producer head repository is not this repository")
        return False
    if actor_type == "Bot":
        if actor_identity != TRUSTED_COPILOT_ACTOR:
            print(f"cache: trust-rejected pr={pr_number}: unsupported or mismatched bot identity "
                  f"id={actor_id} login={login} type={actor_type}")
            return False
        print(f"cache: trust-accepted pr={pr_number} producer={login} "
              "authorization=pinned Copilot identity")
        return True
    if actor_id == TRUSTED_COPILOT_ACTOR[0] or login == TRUSTED_COPILOT_ACTOR[1]:
        print(f"cache: trust-rejected pr={pr_number}: producer identity does not match "
              "the pinned Copilot identity")
        return False
    if actor_type != "User":
        print(f"cache: trust-rejected pr={pr_number}: unsupported producer actor type "
              f"id={actor_id} login={login} type={actor_type}")
        return False
    encoded_login = urllib.parse.quote(login, safe="")
    permission = request_json(
        f"{base}/collaborators/{encoded_login}/permission", token
    )
    identity = permission.get("user", {}) if isinstance(permission, dict) else {}
    if not isinstance(permission, dict) or not isinstance(identity, dict) \
            or identity.get("login") != login \
            or permission.get("permission") not in ("admin", "maintain", "write"):
        reason = "collaborator permission metadata is unavailable" if permission is None \
            else f"actor {login} lacks verified write permission"
        print(f"cache: trust-rejected pr={pr_number}: {reason}")
        return False
    print(f"cache: trust-accepted pr={pr_number} producer={login} "
          f"permission={permission['permission']}")
    return True


def trusted_actor_identity(actor):
    if not isinstance(actor, dict):
        return None
    actor_id = actor.get("id")
    login = actor.get("login")
    actor_type = actor.get("type")
    if type(actor_id) is not int or actor_id <= 0 \
            or not isinstance(login, str) or not login \
            or not isinstance(actor_type, str) or not actor_type:
        return None
    return actor_id, login, actor_type


def squash_pull_request(base, token, repository, commit_sha):
    encoded_sha = urllib.parse.quote(commit_sha, safe="")
    pulls = request_json(f"{base}/commits/{encoded_sha}/pulls", token)
    if not isinstance(pulls, list):
        print(f"cache: squash-fallback revision={commit_sha}: malformed associated-PR metadata")
        return None
    matches = []
    for pull in pulls:
        if not isinstance(pull, dict):
            continue
        base_metadata = pull.get("base")
        base_repository = base_metadata.get("repo") if isinstance(base_metadata, dict) else None
        if pull.get("state") == "closed" and pull.get("merged_at") \
                and pull.get("merge_commit_sha") == commit_sha \
                and isinstance(base_repository, dict) \
                and base_metadata.get("ref") == "main" \
                and base_repository.get("full_name") == repository:
            matches.append(pull)
    if not matches:
        print(f"cache: squash-not-found revision={commit_sha}: no merged PR association")
        return None
    if len(matches) != 1:
        reason = "ambiguous merged PR association"
        print(f"cache: squash-fallback revision={commit_sha}: {reason}")
        return False
    pull = matches[0]
    head = pull.get("head")
    if not isinstance(head, dict) or type(pull.get("number")) is not int \
            or pull["number"] <= 0 or not re.fullmatch(
        r"(?:[0-9a-f]{40}|[0-9a-f]{64})", str(head.get("sha", ""))
    ):
        print(f"cache: squash-fallback revision={commit_sha}: malformed final PR head")
        return False
    head_repository = head.get("repo")
    if not isinstance(head_repository, dict) or head_repository.get("full_name") != repository:
        print(f"cache: squash-fallback revision={commit_sha}: fork-produced PR cache is never imported")
        return False
    print(f"cache: squash-associated revision={commit_sha} pr={pull['number']} "
          f"final-head={head['sha']} synthetic-merge=distinct")
    return pull


def restore_scope(args, base, token, scope, pr_number, history, destination,
                  expected_head=None, require_trusted_writer=False):
    query = {"event": "pull_request"} if scope == "pr" \
        else {"event": "push", "branch": "main"}
    runs_url = f"{base}/actions/runs?" + urllib.parse.urlencode(query)
    try:
        runs = list(paginated(
            runs_url, token, "workflow_runs", page_size=WORKFLOW_RUNS_PAGE_SIZE
        ))
        candidates = rank_runs(
            runs, scope, pr_number, history,
            int(args.run_number) if scope == "pr" else None,
        )
    except ApiFailure as error:
        print(f"cache: API-error source={scope} listing: {error}", file=sys.stderr)
        return False
    for run in candidates:
        if expected_head is not None and run.get("head_sha") != expected_head:
            continue
        try:
            artifacts = artifacts_for_run(base, token, run)
        except ApiFailure as error:
            print(f"cache: API-error source={scope} run={run['id']} artifacts: {error}",
                  file=sys.stderr)
            continue
        for artifact in artifacts:
            artifact_scope = "main" if scope == "main" else f"pr-{pr_number}"
            legacy_pattern = LEGACY_MAIN_ARTIFACT_PATTERN if scope == "main" \
                else LEGACY_PR_ARTIFACT_PATTERN
            if legacy_pattern.fullmatch(artifact.get("name", "")):
                print(f"cache: migration-skip source={scope} artifact={artifact['name']}: "
                      "legacy synthetic-build format is not consumable")
                continue
            match = re.fullmatch(
                rf"{ARTIFACT_PREFIX}-{artifact_scope}-r(\d+)-a(\d+)",
                artifact.get("name", ""),
            )
            if match is None or int(match.group(1)) != int(run["id"]):
                continue
            if artifact.get("expired"):
                print(f"cache: artifact-miss run={run['id']} attempt={match.group(2)}: expired")
                continue
            attempt = int(match.group(2))
            if scope == "pr" and not pr_attempt_is_eligible(
                run, attempt, int(args.run_id), int(args.run_number), int(args.run_attempt)
            ):
                continue
            if artifact.get("workflow_run", {}).get("id") not in (None, int(run["id"])):
                continue
            try:
                extra = {}
                if expected_head is not None:
                    extra["expected_head"] = expected_head
                if require_trusted_writer:
                    extra["require_trusted_writer"] = True
                downloaded = download_candidate(
                    base, token, artifact, destination, args.repository, run, scope,
                    pr_number, **extra,
                )
                if downloaded is None:
                    return True
                print(f"cache: artifact-miss source={scope} run={run['id']}: {downloaded}")
            except ApiFailure as error:
                print(f"cache: API-error source={scope} run={run['id']}: {error}", file=sys.stderr)
            except Exception as error:
                print(f"cache: rejected run={run['id']} source={scope} "
                      f"artifact={artifact.get('name')}: {error}")
    print(f"cache: fallback scope={scope}: no acceptable snapshot")
    return False


def identical_files(left, right):
    if left.stat().st_size != right.stat().st_size:
        return False
    with left.open("rb") as left_stream, right.open("rb") as right_stream:
        while True:
            left_block = left_stream.read(1024 * 1024)
            right_block = right_stream.read(1024 * 1024)
            if left_block != right_block:
                return False
            if not left_block:
                return True


def union_caches(main_cache, pr_cache, destination):
    started = time.monotonic()
    main_files = cache_files(Path(main_cache))
    pr_files = cache_files(Path(pr_cache))
    if destination.exists() or destination.is_symlink():
        raise Invalid("cache destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".bazel-cache-union-", dir=destination.parent))
    counts = {"ac": 0, "cas": 0}
    expanded = 0
    try:
        for category in ("ac", "cas"):
            merged = dict(main_files[category])
            for digest, source in pr_files[category].items():
                existing = merged.get(digest)
                if existing is None:
                    merged[digest] = source
                elif not identical_files(existing[0], source[0]):
                    if category == "cas":
                        raise Invalid(f"conflicting CAS bytes for digest {digest}")
                    print(f"cache: union-conflict action-key={digest} winner=main")
                elif category == "cas" and source[0].stat().st_mtime_ns \
                        > existing[0].stat().st_mtime_ns:
                    merged[digest] = source
                    print(f"cache: union-duplicate cas={digest}")
                elif category == "cas":
                    print(f"cache: union-duplicate cas={digest}")
            for digest, (source, size) in merged.items():
                counts[category] += 1
                expanded += size
                if counts["ac"] + counts["cas"] > MAX_FILES \
                        or expanded > MAX_EXPANDED_BYTES:
                    raise Invalid("cache union exceeds file or expansion limits")
                target = stage / category / digest[:2] / digest
                target.parent.mkdir(parents=True, exist_ok=True)
                if category == "ac" and digest in main_files[category]:
                    source = main_files[category][digest][0]
                shutil.copy2(source, target)
        validated = cache_files(stage)
        stage.rename(destination)
        stats = {
            "files": sum(counts.values()),
            "expandedBytes": expanded,
            "seconds": round(time.monotonic() - started, 3),
            "peakRssBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024,
        }
        print(f"cache: union=accepted main-actions={len(main_files['ac'])} "
              f"pr-actions={len(pr_files['ac'])} merged-actions={len(validated['ac'])} "
              f"stats={json.dumps(stats)}")
        return stats
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def copy_cache(source, destination):
    source = Path(source)
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise Invalid("cache destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".bazel-cache-restore-", dir=destination.parent))
    try:
        shutil.copytree(source, stage, dirs_exist_ok=True, copy_function=shutil.copy2)
        cache_files(stage)
        stage.rename(destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def discover_and_restore(args):
    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        print("cache: API-error missing GITHUB_TOKEN; continuing uncached", file=sys.stderr)
        return
    base = api_base(args.repository)
    try:
        current_event = parse_json(Path(args.event_path).read_bytes())
        scope = "pr" if args.event_name == "pull_request" else "main"
        pr_number = int(args.pr_number) if scope == "pr" else None
        current_run, current_attempt = int(args.run_id), int(args.run_attempt)
        target_sha = current_event["pull_request"]["base"]["sha"] if scope == "pr" \
            else args.commit
        history = run_history(target_sha)
        if scope == "pr":
            restored = restore_scope(
                args, base, token, "pr", pr_number, history, Path(args.cache)
            )
            if not restored:
                main_history = run_history(current_event["pull_request"]["base"]["sha"])
                restore_scope(args, base, token, "main", None, main_history, Path(args.cache))
        else:
            pull = None
            try:
                pull = squash_pull_request(base, token, args.repository, args.commit)
            except ApiFailure as error:
                print(f"cache: API-error squash-association: {error}; using main-only path",
                      file=sys.stderr)
                pull = False
            if pull is None:
                restore_scope(args, base, token, "main", None, history, Path(args.cache))
            else:
                squash_history = dict(history)
                squash_history.pop(args.commit, None)
                if pull is False:
                    print(f"cache: squash-fallback revision={args.commit}: using main-only snapshot")
                    restore_scope(
                        args, base, token, "main", None, squash_history, Path(args.cache)
                    )
                    return
                with tempfile.TemporaryDirectory(prefix="bazel-cache-union-") as directory:
                    main_cache = Path(directory) / "main"
                    pr_cache = Path(directory) / "pr"
                    main_restored = restore_scope(
                        args, base, token, "main", None, squash_history, main_cache
                    )
                    pull_number = int(pull["number"])
                    final_head = pull["head"]["sha"]
                    pr_restored = restore_scope(
                        args, base, token, "pr", pull_number, {}, pr_cache,
                        final_head, True,
                    )
                    if main_restored and pr_restored:
                        try:
                            union_caches(main_cache, pr_cache, Path(args.cache))
                        except Exception as error:
                            print(f"cache: union-rejected pr={pull_number}: {error}; "
                                  "using main-only snapshot")
                            copy_cache(main_cache, Path(args.cache))
                    elif main_restored:
                        print(f"cache: squash-fallback pr={pull_number}: using main-only snapshot")
                        copy_cache(main_cache, Path(args.cache))
                    elif pr_restored:
                        print(f"cache: squash-fallback pr={pull_number}: using PR-only snapshot")
                        copy_cache(pr_cache, Path(args.cache))
                    else:
                        print("cache: cold build; neither squash source has a compatible snapshot")
    except ApiFailure as error:
        print(f"cache: API-error {error}; continuing uncached", file=sys.stderr)
    except Exception as error:
        print(f"cache: selection-error {error}; continuing uncached", file=sys.stderr)


def upload(args):
    started = time.monotonic()
    cache = Path(args.cache)
    archive = Path(args.archive)
    manifest_path = Path(args.manifest)
    try:
        report_action_logs(args.execution_log)
        stats = snapshot(cache, archive)
        manifest = make_manifest(args, archive)
        if manifest_path.exists() or manifest_path.is_symlink():
            raise Invalid("manifest output already exists")
        with manifest_path.open("x") as stream:
            stream.write(json.dumps(manifest, sort_keys=True) + "\n")
        identity = f"pr-{manifest['pullRequest']['number']}" if manifest["pullRequest"] else "main"
        name = f"{ARTIFACT_PREFIX}-{identity}-r{args.run_id}-a{args.run_attempt}"
        if args.output:
            Path(args.output).write_text(f"name={name}\n")
        print(f"cache: snapshot ready name={name} source={args.commit} "
              f"stats={json.dumps(stats)} totalSeconds={round(time.monotonic() - started, 3)} "
              f"peakRssBytes={resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024}")
    except Exception as error:
        print(f"cache: upload-preparation-error {error}; checks remain successful", file=sys.stderr)
        if args.output:
            Path(args.output).write_text("name=\n")


def report_action_logs(specifications):
    decoder = json.JSONDecoder()

    def iter_records(stream):
        buffer = ""
        buffered_bytes = 0
        eof = False
        while True:
            stripped = buffer.lstrip()
            removed = len(buffer) - len(stripped)
            if removed:
                buffered_bytes -= len(buffer[:removed].encode("utf-8"))
                buffer = stripped
            if not buffer:
                if eof:
                    return
                chunk = stream.read(MAX_ACTION_LOG_CHUNK_BYTES)
                if not chunk:
                    return
                buffer = chunk
                buffered_bytes = len(chunk.encode("utf-8"))
                continue
            try:
                value, end = decoder.raw_decode(buffer)
            except json.JSONDecodeError as error:
                if buffered_bytes > MAX_ACTION_LOG_RECORD_BYTES:
                    raise Invalid("action log record exceeds size limit") from error
                if eof:
                    raise Invalid("malformed action execution log") from error
                chunk = stream.read(MAX_ACTION_LOG_CHUNK_BYTES)
                if not chunk:
                    eof = True
                else:
                    buffer += chunk
                    buffered_bytes += len(chunk.encode("utf-8"))
                continue
            record_bytes = len(buffer[:end].encode("utf-8"))
            if record_bytes > MAX_ACTION_LOG_RECORD_BYTES:
                raise Invalid("action log record exceeds size limit")
            yield value
            buffer = buffer[end:]
            buffered_bytes -= record_bytes

    for specification in specifications:
        label, separator, filename = specification.partition("=")
        try:
            path = Path(filename)
            if not separator or not label or not path.is_file():
                raise Invalid("action log is unavailable")
            hits = 0
            executions = 0
            record_count = 0
            visited_nodes = 0
            with path.open(encoding="utf-8") as stream:
                for value in iter_records(stream):
                    pending = [value]
                    while pending:
                        item = pending.pop()
                        visited_nodes += 1
                        if visited_nodes > MAX_FILES:
                            raise Invalid("action execution log exceeds node-count limit")
                        if isinstance(item, dict):
                            if isinstance(item.get("cacheHit"), bool):
                                record_count += 1
                                hits += int(item["cacheHit"])
                                executions += int(not item["cacheHit"])
                            if record_count > MAX_FILES:
                                raise Invalid("action execution log exceeds record-count limit")
                            if len(pending) + len(item) > MAX_FILES:
                                raise Invalid("action execution log exceeds node-count limit")
                            pending.extend(item.values())
                        elif isinstance(item, list):
                            if len(pending) + len(item) > MAX_FILES:
                                raise Invalid("action execution log exceeds node-count limit")
                            pending.extend(item)
            print(f"cache: actions stage={label} hits={hits} executions={executions} "
                  f"records={record_count}")
        except (Invalid, OSError, UnicodeError, RecursionError):
            print(f"cache: actions stage={label or specification} unavailable")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("prepare-upload")
    create.add_argument("--cache", required=True)
    create.add_argument("--archive", required=True)
    create.add_argument("--manifest", required=True)
    create.add_argument("--event-path", required=True)
    create.add_argument("--event-name", required=True)
    create.add_argument("--repository", required=True)
    create.add_argument("--run-id", required=True)
    create.add_argument("--run-attempt", required=True)
    create.add_argument("--commit", required=True)
    create.add_argument("--pr-number", default="")
    create.add_argument("--output", default="")
    create.add_argument("--execution-log", action="append", default=[])
    restore = commands.add_parser("restore")
    restore.add_argument("--cache", required=True)
    restore.add_argument("--event-path", required=True)
    restore.add_argument("--event-name", required=True)
    restore.add_argument("--repository", required=True)
    restore.add_argument("--run-id", required=True)
    restore.add_argument("--run-number", required=True, type=int)
    restore.add_argument("--run-attempt", required=True)
    restore.add_argument("--commit", required=True)
    restore.add_argument("--pr-number", default="")
    cleanup = commands.add_parser("cleanup")
    cleanup.add_argument("--repository", required=True)
    args = parser.parse_args()
    if args.command == "prepare-upload":
        upload(args)
    elif args.command == "restore":
        discover_and_restore(args)
    else:
        token = os.environ.get("GITHUB_TOKEN")
        if not token:
            print("cleanup: API-error missing GITHUB_TOKEN; cleanup incomplete", file=sys.stderr)
            return 1
        return cleanup_artifacts(api_base(args.repository), token, args.repository)


if __name__ == "__main__":
    sys.exit(main() or 0)
