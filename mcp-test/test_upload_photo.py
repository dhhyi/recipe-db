"""Opt-in scripted real-GraphQL baseline; this is NOT an AI-client experiment.

Use only a fresh isolated development Compose stack with experimental uploads
explicitly enabled on MCP. MCP_UPLOAD_PHOTO must name the client-workspace copy
of demo-data/recipe1.jpg, not the original server-side fixture. The test only
uploads through MCP and deletes its own dedicated recipe through trusted
GraphQL ingress afterwards. No reset APIs are used.
"""

import base64
import hashlib
import json
import os
import time
import uuid
from pathlib import Path

import httpx
import pytest

from test_mcp import AUTH_TOKENS, create_recipe, fixture_server_ready, mcp_session

PHOTO = os.environ.get("MCP_UPLOAD_PHOTO")
pytestmark = pytest.mark.skipif(not PHOTO, reason="real photo experiment not enabled")
CHUNK = 262144


def payload(result):
    assert not result.is_error, result.content[0].text
    return json.loads(result.content[0].text)


async def test_copied_photo_through_real_graphql(fixture_server_ready):
    photo = Path(PHOTO).read_bytes()
    digest = hashlib.sha256(photo).hexdigest()
    assert len(photo) == 1195052
    assert digest == "e09fb7cb8bf8bfc420c80b5616d4afe05edce7e539eae444e60a3e0470e2bedb"
    assert Path(PHOTO).name != "recipe1.jpg", "Use a separately named client copy"
    handles = []
    started = time.monotonic()
    async with mcp_session() as client:
        recipe_id = await create_recipe(client, f"Chunk experiment {uuid.uuid4()}")
        try:
            handle = payload(await client.call_tool("start_image_upload", {
                "recipeId": recipe_id, "byteLength": len(photo),
                "mediaType": "image/jpeg", "sha256": digest,
            }))["uploadHandle"]
            handles.append(handle)
            argument_sizes = []
            for number, offset in enumerate(range(0, len(photo), CHUNK)):
                args = {
                    "uploadHandle": handle, "chunkNumber": number,
                    "base64": base64.b64encode(photo[offset:offset + CHUNK]).decode(),
                }
                argument_sizes.append(len(json.dumps(args).encode()))
                assert payload(await client.call_tool("send_image_chunk", args))["nextChunkNumber"] == number + 1
                if number == 0:
                    assert payload(await client.call_tool("send_image_chunk", args))["nextChunkNumber"] == 1
            result = payload(await client.call_tool("finish_image_upload", {"uploadHandle": handle}))
            assert result["success"] is True
            assert result["byteLength"] == len(photo)
            assert result["sha256"] == digest
            image = payload(await client.call_tool("get_recipe", {"recipeId": recipe_id}))["image"]
            assert image["width"] > 0 and image["height"] > 0 and image["size"] > 0
            async with httpx.AsyncClient() as http:
                # Read only the public image URL returned through the normal application interface.
                url = httpx.URL(image["url"])
                response = await http.get(str(url) if url.is_absolute_url else f"http://traefik{url}")
                assert response.status_code == 200
                assert response.headers["content-type"].startswith("image/")
                assert response.content
            payload(await client.call_tool("discard_image_upload", {"uploadHandle": handle}))
            handles.remove(handle)

            invalid = b"checksum-correct but unsupported image content"
            handle = payload(await client.call_tool("start_image_upload", {
                "recipeId": recipe_id, "byteLength": len(invalid), "mediaType": "image/jpeg",
                "sha256": hashlib.sha256(invalid).hexdigest(),
            }))["uploadHandle"]
            handles.append(handle)
            payload(await client.call_tool("send_image_chunk", {
                "uploadHandle": handle, "chunkNumber": 0,
                "base64": base64.b64encode(invalid).decode(),
            }))
            failure = await client.call_tool("finish_image_upload", {"uploadHandle": handle})
            assert failure.is_error
            assert "assignment-failed-or-uncertain" in failure.content[0].text
            assert payload(await client.call_tool("get_recipe", {"recipeId": recipe_id}))["image"] == image
            print(json.dumps({
                "transport": "scripted Python MCP SDK (not model-mediated)",
                "sourceBytes": len(photo), "sourceSha256": digest,
                "uploadCalls": 7, "deliberateRetryCalls": 1, "chunkArgumentBytes": argument_sizes,
                "elapsedSecondsAfterSourceReadIncludingInvalidImageCheck": round(time.monotonic() - started, 3),
                "tokenUsage": "unavailable", "cost": "unavailable",
            }))
        finally:
            try:
                for handle in handles:
                    payload(await client.call_tool("discard_image_upload", {"uploadHandle": handle}))
            finally:
                async with httpx.AsyncClient() as http:
                    response = await http.post(
                        "http://traefik/graphql",
                        headers={"Authorization": "Bearer " + AUTH_TOKENS["owner"], "Origin": "http://traefik"},
                        json={"query": "mutation($id: ID!) { deleteRecipe(id: $id) }", "variables": {"id": recipe_id}},
                    )
                    response.raise_for_status()
                    assert response.json().get("data", {}).get("deleteRecipe") is True
