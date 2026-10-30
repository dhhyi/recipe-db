import asyncio
import json
import os
import sys
import random
import unicodedata

import httpx
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
TAG_CATEGORIES = {
    "Küche": "CUISINE",
    "Ernährung": "DIETARY_STYLE",
    "Gang": "COURSE",
}


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


async def insert_recipe(number, tag_ids):
    recipe = load_json(f"recipe{number}.json")
    tags = recipe.pop("tags", [])
    recipe["method"] = load_md(f"recipe{number}.method.md")
    if file_exists(f"recipe{number}.inspirations.txt"):
        recipe["inspirations"] = load_txt(f"recipe{number}.inspirations.txt")
    recipe_id = await add_recipe(recipe)
    await assign_demo_tags(recipe_id, tags, tag_ids)
    return recipe_id


def recipe_tag_definitions():
    return {
        number: [
            (TAG_CATEGORIES[tag["category"]], tag["name"])
            for tag in load_json(f"recipe{number}.json").get("tags", [])
        ]
        for number in range(1, 6)
    }


def tag_identity_key(tag_category, name):
    normalized = unicodedata.normalize("NFKD", name).casefold()
    identity = []
    for character in normalized:
        character_category = unicodedata.category(character)
        if character_category[0] in ("L", "N") and not character.isascii():
            raise ValueError(f"Tag name does not fold to ASCII: {name}")
        if character.isascii() and character.isalnum():
            identity.append(character)
    if not identity:
        raise ValueError(f"Tag name has no ASCII letters or numbers: {name}")
    return tag_category, "".join(identity)


async def seed_demo_tag_inventory(tag_definitions=None, graphql_client=None):
    graphql_client = graphql_client or client
    if tag_definitions is None:
        tag_definitions = recipe_tag_definitions()
    result = await graphql_client.demo_tag_inventory()
    if result.tags is None:
        raise Exception("Failed to load tag inventory")

    inventory = {
        tag_identity_key(tag.category.value, tag.name): tag.id for tag in result.tags
    }
    tag_ids = {}
    for tags in tag_definitions.values():
        for category, name in tags:
            key = tag_identity_key(category, name)
            if key not in inventory:
                created = await graphql_client.demo_create_tag(
                    TagCategory(category), name
                )
                if created.create_tag is None:
                    raise Exception(f"Failed to create {category} tag {name}")
                inventory[key] = created.create_tag.id
            tag_ids[key] = inventory[key]
    return tag_ids


async def assign_demo_tags(recipe_id, tags, tag_ids, graphql_client=None):
    if not tags:
        return
    graphql_client = graphql_client or client
    assigned_ids = [
        tag_ids[tag_identity_key(category, name)] for category, name in tags
    ]
    result = await graphql_client.demo_assign_recipe_tags(
        recipe_id, add_tag_ids=assigned_ids
    )
    if result.change_recipe_tags is None:
        raise Exception(f"Failed to assign tags to recipe {recipe_id}")


async def maybe_add_image(number, recipe_id):
    image_file = f"recipe{number}.jpg"
    if file_exists(image_file):
        print(f"Adding image to recipe {recipe_id}")
        with open(image_file, mode="rb") as content:
            content = content.read()
            upload = Upload(image_file, content, "image/jpeg")
            result = await client.add_image(recipe_id, upload)
            print(f"-> {result.set_image.url}")


async def main():
    try:
        await wait_all_online()

        args = sys.argv[1:]
        if len(args) == 1 and args[0] == "--delete":
            if await has_existing_recipes():
                confirm_delete()
            await delete_everything()

        tag_ids = await seed_demo_tag_inventory()

        recipe_id = await insert_recipe(1, tag_ids)
        await maybe_add_image(1, recipe_id)
        await rate_recipe(recipe_id, 4)

        recipe_id = await insert_recipe(2, tag_ids)
        await maybe_add_image(2, recipe_id)
        await random_rate_recipe(recipe_id)

        recipe_id = await insert_recipe(3, tag_ids)
        await maybe_add_image(3, recipe_id)
        await random_rate_recipe(recipe_id)

        recipe_id = await insert_recipe(4, tag_ids)
        await maybe_add_image(4, recipe_id)
        await random_rate_recipe(recipe_id)

        recipe_id = await insert_recipe(5, tag_ids)
        await maybe_add_image(5, recipe_id)
        await random_rate_recipe(recipe_id)

    except GraphQLClientHttpError as graphql_error:
        print(f"HTTP error: {graphql_error.status_code}")
        print(json.dumps(graphql_error.response.json(), indent=2))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
