#!/usr/bin/env python3
"""Validate the declared authoritative layout of one read-only PVC archive."""

import hashlib
import json
from pathlib import PurePosixPath
import re
import sys
import tarfile
from urllib.parse import unquote


def validate(archive, layout):
    files = {}
    directories = set()
    inventory = []
    with tarfile.open(archive, "r:") as source:
        for member in source:
            name = member.name.removeprefix("./")
            if name in ("", ".") and member.isdir():
                continue
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or str(path) != name:
                raise ValueError("unsafe archive path")
            if member.isdir():
                if layout["kind"] != "images" or name not in ("public", "manifests"):
                    raise ValueError("unclassified archive directory")
                directories.add(name)
                continue
            if not member.isfile() or name in files:
                raise ValueError("archive contains a link, special file or duplicate")
            stream = source.extractfile(member)
            if stream is None:
                raise ValueError("archive file is unreadable")
            digest = hashlib.sha256()
            content = bytearray()
            keep_content = name.endswith(".json")
            first = b""
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
                if not first:
                    first = block[:16]
                if keep_content:
                    content.extend(block)
            files[name] = (member.size, digest.hexdigest(), bytes(content), first)
            inventory.append({"path": name, "sizeBytes": member.size, "sha256": digest.hexdigest()})
    kind = layout["kind"]
    if kind in ("sqlite", "json"):
        name = layout["file"]
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
            raise ValueError("unsafe declared database filename")
        allowed = {name}
        if kind == "sqlite":
            allowed.update({name + "-wal", name + "-shm", name + "-journal"})
        if name not in files or not set(files).issubset(allowed):
            raise ValueError("missing authoritative database or unclassified PVC data")
        if kind == "sqlite" and files[name][3] != b"SQLite format 3\x00":
            raise ValueError("authoritative database is not SQLite")
        if kind == "json":
            document = json.loads(files[name][2])
            if not isinstance(document, dict) and document != []:
                raise ValueError("authoritative JSON database is not an object or empty array")
    elif kind == "images":
        if directories != {"public", "manifests"}:
            raise ValueError("image PVC lacks its authoritative storage directories")
        selected = set()
        for path, (_, _, content, _) in files.items():
            if not path.startswith("manifests/") or not path.endswith(".json"):
                continue
            document = json.loads(content)
            recipe_id = PurePosixPath(path).name[:-5]
            if not recipe_id or len(recipe_id) > 128 or ".." in recipe_id or "\\" in recipe_id:
                raise ValueError("invalid image manifest recipe ID")
            if document["recipeId"] != recipe_id:
                raise ValueError("image manifest identity mismatch")
            selected.add(path)
            for field in ("url", "thumbUrl"):
                url = document[field]
                if not url.startswith("/public/"):
                    raise ValueError("invalid image manifest URL")
                name = unquote(url[len("/public/"):])
                suffix = "-thumb" if field == "thumbUrl" else ""
                match = re.fullmatch(re.escape(recipe_id) + r"-([0-9a-f]{64})" + suffix + r"\.png", name)
                output = "public/" + name
                if match is None or output not in files or files[output][1] != match[1]:
                    raise ValueError("image manifest references a missing or corrupt pair")
                if field == "url" and files[output][0] != document["size"]:
                    raise ValueError("image manifest size mismatch")
                selected.add(output)
        if selected != set(files):
            raise ValueError("image archive contains unselected or unclassified data")
    else:
        raise ValueError("unclassified authoritative layout")
    return sorted(inventory, key=lambda item: item["path"])


def main():
    if len(sys.argv) != 3:
        raise ValueError("usage: validate-backup-snapshot.py ARCHIVE LAYOUT_JSON")
    print(json.dumps(validate(sys.argv[1], json.loads(sys.argv[2]))))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, tarfile.TarError) as error:
        print(f"production: snapshot validation failed: {error}", file=sys.stderr)
        sys.exit(1)
