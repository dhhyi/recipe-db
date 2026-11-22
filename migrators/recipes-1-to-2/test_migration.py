import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import migrate as migration
from migrate import migrate


def create_v1_data(data_directory):
    data_directory = Path(data_directory)
    data_directory.mkdir(parents=True, exist_ok=True)
    (data_directory / "storage-version").write_text("1\n", encoding="ascii")
    connection = sqlite3.connect(data_directory / "recipes.sqlite3")
    connection.execute(
        "CREATE TABLE recipes (id TEXT PRIMARY KEY, document TEXT NOT NULL)"
    )
    connection.execute(
        "INSERT INTO recipes VALUES (?, ?)",
        (
            "recipe-one",
            '{"name":"Soup","method":"Simmer",'
            '"ingredients":['
            '{"name":"integer","amount":2},'
            '{"name":"decimal","amount":1.20e-3},'
            '{"name":"negative","amount":-4.50},'
            '{"name":"string","amount":"1-2"},'
            '{"name":"null","amount":null},'
            '{"name":"omitted"},'
            '{"name":"boolean","amount":true},'
            '{"name":"array","amount":[]},'
            '{"name":"object","amount":{"value":1}}],'
            '"servings":2.50,"createdAt":"2026-03-04T05:06:07.890000Z",'
            '"updatedAt":"2026-03-05T05:06:07.890000Z",'
            '"other":{"enabled":true,"count":3}}',
        ),
    )
    connection.execute(
        "INSERT INTO recipes VALUES (?, ?)",
        (
            "recipe-two",
            '{"name":"Bread","ingredients":[{"name":"flour","amount":500.0}],'
            '"createdAt":"2026-01-02T03:04:05.000000Z"}',
        ),
    )
    connection.commit()
    connection.close()


def read_recipes(data_directory):
    connection = sqlite3.connect(Path(data_directory) / "recipes.sqlite3")
    rows = connection.execute(
        "SELECT id, document FROM recipes ORDER BY rowid"
    ).fetchall()
    connection.close()
    return [(recipe_id, json.loads(document)) for recipe_id, document in rows]


def verify_v2_data(data_directory):
    data_directory = Path(data_directory)
    if (data_directory / "storage-version").read_text(encoding="ascii") != "2\n":
        raise AssertionError("migration did not publish version 2")
    recipes = read_recipes(data_directory)
    if [recipe_id for recipe_id, _ in recipes] != ["recipe-one", "recipe-two"]:
        raise AssertionError(f"migration changed recipe IDs: {recipes}")

    first = recipes[0][1]
    ingredients = {ingredient["name"]: ingredient for ingredient in first["ingredients"]}
    amounts = {
        name: ingredient.get("amount", "omitted")
        for name, ingredient in ingredients.items()
    }
    if amounts != {
        "integer": "2",
        "decimal": "0.00120",
        "negative": "-4.50",
        "string": "1-2",
        "null": None,
        "omitted": "omitted",
        "boolean": None,
        "array": None,
        "object": None,
    }:
        raise AssertionError(f"migration produced incorrect ingredient amounts: {amounts}")
    if first["method"] != "Simmer" or first["servings"] != 2.5:
        raise AssertionError(f"migration changed unrelated recipe data: {first}")
    if first["createdAt"] != "2026-03-04T05:06:07.890000Z":
        raise AssertionError(f"migration changed createdAt: {first['createdAt']}")
    if first["updatedAt"] != "2026-03-05T05:06:07.890000Z":
        raise AssertionError(f"migration changed updatedAt: {first['updatedAt']}")
    if first["other"] != {"enabled": True, "count": 3}:
        raise AssertionError(f"migration changed nested recipe data: {first['other']}")

    second = recipes[1][1]
    if second["ingredients"][0]["amount"] != "500.0":
        raise AssertionError(f"migration did not normalize recipe-two amount: {second}")
    if second["createdAt"] != "2026-01-02T03:04:05.000000Z":
        raise AssertionError(f"migration changed recipe-two timestamp: {second}")


class RecipesMigrationTest(unittest.TestCase):
    def test_normalizes_amounts_and_preserves_recipe_data(self):
        with tempfile.TemporaryDirectory() as directory:
            create_v1_data(directory)
            migrate(directory)
            verify_v2_data(directory)

    def test_rejects_unexpected_version_without_changing_data(self):
        with tempfile.TemporaryDirectory() as directory:
            create_v1_data(directory)
            marker = Path(directory) / "storage-version"
            marker.write_text("3\n", encoding="ascii")
            before = read_recipes(directory)
            with self.assertRaisesRegex(RuntimeError, "expected storage version 1"):
                migrate(directory)
            self.assertEqual(read_recipes(directory), before)
            self.assertEqual(marker.read_text(encoding="ascii"), "3\n")

    def test_rejects_invalid_recipe_json_without_publishing_version(self):
        with tempfile.TemporaryDirectory() as directory:
            create_v1_data(directory)
            connection = sqlite3.connect(Path(directory) / "recipes.sqlite3")
            connection.execute(
                "UPDATE recipes SET document = ? WHERE id = ?",
                ("not json", "recipe-two"),
            )
            connection.commit()
            connection.close()
            before = read_database_rows(directory)

            with self.assertRaisesRegex(RuntimeError, "invalid recipe JSON"):
                migrate(directory)

            self.assertEqual(read_database_rows(directory), before)
            self.assertEqual(
                (Path(directory) / "storage-version").read_text(encoding="ascii"),
                "1\n",
            )

    def test_rolls_back_updates_if_target_validation_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            create_v1_data(directory)
            before = read_database_rows(directory)
            validate = migration._validate_database
            calls = 0

            def fail_target_validation(connection):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise RuntimeError("injected target validation failure")
                return validate(connection)

            with mock.patch.object(
                migration, "_validate_database", side_effect=fail_target_validation
            ):
                with self.assertRaisesRegex(
                    RuntimeError, "injected target validation failure"
                ):
                    migrate(directory)

            self.assertEqual(read_database_rows(directory), before)
            self.assertEqual(
                (Path(directory) / "storage-version").read_text(encoding="ascii"),
                "1\n",
            )

    def test_does_not_publish_version_when_marker_publication_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            create_v1_data(directory)
            with mock.patch.object(
                migration,
                "_publish_version",
                side_effect=RuntimeError("injected marker publication failure"),
            ):
                with self.assertRaisesRegex(
                    RuntimeError, "injected marker publication failure"
                ):
                    migrate(directory)

            self.assertEqual(
                (Path(directory) / "storage-version").read_text(encoding="ascii"),
                "1\n",
            )
            verify_migrated_data_without_version(directory)


def read_database_rows(data_directory):
    connection = sqlite3.connect(Path(data_directory) / "recipes.sqlite3")
    rows = connection.execute(
        "SELECT id, document FROM recipes ORDER BY rowid"
    ).fetchall()
    connection.close()
    return rows


def verify_migrated_data_without_version(data_directory):
    rows = read_recipes(data_directory)
    first = rows[0][1]
    amounts = [ingredient.get("amount") for ingredient in first["ingredients"]]
    if amounts != ["2", "0.00120", "-4.50", "1-2", None, None, None, None, None]:
        raise AssertionError(f"migration did not commit normalized data: {amounts}")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--create-fixture":
        create_v1_data(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "--verify":
        verify_v2_data(sys.argv[2])
    else:
        unittest.main()
