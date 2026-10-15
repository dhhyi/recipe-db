from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from graphql import GraphQLError, build_schema, parse, validate

from generate_operations import ROOT, generate


SCHEMA = """
type Query { recipe(id: ID!): Recipe recipes: [Recipe!]! }
type Recipe { id: ID! name: String! }
"""


class GenerateOperationsTests(unittest.TestCase):
    def test_queries_are_separate_and_include_only_required_fragments(self):
        generated = generate(
            SCHEMA,
            """
            query CoreRecipe($id: ID!) { recipe(id: $id) { ...Details } }
            query RecipeIds { recipes { id } }
            fragment Details on Recipe { ...Identity name }
            fragment Identity on Recipe { id }
            """,
        )
        queries = {}
        for block in generated.split("pub const ")[1:]:
            name = block.split(" =", 1)[0].strip('@"')
            query = "\n".join(
                line[6:] for line in block.splitlines() if line.startswith("    \\\\")
            )
            queries[name] = query
            self.assertEqual(validate(build_schema(SCHEMA), parse(query)), [])
        self.assertEqual(set(queries), {"CoreRecipe", "RecipeIds"})
        self.assertIn("fragment Identity", queries["CoreRecipe"])
        self.assertIn("fragment Details", queries["CoreRecipe"])
        self.assertNotIn("fragment", queries["RecipeIds"])
        self.assertNotIn("query CoreRecipe", queries["RecipeIds"])

    def test_invalid_operations_are_rejected(self):
        cases = [
            ("unknown field", "query Bad { recipes { missing } }"),
            ("missing argument", "query Bad { recipe { id } }"),
            ("variable type", "query Bad($id: Int!) { recipe(id: $id) { id } }"),
            ("nullable variable", "query Bad($id: ID) { recipe(id: $id) { id } }"),
            ("missing selection", "query Bad { recipes }"),
            ("unknown fragment", "query Bad { recipes { ...Missing } }"),
            ("unused variable", "query Bad($id: ID!) { recipes { id } }"),
            ("duplicate name", "query Bad { recipes { id } } query Bad { recipes { id } }"),
            ("anonymous operation", "{ recipes { id } }"),
            ("no operations", "fragment Identity on Recipe { id }"),
            ("syntax error", "query Bad {"),
        ]
        for label, operation in cases:
            with self.subTest(label=label):
                with self.assertRaises((ValueError, GraphQLError)):
                    generate(SCHEMA, operation)

    def test_invalid_schema_is_rejected(self):
        with self.assertRaises((TypeError, GraphQLError)):
            generate("type Query { recipe: Missing }", "query Recipes { recipe }")

    def test_cli_preserves_output_on_failure_and_detects_stale_constants(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            schema = directory / "schema.graphqls"
            operations = directory / "operations.graphql"
            output = directory / "operations.zig"
            schema.write_text(SCHEMA, encoding="utf-8")
            operations.write_text("query Recipes { recipes { id } }", encoding="utf-8")
            command = [
                sys.executable, str(ROOT / "generate_operations.py"),
                "--schema", str(schema), "--operations", str(operations),
                "--output", str(output),
            ]
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = output.read_text(encoding="utf-8")
            result = subprocess.run(
                command + ["--check"], capture_output=True, text=True, check=False
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            operations.write_text("query Recipes { recipes { name } }", encoding="utf-8")
            result = subprocess.run(
                command + ["--check"], capture_output=True, text=True, check=False
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("is stale", result.stderr)
            self.assertEqual(output.read_text(encoding="utf-8"), expected)
            operations.write_text("query Recipes { recipes { missing } }", encoding="utf-8")
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Cannot query field", result.stderr)
            self.assertIn(str(operations), result.stderr)
            self.assertEqual(output.read_text(encoding="utf-8"), expected)

    def test_search_operations_validate_against_synchronized_schema(self):
        generated = generate(
            (ROOT / "recipe-db.graphqls").read_text(encoding="utf-8"),
            (ROOT / "src/operations.graphql").read_text(encoding="utf-8"),
        )
        for name in ("RecipeIds", "IndexRecipe"):
            self.assertIn(f"pub const {name} =", generated)


if __name__ == "__main__":
    unittest.main()
