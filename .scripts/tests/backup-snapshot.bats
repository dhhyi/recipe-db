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
second_normal, second_thumb = b"second normal image", b"second thumbnail"
second_normal_name = "a-" + hashlib.sha256(second_normal).hexdigest() + ".png"
second_thumb_name = "a-" + hashlib.sha256(second_thumb).hexdigest() + "-thumb.png"
entry = {"recipeId":"a","url":"/public/"+normal_name,
    "thumbUrl":"/public/"+thumb_name,"size":len(normal)}
v2_entry = entry | {"id": hashlib.sha256(normal).hexdigest()}
v2_second_entry = {
    "recipeId":"a", "url":"/public/"+second_normal_name,
    "thumbUrl":"/public/"+second_thumb_name, "size":len(second_normal),
    "id":hashlib.sha256(second_normal).hexdigest(),
}
images = {"public/"+normal_name:normal, "public/"+thumb_name:thumb}
images_v2 = images | {
    "public/"+second_normal_name:second_normal,
    "public/"+second_thumb_name:second_thumb,
}
for version, manifest, image_files in (
    (1, entry, images),
    (2, [v2_entry, v2_second_entry], images_v2),
):
    values = image_files | {"manifests/a.json":json.dumps(manifest).encode(),
        "storage-version":f"{version}\n".encode()}
    assert len(module.validate(archive(values), {"kind":"images"})) == len(image_files) + 2
images = images | {"manifests/a.json":json.dumps(entry).encode(), "storage-version":b"1\n"}
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
    ({name:value for name,value in images.items() if name != "storage-version"}, {"kind":"images"}, False),
    (images | {"storage-version":b"3\n"}, {"kind":"images"}, False),
    (images | {"storage-version":b"2\n", "manifests/a.json":b"[]"}, {"kind":"images"}, False),
    (images | {"storage-version":b"2\n", "manifests/a.json":json.dumps(entry).encode()}, {"kind":"images"}, False),
    (images | {"storage-version":b"1\n", "manifests/a.json":json.dumps([entry]).encode()}, {"kind":"images"}, False),
    (images | {"storage-version":b"2\n", "manifests/a.json":json.dumps([v2_entry, v2_entry | {"recipeId":"b"}]).encode()}, {"kind":"images"}, False),
    (images | {"storage-version":b"2\n", "manifests/a.json":json.dumps([v2_entry, v2_second_entry | {"thumbUrl":"/public/missing.png"}]).encode()}, {"kind":"images"}, False),
    (images_v2 | {"storage-version":b"2\n", "manifests/a.json":json.dumps([v2_entry, v2_second_entry | {"size":len(second_normal)+1}]).encode()}, {"kind":"images"}, False),
    (images | {"storage-version":b"2\n", "manifests/a.json":json.dumps([v2_entry, v2_entry]).encode()}, {"kind":"images"}, False),
    (images | {"storage-version":b"2\n", "manifests/a.json":json.dumps([v2_entry] * 11).encode()}, {"kind":"images"}, False),
    (images | {"storage-version":b"2\n", "manifests/a.json":json.dumps([v2_entry | {"id":"0" * 64}]).encode()}, {"kind":"images"}, False),
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
