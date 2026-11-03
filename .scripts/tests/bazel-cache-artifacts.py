#!/usr/bin/env python3
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import tempfile
import tarfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error
import zipfile
from contextlib import redirect_stdout


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "bazel_cache_artifacts", ROOT / ".scripts/bazel-cache-artifacts.py"
)
CACHE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CACHE)


def varint(number):
    output = bytearray()
    while number > 127:
        output.append((number & 127) | 128)
        number >>= 7
    output.append(number)
    return bytes(output)


def integer(field, number):
    return varint(field * 8) + varint(number)


def message(field, data):
    return varint(field * 8 + 2) + varint(len(data)) + data


def digest(data):
    return message(1, hashlib.sha256(data).hexdigest().encode()) + integer(2, len(data))


def put_cache_file(root, category, key, content):
    path = root / category / key[:2] / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return path


def make_cache(root, output=b"built", output_path="result.txt", executable=True):
    output_digest = hashlib.sha256(output).hexdigest()
    put_cache_file(root, "cas", output_digest, output)
    output_file = message(1, output_path.encode()) + message(2, digest(output))
    if executable:
        output_file += integer(4, 1)
    action_result = message(2, output_file)
    action_digest = "a" * 64
    put_cache_file(root, "ac", action_digest, action_result)


class CacheArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_round_trip_validates_action_references_and_excludes_temporary_files(self):
        source = self.root / "source"
        source.mkdir()
        make_cache(source)
        (source / "tmp").mkdir()
        (source / "tmp" / "partial").write_bytes(b"unfinished")
        archive = self.root / "snapshot.tar"
        destination = self.root / "restored"

        stats = CACHE.snapshot(source, archive)
        restored = CACHE.unpack_snapshot(archive, destination)
        CACHE.cache_files(destination)

        self.assertEqual(stats["files"], 2)
        self.assertEqual(restored["files"], 2)
        self.assertFalse((destination / "tmp").exists())
        self.assertEqual(
            (destination / "ac" / "aa" / ("a" * 64)).read_bytes(),
            (source / "ac" / "aa" / ("a" * 64)).read_bytes(),
        )
        self.assertEqual((destination / "cas" / hashlib.sha256(b"built").hexdigest()[:2]
                          / hashlib.sha256(b"built").hexdigest()).read_bytes(), b"built")

    def test_rejects_malformed_action_result_and_missing_or_wrong_size_blob(self):
        source = self.root / "source"
        source.mkdir()
        make_cache(source)
        action = source / "ac" / "aa" / ("a" * 64)
        action.write_bytes(b"\x12\xff")
        with self.assertRaisesRegex(CACHE.Invalid, "invalid ActionResult"):
            CACHE.cache_files(source)

        source = self.root / "missing"
        source.mkdir()
        make_cache(source)
        missing_digest = hashlib.sha256(b"built").hexdigest()
        (source / "cas" / missing_digest[:2] / missing_digest).unlink()
        with self.assertRaisesRegex(CACHE.Invalid, "missing or wrong-size"):
            CACHE.cache_files(source)

    def test_rejects_corrupt_cas_and_resource_limit_excess(self):
        source = self.root / "source"
        source.mkdir()
        make_cache(source)
        blob_digest = hashlib.sha256(b"built").hexdigest()
        (source / "cas" / blob_digest[:2] / blob_digest).write_bytes(b"corrupt")
        with self.assertRaisesRegex(CACHE.Invalid, "CAS digest mismatch"):
            CACHE.cache_files(source)

        source = self.root / "bounded"
        source.mkdir()
        make_cache(source)
        with patch.object(CACHE, "MAX_FILES", 2):
            with self.assertRaisesRegex(CACHE.Invalid, "file-count limit"):
                CACHE.cache_files(source)
        with patch.object(CACHE, "MAX_EXPANDED_BYTES", 1):
            with self.assertRaisesRegex(CACHE.Invalid, "expansion limits"):
                CACHE.cache_files(source)

        source = self.root / "wrong-size"
        source.mkdir()
        make_cache(source)
        action = source / "ac" / "aa" / ("a" * 64)
        action.write_bytes(action.read_bytes().replace(b"\x10\x05", b"\x10\x06"))
        with self.assertRaisesRegex(CACHE.Invalid, "missing or wrong-size"):
            CACHE.cache_files(source)

    def test_accepts_canonical_empty_blob_without_a_cas_file(self):
        source = self.root / "source"
        source.mkdir()
        action_result = message(
            2, message(1, b"empty.txt") + message(2, digest(b""))
        )
        put_cache_file(source, "ac", "b" * 64, action_result)
        self.assertEqual(CACHE.cache_files(source)["ac"]["b" * 64][1], len(action_result))

    def test_validates_tree_outputs_and_safe_output_symlinks(self):
        source = self.root / "source"
        source.mkdir()
        output = b"tree output"
        output_digest = hashlib.sha256(output).hexdigest()
        put_cache_file(source, "cas", output_digest, output)
        file_node = message(1, b"nested.txt") + message(2, digest(output))
        symlink_node = message(1, b"alias.txt") + message(2, b"nested.txt")
        child = message(1, file_node) + message(3, symlink_node)
        child_node = message(1, b"subdir") + message(2, digest(child))
        root_directory = message(2, child_node)
        tree = message(1, root_directory) + message(2, child)
        tree_digest = hashlib.sha256(tree).hexdigest()
        put_cache_file(source, "cas", tree_digest, tree)
        result = message(
            3, message(1, b"directory") + message(3, digest(tree))
            + message(5, digest(root_directory))
        )
        result += message(10, message(1, b"old-file-link") + message(2, b"directory/subdir/nested.txt"))
        result += message(11, message(1, b"old-dir-link") + message(2, b"directory/subdir"))
        result += message(12, message(1, b"link") + message(2, b"directory/subdir/nested.txt"))
        put_cache_file(source, "ac", "c" * 64, result)

        CACHE.cache_files(source)

        bad = self.root / "escaping"
        bad.mkdir()
        unsafe_result = message(
            12, message(1, b"link") + message(2, b"../../outside")
        )
        put_cache_file(bad, "ac", "d" * 64, unsafe_result)
        with self.assertRaisesRegex(CACHE.Invalid, "escaping"):
            CACHE.cache_files(bad)

    def test_rejects_unknown_layouts_and_symlinks(self):
        source = self.root / "source"
        source.mkdir()
        make_cache(source)
        (source / "gc").mkdir()
        with self.assertRaisesRegex(CACHE.Invalid, "unsupported cache layout"):
            CACHE.cache_files(source)
        (source / "gc").rmdir()
        (source / "tmp").mkdir()
        (source / "tmp" / "link").symlink_to(source)
        with self.assertRaisesRegex(CACHE.Invalid, "symlink"):
            CACHE.cache_files(source)

    def test_rejects_unsafe_tar_paths_and_links_without_publishing(self):
        for kind in ("traversal", "symlink"):
            archive = self.root / f"{kind}.tar"
            destination = self.root / kind
            with tarfile.open(archive, "w:") as output:
                entry = tarfile.TarInfo("../outside" if kind == "traversal" else "ac/aa/link")
                if kind == "symlink":
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = "/outside"
                    output.addfile(entry)
                else:
                    entry.size = 1
                    output.addfile(entry, io.BytesIO(b"x"))
            with self.assertRaises(CACHE.Invalid):
                CACHE.unpack_snapshot(archive, destination)
            self.assertFalse(destination.exists())
        self.assertFalse((self.root / "outside").exists())

    def test_zip_preflight_requires_the_two_contract_members(self):
        good = self.root / "good.zip"
        with zipfile.ZipFile(good, "w") as archive:
            archive.writestr("manifest.json", "{}")
            archive.writestr("snapshot.tar", b"")
        CACHE.preflight_zip(good)
        bad = self.root / "many.zip"
        with zipfile.ZipFile(bad, "w") as archive:
            archive.writestr("manifest.json", "{}")
            archive.writestr("snapshot.tar", b"")
            archive.writestr("extra", b"x")
        with self.assertRaisesRegex(CACHE.Invalid, "member limits"):
            CACHE.preflight_zip(bad)

    def test_artifact_download_verifies_github_identity_before_atomic_restore(self):
        source = self.root / "source"
        source.mkdir()
        make_cache(source)
        snapshot = self.root / "snapshot.tar"
        CACHE.snapshot(source, snapshot)
        archive_digest = hashlib.sha256(snapshot.read_bytes()).hexdigest()
        run = {
            "id": 42, "run_number": 8, "run_attempt": 1, "workflow_id": 9,
            "head_sha": "b" * 40, "event": "push", "head_branch": "main",
        }
        manifest = {
            "format": CACHE.FORMAT, "formatVersion": CACHE.FORMAT_VERSION,
            "repository": "owner/repo", "workflow": CACHE.WORKFLOW, "job": CACHE.JOB,
            "runId": 42, "runAttempt": 1, "event": "push", "builtCommit": "b" * 40,
            "pullRequest": None,
            "compatibility": {
                "bazelVersion": (ROOT / ".bazelversion").read_text().strip(),
                "os": platform.system().lower(),
                "architecture": CACHE.normalize_arch(platform.machine()),
                "digest": "sha256",
            },
            "archive": {
                "file": "snapshot.tar", "sizeBytes": snapshot.stat().st_size,
                "sha256": archive_digest,
            },
        }
        artifact_zip = self.root / "workflow-artifact.zip"
        with zipfile.ZipFile(artifact_zip, "w") as archive:
            archive.writestr("manifest.json", json.dumps(manifest))
            archive.write(snapshot, "snapshot.tar")
        artifact = {
            "id": 88, "name": "bazel-cache-v1-main-r42-a1",
            "size_in_bytes": artifact_zip.stat().st_size, "workflow_run": {"id": 42},
        }
        detail = {
            **run, "repository": {"full_name": "owner/repo"},
            "path": CACHE.WORKFLOW, "name": "Publish", "conclusion": "failure",
        }
        jobs = [{"name": CACHE.JOB, "steps": [
            {"name": CACHE.UPLOAD_STEP, "conclusion": "success"},
        ]}]
        destination = self.root / "restored"

        def copy_artifact(url, token, path, maximum):
            shutil.copyfile(artifact_zip, path)
            return path.stat().st_size

        with patch.object(CACHE, "request_file", side_effect=copy_artifact), \
                patch.object(CACHE, "producer_attempt", return_value=detail), \
                patch.object(CACHE, "jobs_for_attempt", return_value=jobs):
            result = CACHE.download_candidate(
                "https://api.github.com/repos/owner/repo", "token", artifact,
                destination, "owner/repo", run, "main", None,
            )

        self.assertIsNone(result)
        self.assertTrue((destination / "ac" / "aa" / ("a" * 64)).is_file())

    def test_rejects_unsafe_zip_member_paths_and_links(self):
        for kind in ("traversal", "symlink"):
            archive_path = self.root / f"{kind}.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("../manifest.json" if kind == "traversal" else "manifest.json", "{}")
                info = zipfile.ZipInfo("snapshot.tar")
                if kind == "symlink":
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(info, b"")
            with zipfile.ZipFile(archive_path) as archive:
                with self.assertRaisesRegex(CACHE.Invalid, "unsafe"):
                    CACHE.validate_zip_members(archive)

    def test_deleted_artifact_is_a_miss_but_authorization_errors_are_distinct(self):
        def deleted(request, timeout):
            raise urllib.error.HTTPError(request.full_url, 404, "gone", {}, None)

        with patch.object(CACHE, "opener", return_value=deleted):
            self.assertIsNone(CACHE.request_file(
                "https://api.github.com/repos/example/repo/actions/artifacts/1/zip",
                "token", self.root / "missing.zip", 100,
            ))

        def denied(request, timeout):
            raise urllib.error.HTTPError(request.full_url, 403, "denied", {}, None)

        with patch.object(CACHE, "opener", return_value=denied):
            with self.assertRaisesRegex(CACHE.ApiFailure, "HTTP 403"):
                CACHE.request_file(
                    "https://api.github.com/repos/example/repo/actions/artifacts/1/zip",
                    "token", self.root / "denied.zip", 100,
                )

    def test_pr_reruns_and_force_pushes_rank_by_run_attempt_not_ancestry(self):
        runs = [
            {"id": 4, "run_number": 10, "run_attempt": 3, "head_sha": "old",
             "event": "pull_request", "pull_requests": [{"number": 17}]},
            {"id": 5, "run_number": 11, "run_attempt": 1, "head_sha": "new",
             "event": "pull_request", "pull_requests": [{"number": 17}]},
            {"id": 6, "run_number": 99, "run_attempt": 1, "head_sha": "other",
             "event": "pull_request", "pull_requests": [{"number": 18}]},
        ]
        selected = CACHE.rank_runs(runs, "pr", 17, {})
        self.assertEqual([run["id"] for run in selected], [5, 4])
        artifact_runs = []
        artifacts = [
            {"name": "bazel-cache-v1-pr-17-r4-a1"},
            {"name": "bazel-cache-v1-pr-17-r4-a3"},
            {"name": "bazel-cache-v1-pr-17-r4-a2"},
        ]
        with patch.object(CACHE, "paginated", side_effect=lambda url, token, key: (
            artifact_runs.append(url) or artifacts
        )):
            ordered = CACHE.artifacts_for_run("https://api.github.com/repos/owner/repo", "token", runs[0])
        self.assertEqual([item["name"].rsplit("-a", 1)[1] for item in ordered], ["3", "2", "1"])
        self.assertEqual(artifact_runs, [
            "https://api.github.com/repos/owner/repo/actions/runs/4/artifacts"
        ])

    def test_main_prefers_nearest_ancestor_then_run_and_attempt_order(self):
        current = {"id": 10, "run_number": 100, "run_attempt": 1,
                   "head_sha": "main-3", "event": "push", "head_branch": "main"}
        same_revision = {"id": 11, "run_number": 101, "run_attempt": 2,
                         "head_sha": "main-3", "event": "push", "head_branch": "main"}
        previous = {"id": 12, "run_number": 102, "run_attempt": 1,
                    "head_sha": "main-2", "event": "push", "head_branch": "main"}
        future = {"id": 13, "run_number": 999, "run_attempt": 1,
                  "head_sha": "main-4", "event": "push", "head_branch": "main"}
        history = {"main-3": 0, "main-2": 1, "main-1": 2}
        selected = CACHE.rank_runs([previous, same_revision, future, current], "main", None, history)
        self.assertEqual([run["id"] for run in selected], [11, 10, 12])

    def test_pr_selection_falls_back_to_an_older_same_pr_artifact(self):
        event_path = self.root / "event.json"
        event_path.write_text(json.dumps({"pull_request": {"base": {"sha": "base"}}}))
        runs = [
            {"id": 2, "run_number": 20, "run_attempt": 1, "head_sha": "new",
             "event": "pull_request", "pull_requests": [{"number": 17}]},
            {"id": 1, "run_number": 19, "run_attempt": 1, "head_sha": "old",
             "event": "pull_request", "pull_requests": [{"number": 17}]},
        ]
        artifacts = {
            2: [{"id": 22, "name": "bazel-cache-v1-pr-17-r2-a1"}],
            1: [{"id": 11, "name": "bazel-cache-v1-pr-17-r1-a1"}],
        }
        calls = []

        def fake_download(base, token, artifact, cache_path, repository, run, scope, pr_number):
            calls.append((run["id"], artifact["id"], scope, pr_number))
            if run["id"] == 2:
                raise CACHE.Invalid("corrupt snapshot")
            return None

        args = SimpleNamespace(
            repository="owner/repo", event_path=str(event_path), event_name="pull_request",
            pr_number="17", run_id="99", run_attempt="1", commit="c" * 40,
            cache=str(self.root / "cache"),
        )
        output = io.StringIO()
        with patch.dict(os.environ, {"GITHUB_TOKEN": "fixture"}), \
                patch.object(CACHE, "run_history", return_value={"base": 0}), \
                patch.object(CACHE, "paginated", return_value=runs), \
                patch.object(CACHE, "artifacts_for_run", side_effect=lambda base, token, run: artifacts[run["id"]]), \
                patch.object(CACHE, "download_candidate", side_effect=fake_download), \
                redirect_stdout(output):
            CACHE.discover_and_restore(args)

        self.assertEqual(calls, [(2, 22, "pr", 17), (1, 11, "pr", 17)])
        self.assertIn("cache: rejected run=2", output.getvalue())

    def test_pr_without_own_artifact_falls_back_to_ancestor_main(self):
        event_path = self.root / "event.json"
        event_path.write_text(json.dumps({"pull_request": {"base": {"sha": "base"}}}))
        pr_run = {"id": 1, "run_number": 4, "run_attempt": 1, "head_sha": "pr",
                  "event": "pull_request", "pull_requests": [{"number": 17}]}
        main_run = {"id": 2, "run_number": 5, "run_attempt": 1, "head_sha": "base",
                    "event": "push", "head_branch": "main"}
        artifacts = {1: [], 2: [{"id": 22, "name": "bazel-cache-v1-main-r2-a1"}]}
        calls = []

        def fake_paginated(url, token, key):
            return [pr_run] if "event=pull_request" in url else [main_run]

        def fake_download(base, token, artifact, cache_path, repository, run, scope, pr_number):
            calls.append((run["id"], artifact["id"], scope))
            return None

        args = SimpleNamespace(
            repository="owner/repo", event_path=str(event_path), event_name="pull_request",
            pr_number="17", run_id="99", run_attempt="1", commit="c" * 40,
            cache=str(self.root / "cache"),
        )
        output = io.StringIO()
        with patch.dict(os.environ, {"GITHUB_TOKEN": "fixture"}), \
                patch.object(CACHE, "run_history", return_value={"base": 0}), \
                patch.object(CACHE, "paginated", side_effect=fake_paginated), \
                patch.object(CACHE, "artifacts_for_run", side_effect=lambda base, token, run: artifacts[run["id"]]), \
                patch.object(CACHE, "download_candidate", side_effect=fake_download), \
                redirect_stdout(output):
            CACHE.discover_and_restore(args)

        self.assertEqual(calls, [(2, 22, "main")])
        self.assertIn("fallback scope=pr", output.getvalue())

    def test_identity_validation_rejects_wrong_repository_workflow_or_pr(self):
        run = {
            "id": 25, "run_number": 4, "workflow_id": 9, "head_sha": "built",
            "event": "pull_request", "head_branch": "feature",
        }
        detail = {
            **run, "run_attempt": 2, "repository": {"full_name": "owner/repo"},
            "path": CACHE.WORKFLOW, "name": "Publish", "conclusion": "failure",
            "pull_requests": [{"number": 3, "head": {"sha": "pr-head"},
                               "base": {"sha": "main-base"}}],
        }
        jobs = [{"name": CACHE.JOB, "steps": [
            {"name": CACHE.UPLOAD_STEP, "conclusion": "success"},
        ]}]
        manifest = {
            "repository": "owner/repo", "workflow": CACHE.WORKFLOW,
            "job": CACHE.JOB, "runId": 25, "runAttempt": 2,
            "event": "pull_request", "builtCommit": "built",
            "pullRequest": {"number": 3, "head": "pr-head", "base": "main-base"},
        }
        CACHE.verify_producer(
            run, detail, jobs, manifest, "bazel-cache-v1-pr-3-r25-a2", "pr", 3, "owner/repo"
        )
        with self.assertRaisesRegex(CACHE.Invalid, "identity"):
            CACHE.verify_producer(
                run, detail, jobs, manifest, "bazel-cache-v1-pr-3-r25-a2",
                "pr", 4, "owner/repo",
            )
        with self.assertRaisesRegex(CACHE.Invalid, "metadata mismatch"):
            CACHE.verify_producer(
                run, {**detail, "path": "other.yml"}, jobs, manifest,
                "bazel-cache-v1-pr-3-r25-a2", "pr", 3, "owner/repo",
            )
        with self.assertRaisesRegex(CACHE.Invalid, "metadata mismatch"):
            CACHE.verify_producer(
                run, {**detail, "repository": {"full_name": "fork/repo"}}, jobs,
                manifest, "bazel-cache-v1-pr-3-r25-a2", "pr", 3, "owner/repo",
            )

    def test_main_identity_rejects_pr_producers(self):
        run = {
            "id": 26, "run_number": 5, "workflow_id": 9, "head_sha": "b" * 40,
            "event": "push", "head_branch": "main",
        }
        detail = {
            **run, "run_attempt": 1, "repository": {"full_name": "owner/repo"},
            "path": CACHE.WORKFLOW, "name": "Publish",
        }
        job = [{"name": CACHE.JOB, "steps": [
            {"name": CACHE.UPLOAD_STEP, "conclusion": "success"},
        ]}]
        manifest = {
            "repository": "owner/repo", "workflow": CACHE.WORKFLOW,
            "job": CACHE.JOB, "runId": 26, "runAttempt": 1, "event": "push",
            "builtCommit": "b" * 40,
            "pullRequest": {"number": 7, "head": "c" * 40, "base": "d" * 40},
        }
        with self.assertRaisesRegex(CACHE.Invalid, "invalid producer scope"):
            CACHE.verify_producer(
                run, detail, job, manifest, "bazel-cache-v1-main-r26-a1",
                "main", None, "owner/repo",
            )

    def test_compatibility_requires_versions_platform_and_digest(self):
        compatible = {
            "format": CACHE.FORMAT, "formatVersion": CACHE.FORMAT_VERSION,
            "compatibility": {
                "bazelVersion": (ROOT / ".bazelversion").read_text().strip(),
                "os": platform.system().lower(),
                "architecture": CACHE.normalize_arch(platform.machine()),
                "digest": "sha256",
            },
        }
        CACHE.validate_compatibility(compatible)
        incompatible = json.loads(json.dumps(compatible))
        incompatible["compatibility"]["digest"] = "sha512"
        with self.assertRaisesRegex(CACHE.Invalid, "compatibility mismatch"):
            CACHE.validate_compatibility(incompatible)

    def test_manifest_rejects_duplicate_and_unrecognized_fields(self):
        with self.assertRaisesRegex(CACHE.Invalid, "duplicate JSON key"):
            CACHE.parse_json(b'{"runId":1,"runId":2}')
        manifest = {
            "format": CACHE.FORMAT, "formatVersion": CACHE.FORMAT_VERSION,
            "repository": "owner/repo", "workflow": CACHE.WORKFLOW,
            "job": CACHE.JOB, "runId": 3, "runAttempt": 1, "event": "push",
            "builtCommit": "a" * 40, "pullRequest": None,
            "compatibility": {
                "bazelVersion": (ROOT / ".bazelversion").read_text().strip(),
                "os": platform.system().lower(),
                "architecture": CACHE.normalize_arch(platform.machine()),
                "digest": "sha256",
            },
            "archive": {"file": "snapshot.tar", "sizeBytes": 1, "sha256": "f" * 64},
        }
        CACHE.validate_manifest(manifest)
        with self.assertRaisesRegex(CACHE.Invalid, "malformed snapshot manifest"):
            CACHE.validate_manifest({**manifest, "futureField": True})

    def test_action_execution_diagnostics_count_hits_and_executions(self):
        logfile = self.root / "execution.json"
        logfile.write_text(
            '{"action":{"cacheHit":true}}\n'
            '{"action":{"cacheHit":false}}\n'
        )
        output = io.StringIO()
        with redirect_stdout(output):
            CACHE.report_action_logs([f"checks={logfile}"])
        self.assertIn("stage=checks hits=1 executions=1 records=2", output.getvalue())


if __name__ == "__main__":
    unittest.main()
