import asyncio
import json
import os
import sys
import random

from graphql_client import Client
from graphql_client.base_model import Upload
from graphql_client.exceptions import GraphQLClientHttpError

headers = {"apollo-require-preflight": "true"}
client = Client("http://traefik/graphql", headers=headers)


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


async def delete_everything():
    print("Deleting everything")

    result = await client.delete_recipes()
    print(f"-> {result}")

    result = await client.delete_ratings()
    print(f"-> {result}")

    result = await client.delete_inspirations()
    print(f"-> {result}")

    result = await client.delete_images()
    print(f"-> {result}")


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


async def rate_recipe(recipe_id, rating, user):
    print(f"Rating recipe {recipe_id} with {rating} by {user}")
    result = await client.add_rating(recipe_id, rating, user)
    print(f"-> {result}")


async def random_rate_recipe(recipe_id):
    users = ["joe", "jane", "bob", "alice", "eve"]

    random_users = random.sample(users, random.randint(3, 5))
    for user in random_users:
        await rate_recipe(recipe_id, random.randint(1, 5), user)


async def insert_recipe(number):
    recipe = load_json(f"recipe{number}.json")
    recipe["method"] = load_md(f"recipe{number}.method.md")
    if file_exists(f"recipe{number}.inspirations.txt"):
        recipe["inspirations"] = load_txt(f"recipe{number}.inspirations.txt")
    return await add_recipe(recipe)


async def maybe_add_image(number, recipe_id):
    image_file = f"recipe{number}.jpg"
    if file_exists(image_file):
        print(f"Adding image to recipe {recipe_id}")
        with open(image_file, mode="rb") as content:
            content = content.read()
            upload = Upload(image_file, content, "image/jpeg")
            result = await client.add_image(recipe_id, upload)
            print(f"-> {result}")


async def main():
    try:
        await wait_all_online()

        args = sys.argv[1:]
        if len(args) == 1 and args[0] == "--delete":
            await delete_everything()

        recipe_id = await insert_recipe(1)
        await maybe_add_image(1, recipe_id)
        await rate_recipe(recipe_id, 4, "jane")

        recipe_id = await insert_recipe(2)
        await maybe_add_image(2, recipe_id)
        await random_rate_recipe(recipe_id)

        recipe_id = await insert_recipe(3)
        await maybe_add_image(3, recipe_id)
        await random_rate_recipe(recipe_id)

    except GraphQLClientHttpError as graphql_error:
        print(f"HTTP error: {graphql_error.status_code}")
        print(json.dumps(graphql_error.response.json(), indent=2))
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
