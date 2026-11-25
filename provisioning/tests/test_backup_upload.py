import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
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
             mtime=1730000000, root_directory=False, directories=None, directory_metadata=None):
    files = files or {"nested/opaque.data": b"opaque data"}
    path.mkdir(parents=True)
    entries = []
    archive_path = path / "recipes.tar"
    with tarfile.open(archive_path, "w") as archive:
        if root_directory:
            root = tarfile.TarInfo(".")
            root.type = tarfile.DIRTYPE
            for key, value in (directory_metadata or {}).get(".", {}).items():
                setattr(root, key, value)
            archive.addfile(root)
        for name in sorted(directories or []):
            member = tarfile.TarInfo(name)
            member.type = tarfile.DIRTYPE
            member.mtime = mtime
            for key, value in (directory_metadata or {}).get(name, {}).items():
                setattr(member, key, value)
            archive.addfile(member)
        for name, content in sorted(files.items()):
            member = tarfile.TarInfo(name)
            member.size = len(content)
            member.mtime = mtime
            archive.addfile(member, io.BytesIO(content))
            entry = {"path": name, "sizeBytes": len(content),
                     "sha256": hashlib.sha256(content).hexdigest()}
            if name == "storage-version":
                entry["storageVersion"] = int(content.strip())
            entries.append(entry)
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
    if directories is not None:
        manifest["inventory"][0]["directories"] = sorted(directories)
    if directory_metadata is not None:
        with tarfile.open(archive_path, "r:") as archive:
            manifest["inventory"][0]["directoryMetadata"] = sorted(
                ({"path": member.name, "mode": member.mode, "uid": member.uid, "gid": member.gid}
                 for member in archive if member.isdir()), key=lambda item: item["path"])
    (path / "manifest.json").write_bytes(backup.json_bytes(manifest))
    return path


class BackupUploadTests(unittest.TestCase):
    def test_status_reports_restore_capture_without_a_check_record(self):
        capture_state = self.state / "restore-captures" / "backup-20261101120000-1"
        capture_state.mkdir(parents=True)
        backup.restore_capture_write(
            capture_state / "restore-capture-state.json",
            "backup-20261101120000-1", "restore-holder", "lease-uid-1",
            "upload-failed", "upload-pending", backupId="backup-20261101120100-2",
        )

        status = backup.report_status(self.config)

        self.assertEqual(status["code"], "no-check-record")
        self.assertEqual(status["restoreCapture"]["status"], "upload-failed")
        self.assertEqual(status["restoreCapture"]["phase"], "upload-pending")
        self.assertEqual(status["restoreCapture"]["backupId"], "backup-20261101120100-2")

    def test_status_reports_installed_closeout_capability_not_cached_capability(self):
        self.assertEqual(backup.report_status(self.config)["migrationRecoveryCloseoutVersion"], 1)
        backup.ensure_private_dir(self.state)
        backup.atomic_json(backup.status_path(self.config), ["invalid"])
        self.assertEqual(backup.report_status(self.config)["migrationRecoveryCloseoutVersion"], 1)
        backup.atomic_json(backup.status_path(self.config),
                           {"migrationRecoveryCloseoutVersion": 99})
        self.assertEqual(backup.report_status(self.config)["migrationRecoveryCloseoutVersion"], 1)

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
        systemctl = self.bin / "systemctl"
        self.systemctl_log = self.root / "systemctl.log"
        systemctl.write_text(f"""#!/usr/bin/env python3
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with Path({str(self.systemctl_log)!r}).open("a") as log:
    log.write(" ".join(args) + "\\n")
if args[:1] == ["show"]:
    print(os.environ.get("FAKE_BACKUP_SERVICE_ACTIVE", "inactive"))
    raise SystemExit(0)
if args[:2] == ["disable", "--now"] and os.environ.get("FAKE_TIMER_DISABLE_FAIL") == "true":
    raise SystemExit(1)
raise SystemExit(0)
""")
        systemctl.chmod(0o755)
        self.env = patch.dict(os.environ, {"PATH": f"{self.bin}:{os.environ['PATH']}",
                                           "FAKE_REMOTE": str(self.remote)})
        self.env.start()
        self.addCleanup(self.env.stop)

    def tearDown(self):
        self.temp.cleanup()

    def make_snapshot(self, name="snapshot", **kwargs):
        return snapshot(self.root / name, **kwargs)

    def test_restore_capture_records_a_distinct_completed_backup(self):
        restore_id = "backup-20261101120000-1"
        holder = "restore-holder"
        lease_uid = "lease-uid-1"
        backup_id = "backup-20261101120100-2"
        capture_state = backup.restore_capture_path(self.config, restore_id)
        capture_state.mkdir(mode=0o700)
        backup.restore_capture_write(
            capture_state / "restore-capture-state.json", restore_id, holder, lease_uid,
            "capture-failed", "capture", failureCode="operator-retry",
        )

        def capture(config, action, path, operation_id, operation_holder, operation_uid, confirmation):
            self.assertEqual(action, "restore-capture")
            self.assertEqual((operation_id, operation_holder, operation_uid),
                             (restore_id, holder, lease_uid))
            self.assertEqual(confirmation, f"CAPTURE-RESTORE-{restore_id}-{holder}")
            backup.restore_capture_write(
                Path(path) / "restore-capture-state.json", restore_id, holder, lease_uid,
                "complete", "maintenance", backupId=backup_id,
            )

        with patch.object(backup, "backup_timer_disabled") as timer_check, \
                patch.object(backup, "run_capture_command", side_effect=capture):
            result = backup.run_restore_capture_action(
                self.config, "restore-capture", restore_id, holder, lease_uid,
                f"CAPTURE-RESTORE-{restore_id}-{holder}",
            )

        timer_check.assert_not_called()
        self.assertNotEqual(result["restoreBackupId"], result["backupId"])
        self.assertEqual((result["status"], result["phase"]), ("complete", "maintenance"))

    def test_restore_upload_retry_resumes_interrupted_state_without_recapture(self):
        restore_id = "backup-20261101120000-1"
        holder = "restore-holder"
        lease_uid = "lease-uid-1"
        capture_state = backup.restore_capture_path(self.config, restore_id)
        capture_state.mkdir(mode=0o700)
        backup.restore_capture_write(
            capture_state / "restore-capture-state.json", restore_id, holder, lease_uid,
            "capture-failed", "capture", backupId="backup-20261101120100-2",
        )

        def resume(config, action, path, operation_id, operation_holder, operation_uid, confirmation):
            self.assertEqual(action, "restore-upload-retry")
            self.assertEqual((operation_id, operation_holder, operation_uid),
                             (restore_id, holder, lease_uid))
            self.assertEqual(confirmation, f"RETRY-UPLOAD-RESTORE-{restore_id}-{holder}")
            backup.restore_capture_write(
                Path(path) / "restore-capture-state.json", restore_id, holder, lease_uid,
                "upload-verified", "maintenance-pending",
                backupId="backup-20261101120100-2",
            )

        with patch.object(backup, "subprocess") as subprocess_mock, \
                patch.object(backup, "run_capture_command", side_effect=resume):
            subprocess_mock.run.side_effect = [
                SimpleNamespace(returncode=1, stdout="disabled\n"),
                SimpleNamespace(returncode=3, stdout="inactive\n"),
            ]
            result = backup.run_restore_capture_action(
                self.config, "restore-upload-retry", restore_id, holder, lease_uid,
                f"RETRY-UPLOAD-RESTORE-{restore_id}-{holder}",
            )

        self.assertEqual((result["status"], result["phase"]),
                         ("upload-verified", "maintenance-pending"))

    def test_restore_upload_retry_accepts_interruption_before_failure_recording(self):
        restore_id = "backup-20261101120000-1"
        holder = "restore-holder"
        lease_uid = "lease-uid-1"
        backup_id = "backup-20261101120100-2"
        capture_state = backup.restore_capture_path(self.config, restore_id)
        capture_state.mkdir(mode=0o700)
        state_path = capture_state / "restore-capture-state.json"
        backup.restore_capture_write(
            state_path, restore_id, holder, lease_uid, "upload-pending", "upload-pending",
            backupId=backup_id,
        )

        def resume(config, action, path, operation_id, operation_holder, operation_uid, confirmation):
            self.assertEqual(action, "restore-upload-retry")
            backup.restore_capture_write(
                Path(path) / "restore-capture-state.json", restore_id, holder, lease_uid,
                "upload-verified", "maintenance-pending", backupId=backup_id,
            )

        with patch.object(backup, "subprocess") as subprocess_mock, \
                patch.object(backup, "run_capture_command", side_effect=resume):
            subprocess_mock.run.side_effect = [
                SimpleNamespace(returncode=1, stdout="disabled\n"),
                SimpleNamespace(returncode=3, stdout="inactive\n"),
            ]
            result = backup.run_restore_capture_action(
                self.config, "restore-upload-retry", restore_id, holder, lease_uid,
                f"RETRY-UPLOAD-RESTORE-{restore_id}-{holder}",
            )

        self.assertEqual((result["status"], result["phase"]),
                         ("upload-verified", "maintenance-pending"))

    def test_restore_maintenance_resume_does_not_recapture(self):
        restore_id = "backup-20261101120000-1"
        holder = "restore-holder"
        lease_uid = "lease-uid-1"
        backup_id = "backup-20261101120100-2"
        capture_state = backup.restore_capture_path(self.config, restore_id)
        capture_state.mkdir(mode=0o700)
        backup.restore_capture_write(
            capture_state / "restore-capture-state.json", restore_id, holder, lease_uid,
            "maintenance-failed", "maintenance-pending", backupId=backup_id,
        )

        def resume(config, action, path, operation_id, operation_holder, operation_uid, confirmation):
            self.assertEqual(action, "restore-maintenance-resume")
            self.assertEqual((operation_id, operation_holder, operation_uid),
                             (restore_id, holder, lease_uid))
            self.assertEqual(confirmation, f"RESUME-MAINTENANCE-RESTORE-{restore_id}-{holder}")
            backup.restore_capture_write(
                Path(path) / "restore-capture-state.json", restore_id, holder, lease_uid,
                "complete", "maintenance", backupId=backup_id,
            )

        with patch.object(backup, "subprocess") as subprocess_mock, \
                patch.object(backup, "run_capture_command", side_effect=resume):
            subprocess_mock.run.side_effect = [
                SimpleNamespace(returncode=1, stdout="disabled\n"),
                SimpleNamespace(returncode=3, stdout="inactive\n"),
            ]
            result = backup.run_restore_capture_action(
                self.config, "restore-maintenance-resume", restore_id, holder, lease_uid,
                f"RESUME-MAINTENANCE-RESTORE-{restore_id}-{holder}",
            )

        self.assertEqual((result["status"], result["phase"]), ("complete", "maintenance"))

    def test_restore_maintenance_resume_recovers_completion_before_lease_update(self):
        restore_id = "backup-20261101120000-1"
        holder = "restore-holder"
        lease_uid = "lease-uid-1"
        backup_id = "backup-20261101120100-2"
        capture_state = backup.restore_capture_path(self.config, restore_id)
        capture_state.mkdir(mode=0o700)
        backup.restore_capture_write(
            capture_state / "restore-capture-state.json", restore_id, holder, lease_uid,
            "complete", "maintenance", backupId=backup_id,
        )

        with patch.object(backup, "subprocess") as subprocess_mock, \
                patch.object(backup, "run_capture_command") as resume:
            subprocess_mock.run.side_effect = [
                SimpleNamespace(returncode=1, stdout="disabled\n"),
                SimpleNamespace(returncode=3, stdout="inactive\n"),
            ]
            result = backup.run_restore_capture_action(
                self.config, "restore-maintenance-resume", restore_id, holder, lease_uid,
                f"RESUME-MAINTENANCE-RESTORE-{restore_id}-{holder}",
            )

        resume.assert_called_once()
        self.assertEqual((result["status"], result["phase"]), ("complete", "maintenance"))

    def test_restore_upload_retry_refuses_already_completed_capture(self):
        restore_id = "backup-20261101120000-1"
        holder = "restore-holder"
        lease_uid = "lease-uid-1"
        capture_state = backup.restore_capture_path(self.config, restore_id)
        capture_state.mkdir(mode=0o700)
        backup.restore_capture_write(
            capture_state / "restore-capture-state.json", restore_id, holder, lease_uid,
            "complete", "maintenance", backupId="backup-20261101120100-2",
        )

        with patch.object(backup, "run_capture_command") as capture:
            with self.assertRaisesRegex(backup.BackupError, "restore-capture-phase-mismatch"):
                backup.run_restore_capture_action(
                    self.config, "restore-upload-retry", restore_id, holder, lease_uid,
                    f"RETRY-UPLOAD-RESTORE-{restore_id}-{holder}",
                )

        capture.assert_not_called()

    def test_backup_timer_check_refuses_unavailable_status(self):
        with patch.object(backup, "subprocess") as subprocess_mock, \
                patch.object(backup, "run_capture_command") as capture:
            subprocess_mock.run.return_value.returncode = 4
            subprocess_mock.run.return_value.stdout = ""
            with self.assertRaisesRegex(backup.BackupError, "backup-timer-status-failed"):
                backup.backup_timer_disabled()

        capture.assert_not_called()

    def test_backup_timer_check_refuses_unknown_inactive_response(self):
        with patch.object(backup, "subprocess") as subprocess_mock, \
                patch.object(backup, "run_capture_command") as capture:
            subprocess_mock.run.side_effect = [
                SimpleNamespace(returncode=1, stdout="disabled\n"),
                SimpleNamespace(returncode=3, stdout="unknown\n"),
            ]
            with self.assertRaisesRegex(backup.BackupError, "backup-timer-status-failed"):
                backup.backup_timer_disabled()

        capture.assert_not_called()

    def test_restore_maintenance_failure_preserves_verified_upload_for_resume(self):
        restore_id = "backup-20261101120000-1"
        holder = "restore-holder"
        lease_uid = "lease-uid-1"
        backup_id = "backup-20261101120100-2"
        capture_state = backup.restore_capture_path(self.config, restore_id)
        capture_state.mkdir(mode=0o700)
        state_path = capture_state / "restore-capture-state.json"
        backup.restore_capture_write(
            state_path, restore_id, holder, lease_uid,
            "maintenance-failed", "maintenance-pending", backupId=backup_id,
        )
        snapshot_path = snapshot(capture_state / "snapshot", backup_id=backup_id)
        manifest = backup.read_json(snapshot_path / "manifest.json")
        capture = {
            "stateVersion": 2, "backupId": backup_id, "status": "maintenance-mode",
            "phase": "maintenance-entered", "source": manifest["source"],
            "restoreOperation": {
                "backupId": restore_id, "holder": holder, "leaseUid": lease_uid,
            },
        }
        backup.atomic_json(snapshot_path / "backup-state.json", capture)
        backup.write_status(self.config, "verified-upload", "remote-readback", backup_id)
        self.assertEqual(backup.read_json(backup.status_path(self.config))["status"], "verified-upload")
        self.assertTrue((capture_state / "snapshot" / "manifest.json").is_file())
        self.assertEqual(backup.read_json(state_path)["backupId"], backup_id)
        self.assertEqual(backup.lifecycle_state(snapshot_path)["restoreOperation"], capture["restoreOperation"])
        self.assertEqual(backup.read_json(snapshot_path / "manifest.json")["source"], capture["source"])
        self.assertIsNotNone(backup.protected_restore_verified_upload(self.config))

        def resume(config, action, path, operation_id, operation_holder, operation_uid, confirmation):
            backup.restore_capture_write(
                state_path, restore_id, holder, lease_uid,
                "maintenance-failed", "maintenance-pending", backupId=backup_id,
            )
            raise backup.BackupError("maintenance-failure", "maintenance-resume-interrupted")

        with patch.object(backup, "subprocess") as subprocess_mock, \
                patch.object(backup, "run_capture_command", side_effect=resume):
            subprocess_mock.run.side_effect = [
                SimpleNamespace(returncode=1, stdout="disabled\n"),
                SimpleNamespace(returncode=3, stdout="inactive\n"),
            ]
            with self.assertRaisesRegex(backup.BackupError, "maintenance-resume-interrupted"):
                backup.run_restore_capture_action(
                    self.config, "restore-maintenance-resume", restore_id, holder, lease_uid,
                    f"RESUME-MAINTENANCE-RESTORE-{restore_id}-{holder}",
                )

        self.assertTrue(backup.verified_upload_status(self.config, backup_id))
        attempt = backup.read_json(backup.status_path(self.config).with_name("maintenance-attempt.json"))
        self.assertEqual(attempt["backupId"], backup_id)
        self.assertEqual(attempt["restoreBackupId"], restore_id)
        self.assertEqual(attempt["code"], "maintenance-resume-interrupted")

    def test_restore_upload_does_not_prune_previous_release_backup(self):
        snapshot_path = self.make_snapshot()
        with patch.object(backup, "prune") as prune:
            result = backup.upload_snapshot(
                snapshot_path, self.config, force_upload=True, preserve_remote_points=True,
            )

        self.assertEqual(result, "verified-upload")
        prune.assert_not_called()

    def test_restore_publish_uploads_the_complete_capture_snapshot(self):
        restore_id = "backup-20261101120000-1"
        backup_id = "backup-20261101120100-2"
        snapshot_path = (
            self.state / "restore-captures" / restore_id / "snapshot"
        )
        snapshot(snapshot_path, backup_id=backup_id)
        manifest = backup.read_json(snapshot_path / "manifest.json")
        backup.atomic_json(snapshot_path / "backup-state.json", {
            "stateVersion": 2,
            "backupId": backup_id,
            "status": "backup-mode",
            "phase": "upload-pending",
            "source": manifest["source"],
            "restoreOperation": {
                "backupId": restore_id,
                "holder": "restore-holder",
                "leaseUid": "lease-uid-1",
            },
        })

        with patch.dict(os.environ, {"RECIPE_DB_RESTORE_CAPTURE_ACTIVE": "1"}), \
                patch.object(backup, "prune") as prune:
            result = backup.run_restore_publish(self.config, snapshot_path)

        self.assertEqual(result, "verified-upload")
        self.assertTrue(backup.verified_upload_status(self.config, backup_id))
        prune.assert_not_called()

    def test_restore_upload_retry_records_enabled_timer_refusal(self):
        restore_id = "backup-20261101120000-1"
        holder = "restore-holder"
        lease_uid = "lease-uid-1"
        confirmation = f"RETRY-UPLOAD-RESTORE-{restore_id}-{holder}"
        capture_state = backup.restore_capture_path(self.config, restore_id)
        capture_state.mkdir(mode=0o700)
        state_path = capture_state / "restore-capture-state.json"
        backup.restore_capture_write(
            state_path, restore_id, holder, lease_uid, "upload-pending", "upload-pending",
            backupId="backup-20261101120100-2",
        )

        with patch.object(backup, "backup_timer_disabled",
                          side_effect=backup.BackupError("capture-failure", "backup-timer-enabled")), \
                patch.object(backup, "run_capture_command") as capture:
            with self.assertRaisesRegex(backup.BackupError, "backup-timer-enabled"):
                backup.run_restore_capture_action(
                    self.config, "restore-upload-retry", restore_id, holder, lease_uid, confirmation,
                )

        capture.assert_not_called()
        state = backup.read_json(state_path)
        self.assertEqual((state["status"], state["phase"]), ("upload-pending", "upload-pending"))
        self.assertEqual(state["failureCode"], "backup-timer-enabled")
        self.assertEqual(backup.read_json(backup.status_path(self.config))["code"],
                         "backup-timer-enabled")

    def test_check_timer_cli_verifies_the_timer(self):
        with patch.object(backup, "safe_config", return_value=self.config), \
                patch.object(backup, "ensure_private_dir"), \
                patch.object(backup, "backup_timer_disabled") as timer_check, \
                patch.object(backup.signal, "signal"), \
                patch.object(sys, "argv", ["backup-upload.py", "check-timer",
                                           "--config", str(self.config_path)]):
            self.assertEqual(backup.main(), 0)

        timer_check.assert_called_once_with()

    def test_normal_service_captures_candidate_and_retries_failed_upload_without_recapture(self):
        self.write_maintenance_capture()
        candidate = "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "b" * 64
        maintenance = backup.ensure_private_dir(self.state / "maintenance")
        release_snapshot = maintenance / "post-release-backup"
        reference = self.root / "backup-release-ref"
        reference.write_text(candidate + "\n")
        state = {
            "backupId": "backup-1-2", "status": "access-open", "phase": "website-passed",
            "source": {"artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64},
            "candidate": {"artifact": candidate, "revision": "b" * 40},
            "backupAlignment": {"artifact": candidate, "revision": "b" * 40},
            "websiteCheck": {"outcome": "passed"},
        }
        backup.atomic_json(maintenance / "backup-state.json", state)

        def capture(config, action, path, artifact):
            self.assertEqual((action, path, artifact), ("release-capture", maintenance, candidate))
            snapshot(release_snapshot, files={"recipes.sqlite3": b"data", "storage-version": b"2\n"},
                     backup_id="backup-3-4", artifact=candidate, revision="b" * 40)
            saved = dict(state, phase="post-release-backup-captured", postReleaseBackup={
                "status": "captured", "artifact": candidate, "backupId": "backup-3-4",
                "snapshotPath": str(release_snapshot),
            })
            backup.atomic_json(maintenance / "backup-state.json", saved)

        with patch.object(backup, "RELEASE_REFERENCE_PATH", reference), \
                patch.object(backup, "run_capture_command", side_effect=capture) as worker:
            with patch.dict(os.environ, {"FAKE_RCLONE_FAIL": "copyto"}):
                with self.assertRaises(backup.BackupError):
                    backup.run_nightly(self.config)
            self.assertEqual(worker.call_count, 1)
            self.assertTrue(release_snapshot.is_dir())
            self.assertEqual(backup.run_nightly(self.config), "verified-upload")
            self.assertEqual(worker.call_count, 1)
        saved = backup.lifecycle_state(maintenance)
        self.assertEqual(saved["source"], state["source"])
        self.assertEqual(saved["postReleaseBackup"]["uploadStatus"], "verified-upload")
        self.assertTrue(backup.report_status(self.config)["maintenanceActive"])
        self.assertEqual(backup.report_status(self.config)["backupId"], "backup-3-4")

    def test_normal_service_refuses_unaccepted_or_unaligned_candidate_before_capture(self):
        self.write_maintenance_capture()
        maintenance = backup.ensure_private_dir(self.state / "maintenance")
        candidate = "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "b" * 64
        reference = self.root / "backup-release-ref"
        reference.write_text("old release\n")
        state = {
            "backupId": "backup-1-2", "status": "access-open", "phase": "website-passed",
            "source": {"artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64},
            "candidate": {"artifact": candidate}, "websiteCheck": {"outcome": "passed"},
        }
        with patch.object(backup, "RELEASE_REFERENCE_PATH", reference), \
                patch.object(backup, "run_capture_command") as worker:
            backup.atomic_json(maintenance / "backup-state.json", state)
            with self.assertRaisesRegex(backup.BackupError, "inputs-not-aligned"):
                backup.run_nightly(self.config)
            reference.write_text(candidate + "\n")
            state["websiteCheck"]["outcome"] = "failed"
            backup.atomic_json(maintenance / "backup-state.json", state)
            with self.assertRaisesRegex(backup.BackupError, "gates-incomplete"):
                backup.run_nightly(self.config)
            worker.assert_not_called()
        self.assertFalse((self.remote / "backups").exists())

    def test_release_upload_requires_passed_website_and_changed_versioned_artifact(self):
        candidate = "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "b" * 64
        backup_id = "backup-20261110T100000-42"
        maintenance = self.state / "maintenance"
        release_snapshot = maintenance / "post-release-backup"
        snapshot(
            release_snapshot,
            files={"recipes.sqlite3": b"sqlite data", "storage-version": b"2\n"},
            backup_id=backup_id,
            artifact=candidate,
            revision="b" * 40,
        )
        maintenance.mkdir(parents=True, exist_ok=True)
        state = {
            "stateVersion": 2,
            "status": "access-open",
            "phase": "post-release-backup-captured",
            "source": {"artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64},
            "candidate": {"artifact": candidate},
            "websiteCheck": {"outcome": "failed"},
            "postReleaseBackup": {
                "status": "captured", "artifact": candidate, "backupId": backup_id,
                "snapshotPath": str(release_snapshot),
            },
        }
        backup.atomic_json(maintenance / "backup-state.json", state)

        with self.assertRaisesRegex(backup.BackupError, "release-gates-incomplete"):
            backup.run_release_upload(self.config)
        state["postCheckDisposition"] = {"choice": "accept-partial-failure"}
        backup.atomic_json(maintenance / "backup-state.json", state)
        self.assertEqual(backup.run_release_upload(self.config), "verified-upload")
        uploaded = backup.read_json(maintenance / "backup-state.json")
        self.assertEqual(uploaded["postReleaseBackup"]["uploadStatus"], "verified-upload")
        status = backup.read_json(backup.status_path(self.config))
        self.assertEqual(status["backupId"], backup_id)
        self.assertEqual(status["status"], "verified-upload")
        self.assertEqual(backup.run_release_upload(self.config), "verified-upload")

    def test_release_upload_rejects_missing_storage_version_before_remote_write(self):
        candidate = "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "b" * 64
        backup_id = "backup-20261110T100000-43"
        maintenance = self.state / "maintenance"
        release_snapshot = maintenance / "post-release-backup"
        snapshot(
            release_snapshot,
            backup_id=backup_id,
            artifact=candidate,
            revision="b" * 40,
        )
        maintenance.mkdir(parents=True, exist_ok=True)
        backup.atomic_json(maintenance / "backup-state.json", {
            "stateVersion": 2,
            "status": "access-open",
            "phase": "post-release-backup-captured",
            "source": {"artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64},
            "candidate": {"artifact": candidate},
            "websiteCheck": {"outcome": "passed"},
            "postReleaseBackup": {
                "status": "captured", "artifact": candidate, "backupId": backup_id,
                "snapshotPath": str(release_snapshot),
            },
        })

        with self.assertRaisesRegex(backup.BackupError, "invalid-release-snapshot"):
            backup.run_release_upload(self.config)
        self.assertFalse((self.remote / "backups").exists())

    def write_maintenance_capture(self):
        command = Path(self.config["captureCommand"])
        command.write_text(f"""#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import sys
import tarfile

action, path = sys.argv[1:]
path = Path(path)
with Path({str(self.root / "capture-actions.log")!r}).open("a") as log:
    log.write(action + "\\n")
backup_id = "backup-20261110T100000-42"
artifact = "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64
revision = "a" * 40
state_path = path / "backup-state.json"
if action == "maintenance-enter":
    path.mkdir(mode=0o700)
    state_path.write_text(json.dumps({{
        "stateVersion": 2, "backupId": backup_id, "status": "maintenance-mode",
        "phase": "maintenance-entered",
        "source": {{"artifact": artifact, "revision": revision}},
    }}))
    raise SystemExit(0)
if action == "maintenance-restore":
    state = json.loads(state_path.read_text())
    state["phase"] = "restoration-pending"
    state_path.write_text(json.dumps(state))
    if Path({str(self.root / "fail-restore")!r}).exists():
        raise SystemExit(1)
    state["status"] = "captured"
    state["phase"] = "captured"
    state["maintenanceRestored"] = True
    state_path.write_text(json.dumps(state))
    raise SystemExit(0)
if action != "maintenance-capture":
    raise SystemExit(2)
state = json.loads(state_path.read_text())
data = b"sqlite data"
with tarfile.open(path / "recipes.tar", "w") as archive:
    import io
    member = tarfile.TarInfo("recipes.sqlite3")
    member.size = len(data)
    archive.addfile(member, io.BytesIO(data))
archive_path = path / "recipes.tar"
manifest = {{
    "format": "recipe-db-pvc-snapshot", "formatVersion": 1,
    "backupId": backup_id, "capturedAt": "2026-11-10T10:00:00Z",
    "source": {{"target": "pi", "cluster": "recipe-db-pi", "context": "recipe-db-pi",
        "namespace": "recipe-db", "artifact": artifact, "revision": revision}},
    "inventory": [{{
        "service": "recipes", "role": "authoritative-read-only", "pvc": "recipes",
        "archive": "recipes.tar", "sizeBytes": archive_path.stat().st_size,
        "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
        "fileCount": 1, "files":[{{"path":"recipes.sqlite3","sizeBytes":len(data),
            "sha256":hashlib.sha256(data).hexdigest()}}],
        "storage": {{"uid":"claim-recipes","volumeName":"pv-recipes",
            "storageClassName":"local-path","requestedStorage":"1Gi","capacity":"1Gi",
            "accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem"}},
    }}],
}}
(path / "manifest.json").write_text(json.dumps(manifest))
state["status"] = "backup-mode"
state["phase"] = "upload-pending"
state_path.write_text(json.dumps(state))
""")
        command.chmod(0o755)

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
        added = self.make_snapshot("added", files={"nested/new.data": b"new", "opaque.data": b"opaque"})
        with_extra = self.make_snapshot("with-extra", files={"nested/obsolete.data": b"old",
                                                             "opaque.data": b"opaque"})
        deleted = self.make_snapshot("deleted", files={"opaque.data": b"opaque"})
        self.assertNotEqual(backup.content_fingerprint(manifest),
                            backup.content_fingerprint(backup.validate_snapshot(added)))
        self.assertNotEqual(backup.content_fingerprint(backup.validate_snapshot(with_extra)),
                            backup.content_fingerprint(backup.validate_snapshot(deleted)))

    def test_empty_directory_changes_trigger_upload_without_timestamp_churn(self):
        first = self.make_snapshot("directory-first", directories=["empty"])
        later = self.make_snapshot("directory-later", directories=["empty"], mtime=1760000000,
                                   backup_id="later")
        removed = self.make_snapshot("directory-removed", directories=[], backup_id="removed")
        added = self.make_snapshot("directory-added", directories=["another", "empty"], backup_id="added")
        fingerprints = [backup.content_fingerprint(backup.validate_snapshot(path))
                        for path in (first, later, removed, added)]
        self.assertEqual(fingerprints[0], fingerprints[1])
        self.assertNotEqual(fingerprints[0], fingerprints[2])
        self.assertNotEqual(fingerprints[0], fingerprints[3])
        self.assertEqual(backup.upload_snapshot(first, self.config), "verified-upload")
        self.assertEqual(backup.upload_snapshot(later, self.config), "verified-unchanged")
        self.assertEqual(backup.upload_snapshot(removed, self.config), "verified-upload")
        self.assertEqual(backup.upload_snapshot(added, self.config), "verified-upload")
        manifest = json.loads((first / "manifest.json").read_text())
        manifest["inventory"][0]["directories"] = []
        (first / "manifest.json").write_bytes(backup.json_bytes(manifest))
        with self.assertRaisesRegex(ValueError, "directory inventory mismatch"):
            backup.validate_snapshot(first)

    def test_directory_metadata_changes_trigger_upload_without_timestamp_churn(self):
        first = self.make_snapshot("metadata-first", root_directory=True, directories=["nested"],
                                   directory_metadata={})
        later = self.make_snapshot("metadata-later", root_directory=True, directories=["nested"],
                                   directory_metadata={}, mtime=1760000000)
        first_fingerprint = backup.content_fingerprint(backup.validate_snapshot(first))
        self.assertEqual(first_fingerprint, backup.content_fingerprint(backup.validate_snapshot(later)))
        self.assertEqual(backup.upload_snapshot(first, self.config), "verified-upload")
        self.assertEqual(backup.upload_snapshot(later, self.config), "verified-unchanged")
        for path, key, value in [(".", "mode", 0o700), ("nested", "mode", 0o700),
                                 ("nested", "uid", 123), ("nested", "gid", 456)]:
            name = f"metadata-{path.replace('.', 'root')}-{key}"
            changed = self.make_snapshot(name, backup_id=name,
                                         root_directory=True, directories=["nested"],
                                         directory_metadata={path: {key: value}})
            self.assertNotEqual(first_fingerprint, backup.content_fingerprint(backup.validate_snapshot(changed)))
            self.assertEqual(backup.upload_snapshot(changed, self.config), "verified-upload")
        manifest = json.loads((first / "manifest.json").read_text())
        manifest["inventory"][0]["directoryMetadata"][0]["uid"] = 123
        (first / "manifest.json").write_bytes(backup.json_bytes(manifest))
        with self.assertRaisesRegex(ValueError, "directory metadata mismatch"):
            backup.validate_snapshot(first)
        typed = self.make_snapshot("metadata-typed", directories=["nested"],
                                   directory_metadata={"nested": {"uid": 1}})
        manifest = json.loads((typed / "manifest.json").read_text())
        manifest["inventory"][0]["directoryMetadata"][0]["uid"] = True
        (typed / "manifest.json").write_bytes(backup.json_bytes(manifest))
        with self.assertRaisesRegex(ValueError, "directory metadata mismatch"):
            backup.validate_snapshot(typed)

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

    def test_nested_opaque_snapshot_files_are_accepted(self):
        image_dir = self.root / "nested-snapshot"
        image_dir.mkdir()
        files = {"nested/deeper/opaque.data": b"\x00unclassified bytes"}
        archive_path = image_dir / "data.tar"
        with tarfile.open(archive_path, "w") as archive:
            for name in ("nested", "nested/deeper"):
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
            "format": "recipe-db-pvc-snapshot", "formatVersion": 1, "backupId": "backup-nested",
            "capturedAt": "2026-10-31T10:00:00Z",
            "source": {"target": "pi", "cluster": "recipe-db-pi", "context": "recipe-db-pi",
                       "namespace": "recipe-db", "artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64,
                       "revision": "a" * 40},
            "inventory": [{"service": "data", "role": "cleanup-participant", "pvc": "data",
                           "archive": "data.tar", "sizeBytes": len(archive_bytes), "fileCount": len(entries),
                           "sha256": hashlib.sha256(archive_bytes).hexdigest(), "files": entries}],
        }
        (image_dir / "manifest.json").write_bytes(backup.json_bytes(manifest))
        self.assertEqual(backup.validate_snapshot(image_dir), manifest)

    def test_root_named_regular_file_is_rejected(self):
        source = self.make_snapshot(files={".": b"not a volume-root directory"})
        with self.assertRaisesRegex(ValueError, "unsafe file path"):
            backup.validate_snapshot(source)

    def test_archive_safety_and_limits_before_upload(self):
        source = self.make_snapshot(directories=["one", "two"], root_directory=True)
        manifest_path = source / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        archive_path = source / "recipes.tar"
        original = archive_path.read_bytes()

        def replace(members):
            with tarfile.open(archive_path, "w") as archive:
                for member in members:
                    archive.addfile(member)
            manifest["inventory"][0]["sizeBytes"] = archive_path.stat().st_size
            manifest["inventory"][0]["sha256"] = backup.file_hash(archive_path)
            manifest_path.write_bytes(backup.json_bytes(manifest))

        def directory(name, mode=0o755):
            member = tarfile.TarInfo(name)
            member.type = tarfile.DIRTYPE
            member.mode = mode
            return member

        for member in (directory("/"), directory("////"), directory(".", 0o2755),
                       directory("nested", 0o2770)):
            replace([member])
            with self.assertRaisesRegex(ValueError, "unsafe archive metadata"):
                backup.validate_snapshot(source)
        archive_path.write_bytes(original)
        manifest["inventory"][0]["sizeBytes"] = archive_path.stat().st_size
        manifest["inventory"][0]["sha256"] = backup.file_hash(archive_path)
        manifest["inventory"][0].pop("directories")
        manifest_path.write_bytes(backup.json_bytes(manifest))
        with patch.object(backup, "MAX_DIRECTORIES", 2):
            with self.assertRaisesRegex(ValueError, "too many archive directories"):
                backup.validate_snapshot(source)
        with patch.object(backup, "MAX_DIRECTORIES", 3):
            backup.validate_snapshot(source)

        implicit = self.make_snapshot("implicit", files={"one/two/file": b"data"})
        with patch.object(backup, "MAX_DIRECTORIES", 1):
            with self.assertRaisesRegex(ValueError, "too many archive directories"):
                backup.validate_snapshot(implicit)
        with patch.object(backup, "MAX_DIRECTORIES", 2):
            backup.validate_snapshot(implicit)
        collision = self.make_snapshot("collision", files={"parent": b"file", "parent/child": b"data"})
        with self.assertRaisesRegex(ValueError, "archive file is a parent directory"):
            backup.validate_snapshot(collision)

        second = source / "second.tar"
        second.write_bytes(original)
        other = dict(manifest["inventory"][0], service="other", pvc="other", archive="second.tar")
        manifest["inventory"].append(other)
        manifest_path.write_bytes(backup.json_bytes(manifest))
        with patch.object(backup, "MAX_FILES", 1):
            with self.assertRaisesRegex(ValueError, "too many snapshot files"):
                backup.validate_snapshot(source)

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

    def test_maintenance_entry_disables_timer_and_requires_an_idle_backup_service(self):
        self.write_maintenance_capture()
        with patch.dict(os.environ, {"FAKE_BACKUP_SERVICE_ACTIVE": "active"}):
            with self.assertRaises(backup.BackupError) as error:
                backup.enter_maintenance(self.config)
        self.assertEqual(error.exception.code, "backup-service-active")
        self.assertIn("disable --now recipe-db-backup.timer", self.systemctl_log.read_text())
        self.assertFalse(backup.maintenance_state_path(self.config).exists())
        self.assertFalse(backup.report_status(self.config)["maintenanceActive"])

        with patch.dict(os.environ, {"FAKE_BACKUP_SERVICE_ACTIVE": "inactive"}):
            backup.enter_maintenance(self.config)
        state = backup.lifecycle_state(backup.maintenance_state_path(self.config))
        self.assertEqual(state["status"], "maintenance-mode")
        self.assertEqual(state["phase"], "maintenance-entered")
        status = backup.report_status(self.config)
        self.assertTrue(status["maintenanceActive"])
        self.assertEqual(status["backupId"], state["backupId"])
        self.assertEqual(self.systemctl_log.read_text().splitlines().count(
            "disable --now recipe-db-backup.timer"), 2)

    def test_maintenance_capture_upload_failure_preserves_state_and_retries_upload_only(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        with patch.dict(os.environ, {"FAKE_RCLONE_FAIL": "copyto"}):
            with self.assertRaises(backup.BackupError) as error:
                backup.run_nightly(self.config)
        self.assertEqual(error.exception.status, "upload-failure")
        maintenance = backup.maintenance_state_path(self.config)
        self.assertTrue((maintenance / "manifest.json").is_file())
        self.assertEqual(backup.lifecycle_state(maintenance)["phase"], "upload-pending")
        self.assertTrue(backup.report_status(self.config)["maintenanceActive"])
        self.assertEqual((self.root / "capture-actions.log").read_text().splitlines(),
                         ["maintenance-enter", "maintenance-capture"])

        self.assertEqual(backup.run_nightly(self.config), "verified-upload")
        self.assertEqual((self.root / "capture-actions.log").read_text().splitlines(),
                         ["maintenance-enter", "maintenance-capture", "maintenance-restore"])
        self.assertEqual(backup.lifecycle_state(maintenance)["phase"], "captured")
        status = backup.report_status(self.config)
        self.assertEqual(status["status"], "verified-upload")
        self.assertEqual(status["backupId"], backup.lifecycle_state(maintenance)["backupId"])
        self.assertTrue(status["maintenanceActive"])
        self.assertTrue((maintenance / "backup-state.json").is_file())

    def test_verified_maintenance_capture_is_not_removed_or_recaptured(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        self.assertEqual(backup.run_nightly(self.config), "verified-upload")
        with patch.object(backup, "upload_snapshot", side_effect=AssertionError("must not upload")):
            self.assertEqual(backup.run_nightly(self.config), "verified-upload")
        self.assertEqual((self.root / "capture-actions.log").read_text().splitlines(),
                         ["maintenance-enter", "maintenance-capture", "maintenance-restore"])
        self.assertTrue((backup.maintenance_state_path(self.config) / "manifest.json").is_file())

    def test_unchanged_maintenance_capture_is_published_under_its_own_id(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        maintenance = backup.maintenance_state_path(self.config)
        backup.run_capture_command(self.config, "maintenance-capture", maintenance)
        previous = self.root / "previous"
        shutil.copytree(maintenance, previous)
        (previous / "backup-state.json").unlink()
        manifest_path = previous / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["backupId"] = "backup-20261109T100000-1"
        manifest_path.write_bytes(backup.json_bytes(manifest))
        self.assertEqual(backup.upload_snapshot(previous, self.config), "verified-upload")

        self.assertEqual(backup.run_nightly(self.config), "verified-upload")
        baseline = backup.read_json(backup.baseline_path(self.config))
        self.assertEqual(baseline["backupId"], backup.lifecycle_state(maintenance)["backupId"])
        remote = self.remote / "backups" / self.config["deploymentId"]
        self.assertTrue((remote / baseline["manifest"]).is_file())
        self.assertTrue((remote / baseline["archive"]).is_file())

    def test_restore_failure_preserves_evidence_and_retries_without_upload(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        failure = self.root / "fail-restore"
        failure.touch()
        with self.assertRaises(backup.BackupError):
            backup.run_nightly(self.config)
        maintenance = backup.maintenance_state_path(self.config)
        self.assertEqual(backup.lifecycle_state(maintenance)["phase"], "restoration-pending")
        saved = backup.read_json(backup.status_path(self.config))
        self.assertEqual(saved["status"], "verified-upload")
        self.assertEqual(saved["backupId"], backup.lifecycle_state(maintenance)["backupId"])
        self.assertEqual(backup.report_status(self.config)["status"], "restart-failure")
        failure.unlink()
        with patch.object(backup, "upload_snapshot", side_effect=AssertionError("must not upload")):
            self.assertEqual(backup.run_nightly(self.config), "verified-upload")
        self.assertEqual(backup.lifecycle_state(maintenance)["phase"], "captured")
        self.assertEqual(backup.report_status(self.config)["status"], "verified-upload")
        self.assertEqual((self.root / "capture-actions.log").read_text().splitlines(),
                         ["maintenance-enter", "maintenance-capture",
                          "maintenance-restore", "maintenance-restore"])

    def test_interruption_after_upload_keeps_verification_and_restores_on_retry(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        maintenance = backup.maintenance_state_path(self.config)
        backup.run_capture_command(self.config, "maintenance-capture", maintenance)
        with patch.object(backup, "run_capture_command", side_effect=KeyboardInterrupt):
            with self.assertRaises(backup.BackupError) as error:
                backup.run_nightly(self.config)
        self.assertEqual(error.exception.status, "interrupted")
        self.assertEqual(backup.lifecycle_state(maintenance)["phase"], "upload-pending")
        self.assertEqual(backup.read_json(backup.status_path(self.config))["status"], "verified-upload")
        self.assertEqual(backup.report_status(self.config)["status"], "restart-failure")
        with patch.object(backup, "upload_snapshot", side_effect=AssertionError("must not upload")):
            self.assertEqual(backup.run_nightly(self.config), "verified-upload")
        self.assertEqual(backup.lifecycle_state(maintenance)["phase"], "captured")

    def test_competing_run_does_not_replace_restoration_verification(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        failure = self.root / "fail-restore"
        failure.touch()
        with self.assertRaises(backup.BackupError):
            backup.run_nightly(self.config)
        saved = backup.read_json(backup.status_path(self.config))
        lock_fd = backup.acquire_run_lock(self.config)
        try:
            with self.assertRaises(backup.BackupError) as error:
                backup.run_nightly(self.config)
            self.assertEqual(error.exception.code, "already-running")
            self.assertEqual(backup.read_json(backup.status_path(self.config)), saved)
        finally:
            os.close(lock_fd)
        with self.assertRaises(backup.BackupError):
            backup.enter_maintenance(self.config)
        self.assertEqual(backup.read_json(backup.status_path(self.config)), saved)
        failure.unlink()
        with patch.object(backup, "upload_snapshot", side_effect=AssertionError("must not upload")):
            self.assertEqual(backup.run_nightly(self.config), "verified-upload")

    def test_missing_capture_command_does_not_erase_restoration_evidence(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        failure = self.root / "fail-restore"
        failure.touch()
        with self.assertRaises(backup.BackupError):
            backup.run_nightly(self.config)
        saved = backup.read_json(backup.status_path(self.config))
        capture = Path(self.config["captureCommand"])
        capture.chmod(0o600)
        with self.assertRaises(backup.BackupError):
            backup.run_nightly(self.config)
        self.assertEqual(backup.read_json(backup.status_path(self.config)), saved)
        capture.chmod(0o755)
        failure.unlink()
        self.assertEqual(backup.run_nightly(self.config), "verified-upload")

    def test_completed_restoration_preserves_verification_on_preflight_failure(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        self.assertEqual(backup.run_nightly(self.config), "verified-upload")
        saved = backup.read_json(backup.status_path(self.config))
        capture = Path(self.config["captureCommand"])
        capture.chmod(0o600)
        with self.assertRaises(backup.BackupError):
            backup.run_nightly(self.config)
        self.assertEqual(backup.read_json(backup.status_path(self.config)), saved)
        self.assertEqual(backup.report_status(self.config)["status"], "capture-failure")
        capture.chmod(0o755)
        with patch.object(backup, "upload_snapshot", side_effect=AssertionError("must not upload")):
            self.assertEqual(backup.run_nightly(self.config), "verified-upload")
        self.assertEqual(backup.report_status(self.config)["status"], "verified-upload")

    def test_completed_maintenance_refreshes_overdue_verification_without_upload(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        self.assertEqual(backup.run_nightly(self.config), "verified-upload")
        saved = backup.read_json(backup.status_path(self.config))
        saved["lastCheck"] = "2026-01-01T00:00:00+00:00"
        backup.atomic_json(backup.status_path(self.config), saved)
        self.assertEqual(backup.report_status(self.config)["status"], "overdue")
        with patch.object(backup, "remote_names",
                          side_effect=backup.BackupError("upload-failure", "remote-unavailable")):
            with self.assertRaises(backup.BackupError):
                backup.run_nightly(self.config)
        self.assertEqual(backup.report_status(self.config)["status"], "upload-failure")
        with patch.object(backup, "upload_snapshot", side_effect=AssertionError("must not upload")):
            self.assertEqual(backup.run_nightly(self.config), "verified-upload")
        self.assertEqual(backup.report_status(self.config)["status"], "verified-upload")

    def test_backup_only_capture_uploads_without_read_only_restoration(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        maintenance = backup.maintenance_state_path(self.config)
        backup.run_capture_command(self.config, "maintenance-capture", maintenance)
        state = backup.lifecycle_state(maintenance)
        state.update(status="captured", phase="captured", maintenanceKind="backup-only")
        backup.atomic_json(maintenance / "backup-state.json", state)
        self.assertEqual(backup.run_nightly(self.config), "verified-upload")
        self.assertEqual(backup.lifecycle_state(maintenance)["maintenanceKind"], "backup-only")
        self.assertEqual((self.root / "capture-actions.log").read_text().splitlines(),
                         ["maintenance-enter", "maintenance-capture"])

    def test_legacy_captured_state_without_restoration_evidence_is_refused(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        maintenance = backup.maintenance_state_path(self.config)
        backup.run_capture_command(self.config, "maintenance-capture", maintenance)
        state = backup.lifecycle_state(maintenance)
        state.update(status="captured", phase="captured")
        backup.atomic_json(maintenance / "backup-state.json", state)
        with patch.object(backup, "upload_snapshot", side_effect=AssertionError("must not upload")):
            with self.assertRaises(backup.BackupError) as error:
                backup.run_nightly(self.config)
        self.assertEqual(error.exception.code, "maintenance-restoration-unverified")

    def test_restore_success_without_captured_state_fails_closed(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        maintenance = backup.maintenance_state_path(self.config)
        backup.run_capture_command(self.config, "maintenance-capture", maintenance)
        with patch.object(backup, "run_capture_command"):
            with self.assertRaises(backup.BackupError) as error:
                backup.run_nightly(self.config)
        self.assertEqual(error.exception.status, "restart-failure")
        self.assertEqual(backup.report_status(self.config)["status"], "restart-failure")
        self.assertEqual(backup.read_json(backup.status_path(self.config))["status"], "verified-upload")
        self.assertEqual(backup.run_nightly(self.config), "verified-upload")

    def test_restore_success_without_state_file_fails_closed(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        maintenance = backup.maintenance_state_path(self.config)
        backup.run_capture_command(self.config, "maintenance-capture", maintenance)

        def lose_state(config, action, path):
            self.assertEqual(action, "maintenance-restore")
            (path / "backup-state.json").unlink()

        with patch.object(backup, "run_capture_command", side_effect=lose_state):
            with self.assertRaises(backup.BackupError) as error:
                backup.run_nightly(self.config)
        self.assertEqual(error.exception.code, "maintenance-restore-incomplete")
        self.assertEqual(backup.report_status(self.config)["status"], "restart-failure")

    def test_interrupted_restore_requires_matching_verified_status(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        maintenance = backup.maintenance_state_path(self.config)
        backup.run_capture_command(self.config, "maintenance-capture", maintenance)
        state = backup.lifecycle_state(maintenance)
        state["phase"] = "restoration-pending"
        backup.atomic_json(maintenance / "backup-state.json", state)
        for status in (None, {"format": backup.STATUS_FORMAT, "status": "verified-upload",
                             "backupId": "backup-other"},
                       {"format": backup.STATUS_FORMAT, "status": "verified-unchanged",
                        "backupId": state["backupId"]}):
            with self.subTest(status=status):
                if status is None:
                    backup.status_path(self.config).unlink()
                else:
                    backup.atomic_json(backup.status_path(self.config), status)
                with patch.object(backup, "upload_snapshot", side_effect=AssertionError("must not upload")):
                    with self.assertRaises(backup.BackupError):
                        backup.run_nightly(self.config)
                self.assertEqual(backup.lifecycle_state(maintenance)["phase"], "restoration-pending")
        self.assertEqual((self.root / "capture-actions.log").read_text().splitlines(),
                         ["maintenance-enter", "maintenance-capture"])

    def test_upload_pending_validation_is_explicit_and_checks_identity_and_contents(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        maintenance = backup.maintenance_state_path(self.config)
        backup.run_capture_command(self.config, "maintenance-capture", maintenance)
        with self.assertRaises(ValueError):
            backup.validate_snapshot(maintenance)
        self.assertEqual(backup.validate_snapshot(maintenance, allow_upload_pending=True)["backupId"],
                         backup.lifecycle_state(maintenance)["backupId"])
        state = backup.lifecycle_state(maintenance)
        for status, phase in (("maintenance-mode", "upload-pending"),
                              ("backup-mode", "restoration-pending"),
                              ("backup-mode", "maintenance-entered")):
            with self.subTest(status=status, phase=phase):
                backup.atomic_json(maintenance / "backup-state.json", dict(state, status=status, phase=phase))
                with self.assertRaises(ValueError):
                    backup.validate_snapshot(maintenance, allow_upload_pending=True)
        backup.atomic_json(maintenance / "backup-state.json", dict(state, backupId="backup-other"))
        with self.assertRaises(ValueError):
            backup.validate_snapshot(maintenance, allow_upload_pending=True)
        backup.atomic_json(maintenance / "backup-state.json", state)
        (maintenance / "recipes.tar").write_bytes(b"corrupted")
        with self.assertRaises(backup.BackupError):
            backup.run_nightly(self.config)
        self.assertEqual((self.root / "capture-actions.log").read_text().splitlines(),
                         ["maintenance-enter", "maintenance-capture"])

    def test_restore_requires_verified_upload_with_exact_identity(self):
        self.write_maintenance_capture()
        backup.enter_maintenance(self.config)
        maintenance = backup.maintenance_state_path(self.config)
        backup.run_capture_command(self.config, "maintenance-capture", maintenance)
        backup.write_status(self.config, "verified-upload", "remote-readback", "backup-other")
        with patch.object(backup, "upload_snapshot", return_value="verified-upload"):
            with self.assertRaises(backup.BackupError) as error:
                backup.run_nightly(self.config)
        self.assertEqual(error.exception.code, "remote-verification-mismatch")
        self.assertEqual((self.root / "capture-actions.log").read_text().splitlines(),
                         ["maintenance-enter", "maintenance-capture"])


if __name__ == "__main__":
    unittest.main()
