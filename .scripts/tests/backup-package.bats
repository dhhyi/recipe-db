#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture validate-backup-package.py
  cp "$BATS_TEST_DIRNAME/../validate-backup-snapshot.py" .scripts/
  mkdir -p provisioning/files
  cp "$BATS_TEST_DIRNAME/../../provisioning/files/backup-upload.py" provisioning/files/
}

package_cases() {
  run python3 - "$1" << 'PY'
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile

spec = importlib.util.spec_from_file_location("package", ".scripts/validate-backup-package.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
root = Path.cwd() / "private"
root.mkdir(mode=0o700)
counter = 0


def write(path, content):
    path.write_bytes(content)
    path.chmod(0o600)


def tar_bytes(entries, mode=None):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, content, kind in entries:
            member = tarfile.TarInfo(name)
            if mode is not None:
                member.mode = mode
            if kind:
                member.type = kind
                member.linkname = "../outside"
                tar.addfile(member)
            else:
                member.size = len(content)
                tar.addfile(member, io.BytesIO(content))
    return output.getvalue()


normal, thumb = b"normal image", b"thumbnail"
normal_name = "a-" + hashlib.sha256(normal).hexdigest() + ".png"
thumb_name = "a-" + hashlib.sha256(thumb).hexdigest() + "-thumb.png"
image_files = [
    ("public", b"", tarfile.DIRTYPE),
    ("manifests", b"", tarfile.DIRTYPE),
    ("public/" + normal_name, normal, None),
    ("public/" + thumb_name, thumb, None),
    ("manifests/a.json", json.dumps({
        "recipeId": "a", "url": "/public/" + normal_name,
        "thumbUrl": "/public/" + thumb_name, "size": len(normal),
    }).encode(), None),
]
layouts = {
    "recipes": ("authoritative-read-only", {"kind": "sqlite", "file": "recipes.sqlite3"}),
    "tags": ("cleanup-participant", {"kind": "sqlite", "file": "tags.sqlite"}),
    "images": ("cleanup-participant", {"kind": "images"}),
    "inspirations": ("cleanup-participant", {"kind": "json", "file": "db.json"}),
    "ratings": ("cleanup-participant", {"kind": "sqlite", "file": "db.sqlite"}),
}
entries = {
    "recipes": [("recipes.sqlite3", b"SQLite format 3\x00recipes", None)],
    "tags": [("tags.sqlite", b"SQLite format 3\x00tags", None), ("tags.sqlite-wal", b"wal", None)],
    "images": image_files,
    "inspirations": [("db.json", b"{}", None)],
    "ratings": [("db.sqlite", b"SQLite format 3\x00ratings", None)],
}


def fixture():
    global counter
    counter += 1
    case = root / str(counter)
    case.mkdir(mode=0o700)
    capture = case / "capture"
    capture.mkdir(mode=0o700)
    inventory = []
    for service, values in entries.items():
        data = tar_bytes(values)
        name = service + ".tar"
        write(capture / name, data)
        files = sorted([
            {"path": name, "sizeBytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}
            for name, content, kind in values if not kind
        ], key=lambda item: item["path"])
        inventory.append({
            "service": service, "role": layouts[service][0], "pvc": service,
            "archive": name, "sizeBytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "fileCount": len(files), "files": files,
        })
    manifest = {
        "format": module.upload.FORMAT, "formatVersion": 1, "backupId": "selected-backup",
        "capturedAt": "2026-10-31T12:00:00Z",
        "source": {
            "target": "pi", "cluster": "recipe-db", "context": "pi", "namespace": "recipe-db",
            "artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64,
            "revision": "b" * 40,
        },
        "inventory": inventory,
    }
    write(capture / "manifest.json", module.upload.json_bytes(manifest))
    package_info = module.upload.create_package(capture, case, manifest, "pi", module.MAX_BYTES)
    archive = case / package_info["archive"]
    archive.chmod(0o600)
    metadata = case / package_info["manifest"]
    projects = case / "projects.jsonl"
    classifications = [
        {"name": service, "category": "backend", "backupRole": role, "backupData": layout}
        for service, (role, layout) in layouts.items()
    ] + [{"name": "graphql", "category": "api", "backupRole": "derived-stateless", "backupData": None},
         {"name": "link-extract", "category": "backend", "backupRole": "excluded-external-cache", "backupData": None},
         {"name": "browse", "category": "frontend"}]
    write(projects, b"".join(module.upload.json_bytes(item) for item in classifications))
    return case, metadata, archive, projects, manifest


def repack(metadata, archive, manifest=None, outer=None, inner=None, mode=None):
    document = json.loads(metadata.read_bytes())
    manifest = manifest or document["snapshotManifest"]
    content = []
    for item in manifest["inventory"]:
        path = metadata.parent / "capture" / item["archive"]
        data = inner if inner is not None and item["service"] == "images" else path.read_bytes()
        if inner is not None and item["service"] == "images":
            item["sizeBytes"] = len(data)
            item["sha256"] = hashlib.sha256(data).hexdigest()
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as source:
                files = []
                for member in source:
                    if member.isfile():
                        value = source.extractfile(member).read()
                        files.append({"path": member.name, "sizeBytes": len(value),
                                      "sha256": hashlib.sha256(value).hexdigest()})
            item["files"] = sorted(files, key=lambda item: item["path"])
            item["fileCount"] = len(files)
        content.append((item["archive"], data, None))
    content.insert(0, ("manifest.json", module.upload.json_bytes(manifest), None))
    if outer:
        content = outer(content)
    import gzip
    write(archive, gzip.compress(tar_bytes(content, mode), mtime=0))
    document["snapshotManifest"] = manifest
    document["contentFingerprint"] = module.upload.content_fingerprint(manifest)
    document["archive"]["sizeBytes"] = archive.stat().st_size
    document["archive"]["sha256"] = module.upload.file_hash(archive)
    write(metadata, module.upload.json_bytes(document))


def reject(change, before=False):
    case, metadata, archive, projects, manifest = fixture()
    output = case / "snapshot"
    change(case, metadata, archive, projects, manifest)
    original_mkdir = Path.mkdir
    def guarded_mkdir(path, *args, **kwargs):
        if before and path == output:
            raise AssertionError("outer validation created staging")
        return original_mkdir(path, *args, **kwargs)
    Path.mkdir = guarded_mkdir
    try:
        try:
            module.validate(str(metadata), str(archive), str(output), str(projects), "selected-backup")
        except (ValueError, KeyError, TypeError, OSError, tarfile.TarError):
            assert not output.exists(), "failed validation left staging"
        else:
            raise AssertionError("corrupt package accepted")
    finally:
        Path.mkdir = original_mkdir


def update(metadata, key, value):
    document = json.loads(metadata.read_bytes())
    document[key] = value
    write(metadata, module.upload.json_bytes(document))


group = sys.argv[1]
if group == "valid":
    case, metadata, archive, projects, manifest = fixture()
    output = case / "snapshot"
    result = subprocess.run([
        sys.executable, ".scripts/validate-backup-package.py", str(metadata), str(archive),
        str(output), str(projects), "selected-backup",
    ], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == manifest
    assert output.stat().st_mode & 0o777 == 0o700
    assert {path.name for path in output.iterdir()} == {"manifest.json"} | {
        item["archive"] for item in manifest["inventory"]
    }
    assert all(path.stat().st_mode & 0o777 == 0o600 for path in output.iterdir())
    assert module.upload.validate_snapshot(output) == manifest
    try:
        module.validate(str(metadata), str(archive), str(output), str(projects), "selected-backup")
    except ValueError:
        pass
    else:
        raise AssertionError("existing output accepted")
    assert module.upload.validate_snapshot(output) == manifest
elif group == "identity":
    for key, value in [
        ("format", "other"), ("formatVersion", 2), ("formatVersion", True),
        ("backupId", "other"), ("deploymentId", "../pi"), ("contentFingerprint", "0" * 64),
        ("source", {}), ("capturedAt", "2026-10-31"),
    ]:
        reject(lambda c, m, a, p, s, k=key, v=value: update(m, k, v), before=True)
    for key, value in [("name", "../archive.tar.gz"), ("sizeBytes", 1), ("sha256", "0" * 64)]:
        def change(c, m, a, p, s, key=key, value=value):
            document = json.loads(m.read_bytes())
            document["archive"][key] = value
            write(m, module.upload.json_bytes(document))
        reject(change, before=True)
    reject(lambda c, m, a, p, s: write(a, a.read_bytes()[:-10]), before=True)
    reject(lambda c, m, a, p, s: m.chmod(0o644), before=True)
    reject(lambda c, m, a, p, s: a.chmod(0o644), before=True)
    reject(lambda c, m, a, p, s: p.chmod(0o644), before=True)
    reject(lambda c, m, a, p, s: c.chmod(0o755), before=True)
    def hardlink(c, m, a, p, s):
        import os
        os.link(a, c / "other-name")
    reject(hardlink, before=True)
    def symlink(c, m, a, p, s):
        moved = c / "moved"
        a.rename(moved)
        a.symlink_to(moved)
    reject(symlink, before=True)
    def release(c, m, a, p, s):
        s["source"]["artifact"] = "ghcr.io/dhhyi/recipe-db-releases:latest"
        repack(m, a, s)
        update(m, "source", s["source"])
    reject(release, before=True)
    def missing(c, m, a, p, s):
        s["inventory"].pop()
        repack(m, a, s)
    reject(missing, before=True)
    def duplicate_service(c, m, a, p, s):
        s["inventory"][1]["service"] = "recipes"
        repack(m, a, s)
    reject(duplicate_service, before=True)
    def wrong_role(c, m, a, p, s):
        s["inventory"][0]["role"] = "cleanup-participant"
        repack(m, a, s)
    reject(wrong_role, before=True)
    def duplicate_projects(c, m, a, p, s):
        write(p, p.read_bytes() + p.read_bytes().splitlines(keepends=True)[0])
    reject(duplicate_projects, before=True)
    def classifications(c, m, a, p, s, transform):
        rows = [transform(json.loads(line)) for line in p.read_bytes().splitlines()]
        write(p, b"".join(module.upload.json_bytes(row) for row in rows))
    for transform in [
        lambda row: {key: value for key, value in row.items() if key != "category"},
        lambda row: {key: value for key, value in row.items() if key != "backupRole"},
        lambda row: row | {"backupRole": "cleanup-participant"}
                    if row.get("backupRole") == "authoritative-read-only" else row,
        lambda row: row | {"backupRole": "derived-stateless"}
                    if row.get("backupRole") == "cleanup-participant" else row,
        lambda row: row | {"backupRole": "authoritative-read-only"}
                    if row["name"] == "tags" else row,
    ]:
        reject(lambda c, m, a, p, s, transform=transform:
               classifications(c, m, a, p, s, transform), before=True)
    def arbitrary_archive(c, m, a, p, s):
        item = s["inventory"][0]
        (c / "capture" / item["archive"]).rename(c / "capture" / "arbitrary.tar")
        item["archive"] = "arbitrary.tar"
        repack(m, a, s)
    reject(arbitrary_archive, before=True)
    def arbitrary_claim(c, m, a, p, s):
        s["inventory"][0]["pvc"] = "arbitrary"
        repack(m, a, s)
    reject(arbitrary_claim, before=True)
    def embedded(c, m, a, p, s):
        s["source"]["cluster"] = "different"
        repack(m, a, s)
    reject(embedded, before=True)
    def inner_hash(c, m, a, p, s):
        s["inventory"][0]["sha256"] = "0" * 64
        repack(m, a, s)
    reject(inner_hash)
    def file_hash(c, m, a, p, s):
        s["inventory"][0]["files"][0]["sha256"] = "0" * 64
        repack(m, a, s)
    reject(file_hash)
    def unsafe_inventory(c, m, a, p, s):
        s["inventory"][0]["files"][0]["path"] = "../escape"
        repack(m, a, s)
    reject(unsafe_inventory)
    def invalid_database(c, m, a, p, s):
        write(c / "capture" / "recipes.tar", tar_bytes([("recipes.sqlite3", b"not SQLite", None)]))
        item = s["inventory"][0]
        data = (c / "capture" / item["archive"]).read_bytes()
        item["sizeBytes"] = len(data)
        item["sha256"] = hashlib.sha256(data).hexdigest()
        item["files"][0]["sizeBytes"] = len(b"not SQLite")
        item["files"][0]["sha256"] = hashlib.sha256(b"not SQLite").hexdigest()
        repack(m, a, s)
    reject(invalid_database)
    original_limit = module.MAX_BYTES
    def bounded(*args):
        module.MAX_BYTES = 100
    reject(bounded, before=True)
    module.MAX_BYTES = original_limit
elif group == "unsafe":
    for name, kind in [
        ("../escape", None), ("/absolute", None), ("./recipes.tar", None),
        ("unexpected", None), ("directory", tarfile.DIRTYPE),
        ("recipes.tar", tarfile.SYMTYPE), ("recipes.tar", tarfile.LNKTYPE),
        ("recipes.tar", tarfile.FIFOTYPE), ("recipes.tar", tarfile.CHRTYPE),
    ]:
        reject(lambda c, m, a, p, s, n=name, k=kind:
               repack(m, a, outer=lambda items: items + [(n, b"bad", k)]), before=True)
    reject(lambda c, m, a, p, s: repack(m, a, outer=lambda items: items + [items[1]]), before=True)
    reject(lambda c, m, a, p, s: repack(m, a, outer=lambda items: items[:-1]), before=True)
    def trailing(c, m, a, p, s):
        import gzip
        data = gzip.decompress(a.read_bytes()) + tar_bytes([("hidden", b"hidden", None)])
        write(a, gzip.compress(data, mtime=0))
        document = json.loads(m.read_bytes())
        document["archive"]["sizeBytes"] = a.stat().st_size
        document["archive"]["sha256"] = module.upload.file_hash(a)
        write(m, module.upload.json_bytes(document))
    reject(trailing, before=True)
    reject(lambda c, m, a, p, s: repack(m, a, inner=tar_bytes(image_files)
           + tar_bytes([("public/hidden", b"hidden", None)])))
    for mode in (0o4755, 0o2755, 0o1755):
        reject(lambda c, m, a, p, s, mode=mode: repack(m, a, mode=mode), before=True)
        reject(lambda c, m, a, p, s, mode=mode: repack(m, a, inner=tar_bytes(image_files, mode)))
    for values in [
        [value for value in image_files if value[0] != "public/" + thumb_name],
        image_files + [("public/old.png", b"old", None)],
        image_files + [("public", b"", tarfile.DIRTYPE)],
        image_files + [image_files[-1]],
        image_files + [("../escape", b"bad", None)],
        image_files + [("/absolute", b"bad", None)],
        image_files + [("public/link", b"", tarfile.SYMTYPE)],
        image_files + [("public/hardlink", b"", tarfile.LNKTYPE)],
        image_files + [("public/fifo", b"", tarfile.FIFOTYPE)],
        image_files + [("extra", b"", tarfile.DIRTYPE)],
        [value if value[0] != "public/" + normal_name else (value[0], b"corrupt", None)
         for value in image_files],
    ]:
        reject(lambda c, m, a, p, s, values=values: repack(m, a, inner=tar_bytes(values)))
else:
    raise AssertionError(group)
PY
  [ "$status" -eq 0 ]
}

@test "backup package stages the complete selected pair privately and prints its snapshot manifest" {
  package_cases valid
}

@test "backup package rejects corrupt identity, release, hashes and incomplete dataset without retaining staging" {
  package_cases identity
}

@test "backup package rejects unsafe outer and inner entries and incomplete image pairs" {
  package_cases unsafe
}
