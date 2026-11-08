import os
import sys
import unittest
import hashlib
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
        tag = SimpleNamespace(category=category, name=name)
        self.create_calls.append((category, name))
        self.tags.append(tag)
        return SimpleNamespace(create_tag=tag)

    async def demo_assign_recipe_tags(self, recipe_id, add_tag_ids):
        add_tag_ids = list(add_tag_ids or [])
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

    async def test_tag_catalog_is_category_to_name_lists(self):
        catalog = demo_data.load_json("tags.json")
        self.assertIsInstance(catalog, dict)
        self.assertEqual(
            set(catalog), {"CUISINE", "DIETARY_STYLE", "COURSE"}
        )
        self.assertTrue(
            all(
                isinstance(names, list)
                and all(isinstance(name, str) for name in names)
                for names in catalog.values()
            )
        )
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
            6: [
                "cuisine-mediterran",
                "dietary-style-vegan",
                "course-hauptgericht",
            ],
        }
        for number, tag_ids in expected.items():
            with self.subTest(recipe=number):
                self.assertEqual(
                    demo_data.load_txt(f"recipe{number}.tags.txt"), tag_ids
                )
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

    async def test_matching_inventory_entry_is_reused_by_category_and_name(self):
        existing = SimpleNamespace(
            id="opaque-existing-id", category=TagCategory.CUISINE, name="Deutsch"
        )
        client = FakeGraphQLClient([existing])

        await demo_data.import_demo_tags(client)

        self.assertEqual(len(client.tags), 8)
        self.assertNotIn((TagCategory.CUISINE, "Deutsch"), client.create_calls)

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
            for number in range(1, 7):
                recipe_id = f"cycle-{cycle}-recipe-{number}"
                client.recipes_data.append(SimpleNamespace(id=recipe_id))
                await demo_data.assign_demo_tags(
                    recipe_id, demo_data.load_txt(f"recipe{number}.tags.txt"), client
                )

            self.assertEqual(len(client.tags), 8)
            for number in range(1, 7):
                recipe_id = f"cycle-{cycle}-recipe-{number}"
                expected_ids = demo_data.load_txt(f"recipe{number}.tags.txt")
                self.assertEqual(client.assignments[recipe_id], expected_ids)

        self.assertEqual(sum(url.endswith("/tags") for url in reset_client.urls), 2)
        self.assertEqual(len(client.create_calls), 16)

    async def test_kritharaki_core_data_and_method_are_loaded(self):
        with (
            patch.object(
                demo_data, "add_recipe", new=AsyncMock(return_value="recipe-id")
            ) as add_recipe,
            patch.object(demo_data, "assign_demo_tags", new=AsyncMock()) as assign_tags,
        ):
            await demo_data.insert_recipe(6)

        recipe = add_recipe.await_args.args[0]
        self.assertEqual(recipe["name"], "Kritharaki-Pfanne mit Gemüse")
        self.assertEqual(len(recipe["ingredients"]), 13)
        self.assertTrue(all(not item["optional"] for item in recipe["ingredients"]))
        self.assertEqual(recipe["ingredients"][6]["amount"], "500")
        self.assertEqual(recipe["ingredients"][6]["unit"], "g")
        self.assertEqual(recipe["method"], demo_data.load_md("recipe6.method.md"))
        self.assertNotIn("inspirations", recipe)
        assign_tags.assert_awaited_once_with(
            "recipe-id",
            ["cuisine-mediterran", "dietary-style-vegan", "course-hauptgericht"],
        )

    async def test_jpeg_and_original_png_images_use_matching_upload_types(self):
        for number, extension, content_type in [
            (1, "jpg", "image/jpeg"),
            (6, "png", "image/png"),
        ]:
            with self.subTest(recipe=number):
                with patch.object(
                    demo_data.client,
                    "add_image",
                    new=AsyncMock(
                        return_value=SimpleNamespace(
                            set_image=SimpleNamespace(url="/public/image")
                        )
                    ),
                ) as add_image:
                    await demo_data.maybe_add_image(number, "recipe-id")
                add_image.assert_awaited_once()
                recipe_id, upload = add_image.await_args.args
                self.assertEqual(recipe_id, "recipe-id")
                self.assertEqual(upload.filename, f"recipe{number}.{extension}")
                self.assertEqual(upload.content_type, content_type)
                self.assertEqual(
                    upload.content, Path(upload.filename).read_bytes()
                )
                if number == 6:
                    self.assertEqual(
                        hashlib.sha256(upload.content).hexdigest(),
                        "d3272f238864ead2470d66c94028d2d58d4a41badd5ffa2b2af27bbd340bb9d5",
                    )

    async def test_missing_image_does_not_upload(self):
        with patch.object(demo_data.client, "add_image", new=AsyncMock()) as add_image:
            await demo_data.maybe_add_image("missing", "recipe-id")
        add_image.assert_not_awaited()

    async def test_main_includes_six_recipes_and_preserves_live_kritharaki_rating(self):
        with (
            patch.object(sys, "argv", ["demo_data.py"]),
            patch.object(demo_data, "wait_all_online", new=AsyncMock()),
            patch.object(demo_data, "import_demo_tags", new=AsyncMock()),
            patch.object(
                demo_data, "insert_recipe", new=AsyncMock(side_effect=range(1, 7))
            ) as insert_recipe,
            patch.object(demo_data, "maybe_add_image", new=AsyncMock()) as add_image,
            patch.object(demo_data, "rate_recipe", new=AsyncMock()) as rate_recipe,
            patch.object(demo_data, "random_rate_recipe", new=AsyncMock()) as random_rate,
        ):
            await demo_data.main()
        self.assertEqual(
            [call.args for call in insert_recipe.await_args_list],
            [(number,) for number in range(1, 7)],
        )
        self.assertEqual(
            [call.args for call in add_image.await_args_list],
            [(number, number) for number in range(1, 7)],
        )
        self.assertEqual(
            [call.args for call in rate_recipe.await_args_list], [(1, 4), (6, 4)]
        )
        self.assertEqual(
            [call.args for call in random_rate.await_args_list],
            [(number,) for number in range(2, 6)],
        )


if __name__ == "__main__":
    unittest.main()
