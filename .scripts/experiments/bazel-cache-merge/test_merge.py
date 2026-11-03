import hashlib
from pathlib import Path
import tempfile
import unittest

from merge import Invalid, merge, snapshot


def integer(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def message(number, value):
    return integer(number * 8 + 2) + integer(len(value)) + value


def put(root, kind, key, data):
    path = root / kind / key[:2] / key
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def result(root, key, content, output="file.out", executable=False):
    hashed = hashlib.sha256(content).hexdigest()
    put(root, "cas", hashed, content)
    digest = message(1, hashed.encode()) + b"\x10" + integer(len(content))
    file = message(1, output.encode()) + message(2, digest)
    if executable:
        file += b"\x20\x01"
    data = message(2, file)
    put(root, "ac", key, data)
    return data, hashed


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.main, self.pr, self.dest = [self.root / n for n in ("main", "pr", "union")]
        self.main.mkdir()
        self.pr.mkdir()
        self.key = "a" * 64
        self.data, self.blob = result(self.main, self.key, b"main", executable=True)

    def rejected(self, pattern):
        with self.assertRaisesRegex(Invalid, pattern):
            merge(self.main, self.pr, self.dest)
        self.assertFalse(self.dest.exists())

    def test_identical_duplicates_and_temporary_exclusion(self):
        result(self.pr, self.key, b"main", executable=True)
        (self.pr / "tmp").mkdir()
        (self.pr / "tmp/partial").write_bytes(b"incomplete")
        stats = merge(self.main, self.pr, self.dest)
        self.assertEqual(stats["identical"], 2)
        self.assertEqual(stats["temporary_excluded"], 1)
        self.assertFalse((self.dest / "tmp").exists())
        self.assertEqual(snapshot(self.dest)[0], snapshot(self.main)[0])

    def test_main_wins_different_valid_results_and_both_blobs_survive(self):
        _, other = result(self.pr, self.key, b"pr", executable=True)
        stats = merge(self.main, self.pr, self.dest)
        entries, _ = snapshot(self.dest)
        self.assertEqual(stats["main_wins"], 1)
        self.assertEqual(entries["ac"][self.key], self.data)
        self.assertEqual(set(entries["cas"]), {self.blob, other})
        ac = self.dest / "ac" / self.key[:2] / self.key
        self.assertLessEqual(ac.stat().st_mtime_ns,
                             (self.dest / "cas" / self.blob[:2] / self.blob).stat().st_mtime_ns)

    def test_corrupt_blob_conflicting_with_valid_source_is_rejected(self):
        put(self.pr, "cas", self.blob, b"corrupt")
        self.rejected("CAS digest mismatch / conflicting bytes")

    def test_malformed_action_result_is_rejected_even_if_main_would_win(self):
        put(self.pr, "ac", self.key, b"\x12\xff")
        self.rejected("invalid ActionResult.*truncated")

    def test_missing_referenced_blob_rejected_even_if_other_source_has_it(self):
        put(self.pr, "ac", self.key, self.data)
        self.rejected("missing/wrong-size referenced blob")

    def test_wrong_size_reference_is_rejected(self):
        put(self.main, "ac", self.key, self.data.replace(b"\x10\x04", b"\x10\x05"))
        self.rejected("wrong-size")

    def test_incomplete_snapshot_without_action_result_is_safe(self):
        (self.main / "ac" / self.key[:2] / self.key).unlink()
        merge(self.main, self.pr, self.dest)
        self.assertEqual(snapshot(self.dest)[0]["ac"], {})

    def test_unsupported_layout_and_digest_prefix_are_rejected(self):
        for path in ("unknown", "gc/lock", "cas/ff/" + self.blob):
            with self.subTest(path=path):
                bad = self.pr / path
                bad.parent.mkdir(parents=True, exist_ok=True)
                bad.write_bytes(b"bad")
                self.rejected("unsupported")
                bad.unlink()
                if bad.parent != self.pr:
                    bad.parent.rmdir()

    def test_symlinks_are_rejected_including_temporary_entries(self):
        (self.pr / "tmp").mkdir()
        (self.pr / "tmp/link").symlink_to(self.main)
        self.rejected("symlink forbidden")

    def test_unsupported_outputs_failed_results_and_unsafe_paths(self):
        for data in (b"\x1a\x00", b"\x20\x01",
                     message(2, message(1, b"../escape")), b"\x00"):
            with self.subTest(data=data):
                put(self.pr, "ac", self.key, data)
                self.rejected("invalid ActionResult")

    def test_existing_destination_is_not_overwritten(self):
        self.dest.mkdir()
        with self.assertRaisesRegex(Invalid, "destination must not exist"):
            merge(self.main, self.pr, self.dest)


if __name__ == "__main__":
    unittest.main()
