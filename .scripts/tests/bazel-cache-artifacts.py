#!/usr/bin/env python3
import http.client
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
from contextlib import redirect_stderr, redirect_stdout


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


def put_tree_cache(root, tree, root_directory, action_digest="a" * 64, output_path=b"tree"):
    tree_digest = hashlib.sha256(tree).hexdigest()
    put_cache_file(root, "cas", tree_digest, tree)
    result = message(
        3, message(1, output_path) + message(3, digest(tree))
        + message(5, digest(root_directory))
    )
    put_cache_file(root, "ac", action_digest, result)


def make_cache(root, output=b"built", output_path="result.txt", executable=True,
               action_digest="a" * 64):
    output_digest = hashlib.sha256(output).hexdigest()
    put_cache_file(root, "cas", output_digest, output)
    output_file = message(1, output_path.encode()) + message(2, digest(output))
    if executable:
        output_file += integer(4, 1)
    action_result = message(2, output_file)
    put_cache_file(root, "ac", action_digest, action_result)


def cleanup_fixture(run_id, run_number, attempt=1, pr_number=None, artifact_id=None):
    if pr_number is None:
        scope = "main"
        branch = "main"
        event = "push"
        pull_requests = []
    else:
        scope = f"pr-{pr_number}"
        branch = f"feature-{pr_number}"
        event = "pull_request"
        pull_requests = []
    sha = f"{run_id:040x}"
    name = f"bazel-cache-v2-{scope}-r{run_id}-a{attempt}"
    return {
        "artifact": {
            "id": artifact_id or run_id,
            "name": name,
            "workflow_run": {
                "id": run_id, "head_sha": sha, "head_branch": branch,
                "repository_id": 9, "head_repository_id": 9,
            },
        },
        "run": {
            "id": run_id, "run_number": run_number, "run_attempt": attempt,
            "head_sha": sha, "head_branch": branch, "event": event,
            "path": CACHE.WORKFLOW, "name": "Publish",
            "repository": {"id": 9, "full_name": "owner/repo"},
            "head_repository": {"id": 9, "full_name": "owner/repo"},
            "workflow_id": 9,
            "pull_requests": pull_requests,
        },
        "jobs": [{"name": CACHE.JOB, "steps": [
            {"name": CACHE.UPLOAD_STEP, "conclusion": "success"},
        ]}],
    }


class CacheArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_cleanup_identity_accepts_real_artifact_metadata_for_main_and_pr(self):
        for version in ("v1", "v2"):
            for pr_number in (None, 17):
                with self.subTest(version=version, pr=pr_number):
                    fixture = cleanup_fixture(201, 1, pr_number=pr_number)
                    fixture["artifact"]["name"] = fixture["artifact"]["name"].replace(
                        "v2", version
                    )
                    if pr_number is not None:
                        fixture["artifact"]["workflow_run"]["head_repository_id"] = 10
                        fixture["run"]["head_repository"] = {
                            "id": 10, "full_name": "fork/repo",
                        }
                    self.assertNotIn("event", fixture["artifact"]["workflow_run"])
                    with patch.object(CACHE, "resolve_pr_association") as association:
                        identity = CACHE.cleanup_artifact_identity(
                            fixture["artifact"], fixture["run"], fixture["jobs"],
                            "owner/repo", 9, "https://api.github.com/repos/owner/repo", "token"
                        )
                    self.assertEqual(identity["scope"], "main" if pr_number is None else "pr")
                    self.assertEqual(identity["pr"], pr_number)
                    if pr_number is None:
                        association.assert_not_called()
                    else:
                        association.assert_called_once_with(
                            "https://api.github.com/repos/owner/repo", "token", "owner/repo",
                            fixture["run"]["head_sha"], pr_number, 9
                        )

    def test_cleanup_rejects_spoofed_producer_metadata(self):
        cases = [
            ("artifact", "id", 0),
            ("artifact", "name", "unrelated-report"),
            ("workflow_run", "id", 202),
            ("workflow_run", "repository_id", 10),
            ("workflow_run", "head_repository_id", 10),
            ("workflow_run", "head_repository_id", None),
            ("workflow_run", "head_sha", "b" * 40),
            ("workflow_run", "head_branch", "other"),
            ("run", "id", 202),
            ("run", "run_attempt", 2),
            ("run", "run_number", 0),
            ("run", "repository", {"id": 10, "full_name": "owner/repo"}),
            ("run", "repository", {"id": 9, "full_name": "other/repo"}),
            ("run", "head_repository", None),
            ("run", "workflow_id", 0),
            ("run", "path", ".github/workflows/other.yaml"),
            ("run", "name", "Other"),
            ("run", "head_sha", "invalid"),
            ("job", "name", "other"),
            ("step", "name", "other"),
            ("step", "conclusion", "failure"),
        ]
        for pr_number in (None, 17):
            for target, field, value in cases:
                with self.subTest(pr=pr_number, target=target, field=field, value=value):
                    fixture = cleanup_fixture(201, 1, pr_number=pr_number)
                    targets = {
                        "artifact": fixture["artifact"],
                        "workflow_run": fixture["artifact"]["workflow_run"],
                        "run": fixture["run"],
                        "job": fixture["jobs"][0],
                        "step": fixture["jobs"][0]["steps"][0],
                    }
                    targets[target][field] = value
                    with patch.object(CACHE, "resolve_pr_association"), \
                            self.assertRaises(CACHE.Invalid):
                        CACHE.cleanup_artifact_identity(
                            fixture["artifact"], fixture["run"], fixture["jobs"],
                            "owner/repo", 9, "https://api.github.com/repos/owner/repo", "token"
                        )

    def test_cleanup_rejects_spoofed_pr_association(self):
        fixture = cleanup_fixture(201, 1, pr_number=17)
        for pulls in (
            [],
            [{"number": 18, "base": {"repo": {"id": 9, "full_name": "owner/repo"}}}],
            [{"number": 17, "base": {"repo": {"id": 10, "full_name": "owner/repo"}}}],
            [{"number": 17, "base": {"repo": {"id": 9, "full_name": "other/repo"}}}],
        ):
            with self.subTest(pulls=pulls), \
                    patch.object(CACHE, "request_json", return_value=pulls), \
                    self.assertRaisesRegex(CACHE.Invalid, "commit-to-PR association"):
                CACHE.cleanup_artifact_identity(
                    fixture["artifact"], fixture["run"], fixture["jobs"],
                    "owner/repo", 9, "https://api.github.com/repos/owner/repo", "token"
                )

    def test_cleanup_scope_and_event_come_from_authenticated_run(self):
        for pr_number in (None, 17):
            for event in (None, "schedule", "push" if pr_number else "pull_request"):
                with self.subTest(pr=pr_number, event=event):
                    fixture = cleanup_fixture(201, 1, pr_number=pr_number)
                    fixture["artifact"]["workflow_run"]["event"] = fixture["run"]["event"]
                    fixture["run"]["event"] = event
                    with patch.object(CACHE, "resolve_pr_association") as association, \
                            self.assertRaisesRegex(CACHE.Invalid, "invalid producer"):
                        CACHE.cleanup_artifact_identity(
                            fixture["artifact"], fixture["run"], fixture["jobs"],
                            "owner/repo", 9, "https://api.github.com/repos/owner/repo", "token"
                        )
                    association.assert_not_called()
        for head_repository, branch in (
            ({"id": 9, "full_name": "fork/repo"}, "main"),
            ({"id": 10, "full_name": "fork/repo"}, "main"),
            ({"id": 9, "full_name": "owner/repo"}, "feature"),
        ):
            with self.subTest(head_repository=head_repository, branch=branch):
                fixture = cleanup_fixture(201, 1)
                fixture["run"]["head_repository"] = head_repository
                fixture["artifact"]["workflow_run"]["head_repository_id"] = head_repository["id"]
                fixture["run"]["head_branch"] = branch
                fixture["artifact"]["workflow_run"]["head_branch"] = branch
                with self.assertRaisesRegex(CACHE.Invalid, "invalid producer scope"):
                    CACHE.cleanup_artifact_identity(
                        fixture["artifact"], fixture["run"], fixture["jobs"], "owner/repo", 9
                    )

    def test_paginated_requests_honor_page_size_and_advance_pages(self):
        requests = []
        pages = [
            {"workflow_runs": [{"id": number} for number in range(20)]},
            {"workflow_runs": [{"id": 20}]},
        ]

        def fake_request(url, token):
            requests.append(url)
            return pages.pop(0)

        with patch.object(CACHE, "request_json", side_effect=fake_request):
            runs = list(CACHE.paginated(
                "https://api.github.com/repos/owner/repo/actions/runs?event=push",
                "token", "workflow_runs", page_size=20,
            ))

        self.assertEqual([run["id"] for run in runs], list(range(21)))
        self.assertEqual(
            requests,
            [
                "https://api.github.com/repos/owner/repo/actions/runs?event=push&per_page=20&page=1",
                "https://api.github.com/repos/owner/repo/actions/runs?event=push&per_page=20&page=2",
            ],
        )

    def test_cleanup_paginates_and_ranks_main_by_run_and_attempt_not_upload_order(self):
        fixtures = [
            cleanup_fixture(201, 1),
            cleanup_fixture(202, 2),
            cleanup_fixture(203, 3),
            cleanup_fixture(204, 4),
            cleanup_fixture(205, 5),
            cleanup_fixture(206, 5, attempt=2),
            cleanup_fixture(207, 6),
        ]
        fixtures.reverse()
        artifacts = [fixture["artifact"] for fixture in fixtures]
        artifacts.extend({"id": 900 + i, "name": f"unrelated-report-{i}"} for i in range(94))
        page_requests = []
        deleted = []

        def fake_json(url, token):
            if url == "https://api.github.com/repos/owner/repo":
                return {"id": 9, "full_name": "owner/repo"}
            page_requests.append(url)
            page = int(url.rsplit("page=", 1)[1])
            return {"artifacts": artifacts[(page - 1) * 100:page * 100]}

        by_attempt = {
            (fixture["run"]["id"], fixture["run"]["run_attempt"]): fixture
            for fixture in fixtures
        }
        with patch.object(CACHE, "request_json", side_effect=fake_json), \
                patch.object(CACHE, "producer_attempt",
                             side_effect=lambda base, token, run, attempt:
                             by_attempt[(run["id"], attempt)]["run"]), \
                patch.object(CACHE, "jobs_for_attempt",
                             side_effect=lambda base, token, run_id, attempt:
                             by_attempt[(run_id, attempt)]["jobs"]), \
                patch.object(CACHE, "request_delete",
                             side_effect=lambda url, token: deleted.append(url) or True):
            with redirect_stdout(io.StringIO()) as output:
                status = CACHE.cleanup_artifacts(
                    "https://api.github.com/repos/owner/repo", "token", "owner/repo"
                )

        self.assertEqual(status, 0)
        self.assertEqual(len(page_requests), 2)
        self.assertEqual([url.rsplit("/", 1)[1] for url in deleted], ["202", "201"])
        self.assertIn("cleanup: complete retained-main=5 deleted=2", output.getvalue())

    def test_cleanup_deletes_only_merged_pr_artifacts(self):
        fixtures = [
            cleanup_fixture(301, 1, pr_number=11),
            cleanup_fixture(302, 2, pr_number=12),
            cleanup_fixture(303, 3, pr_number=13),
        ]
        by_attempt = {
            (fixture["run"]["id"], fixture["run"]["run_attempt"]): fixture
            for fixture in fixtures
        }
        deleted = []
        pull_states = {
            11: {"state": "closed", "merged_at": "2026-01-01T00:00:00Z"},
            12: {"state": "open", "merged_at": None},
            13: {"state": "closed", "merged_at": None},
        }

        def fake_json(url, token):
            if url == "https://api.github.com/repos/owner/repo":
                return {"id": 9, "full_name": "owner/repo"}
            if "/commits/" in url and url.endswith("/pulls"):
                sha = url.split("/commits/", 1)[1].rsplit("/pulls", 1)[0]
                fixture = next(item for item in fixtures if item["run"]["head_sha"] == sha)
                pr_number = fixture["artifact"]["name"].split("-")[4]
                number = int(pr_number)
                return [{
                    "number": number,
                    "base": {"repo": {"id": 9, "full_name": "owner/repo"}},
                }]
            if "/pulls/" in url:
                number = int(url.rsplit("/", 1)[1])
                return {
                    "number": number, **pull_states[number],
                    "base": {"repo": {"id": 9, "full_name": "owner/repo"}},
                }
            return {"artifacts": [fixture["artifact"] for fixture in fixtures]}

        with patch.object(CACHE, "request_json", side_effect=fake_json), \
                patch.object(CACHE, "producer_attempt",
                             side_effect=lambda base, token, run, attempt:
                             by_attempt[(run["id"], attempt)]["run"]), \
                patch.object(CACHE, "jobs_for_attempt",
                             side_effect=lambda base, token, run_id, attempt:
                             by_attempt[(run_id, attempt)]["jobs"]), \
                patch.object(CACHE, "request_delete",
                             side_effect=lambda url, token: deleted.append(url) or True):
            self.assertEqual(CACHE.cleanup_artifacts(
                "https://api.github.com/repos/owner/repo", "token", "owner/repo"
            ), 0)

        self.assertEqual(deleted, [
            "https://api.github.com/repos/owner/repo/actions/artifacts/301",
        ])

    def test_cleanup_authenticates_legacy_pr_head_before_deletion(self):
        fixture = cleanup_fixture(350, 1, pr_number=15)
        fixture["artifact"]["name"] = "bazel-cache-v1-pr-15-r350-a1"
        api_base = "https://api.github.com/repos/owner/repo"
        deleted = []

        def fake_json(url, token):
            if url == api_base:
                return {"id": 9, "full_name": "owner/repo"}
            if "/commits/" in url:
                return [{
                    "number": 15,
                    "base": {"repo": {"id": 9, "full_name": "owner/repo"}},
                }]
            if "/pulls/15" in url:
                return {
                    "number": 15, "state": "closed", "merged_at": "2026-01-01",
                    "base": {"repo": {"id": 9, "full_name": "owner/repo"}},
                }
            return {"artifacts": [fixture["artifact"]]}

        with patch.object(CACHE, "request_json", side_effect=fake_json), \
                patch.object(CACHE, "producer_attempt", return_value=fixture["run"]), \
                patch.object(CACHE, "jobs_for_attempt", return_value=fixture["jobs"]), \
                patch.object(CACHE, "request_delete",
                             side_effect=lambda url, token: deleted.append(url) or True):
            self.assertEqual(CACHE.cleanup_artifacts(api_base, "token", "owner/repo"), 0)

        self.assertEqual(
            deleted, [f"{api_base}/actions/artifacts/{fixture['artifact']['id']}"]
        )

    def test_cleanup_identity_and_service_errors_are_incomplete(self):
        fixture = cleanup_fixture(401, 1)
        invalid_run = {**fixture["run"], "path": ".github/workflows/unrelated.yaml"}
        by_attempt = {(401, 1): {**fixture, "run": invalid_run}}
        api_base = "https://api.github.com/repos/owner/repo"

        with patch.object(CACHE, "request_json", side_effect=lambda url, token: (
            {"id": 9, "full_name": "owner/repo"} if url == api_base
            else {"artifacts": [fixture["artifact"]]}
        )), patch.object(CACHE, "producer_attempt",
                         return_value=invalid_run), patch.object(CACHE, "jobs_for_attempt",
                                                                 return_value=fixture["jobs"]):
            with redirect_stdout(io.StringIO()) as output, redirect_stderr(io.StringIO()) as errors:
                status = CACHE.cleanup_artifacts(api_base, "token", "owner/repo")

        self.assertEqual(status, 1)
        self.assertIn("identity-error", errors.getvalue())
        self.assertIn("cleanup: incomplete", errors.getvalue())
        self.assertNotIn("cleanup: complete", output.getvalue())

        with patch.object(CACHE, "request_json", side_effect=CACHE.ApiFailure("HTTP 403")):
            with redirect_stderr(io.StringIO()) as errors:
                self.assertEqual(CACHE.cleanup_artifacts(api_base, "token", "owner/repo"), 1)
        self.assertIn("HTTP 403", errors.getvalue())

    def test_cleanup_reports_partial_deletion_failure_without_claiming_completion(self):
        fixtures = [cleanup_fixture(600 + i, i + 1) for i in range(6)]
        by_attempt = {
            (fixture["run"]["id"], fixture["run"]["run_attempt"]): fixture
            for fixture in fixtures
        }
        api_base = "https://api.github.com/repos/owner/repo"

        def fake_json(url, token):
            if url == api_base:
                return {"id": 9, "full_name": "owner/repo"}
            return {"artifacts": [fixture["artifact"] for fixture in fixtures]}

        with patch.object(CACHE, "request_json", side_effect=fake_json), \
                patch.object(CACHE, "producer_attempt",
                             side_effect=lambda base, token, run, attempt:
                             by_attempt[(run["id"], attempt)]["run"]), \
                patch.object(CACHE, "jobs_for_attempt",
                             side_effect=lambda base, token, run_id, attempt:
                             by_attempt[(run_id, attempt)]["jobs"]), \
                patch.object(CACHE, "request_delete",
                             side_effect=CACHE.ApiFailure("HTTP 500")):
            with redirect_stdout(io.StringIO()) as output, redirect_stderr(io.StringIO()) as errors:
                status = CACHE.cleanup_artifacts(api_base, "token", "owner/repo")

        self.assertEqual(status, 1)
        self.assertIn("HTTP 500", errors.getvalue())
        self.assertIn("cleanup: incomplete", errors.getvalue())
        self.assertNotIn("cleanup: complete", output.getvalue())

    def test_cleanup_is_idempotent_when_artifact_disappears_before_delete(self):
        fixtures = [cleanup_fixture(500 + i, i + 1) for i in range(6)]
        by_attempt = {
            (fixture["run"]["id"], fixture["run"]["run_attempt"]): fixture
            for fixture in fixtures
        }
        api_base = "https://api.github.com/repos/owner/repo"

        def fake_json(url, token):
            if url == api_base:
                return {"id": 9, "full_name": "owner/repo"}
            return {"artifacts": [fixture["artifact"] for fixture in fixtures]}

        with patch.object(CACHE, "request_json", side_effect=fake_json), \
                patch.object(CACHE, "producer_attempt",
                             side_effect=lambda base, token, run, attempt:
                             by_attempt[(run["id"], attempt)]["run"]), \
                patch.object(CACHE, "jobs_for_attempt",
                             side_effect=lambda base, token, run_id, attempt:
                             by_attempt[(run_id, attempt)]["jobs"]), \
                patch.object(CACHE, "request_delete", return_value=False):
            with redirect_stdout(io.StringIO()) as output:
                self.assertEqual(CACHE.cleanup_artifacts(api_base, "token", "owner/repo"), 0)
        self.assertIn("already-gone", output.getvalue())

    def test_delete_404_is_idempotent_but_authorization_errors_are_distinct(self):
        def gone(request, timeout):
            raise urllib.error.HTTPError(request.full_url, 404, "gone", {}, None)

        with patch.object(CACHE, "opener", return_value=gone):
            self.assertFalse(CACHE.request_delete(
                "https://api.github.com/repos/owner/repo/actions/artifacts/1", "token"
            ))

        def denied(request, timeout):
            raise urllib.error.HTTPError(request.full_url, 403, "denied", {}, None)

        with patch.object(CACHE, "opener", return_value=denied):
            with self.assertRaisesRegex(CACHE.ApiFailure, "HTTP 403"):
                CACHE.request_delete(
                    "https://api.github.com/repos/owner/repo/actions/artifacts/1", "token"
                )

    def test_delete_disconnect_is_confirmed_by_rechecking_artifact(self):
        def disconnected(request, timeout):
            raise http.client.RemoteDisconnected("connection closed")

        with patch.object(CACHE, "opener", return_value=disconnected), \
                patch.object(CACHE, "request_json", return_value=None):
            self.assertFalse(CACHE.request_delete(
                "https://api.github.com/repos/owner/repo/actions/artifacts/1", "token"
            ))

        with patch.object(CACHE, "opener", return_value=disconnected), \
                patch.object(CACHE, "request_json", return_value={"id": 1}):
            with self.assertRaisesRegex(CACHE.ApiFailure, "outcome is unknown"):
                CACHE.request_delete(
                    "https://api.github.com/repos/owner/repo/actions/artifacts/1", "token"
                )

        def server_error(request, timeout):
            raise urllib.error.HTTPError(request.full_url, 500, "server error", {}, None)

        with patch.object(CACHE, "opener", return_value=server_error), \
                patch.object(CACHE, "request_json", return_value=None):
            self.assertFalse(CACHE.request_delete(
                "https://api.github.com/repos/owner/repo/actions/artifacts/1", "token"
            ))

    def test_safe_json_reads_retry_remote_disconnect_with_bounded_attempts(self):
        attempts = []

        def disconnected_once(request, timeout):
            attempts.append(request.full_url)
            if len(attempts) == 1:
                raise http.client.RemoteDisconnected("connection closed")
            return io.BytesIO(b'{"ok":true}')

        with patch.object(CACHE, "opener", return_value=disconnected_once), \
                patch.object(CACHE.time, "sleep"):
            self.assertEqual(CACHE.request_json("https://api.github.com/test", "token"), {"ok": True})
        self.assertEqual(len(attempts), 2)

        attempts.clear()

        def always_disconnected(request, timeout):
            attempts.append(request.full_url)
            raise http.client.RemoteDisconnected("connection closed")

        with patch.object(CACHE, "opener", return_value=always_disconnected), \
                patch.object(CACHE.time, "sleep"):
            with self.assertRaisesRegex(CACHE.ApiFailure, "bounded retries"):
                CACHE.request_json("https://api.github.com/test", "token")
        self.assertEqual(len(attempts), CACHE.API_READ_ATTEMPTS)

    def test_artifact_download_retries_disconnect_without_leaving_partial_file(self):
        destination = self.root / "download.zip"
        attempts = []

        class PartialResponse:
            headers = {}

            def __init__(self, fails):
                self.fails = fails

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def read(self, _):
                if self.fails:
                    self.fails = False
                    return b"partial"
                raise http.client.RemoteDisconnected("connection closed")

        class CompleteResponse(io.BytesIO):
            headers = {}

        def open_artifact(request, timeout):
            attempts.append(request.full_url)
            if len(attempts) == 1:
                return PartialResponse(True)
            return CompleteResponse(b"complete")

        with patch.object(CACHE, "opener", return_value=open_artifact), \
                patch.object(CACHE.time, "sleep"):
            self.assertEqual(
                CACHE.request_file("https://api.github.com/artifact", "token", destination, 100),
                len(b"complete"),
            )
        self.assertEqual(destination.read_bytes(), b"complete")
        self.assertEqual(len(attempts), 2)

    def test_workflow_run_listing_uses_bounded_page_size(self):
        requests = []

        def fake_paginated(url, token, key, page_size=100):
            requests.append((key, page_size))
            return iter(())

        with patch.object(CACHE, "paginated", side_effect=fake_paginated), \
                redirect_stdout(io.StringIO()):
            restored = CACHE.restore_scope(
                SimpleNamespace(run_number=10),
                "https://api.github.com/repos/owner/repo", "token", "pr", 17,
                {}, self.root / "cache",
            )

        self.assertFalse(restored)
        self.assertEqual(
            requests, [("workflow_runs", CACHE.WORKFLOW_RUNS_PAGE_SIZE)]
        )

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

    def test_union_keeps_both_sources_and_main_wins_valid_action_conflicts(self):
        main = self.root / "main"
        pr = self.root / "pr"
        main.mkdir()
        pr.mkdir()
        make_cache(main, b"main output", executable=True)
        make_cache(pr, b"PR output", executable=False, action_digest="b" * 64)
        destination = self.root / "union"

        CACHE.union_caches(main, pr, destination)

        merged = CACHE.cache_files(destination)
        self.assertEqual(set(merged["ac"]), {"a" * 64, "b" * 64})
        self.assertEqual(
            (destination / "cas" / hashlib.sha256(b"main output").hexdigest()[:2]
             / hashlib.sha256(b"main output").hexdigest()).read_bytes(),
            b"main output",
        )
        self.assertEqual(
            (destination / "cas" / hashlib.sha256(b"PR output").hexdigest()[:2]
             / hashlib.sha256(b"PR output").hexdigest()).read_bytes(),
            b"PR output",
        )

        conflict_main = self.root / "conflict-main"
        conflict_pr = self.root / "conflict-pr"
        conflict_main.mkdir()
        conflict_pr.mkdir()
        make_cache(conflict_main, b"winner", executable=True)
        make_cache(conflict_pr, b"loser", executable=False)
        conflict_union = self.root / "conflict-union"
        output = io.StringIO()
        with redirect_stdout(output):
            CACHE.union_caches(conflict_main, conflict_pr, conflict_union)
        merged = CACHE.cache_files(conflict_union)
        self.assertEqual(set(merged["ac"]), {"a" * 64})
        self.assertEqual(
            (conflict_union / "ac" / "aa" / ("a" * 64)).read_bytes(),
            (conflict_main / "ac" / "aa" / ("a" * 64)).read_bytes(),
        )
        self.assertIn("union-conflict action-key=", output.getvalue())
        self.assertTrue(
            (conflict_union / "cas" / hashlib.sha256(b"loser").hexdigest()[:2]
             / hashlib.sha256(b"loser").hexdigest()).is_file()
        )

    def test_union_rejects_invalid_source_without_publishing(self):
        main = self.root / "main"
        pr = self.root / "pr"
        main.mkdir()
        pr.mkdir()
        make_cache(main)
        make_cache(pr, b"invalid")
        digest = hashlib.sha256(b"invalid").hexdigest()
        (pr / "cas" / digest[:2] / digest).write_bytes(b"corrupt")
        destination = self.root / "union"

        with self.assertRaisesRegex(CACHE.Invalid, "CAS digest mismatch"):
            CACHE.union_caches(main, pr, destination)

        self.assertFalse(destination.exists())

    def test_union_deduplicates_identical_content_addressed_entries(self):
        main = self.root / "main"
        pr = self.root / "pr"
        main.mkdir()
        pr.mkdir()
        make_cache(main, b"shared", action_digest="a" * 64)
        make_cache(pr, b"shared", action_digest="b" * 64)
        destination = self.root / "union"

        stats = CACHE.union_caches(main, pr, destination)

        self.assertEqual(stats["files"], 3)
        self.assertEqual(len(CACHE.cache_files(destination)["cas"]), 1)

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

    def test_bounds_tree_depth_and_expanded_nodes_and_bytes(self):
        source = self.root / "too-deep"
        source.mkdir()
        directory = b""
        children = []
        for index in range(257):
            children.append(directory)
            node = message(1, f"level-{index}".encode()) + message(2, digest(directory))
            directory = message(2, node)
        tree = message(1, directory) + b"".join(message(2, item) for item in children)
        put_tree_cache(source, tree, directory)
        with self.assertRaisesRegex(CACHE.Invalid, "depth limit"):
            CACHE.cache_files(source)

        source = self.root / "too-many-nodes"
        source.mkdir()
        directory = b""
        children = []
        for index in range(5):
            children.append(directory)
            child = message(1, b"a") + message(2, digest(directory))
            sibling = message(1, b"b") + message(2, digest(directory))
            directory = message(2, child) + message(2, sibling)
        tree = message(1, directory) + b"".join(message(2, item) for item in children)
        put_tree_cache(source, tree, directory)
        with patch.object(CACHE, "MAX_FILES", 10):
            with self.assertRaisesRegex(CACHE.Invalid, "expanded-node limit"):
                CACHE.cache_files(source)

        source = self.root / "expanded-bytes"
        source.mkdir()
        directory = b""
        children = []
        for index in range(7):
            children.append(directory)
            child = message(1, b"a") + message(2, digest(directory))
            sibling = message(1, b"b") + message(2, digest(directory))
            directory = message(2, child) + message(2, sibling)
        tree = message(1, directory) + b"".join(message(2, item) for item in children)
        put_tree_cache(source, tree, directory)
        with patch.object(CACHE, "MAX_TREE_EXPANDED_BYTES", 512):
            with self.assertRaisesRegex(CACHE.Invalid, "expanded-byte limit"):
                CACHE.cache_files(source)

    def test_validates_symlinks_against_the_complete_output_graph(self):
        for links, expected_error in (
            ((("a", "."), ("b", "a/../outside")), "escaping"),
            ((("a", "b"), ("b", "a")), "cyclic"),
        ):
            with self.subTest(links=links):
                source = self.root / f"symlinks-{len(list(self.root.iterdir()))}"
                source.mkdir()
                root_directory = b"".join(
                    message(3, message(1, path.encode()) + message(2, target.encode()))
                    for path, target in links
                )
                tree = message(1, root_directory)
                put_tree_cache(source, tree, root_directory, output_path=b"")
                with self.assertRaisesRegex(CACHE.Invalid, expected_error):
                    CACHE.cache_files(source)

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

    def test_rejects_tar_extensions_before_tarfile_parses_their_payloads(self):
        for extension in (b"x", b"g", b"L", b"K"):
            archive = self.root / f"extension-{extension.decode()}.tar"
            header = bytearray(512)
            header[124:136] = b"77777777777\0"
            header[156:157] = extension
            archive.write_bytes(header)
            with self.subTest(extension=extension):
                with patch.object(CACHE.tarfile, "open") as tar_open:
                    with self.assertRaisesRegex(CACHE.Invalid, "extension"):
                        CACHE.unpack_snapshot(archive, self.root / f"out-{extension.decode()}")
                    tar_open.assert_not_called()

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
            "repository": {"id": 9, "full_name": "owner/repo"},
        }
        manifest = {
            "format": CACHE.FORMAT, "formatVersion": CACHE.FORMAT_VERSION,
            "repository": "owner/repo", "workflow": CACHE.WORKFLOW, "job": CACHE.JOB,
            "runId": 42, "runAttempt": 1, "event": "push", "builtCommit": "b" * 40,
            "sourceCommit": "b" * 40, "producerHeadSha": "b" * 40,
            "baseCommit": None, "pullRequest": None,
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
            "id": 88, "name": "bazel-cache-v2-main-r42-a1",
            "size_in_bytes": artifact_zip.stat().st_size, "workflow_run": {"id": 42},
        }
        detail = {
            **run, "repository": {"id": 9, "full_name": "owner/repo"},
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

    def test_pinned_copilot_candidate_still_requires_final_head_upload_and_valid_cache(self):
        head = "a" * 40
        base_commit = "b" * 40
        actor = {"login": "Copilot", "id": 198982749, "type": "Bot"}
        repository = {"id": 9, "full_name": "owner/repo"}
        run = {
            "id": 42, "run_number": 8, "run_attempt": 1, "workflow_id": 9,
            "head_sha": head, "event": "pull_request", "head_branch": "feature",
            "repository": repository, "actor": actor,
        }
        detail = {
            **run, "path": CACHE.WORKFLOW, "name": "Publish", "conclusion": "failure",
            "head_repository": repository,
        }
        pull = {
            "number": 17, "head": {"sha": head},
            "base": {"sha": base_commit, "repo": repository},
        }
        association = f"https://api.github.com/repos/owner/repo/commits/{head}/pulls"
        accepted_upload = [{"name": CACHE.JOB, "steps": [
            {"name": CACHE.UPLOAD_STEP, "conclusion": "success"},
        ]}]
        rejected_cases = (
            ("wrong final head", "final PR head", "f" * 40, [pull], accepted_upload, None),
            ("ambiguous PR association", "ambiguous", head,
             [pull, {**pull, "number": 18}], accepted_upload, None),
            ("missing upload job", "did not complete", head, [pull], [], None),
            ("failed upload step", "did not complete", head, [pull], [{
                "name": CACHE.JOB, "steps": [
                    {"name": CACHE.UPLOAD_STEP, "conclusion": "failure"},
                ],
            }], None),
            ("unsupported bot", "not an eligible same-repository writer", head,
             [pull], accepted_upload, None),
            ("incompatible manifest", "compatibility mismatch", head, [pull],
             accepted_upload, {"compatibility": {"bazelVersion": "wrong"}}),
            ("invalid cache contents", "invalid ActionResult", head, [pull], accepted_upload,
             {"invalid_cache": True}),
        )

        def artifact_fixture(label, manifest_changes=None):
            root = self.root / label
            root.mkdir()
            snapshot = root / "snapshot.tar"
            if manifest_changes == {"invalid_cache": True}:
                with tarfile.open(snapshot, "w:") as archive:
                    content = b"\xff"
                    entry = tarfile.TarInfo(f"ac/aa/{'a' * 64}")
                    entry.size = len(content)
                    archive.addfile(entry, io.BytesIO(content))
                manifest_changes = None
            else:
                source = root / "source"
                source.mkdir()
                make_cache(source)
                CACHE.snapshot(source, snapshot)
            archive_digest = hashlib.sha256(snapshot.read_bytes()).hexdigest()
            manifest = {
                "format": CACHE.FORMAT, "formatVersion": CACHE.FORMAT_VERSION,
                "repository": "owner/repo", "workflow": CACHE.WORKFLOW, "job": CACHE.JOB,
                "runId": 42, "runAttempt": 1, "event": "pull_request",
                "builtCommit": head, "sourceCommit": head, "producerHeadSha": head,
                "baseCommit": base_commit,
                "pullRequest": {"number": 17, "head": head, "base": base_commit},
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
            if manifest_changes:
                manifest.update(manifest_changes)
            zipped = root / "artifact.zip"
            with zipfile.ZipFile(zipped, "w") as archive:
                archive.writestr("manifest.json", json.dumps(manifest))
                archive.write(snapshot, "snapshot.tar")
            return {
                "id": 88, "name": "bazel-cache-v2-pr-17-r42-a1",
                "size_in_bytes": zipped.stat().st_size,
                "workflow_run": {"id": 42},
            }, zipped

        artifact, zipped = artifact_fixture("accepted-pr-candidate")
        destination = self.root / "accepted-pr-candidate-cache"
        api_calls = []

        def copy_artifact(url, token, path, maximum):
            shutil.copyfile(zipped, path)
            return path.stat().st_size

        def fake_json(url, token):
            api_calls.append(url)
            return [pull] if url == association else None

        with patch.object(CACHE, "request_file", side_effect=copy_artifact), \
                patch.object(CACHE, "producer_attempt", return_value=detail), \
                patch.object(CACHE, "jobs_for_attempt", return_value=accepted_upload), \
                patch.object(CACHE, "request_json", side_effect=fake_json), \
                redirect_stdout(io.StringIO()) as output:
            self.assertIsNone(CACHE.download_candidate(
                "https://api.github.com/repos/owner/repo", "token", artifact,
                destination, "owner/repo", run, "pr", 17,
                expected_head=head, require_trusted_writer=True,
            ))
        self.assertIn("authorization=pinned Copilot identity", output.getvalue())
        self.assertTrue(destination.is_dir())
        self.assertTrue(all("/collaborators/" not in url for url in api_calls))

        for index, (label, error, expected_head, pulls, jobs, changes) in enumerate(rejected_cases):
            with self.subTest(case=label):
                artifact, zipped = artifact_fixture(f"pr-candidate-{index}", changes)
                destination = self.root / f"rejected-candidate-{index}"
                api_calls = []
                candidate_run = run
                candidate_detail = detail
                if label == "unsupported bot":
                    unknown_bot = {"login": "OtherBot", "id": 123, "type": "Bot"}
                    candidate_run = {**run, "actor": unknown_bot}
                    candidate_detail = {**detail, "actor": unknown_bot}

                def copy_artifact(url, token, path, maximum):
                    shutil.copyfile(zipped, path)
                    return path.stat().st_size

                def fake_json(url, token):
                    api_calls.append(url)
                    return pulls if url == association else None

                with patch.object(CACHE, "request_file", side_effect=copy_artifact), \
                        patch.object(CACHE, "producer_attempt", return_value=candidate_detail), \
                        patch.object(CACHE, "jobs_for_attempt", return_value=jobs), \
                        patch.object(CACHE, "request_json", side_effect=fake_json), \
                        redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(CACHE.Invalid, error):
                        CACHE.download_candidate(
                            "https://api.github.com/repos/owner/repo", "token", artifact,
                            destination, "owner/repo", candidate_run, "pr", 17,
                            expected_head=expected_head, require_trusted_writer=True,
                        )
                self.assertFalse(destination.exists())
                self.assertTrue(all("/collaborators/" not in url for url in api_calls))

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
             "event": "pull_request", "pull_requests": []},
            {"id": 5, "run_number": 11, "run_attempt": 1, "head_sha": "new",
             "event": "pull_request"},
            {"id": 6, "run_number": 99, "run_attempt": 1, "head_sha": "other",
             "event": "pull_request", "pull_requests": []},
        ]
        selected = CACHE.rank_runs(runs, "pr", 17, {})
        self.assertEqual([run["id"] for run in selected], [6, 5, 4])
        artifact_runs = []
        artifacts = [
            {"name": "bazel-cache-v2-pr-17-r4-a1"},
            {"name": "bazel-cache-v2-pr-17-r4-a3"},
            {"name": "bazel-cache-v2-pr-17-r4-a2"},
        ]
        with patch.object(CACHE, "paginated", side_effect=lambda url, token, key: (
            artifact_runs.append(url) or artifacts
        )):
            ordered = CACHE.artifacts_for_run("https://api.github.com/repos/owner/repo", "token", runs[0])
        self.assertEqual([item["name"].rsplit("-a", 1)[1] for item in ordered], ["3", "2", "1"])
        self.assertEqual(artifact_runs, [
            "https://api.github.com/repos/owner/repo/actions/runs/4/artifacts"
        ])

    def test_commit_to_pr_association_authenticates_historical_head_uniquely(self):
        head = "a" * 40
        advanced_pull = {
            "number": 17,
            "head": {"sha": "b" * 40},
            "base": {"sha": "c" * 40, "repo": {"full_name": "owner/repo"}},
        }
        with patch.object(CACHE, "request_json", return_value=[advanced_pull]):
            self.assertEqual(
                CACHE.resolve_pr_association(
                    "https://api.github.com/repos/owner/repo", "token", "owner/repo",
                    head, 17,
                ),
                advanced_pull,
            )
        with patch.object(CACHE, "request_json", return_value=[
            advanced_pull,
            {**advanced_pull, "number": 18},
        ]):
            with self.assertRaisesRegex(CACHE.Invalid, "ambiguous"):
                CACHE.resolve_pr_association(
                    "https://api.github.com/repos/owner/repo", "token", "owner/repo",
                    head, 17,
                )
        with patch.object(CACHE, "request_json", return_value=[]):
            with self.assertRaisesRegex(CACHE.Invalid, "missing"):
                CACHE.resolve_pr_association(
                    "https://api.github.com/repos/owner/repo", "token", "owner/repo",
                    head, 17,
                )

    def test_pr_selection_excludes_newer_runs_and_keeps_prior_attempts(self):
        runs = [
            {"id": 1, "run_number": 19, "run_attempt": 5,
             "event": "pull_request", "pull_requests": [{"number": 17}]},
            {"id": 2, "run_number": 20, "run_attempt": 1,
             "event": "pull_request", "pull_requests": [{"number": 17}]},
            {"id": 3, "run_number": 20, "run_attempt": 2,
             "event": "pull_request", "pull_requests": [{"number": 17}]},
            {"id": 4, "run_number": 20, "run_attempt": 3,
             "event": "pull_request", "pull_requests": [{"number": 17}]},
            {"id": 5, "run_number": 21, "run_attempt": 1,
             "event": "pull_request", "pull_requests": [{"number": 17}]},
        ]
        selected = CACHE.rank_runs(runs, "pr", 17, {}, 20)
        self.assertEqual([run["id"] for run in selected], [4, 3, 2, 1])
        current = runs[2]
        self.assertTrue(CACHE.pr_attempt_is_eligible(current, 1, 3, 20, 2))
        self.assertFalse(CACHE.pr_attempt_is_eligible(current, 2, 3, 20, 2))
        self.assertFalse(CACHE.pr_attempt_is_eligible(current, 3, 3, 20, 2))
        self.assertFalse(CACHE.pr_attempt_is_eligible(runs[4], 1, 3, 20, 2))

    def test_restore_logs_legacy_pr_migration_skip(self):
        run = {
            "id": 1, "run_number": 2, "run_attempt": 1, "head_sha": "a" * 40,
            "event": "pull_request",
        }
        artifact = {"id": 2, "name": "bazel-cache-v1-pr-17-r1-a1"}
        args = SimpleNamespace(run_number=10, run_id="99", run_attempt="1")
        output = io.StringIO()
        with patch.object(CACHE, "paginated", return_value=[run]), \
                patch.object(CACHE, "artifacts_for_run", return_value=[artifact]), \
                patch.object(CACHE, "download_candidate") as download, \
                redirect_stdout(output):
            restored = CACHE.restore_scope(
                args, "https://api.github.com/repos/owner/repo", "token",
                "pr", 17, {}, self.root / "cache",
            )
        self.assertFalse(restored)
        download.assert_not_called()
        self.assertIn("migration-skip", output.getvalue())

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

    def test_squash_association_is_unique_and_uses_the_final_pr_head(self):
        commit = "a" * 40
        final_head = "b" * 40
        pull = {
            "number": 17, "state": "closed", "merged_at": "2026-11-03T00:00:00Z",
            "merge_commit_sha": commit,
            "base": {"ref": "main", "repo": {"full_name": "owner/repo"}},
            "head": {"sha": final_head, "repo": {"full_name": "owner/repo"}},
        }
        with patch.object(CACHE, "request_json", return_value=[pull]):
            selected = CACHE.squash_pull_request(
                "https://api.github.com/repos/owner/repo", "token", "owner/repo", commit
            )
        self.assertEqual(selected["head"]["sha"], final_head)

        with patch.object(CACHE, "request_json", return_value=[]):
            self.assertIsNone(CACHE.squash_pull_request(
                "https://api.github.com/repos/owner/repo", "token", "owner/repo", commit
            ))
        with patch.object(CACHE, "request_json", return_value=[pull, pull]):
            self.assertIs(
                CACHE.squash_pull_request(
                    "https://api.github.com/repos/owner/repo", "token", "owner/repo", commit
                ),
                False,
            )
        fork_pull = json.loads(json.dumps(pull))
        fork_pull["head"]["repo"]["full_name"] = "contributor/repo"
        with patch.object(CACHE, "request_json", return_value=[fork_pull]):
            self.assertIs(
                CACHE.squash_pull_request(
                    "https://api.github.com/repos/owner/repo", "token", "owner/repo", commit
                ),
                False,
            )

    def test_pinned_copilot_identity_is_authorized_without_collaborator_lookup(self):
        actor = {"login": "Copilot", "id": 198982749, "type": "Bot"}
        run = {"actor": actor}
        detail = {
            "actor": actor,
            "repository": {"id": 42, "full_name": "owner/repo"},
            "head_repository": {"id": 42, "full_name": "owner/repo"},
        }
        with patch.object(CACHE, "request_json") as request:
            with redirect_stdout(io.StringIO()) as output:
                self.assertTrue(CACHE.trusted_pr_writer(
                    "https://api.github.com/repos/owner/repo", "token", run, detail,
                    "owner/repo", 17,
                ))
            request.assert_not_called()
        self.assertIn("authorization=pinned Copilot identity", output.getvalue())

    def test_pinned_copilot_rejects_mismatched_malformed_and_unsupported_identities(self):
        copilot = {"login": "Copilot", "id": 198982749, "type": "Bot"}
        invalid_identities = [
            {"login": "Copilot", "id": 198982748, "type": "Bot"},
            {"login": "other-bot", "id": 198982749, "type": "Bot"},
            {"login": "Copilot", "id": 198982749, "type": "User"},
            {"login": "other-bot", "id": 14, "type": "Bot"},
            {"login": "Copilot", "id": "198982749", "type": "Bot"},
            {"login": "Copilot", "id": True, "type": "Bot"},
            {"login": "Copilot", "type": "Bot"},
            {"login": "Copilot", "id": None, "type": "Bot"},
            {"id": 198982749, "type": "Bot"},
            {"login": "Copilot", "id": 198982749},
        ]
        detail_base = {
            "repository": {"id": 42, "full_name": "owner/repo"},
            "head_repository": {"id": 42, "full_name": "owner/repo"},
        }
        with patch.object(CACHE, "request_json") as request:
            for identity in invalid_identities:
                with self.subTest(identity=identity):
                    self.assertFalse(CACHE.trusted_pr_writer(
                        "https://api.github.com/repos/owner/repo", "token",
                        {"actor": identity},
                        {**detail_base, "actor": identity},
                        "owner/repo", 17,
                    ))
            self.assertFalse(CACHE.trusted_pr_writer(
                "https://api.github.com/repos/owner/repo", "token",
                {"actor": copilot},
                {**detail_base, "actor": {"login": "Copilot", "id": 8, "type": "Bot"}},
                "owner/repo", 17,
            ))
            self.assertFalse(CACHE.trusted_pr_writer(
                "https://api.github.com/repos/owner/repo", "token",
                {
                    "actor": {"login": "unknown", "id": 9, "type": "Bot"},
                    "triggering_actor": copilot,
                },
                {**detail_base, "actor": {"login": "unknown", "id": 9, "type": "Bot"}},
                "owner/repo", 17,
            ))
            fork = {
                **detail_base,
                "actor": copilot,
                "head_repository": {"id": 43, "full_name": "fork/repo"},
            }
            self.assertFalse(CACHE.trusted_pr_writer(
                "https://api.github.com/repos/owner/repo", "token",
                {"actor": copilot}, fork, "owner/repo", 17,
            ))
            request.assert_not_called()

    def test_human_writer_still_requires_matching_identity_and_verified_write_permission(self):
        actor = {"login": "trusted-writer", "id": 13, "type": "User"}
        run = {"actor": actor}
        detail = {
            "actor": actor,
            "repository": {"id": 42, "full_name": "owner/repo"},
            "head_repository": {"id": 42, "full_name": "owner/repo"},
        }
        for permission_name in ("admin", "maintain", "write"):
            with self.subTest(permission=permission_name), patch.object(
                CACHE, "request_json",
                return_value={"user": {"login": "trusted-writer"}, "permission": permission_name},
            ):
                self.assertTrue(CACHE.trusted_pr_writer(
                    "https://api.github.com/repos/owner/repo", "token", run, detail,
                    "owner/repo", 17,
                ))
        for response in (
            {"user": {"login": "trusted-writer"}, "permission": "read"},
            {"user": {"login": "trusted-writer"}, "permission": "triage"},
            {"user": {"login": "trusted-writer"}, "permission": "unknown"},
            {"permission": "write"},
            {"user": [], "permission": "write"},
        ):
            with self.subTest(response=response), patch.object(
                CACHE, "request_json", return_value=response,
            ):
                self.assertFalse(CACHE.trusted_pr_writer(
                    "https://api.github.com/repos/owner/repo", "token", run, detail,
                    "owner/repo", 17,
                ))

        for malformed_actor in (
            {"login": "trusted-writer", "id": "13", "type": "User"},
            {"login": "trusted-writer", "id": True, "type": "User"},
            {"login": "trusted-writer", "type": "User"},
            {"login": "trusted-writer", "id": 13},
        ):
            with self.subTest(actor=malformed_actor), patch.object(
                CACHE, "request_json",
            ) as request:
                self.assertFalse(CACHE.trusted_pr_writer(
                    "https://api.github.com/repos/owner/repo", "token",
                    {"actor": malformed_actor},
                    {**detail, "actor": malformed_actor},
                    "owner/repo", 17,
                ))
                request.assert_not_called()

        with patch.object(CACHE, "request_json", return_value=None), \
                redirect_stdout(io.StringIO()) as output:
            self.assertFalse(CACHE.trusted_pr_writer(
                "https://api.github.com/repos/owner/repo", "token", run, detail,
                "owner/repo", 17,
            ))
        self.assertIn("permission metadata is unavailable", output.getvalue())
        for error in (CACHE.ApiFailure("GitHub API returned HTTP 403"),
                      CACHE.ApiFailure("GitHub API request failed after bounded retries")):
            with self.subTest(error=error), patch.object(
                CACHE, "request_json", side_effect=error,
            ):
                with self.assertRaises(CACHE.ApiFailure):
                    CACHE.trusted_pr_writer(
                        "https://api.github.com/repos/owner/repo", "token", run, detail,
                        "owner/repo", 17,
                    )

        forged = {**detail, "actor": {"login": "other-user", "id": 13, "type": "User"}}
        self.assertFalse(CACHE.trusted_pr_writer(
            "https://api.github.com/repos/owner/repo", "token", run, forged,
            "owner/repo", 17,
        ))
        fork = json.loads(json.dumps(detail))
        fork["head_repository"]["id"] = 43
        self.assertFalse(CACHE.trusted_pr_writer(
            "https://api.github.com/repos/owner/repo", "token", run, fork,
            "owner/repo", 17,
        ))

    def test_squash_restore_uses_preceding_main_and_final_head_pr_snapshot(self):
        event_path = self.root / "event.json"
        event_path.write_text("{}")
        squash_sha = "a" * 40
        final_head = "b" * 40
        pull = {"number": 17, "head": {"sha": final_head}}
        args = SimpleNamespace(
            repository="owner/repo", event_path=str(event_path), event_name="push",
            pr_number="", run_id="99", run_number=50, run_attempt="1",
            commit=squash_sha, cache=str(self.root / "cache"),
        )
        history = {squash_sha: 0, "previous-main": 1}
        restored = []
        results = {"main": True, "pr": True}

        def fake_restore(args, base, token, scope, pr_number, revisions, destination,
                         expected_head=None, require_trusted_writer=False):
            restored.append((scope, pr_number, dict(revisions), expected_head, require_trusted_writer))
            if results[scope]:
                Path(destination).mkdir(parents=True)
            return results[scope]

        output = io.StringIO()
        with patch.dict(os.environ, {"GITHUB_TOKEN": "fixture"}), \
                patch.object(CACHE, "run_history", return_value=history), \
                patch.object(CACHE, "squash_pull_request", return_value=pull), \
                patch.object(CACHE, "restore_scope", side_effect=fake_restore), \
                patch.object(CACHE, "union_caches") as union, \
                redirect_stdout(output):
            CACHE.discover_and_restore(args)

        self.assertEqual(restored, [
            ("main", None, {"previous-main": 1}, None, False),
            ("pr", 17, {}, final_head, True),
        ])
        union.assert_called_once()
        self.assertNotIn(squash_sha, dict(restored[0][2]))

    def test_squash_fallbacks_preserve_an_independently_available_source(self):
        event_path = self.root / "event.json"
        event_path.write_text("{}")
        squash_sha = "a" * 40
        pull = {"number": 17, "head": {"sha": "b" * 40}}
        args = SimpleNamespace(
            repository="owner/repo", event_path=str(event_path), event_name="push",
            pr_number="", run_id="99", run_number=50, run_attempt="1",
            commit=squash_sha, cache=str(self.root / "cache"),
        )
        outcomes = [
            ({"main": True, "pr": False}, "main", "main"),
            ({"main": False, "pr": True}, "pr", "PR"),
        ]
        for index, (results, selected, display) in enumerate(outcomes):
            with self.subTest(selected=selected):
                args.cache = str(self.root / f"cache-{index}")
                restored = []

                def fake_restore(args, base, token, scope, pr_number, history, destination,
                                 expected_head=None, require_trusted_writer=False):
                    restored.append(scope)
                    if results[scope]:
                        Path(destination).mkdir(parents=True)
                    return results[scope]

                output = io.StringIO()
                with patch.dict(os.environ, {"GITHUB_TOKEN": "fixture"}), \
                        patch.object(CACHE, "run_history", return_value={squash_sha: 0, "prev": 1}), \
                        patch.object(CACHE, "squash_pull_request", return_value=pull), \
                        patch.object(CACHE, "restore_scope", side_effect=fake_restore), \
                        patch.object(CACHE, "copy_cache") as copy, \
                        patch.object(CACHE, "union_caches") as union, \
                        redirect_stdout(output):
                    CACHE.discover_and_restore(args)

                self.assertEqual(restored, ["main", "pr"])
                copy.assert_called_once()
                self.assertEqual(Path(copy.call_args.args[0]).name, selected)
                self.assertEqual(Path(copy.call_args.args[1]), Path(args.cache))
                self.assertIn(f"using {display}-only snapshot", output.getvalue())
                union.assert_not_called()

    def test_union_failure_falls_back_to_the_independently_valid_main_cache(self):
        event_path = self.root / "event.json"
        event_path.write_text("{}")
        squash_sha = "a" * 40
        args = SimpleNamespace(
            repository="owner/repo", event_path=str(event_path), event_name="push",
            pr_number="", run_id="99", run_number=50, run_attempt="1",
            commit=squash_sha, cache=str(self.root / "cache"),
        )

        def fake_restore(args, base, token, scope, pr_number, history, destination,
                         expected_head=None, require_trusted_writer=False):
            Path(destination).mkdir(parents=True)
            return True

        output = io.StringIO()
        with patch.dict(os.environ, {"GITHUB_TOKEN": "fixture"}), \
                patch.object(CACHE, "run_history", return_value={squash_sha: 0, "prev": 1}), \
                patch.object(CACHE, "squash_pull_request", return_value={
                    "number": 17, "head": {"sha": "b" * 40},
                }), \
                patch.object(CACHE, "restore_scope", side_effect=fake_restore), \
                patch.object(CACHE, "union_caches", side_effect=CACHE.Invalid("union limit")), \
                patch.object(CACHE, "copy_cache") as copy, \
                redirect_stdout(output):
            CACHE.discover_and_restore(args)

        copy.assert_called_once()
        self.assertEqual(Path(copy.call_args.args[0]).name, "main")
        self.assertIn("union-rejected pr=17", output.getvalue())

    def test_squash_with_no_sources_runs_cold_and_ambiguous_metadata_uses_main_only(self):
        event_path = self.root / "event.json"
        event_path.write_text("{}")
        squash_sha = "a" * 40
        args = SimpleNamespace(
            repository="owner/repo", event_path=str(event_path), event_name="push",
            pr_number="", run_id="99", run_number=50, run_attempt="1",
            commit=squash_sha, cache=str(self.root / "cache"),
        )
        for pull, expected_scopes, expected_log in (
            ({"number": 17, "head": {"sha": "b" * 40}}, ["main", "pr"], "cold build"),
            (False, ["main"], "using main-only snapshot"),
        ):
            restored = []

            def fake_restore(args, base, token, scope, pr_number, history, destination,
                             expected_head=None, require_trusted_writer=False):
                restored.append((scope, dict(history)))
                return False

            output = io.StringIO()
            with patch.dict(os.environ, {"GITHUB_TOKEN": "fixture"}), \
                    patch.object(CACHE, "run_history", return_value={squash_sha: 0, "prev": 1}), \
                    patch.object(CACHE, "squash_pull_request", return_value=pull), \
                    patch.object(CACHE, "restore_scope", side_effect=fake_restore), \
                    redirect_stdout(output):
                CACHE.discover_and_restore(args)

            self.assertEqual([scope for scope, _ in restored], expected_scopes)
            self.assertTrue(all(squash_sha not in revisions for _, revisions in restored))
            self.assertIn(expected_log, output.getvalue())

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
            2: [{"id": 22, "name": "bazel-cache-v2-pr-17-r2-a1"}],
            1: [{"id": 11, "name": "bazel-cache-v2-pr-17-r1-a1"}],
        }
        calls = []

        def fake_download(base, token, artifact, cache_path, repository, run, scope, pr_number):
            calls.append((run["id"], artifact["id"], scope, pr_number))
            if run["id"] == 2:
                raise CACHE.Invalid("corrupt snapshot")
            return None

        args = SimpleNamespace(
            repository="owner/repo", event_path=str(event_path), event_name="pull_request",
            pr_number="17", run_id="99", run_number=99, run_attempt="1", commit="c" * 40,
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
        artifacts = {1: [], 2: [{"id": 22, "name": "bazel-cache-v2-main-r2-a1"}]}
        calls = []

        def fake_paginated(url, token, key, page_size=100):
            return [pr_run] if "event=pull_request" in url else [main_run]

        def fake_download(base, token, artifact, cache_path, repository, run, scope, pr_number):
            calls.append((run["id"], artifact["id"], scope))
            return None

        args = SimpleNamespace(
            repository="owner/repo", event_path=str(event_path), event_name="pull_request",
            pr_number="17", run_id="99", run_number=99, run_attempt="1", commit="c" * 40,
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
        head = "a" * 40
        base = "b" * 40
        run = {
            "id": 25, "run_number": 4, "run_attempt": 2, "workflow_id": 9,
            "head_sha": head, "event": "pull_request", "head_branch": "feature",
            "repository": {"id": 9, "full_name": "owner/repo"},
        }
        detail = {
            **run, "repository": {"id": 9, "full_name": "owner/repo"},
            "path": CACHE.WORKFLOW, "name": "Publish", "conclusion": "failure",
        }
        jobs = [{"name": CACHE.JOB, "conclusion": "failure", "steps": [
            {"name": "check project formatting", "conclusion": "success"},
            {"name": "Bazel precommit checks and unit tests", "conclusion": "failure"},
            {"name": CACHE.UPLOAD_STEP, "conclusion": "success"},
        ]}]
        manifest = {
            "repository": "owner/repo", "workflow": CACHE.WORKFLOW,
            "job": CACHE.JOB, "runId": 25, "runAttempt": 2,
            "event": "pull_request", "builtCommit": head,
            "sourceCommit": head, "producerHeadSha": head, "baseCommit": base,
            "pullRequest": {"number": 3, "head": head, "base": base},
        }
        associated_pr = {
            "number": 3, "head": {"sha": "c" * 40},
            "base": {"sha": "d" * 40, "repo": {"id": 9, "full_name": "owner/repo"}},
        }
        CACHE.verify_producer(
            run, detail, jobs, manifest, "bazel-cache-v2-pr-3-r25-a2", "pr", 3,
            "owner/repo", associated_pr,
        )
        for conclusion in ("failure", "skipped", "cancelled"):
            with self.subTest(upload_conclusion=conclusion):
                rejected_jobs = [{"name": CACHE.JOB, "steps": [
                    {"name": CACHE.UPLOAD_STEP, "conclusion": conclusion},
                ]}]
                with self.assertRaisesRegex(CACHE.Invalid, "upload step"):
                    CACHE.verify_producer(
                        run, detail, rejected_jobs, manifest,
                        "bazel-cache-v2-pr-3-r25-a2", "pr", 3,
                        "owner/repo", associated_pr,
                    )
        with self.assertRaisesRegex(CACHE.Invalid, "identity"):
            CACHE.verify_producer(
                run, detail, jobs, manifest, "bazel-cache-v2-pr-3-r25-a2",
                "pr", 4, "owner/repo", associated_pr,
            )
        with self.assertRaisesRegex(CACHE.Invalid, "metadata mismatch"):
            CACHE.verify_producer(
                run, {**detail, "path": "other.yml"}, jobs, manifest,
                "bazel-cache-v2-pr-3-r25-a2", "pr", 3, "owner/repo", associated_pr,
            )
        with self.assertRaisesRegex(CACHE.Invalid, "metadata mismatch"):
            CACHE.verify_producer(
                run, {**detail, "repository": {"full_name": "fork/repo"}}, jobs,
                manifest, "bazel-cache-v2-pr-3-r25-a2", "pr", 3, "owner/repo", associated_pr,
            )
        with self.assertRaisesRegex(CACHE.Invalid, "source or commit-to-PR"):
            CACHE.verify_producer(
                run, detail, jobs, {**manifest, "sourceCommit": base},
                "bazel-cache-v2-pr-3-r25-a2", "pr", 3, "owner/repo", associated_pr,
            )
        with self.assertRaisesRegex(CACHE.Invalid, "final PR head"):
            CACHE.verify_producer(
                run, detail, jobs, manifest, "bazel-cache-v2-pr-3-r25-a2",
                "pr", 3, "owner/repo", associated_pr, "different-final-head",
            )

    def test_main_identity_rejects_pr_producers(self):
        run = {
            "id": 26, "run_number": 5, "workflow_id": 9, "head_sha": "b" * 40,
            "event": "push", "head_branch": "main",
            "repository": {"id": 9, "full_name": "owner/repo"},
        }
        detail = {
            **run, "run_attempt": 1, "repository": {"id": 9, "full_name": "owner/repo"},
            "path": CACHE.WORKFLOW, "name": "Publish",
        }
        job = [{"name": CACHE.JOB, "steps": [
            {"name": CACHE.UPLOAD_STEP, "conclusion": "success"},
        ]}]
        manifest = {
            "repository": "owner/repo", "workflow": CACHE.WORKFLOW,
            "job": CACHE.JOB, "runId": 26, "runAttempt": 1, "event": "push",
            "builtCommit": "b" * 40, "sourceCommit": "b" * 40,
            "producerHeadSha": "b" * 40, "baseCommit": None,
            "pullRequest": {"number": 7, "head": "c" * 40, "base": "d" * 40},
        }
        with self.assertRaisesRegex(CACHE.Invalid, "invalid producer scope"):
            CACHE.verify_producer(
                run, detail, job, manifest, "bazel-cache-v2-main-r26-a1",
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
            "builtCommit": "a" * 40, "sourceCommit": "a" * 40,
            "producerHeadSha": "a" * 40, "baseCommit": None, "pullRequest": None,
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

    def test_pr_manifest_records_only_the_verified_direct_head_as_built_source(self):
        source = "a" * 40
        base = "b" * 40
        event_path = self.root / "event.json"
        event_path.write_text(json.dumps({
            "pull_request": {
                "number": 17,
                "head": {"sha": source},
                "base": {"sha": base},
            },
        }))
        archive = self.root / "snapshot.tar"
        archive.write_bytes(b"snapshot")
        args = SimpleNamespace(
            event_path=str(event_path), event_name="pull_request", repository="owner/repo",
            run_id="1", run_attempt="1", commit=source, pr_number="17",
        )

        manifest = CACHE.make_manifest(args, archive)

        self.assertEqual(manifest["builtCommit"], source)
        self.assertEqual(manifest["sourceCommit"], source)
        self.assertEqual(manifest["producerHeadSha"], source)
        self.assertEqual(manifest["pullRequest"], {
            "number": 17, "head": source, "base": base,
        })
        self.assertEqual(manifest["baseCommit"], base)
        with self.assertRaisesRegex(CACHE.Invalid, "differs from the pull request head"):
            CACHE.make_manifest(SimpleNamespace(**{**vars(args), "commit": "c" * 40}), archive)

    def test_action_execution_diagnostics_count_hits_and_executions(self):
        logfile = self.root / "execution.json"
        sample_path = ROOT / ".scripts/tests/fixtures/bazel-cache-artifacts-execution-log.json"
        sample = sample_path.read_text()
        logfile.write_text(sample + sample)
        output = io.StringIO()
        with redirect_stdout(output):
            CACHE.report_action_logs([f"checks={logfile}"])
        self.assertIn("stage=checks hits=0 executions=2 records=2", output.getvalue())


if __name__ == "__main__":
    unittest.main()
