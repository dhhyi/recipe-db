import os
import sqlite3
import stat
import sys
import tempfile
from pathlib import Path


VERSION_FILE = "storage-version"
DATABASE_FILE = "tags.sqlite"
SOURCE_VERSION = 1
TARGET_VERSION = 2
SOURCE_CATEGORIES = {"cuisine", "dietary-style", "course"}
TARGET_CATEGORIES = SOURCE_CATEGORIES | {"other"}


def _require_regular_file(path):
    try:
        mode = path.lstat().st_mode
    except OSError as error:
        raise RuntimeError(f"cannot inspect {path}: {error}") from error
    if not stat.S_ISREG(mode):
        raise RuntimeError(f"expected a regular file at {path}")


def _check_version(path, expected):
    _require_regular_file(path)
    try:
        contents = path.read_bytes()
    except OSError as error:
        raise RuntimeError(f"cannot read {path}: {error}") from error
    if contents != f"{expected}\n".encode():
        raise RuntimeError(f"expected storage version {expected} at {path}")


def _table_columns(connection, table):
    return [
        (row[1], row[2].upper(), row[3], row[5])
        for row in connection.execute(f"PRAGMA table_info({table})")
    ]


def _check_schema(connection, categories):
    tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        )
    }
    if tables != {"tags", "assignments"}:
        raise RuntimeError("unexpected tags database tables")
    if _table_columns(connection, "tags") != [
        ("id", "TEXT", 1, 1),
        ("category", "TEXT", 1, 0),
        ("name", "TEXT", 1, 0),
    ]:
        raise RuntimeError("unexpected tags table schema")
    if _table_columns(connection, "assignments") != [
        ("recipe_id", "TEXT", 1, 1),
        ("tag_id", "TEXT", 1, 2),
    ]:
        raise RuntimeError("unexpected assignments table schema")
    if _rows(connection, "PRAGMA foreign_key_list(assignments)") != [
        (0, 0, "tags", "tag_id", "id", "NO ACTION", "NO ACTION", "NONE")
    ]:
        raise RuntimeError("unexpected assignments foreign key")

    tags_sql = connection.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'tags'"
    ).fetchone()
    schema_sql = "".join(tags_sql[0].lower().split()) if tags_sql else ""
    expected_order = ("cuisine", "dietary-style", "course")
    if "other" in categories:
        expected_order += ("other",)
    expected_categories = ",".join(f"'{category}'" for category in expected_order)
    expected_check = f"check(categoryin({expected_categories}))"
    if expected_check not in schema_sql:
        raise RuntimeError("unexpected tag category constraint")


def _rows(connection, query):
    return connection.execute(query).fetchall()


def _validate_database(connection, categories):
    _check_schema(connection, categories)
    integrity = _rows(connection, "PRAGMA integrity_check")
    if integrity != [("ok",)]:
        raise RuntimeError("tags database integrity check failed")
    if _rows(connection, "PRAGMA foreign_key_check"):
        raise RuntimeError("tags database foreign key check failed")

    tags = _rows(connection, "SELECT id, category, name FROM tags ORDER BY id")
    if any(
        not isinstance(tag_id, str)
        or not tag_id
        or category not in categories
        or not isinstance(name, str)
        or not name
        for tag_id, category, name in tags
    ):
        raise RuntimeError("invalid tag data")
    assignments = _rows(
        connection,
        "SELECT recipe_id, tag_id FROM assignments ORDER BY recipe_id, tag_id",
    )
    tag_ids = {tag_id for tag_id, _, _ in tags}
    if any(
        not isinstance(recipe_id, str)
        or not recipe_id
        or not isinstance(tag_id, str)
        or tag_id not in tag_ids
        for recipe_id, tag_id in assignments
    ):
        raise RuntimeError("invalid recipe tag assignment")
    return tags, assignments


def _publish_version(path):
    _check_version(path, SOURCE_VERSION)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".storage-version-", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as file:
            file.write(f"{TARGET_VERSION}\n".encode())
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def migrate(data_directory=Path("/data")):
    data_directory = Path(data_directory)
    version_path = data_directory / VERSION_FILE
    database_path = data_directory / DATABASE_FILE
    _check_version(version_path, SOURCE_VERSION)
    _require_regular_file(database_path)

    connection = sqlite3.connect(
        database_path.resolve().as_uri() + "?mode=rw",
        uri=True,
        isolation_level=None,
    )
    try:
        connection.execute("PRAGMA foreign_keys = OFF")
        connection.execute("BEGIN IMMEDIATE")
        previous_tags, previous_assignments = _validate_database(
            connection, SOURCE_CATEGORIES
        )
        connection.execute(
            "CREATE TABLE tags_v2 ("
            "id TEXT PRIMARY KEY NOT NULL,"
            "category TEXT NOT NULL CHECK "
            "(category IN ('cuisine', 'dietary-style', 'course', 'other')),"
            "name TEXT NOT NULL)"
        )
        connection.executemany(
            "INSERT INTO tags_v2 (id, category, name) VALUES (?, ?, ?)",
            previous_tags,
        )
        connection.execute("DROP TABLE tags")
        connection.execute("ALTER TABLE tags_v2 RENAME TO tags")
        current_tags, current_assignments = _validate_database(
            connection, TARGET_CATEGORIES
        )
        if current_tags != previous_tags or current_assignments != previous_assignments:
            raise RuntimeError("tag migration changed existing tags or assignments")
        connection.execute("COMMIT")
    except BaseException:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()

    _publish_version(version_path)


def main():
    try:
        migrate()
    except (OSError, RuntimeError, sqlite3.Error) as error:
        print(f"tags 1-to-2 migration failed: {error}", file=sys.stderr)
        return 1
    print("tags storage migrated from version 1 to 2")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
