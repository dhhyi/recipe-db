import json
import os
from contextlib import asynccontextmanager

import pytest
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

MCP_URL = os.environ.get("MCP_URL", "http://traefik/mcp")
FIXTURE_API = os.environ.get("FIXTURE_API", "http://traefik:3000/mcp-test-fixture")


@asynccontextmanager
async def mcp_session():
    async with streamable_http_client(MCP_URL) as (read_stream, write_stream):
        async with ClientSession(read_stream, write_stream) as session:
            await session.initialize()
            yield session


async def create_recipe(session, name):
    result = await session.call_tool("add_recipe", {"recipeJson": json.dumps({"name": name})})
    return json.loads(result.content[0].text)["id"]


async def test_lists_exactly_the_expected_tools_and_no_delete_tool():
    async with mcp_session() as session:
        tools = await session.list_tools()
        names = {tool.name for tool in tools.tools}
        assert names == {
            "get_recipe_schema",
            "add_recipe",
            "add_rating",
            "list_recipes",
            "get_recipe",
            "change_recipe",
        }


async def test_get_recipe_schema_describes_name_as_required_for_add_recipe():
    async with mcp_session() as session:
        result = await session.call_tool("get_recipe_schema", {})
        schema = json.loads(result.content[0].text)
        assert schema["addRecipe"]["required"] == ["name"]
        assert "required" not in schema["changeRecipe"]


async def test_add_recipe_with_valid_json_creates_a_recipe():
    async with mcp_session() as session:
        result = await session.call_tool(
            "add_recipe", {"recipeJson": json.dumps({"name": "Rice Pudding"})}
        )
        payload = json.loads(result.content[0].text)
        assert payload["id"]
        assert payload["name"] == "Rice Pudding"


async def test_add_recipe_without_a_name_fails_schema_validation():
    async with mcp_session() as session:
        result = await session.call_tool("add_recipe", {"recipeJson": json.dumps({"method": "Mix"})})
        assert "validation" in result.content[0].text.lower()


async def test_add_recipe_with_image_url_attaches_the_image():
    async with mcp_session() as session:
        result = await session.call_tool(
            "add_recipe",
            {"recipeJson": json.dumps({"name": "Recipe With Image", "imageUrl": f"{FIXTURE_API}/test.jpg"})},
        )
        assert "Image uploaded" in result.content[0].text


async def test_list_recipes_includes_a_created_recipe():
    async with mcp_session() as session:
        recipe_id = await create_recipe(session, "Listed Recipe")
        result = await session.call_tool("list_recipes", {})
        recipes = json.loads(result.content[0].text)
        assert any(r["id"] == recipe_id and r["name"] == "Listed Recipe" for r in recipes)


async def test_get_recipe_returns_full_details():
    async with mcp_session() as session:
        recipe_id = await create_recipe(session, "Detailed Recipe")
        await session.call_tool(
            "change_recipe",
            {"recipeId": recipe_id, "recipeJson": json.dumps({"method": "Simmer gently"})},
        )
        result = await session.call_tool("get_recipe", {"recipeId": recipe_id})
        payload = json.loads(result.content[0].text)
        assert payload["id"] == recipe_id
        assert payload["name"] == "Detailed Recipe"
        assert payload["method"] == "Simmer gently"


async def test_get_recipe_with_unknown_id_reports_not_found():
    async with mcp_session() as session:
        result = await session.call_tool("get_recipe", {"recipeId": "does-not-exist"})
        assert "not found" in result.content[0].text.lower()


async def test_change_recipe_updates_only_the_given_fields():
    async with mcp_session() as session:
        recipe_id = await create_recipe(session, "Original Name")
        result = await session.call_tool(
            "change_recipe",
            {"recipeId": recipe_id, "recipeJson": json.dumps({"method": "Simmer gently"})},
        )
        payload = json.loads(result.content[0].text)
        assert payload["name"] == "Original Name"


async def test_change_recipe_with_image_url_replaces_the_image():
    async with mcp_session() as session:
        recipe_id = await create_recipe(session, "Recipe To Get An Image")
        result = await session.call_tool(
            "change_recipe",
            {"recipeId": recipe_id, "recipeJson": json.dumps({"imageUrl": f"{FIXTURE_API}/test.jpg"})},
        )
        assert "Image uploaded" in result.content[0].text


async def test_add_rating_updates_the_recipe_rating():
    async with mcp_session() as session:
        recipe_id = await create_recipe(session, "Rating Test Recipe")
        result = await session.call_tool(
            "add_rating", {"recipeId": recipe_id, "rating": 5, "login": "mcp-test"}
        )
        payload = json.loads(result.content[0].text)
        assert payload["average"] > 0
        assert payload["count"] >= 1
