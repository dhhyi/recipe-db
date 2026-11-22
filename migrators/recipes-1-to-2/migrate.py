import json
import os
import sqlite3
import stat
import sys
import tempfile
from decimal import Decimal
from pathlib import Path


VERSION_FILE = "storage-version"
DATABASE_FILE = "recipes.sqlite3"
SOURCE_VERSION = 1
TARGET_VERSION = 2
MAX_NORMALIZED_AMOUNT_LENGTH = 1_000_000


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


def _parse_document(text):
    try:
        document = json.loads(
            text,
            parse_int=Decimal,
            parse_float=Decimal,
            parse_constant=_reject_json_constant,
        )
    except (RecursionError, TypeError, ValueError) as error:
        raise RuntimeError(f"invalid recipe JSON: {error}") from error
    if not isinstance(document, dict):
        raise RuntimeError("recipe document must be a JSON object")
    return document


def _reject_json_constant(value):
    raise ValueError(f"invalid JSON number {value}")


def _validate_database(connection):
    tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        )
    }
    if tables != {"recipes"}:
        raise RuntimeError("unexpected recipes database tables")
    if _table_columns(connection, "recipes") != [
        ("id", "TEXT", 0, 1),
        ("document", "TEXT", 1, 0),
    ]:
        raise RuntimeError("unexpected recipes table schema")

    if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
        raise RuntimeError("recipes database integrity check failed")

    rows = connection.execute(
        "SELECT id, document FROM recipes ORDER BY rowid"
    ).fetchall()
    for recipe_id, document_text in rows:
        if not isinstance(recipe_id, str) or not recipe_id:
            raise RuntimeError("invalid recipe ID")
        if not isinstance(document_text, str):
            raise RuntimeError(f"invalid recipe document for {recipe_id}")
        _parse_document(document_text)
    return rows


def _ordinary_decimal(value):
    if value.is_zero():
        return "-0" if value.is_signed() else "0"

    digits = len(value.as_tuple().digits)
    exponent = value.as_tuple().exponent
    decimal_position = digits + exponent
    if exponent >= 0:
        output_length = decimal_position
    elif decimal_position > 0:
        output_length = digits + 1
    else:
        output_length = 2 - decimal_position + digits
    if value.is_signed():
        output_length += 1
    if output_length > MAX_NORMALIZED_AMOUNT_LENGTH:
        raise RuntimeError("normalized ingredient amount is too long")
    return format(value, "f")


def _encode_json(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, Decimal):
        if not value.is_finite():
            raise RuntimeError("non-finite number in recipe document")
        return str(value)
    if isinstance(value, dict):
        return (
            "{"
            + ",".join(
                f"{json.dumps(key)}:{_encode_json(item)}"
                for key, item in value.items()
            )
            + "}"
        )
    if isinstance(value, list):
        return "[" + ",".join(_encode_json(item) for item in value) + "]"
    raise RuntimeError("unsupported value in recipe document")


def _migrate_document(text):
    document = _parse_document(text)
    changed = False
    ingredients = document.get("ingredients")
    if isinstance(ingredients, list):
        for ingredient in ingredients:
            if not isinstance(ingredient, dict) or "amount" not in ingredient:
                continue
            amount = ingredient["amount"]
            if isinstance(amount, str) or amount is None:
                continue
            if isinstance(amount, Decimal):
                ingredient["amount"] = _ordinary_decimal(amount)
            else:
                ingredient["amount"] = None
            changed = True
    return _encode_json(document) if changed else text


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
        connection.execute("BEGIN IMMEDIATE")
        original_rows = _validate_database(connection)
        expected_rows = [
            (recipe_id, _migrate_document(document))
            for recipe_id, document in original_rows
        ]
        updates = [
            (migrated_document, recipe_id)
            for (recipe_id, original_document), (_, migrated_document) in zip(
                original_rows, expected_rows
            )
            if original_document != migrated_document
        ]
        connection.executemany(
            "UPDATE recipes SET document = ? WHERE id = ?",
            updates,
        )
        current_rows = _validate_database(connection)
        if current_rows != expected_rows:
            raise RuntimeError("recipe migration changed unexpected data")
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
        print(f"recipes 1-to-2 migration failed: {error}", file=sys.stderr)
        return 1
    print("recipes storage migrated from version 1 to 2")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
