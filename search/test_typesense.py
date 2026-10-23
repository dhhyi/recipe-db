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
        return [hit["document"]["id"] for hit in result["hits"]]

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
