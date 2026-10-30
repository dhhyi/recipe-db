import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

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
        self.next_id = 1

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
        key = demo_data.tag_identity_key(category.value, name)
        if any(
            demo_data.tag_identity_key(tag.category.value, tag.name) == key
            for tag in self.tags
        ):
            raise AssertionError("attempted to recreate a matching inventory tag")
        tag = SimpleNamespace(
            id=f"tag-{self.next_id}", category=category, name=name
        )
        self.next_id += 1
        self.create_calls.append((category, name))
        self.tags.append(tag)
        return SimpleNamespace(create_tag=tag)

    async def demo_assign_recipe_tags(self, recipe_id, add_tag_ids):
        self.assignments[recipe_id] = list(add_tag_ids)
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

    async def test_recipe_fixtures_contain_the_requested_tag_classifications(self):
        self.assertEqual(
            demo_data.recipe_tag_definitions(),
            {
                1: [
                    ("CUISINE", "Deutsch"),
                    ("DIETARY_STYLE", "Vegetarisch"),
                    ("COURSE", "Dessert"),
                ],
                2: [
                    ("CUISINE", "Deutsch"),
                    ("DIETARY_STYLE", "Vegetarisch"),
                    ("COURSE", "Suppe"),
                ],
                3: [
                    ("CUISINE", "Italienisch"),
                    ("COURSE", "Hauptgericht"),
                ],
                4: [
                    ("CUISINE", "Mediterran"),
                    ("DIETARY_STYLE", "Vegan"),
                    ("COURSE", "Hauptgericht"),
                ],
                5: [
                    ("CUISINE", "Deutsch"),
                    ("COURSE", "Hauptgericht"),
                ],
            },
        )

    async def test_matching_inventory_entry_is_reused_by_normalized_identity(self):
        existing = SimpleNamespace(
            id="existing-cuisine", category=TagCategory.CUISINE, name="Creme-brulee"
        )
        client = FakeGraphQLClient([existing])
        definitions = {1: [("CUISINE", "Crème brûlée")]}

        tag_ids = await demo_data.seed_demo_tag_inventory(definitions, client)

        self.assertEqual(
            tag_ids[demo_data.tag_identity_key("CUISINE", "Crème brûlée")],
            existing.id,
        )
        self.assertEqual(client.create_calls, [])

    async def test_repeated_destructive_reseeding_restores_inventory_and_assignments(self):
        client = FakeGraphQLClient(
            [SimpleNamespace(id="stale", category=TagCategory.COURSE, name="Old")]
        )
        client.recipes_data = [SimpleNamespace(id="old-recipe")]
        reset_client = FakeResetClient(client)
        definitions = demo_data.recipe_tag_definitions()

        for cycle in range(2):
            await demo_data.delete_everything(client, reset_client)
            tag_ids = await demo_data.seed_demo_tag_inventory(
                definitions, client
            )
            for number, tags in definitions.items():
                recipe_id = f"cycle-{cycle}-recipe-{number}"
                client.recipes_data.append(SimpleNamespace(id=recipe_id))
                await demo_data.assign_demo_tags(recipe_id, tags, tag_ids, client)

            self.assertEqual(len(client.tags), 8)
            for number, tags in definitions.items():
                recipe_id = f"cycle-{cycle}-recipe-{number}"
                expected_ids = [
                    tag_ids[demo_data.tag_identity_key(category, name)]
                    for category, name in tags
                ]
                self.assertEqual(client.assignments[recipe_id], expected_ids)

        self.assertEqual(
            sum(url.endswith("/tags") for url in reset_client.urls), 2
        )
        self.assertEqual(len(client.create_calls), 16)


if __name__ == "__main__":
    unittest.main()
