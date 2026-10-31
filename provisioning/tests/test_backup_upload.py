import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("backup_upload", ROOT / "files" / "backup-upload.py")
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)


def snapshot(path, files=None, backup_id="backup-20261031T100000-1", captured_at="2026-10-31T10:00:00Z",
             artifact="ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64, revision="a" * 40,
             mtime=1730000000, root_directory=False):
    files = files or {"recipes.sqlite3": b"sqlite data"}
    path.mkdir(parents=True)
    entries = []
    archive_path = path / "recipes.tar"
    with tarfile.open(archive_path, "w") as archive:
        if root_directory:
            root = tarfile.TarInfo(".")
            root.type = tarfile.DIRTYPE
            archive.addfile(root)
        for name, content in sorted(files.items()):
            member = tarfile.TarInfo(name)
            member.size = len(content)
            member.mtime = mtime
            archive.addfile(member, io.BytesIO(content))
            entries.append({"path": name, "sizeBytes": len(content),
                            "sha256": hashlib.sha256(content).hexdigest()})
    raw_archive = archive_path.read_bytes()
    manifest = {
        "format": "recipe-db-pvc-snapshot",
        "formatVersion": 1,
        "backupId": backup_id,
        "startedAt": "2026-10-31T09:59:00Z",
        "capturedAt": captured_at,
        "completedAt": "2026-10-31T10:01:00Z",
        "source": {"target": "pi", "cluster": "recipe-db-pi", "context": "recipe-db-pi",
                   "namespace": "recipe-db", "artifact": artifact, "revision": revision},
        "inventory": [{"service": "recipes", "role": "authoritative-read-only", "pvc": "recipes",
                       "archive": "recipes.tar", "sizeBytes": len(raw_archive), "fileCount": len(entries),
                       "sha256": hashlib.sha256(raw_archive).hexdigest(), "files": entries}],
    }
    (path / "manifest.json").write_bytes(backup.json_bytes(manifest))
    return path


class BackupUploadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.remote = self.root / "remote"
        self.remote.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.rclone_config = self.root / "rclone.conf"
        self.rclone_config.write_text("[fake]\ntype = local\n")
        self.rclone_config.chmod(0o600)
        self.state = self.root / "state"
        self.staging = self.root / "staging"
        self.config_path = self.root / "backup.json"
        self.config_path.write_text(json.dumps({
            "deploymentId": "recipe-db-pi",
            "remote": "fake:backups",
            "rcloneConfig": str(self.rclone_config),
            "stateDirectory": str(self.state),
            "stagingDirectory": str(self.staging),
            "captureCommand": str(self.root / "capture"),
            "maxStagingBytes": 256 * 1024**2,
            "captureTimeoutSeconds": 60,
        }))
        self.config_path.chmod(0o600)
        self.config = backup.safe_config(self.config_path)
        fake = self.bin / "rclone"
        fake.write_text("""#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys

args = sys.argv[1:]
action = args[0]
if os.environ.get("FAKE_RCLONE_FAIL") == action:
    print("SENSITIVE-RCLONE-ERROR", file=sys.stderr)
    raise SystemExit(9)
def remote_path(value):
    return Path(os.environ["FAKE_REMOTE"]) / value.split(":", 1)[1]
if action == "lsf":
    folder = remote_path(args[1])
    if not folder.is_dir():
        raise SystemExit(3)
    for child in sorted(folder.iterdir()):
        if child.is_file():
            print(child.name)
elif action == "mkdir":
    remote_path(args[1]).mkdir(parents=True, exist_ok=True)
elif action == "copyto":
    source, destination = Path(args[1]), remote_path(args[2])
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    if os.environ.get("FAKE_RCLONE_CORRUPT") == action:
        destination.write_bytes(b"corrupted remote bytes")
elif action == "cat":
    sys.stdout.buffer.write(remote_path(args[1]).read_bytes())
elif action == "deletefile":
    remote_path(args[1]).unlink()
else:
    raise SystemExit(2)
""")
        fake.chmod(0o755)
        self.env = patch.dict(os.environ, {"PATH": f"{self.bin}:{os.environ['PATH']}",
                                           "FAKE_REMOTE": str(self.remote)})
        self.env.start()
        self.addCleanup(self.env.stop)

    def tearDown(self):
        self.temp.cleanup()

    def make_snapshot(self, name="snapshot", **kwargs):
        return snapshot(self.root / name, **kwargs)

    def test_release_aware_fingerprint_ignores_capture_times_and_ids(self):
        first = self.make_snapshot("first")
        second = self.make_snapshot("second", backup_id="another-id",
                                    captured_at="2026-10-31T11:00:00Z", mtime=1760000000)
        release = self.make_snapshot("release", backup_id="release-id",
                                     artifact="ghcr.io/dhhyi/recipe-db-releases@sha256:" + "b" * 64,
                                     revision="b" * 40)
        self.assertEqual(backup.content_fingerprint(backup.validate_snapshot(first)),
                         backup.content_fingerprint(backup.validate_snapshot(second)))
        self.assertNotEqual(backup.content_fingerprint(backup.validate_snapshot(first)),
                            backup.content_fingerprint(backup.validate_snapshot(release)))

    def test_deterministic_package_and_inventory_add_delete(self):
        source = self.make_snapshot()
        manifest = backup.validate_snapshot(source)
        stage_a, stage_b = self.root / "stage-a", self.root / "stage-b"
        stage_a.mkdir()
        stage_b.mkdir()
        a = backup.create_package(source, stage_a, manifest, "recipe-db-pi", 64 * 1024**2)
        b = backup.create_package(source, stage_b, manifest, "recipe-db-pi", 64 * 1024**2)
        self.assertEqual((stage_a / a["archive"]).read_bytes(), (stage_b / b["archive"]).read_bytes())
        with tarfile.open(stage_a / a["archive"], "r:gz") as archive:
            self.assertEqual([member.name for member in archive], ["manifest.json", "recipes.tar"])
        added = self.make_snapshot("added", files={"new.json": b"{}", "recipes.sqlite3": b"sqlite data"})
        with_extra = self.make_snapshot("with-extra", files={"obsolete.json": b"[]",
                                                             "recipes.sqlite3": b"sqlite data"})
        deleted = self.make_snapshot("deleted", files={"recipes.sqlite3": b"sqlite data"})
        self.assertNotEqual(backup.content_fingerprint(manifest),
                            backup.content_fingerprint(backup.validate_snapshot(added)))
        self.assertNotEqual(backup.content_fingerprint(backup.validate_snapshot(with_extra)),
                            backup.content_fingerprint(backup.validate_snapshot(deleted)))

    def test_incomplete_and_corrupt_snapshots_are_rejected(self):
        incomplete = self.make_snapshot("incomplete")
        (incomplete / "backup-state.json").write_text('{"status":"in-progress"}')
        with self.assertRaises(ValueError):
            backup.validate_snapshot(incomplete)
        corrupted = self.make_snapshot("corrupted")
        (corrupted / "recipes.tar").write_bytes(b"corrupt")
        with self.assertRaises(ValueError):
            backup.validate_snapshot(corrupted)
        with self.assertRaises(backup.BackupError):
            backup.upload_snapshot(incomplete, self.config)
        self.assertEqual(backup.report_status(self.config)["status"], "capture-failure")

    def test_snapshot_root_directory_entry_is_accepted(self):
        source = self.make_snapshot(root_directory=True)
        self.assertEqual(backup.validate_snapshot(source)["backupId"], "backup-20261031T100000-1")

    def test_missing_check_record_is_overdue(self):
        self.assertEqual(backup.report_status(self.config)["status"], "overdue")

    def test_image_snapshot_with_owned_directories_is_accepted(self):
        image_dir = self.root / "image-snapshot"
        image_dir.mkdir()
        files = {"public/a.png": b"image", "manifests/a.json": b'{"recipeId":"a"}'}
        archive_path = image_dir / "images.tar"
        with tarfile.open(archive_path, "w") as archive:
            for name in ("public", "manifests"):
                directory = tarfile.TarInfo(name)
                directory.type = tarfile.DIRTYPE
                archive.addfile(directory)
            for name, content in sorted(files.items()):
                member = tarfile.TarInfo(name)
                member.size = len(content)
                archive.addfile(member, io.BytesIO(content))
        entries = [{"path": name, "sizeBytes": len(value), "sha256": hashlib.sha256(value).hexdigest()}
                   for name, value in sorted(files.items())]
        archive_bytes = archive_path.read_bytes()
        manifest = {
            "format": "recipe-db-pvc-snapshot", "formatVersion": 1, "backupId": "backup-images",
            "capturedAt": "2026-10-31T10:00:00Z",
            "source": {"target": "pi", "cluster": "recipe-db-pi", "context": "recipe-db-pi",
                       "namespace": "recipe-db", "artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64,
                       "revision": "a" * 40},
            "inventory": [{"service": "images", "role": "cleanup-participant", "pvc": "images",
                           "archive": "images.tar", "sizeBytes": len(archive_bytes), "fileCount": len(entries),
                           "sha256": hashlib.sha256(archive_bytes).hexdigest(), "files": entries}],
        }
        (image_dir / "manifest.json").write_bytes(backup.json_bytes(manifest))
        self.assertEqual(backup.validate_snapshot(image_dir), manifest)

    def test_verified_upload_then_unchanged_requires_remote_readback(self):
        first = self.make_snapshot()
        self.assertEqual(backup.upload_snapshot(first, self.config), "verified-upload")
        original_names = set((self.remote / "backups" / "recipe-db-pi").iterdir())
        baseline = backup.read_json(self.state / "baseline.json")
        (self.remote / "backups" / "recipe-db-pi" / baseline["archive"]).unlink()
        second = self.make_snapshot("second", backup_id="backup-20261031T110000-2",
                                    captured_at="2026-10-31T11:00:00Z")
        self.assertEqual(backup.upload_snapshot(second, self.config), "verified-upload")
        self.assertNotEqual(set((self.remote / "backups" / "recipe-db-pi").iterdir()), original_names)
        self.assertEqual(backup.upload_snapshot(
            self.make_snapshot("same", backup_id="backup-20261031T113000-3",
                               captured_at="2026-10-31T11:30:00Z"), self.config), "verified-unchanged")
        baseline = backup.read_json(self.state / "baseline.json")
        (self.remote / "backups" / "recipe-db-pi" / baseline["archive"]).write_bytes(b"corrupted")
        third = self.make_snapshot("third", backup_id="backup-20261031T120000-4",
                                   captured_at="2026-10-31T12:00:00Z")
        with self.assertRaises(backup.BackupError) as error:
            backup.upload_snapshot(third, self.config)
        self.assertEqual(error.exception.status, "retention-failure")
        self.assertEqual(backup.read_json(self.state / "baseline.json")["backupId"],
                         "backup-20261031T120000-4")
        remote_folder = self.remote / "backups" / "recipe-db-pi"
        (remote_folder / baseline["archive"]).unlink()
        (remote_folder / baseline["manifest"]).unlink()
        baseline = backup.read_json(self.state / "baseline.json")
        (self.remote / "backups" / "recipe-db-pi" / baseline["manifest"]).write_bytes(b"[]")
        baseline["manifestSizeBytes"] = 2
        baseline["manifestSha256"] = hashlib.sha256(b"[]").hexdigest()
        (self.state / "baseline.json").write_bytes(backup.json_bytes(baseline))
        fourth = self.make_snapshot("fourth", backup_id="backup-20261031T130000-5",
                                   captured_at="2026-10-31T13:00:00Z")
        self.assertEqual(backup.upload_snapshot(fourth, self.config), "verified-upload")

    def test_failed_upload_preserves_verified_baseline_and_hides_remote_diagnostics(self):
        self.assertEqual(backup.upload_snapshot(self.make_snapshot(), self.config), "verified-upload")
        baseline = (self.state / "baseline.json").read_bytes()
        changed = self.make_snapshot("changed", files={"recipes.sqlite3": b"changed"})
        with patch.dict(os.environ, {"FAKE_RCLONE_FAIL": "copyto"}):
            with self.assertRaises(backup.BackupError):
                backup.upload_snapshot(changed, self.config)
        self.assertEqual((self.state / "baseline.json").read_bytes(), baseline)
        status = backup.report_status(self.config)
        self.assertEqual(status["status"], "upload-failure")
        self.assertNotIn("SENSITIVE", json.dumps(status))

    def test_remote_integrity_failure_does_not_advance_baseline(self):
        self.assertEqual(backup.upload_snapshot(self.make_snapshot(), self.config), "verified-upload")
        baseline = (self.state / "baseline.json").read_bytes()
        changed = self.make_snapshot("changed", files={"recipes.sqlite3": b"changed"})
        with patch.dict(os.environ, {"FAKE_RCLONE_CORRUPT": "copyto"}):
            with self.assertRaises(backup.BackupError):
                backup.upload_snapshot(changed, self.config)
        self.assertEqual((self.state / "baseline.json").read_bytes(), baseline)
        self.assertEqual(backup.report_status(self.config)["status"], "upload-failure")

    def test_disk_full_staging_is_a_capture_failure(self):
        source = self.make_snapshot()
        manifest = backup.validate_snapshot(source)
        stage = self.root / "small-stage"
        stage.mkdir()
        with patch.object(backup.shutil, "disk_usage",
                          return_value=SimpleNamespace(free=0, total=0, used=0)):
            with self.assertRaises(backup.BackupError) as error:
                backup.create_package(source, stage, manifest, "recipe-db-pi", 64 * 1024**2)
        self.assertEqual(error.exception.code, "staging-space")
        with patch.object(backup.gzip, "GzipFile", side_effect=OSError("disk full")):
            with self.assertRaises(backup.BackupError) as error:
                backup.create_package(source, stage, manifest, "recipe-db-pi", 64 * 1024**2)
        self.assertEqual(error.exception.code, "staging-write")

    def seed_remote_points(self, count):
        folder = self.remote / "backups" / "recipe-db-pi"
        folder.mkdir(parents=True, exist_ok=True)
        for index in range(count):
            stamp = f"202601{index // 24 + 1:02d}T{index % 24:02d}0000Z"
            prefix = f"recipe-db-recipe-db-pi-{stamp}-backup-{index:04d}"
            archive_name = prefix + ".tar.gz"
            data = f"archive-{index}".encode()
            (folder / archive_name).write_bytes(data)
            document = {
                "format": "recipe-db-backup", "formatVersion": 1, "deploymentId": "recipe-db-pi",
                "backupId": f"backup-{index:04d}", "capturedAt": f"2026-01-{index // 24 + 1:02d}T{index % 24:02d}:00:00Z",
                "source": {"target": "pi", "cluster": "recipe-db-pi", "context": "recipe-db-pi",
                           "namespace": "recipe-db",
                           "artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64,
                           "revision": "a" * 40},
                "contentFingerprint": "b" * 64,
                "snapshotManifest": {
                    "format": "recipe-db-pvc-snapshot", "formatVersion": 1,
                    "backupId": f"backup-{index:04d}",
                    "capturedAt": f"2026-01-{index // 24 + 1:02d}T{index % 24:02d}:00:00Z",
                    "source": {"target": "pi", "cluster": "recipe-db-pi", "context": "recipe-db-pi",
                               "namespace": "recipe-db",
                               "artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64,
                               "revision": "a" * 40},
                    "inventory": [{"service": "recipes"}],
                },
                "archive": {"name": archive_name, "sizeBytes": len(data),
                            "sha256": hashlib.sha256(data).hexdigest()},
            }
            (folder / (prefix + ".manifest.json")).write_bytes(backup.json_bytes(document))
        malformed_prefix = "recipe-db-recipe-db-pi-20250101T000000Z-backup-malformed"
        (folder / (malformed_prefix + ".tar.gz")).write_text("unrecognized")
        (folder / (malformed_prefix + ".manifest.json")).write_bytes(backup.json_bytes({
            "format": "recipe-db-backup", "formatVersion": 1, "deploymentId": "recipe-db-pi",
            "backupId": "backup-malformed", "capturedAt": "2025-01-01T00:00:00Z",
            "archive": {"name": ["not", "a", "filename"], "sha256": "a" * 64, "sizeBytes": 1},
        }))
        (folder / "unrelated.txt").write_text("keep")
        (folder / "recipe-db-pi-orphan.tar.gz").write_text("incomplete")

    def test_retention_keeps_newest_30_and_preserves_unrelated_and_incomplete_files(self):
        self.seed_remote_points(31)
        self.assertEqual(backup.upload_snapshot(self.make_snapshot(), self.config), "verified-upload")
        folder = self.remote / "backups" / "recipe-db-pi"
        manifests = list(folder.glob("*.manifest.json"))
        archives = list(folder.glob("*.tar.gz"))
        self.assertEqual(len(manifests), 31)  # 30 complete points and one unrecognized manifest.
        self.assertEqual(len(archives), 32)  # Incomplete and malformed points are never pruned.
        self.assertTrue((folder / "unrelated.txt").exists())
        self.assertTrue((folder / "recipe-db-pi-orphan.tar.gz").exists())
        self.assertTrue((folder / "recipe-db-recipe-db-pi-20250101T000000Z-backup-malformed.manifest.json").exists())
        self.assertFalse((folder / "recipe-db-recipe-db-pi-20260101T000000Z-backup-0000.manifest.json").exists())
        self.assertFalse((folder / "recipe-db-recipe-db-pi-20260101T010000Z-backup-0001.manifest.json").exists())
        self.assertTrue((folder / "recipe-db-recipe-db-pi-20260101T020000Z-backup-0002.manifest.json").exists())
        self.assertTrue((folder / "recipe-db-recipe-db-pi-20260102T060000Z-backup-0030.tar.gz").exists())

    def test_retention_failure_keeps_verified_baseline_and_reports_separately(self):
        self.seed_remote_points(31)
        with patch.dict(os.environ, {"FAKE_RCLONE_FAIL": "deletefile"}):
            with self.assertRaises(backup.BackupError):
                backup.upload_snapshot(self.make_snapshot(), self.config)
        self.assertTrue((self.state / "baseline.json").is_file())
        self.assertEqual(backup.report_status(self.config)["status"], "retention-failure")

    def test_retention_aborts_before_deleting_when_newer_candidate_is_corrupt(self):
        self.seed_remote_points(31)
        folder = self.remote / "backups" / "recipe-db-pi"
        corrupt = folder / "recipe-db-recipe-db-pi-20260102T060000Z-backup-0030.tar.gz"
        corrupt.write_bytes(b"corrupted")
        oldest = folder / "recipe-db-recipe-db-pi-20260101T000000Z-backup-0000.manifest.json"
        with self.assertRaises(backup.BackupError) as error:
            backup.upload_snapshot(self.make_snapshot(), self.config)
        self.assertEqual(error.exception.status, "retention-failure")
        self.assertEqual(error.exception.code, "remote-point-integrity")
        self.assertTrue(oldest.exists())
        self.assertEqual(backup.report_status(self.config)["status"], "retention-failure")

    def test_stale_capture_deletes_only_explicitly_recovered_state(self):
        captures = self.state / "staging"
        captures.mkdir(parents=True)
        recovered = captures / "capture-recovered"
        recovered.mkdir()
        (recovered / "backup-state.json").write_text(
            '{"status":"failed","phase":"safely-recovered"}'
        )
        backup.reconcile_stale_captures(self.state)
        self.assertFalse(recovered.exists())

        unresolved = captures / "capture-unresolved"
        unresolved.mkdir()
        (unresolved / "backup-state.json").write_text('{"status":"in-progress"}')
        with self.assertRaises(backup.BackupError):
            backup.reconcile_stale_captures(self.state)
        self.assertTrue((self.state / "recovery-capture-unresolved" /
                         "capture-unresolved" / "backup-state.json").exists())

    def test_capture_restart_interrupt_and_overdue_statuses(self):
        command = Path(self.config["captureCommand"])
        command.write_text("#!/bin/sh\n[ \"$KUBECONFIG\" = /expected/private/kubeconfig ] || exit 2\nexit 1\n")
        command.chmod(0o755)
        with patch.dict(os.environ, {"KUBECONFIG": "/expected/private/kubeconfig"}):
            with self.assertRaises(backup.BackupError):
                backup.run_nightly(self.config)
        self.assertEqual(backup.report_status(self.config)["status"], "capture-failure")

        command.write_text("#!/bin/sh\nmkdir -p \"$1\"\nprintf '{\"status\":\"recovery-required\"}' > \"$1/backup-state.json\"\nexit 1\n")
        command.chmod(0o755)
        with self.assertRaises(backup.BackupError):
            backup.run_nightly(self.config)
        self.assertEqual(backup.report_status(self.config)["status"], "restart-failure")

        marker = self.root / "capture-was-started"
        command.write_text(f"#!/bin/sh\ntouch {marker}\n")
        command.chmod(0o755)
        with self.assertRaises(backup.BackupError):
            backup.run_nightly(self.config)
        self.assertFalse(marker.exists())

        for child in self.state.glob("recovery-*"):
            if child.is_dir():
                shutil.rmtree(child)
        sentinel = self.root / "capture-descendant-survived"
        command.write_text(
            "#!/bin/sh\n"
            "mkdir -p \"$1\"\n"
            "printf '{\"status\":\"in-progress\",\"phase\":\"prepared\"}' > \"$1/backup-state.json\"\n"
            f"(sleep 2; touch {sentinel}) &\n"
            "wait\n"
        )
        command.chmod(0o755)
        self.config["captureTimeoutSeconds"] = 1
        with self.assertRaises(backup.BackupError):
            backup.run_nightly(self.config)
        self.assertEqual(backup.report_status(self.config)["status"], "restart-failure")
        recovery_state = next(self.state.glob("recovery-*/capture-*/backup-state.json"))
        self.assertEqual(backup.read_json(recovery_state)["status"], "in-progress")
        time.sleep(2.2)
        self.assertFalse(sentinel.exists())

        backup.write_status(self.config, "verified-unchanged", "content-unchanged")
        path = self.state / "status.json"
        old = backup.read_json(path)
        old["lastCheck"] = "2026-10-29T00:00:00+00:00"
        path.write_bytes(backup.json_bytes(old))
        self.assertEqual(backup.report_status(self.config)["status"], "overdue")


if __name__ == "__main__":
    unittest.main()
