import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

from migrate import migrate


def create_v1_data(data_directory):
    data_directory = Path(data_directory)
    data_directory.mkdir(parents=True, exist_ok=True)
    (data_directory / "storage-version").write_text("1\n", encoding="ascii")
    connection = sqlite3.connect(data_directory / "tags.sqlite")
    connection.executescript(
        """
        CREATE TABLE tags (
          id TEXT PRIMARY KEY NOT NULL,
          category TEXT NOT NULL CHECK (
            category IN ('cuisine', 'dietary-style', 'course')
          ),
          name TEXT NOT NULL
        );
        CREATE TABLE assignments (
          recipe_id TEXT NOT NULL,
          tag_id TEXT NOT NULL REFERENCES tags(id),
          PRIMARY KEY (recipe_id, tag_id)
        ) WITHOUT ROWID;
        INSERT INTO tags VALUES ('legacy-cuisine', 'cuisine', 'Thai');
        INSERT INTO tags VALUES ('legacy-course', 'course', 'Soup');
        INSERT INTO assignments VALUES ('recipe/one', 'legacy-cuisine');
        INSERT INTO assignments VALUES ('recipe/one', 'legacy-course');
        INSERT INTO assignments VALUES ('recipe/two', 'legacy-course');
        """
    )
    connection.close()


def verify_v2_data(data_directory):
    data_directory = Path(data_directory)
    if (data_directory / "storage-version").read_text(encoding="ascii") != "2\n":
        raise AssertionError("migration did not publish version 2")
    connection = sqlite3.connect(data_directory / "tags.sqlite")
    tags = connection.execute(
        "SELECT id, category, name FROM tags ORDER BY id"
    ).fetchall()
    assignments = connection.execute(
        "SELECT recipe_id, tag_id FROM assignments ORDER BY recipe_id, tag_id"
    ).fetchall()
    if tags != [
        ("legacy-course", "course", "Soup"),
        ("legacy-cuisine", "cuisine", "Thai"),
    ]:
        raise AssertionError(f"migration changed existing tags: {tags}")
    if assignments != [
        ("recipe/one", "legacy-course"),
        ("recipe/one", "legacy-cuisine"),
        ("recipe/two", "legacy-course"),
    ]:
        raise AssertionError(f"migration changed recipe assignments: {assignments}")
    connection.execute(
        "INSERT INTO tags VALUES ('other-general', 'other', 'General')"
    )
    other_tag = connection.execute(
        "SELECT id, category, name FROM tags WHERE category = 'other'"
    ).fetchone()
    if other_tag != ("other-general", "other", "General"):
        raise AssertionError(f"OTHER tag could not be stored and retrieved: {other_tag}")
    connection.close()


class TagsMigrationTest(unittest.TestCase):
    def test_preserves_tags_and_assignments_and_allows_other(self):
        with tempfile.TemporaryDirectory() as directory:
            create_v1_data(directory)
            migrate(directory)
            verify_v2_data(directory)

    def test_rejects_unexpected_version_without_changing_database(self):
        with tempfile.TemporaryDirectory() as directory:
            create_v1_data(directory)
            marker = Path(directory) / "storage-version"
            marker.write_text("3\n", encoding="ascii")
            database = Path(directory) / "tags.sqlite"
            before = database.read_bytes()
            with self.assertRaisesRegex(RuntimeError, "expected storage version 1"):
                migrate(directory)
            self.assertEqual(database.read_bytes(), before)
            self.assertEqual(marker.read_text(encoding="ascii"), "3\n")

    def test_rejects_invalid_v1_data_without_publishing_version(self):
        with tempfile.TemporaryDirectory() as directory:
            create_v1_data(directory)
            database = Path(directory) / "tags.sqlite"
            connection = sqlite3.connect(database)
            connection.execute("PRAGMA ignore_check_constraints = ON")
            connection.execute(
                "INSERT INTO tags VALUES ('bad', 'unknown', 'Invalid')"
            )
            connection.commit()
            connection.close()
            before = database.read_bytes()
            with self.assertRaisesRegex(RuntimeError, "integrity check failed"):
                migrate(directory)
            self.assertEqual(database.read_bytes(), before)
            self.assertEqual(
                (Path(directory) / "storage-version").read_text(encoding="ascii"),
                "1\n",
            )

if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--create-fixture":
        create_v1_data(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "--verify":
        verify_v2_data(sys.argv[2])
    else:
        unittest.main()
