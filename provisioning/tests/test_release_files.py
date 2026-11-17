import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_files", ROOT / "files/release-files.py")
files = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(files)


class ReleaseFilesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.maintenance = self.base / "maintenance"
        self.maintenance.mkdir(mode=0o700)
        self.path = self.maintenance / "backup-state.json"
        self.config = {"stateDirectory": str(self.base)}
        self.previous = "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "a" * 64
        self.candidate = "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "b" * 64
        self.state = {
            "backupId": "backup-1-2", "source": {"artifact": self.previous},
            "configSha256": "c" * 64, "status": "captured", "phase": "captured",
            "toolingRevision": "b" * 40,
            "candidate": {"artifact": self.candidate, "revision": "b" * 40},
        }
        files.backup["atomic_json"](self.path, self.state)
        self.git = patch.object(files.subprocess, "check_output", return_value=("b" * 40 + "\n").encode())
        self.git.start()
        self.addCleanup(self.git.stop)

    def request(self, operation, **fields):
        return files.handle({"operation": operation, "token": "token", **fields}, self.config)

    def begin(self):
        return self.request("begin", revision="b" * 40, action="release-stage")

    def test_write_through_state_uses_identity_and_compare_and_swap(self):
        initial = self.begin()
        with self.assertRaisesRegex(ValueError, "already retained"):
            self.begin()
        updated = dict(self.state, status="candidate-staged", phase="candidate-staged")
        checkpoint = self.request("checkpoint", expected=initial["expected"], state=updated)
        self.assertEqual(json.loads(self.path.read_text())["phase"], "candidate-staged")
        with self.assertRaisesRegex(ValueError, "state changed"):
            self.request("checkpoint", expected=initial["expected"], state=self.state)
        updated["source"] = {"artifact": self.candidate}
        with self.assertRaisesRegex(ValueError, "identity changed"):
            self.request("checkpoint", expected=checkpoint["expected"], state=updated)

    def test_retained_credentials_are_private_and_not_overwritten(self):
        initial = self.begin()
        retained = {"backupId": self.state["backupId"], "source": self.state["source"],
                    "data": {"private": "test-value"}}
        self.request("retain", expected=initial["expected"], retained=retained)
        path = self.base / "maintenance.previous-runtime-secret.json"
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        retained["data"] = {"changed": "test"}
        with self.assertRaisesRegex(ValueError, "different data"):
            self.request("retain", expected=initial["expected"], retained=retained)

    def test_cleanup_keeps_state_and_credentials_until_publication_and_finalization(self):
        initial = self.begin()
        with self.assertRaisesRegex(ValueError, "verified publication"):
            self.request("prune", expected=initial["expected"])
        self.state.update(status="release-published", phase="published-cleanup-pending",
                          publishedRelease={"tag": "v1"})
        current = self.request("checkpoint", expected=initial["expected"], state=self.state)
        archive = self.maintenance / "recipes.tar"
        archive.write_bytes(b"test archive")
        self.request("prune", expected=current["expected"])
        self.assertFalse(archive.exists())
        self.assertTrue(self.path.exists())
        self.assertTrue((self.base / "release-command.json").exists())
        self.request("finalize", expected=current["expected"])
        self.assertFalse(self.maintenance.exists())
        self.assertFalse((self.base / "release-command.json").exists())

    def test_interrupted_terminal_deletions_resume_only_exact_publication_cleanup(self):
        for deletion in ("credentials", "state", "directory", "marker"):
            with self.subTest(deletion=deletion):
                self.maintenance.mkdir(mode=0o700, exist_ok=True)
                self.state.update(status="release-published", phase="published-cleanup-pending",
                                  publishedRelease={"tag": "v1"})
                files.backup["atomic_json"](self.path, self.state)
                initial = self.begin()
                credentials = self.base / "maintenance.previous-runtime-secret.json"
                files.backup["atomic_json"](credentials, {"test": True})
                target = {"credentials": credentials, "state": self.path,
                          "directory": self.maintenance,
                          "marker": self.base / "release-command.json"}[deletion]
                method = "rmdir" if deletion == "directory" else "unlink"
                original = getattr(Path, method)

                def interrupted(path, *args, **kwargs):
                    if path == target:
                        raise OSError("injected cleanup interruption")
                    return original(path, *args, **kwargs)

                with patch.object(Path, method, interrupted):
                    with self.assertRaisesRegex(OSError, "injected cleanup"):
                        self.request("finalize", expected=initial["expected"])
                with self.assertRaisesRegex(ValueError, "exact release-finalize"):
                    self.request("begin", action="release-finalize",
                                 arguments=[self.previous, "v1", "PUBLISHED-backup-1-2-v1"])
                result = self.request("begin", action="release-finalize", arguments=[
                    self.candidate, "v1", "PUBLISHED-backup-1-2-v1",
                ])
                self.assertEqual(result, {"finalized": True})
                self.assertFalse(self.maintenance.exists())
                self.assertFalse((self.base / "release-command.json").exists())

    def test_abandoned_claim_requires_exact_stopped_command_confirmation(self):
        self.begin()
        with self.assertRaisesRegex(ValueError, "stopped-command"):
            self.request("abandon", confirmation="wrong")
        self.request("abandon", confirmation="ABANDON-backup-1-2-token-AFTER-COMMAND-STOPPED")
        self.assertTrue(self.path.exists())
        self.assertFalse((self.base / "release-command.json").exists())

    def test_cleanup_proof_write_failure_preserves_state_and_original_claim(self):
        self.state.update(status="release-published", phase="published-cleanup-pending",
                          publishedRelease={"tag": "v1"})
        files.backup["atomic_json"](self.path, self.state)
        initial = self.begin()
        marker = self.base / "release-command.json"
        original = marker.read_bytes()
        replace = files.os.replace

        def interrupted(source, destination):
            if Path(destination) == marker:
                raise OSError("injected proof write failure")
            return replace(source, destination)

        with patch.object(files.os, "replace", side_effect=interrupted):
            with self.assertRaisesRegex(OSError, "proof write failure"):
                self.request("finalize", expected=initial["expected"])
        self.assertEqual(marker.read_bytes(), original)
        self.assertTrue(self.path.exists())
        self.request("end")
        initial = self.begin()
        self.request("finalize", expected=initial["expected"])
        self.assertFalse(self.maintenance.exists())

    def test_alignment_only_changes_reference_after_candidate_and_website_gates(self):
        reference = self.base / "backup-release-ref"
        reference.write_text(self.previous + "\n")
        reference.chmod(0o600)
        self.state.update(status="access-open", phase="website-passed",
                          websiteCheck={"outcome": "passed"})
        self.state["candidate"]["revision"] = "d" * 40
        files.backup["atomic_json"](self.path, self.state)
        with patch.object(files, "REFERENCE", reference), patch.object(
            files, "config_info", return_value={"configSha256": self.state["configSha256"]},
        ):
            with self.assertRaisesRegex(ValueError, "gate is incomplete"):
                self.request("align", holder="backup-1-3", artifact=self.candidate, revision="b" * 40)
            self.assertEqual(reference.read_text().strip(), self.previous)
            self.request("align", holder="backup-1-2", artifact=self.candidate, revision="b" * 40)
        self.assertEqual(reference.read_text().strip(), self.candidate)
        self.assertEqual(json.loads(self.path.read_text())["source"], self.state["source"])
        self.assertEqual(json.loads(self.path.read_text())["backupAlignment"]["revision"], "d" * 40)
        self.assertTrue(reference.with_name("backup-configured-at").is_file())

    def test_private_file_symlinks_are_refused(self):
        link = self.base / "symlink"
        link.symlink_to(self.path)
        with self.assertRaisesRegex(ValueError, "symlink"):
            files.private_read(link)
