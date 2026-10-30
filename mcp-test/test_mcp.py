import json
import os
import time
import uuid
from contextlib import asynccontextmanager
from datetime import timedelta

import anyio
import httpx
import pytest
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

MCP_URL = os.environ.get("MCP_URL", "http://traefik/mcp")
FIXTURE_API = os.environ.get("FIXTURE_API", "http://traefik:3000/mcp-test-fixture")
MCP_API_TOKEN = os.environ.get("MCP_API_TOKEN")
AUTH_TOKENS = json.loads(os.environ.get("E2E_AUTH_TOKENS", "{}"))
MCP_REQUEST_TIMEOUT = timedelta(seconds=30)
MCP_SESSION_TIMEOUT_SECONDS = 60


@pytest.fixture(scope="session", autouse=True)
def fixture_server_ready():
    with httpx.Client(timeout=1) as client:
        for method, url, kwargs in (
            ("GET", f"{FIXTURE_API}/test.jpg", {}),
            (
                "POST",
                MCP_URL,
                {
                    "headers": {"Accept": "application/json, text/event-stream"},
                    "json": {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "protocolVersion": "2025-03-26",
                            "capabilities": {},
                            "clientInfo": {"name": "readiness", "version": "1"},
                        },
                    },
                },
            ),
        ):
            deadline = time.monotonic() + 30
            last_error = None
            while time.monotonic() < deadline:
                try:
                    response = client.request(method, url, **kwargs)
                    if response.is_success:
                        break
                    last_error = f"HTTP {response.status_code}"
                except httpx.RequestError as error:
                    last_error = str(error)
                time.sleep(0.2)
            else:
                pytest.fail(f"{url} did not become ready within 30 seconds: {last_error}")


@asynccontextmanager
async def mcp_session(authenticated=True, account="owner"):
    with anyio.fail_after(MCP_SESSION_TIMEOUT_SECONDS):
        headers = {}
        if authenticated:
            token = AUTH_TOKENS.get(account)
            if not token and account == "owner":
                token = MCP_API_TOKEN
            if not token:
                pytest.fail("E2E_AUTH_TOKENS with owner/memberOne/memberTwo is required")
            headers["Authorization"] = "Bearer " + token
        async with streamablehttp_client(
            MCP_URL, headers=headers, timeout=10, sse_read_timeout=30
        ) as (read_stream, write_stream, _):
            async with ClientSession(
                read_stream, write_stream, read_timeout_seconds=MCP_REQUEST_TIMEOUT
            ) as session:
                await session.initialize()
                yield session


@pytest.mark.parametrize("stall", ["response", "cleanup"])
async def test_mcp_session_deadline_bounds_response_and_cleanup(monkeypatch, stall):
    @asynccontextmanager
    async def transport(*args, **kwargs):
        incoming, read_stream = anyio.create_memory_object_stream(1)
        write_stream, outgoing = anyio.create_memory_object_stream(1)
        async with incoming, read_stream, write_stream, outgoing:
            yield read_stream, write_stream, lambda: None
            if stall == "cleanup":
                await anyio.sleep_forever()

    @asynccontextmanager
    async def initialized_session(*args, **kwargs):
        class Session:
            async def initialize(self):
                pass

        yield Session()

    monkeypatch.setitem(globals(), "streamablehttp_client", transport)
    monkeypatch.setitem(globals(), "MCP_SESSION_TIMEOUT_SECONDS", 0.05)
    if stall == "cleanup":
        monkeypatch.setitem(globals(), "ClientSession", initialized_session)

    started = time.monotonic()
    with pytest.raises(TimeoutError):
        async with mcp_session(authenticated=False):
            pass
    assert time.monotonic() - started < 2


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
            "list_tags",
            "create_tag",
            "delete_tag",
            "change_recipe_tags",
        }


async def test_tag_tools_describe_categories_and_optional_bulk_lists():
    async with mcp_session() as session:
        tools = {tool.name: tool for tool in (await session.list_tools()).tools}
        category_schema = tools["list_tags"].inputSchema["properties"]["category"]
        assert {value for value in category_schema["enum"] if value is not None} == {
            "CUISINE",
            "DIETARY_STYLE",
            "COURSE",
        }
        change_schema = tools["change_recipe_tags"].inputSchema
        assert "addTagIds" not in change_schema.get("required", [])
        assert "removeTagIds" not in change_schema.get("required", [])
        assert "collision" in tools["create_tag"].description.lower()
        assert "null" in tools["change_recipe_tags"].description.lower()


async def test_tag_inventory_create_collision_and_delete():
    async with mcp_session() as session:
        name = f"Tag {uuid.uuid4()}"
        created = await session.call_tool(
            "create_tag", {"category": "CUISINE", "name": name}
        )
        tag = json.loads(created.content[0].text)
        assert tag["category"] == "CUISINE"
        assert tag["name"] == name

        listed = await session.call_tool("list_tags", {"category": "CUISINE"})
        assert tag in json.loads(listed.content[0].text)

        collision = await session.call_tool(
            "create_tag", {"category": "CUISINE", "name": name}
        )
        assert collision.isError is True
        assert "tag-collision" in collision.content[0].text

        deleted = await session.call_tool("delete_tag", {"tagId": tag["id"]})
        assert json.loads(deleted.content[0].text) == {"deleted": True}


async def test_non_owner_cannot_create_tags():
    name = f"Denied Tag {uuid.uuid4()}"
    async with mcp_session(account="memberOne") as session:
        denied = await session.call_tool(
            "create_tag", {"category": "CUISINE", "name": name}
        )
        assert denied.isError is True
        assert "forbidden" in denied.content[0].text

    async with mcp_session() as session:
        listed = await session.call_tool("list_tags", {"category": "CUISINE"})
        assert all(tag["name"] != name for tag in json.loads(listed.content[0].text))


async def test_change_recipe_tags_bulk_and_get_recipe_includes_tags():
    async with mcp_session() as session:
        recipe_id = await create_recipe(session, "Tagged Recipe")
        tags = []
        for category, name in [
            ("CUISINE", f"Bulk A {uuid.uuid4()}"),
            ("COURSE", f"Bulk B {uuid.uuid4()}"),
        ]:
            result = await session.call_tool(
                "create_tag", {"category": category, "name": name}
            )
            tags.append(json.loads(result.content[0].text))

        changed = await session.call_tool(
            "change_recipe_tags",
            {
                "recipeId": recipe_id,
                "addTagIds": [tag["id"] for tag in tags],
            },
        )
        assert {tag["id"] for tag in json.loads(changed.content[0].text)} == {
            tag["id"] for tag in tags
        }

        recipe = json.loads(
            (await session.call_tool("get_recipe", {"recipeId": recipe_id})).content[0].text
        )
        assert {tag["id"] for tag in recipe["tags"]} == {tag["id"] for tag in tags}

        removed = await session.call_tool(
            "change_recipe_tags",
            {"recipeId": recipe_id, "removeTagIds": [tags[0]["id"]]},
        )
        assert [tag["id"] for tag in json.loads(removed.content[0].text)] == [tags[1]["id"]]


async def test_get_recipe_schema_describes_name_as_required_for_add_recipe():
    async with mcp_session() as session:
        result = await session.call_tool("get_recipe_schema", {})
        schema = json.loads(result.content[0].text)
        assert schema["addRecipe"]["required"] == ["name"]
        assert "required" not in schema["changeRecipe"]


async def test_add_recipe_without_an_api_token_is_rejected():
    async with mcp_session(authenticated=False) as session:
        result = await session.call_tool(
            "add_recipe", {"recipeJson": json.dumps({"name": "Unauthenticated Recipe"})}
        )
        assert result.isError is True
        assert "authentication-required" in result.content[0].text.lower()


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
            "add_rating", {"recipeId": recipe_id, "rating": 5}
        )
        payload = json.loads(result.content[0].text)
        assert payload["average"] > 0
        assert payload["count"] >= 1
