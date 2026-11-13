"""Disposable production MCP process with an isolated authoritative GraphQL peer."""

import hashlib
import json
import os
import socket
import subprocess
import threading
import time
from contextlib import contextmanager
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx


class GraphQLPeer:
    def __init__(self):
        self.permissions = {}
        self.requests = []
        self.queries = []
        self.assignments = []
        self.outcome = "success"
        self.entered = threading.Event()
        self.release = threading.Event()

    def handle(self, handler):
        body = handler.rfile.read(int(handler.headers["Content-Length"]))
        authorization = handler.headers.get("Authorization")
        self.requests.append(authorization)
        multipart = handler.headers.get("Content-Type", "").startswith("multipart/")
        if multipart:
            message = BytesParser(policy=policy.default).parsebytes(
                b"Content-Type: " + handler.headers["Content-Type"].encode()
                + b"\r\nMIME-Version: 1.0\r\n\r\n" + body
            )
            parts = {
                part.get_param("name", header="content-disposition"): part.get_payload(decode=True)
                for part in message.iter_parts()
            }
            operation = json.loads(parts["operations"])
            uploaded = next(value for key, value in parts.items() if key not in ("operations", "map"))
            self.assignments.append((operation, uploaded, authorization))
            self.entered.set()
            if self.outcome == "delay":
                self.release.wait(20)
            if self.outcome == "disconnect":
                handler.connection.shutdown(socket.SHUT_RDWR)
                handler.connection.close()
                return
            if self.outcome in ("http500", "malformed"):
                handler.send_response(500 if self.outcome == "http500" else 200)
                handler.send_header("Content-Type", "application/json")
                handler.send_header("Content-Length", "1")
                handler.end_headers()
                handler.wfile.write(b"{")
                return
            if self.outcome in ("rejected", "unknown"):
                extensions = {"code": "unsupported-image", "field": "file", "status": 415}
                if self.outcome == "unknown":
                    extensions = {"code": "image-assignment-unknown", "status": 502, "outcome": "unknown"}
                result = {"data": None, "errors": [{
                    "message": (
                        "Assignment outcome could not be confirmed"
                        if self.outcome == "unknown" else "Actual image content was rejected"
                    ),
                    "extensions": extensions,
                }]}
            else:
                result = {"data": {"__typename": "MutationRoot", "setImage": {
                    "__typename": "ImageMetadata",
                    "url": "/images/assigned.jpg", "thumbUrl": "/images/assigned-thumb.jpg",
                    "width": 640, "height": 480, "size": len(uploaded),
                }}}
        else:
            operation = json.loads(body)
            self.queries.append(operation)
            assert "myCapabilities" in operation["query"]
            assert "canManageImages" in operation["query"]
            permission = self.permissions.get(authorization, True)
            if permission == "unavailable":
                handler.send_response(503)
                handler.end_headers()
                return
            if permission == "invalid":
                result = {"errors": [{"message": "Invalid credentials", "extensions": {
                    "code": "invalid-credentials", "status": 401,
                }}]}
            elif permission == "null":
                result = {"data": None}
            elif permission == "missing":
                result = {"data": {"__typename": "QueryRoot"}}
            elif permission == "error":
                result = {"data": None, "errors": [{
                    "message": "Capability lookup failed",
                    "extensions": {"code": "capability-check-failed", "status": 503},
                }]}
            else:
                result = {"data": {
                    "__typename": "QueryRoot",
                    "myCapabilities": {"__typename": "MyCapabilities", "canManageImages": permission},
                }}
        data = json.dumps(result).encode()
        handler.send_response(200)
        handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(data)))
        handler.end_headers()
        handler.wfile.write(data)


class UploadServer:
    def __init__(self, url, peer, staging):
        self.url = url
        self.peer = peer
        self.staging = staging
        self.request_id = 0

    async def rpc(self, method, params, token="permitted-one"):
        self.request_id += 1
        request_id = self.request_id
        headers = {
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2025-03-26",
        }
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        async with httpx.AsyncClient(timeout=30) as client:
            response = await client.post(self.url, headers=headers, json={
                "jsonrpc": "2.0", "id": request_id, "method": method, "params": params,
            })
        assert response.status_code == 200, response.text
        assert "mcp-session-id" not in response.headers
        messages = (
            [json.loads(line[5:]) for line in response.text.splitlines() if line.startswith("data:")]
            if response.headers.get("content-type", "").startswith("text/event-stream")
            else [response.json()]
        )
        result = next(message for message in messages if message.get("id") == request_id)
        assert "error" not in result, result
        return result["result"]

    async def call(self, name, arguments, token="permitted-one"):
        return await self.rpc("tools/call", {"name": name, "arguments": arguments}, token)

    async def start(self, data, **overrides):
        args = {
            "recipeId": "isolated-recipe", "byteLength": len(data),
            "mediaType": "image/jpeg", "sha256": hashlib.sha256(data).hexdigest(),
        }
        args.update(overrides)
        return successful(await self.call("image_upload_start", args))

    async def chunk(self, handle, number, data, token="permitted-one"):
        import base64
        return await self.call("image_upload_chunk", {
            "uploadHandle": handle, "chunkNumber": number,
            "base64": base64.b64encode(data).decode(),
        }, token)

    async def status(self, handle, token="permitted-one"):
        return successful(await self.call("image_upload_status", {"uploadHandle": handle}, token))

    async def finish(self, handle, token="permitted-one"):
        return successful(await self.call("image_upload_finish", {"uploadHandle": handle}, token))


def successful(result):
    assert not result.get("isError", False), result
    return json.loads(result["content"][0]["text"])


def rejected(result, code):
    assert result.get("isError"), result
    assert code in result["content"][0]["text"], result


@contextmanager
def disposable_server(work, mode="testing", enabled=True):
    peer = GraphQLPeer()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            peer.handle(self)

        def log_message(self, *args):
            pass

    class Server(ThreadingHTTPServer):
        request_queue_size = 128

    upstream = Server(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    staging = work / "staging"
    staging.mkdir()
    default_assembly = "/app/mcp/mcp.dll"
    if not Path(default_assembly).exists():
        default_assembly = str(
            Path(__file__).resolve().parents[1] / "mcp/bin/Debug/net9.0/mcp.dll"
        )
    assembly = os.environ.get("MCP_UPLOAD_ASSEMBLY", default_assembly)
    env = os.environ | {
        "ASPNETCORE_URLS": f"http://127.0.0.1:{port}",
        "MODE": mode, "MCP_IMAGE_UPLOAD_TESTING": "1" if enabled else "0",
        "GRAPHQL_URL": f"http://127.0.0.1:{upstream.server_port}/graphql",
        "MCP_IMAGE_UPLOAD_DIRECTORY": str(staging),
    }
    with (work / "server.log").open("w+") as log:
        process = subprocess.Popen(["dotnet", assembly], env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    log.seek(0)
                    raise AssertionError("Disposable MCP exited: " + log.read())
                try:
                    if httpx.get(f"http://127.0.0.1:{port}/health", timeout=1).is_success:
                        break
                except httpx.RequestError:
                    pass
                time.sleep(0.1)
            else:
                raise AssertionError("Disposable MCP did not become healthy")
            yield UploadServer(f"http://127.0.0.1:{port}/mcp", peer, staging)
        finally:
            peer.release.set()
            process.terminate()
            process.wait(timeout=10)
            upstream.shutdown()
            upstream.server_close()
            thread.join(timeout=5)
            log.seek(0)
            print(log.read()[-6000:])
