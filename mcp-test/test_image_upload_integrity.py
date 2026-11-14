"""Verify backend image-decoder rejection preserves an existing recipe image."""

import json

import pytest

from image_fixture import synthetic_png
from test_image_upload_integration import UPLOAD_URL, payload, stage
from test_mcp import FIXTURE_API, create_recipe, fixture_server_ready, mcp_session


@pytest.mark.usefixtures("fixture_server_ready")
async def test_recognized_broken_png_preserves_real_recipe_and_existing_image():
    data = synthetic_png()[:100]
    assert len(data) == 100
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    async with mcp_session(url=UPLOAD_URL) as session:
        recipe_id = await create_recipe(session, "Recognized broken PNG sentinel")
        initial = await session.call_tool("change_recipe", {
            "recipeId": recipe_id,
            "recipeJson": json.dumps({"imageUrl": f"{FIXTURE_API}/test.jpg"}),
        })
        assert not initial.is_error, initial.content[0].text
        before = payload(await session.call_tool("get_recipe", {"recipeId": recipe_id}))
        assert before["image"]["url"]
        handle = await stage(session, recipe_id, data, "image/png")
        progress = payload(await session.call_tool("image_upload_status", {"uploadHandle": handle}))
        assert progress["receivedBytes"] == len(data)
        failed = payload(await session.call_tool("image_upload_finish", {"uploadHandle": handle}))
        assert failed["state"] == "failed"
        assert failed["error"]["code"] == "invalid-image"
        assert failed["error"]["status"] == 400
        assert payload(await session.call_tool("get_recipe", {"recipeId": recipe_id})) == before
        assert payload(await session.call_tool("image_upload_finish", {"uploadHandle": handle})) == failed
        assert payload(await session.call_tool("image_upload_status", {"uploadHandle": handle})) == failed
        assert payload(await session.call_tool("get_recipe", {"recipeId": recipe_id})) == before
