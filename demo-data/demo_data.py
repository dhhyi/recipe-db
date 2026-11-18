import asyncio
import json
import os
import sys
import random
from io import BytesIO

import httpx
from PIL import Image, ImageDraw, ImageFont, ImageOps
from graphql_client import Client
from graphql_client.base_model import Upload
from graphql_client.enums import TagCategory
from graphql_client.exceptions import GraphQLClientHttpError

authorization = os.getenv("DEMO_DATA_AUTH_TOKEN")
if not authorization:
    sys.exit("DEMO_DATA_AUTH_TOKEN is required to seed demo data.")

headers = {
    "apollo-require-preflight": "true",
    "origin": "http://traefik",
    "authorization": f"Bearer {authorization}",
}
# large recipe photos can take a while to decode/resize server-side
http_client = httpx.AsyncClient(headers=headers, timeout=30.0)
client = Client("http://traefik/graphql", http_client=http_client)
rest_api = os.getenv("REST_API", "http://traefik:3000")


async def wait_all_online():
    print("Waiting for all services to be online")

    names = os.getenv("SERVICES")
    if names is None:
        print("SERVICES environment variable not set")
        return

    print(f"SERVICES: {names}")

    while True:
        result = await client.all_services_up(names.split(","))
        print(f"-> {result}")
        if result.all_services_online:
            break
        sys.stdout.flush()
        await asyncio.sleep(1)


async def delete_everything(graphql_client=None, reset_client=None):
    print("Deleting everything")

    graphql_client = graphql_client or client
    reset_client = reset_client or http_client
    result = await graphql_client.recipes()
    for recipe in result.recipes:
        deleted = await graphql_client.delete_recipe(recipe.id)
        print(f"-> Deleted recipe {recipe.id}: {deleted.delete_recipe}")

    for service in ["ratings", "images", "inspirations", "tags"]:
        response = await reset_client.delete(f"{rest_api}/{service}")
        response.raise_for_status()
        print(f"-> Reset {service}")


async def has_existing_recipes():
    result = await client.recipes()
    return bool(result.recipes)


def confirm_delete():
    if os.getenv("FORCE_DELETE"):
        print("FORCE_DELETE set, deleting existing recipe data without confirmation")
        return

    if not sys.stdin.isatty():
        print("Existing recipe data found, refusing to delete non-interactively.")
        print("Set FORCE_DELETE=1 to delete without confirmation.")
        sys.exit(1)

    answer = input("Existing recipe data found. Delete it and continue? [y/N] ")
    if answer.strip().lower() not in ("y", "yes"):
        print("Aborting")
        sys.exit(1)


async def add_recipe(recipe):
    print(f"Adding recipe {recipe['name']}")
    result = await client.add_recipe(recipe)
    print(f"-> {result}")

    if result.create_recipe is None:
        raise Exception("Failed to add recipe")
    return result.create_recipe.id


def load_json(file):
    with open(file, mode="r", encoding="utf-8") as content:
        return json.load(content)


def load_txt(file):
    with open(file, mode="r", encoding="utf-8") as content:
        return [line for line in content.read().split("\n") if line]


def load_md(file):
    with open(file, mode="r", encoding="utf-8") as content:
        return content.read().strip()


def file_exists(file):
    try:
        with open(file, mode="r", encoding="utf-8"):
            return True
    except FileNotFoundError:
        return False


async def rate_recipe(recipe_id, rating):
    print(f"Rating recipe {recipe_id} with {rating}")
    result = await client.add_rating(recipe_id, rating)
    print(f"-> {result}")


async def random_rate_recipe(recipe_id):
    if random.randint(0, 3) > 0:
        await rate_recipe(recipe_id, random.randint(1, 5))


async def insert_recipe(number):
    recipe = load_json(f"recipe{number}.json")
    tag_ids = load_txt(f"recipe{number}.tags.txt")
    recipe["method"] = load_md(f"recipe{number}.method.md")
    if file_exists(f"recipe{number}.inspirations.txt"):
        recipe["inspirations"] = load_txt(f"recipe{number}.inspirations.txt")
    recipe_id = await add_recipe(recipe)
    await assign_demo_tags(recipe_id, tag_ids)
    return recipe_id


async def import_demo_tags(graphql_client=None):
    graphql_client = graphql_client or client
    initial_tags = load_json("tags.json")
    result = await graphql_client.demo_tag_inventory()
    if result.tags is None:
        raise Exception("Failed to load tag inventory")

    inventory = {(tag.category, tag.name) for tag in result.tags}
    for category_name, names in initial_tags.items():
        category = TagCategory(category_name)
        for name in names:
            if (category, name) in inventory:
                continue
            created = await graphql_client.demo_create_tag(category, name)
            if created.create_tag is None:
                raise Exception(f"Failed to import {category_name} tag {name}")
            inventory.add((category, name))


async def assign_demo_tags(recipe_id, tag_ids, graphql_client=None):
    if not tag_ids:
        return
    graphql_client = graphql_client or client
    result = await graphql_client.demo_assign_recipe_tags(
        recipe_id, add_tag_ids=tag_ids
    )
    if result.change_recipe_tags is None:
        raise Exception(f"Failed to assign tags to recipe {recipe_id}")


async def upload_image(recipe_id, upload):
    print(f"Adding {upload.filename} to recipe {recipe_id}")
    result = await client.add_image(recipe_id, upload)
    print(f"-> {result.add_image.url}")


async def maybe_add_image(number, recipe_id, *, numbered_images=0):
    if numbered_images:
        with Image.open(f"recipe{number}.jpg") as source:
            photo = ImageOps.fit(ImageOps.exif_transpose(source), (648, 486)).convert(
                "RGB"
            )
        font = ImageFont.load_default(size=44)
        # Uploads are prepended, so seed in reverse carousel order.
        for slide in range(numbered_images, 0, -1):
            image = photo.copy()
            draw = ImageDraw.Draw(image)
            draw.rounded_rectangle((564, 24, 624, 84), radius=10, fill="black")
            draw.text((594, 54), str(slide), font=font, fill="white", anchor="mm")
            with BytesIO() as content:
                image.save(content, format="JPEG", quality=92)
                upload = Upload(
                    f"recipe{number}.slide{slide}.jpg", content.getvalue(), "image/jpeg"
                )
            await upload_image(recipe_id, upload)
        return
    for extension, content_type in [("jpg", "image/jpeg"), ("png", "image/png")]:
        image_file = f"recipe{number}.{extension}"
        if file_exists(image_file):
            with open(image_file, mode="rb") as content:
                upload = Upload(image_file, content.read(), content_type)
            await upload_image(recipe_id, upload)
            return


async def main():
    try:
        await wait_all_online()

        args = sys.argv[1:]
        if len(args) == 1 and args[0] == "--delete":
            if await has_existing_recipes():
                confirm_delete()
            await delete_everything()

        await import_demo_tags()

        recipe_id = await insert_recipe(1)
        await maybe_add_image(1, recipe_id, numbered_images=3)
        await rate_recipe(recipe_id, 4)

        recipe_id = await insert_recipe(2)
        await maybe_add_image(2, recipe_id, numbered_images=4)
        await random_rate_recipe(recipe_id)

        recipe_id = await insert_recipe(3)
        await maybe_add_image(3, recipe_id, numbered_images=2)
        await random_rate_recipe(recipe_id)

        recipe_id = await insert_recipe(4)
        await maybe_add_image(4, recipe_id)
        await random_rate_recipe(recipe_id)

        recipe_id = await insert_recipe(5)
        await maybe_add_image(5, recipe_id)
        await random_rate_recipe(recipe_id)

        recipe_id = await insert_recipe(6)
        await maybe_add_image(6, recipe_id)
        await rate_recipe(recipe_id, 4)

    except GraphQLClientHttpError as graphql_error:
        print(f"HTTP error: {graphql_error.status_code}")
        print(json.dumps(graphql_error.response.json(), indent=2))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
