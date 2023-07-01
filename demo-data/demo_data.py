import asyncio
import json

from graphql_client import Client

client = Client("http://traefik/graphql")


async def delete_everything():
    print("Deleting everything")

    result = await client.delete_ratings()
    print(f"-> {result}")

    result = await client.delete_recipes()
    print(f"-> {result}")


async def add_recipe(name):
    print(f"Adding recipe {name}")
    result = await client.add_recipe(json.dumps({"name": name}))
    print(f"-> {result}")

    if result.create_recipe is None:
        raise Exception("Failed to add recipe")
    return result.create_recipe.id


async def rate_recipe(recipe_id, rating, user):
    print(f"Rating recipe {recipe_id} with {rating} by {user}")
    result = await client.add_rating(recipe_id, rating, user)
    print(f"-> {result}")


async def main():
    await delete_everything()

    recipe_id = await add_recipe("Rice Pudding")
    await rate_recipe(recipe_id, 5, "joe")
    await rate_recipe(recipe_id, 4, "jane")

    recipe_id = await add_recipe("Beetroot Soup")
    await rate_recipe(recipe_id, 3, "joe")

    recipe_id = await add_recipe("Bean Stew")
    await rate_recipe(recipe_id, 4, "jane")


if __name__ == "__main__":
    asyncio.run(main())
