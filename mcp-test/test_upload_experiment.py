"""Opt-in protocol tests: a private mock ingress, not real-client evidence.

From the repository root, create the recipe-db-upload-experiment Docker network,
start mcp-test's devcontainer with --keep-running, and connect that container to
the network with alias traefik. Bring up compose.upload-experiment.yaml using a
dedicated Compose project. The fake ingress below listens only in that test
container; do not connect application services to this mock network.

Run via mise run --raw in-devcontainer mcp-test, setting MCP_UPLOAD_URL to
http://mcp-upload-experiment:5000/mcp and invoking pytest on this file.
Teardown the dedicated Compose project, disconnect the devcontainer from the
experiment network, then remove that network. No shared-data resets are needed.
"""

import base64
import hashlib
import json
import os
import threading
from contextlib import asynccontextmanager
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpx2
import httpx
import pytest
from mcp import Client
from mcp.client.streamable_http import streamable_http_client

URL = os.environ.get("MCP_UPLOAD_URL")
pytestmark = pytest.mark.skipif(not URL, reason="isolated upload experiment not enabled")
CHUNK = 262144


@pytest.fixture
def ingress():
    state = {"permission": "allowed", "mutations": [], "upstream": "success"}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            assert self.path == "/graphql"
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.headers.get("Content-Type", "").startswith("multipart/"):
                message = BytesParser(policy=default).parsebytes(
                    b"Content-Type: " + self.headers["Content-Type"].encode()
                    + b"\r\n\r\n" + body
                )
                parts = list(message.iter_parts())
                operations = json.loads(parts[0].get_payload(decode=True))
                file_bytes = parts[-1].get_payload(decode=True)
            else:
                operations = json.loads(body)
                file_bytes = None
            query = operations["query"]
            if "canManageImages" in query:
                if self.headers.get("Authorization") != "Bearer " + "experiment-caller":
                    response = {"errors": [{"message": "Invalid credentials", "extensions": {"code": "invalid-credentials"}}]}
                elif state["permission"] == "unavailable":
                    self.send_response(503)
                    self.end_headers()
                    return
                elif state["permission"] == "error":
                    response = {"errors": [{"message": "Capability lookup unavailable", "extensions": {"code": "service-unavailable"}}]}
                else:
                    response = {"data": {"__typename": "QueryRoot", "myCapabilities": {
                        "__typename": "MyCapabilities", "canManageImages": state["permission"] == "allowed",
                    }}}
            else:
                assert "setImage" in query
                state["mutations"].append((operations["variables"]["recipeId"], file_bytes))
                if state["upstream"] == "failure":
                    response = {"errors": [{"message": "Unsupported image", "extensions": {"code": "invalid-image", "status": 422}}]}
                elif state["upstream"] == "uncertain":
                    self.close_connection = True
                    return
                else:
                    response = {"data": {"__typename": "MutationRoot", "setImage": {
                        "__typename": "ImageMetadata",
                        "url": "/images/experiment", "thumbUrl": "/images/experiment/thumb",
                        "width": 1, "height": 1, "size": len(file_bytes),
                    }}}
            encoded = json.dumps(response).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

    server = ThreadingHTTPServer(("0.0.0.0", 80), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield state
    server.shutdown()
    server.server_close()
    thread.join()


@asynccontextmanager
async def session(token="experiment-caller", url=URL):
    async with httpx2.AsyncClient(
        headers={"Authorization": "Bearer " + token}, timeout=15
    ) as http:
        async with Client(
            streamable_http_client(url, http_client=http),
            mode="2026-07-28", read_timeout_seconds=15,
        ) as client:
            yield client


def payload(result):
    assert not result.is_error, result.content[0].text
    return json.loads(result.content[0].text)


def rejected(result, code):
    assert result.is_error
    assert code in result.content[0].text


def start_args(data, **overrides):
    return {
        "recipeId": "dedicated-experiment-recipe", "byteLength": len(data),
        "mediaType": "image/jpeg", "sha256": hashlib.sha256(data).hexdigest(),
        **overrides,
    }


async def start(client, data, **overrides):
    return payload(await client.call_tool("start_image_upload", start_args(data, **overrides)))["uploadHandle"]


async def chunk(client, handle, number, data):
    return await client.call_tool("send_image_chunk", {
        "uploadHandle": handle, "chunkNumber": number,
        "base64": base64.b64encode(data).decode(),
    })


async def discard(client, handle, ingress):
    ingress["permission"] = "allowed"
    payload(await client.call_tool("discard_image_upload", {"uploadHandle": handle}))


async def test_reconstruction_retry_and_order(ingress):
    data = b"a" * CHUNK + b"b" * CHUNK + b"short final chunk"
    async with session() as client:
        tools = {tool.name: tool for tool in (await client.list_tools()).tools}
        for name in ("start_image_upload", "send_image_chunk", "finish_image_upload", "discard_image_upload"):
            assert tools[name].description
        handle = await start(client, data)
        try:
            rejected(await start_result(client, data), "upload-slot-full")
            rejected(await chunk(client, handle, 1, data[:CHUNK]), "unexpected-chunk")
            assert payload(await chunk(client, handle, 0, data[:CHUNK]))["nextChunkNumber"] == 1
            assert payload(await chunk(client, handle, 0, data[:CHUNK]))["nextChunkNumber"] == 1
            rejected(await chunk(client, handle, 0, b"x" * CHUNK), "conflicting-chunk")
            rejected(await chunk(client, handle, -1, b"x"), "unexpected-chunk")
            rejected(await client.call_tool("send_image_chunk", {
                "uploadHandle": handle, "chunkNumber": 1, "base64": "not base64!",
            }), "invalid-base64")
            rejected(await chunk(client, handle, 1, b"short"), "invalid-chunk-size")
            rejected(await chunk(client, handle, 1, b"x" * (CHUNK + 1)), "invalid-chunk-size")
            rejected(await chunk(client, handle, 1, b"x" * (CHUNK + 3)), "chunk-too-large")
            payload(await chunk(client, handle, 1, data[CHUNK:2 * CHUNK]))
            rejected(await chunk(client, handle, 0, data[:CHUNK]), "unexpected-chunk")
            payload(await chunk(client, handle, 2, data[2 * CHUNK:]))
            result = payload(await client.call_tool("finish_image_upload", {"uploadHandle": handle}))
            assert result["success"] is True
            assert result["byteLength"] == len(data)
            assert result["sha256"] == hashlib.sha256(data).hexdigest()
            assert ingress["mutations"] == [("dedicated-experiment-recipe", data)]
            rejected(await client.call_tool("finish_image_upload", {"uploadHandle": handle}), "upload-sealed")
            assert len(ingress["mutations"]) == 1
        finally:
            await discard(client, handle, ingress)
        rejected(await chunk(client, handle, 0, b"x"), "unknown-upload")


async def start_result(client, data, **overrides):
    return await client.call_tool("start_image_upload", start_args(data, **overrides))


@pytest.mark.parametrize("overrides", [
    {"byteLength": 0}, {"byteLength": -1}, {"byteLength": 5242881},
    {"sha256": "bad"}, {"sha256": "z" * 64}, {"mediaType": "text/plain"},
    {"recipeId": ""}, {"recipeId": "x" * 257},
])
async def test_invalid_declarations_do_not_take_slot(ingress, overrides):
    async with session() as client:
        rejected(await start_result(client, b"x", **overrides), "invalid-upload")
        handle = await start(client, b"x")
        await discard(client, handle, ingress)
    assert not ingress["mutations"]


@pytest.mark.parametrize("failure", ["length", "checksum", "excess"])
async def test_integrity_failure_never_assigns(ingress, failure):
    async with session() as client:
        handle = await start(client, b"good")
        try:
            if failure == "checksum":
                payload(await chunk(client, handle, 0, b"evil"))
            if failure == "excess":
                rejected(await chunk(client, handle, 0, b"excess"), "excess-bytes")
                rejected(await chunk(client, handle, 0, b"good"), "upload-sealed")
            code = {"length": "length-mismatch", "checksum": "checksum-mismatch", "excess": "upload-sealed"}[failure]
            rejected(await client.call_tool("finish_image_upload", {"uploadHandle": handle}), code)
            assert not ingress["mutations"]
        finally:
            await discard(client, handle, ingress)


@pytest.mark.parametrize("permission", ["denied", "unavailable", "error", "invalid-credentials"])
async def test_permission_checked_before_every_stage(ingress, permission):
    async with session() as client, session("invalid") as invalid:
        caller = invalid if permission == "invalid-credentials" else client
        code = {"denied": "forbidden", "error": "service-unavailable", "invalid-credentials": "invalid-credentials"}.get(permission)

        async def fail(name, arguments):
            ingress["permission"] = permission
            result = await caller.call_tool(name, arguments)
            assert result.is_error
            if code:
                assert code in result.content[0].text
            assert not ingress["mutations"]
            ingress["permission"] = "allowed"

        await fail("start_image_upload", start_args(b"good"))
        handle = await start(client, b"good")
        try:
            args = {"uploadHandle": handle, "chunkNumber": 0, "base64": base64.b64encode(b"evil").decode()}
            await fail("send_image_chunk", args)
            assert payload(await chunk(client, handle, 0, b"good"))["nextChunkNumber"] == 1
            await fail("finish_image_upload", {"uploadHandle": handle})
            result = payload(await client.call_tool("finish_image_upload", {"uploadHandle": handle}))
            assert result["success"]
            assert ingress["mutations"] == [("dedicated-experiment-recipe", b"good")]
        finally:
            await discard(client, handle, ingress)


@pytest.mark.parametrize("upstream", ["failure", "uncertain"])
async def test_final_failure_is_explicit_and_never_replayed(ingress, upstream):
    ingress["upstream"] = upstream
    async with session() as client:
        handle = await start(client, b"not an image")
        try:
            payload(await chunk(client, handle, 0, b"not an image"))
            result = await client.call_tool("finish_image_upload", {"uploadHandle": handle})
            rejected(result, "assignment-failed-or-uncertain")
            if upstream == "failure":
                assert "invalid-image" in result.content[0].text
            rejected(await client.call_tool("finish_image_upload", {"uploadHandle": handle}), "upload-sealed")
            assert len(ingress["mutations"]) == 1
        finally:
            await discard(client, handle, ingress)


async def test_maximum_file_and_request_body_limit(ingress):
    data = b"x" * (5 * 1024 * 1024)
    async with session() as client:
        handle = await start(client, data)
        try:
            for number in range(20):
                payload(await chunk(client, handle, number, data[number * CHUNK:(number + 1) * CHUNK]))
            result = payload(await client.call_tool("finish_image_upload", {"uploadHandle": handle}))
            assert result["sha256"] == hashlib.sha256(data).hexdigest()
            assert ingress["mutations"][0][1] == data
        finally:
            await discard(client, handle, ingress)
    async with httpx.AsyncClient() as http:
        response = await http.post(URL, headers={
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2025-03-26",
        }, json={
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "send_image_chunk", "arguments": {
                "uploadHandle": "x" * 32, "chunkNumber": 0, "base64": "x" * 360449,
            }},
        })
        assert response.status_code == 413
    assert len(ingress["mutations"]) == 1


@pytest.mark.parametrize("service", ["mcp-upload-backup", "mcp-upload-default", "mcp-upload-disabled"])
async def test_experiment_unavailable_without_both_testing_and_opt_in(service):
    url = f"http://{service}:5000/mcp"
    async with session(url=url) as client:
        names = {tool.name for tool in (await client.list_tools()).tools}
        assert "list_recipes" in names
        assert not names.intersection({
            "start_image_upload", "send_image_chunk", "finish_image_upload", "discard_image_upload",
        })
        rejected(await client.call_tool("start_image_upload", start_args(b"x")), "Unknown tool")
    async with httpx.AsyncClient() as http:
        assert (await http.get(f"http://{service}:5000/health")).status_code == 200
