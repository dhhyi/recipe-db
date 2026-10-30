import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

os.environ.setdefault("DEMO_DATA_AUTH_TOKEN", "test-token")
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import demo_data
from graphql_client.enums import TagCategory


class FakeGraphQLClient:
    def __init__(self, tags=None):
        self.tags = list(tags or [])
        self.recipes_data = []
        self.assignments = {}
        self.create_calls = []

    async def recipes(self):
        return SimpleNamespace(recipes=list(self.recipes_data))

    async def delete_recipe(self, recipe_id):
        self.recipes_data = [
            recipe for recipe in self.recipes_data if recipe.id != recipe_id
        ]
        self.assignments.pop(recipe_id, None)
        return SimpleNamespace(delete_recipe=True)

    async def demo_tag_inventory(self):
        return SimpleNamespace(tags=list(self.tags))

    async def demo_create_tag(self, category, name):
        if any(tag.category == category and tag.name == name for tag in self.tags):
            raise AssertionError("attempted to recreate an existing inventory tag")
        initial = next(
            tag
            for tag in demo_data.load_json("tags.json")
            if tag["category"] == category.value and tag["name"] == name
        )
        tag = SimpleNamespace(id=initial["id"], category=category, name=name)
        self.create_calls.append((category, name))
        self.tags.append(tag)
        return SimpleNamespace(create_tag=tag)

    async def demo_assign_recipe_tags(self, recipe_id, add_tag_ids):
        add_tag_ids = list(add_tag_ids or [])
        known_ids = {tag.id for tag in self.tags}
        if any(tag_id not in known_ids for tag_id in add_tag_ids):
            raise ValueError("unknown tag ID")
        self.assignments[recipe_id] = add_tag_ids
        return SimpleNamespace(
            change_recipe_tags=[SimpleNamespace(id=tag_id) for tag_id in add_tag_ids]
        )


class FakeResetClient:
    def __init__(self, graphql_client):
        self.graphql_client = graphql_client
        self.urls = []

    async def delete(self, url):
        self.urls.append(url)
        if url.endswith("/tags"):
            self.graphql_client.tags.clear()
            self.graphql_client.assignments.clear()
        return SimpleNamespace(raise_for_status=lambda: None)


class DemoDataTagTests(unittest.IsolatedAsyncioTestCase):
    async def asyncTearDown(self):
        await demo_data.http_client.aclose()

    async def test_recipe_tag_files_reference_the_imported_tag_ids(self):
        catalog_ids = {tag["id"] for tag in demo_data.load_json("tags.json")}
        expected = {
            1: ["cuisine-deutsch", "dietary-style-vegetarisch", "course-dessert"],
            2: ["cuisine-deutsch", "dietary-style-vegetarisch", "course-suppe"],
            3: ["cuisine-italienisch", "course-hauptgericht"],
            4: [
                "cuisine-mediterran",
                "dietary-style-vegan",
                "course-hauptgericht",
            ],
            5: ["cuisine-deutsch", "course-hauptgericht"],
        }
        for number, tag_ids in expected.items():
            with self.subTest(recipe=number):
                self.assertEqual(
                    demo_data.load_txt(f"recipe{number}.tags.txt"), tag_ids
                )
                self.assertTrue(set(tag_ids).issubset(catalog_ids))
                self.assertNotIn("tags", demo_data.load_json(f"recipe{number}.json"))

    async def test_insert_recipe_excludes_tag_files_from_recipe_and_assigns_ids(self):
        tag_ids = demo_data.load_txt("recipe1.tags.txt")
        with (
            patch.object(
                demo_data, "add_recipe", new=AsyncMock(return_value="recipe-id")
            ) as add_recipe,
            patch.object(demo_data, "assign_demo_tags", new=AsyncMock()) as assign_tags,
        ):
            recipe_id = await demo_data.insert_recipe(1)

        self.assertEqual(recipe_id, "recipe-id")
        self.assertNotIn("tags", add_recipe.await_args.args[0])
        self.assertEqual(
            assign_tags.await_args.args,
            ("recipe-id", tag_ids),
        )

    async def test_matching_inventory_entry_is_reused_by_id(self):
        existing = SimpleNamespace(
            id="cuisine-deutsch", category=TagCategory.CUISINE, name="Deutsch"
        )
        client = FakeGraphQLClient([existing])

        await demo_data.import_demo_tags(client)

        self.assertEqual(len(client.tags), 8)
        self.assertNotIn((TagCategory.CUISINE, "Deutsch"), client.create_calls)

    async def test_unknown_recipe_tag_id_fails_assignment_without_name_remapping(self):
        client = FakeGraphQLClient(
            [
                SimpleNamespace(
                    id="cuisine-deutsch", category=TagCategory.CUISINE, name="Deutsch"
                )
            ]
        )

        with self.assertRaisesRegex(ValueError, "unknown tag ID"):
            await demo_data.assign_demo_tags("recipe", ["different-id"], client)

    async def test_repeated_destructive_reseeding_restores_inventory_and_assignments(
        self,
    ):
        client = FakeGraphQLClient(
            [SimpleNamespace(id="stale", category=TagCategory.COURSE, name="Old")]
        )
        client.recipes_data = [SimpleNamespace(id="old-recipe")]
        reset_client = FakeResetClient(client)

        for cycle in range(2):
            await demo_data.delete_everything(client, reset_client)
            await demo_data.import_demo_tags(client)
            for number in range(1, 6):
                recipe_id = f"cycle-{cycle}-recipe-{number}"
                client.recipes_data.append(SimpleNamespace(id=recipe_id))
                await demo_data.assign_demo_tags(
                    recipe_id, demo_data.load_txt(f"recipe{number}.tags.txt"), client
                )

            self.assertEqual(len(client.tags), 8)
            for number in range(1, 6):
                recipe_id = f"cycle-{cycle}-recipe-{number}"
                expected_ids = demo_data.load_txt(f"recipe{number}.tags.txt")
                self.assertEqual(client.assignments[recipe_id], expected_ids)

        self.assertEqual(sum(url.endswith("/tags") for url in reset_client.urls), 2)
        self.assertEqual(len(client.create_calls), 16)


if __name__ == "__main__":
    unittest.main()
