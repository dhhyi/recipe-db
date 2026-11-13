"""Focused physical-integrity, decoder-rejection and streamed-request limits."""

import json

import httpx
import pytest

from image_fixture import synthetic_png
from test_image_upload_integration import UPLOAD_URL, payload, stage
from test_mcp import FIXTURE_API, create_recipe, fixture_server_ready, mcp_session
from upload_fixture import disposable_server, successful


@pytest.mark.parametrize("tampering", ["truncate", "extend"])
async def test_staged_physical_length_mismatch_fails_without_assignment(tmp_path, tampering):
    data = b"correct source bytes with a verified length and checksum"
    with disposable_server(tmp_path) as server:
        handle = (await server.start(data))["uploadHandle"]
        accepted = successful(await server.chunk(handle, 0, data))
        assert accepted["receivedBytes"] == len(data)
        assert accepted["nextChunkNumber"] == 1
        before = await server.status(handle)
        photo = server.staging / (handle + ".photo")
        assert photo.read_bytes() == data
        with photo.open("r+b") as staged:
            if tampering == "truncate":
                staged.truncate(len(data) - 1)
            else:
                staged.seek(0, 2)
                staged.write(b"extra byte")
        assert photo.stat().st_size != len(data)

        failed = await server.finish(handle)
        assert failed["state"] == "failed"
        assert failed["error"]["code"] == "upload-integrity-failed"
        for key in ("receivedBytes", "nextChunkNumber"):
            assert failed[key] == before[key]
        assert not server.peer.assignments
        assert await server.finish(handle) == failed
        assert await server.status(handle) == failed
        assert not server.peer.assignments


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


async def test_oversized_chunked_request_rejected_before_parsing_or_staging(tmp_path):
    async def streamed_body():
        for _ in range(8):
            yield b" " * 65536
        yield b" "

    with disposable_server(tmp_path) as server:
        assert list(server.staging.iterdir()) == []
        async with httpx.AsyncClient(timeout=30) as client:
            request = client.build_request("POST", server.url, headers={
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
                "MCP-Protocol-Version": "2025-03-26",
            }, content=streamed_body())
            assert "content-length" not in request.headers
            assert request.headers["transfer-encoding"] == "chunked"
            response = await client.send(request)
            assert response.status_code == 413, response.text
            health = await client.get(server.url.removesuffix("/mcp") + "/health")
            assert health.is_success
        assert list(server.staging.iterdir()) == []
        assert server.peer.requests == []
        assert server.peer.queries == []
        assert server.peer.assignments == []
