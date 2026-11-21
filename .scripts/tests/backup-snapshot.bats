#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture validate-backup-snapshot.py
}

@test "snapshot validation inventories opaque nested files and rejects unsafe archive members" {
  run python3 - << 'PY'
import hashlib
import importlib.util
import io
import tarfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("snapshot", ".scripts/validate-backup-snapshot.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def archive(entries, special=None):
    path = Path("fixture.tar")
    with tarfile.open(path, "w") as output:
        directories = {"/".join(name.split("/")[:index])
                       for name in entries for index in range(1, len(name.split("/")))}
        for name in sorted(directories):
                directory = tarfile.TarInfo(name)
                directory.type = tarfile.DIRTYPE
                output.addfile(directory)
        for name, content in entries.items():
            member = tarfile.TarInfo(name)
            if special:
                member.type = special
                member.linkname = "/outside"
                output.addfile(member)
            else:
                member.size = len(content)
                output.addfile(member, io.BytesIO(content))
    return str(path)

files = {"nested/deeper/opaque.data":b"\x00not a known storage format",
         "storage-version":b"47\n"}
inventory = module.validate(archive(files), require_storage_version=True)
assert inventory == [
    {"path":"nested/deeper/opaque.data", "sizeBytes":len(files["nested/deeper/opaque.data"]),
     "sha256":hashlib.sha256(files["nested/deeper/opaque.data"]).hexdigest()},
    {"path":"storage-version", "sizeBytes":3,
     "sha256":hashlib.sha256(b"47\n").hexdigest(), "storageVersion":47},
]
assert module.validate(archive({"unversioned.bin":b"anything"})) == [
    {"path":"unversioned.bin", "sizeBytes":8, "sha256":hashlib.sha256(b"anything").hexdigest()}
]

for entries, special in [
    ({"../escape":b"bad"}, None),
    ({"/absolute":b"bad"}, None),
    ({"nested\\escape":b"bad"}, None),
    ({"storage-version":b"1\n", ".":b"bad"}, None),
    ({"storage-version":b"47"}, None),
    ({"storage-version":b"0\n"}, None),
    ({"storage-version":b"4\n7\n"}, None),
    ({"nested/link":b""}, tarfile.SYMTYPE),
    ({"nested/hardlink":b""}, tarfile.LNKTYPE),
    ({"nested/fifo":b""}, tarfile.FIFOTYPE),
]:
    try:
        module.validate(archive(entries, special))
    except ValueError:
        pass
    else:
        raise AssertionError((entries, special))
PY
  [ "$status" -eq 0 ]
}
