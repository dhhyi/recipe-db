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
        directories = {"/".join(name.split("/")[:index])
                       for name, _, kind in entries if not kind
                       for index in range(1, len(name.split("/")))}
        for name in sorted(directories):
            member = tarfile.TarInfo(name)
            member.type = tarfile.DIRTYPE
            tar.addfile(member)
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


def storage_marker(archive, content):
    entries = []
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source:
        for member in source:
            if member.isfile():
                entries.append((member.name, source.extractfile(member).read(), None))
    entries = [item for item in entries if item[0] != "storage-version"]
    entries.append(("storage-version", content, None))
    return tar_bytes(entries)


roles = {
    "recipes": "authoritative-read-only",
    "tags": "cleanup-participant",
    "images": "cleanup-participant",
    "inspirations": "cleanup-participant",
    "ratings": "cleanup-participant",
}
entries = {
    service: [
        ("nested/deeper/opaque.data", b"\x00opaque data for " + service.encode(), None),
        ("storage-version", b"2\n", None),
    ]
    for service in roles
}


def fixture(include_metadata=False):
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
        for item in files:
            if item["path"] == "storage-version":
                item["storageVersion"] = int(next(
                    content for name, content, kind in values
                    if name == "storage-version" and not kind
                ).strip())
        inventory.append({
            "service": service, "role": roles[service], "pvc": service,
            "archive": name, "sizeBytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "fileCount": len(files), "files": files,
        })
        if include_metadata:
            observed = module.snapshot.validate(capture / name, include_directories=True)
            inventory[-1]["directories"] = observed["directories"]
            inventory[-1]["directoryMetadata"] = observed["directoryMetadata"]
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
        {"name": service, "category": "backend", "backupRole": role}
        for service, role in roles.items()
    ] + [{"name": "graphql", "category": "api", "backupRole": "derived-stateless"},
         {"name": "link-extract", "category": "backend", "backupRole": "excluded-external-cache"},
         {"name": "browse", "category": "frontend"}]
    write(projects, b"".join(module.upload.json_bytes(item) for item in classifications))
    return case, metadata, archive, projects, manifest


def repack(metadata, archive, manifest=None, outer=None, inner=None, mode=None,
           inner_service="images", manifest_bytes=None):
    document = json.loads(metadata.read_bytes())
    manifest = manifest or document["snapshotManifest"]
    content = []
    for item in manifest["inventory"]:
        path = metadata.parent / "capture" / item["archive"]
        inner_data = inner.get(item["service"]) if isinstance(inner, dict) else (
            inner if item["service"] == inner_service else None
        )
        data = inner_data if inner_data is not None else path.read_bytes()
        if inner_data is not None:
            item["sizeBytes"] = len(data)
            item["sha256"] = hashlib.sha256(data).hexdigest()
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as source:
                files = []
                for member in source:
                    if member.isfile():
                        value = source.extractfile(member).read()
                        entry = {"path": member.name, "sizeBytes": len(value),
                                 "sha256": hashlib.sha256(value).hexdigest()}
                        if member.name == "storage-version":
                            entry["storageVersion"] = int(value.strip())
                        files.append(entry)
            item["files"] = sorted(files, key=lambda item: item["path"])
            item["fileCount"] = len(files)
        content.append((item["archive"], data, None))
    content.insert(0, ("manifest.json", manifest_bytes or module.upload.json_bytes(manifest), None))
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
    assert all((output / item["archive"]).read_bytes()
               == (case / "capture" / item["archive"]).read_bytes()
               for item in manifest["inventory"])
    assert module.upload.validate_snapshot(output) == manifest
    try:
        module.validate(str(metadata), str(archive), str(output), str(projects), "selected-backup")
    except ValueError:
        pass
    else:
        raise AssertionError("existing output accepted")
    assert module.upload.validate_snapshot(output) == manifest
    case, metadata, archive, projects, manifest = fixture(include_metadata=True)
    output = case / "snapshot"
    assert module.validate(str(metadata), str(archive), str(output), str(projects), "selected-backup") == manifest
    assert module.upload.validate_snapshot(output) == manifest
elif group == "manifest-size":
    case, metadata, archive, projects, manifest = fixture()
    expanded_manifest = json.dumps(manifest, indent=2).encode()
    repack(metadata, archive, manifest, manifest_bytes=expanded_manifest)
    expected = {"manifest.json": None} | {
        item["archive"]: item["sizeBytes"] for item in manifest["inventory"]
    }
    manifest_size = module.bundle_pass(archive, manifest, expected)
    assert manifest_size == len(expanded_manifest)
    input_size = sum(item["sizeBytes"] for item in manifest["inventory"])
    required = module.required_staging_bytes(input_size, manifest_size)
    expected_required = input_size * 2 + len(expanded_manifest) * 3 \
        + input_size // 100 + 1024 * 1024
    assert required == expected_required
    compact_required = module.required_staging_bytes(
        input_size, len(module.upload.json_bytes(manifest))
    )
    assert required > compact_required
    module.ensure_staging_limit(input_size, manifest_size, required)
    try:
        module.ensure_staging_limit(input_size, manifest_size, required - 1)
    except ValueError:
        pass
    else:
        raise AssertionError("accepted one byte below the uploader's staging requirement")
    original_limit_validator = module.upload.validate_max_staging_bytes
    module.upload.validate_max_staging_bytes = lambda value: value
    try:
        assert module.validate(
            str(metadata), str(archive), str(case / "snapshot-exact"), str(projects),
            "selected-backup", required
        ) == manifest
        under_limit_output = case / "snapshot-under"
        original_mkdir = Path.mkdir

        def guarded_mkdir(path, *args, **kwargs):
            if path == under_limit_output:
                raise AssertionError("validation created output before rejecting the staging limit")
            return original_mkdir(path, *args, **kwargs)

        Path.mkdir = guarded_mkdir
        try:
            module.validate(
                str(metadata), str(archive), str(under_limit_output), str(projects),
                "selected-backup", required - 1
            )
        except ValueError as error:
            assert str(error) == "staging limit exceeded"
        else:
            raise AssertionError("package validation accepted one byte below the requirement")
        finally:
            Path.mkdir = original_mkdir
        assert not under_limit_output.exists()
    finally:
        module.upload.validate_max_staging_bytes = original_limit_validator
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
    for mode in (0o4755, 0o2755, 0o1755):
        reject(lambda c, m, a, p, s, mode=mode: repack(m, a, mode=mode), before=True)
        reject(lambda c, m, a, p, s, mode=mode:
               repack(m, a, inner=tar_bytes(entries["images"], mode)))
    def root_archive(modes, owners=None, pax=False, name="."):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w") as archive:
            for index, mode in enumerate(modes):
                root = tarfile.TarInfo(name)
                root.type = tarfile.DIRTYPE
                root.mode = mode
                if owners:
                    root.uid, root.gid = owners
                if pax:
                    root.pax_headers = {"comment": "unsafe"}
                archive.addfile(root)
        return data.getvalue()
    for data in (root_archive([0o4755]), root_archive([0o755, 0o755]),
                 root_archive([0o755], owners=(2**32 - 1, 0)), root_archive([0o755], pax=True),
                 root_archive([0o755], name="/"), root_archive([0o755], name="////"),
                 root_archive([0o2770], name="nested")):
        reject(lambda c, m, a, p, s, data=data: repack(m, a, inner=data))
    # Files and directories have independent bounds.
    case, metadata, archive, projects, manifest = fixture()
    module.MAX_FILES = 2
    module.check_inner_bounds(case / "capture" / "images.tar")
    module.upload.MAX_DIRECTORIES = 1
    try:
        module.check_inner_bounds(case / "capture" / "images.tar")
    except ValueError:
        pass
    else:
        raise AssertionError("directory limit not enforced")
    module.upload.MAX_DIRECTORIES = 100_000
    module.MAX_FILES = 100_000
    for values in [
        entries["images"] + [("nested/deeper/opaque.data", b"duplicate", None)],
        entries["images"] + [("../escape", b"bad", None)],
        entries["images"] + [("/absolute", b"bad", None)],
        entries["images"] + [(".", b"bad", None)],
        entries["images"] + [("nested\\escape", b"bad", None)],
        entries["images"] + [("nested/link", b"", tarfile.SYMTYPE)],
        entries["images"] + [("nested/hardlink", b"", tarfile.LNKTYPE)],
        entries["images"] + [("nested/fifo", b"", tarfile.FIFOTYPE)],
        entries["images"] + [("nested", b"", tarfile.DIRTYPE)],
        [("parent", b"file", None), ("parent/child", b"file", None)],
    ]:
        reject(lambda c, m, a, p, s, values=values: repack(m, a, inner=tar_bytes(values)))
elif group == "storage":
    case, metadata, archive, projects, manifest = fixture()
    inners = {}
    for item in manifest["inventory"]:
        source = (case / "capture" / item["archive"]).read_bytes()
        inners[item["service"]] = storage_marker(source, b"47\n")
    repack(metadata, archive, manifest, inner=inners)
    output = case / "snapshot"
    module.validate(str(metadata), str(archive), str(output), str(projects), "selected-backup")
    for item in manifest["inventory"]:
        with tarfile.open(output / item["archive"], "r:") as restored:
            assert restored.extractfile("storage-version").read() == b"47\n"

    def malformed(c, m, a, p, s):
        recipes = next(item for item in s["inventory"] if item["service"] == "recipes")
        source = (c / "capture" / recipes["archive"]).read_bytes()
        repack(m, a, s, inner={"recipes": storage_marker(source, b"4")})
    reject(malformed)
elif group == "legacy-layout":
    case, metadata, archive, projects, manifest = fixture()
    for item in manifest["inventory"]:
        item["layout"] = {"kind": "sqlite", "file": "legacy.data"}
    repack(metadata, archive, manifest)
    output = case / "snapshot"
    validated = module.validate(str(metadata), str(archive), str(output), str(projects), "selected-backup")
    assert validated == manifest
    assert all("layout" not in item for item in json.loads(
        (output / "manifest.json").read_bytes()
    )["inventory"])

    def tamper_legacy_layout(c, m, a, p, s):
        for item in s["inventory"]:
            item["layout"] = {"kind": "json", "file": "changed"}
        document = json.loads(m.read_bytes())
        document["snapshotManifest"] = s
        bundle = [("manifest.json", module.upload.json_bytes(s), None)]
        bundle.extend(
            (item["archive"], (c / "capture" / item["archive"]).read_bytes(), None)
            for item in s["inventory"]
        )
        import gzip
        write(a, gzip.compress(tar_bytes(bundle), mtime=0))
        document["archive"]["sizeBytes"] = a.stat().st_size
        document["archive"]["sha256"] = module.upload.file_hash(a)
        write(m, module.upload.json_bytes(document))
    reject(tamper_legacy_layout, before=True)
else:
    raise AssertionError(group)
PY
  [ "$status" -eq 0 ]
}

@test "only a completed reopened recovery permits scheduling and archives operation-bound credentials" {
  run python3 - << 'PY'
import importlib.util
import json
from pathlib import Path

spec = importlib.util.spec_from_file_location("upload", "provisioning/files/backup-upload.py")
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)
root = Path.cwd() / "backup-state"
root.mkdir(mode=0o700)
maintenance = root / "maintenance"
maintenance.mkdir(mode=0o700)
config = {"stateDirectory": str(root)}
state = {
    "backupId": "recovery-1", "source": {"artifact": "previous"},
    "status": "recovered", "phase": "migration-recovered",
    "migrationRecovery": {"status": "verified", "candidateAborted": True},
}
def save():
    (maintenance / "backup-state.json").write_text(json.dumps(state))
save()
assert upload.maintenance_active(config)
state["phase"] = "migration-reopened"
state["migrationRecovery"]["status"] = "reopened"
save()
assert upload.maintenance_active(config)
state["migrationRecovery"]["ownershipReleasedAt"] = "2026-11-13T18:00:00Z"
save()
credentials = root / "maintenance.previous-runtime-secret.json"
credentials.write_text(json.dumps({
    "backupId": state["backupId"], "source": state["source"], "data": {"fixture": "secret"},
}))
credentials.chmod(0o600)
assert not upload.maintenance_active(config)
upload.archive_recovered_maintenance(config)
assert not maintenance.exists() and not credentials.exists()
archived = root / "maintenance-history" / state["backupId"]
assert (archived / "backup-state.json").is_file()
assert archived.with_name(archived.name + ".previous-runtime-secret.json").stat().st_mode & 0o777 == 0o600
assert not (archived / "previous-runtime-secret.json").exists()
maintenance.mkdir(mode=0o700)
(maintenance / "backup-state.json").write_text(json.dumps({
    "backupId": "next-operation", "status": "captured", "phase": "captured",
}))
assert upload.maintenance_active(config)
assert not credentials.exists()
PY
  [ "$status" -eq 0 ]
}

@test "backup package stages the complete selected pair privately and prints its snapshot manifest" {
  package_cases valid
}

@test "configured staging limit accepts sizes above the default without large fixtures" {
  run python3 - << 'PY'
import importlib.util

spec = importlib.util.spec_from_file_location("package", ".scripts/validate-backup-package.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
default = module.upload.DEFAULT_MAX_STAGING_BYTES
configured = 12 * 1024**3
maximum = 100 * 1024**3
size_above_default = default + 1

assert module.upload.validate_max_staging_bytes(configured) == configured
assert module.upload.validate_max_staging_bytes(maximum) == maximum
module.ensure_within_limit(size_above_default, configured, "too large")
for size, limit in ((size_above_default, default), (configured + 1, configured)):
    try:
        module.ensure_within_limit(size, limit, "too large")
    except ValueError:
        pass
    else:
        raise AssertionError(f"accepted {size} bytes under {limit}-byte limit")
try:
    module.upload.validate_max_staging_bytes(100 * 1024**3 + 1)
except ValueError:
    pass
else:
    raise AssertionError("accepted a staging limit above the existing 100 GiB maximum")
PY
  [ "$status" -eq 0 ]
}

@test "package validation accepts the Pi uploader's configured staging boundary" {
  run python3 - << 'PY'
import importlib.util
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("package", ".scripts/validate-backup-package.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
upload = module.upload
gigabyte = 1024**3
captured = "2026-11-01T12:34:56Z"
backup_id = "backup-20261101123456-1"
source = {
    "target": "pi", "cluster": "recipe-db-pi", "context": "recipe-db-pi",
    "namespace": "recipe-db", "artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64,
    "revision": "b" * 40,
}
roles = {
    "recipes": "authoritative-read-only", "images": "cleanup-participant",
    "inspirations": "cleanup-participant", "ratings": "cleanup-participant",
    "tags": "cleanup-participant",
}
sizes = [4 * gigabyte, gigabyte // 4, gigabyte // 4, gigabyte // 4, gigabyte // 4]
manifest = {
    "format": upload.FORMAT, "formatVersion": 1, "backupId": backup_id,
    "capturedAt": captured, "source": source, "inventory": [
        {"service": service, "role": role, "pvc": service, "archive": service + ".tar",
         "sizeBytes": size, "files": [], "fileCount": 0}
        for (service, role), size in zip(roles.items(), sizes)
    ],
}
digest = "c" * 64
archive_name = "recipe-db-pi-20261101T123456Z-" + backup_id + ".tar.gz"
package = {
    "format": upload.PACKAGE_FORMAT, "formatVersion": 1, "deploymentId": "pi",
    "backupId": backup_id, "capturedAt": captured, "source": source,
    "snapshotManifest": manifest,
    "archive": {"name": archive_name, "sizeBytes": gigabyte, "sha256": digest},
    "contentFingerprint": upload.content_fingerprint(manifest),
}
archive = SimpleNamespace(name=archive_name, stat=lambda: SimpleNamespace(st_size=gigabyte))
upload.file_hash = lambda _archive: digest
projects = dict(roles)
staging_limit = 12 * gigabyte
assert sum(sizes) == 5 * gigabyte
required = module.required_staging_bytes(sum(sizes), len(upload.json_bytes(manifest)))
expected_required = 2 * sum(sizes) + len(upload.json_bytes(manifest)) * 3 \
    + sum(sizes) // 100 + 1024**2
assert required == expected_required
assert required <= staging_limit
module.ensure_staging_limit(sum(sizes), len(upload.json_bytes(manifest)), staging_limit)
try:
    module.ensure_staging_limit(
        sum(sizes), len(upload.json_bytes(manifest)), upload.DEFAULT_MAX_STAGING_BYTES
    )
except ValueError:
    pass
else:
    raise AssertionError("accepted a Pi-sized package above the configured limit")
PY
  [ "$status" -eq 0 ]
}

@test "package staging boundary uses the exact embedded manifest size" {
  package_cases manifest-size
}

@test "backup package rejects corrupt identity, release, hashes and incomplete dataset without retaining staging" {
  package_cases identity
}

@test "backup package rejects unsafe outer and inner entries while allowing nested data" {
  package_cases unsafe
}

@test "backup package preserves any valid storage marker and rejects malformed markers" {
  package_cases storage
}

@test "backup package verifies legacy layout integrity before discarding it" {
  package_cases legacy-layout
}

@test "snapshot validation preserves actual storage versions and can require every marker" {
  mkdir -p marker-data
  printf 'opaque data' > marker-data/nested.data
  tar -C marker-data -cf versioned.tar nested.data
  run python3 .scripts/validate-backup-snapshot.py versioned.tar
  [ "$status" -eq 0 ]
  run python3 .scripts/validate-backup-snapshot.py --require-storage-version versioned.tar
  [ "$status" -ne 0 ]

  printf '47\n' > marker-data/storage-version
  tar -C marker-data -cf versioned.tar nested.data storage-version
  run python3 .scripts/validate-backup-snapshot.py --require-storage-version versioned.tar
  [ "$status" -eq 0 ]
  jq -e 'any(.[]; .path == "storage-version" and .storageVersion == 47)' \
    <<< "$output" > /dev/null

  printf '47' > marker-data/storage-version
  tar -C marker-data -cf versioned.tar nested.data storage-version
  run python3 .scripts/validate-backup-snapshot.py versioned.tar
  [ "$status" -ne 0 ]

  printf '0\n' > marker-data/storage-version
  tar -C marker-data -cf versioned.tar nested.data storage-version
  run python3 .scripts/validate-backup-snapshot.py versioned.tar
  [ "$status" -ne 0 ]
}
