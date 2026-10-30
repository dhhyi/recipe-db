"""Opt-in contract checks against the pinned engine, using an isolated collection."""
import json
import os
from pathlib import Path
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid


@unittest.skipUnless(os.environ.get("TYPESENSE_TEST_KEY_FILE"),
                     "set TYPESENSE_TEST_KEY_FILE to exercise the deployed engine")
class TypesenseSortTests(unittest.TestCase):
    @classmethod
    def call(cls, method, path, body=None):
        request = urllib.request.Request(
            os.environ.get("TYPESENSE_URL", "http://typesense:8108") + path,
            method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"X-TYPESENSE-API-KEY": cls.key, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            with error:
                raise AssertionError((error.code, error.read().decode())) from error

    @classmethod
    def setUpClass(cls):
        cls.key = Path(os.environ["TYPESENSE_TEST_KEY_FILE"]).read_text().strip()
        version = cls.call("GET", "/debug")["version"]
        if version != "29.0":
            raise AssertionError(f"expected pinned Typesense 29.0, got {version!r}")
        schema = json.loads((Path(__file__).parent / "src/schema.json").read_text())
        schema["name"] = "sort_contract_" + uuid.uuid4().hex
        cls.path = "/collections/" + schema["name"]
        cls.call("POST", "/collections", schema)
        cls.addClassCleanup(lambda: cls.call("DELETE", cls.path))
        names = [
            ("a", "Apfel", "apfel", 5, 1),
            ("b", "Äpfelsuppe", "apfelsuppe", 4, 2),
            ("c", "Banane", "banane", 4, 2),
            ("d", "Ölsuppe", "olsuppe", 0, 0),
            ("e", "Strasse", "strasse", 0, 0),
            ("f", "Straße", "strasse", 0, 0),
            ("g", "Zwiebel", "zwiebel", 0, 0),
        ]
        for i, (recipe_id, name, key, average, count) in enumerate(names):
            cls.call("POST", cls.path + "/documents", {
                "id": recipe_id, "recipe_id_sort": recipe_id,
                "name": name, "name_sort": key,
                "method": "Apfel im Gericht" if i else "",
                "ingredients": [], "ingredient_units": [],
                "created_at": 1791464400123456 + (0 if i < 2 else i),
                "updated_at": 1791464400654321 + (0 if i < 2 else i),
                "rating_average": average, "rating_count": count,
            })

    def search(self, sort, query="*"):
        self.assertLessEqual(len(sort.split(",")), 3)
        result = self.call("GET", self.path + "/documents/search?" + urllib.parse.urlencode({
            "q": query, "query_by": "name,method,ingredients", "sort_by": sort,
            "num_typos": 0, "prefix": "false",
        }))
        self.assertIs(result["search_cutoff"], False)
        return [hit["document"]["id"] for hit in result["hits"]]

    def test_populated_collection_accepts_optional_tag_schema_migration(self):
        schema = json.loads((Path(__file__).parent / "src/schema.json").read_text())
        schema["name"] = "tag_migration_" + uuid.uuid4().hex
        schema["fields"] = [field for field in schema["fields"] if field["name"] != "tag_ids"]
        path = "/collections/" + schema["name"]
        self.call("POST", "/collections", schema)
        self.addCleanup(lambda: self.call("DELETE", path))
        doc = self.call("GET", self.path + "/documents/a")
        self.call("POST", path + "/documents", doc)
        self.call("PATCH", path, {"fields": [
            {"name": "tag_ids", "type": "string[]", "optional": True, "facet": True},
        ]})
        migrated = self.call("GET", path)
        field, = [field for field in migrated["fields"] if field["name"] == "tag_ids"]
        self.assertEqual((field["type"], field["optional"], field["facet"]),
                         ("string[]", True, True))
        self.assertEqual(migrated["num_documents"], 1)
        self.assertNotIn("tag_ids", self.call("GET", path + "/documents/a"))
        doc["tag_ids"] = ["exact-tag"]
        self.call("POST", path + "/documents?action=upsert", doc)
        result = self.call("GET", path + "/documents/search?" + urllib.parse.urlencode({
            "q": "*", "query_by": "name", "filter_by": "tag_ids:=`exact-tag`",
        }))
        self.assertEqual([hit["document"]["id"] for hit in result["hits"]], ["a"])

    def test_tag_similarity_native_matching_and_exact_eligibility(self):
        schema = json.loads((Path(__file__).parent / "src/schema.json").read_text())
        schema["name"] = "tag_similarity_" + uuid.uuid4().hex
        path = "/collections/" + schema["name"]
        self.call("POST", "/collections", schema)
        self.addCleanup(lambda: self.call("DELETE", path))
        base = self.call("GET", self.path + "/documents/a")
        fixtures = [
            ("source", ["course-tagalpha", "dietary-style-tagbeta"]),
            ("both-a", ["course-tagalpha", "dietary-style-tagbeta"]),
            ("both-b", ["course-tagalpha", "dietary-style-tagbeta"]),
            ("beta-only", ["dietary-style-tagbeta"]),
            ("alpha-only", ["course-tagalpha"]),
            ("prefix-only", ["course-tagalphabet"]),
            ("typo-only", ["course-tagalphx"]),
            ("unrelated", ["other"]),
            ("untagged", []),
        ] + [(f"one-{i:03d}", ["course-tagalpha"]) for i in range(125)]
        for recipe_id, tags in fixtures:
            doc = {**base, "id": recipe_id, "recipe_id_sort": recipe_id, "tag_ids": tags}
            self.call("POST", path + "/documents", doc)
        options = {
            "q": "course-tagalpha dietary-style-tagbeta", "query_by": "tag_ids",
            "filter_by": "tag_ids:=[`course-tagalpha`,`dietary-style-tagbeta`] && id:!=`source`",
            "sort_by": "_text_match:desc,recipe_id_sort:asc",
            "prefix": "false", "num_typos": 0, "split_join_tokens": "off",
            "per_page": 100, "page": 1,
        }
        first = self.call("GET", path + "/documents/search?" + urllib.parse.urlencode(options))
        self.assertIs(first["search_cutoff"], False)
        self.assertEqual(first["found"], 2)
        first_ids = [hit["document"]["id"] for hit in first["hits"]]
        self.assertEqual(first_ids, ["both-a", "both-b"])
        scores = [hit["text_match"] for hit in first["hits"]]
        self.assertEqual(scores, sorted(scores, reverse=True))
        # Native query matching is intentional: single-overlap documents need
        # not join the captured result set; do not merge a wildcard fallback.
        self.assertNotIn("alpha-only", first_ids)
        self.assertNotIn("beta-only", first_ids)
        # Exact facet eligibility remains mandatory even when text typo/prefix
        # matching is permissive: near-identical IDs do not share an actual tag.
        permissive = self.call("GET", path + "/documents/search?" + urllib.parse.urlencode({
            **options, "q": "course-tagalpha", "prefix": "true", "num_typos": 2,
        }))
        self.assertFalse({"prefix-only", "typo-only", "source"} &
                         {hit["document"]["id"] for hit in permissive["hits"]})

    def test_single_tag_similarity_returns_all_native_pages(self):
        schema = json.loads((Path(__file__).parent / "src/schema.json").read_text())
        schema["name"] = "tag_pages_" + uuid.uuid4().hex
        path = "/collections/" + schema["name"]
        self.call("POST", "/collections", schema)
        self.addCleanup(lambda: self.call("DELETE", path))
        base = self.call("GET", self.path + "/documents/a")
        for recipe_id in ["source"] + [f"match-{i:03d}" for i in range(125)]:
            self.call("POST", path + "/documents", {
                **base, "id": recipe_id, "recipe_id_sort": recipe_id,
                "tag_ids": ["course-tagalpha"],
            })
        options = {
            "q": "course-tagalpha", "query_by": "tag_ids",
            "filter_by": "tag_ids:=[`course-tagalpha`] && id:!=`source`",
            "sort_by": "_text_match:desc,recipe_id_sort:asc",
            "prefix": "false", "num_typos": 0, "split_join_tokens": "off",
            "per_page": 100,
        }
        ids = []
        for page, count in [(1, 100), (2, 25)]:
            result = self.call("GET", path + "/documents/search?" + urllib.parse.urlencode({
                **options, "page": page,
            }))
            self.assertIs(result["search_cutoff"], False)
            self.assertEqual(result["found"], 125)
            self.assertEqual(len(result["hits"]), count)
            ids.extend(hit["document"]["id"] for hit in result["hits"])
        self.assertEqual(ids, [f"match-{i:03d}" for i in range(125)])

    def test_exact_tag_filter_and_backend_recipe_identifier_literals(self):
        schema = json.loads((Path(__file__).parent / "src/schema.json").read_text())
        schema["name"] = "tag_literals_" + uuid.uuid4().hex
        path = "/collections/" + schema["name"]
        self.call("POST", "/collections", schema)
        self.addCleanup(lambda: self.call("DELETE", path))
        base = self.call("GET", self.path + "/documents/a")
        source_ids = ["53cf7722-2b64-4e9f-a267-8b4d1f878302",
                      "9aa07db0-5d2f-4d24-b82c-08f84ded51f7"]
        for recipe_id in source_ids + ["keep", "near-tag"]:
            doc = {
                **base, "id": recipe_id, "recipe_id_sort": recipe_id,
                "tag_ids": ["course-noodlex" if recipe_id == "near-tag" else "course-noodle"],
            }
            self.call("POST", path + "/documents", doc)

        def literal(value):
            return "`" + value.replace("\\", "\\\\").replace("`", "\\`") + "`"

        for source_id in source_ids:
            with self.subTest(source_id=source_id):
                result = self.call("GET", path + "/documents/search?" + urllib.parse.urlencode({
                    "q": "course-noodle", "query_by": "tag_ids",
                    "filter_by": "tag_ids:=[`course-noodle`] && id:!=" + literal(source_id),
                    "sort_by": "_text_match:desc,recipe_id_sort:asc",
                    "num_typos": 0, "prefix": "false", "split_join_tokens": "off",
                }))
                self.assertIs(result["search_cutoff"], False)
                self.assertEqual({hit["document"]["id"] for hit in result["hits"]},
                                 (set(source_ids) | {"keep"}) - {source_id})

    def test_every_explicit_sort_and_equal_keys(self):
        for sort, expected in [
            ("rating_average:desc,rating_count:desc,recipe_id_sort:asc", "abcdefg"),
            ("rating_count:desc,rating_average:desc,recipe_id_sort:asc", "bcadefg"),
            ("name_sort:asc,recipe_id_sort:asc", "abcdefg"),
            ("name_sort:desc,recipe_id_sort:asc", "gefdcba"),
            ("created_at:desc,recipe_id_sort:asc", "gfedcab"),
            ("updated_at:desc,recipe_id_sort:asc", "gfedcab"),
        ]:
            with self.subTest(sort=sort):
                self.assertEqual(self.search(sort), list(expected))

    def test_relevance_outranks_recency_but_explicit_sort_does_not(self):
        relevance = self.search("_text_match:desc,created_at:desc,recipe_id_sort:asc", "Apfel")
        newest = self.search("created_at:desc,recipe_id_sort:asc", "Apfel")
        self.assertEqual(relevance[0], "a")
        self.assertEqual(newest, list("gfedcab"))
        self.assertNotEqual(relevance, newest)
        self.assertEqual(self.search(
            "rating_count:desc,rating_average:desc,recipe_id_sort:asc", "Apfel"),
            list("bcadefg"))

    def test_microseconds_are_int64_and_required_fields_reject_missing_values(self):
        doc = self.call("GET", self.path + "/documents/a")
        self.assertEqual(doc["created_at"], 1791464400123456)
        self.assertEqual(doc["updated_at"], 1791464400654321)
        for field in ("created_at", "updated_at", "name_sort", "recipe_id_sort",
                      "rating_average", "rating_count"):
            with self.subTest(field=field):
                missing = {key: value for key, value in doc.items() if key != field}
                missing["id"] = "missing"
                with self.assertRaisesRegex(AssertionError, "400"):
                    self.call("POST", self.path + "/documents", missing)


if __name__ == "__main__":
    unittest.main()
