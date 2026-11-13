"""Real GraphQL/backend checks; protocol/fault cases live in test_image_upload.py."""

import base64
import hashlib
import json
import os
from pathlib import Path

import pytest

from test_mcp import FIXTURE_API, create_recipe, fixture_server_ready, mcp_session
from upload_fixture import UploadServer, rejected

UPLOAD_URL = os.environ.get("MCP_UPLOAD_URL", "http://mcp-upload-test-api:5000/mcp")
CHUNK = 262144


def payload(result):
    assert not result.is_error, result.content[0].text
    return json.loads(result.content[0].text)


async def stage(session, recipe_id, data):
    started = payload(await session.call_tool("image_upload_start", {
        "recipeId": recipe_id, "byteLength": len(data),
        "mediaType": "image/jpeg", "sha256": hashlib.sha256(data).hexdigest(),
    }))
    handle = started["uploadHandle"]
    for number, offset in enumerate(range(0, len(data), CHUNK)):
        result = payload(await session.call_tool("image_upload_chunk", {
            "uploadHandle": handle, "chunkNumber": number,
            "base64": base64.b64encode(data[offset:offset + CHUNK]).decode(),
        }))
        assert result["nextChunkNumber"] == number + 1
    return handle


async def test_original_rice_pudding_photo_and_current_single_image_replacement():
    original = Path("/app/fixtures/rice-pudding.jpg")
    if not original.exists():
        original = Path("../demo-data/recipe1.jpg")
    data = original.read_bytes()
    assert len(data) == 1195052
    assert hashlib.sha256(data).hexdigest() == "e09fb7cb8bf8bfc420c80b5616d4afe05edce7e539eae444e60a3e0470e2bedb"
    assert len(data) > CHUNK and len(data) % CHUNK != 0
    async with mcp_session(url=UPLOAD_URL) as session:
        recipe_id = await create_recipe(session, "Rice Pudding original-photo upload")
        first = await session.call_tool("change_recipe", {
            "recipeId": recipe_id, "recipeJson": json.dumps({"imageUrl": f"{FIXTURE_API}/test.jpg"}),
        })
        assert not first.is_error
        before = payload(await session.call_tool("get_recipe", {"recipeId": recipe_id}))
        handle = await stage(session, recipe_id, data)
        finished = payload(await session.call_tool("image_upload_finish", {"uploadHandle": handle}))
        assert finished["state"] == "finished"
        assert finished["source"]["byteLength"] == len(data)
        assert finished["source"]["sha256"] == hashlib.sha256(data).hexdigest()
        after = payload(await session.call_tool("get_recipe", {"recipeId": recipe_id}))
        assert after["image"] == finished["image"]
        assert after["image"]["url"] != before["image"]["url"]
        assert after["image"]["width"] > 1
        assert after["image"]["height"] > 1
        assert after["name"] == before["name"]
        assert "images" not in after
        assert payload(await session.call_tool("image_upload_finish", {"uploadHandle": handle})) == finished
        assert payload(await session.call_tool("get_recipe", {"recipeId": recipe_id})) == after


async def test_actual_unsupported_image_rejection_preserves_existing_image():
    async with mcp_session(url=UPLOAD_URL) as session:
        recipe_id = await create_recipe(session, "Unsupported original-image sentinel")
        await session.call_tool("change_recipe", {
            "recipeId": recipe_id, "recipeJson": json.dumps({"imageUrl": f"{FIXTURE_API}/test.jpg"}),
        })
        before = payload(await session.call_tool("get_recipe", {"recipeId": recipe_id}))
        handle = await stage(session, recipe_id, b"This is not image data, despite matching SHA-256.")
        result = payload(await session.call_tool("image_upload_finish", {"uploadHandle": handle}))
        assert result["state"] == "failed"
        assert result["error"]["code"]
        assert payload(await session.call_tool("get_recipe", {"recipeId": recipe_id})) == before
        assert payload(await session.call_tool("image_upload_finish", {"uploadHandle": handle})) == result
        assert payload(await session.call_tool("get_recipe", {"recipeId": recipe_id})) == before


@pytest.mark.parametrize("account", ["memberOne", "memberTwo", None])
async def test_real_denied_principals_cannot_change_upload_or_recipe(account):
    async with mcp_session(url=UPLOAD_URL) as owner:
        recipe_id = await create_recipe(owner, "Capability upload sentinel")
        handle = payload(await owner.call_tool("image_upload_start", {
            "recipeId": recipe_id, "byteLength": 1,
            "mediaType": "image/jpeg", "sha256": hashlib.sha256(b"x").hexdigest(),
        }))["uploadHandle"]
        before = payload(await owner.call_tool("get_recipe", {"recipeId": recipe_id}))
        status = payload(await owner.call_tool("image_upload_status", {"uploadHandle": handle}))
        async with mcp_session(authenticated=account is not None, account=account, url=UPLOAD_URL) as denied:
            for tool, args in (
                ("image_upload_start", {"recipeId": recipe_id, "byteLength": 1, "mediaType": "image/jpeg", "sha256": "0" * 64}),
                ("image_upload_chunk", {"uploadHandle": handle, "chunkNumber": 0, "base64": "eA=="}),
                ("image_upload_finish", {"uploadHandle": handle}),
                ("image_upload_status", {"uploadHandle": handle}),
            ):
                result = await denied.call_tool(tool, args)
                assert result.is_error
        assert payload(await owner.call_tool("image_upload_status", {"uploadHandle": handle})) == status
        assert payload(await owner.call_tool("get_recipe", {"recipeId": recipe_id})) == before


async def test_real_invalid_credentials_leave_upload_and_recipe_unchanged():
    async with mcp_session(url=UPLOAD_URL) as owner:
        recipe_id = await create_recipe(owner, "Invalid credential upload sentinel")
        handle = payload(await owner.call_tool("image_upload_start", {
            "recipeId": recipe_id, "byteLength": 1,
            "mediaType": "image/jpeg", "sha256": hashlib.sha256(b"x").hexdigest(),
        }))["uploadHandle"]
        before = payload(await owner.call_tool("get_recipe", {"recipeId": recipe_id}))
        status = payload(await owner.call_tool("image_upload_status", {"uploadHandle": handle}))
        transport = UploadServer(UPLOAD_URL, None, None)
        for tool, args in (
            ("image_upload_start", {"recipeId": recipe_id, "byteLength": 1, "mediaType": "image/jpeg", "sha256": "0" * 64}),
            ("image_upload_chunk", {"uploadHandle": handle, "chunkNumber": 0, "base64": "eA=="}),
            ("image_upload_finish", {"uploadHandle": handle}),
            ("image_upload_status", {"uploadHandle": handle}),
        ):
            rejected(await transport.call(tool, args, "invalid-token"), "invalid-credentials")
        assert payload(await owner.call_tool("image_upload_status", {"uploadHandle": handle})) == status
        assert payload(await owner.call_tool("get_recipe", {"recipeId": recipe_id})) == before
