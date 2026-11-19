import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "files" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = load_script("checkout-guard")
release_files = load_script("release-files")


class CloseoutPreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=".")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        self.checkout = root / "checkout"
        self.checkout.mkdir()
        self.base = root / "private"
        self.base.mkdir(mode=0o700)
        self.maintenance = self.base / "maintenance"
        self.maintenance.mkdir(mode=0o700)
        self.state_path = self.maintenance / "backup-state.json"
        self.marker = self.base / "release-command.json"
        self.proc = root / "proc"
        parent = self.proc / str(os.getppid())
        parent.mkdir(parents=True)
        (parent / "stat").write_text(f"{parent.name} (ansible) S" + " 0" * 18 + " 1234\n")
        self.holder = "backup-20261119144000-123"
        self.confirmation = f"PREPARE-CLOSEOUT-{self.holder}"
        self.revision = "b" * 40
        self.old_revision = "a" * 40
        self.source = {
            "target": "pi", "cluster": "recipe-db", "context": "recipe-db-pi",
            "namespace": "recipe-db", "revision": "c" * 40,
            "artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "d" * 64,
        }
        self.state = {
            "stateVersion": 2, "backupId": self.holder, "status": "recovery-required",
            "phase": "post-release-backup-failed", "source": self.source,
            "candidate": {
                "artifact": "ghcr.io/dhhyi/recipe-db-releases@sha256:" + "e" * 64,
                "revision": "f" * 40,
            },
            "toolingRevision": self.old_revision, "configSha256": "1" * 64,
        }
        self.save_state()
        self.lease = {
            "apiVersion": "coordination.k8s.io/v1", "kind": "Lease",
            "metadata": {
                "name": "recipe-db-deploy", "namespace": "kube-system", "uid": "original-uid",
                "labels": {"app.kubernetes.io/part-of": "recipe-db"},
                "annotations": {
                    "recipe-db/operation": "backup", "recipe-db/release": self.source["artifact"],
                    "recipe-db/phase": "recovery-required",
                },
            },
            "spec": {"holderIdentity": self.holder},
        }
        self.service = "inactive"
        self.timer = "ActiveState=inactive\nUnitFileState=disabled\nLoadState=loaded"
        self.config = {"stateDirectory": str(self.base)}
        self.addCleanup(patch.stopall)
        patch.object(guard, "output", side_effect=self.output).start()
        patch.object(guard, "installed_release_files", return_value=vars(release_files)).start()
        patch.object(release_files, "CHECKOUT", self.checkout).start()
        patch.object(release_files, "config_info", return_value={"configSha256": "1" * 64}).start()
        patch.object(release_files, "managed", return_value=json.dumps([self.source]).encode()).start()
        patch.dict(release_files.backup, {"safe_config": lambda path: self.config}).start()
        patch.object(release_files.subprocess, "check_output",
                     return_value=self.old_revision.encode()).start()

    def save_state(self):
        self.state_path.write_text(json.dumps(self.state))
        self.state_path.chmod(0o600)

    def output(self, arguments):
        if arguments[0] == "systemctl":
            return self.service if arguments[-1].endswith(".service") else self.timer
        if arguments[0] == "/usr/local/bin/k3s":
            self.assertEqual(arguments[1:9], [
                "kubectl", "--kubeconfig", "/etc/rancher/k3s/k3s.yaml",
                "--namespace", "kube-system", "--request-timeout=10s", "get", "lease",
            ])
            self.assertEqual(arguments[9:], ["recipe-db-deploy", "-o", "json"])
            return json.dumps(self.lease)
        self.assertEqual(arguments, [
            "/usr/bin/git", "-C", str(self.checkout), "rev-parse", "HEAD",
        ])
        return self.old_revision

    def prepare(self, **changes):
        return guard.prepare_closeout(
            changes.get("revision", self.revision), changes.get("holder", self.holder),
            changes.get("confirmation", self.confirmation),
            self.checkout, self.state_path, self.proc,
        )["token"]

    def validate(self, token):
        return guard.validate_closeout(
            self.revision, self.holder, self.confirmation, token,
            self.checkout, self.state_path, self.proc,
        )

    def test_historical_tooling_is_preserved_and_real_old_begin_claim_is_held_under_lock(self):
        original = self.state_path.read_bytes()
        begin = release_files.handle

        def claim(request, config):
            self.assertEqual(request["operation"], "begin")
            self.assertEqual(request["action"], "release-closeout-prepare")
            self.assertEqual(request["revision"], self.old_revision)
            descriptor = os.open(self.base / "run.lock", os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(descriptor)
            return begin(request, config)

        with patch.object(release_files, "handle", side_effect=claim):
            token = self.prepare()
        self.assertEqual(self.state_path.read_bytes(), original)
        self.assertEqual(json.loads(self.marker.read_text()), {
            "holder": self.holder, "token": token, "source": self.source, "configSha256": "1" * 64,
        })
        self.validate(token)
        with self.assertRaisesRegex(ValueError, "workstation release command"):
            guard.validate(self.revision, self.holder, self.checkout, self.state_path, self.proc)
        result = release_files.handle({"operation": "end", "token": token}, self.config)
        self.assertEqual(result, {})
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.state_path.read_bytes(), original)

    def test_each_known_terminal_failure_is_eligible_but_unknown_and_inflight_are_not(self):
        for phase in sorted(guard.TERMINAL_FAILURES):
            with self.subTest(phase=phase):
                self.state["phase"] = phase
                self.save_state()
                self.validate(None)
        for status, phase in (
            ("in-progress", "post-release-backup-failed"),
            ("recovery-required", "prepared"), ("access-open", "website-passed"),
            ("recovery-required", "migration-failed"),
            ("recovery-required", "new-unknown-failure"),
            ("recovery-closed", "recovery-closed"),
        ):
            with self.subTest(status=status, phase=phase):
                self.state.update(status=status, phase=phase)
                self.save_state()
                with self.assertRaisesRegex(ValueError, "terminal retained"):
                    self.prepare()
                self.assertFalse(self.marker.exists())

    def test_explicit_revision_holder_and_approval_are_all_required(self):
        for changes in (
            {"revision": "main"}, {"holder": ""}, {"holder": "backup-1-2"},
            {"confirmation": ""}, {"confirmation": "true"},
            {"confirmation": "PREPARE-CLOSEOUT-backup-1-2"},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.prepare(**changes)
        self.assertFalse(self.marker.exists())

    def test_private_state_source_candidate_and_configuration_must_match(self):
        initial = copy.deepcopy(self.state)
        for change in (
            {"backupId": "backup-1-2"}, {"stateVersion": 1},
            {"source": self.source | {"target": "local"}},
            {"source": self.source | {"artifact": "tag"}},
            {"source": self.source | {"context": "wrong-cluster"}},
            {"candidate": self.state["candidate"] | {"revision": "main"}},
            {"candidate": self.state["candidate"] | {"artifact": self.source["artifact"]}},
            {"configSha256": "2" * 64},
        ):
            with self.subTest(change=change):
                self.state = initial | change
                self.save_state()
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse(self.marker.exists())
        self.state = initial
        self.save_state()
        self.state_path.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "private owned"):
            self.prepare()
        self.state_path.chmod(0o600)
        self.maintenance.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "directories must be private"):
            self.prepare()

    def test_active_service_or_non_disabled_timer_is_refused_without_mutation(self):
        for service in ("active", "activating", "deactivating", ""):
            with self.subTest(service=service):
                self.service = service
                with self.assertRaisesRegex(ValueError, "idle backup"):
                    self.prepare()
        self.service = "failed"
        for timer in (
            "ActiveState=active\nUnitFileState=disabled\nLoadState=loaded",
            "ActiveState=inactive\nUnitFileState=enabled\nLoadState=loaded",
            "ActiveState=inactive\nUnitFileState=disabled\nLoadState=not-found",
        ):
            with self.subTest(timer=timer):
                self.timer = timer
                with self.assertRaisesRegex(ValueError, "timer already"):
                    self.prepare()
        self.assertFalse(self.marker.exists())

    def test_exact_primary_terminal_lease_and_uid_are_required(self):
        initial = copy.deepcopy(self.lease)
        for field, value in (
            ("name", "recipe-db-migration"), ("namespace", "recipe-db"), ("uid", ""),
            ("deletionTimestamp", "2026-11-19T14:40:00Z"),
        ):
            with self.subTest(field=field):
                self.lease = copy.deepcopy(initial)
                self.lease["metadata"][field] = value
                with self.assertRaisesRegex(ValueError, "primary terminal"):
                    self.prepare()
        for key, value in (
            ("recipe-db/operation", "deploy"), ("recipe-db/release", "other"),
            ("recipe-db/phase", "candidate-starting"),
        ):
            with self.subTest(key=key):
                self.lease = copy.deepcopy(initial)
                self.lease["metadata"]["annotations"][key] = value
                with self.assertRaisesRegex(ValueError, "primary terminal"):
                    self.prepare()
        self.lease = copy.deepcopy(initial)
        self.lease["spec"]["holderIdentity"] = "backup-1-2"
        with self.assertRaisesRegex(ValueError, "primary terminal"):
            self.prepare()
        self.assertFalse(self.marker.exists())
        self.lease = initial
        token = self.prepare()
        self.lease["metadata"]["uid"] = "replacement-uid"
        with self.assertRaisesRegex(ValueError, "Lease UID"):
            self.validate(token)
        self.assertTrue(self.marker.exists())

    def test_retained_or_symlinked_command_claim_is_not_silently_adopted(self):
        self.marker.write_text('{"holder":"another-command"}')
        self.marker.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "retained workstation"):
            self.prepare()
        self.assertEqual(self.marker.read_text(), '{"holder":"another-command"}')
        self.marker.unlink()
        self.marker.symlink_to(self.base / "missing")
        with self.assertRaisesRegex(ValueError, "retained workstation"):
            self.prepare()
        self.assertTrue(self.marker.is_symlink())

    def test_claim_token_source_config_candidate_and_reviewed_revision_cannot_change(self):
        token = self.prepare()
        with self.assertRaisesRegex(ValueError, "exact private file claim"):
            self.validate(token + "other")
        original = json.loads(self.marker.read_text())
        for change in (
            {"holder": "backup-1-2"}, {"source": self.source | {"revision": "0" * 40}},
            {"configSha256": "2" * 64},
        ):
            with self.subTest(change=change):
                self.marker.write_text(json.dumps(original | change))
                with self.assertRaisesRegex(ValueError, "exact private file claim"):
                    self.validate(token)
        self.marker.write_text(json.dumps(original))
        self.state["candidate"]["revision"] = "0" * 40
        self.save_state()
        with self.assertRaisesRegex(ValueError, "retained state"):
            self.validate(token)

    def test_guarded_git_revalidates_its_claim_and_passes_the_exclusion_descriptor(self):
        token = self.prepare()
        fields = dict(closeout_holder=self.holder, closeout_confirmation=self.confirmation,
                      closeout_token=token)

        def git(arguments, check, pass_fds):
            self.assertEqual(arguments, ["/usr/bin/git", "--version"])
            self.assertEqual(len(pass_fds), 1)
            descriptor = os.open(self.base / "run.lock", os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(descriptor)
            return subprocess.CompletedProcess(arguments, 0)

        with patch.object(guard.subprocess, "run", side_effect=git):
            self.assertEqual(guard.guarded_git(
                ["--version"], self.revision, "", self.checkout, self.state_path, self.proc,
                **fields,
            ), 0)
        self.lease["metadata"]["uid"] = "replacement-uid"
        with patch.object(guard.subprocess, "run") as git:
            with self.assertRaises(ValueError):
                guard.guarded_git(
                    ["checkout", self.revision], self.revision, "",
                    self.checkout, self.state_path, self.proc, **fields,
                )
            git.assert_not_called()

    def test_active_checkout_process_checkout_owner_and_run_lock_remain_mandatory(self):
        process = self.proc / "999999"
        process.mkdir()
        (process / "cwd").symlink_to(self.checkout)
        (process / "cmdline").write_bytes(b"bash\0")
        with self.assertRaisesRegex(ValueError, "process is using"):
            self.prepare()
        (process / "cwd").unlink()
        (process / "cmdline").write_bytes(b"unrelated-command\0")
        (process / "stat").write_text("999999 (ansible) S" + " 0" * 18 + " 5678\n")
        owner = self.base / "checkout-owner.json"
        owner.write_text('{"pid":999999,"started":"5678"}')
        with self.assertRaisesRegex(ValueError, "another Ansible"):
            self.prepare()
        (process / "stat").unlink()
        descriptor = os.open(self.base / "run.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.prepare()
        finally:
            os.close(descriptor)
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
