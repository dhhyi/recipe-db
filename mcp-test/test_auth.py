import json
import uuid
from itertools import count

import anyio
import httpx
import pytest

from test_mcp import (
    AUTH_TOKENS,
    FIXTURE_API,
    MCP_URL,
    TRAEFIK_HEADERS,
    create_recipe,
    fixture_server_ready,
    mcp_session,
)

REQUEST_IDS = count(1)
GRAPHQL_URL = MCP_URL.rstrip("/").rsplit("/", 1)[0] + "/graphql"


class RedactedAccounts(dict):
    def __repr__(self):
        return "<configured auth tokens>"


@pytest.fixture(scope="module")
def accounts(fixture_server_ready):
    if not all(AUTH_TOKENS.get(name) for name in ("owner", "memberOne", "memberTwo")):
        pytest.fail("E2E_AUTH_TOKENS with owner/memberOne/memberTwo is required")
    return RedactedAccounts(AUTH_TOKENS)


def payload(result):
    assert result.is_error is False
    return json.loads(result.content[0].text)


def denied(result, code):
    assert result.is_error is True
    assert code in result.content[0].text


async def rpc(client, method, params, headers=None):
    request_id = next(REQUEST_IDS)
    response = await client.post(
        MCP_URL,
        headers=headers,
        json={"jsonrpc": "2.0", "id": request_id, "method": method, "params": params},
    )
    assert response.status_code == 200
    assert "mcp-session-id" not in response.headers
    if response.headers.get("content-type", "").startswith("text/event-stream"):
        messages = [
            json.loads(line[5:].strip())
            for line in response.text.splitlines()
            if line.startswith("data:")
        ]
        message = next(message for message in messages if message.get("id") == request_id)
    else:
        message = response.json()
    assert message["id"] == request_id
    assert "error" not in message
    return message["result"]


async def initialize(client, headers=None):
    return await rpc(
        client,
        "initialize",
        {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "auth-regression", "version": "1"},
        },
        headers,
    )


def bearer(token):
    return {"Authorization": "Bearer " + token}


async def call(client, name, arguments, headers=None):
    return await rpc(
        client,
        "tools/call",
        {"name": name, "arguments": arguments},
        headers,
    )


def raw_payload(result):
    assert result.get("isError", False) is False
    return json.loads(result["content"][0]["text"])


def raw_denied(result, code):
    assert result.get("isError") is True
    assert code in result["content"][0]["text"]


async def graph_ql(client, query, variables, token=None):
    headers = {"Authorization": "Bearer " + token} if token else {}
    response = await client.post(
        GRAPHQL_URL,
        headers=headers,
        json={"query": query, "variables": variables},
    )
    assert response.status_code == 200
    return response.json()


@pytest.fixture
def raw_client():
    return httpx.AsyncClient(
        headers={
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2025-03-26",
            **TRAEFIK_HEADERS,
        },
        timeout=30,
    )


async def test_anonymous_reads_and_denied_writes_leave_data_unchanged(accounts):
    async with mcp_session() as owner:
        recipe_id = await create_recipe(owner, "Anonymous authorization sentinel")
        image = payload(await owner.call_tool(
            "add_recipe_image", {"recipeId": recipe_id, "imageUrl": f"{FIXTURE_API}/test.jpg"}
        ))
    async with mcp_session(authenticated=False) as anonymous:
        tools = await anonymous.list_tools()
        assert "get_recipe_schema" in {tool.name for tool in tools.tools}
        assert payload(await anonymous.call_tool("get_recipe_schema", {}))["addRecipe"]
        before_list = payload(await anonymous.call_tool("list_recipes", {}))
        before = payload(await anonymous.call_tool("get_recipe", {"recipeId": recipe_id}))
        assert before["images"] == [image]
        for name, arguments in (
            ("add_recipe", {"recipeJson": json.dumps({"name": "Denied anonymous recipe"})}),
            ("change_recipe", {"recipeId": recipe_id, "recipeJson": '{"name":"Denied"}'}),
            ("add_recipe_image", {"recipeId": recipe_id, "imageUrl": f"{FIXTURE_API}/missing.jpg"}),
            ("delete_recipe_image", {"recipeId": recipe_id, "imageId": image["id"]}),
            ("add_rating", {"recipeId": recipe_id, "rating": 5}),
        ):
            denied(await anonymous.call_tool(name, arguments), "authentication-required")
        after = payload(await anonymous.call_tool("get_recipe", {"recipeId": recipe_id}))
        assert after == before
        assert payload(await anonymous.call_tool("list_recipes", {})) == before_list


async def test_member_ratings_are_distinct_replaceable_and_cannot_impersonate(accounts):
    async with mcp_session() as owner:
        recipe_id = await create_recipe(owner, "Member rating identities")
    async with mcp_session(account="memberOne") as first:
        tools = await first.list_tools()
        rating_tool = next(tool for tool in tools.tools if tool.name == "add_rating")
        assert "login" not in rating_tool.input_schema.get("properties", {})
        for name, arguments in (
            ("add_recipe", {"recipeJson": '{"name":"Denied member recipe"}'}),
            ("change_recipe", {"recipeId": recipe_id, "recipeJson": '{"name":"Denied"}'}),
            ("add_recipe_image", {"recipeId": recipe_id, "imageUrl": f"{FIXTURE_API}/missing.jpg"}),
            ("delete_recipe_image", {"recipeId": recipe_id, "imageId": "a" * 64}),
        ):
            denied(await first.call_tool(name, arguments), "forbidden")
        original = payload(await first.call_tool("get_recipe", {"recipeId": recipe_id}))
        assert original["name"] == "Member rating identities"
        assert original["images"] == []
        result = payload(await first.call_tool("add_rating", {"recipeId": recipe_id, "rating": 2}))
        assert result["count"] == 1
        result = payload(await first.call_tool("add_rating", {"recipeId": recipe_id, "rating": 4}))
        assert result["count"] == 1
        assert result["average"] == 4
        forged = await first.call_tool(
            "add_rating", {"recipeId": recipe_id, "rating": 3, "login": "e2e-member-two"}
        )
        if forged.is_error:
            result = payload(await first.call_tool("get_recipe", {"recipeId": recipe_id}))["rating"]
            assert result["average"] == 4
        else:
            result = payload(forged)
            assert result["average"] == 3
        assert result["count"] == 1
        first_vote = result["average"]
    async with mcp_session(account="memberTwo") as second:
        result = payload(await second.call_tool("add_rating", {"recipeId": recipe_id, "rating": 1}))
        assert result["count"] == 2
        assert result["average"] == (first_vote + 1) / 2


async def test_each_post_initialize_request_uses_current_bearer(accounts, raw_client):
    async with raw_client as client:
        await initialize(client, bearer(accounts["owner"]))
        arguments = {"recipeJson": '{"name":"Per-request identity"}'}
        for headers, code in (
            (None, "authentication-required"),
            (bearer(accounts["memberOne"]), "forbidden"),
            (bearer("not-a-valid-token"), "invalid-credentials"),
        ):
            raw_denied(await call(client, "add_recipe", arguments, headers), code)
        recipe_id = raw_payload(await call(client, "add_recipe", arguments, bearer(accounts["owner"])))["id"]
        raw_denied(await call(client, "add_rating", {"recipeId": recipe_id, "rating": 5}), "authentication-required")
        raw_payload(await call(client, "get_recipe", {"recipeId": recipe_id}))
        await initialize(client)
        assert raw_payload(await call(client, "add_recipe", arguments, bearer(accounts["owner"])))["id"]


@pytest.mark.parametrize(
    "authorization",
    [
        " ".join(("Bearer", "wrong-token")),
        "Basic dXNlcjpwYXNz",
        "Bearer",
        " ".join(("Bearer", "one", "two")),
        "",
    ],
    ids=["unknown-token", "wrong-scheme", "missing-token", "extra-token", "empty-header"],
)
async def test_explicit_invalid_credentials_never_become_anonymous(authorization, raw_client):
    async with raw_client as client:
        await initialize(client)
        for name in ("list_recipes", "get_recipe_schema"):
            result = await call(client, name, {}, {"Authorization": authorization})
            raw_denied(result, "invalid-credentials")


@pytest.mark.parametrize("combined", [False, True], ids=["duplicate-headers", "comma-joined"])
async def test_multiple_valid_bearers_are_rejected(accounts, raw_client, combined):
    values = [bearer(accounts[name])["Authorization"] for name in ("owner", "memberOne")]
    headers = (
        {"Authorization": ", ".join(values)}
        if combined
        else [("Authorization", value) for value in values]
    )
    async with raw_client as client:
        await initialize(client)
        result = await call(client, "list_recipes", {}, headers)
        contains_credential = any(token in json.dumps(result) for token in accounts.values())
        assert contains_credential is False
        raw_denied(result, "invalid-credentials")


async def test_legacy_sse_endpoint_is_not_enabled(raw_client):
    async with raw_client as client:
        response = await client.get(
            MCP_URL.rstrip("/") + "/sse", headers={"Accept": "text/event-stream"}
        )
        assert response.status_code == 404


async def test_cookies_do_not_authenticate_and_bearer_wins(accounts, raw_client):
    async with raw_client as client:
        await initialize(client)
        cookies = {"Cookie": "_oauth2_proxy=" + accounts["owner"]}
        arguments = {"recipeJson": '{"name":"Credential precedence over cookies"}'}
        raw_payload(await call(client, "list_recipes", {}, cookies))
        raw_denied(await call(client, "add_recipe", arguments, cookies), "authentication-required")
        raw_denied(
            await call(client, "add_recipe", arguments, cookies | bearer(accounts["memberOne"])),
            "forbidden",
        )
        assert raw_payload(
            await call(
                client, "add_recipe", arguments,
                cookies | bearer(accounts["owner"]) | {"Origin": "https://untrusted.invalid"},
            )
        )["id"]
        raw_denied(
            await call(client, "list_recipes", {}, cookies | bearer("wrong-token")),
            "invalid-credentials",
        )


async def test_concurrent_graphql_and_mcp_ratings_preserve_each_identity(
    accounts, raw_client
):
    async with httpx.AsyncClient(
        headers=TRAEFIK_HEADERS, timeout=30
    ) as graphql_client, raw_client as mcp_client:
        recipe = await graph_ql(
            graphql_client,
            "mutation($value: RecipeInput!) { createRecipe(value: $value) { id } }",
            {"value": {"name": "MCP GraphQL rating concurrency " + uuid.uuid4().hex}},
            accounts["owner"],
        )
        assert "errors" not in recipe
        recipe_id = recipe["data"]["createRecipe"]["id"]
        try:
            rate_mutation = (
                "mutation($id: ID!, $rating: Int!) "
                "{ rate(id: $id, rating: $rating) { average count myRating } }"
            )
            for identity, vote in (("memberOne", 2), ("memberTwo", 4)):
                seeded = await graph_ql(
                    graphql_client,
                    rate_mutation,
                    {"id": recipe_id, "rating": vote},
                    accounts[identity],
                )
                assert "errors" not in seeded

            await initialize(mcp_client)
            graphql_results = {}
            mcp_results = {}

            async def read_rating(identity, token=None):
                graphql_results[identity] = await graph_ql(
                    graphql_client,
                    "query($id: ID!) { rating(id: $id) { average count myRating } }",
                    {"id": recipe_id},
                    token,
                )

            async def add_rating(identity, vote, token=None):
                mcp_results[identity] = await call(
                    mcp_client,
                    "add_rating",
                    {"recipeId": recipe_id, "rating": vote},
                    bearer(token) if token else None,
                )

            async with anyio.create_task_group() as group:
                for identity, vote in (("memberOne", 2), ("memberTwo", 4)):
                    group.start_soon(read_rating, identity, accounts[identity])
                    group.start_soon(add_rating, identity, vote, accounts[identity])
                group.start_soon(read_rating, "anonymous")
                group.start_soon(add_rating, "anonymous", 5)

            for identity, vote in (("memberOne", 2), ("memberTwo", 4)):
                assert "errors" not in graphql_results[identity]
                assert graphql_results[identity]["data"]["rating"] == {
                    "average": 3,
                    "count": 2,
                    "myRating": vote,
                }
                assert raw_payload(mcp_results[identity]) == {
                    "average": 3,
                    "count": 2,
                }
            anonymous_rating = graphql_results["anonymous"]
            assert anonymous_rating["data"]["rating"] == {
                "average": 3,
                "count": 2,
                "myRating": None,
            }
            assert any(
                error.get("extensions", {}).get("code") == "authentication-required"
                for error in anonymous_rating.get("errors", [])
            )
            raw_denied(mcp_results["anonymous"], "authentication-required")

            recipe = raw_payload(
                await call(
                    mcp_client,
                    "get_recipe",
                    {"recipeId": recipe_id},
                    bearer(accounts["owner"]),
                )
            )
            assert recipe["rating"]["average"] == 3
            assert recipe["rating"]["count"] == 2
        finally:
            deleted = await graph_ql(
                graphql_client,
                "mutation($id: ID!) { deleteRecipe(id: $id) }",
                {"id": recipe_id},
                accounts["owner"],
            )
            assert "errors" not in deleted


async def test_concurrent_requests_do_not_share_member_or_owner_identity(accounts, raw_client):
    async with raw_client as client:
        await initialize(client)
        recipe_id = raw_payload(await call(
            client, "add_recipe", {"recipeJson": '{"name":"Concurrent identities"}'}, bearer(accounts["owner"])
        ))["id"]
        results = {}

        async def rate(account, rating):
            results[account] = await call(
                client, "add_rating", {"recipeId": recipe_id, "rating": rating}, bearer(accounts[account])
            )

        async def anonymous():
            results["anonymous"] = await call(client, "add_rating", {"recipeId": recipe_id, "rating": 5})

        async def member_write():
            results["member-write"] = await call(
                client, "change_recipe", {"recipeId": recipe_id, "recipeJson": '{"name":"Leaked owner"}'},
                bearer(accounts["memberOne"]),
            )

        async def owner_write():
            results["owner-write"] = await call(
                client, "change_recipe",
                {"recipeId": recipe_id, "recipeJson": '{"method":"Owner concurrent update"}'},
                bearer(accounts["owner"]),
            )

        async with anyio.create_task_group() as group:
            group.start_soon(rate, "memberOne", 2)
            group.start_soon(rate, "memberTwo", 4)
            group.start_soon(anonymous)
            group.start_soon(member_write)
            group.start_soon(owner_write)
        raw_payload(results["memberOne"])
        raw_payload(results["memberTwo"])
        raw_payload(results["owner-write"])
        raw_denied(results["anonymous"], "authentication-required")
        raw_denied(results["member-write"], "forbidden")
        recipe = raw_payload(await call(client, "get_recipe", {"recipeId": recipe_id}))
        assert recipe["name"] == "Concurrent identities"
        assert recipe["method"] == "Owner concurrent update"
        assert recipe["rating"]["count"] == 2
        assert recipe["rating"]["average"] == 3


async def test_owner_upload_follows_external_redirect_without_sending_bearer(accounts):
    async with mcp_session() as owner:
        recipe_id = await create_recipe(owner, "Credential-free image download")
        result = await owner.call_tool(
            "add_recipe_image",
            {"recipeId": recipe_id, "imageUrl": f"{FIXTURE_API}/redirect.jpg"},
        )
        added = payload(result)
        recipe = payload(await owner.call_tool("get_recipe", {"recipeId": recipe_id}))
        assert recipe["images"] == [added]
