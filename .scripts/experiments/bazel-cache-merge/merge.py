"""Bounded Bazel 8.5 SHA-256 disk-cache union; not a production artifact importer."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import tempfile
import time


class Invalid(ValueError):
    pass


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
            if wire == 2:
                size, offset = varint(data, offset)
            else:
                size = 8 if wire == 1 else 4
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


def digest(data):
    message = fields(data)
    if set(message) - {1, 2}:
        raise Invalid("unsupported Digest fields")
    value = one(message, 1, 2, b"").decode("ascii")
    size = one(message, 2, 0, 0)
    if not re.fullmatch("[0-9a-f]{64}", value) or size >= 2**63:
        raise Invalid("malformed SHA-256 Digest")
    return value, size


def references(data):
    message = fields(data)
    if set(message) - {2, 4, 5, 6, 7, 8, 9}:
        raise Invalid("unsupported ActionResult fields (directories/symlinks not supported)")
    if one(message, 4, 0, 0) != 0:
        raise Invalid("unsuccessful ActionResult")
    refs = []
    paths = set()
    for wire, output in message.get(2, []):
        if wire != 2:
            raise Invalid("malformed OutputFile")
        item = fields(output)
        if set(item) - {1, 2, 4}:
            raise Invalid("unsupported OutputFile fields")
        path = one(item, 1, 2, b"").decode("utf-8")
        if not path or path.startswith("/") or any(p in ("", ".", "..") for p in path.split("/")):
            raise Invalid("unsafe OutputFile path")
        if path in paths:
            raise Invalid("duplicate OutputFile path")
        paths.add(path)
        if one(item, 4, 0, 0) not in (0, 1):
            raise Invalid("malformed executable mode")
        refs.append(digest(one(item, 2, 2, b"")))
    for raw, hashed in ((5, 6), (7, 8)):
        one(message, raw, 2)
        if hashed in message:
            if raw in message:
                raise Invalid("ambiguous inline/digest stream")
            refs.append(digest(one(message, hashed, 2)))
    if 9 in message:
        fields(one(message, 9, 2))
    return refs


def snapshot(root):
    if root.is_symlink() or not root.is_dir():
        raise Invalid(f"not a snapshot directory: {root}")
    entries = {"ac": {}, "cas": {}}
    temporary = 0
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            rel = path.relative_to(root).parts
            if path.is_symlink():
                raise Invalid(f"symlink forbidden: {path}")
            if rel[0] == "tmp":
                if not (path.is_dir() or path.is_file()):
                    raise Invalid(f"unsupported temporary entry: {path}")
                if path.is_file():
                    temporary += 1
                continue
            if rel[0] not in entries:
                raise Invalid(f"unsupported layout: {path}")
            if len(rel) == 1 and path.is_dir():
                continue
            if len(rel) == 2 and path.is_dir() and re.fullmatch("[0-9a-f]{2}", rel[1]):
                continue
            if (len(rel) != 3 or not path.is_file()
                    or not re.fullmatch("[0-9a-f]{64}", rel[2]) or rel[1] != rel[2][:2]):
                raise Invalid(f"unsupported digest path: {path}")
            data = path.read_bytes()
            if rel[0] == "cas" and hashlib.sha256(data).hexdigest() != rel[2]:
                raise Invalid(f"CAS digest mismatch / conflicting bytes under hash: {path}")
            entries[rel[0]][rel[2]] = data
    for key, data in entries["ac"].items():
        try:
            for hashed, size in references(data):
                if size == 0 and hashed == hashlib.sha256(b"").hexdigest():
                    continue
                blob = entries["cas"].get(hashed)
                if blob is None or len(blob) != size:
                    raise Invalid(f"missing/wrong-size referenced blob {hashed}")
        except (ValueError, UnicodeError) as error:
            raise Invalid(f"invalid ActionResult {root}/ac/{key[:2]}/{key}: {error}") from error
    return entries, temporary


def merge(main, pr, destination):
    started = time.monotonic()
    if destination.exists() or destination.is_symlink():
        raise Invalid("destination must not exist")
    sources = [snapshot(main), snapshot(pr)]
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".cache-union-", dir=destination.parent))
    counts = {"identical": 0, "main_wins": 0, "temporary_excluded": sum(s[1] for s in sources)}
    try:
        for kind in ("ac", "cas"):
            combined = dict(sources[0][0][kind])
            for key, value in sources[1][0][kind].items():
                if key in combined:
                    if combined[key] == value:
                        counts["identical"] += 1
                    elif kind == "ac":
                        counts["main_wins"] += 1
                    else:
                        raise Invalid(f"conflicting CAS bytes under hash {key}")
                else:
                    combined[key] = value
            for key, value in combined.items():
                path = stage / kind / key[:2] / key
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(value)
            counts[kind] = len(combined)
        stage.rename(destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    counts["seconds"] = round(time.monotonic() - started, 6)
    return counts


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("main", type=Path)
    parser.add_argument("pr", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        print(merge(args.main, args.pr, args.destination))
    except (Invalid, OSError) as error:
        parser.exit(1, f"cache merge rejected: {error}\n")
