#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture validate-backup-snapshot.py
}

@test "snapshot validation covers SQLite sidecars, JSON, image pairs and unsafe or missing data" {
  run python3 - << 'PY'
import hashlib
import importlib.util
import io
import json
import tarfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("snapshot", ".scripts/validate-backup-snapshot.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def archive(entries, link=False):
    path = Path("fixture.tar")
    with tarfile.open(path, "w") as output:
        if any(name.startswith(("public/", "manifests/")) for name in entries):
            for name in ("public", "manifests"):
                directory = tarfile.TarInfo(name)
                directory.type = tarfile.DIRTYPE
                output.addfile(directory)
        for name, content in entries.items():
            member = tarfile.TarInfo(name)
            if link:
                member.type = tarfile.SYMTYPE
                member.linkname = "/etc/passwd"
                output.addfile(member)
            else:
                member.size = len(content)
                output.addfile(member, io.BytesIO(content))
    return str(path)

sqlite = {"kind":"sqlite", "file":"tags.sqlite"}
files = {"tags.sqlite":b"SQLite format 3\x00database", "tags.sqlite-wal":b"wal", "tags.sqlite-shm":b"shm"}
assert len(module.validate(archive(files), sqlite)) == 3
for document in (b"{}", b"[]", b'{"recipe":["https://example.com"]}'):
    assert len(module.validate(archive({"db.json":document}), {"kind":"json","file":"db.json"})) == 1
normal, thumb = b"normal image", b"thumbnail"
normal_name = "a-" + hashlib.sha256(normal).hexdigest() + ".png"
thumb_name = "a-" + hashlib.sha256(thumb).hexdigest() + "-thumb.png"
images = {"public/"+normal_name:normal, "public/"+thumb_name:thumb,
    "manifests/a.json":json.dumps({"recipeId":"a","url":"/public/"+normal_name,
        "thumbUrl":"/public/"+thumb_name,"size":len(normal)}).encode()}
assert len(module.validate(archive(images), {"kind":"images"})) == 3
for entries, layout, link in [
    ({}, sqlite, False),
    ({"tags.sqlite":b"not sqlite"}, sqlite, False),
    (files | {"secret":b"credentials"}, sqlite, False),
    (files | {"../escape":b"bad"}, sqlite, False),
    (files | {"/absolute":b"bad"}, sqlite, False),
    (files, sqlite, True),
    ({}, {"kind":"json","file":"db.json"}, False),
    ({"db.json":b"["}, {"kind":"json","file":"db.json"}, False),
    ({"db.json":b'[{"recipe":[]}]'}, {"kind":"json","file":"db.json"}, False),
    ({"db.json":b'["https://example.com"]'}, {"kind":"json","file":"db.json"}, False),
    ({"db.json":b"[[]]"}, {"kind":"json","file":"db.json"}, False),
    ({"db.json":b"null"}, {"kind":"json","file":"db.json"}, False),
    ({"db.json":b"false"}, {"kind":"json","file":"db.json"}, False),
    ({"db.json":b"0"}, {"kind":"json","file":"db.json"}, False),
    ({"db.json":b'""'}, {"kind":"json","file":"db.json"}, False),
    ({name:value for name,value in images.items() if name != "public/"+thumb_name}, {"kind":"images"}, False),
    (images | {"public/old.png":b"old"}, {"kind":"images"}, False),
    (images | {"public/"+normal_name:b"corrupted"}, {"kind":"images"}, False),
    ({}, {"kind":"images"}, False),
]:
    try:
        module.validate(archive(entries, link), layout)
    except (ValueError, KeyError):
        pass
    else:
        raise AssertionError((entries, layout, link))
PY
  [ "$status" -eq 0 ]
}
