import asyncio
import json
import sys
import random

from graphql_client import Client

client = Client("http://traefik/graphql")


async def delete_everything():
    print("Deleting everything")

    result = await client.delete_recipes()
    print(f"-> {result}")

    result = await client.delete_ratings()
    print(f"-> {result}")

    result = await client.delete_inspirations()
    print(f"-> {result}")


async def add_recipe(recipe):
    print(f"Adding recipe {recipe['name']}")
    result = await client.add_recipe(json.dumps(recipe))
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


async def set_inspirations(recipe_id, inspirations):
    print(f"Setting inspirations for recipe {recipe_id}")
    result = await client.set_inspirations(recipe_id, inspirations)
    print(f"-> {result}")


async def insert_recipe(number):
    recipe = load_json(f"recipe{number}.json")
    recipe["method"] = load_md(f"recipe{number}.method.md")
    recipe_id = await add_recipe(recipe)
    if file_exists(f"recipe{number}.inspirations.txt"):
        await set_inspirations(recipe_id, load_txt(f"recipe{number}.inspirations.txt"))
    return recipe_id


async def main():
    args = sys.argv[1:]
    if len(args) == 1 and args[0] == "--delete":
        await delete_everything()

    recipe_id = await insert_recipe(1)
    await rate_recipe(recipe_id, 4, "jane")

    recipe_id = await insert_recipe(2)
    await random_rate_recipe(recipe_id)

    recipe_id = await insert_recipe(3)
    await random_rate_recipe(recipe_id)


if __name__ == "__main__":
    asyncio.run(main())
