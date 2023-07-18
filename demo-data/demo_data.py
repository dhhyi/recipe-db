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
    for _ in range(1, 10):
        await rate_recipe(recipe_id, random.randint(1, 5), random.choice(users))


async def set_inspirations(recipe_id, inspirations):
    print(f"Setting inspirations for recipe {recipe_id}")
    result = await client.set_inspirations(recipe_id, inspirations)
    print(f"-> {result}")


async def main():
    args = sys.argv[1:]
    if len(args) == 1 and args[0] == "--delete":
        await delete_everything()

    recipe_id = await add_recipe(load_json("recipe1.json"))
    if file_exists("recipe1.inspirations.txt"):
        await set_inspirations(recipe_id, load_txt("recipe1.inspirations.txt"))
    await rate_recipe(recipe_id, 4, "jane")

    recipe_id = await add_recipe(load_json("recipe2.json"))
    if file_exists("recipe2.inspirations.txt"):
        await set_inspirations(recipe_id, load_txt("recipe2.inspirations.txt"))
    await random_rate_recipe(recipe_id)

    recipe_id = await add_recipe(load_json("recipe3.json"))
    if file_exists("recipe3.inspirations.txt"):
        await set_inspirations(recipe_id, load_txt("recipe3.inspirations.txt"))
    await random_rate_recipe(recipe_id)


if __name__ == "__main__":
    asyncio.run(main())
