import base64
import hashlib
import shutil
import uuid
from pathlib import Path

import anyio
import httpx
import pytest

from upload_fixture import disposable_server, rejected, successful

CHUNK = 262144
FILE = 5242880
CAPACITY = 104857600
TOOLS = {
    "image_upload_start", "image_upload_chunk",
    "image_upload_finish", "image_upload_status",
}


@pytest.fixture
def upload_server():
    # Keep scratch files inside the project, including when pytest's default base temp is external.
    root = Path("target") / ("upload-" + uuid.uuid4().hex)
    root.mkdir(parents=True)
    try:
        with disposable_server(root.resolve()) as server:
            yield server
    finally:
        shutil.rmtree(root)


async def complete(server, data):
    started = await server.start(data)
    handle = started["uploadHandle"]
    for number, offset in enumerate(range(0, len(data), CHUNK)):
        successful(await server.chunk(handle, number, data[offset:offset + CHUNK]))
    return handle


async def test_upload_discovery_schemas_and_recovery_descriptions(upload_server):
    tools = {
        tool["name"]: tool
        for tool in (await upload_server.rpc("tools/list", {}))["tools"]
    }
    assert {name for name in tools if "upload" in name} == TOOLS
    assert set(tools["image_upload_start"]["inputSchema"]["required"]) == {
        "recipeId", "byteLength", "mediaType", "sha256",
    }
    assert set(tools["image_upload_chunk"]["inputSchema"]["required"]) == {
        "uploadHandle", "chunkNumber", "base64",
    }
    for name in ("image_upload_finish", "image_upload_status"):
        assert tools[name]["inputSchema"]["required"] == ["uploadHandle"]
    descriptions = " ".join(tools[name]["description"].lower() for name in TOOLS)
    for term in ("262144", "5242880", "104857600", "sha-256", "base64", "permission", "retry", "replaces"):
        assert term in descriptions
    assert "uncertain" in descriptions
    assert "discard" not in tools


async def test_multichunk_original_bytes_short_final_saved_receipt_and_lost_reply(upload_server):
    data = bytes(range(256)) * 2048 + b"short final chunk"
    started = await upload_server.start(data)
    handle = started["uploadHandle"]
    assert started["state"] == "receiving"
    assert started["chunkLimit"] == CHUNK
    assert started["receivedBytes"] == started["nextChunkNumber"] == 0
    successful(await upload_server.chunk(handle, 0, data[:CHUNK]))
    # Discard the acknowledgement and reconnect with another permitted principal.
    assert (await upload_server.status(handle, "permitted-two"))["nextChunkNumber"] == 1
    for number, offset in enumerate(range(CHUNK, len(data), CHUNK), 1):
        result = successful(await upload_server.chunk(handle, number, data[offset:offset + CHUNK], "permitted-two"))
        assert result["receivedBytes"] == min(offset + CHUNK, len(data))
    finished = await upload_server.finish(handle, "permitted-two")
    assert finished["state"] == "finished"
    assert finished["source"] == {
        "byteLength": len(data), "mediaType": "image/jpeg",
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    assert finished["image"]["url"] == "/images/assigned.jpg"
    assert finished["image"]["size"] == len(data)
    assert upload_server.peer.assignments[0][1] == data
    assert upload_server.peer.assignments[0][2].split() == ["Bearer", "permitted-two"]
    assert await upload_server.finish(handle) == finished
    assert await upload_server.status(handle) == finished
    assert len(upload_server.peer.assignments) == 1
    assert not list(upload_server.staging.glob("*.photo"))
    assert len(list(upload_server.staging.glob("*.receipt.json"))) == 1


async def test_duplicate_concurrent_chunks_conflict_outoforder_and_safe_base64(upload_server):
    data = b"a" * CHUNK + b"tail"
    handle = (await upload_server.start(data))["uploadHandle"]
    results = []

    async def append():
        results.append(successful(await upload_server.chunk(handle, 0, data[:CHUNK])))

    async with anyio.create_task_group() as group:
        group.start_soon(append)
        group.start_soon(append)
    assert results[0] == results[1]
    before = await upload_server.status(handle)
    for number, chunk, code in (
        (0, b"b" * CHUNK, "conflicting-chunk"),
        (2, b"tail", "unexpected-chunk-number"),
        (-1, b"tail", "unexpected-chunk-number"),
        (1, b"tail!", "invalid-chunk-length"),
        (1, b"a" * (CHUNK + 1), "invalid-chunk-length"),
    ):
        result = await upload_server.chunk(handle, number, chunk)
        rejected(result, code)
        assert await upload_server.status(handle) == before
    for encoded in ("not-base64!", "Y Q==", "YR==", "", "====", "YQ"):
        result = await upload_server.call("image_upload_chunk", {
            "uploadHandle": handle, "chunkNumber": 1, "base64": encoded,
        })
        assert result.get("isError"), encoded
        assert encoded not in result["content"][0]["text"] or encoded == ""
        assert await upload_server.status(handle) == before
    successful(await upload_server.chunk(handle, 1, b"tail"))
    assert (await upload_server.finish(handle))["state"] == "finished"
    assert upload_server.peer.assignments[0][1] == data


async def test_nonfinal_short_chunk_and_declared_total_overflow_are_unchanged(upload_server):
    handle = (await upload_server.start(b"a" * CHUNK + b"tail"))["uploadHandle"]
    before = await upload_server.status(handle)
    rejected(await upload_server.chunk(handle, 0, b"short"), "invalid-chunk-length")
    assert await upload_server.status(handle) == before
    successful(await upload_server.chunk(handle, 0, b"a" * CHUNK))
    successful(await upload_server.chunk(handle, 1, b"tail"))
    before = await upload_server.status(handle)
    rejected(await upload_server.chunk(handle, 2, b"overflow"), "invalid-chunk-length")
    assert await upload_server.status(handle) == before
    assert not upload_server.peer.assignments


@pytest.mark.parametrize("field,value,code", [
    ("byteLength", 0, "invalid-byte-length"),
    ("byteLength", -1, "invalid-byte-length"),
    ("byteLength", FILE + 1, "invalid-byte-length"),
    ("sha256", "xyz", "invalid-sha256"),
    ("mediaType", "text/plain", "invalid-media-type"),
    ("mediaType", "image/*", "invalid-media-type"),
    ("mediaType", "image/jpeg; charset=utf8", "invalid-media-type"),
])
async def test_start_invalid_inputs_do_not_allocate(upload_server, field, value, code):
    args = {"recipeId": "r", "byteLength": 1, "mediaType": "image/jpeg", "sha256": "0" * 64}
    args[field] = value
    rejected(await upload_server.call("image_upload_start", args), code)
    assert list(upload_server.staging.iterdir()) == []
    assert not upload_server.peer.assignments


async def test_exact_file_and_total_capacity_concurrent_reservations_without_eviction(upload_server):
    results = []

    async def reserve():
        results.append(await upload_server.call("image_upload_start", {
            "recipeId": "r", "byteLength": FILE,
            "mediaType": "image/jpeg", "sha256": "0" * 64,
        }))

    async with anyio.create_task_group() as group:
        for _ in range(CAPACITY // FILE + 1):
            group.start_soon(reserve)
    accepted = [successful(result) for result in results if not result.get("isError")]
    assert len(accepted) == 20, [result for result in results if result.get("isError")]
    assert len({item["uploadHandle"] for item in accepted}) == 20
    assert sum(FILE for _ in accepted) == CAPACITY
    rejected(next(result for result in results if result.get("isError")), "upload-capacity-exceeded")
    for item in accepted:
        assert await upload_server.status(item["uploadHandle"]) == item
    assert len(list(upload_server.staging.glob("*.photo"))) == 20


async def test_success_releases_only_declared_reservation_and_receipts_have_no_count_limit(upload_server):
    for _ in range(24):
        handle = await complete(upload_server, b"a")
        assert (await upload_server.finish(handle))["state"] == "finished"
    assert len(list(upload_server.staging.glob("*.receipt.json"))) == 24
    for _ in range(20):
        await upload_server.start(b"", byteLength=FILE)
    rejected(await upload_server.call("image_upload_start", {
        "recipeId": "r", "byteLength": 1, "mediaType": "image/jpeg", "sha256": "0" * 64,
    }), "upload-capacity-exceeded")


async def test_exact_file_limit_assembles_twenty_full_chunks(upload_server):
    data = bytes(range(256)) * (FILE // 256)
    handle = await complete(upload_server, data)
    status = await upload_server.status(handle)
    assert status["receivedBytes"] == FILE
    assert status["nextChunkNumber"] == 20
    finished = await upload_server.finish(handle)
    assert finished["state"] == "finished"
    assert finished["source"]["byteLength"] == FILE
    assert upload_server.peer.assignments[0][1] == data


async def test_capacity_one_byte_boundary_and_exact_successful_release(upload_server):
    data = b"a" * FILE
    handle = await complete(upload_server, data)
    for _ in range(18):
        await upload_server.start(b"", byteLength=FILE)
    await upload_server.start(b"", byteLength=FILE - 1)
    last = await upload_server.start(b"a")
    assert last["state"] == "receiving"
    rejected(await upload_server.call("image_upload_start", {
        "recipeId": "r", "byteLength": 1, "mediaType": "image/jpeg", "sha256": "0" * 64,
    }), "upload-capacity-exceeded")
    assert (await upload_server.status(handle))["receivedBytes"] == FILE
    assert (await upload_server.finish(handle))["state"] == "finished"
    assert not (upload_server.staging / (handle + ".photo")).exists()
    await upload_server.start(b"", byteLength=FILE)
    rejected(await upload_server.call("image_upload_start", {
        "recipeId": "r", "byteLength": 1, "mediaType": "image/jpeg", "sha256": "0" * 64,
    }), "upload-capacity-exceeded")
    assert (await upload_server.status(last["uploadHandle"]))["state"] == "receiving"
    assert len(upload_server.peer.assignments) == 1


async def test_http_input_is_bounded_before_upstream_or_staging(upload_server):
    async with httpx.AsyncClient() as client:
        response = await client.post(upload_server.url, headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }, content=b"x" * (524288 + 1))
    assert response.status_code == 413
    assert not upload_server.peer.requests
    assert list(upload_server.staging.iterdir()) == []


async def test_concurrent_independent_uploads_do_not_mix_bytes(upload_server):
    results = []

    async def upload(data):
        handle = await complete(upload_server, data)
        results.append((handle, await upload_server.finish(handle)))

    files = [b"a" * CHUNK + b"alpha", b"b" * CHUNK + b"beta"]
    async with anyio.create_task_group() as group:
        for data in files:
            group.start_soon(upload, data)
    assert len({handle for handle, _ in results}) == 2
    assert all(result["state"] == "finished" for _, result in results)
    assert {item[1] for item in upload_server.peer.assignments} == set(files)


async def test_integrity_and_incomplete_fail_before_mutation(upload_server):
    handle = (await upload_server.start(b"original"))["uploadHandle"]
    rejected(await upload_server.call("image_upload_finish", {"uploadHandle": handle}), "upload-incomplete")
    assert (await upload_server.status(handle))["state"] == "receiving"
    successful(await upload_server.chunk(handle, 0, b"changed!"))
    failed = await upload_server.finish(handle)
    assert failed["state"] == "failed"
    assert failed["error"]["code"] == "upload-integrity-failed"
    assert await upload_server.finish(handle) == failed
    assert not upload_server.peer.assignments


@pytest.mark.parametrize("permission,code", [
    (False, "image-permission-denied"),
    ("unavailable", "image-permission-unavailable"),
    ("invalid", "invalid-credentials"),
    ("null", "image-permission-unavailable"),
    ("missing", "image-permission-unavailable"),
    ("error", "capability-check-failed"),
])
async def test_every_tool_permission_failure_leaves_bytes_and_state_unchanged(upload_server, permission, code):
    data = b"x" * CHUNK + b"tail"
    handle = (await upload_server.start(data))["uploadHandle"]
    successful(await upload_server.chunk(handle, 0, data[:CHUNK]))
    before = await upload_server.status(handle)
    photo = next(upload_server.staging.glob("*.photo"))
    original = photo.read_bytes()
    upload_server.peer.permissions[" ".join(("Bearer", "restricted"))] = permission
    for name, args in (
        ("image_upload_start", {"recipeId": "r", "byteLength": 1, "mediaType": "image/jpeg", "sha256": "0" * 64}),
        ("image_upload_chunk", {"uploadHandle": handle, "chunkNumber": 1, "base64": base64.b64encode(b"tail").decode()}),
        ("image_upload_finish", {"uploadHandle": handle}),
        ("image_upload_status", {"uploadHandle": handle}),
    ):
        rejected(await upload_server.call(name, args, "restricted"), code)
        assert await upload_server.status(handle) == before
        assert photo.read_bytes() == original
        assert len(list(upload_server.staging.glob("*.photo"))) == 1
        assert not upload_server.peer.assignments


@pytest.mark.parametrize("tool", ["image_upload_finish", "image_upload_status"])
async def test_finished_receipts_still_require_current_permission(upload_server, tool):
    handle = await complete(upload_server, b"finished original")
    finished = await upload_server.finish(handle)
    assert finished["state"] == "finished"
    receipt = (upload_server.staging / (handle + ".receipt.json")).read_bytes()
    upload_server.peer.permissions[" ".join(("Bearer", "restricted"))] = False
    rejected(await upload_server.call(tool, {"uploadHandle": handle}, "restricted"), "image-permission-denied")
    assert await upload_server.status(handle) == finished
    assert await upload_server.finish(handle) == finished
    assert (upload_server.staging / (handle + ".receipt.json")).read_bytes() == receipt
    assert not list(upload_server.staging.glob("*.photo"))
    assert len(upload_server.peer.assignments) == 1


@pytest.mark.parametrize("tool", sorted(TOOLS - {"image_upload_start"}))
async def test_unknown_handles_fail_explicitly(upload_server, tool):
    args = {"uploadHandle": "unknown"}
    if tool == "image_upload_chunk":
        args.update(chunkNumber=0, base64="YQ==")
    rejected(await upload_server.call(tool, args), "unknown-upload-handle")


@pytest.mark.parametrize("outcome,state", [
    ("disconnect", "uncertain"), ("rejected", "failed"), ("unknown", "uncertain"),
    ("http500", "uncertain"), ("malformed", "uncertain"),
])
async def test_attempted_assignment_never_replays_transport_or_rejection(upload_server, outcome, state):
    handle = await complete(upload_server, b"image content")
    upload_server.peer.outcome = outcome
    result = await upload_server.finish(handle)
    assert result["state"] == state
    assert await upload_server.status(handle) == result
    for _ in range(3):
        assert await upload_server.finish(handle) == result
    assert len(upload_server.peer.assignments) == 1
    assert len(list(upload_server.staging.glob("*.photo"))) == 1
    if state == "failed":
        assert result["error"] == {
            "code": "unsupported-image", "message": "Actual image content was rejected",
            "field": "file", "status": 415,
        }
    else:
        assert result["recovery"]
        if outcome == "unknown":
            assert result["error"]["code"] == "image-assignment-unknown"
            assert result["error"]["status"] == 502


@pytest.mark.parametrize("outcome", ["disconnect", "rejected", "unknown", "http500", "malformed"])
async def test_failed_and_uncertain_reservations_are_not_reclaimed(upload_server, outcome):
    handle = await complete(upload_server, b"a" * FILE)
    upload_server.peer.outcome = outcome
    assert (await upload_server.finish(handle))["state"] in ("failed", "uncertain")
    for _ in range(19):
        await upload_server.start(b"", byteLength=FILE)
    rejected(await upload_server.call("image_upload_start", {
        "recipeId": "r", "byteLength": 1, "mediaType": "image/jpeg", "sha256": "0" * 64,
    }), "upload-capacity-exceeded")
    assert (await upload_server.status(handle))["receivedBytes"] == FILE
    assert (upload_server.staging / (handle + ".photo")).stat().st_size == FILE


async def test_assigning_status_and_concurrent_finish_are_nonreplaying(upload_server):
    handle = await complete(upload_server, b"one assignment")
    upload_server.peer.outcome = "delay"
    completed = []

    async def finish():
        completed.append(await upload_server.finish(handle))

    async with anyio.create_task_group() as group:
        group.start_soon(finish)
        with anyio.fail_after(10):
            while not upload_server.peer.entered.is_set():
                await anyio.sleep(0.05)
        assert (await upload_server.status(handle))["state"] == "assigning"
        assert (await upload_server.finish(handle))["state"] == "assigning"
        assert len(upload_server.peer.assignments) == 1
        upload_server.peer.release.set()
    assert completed[0]["state"] == "finished"
    assert await upload_server.finish(handle) == completed[0]
    assert len(upload_server.peer.assignments) == 1


@pytest.mark.parametrize("fault,code", [
    ("receipt", "receipt-save-failed"),
    ("deletion", "staging-delete-failed"),
])
async def test_filesystem_faults_never_replay_or_release_reserved_photo_bytes(upload_server, fault, code):
    data = b"a" * FILE
    handle = await complete(upload_server, data)
    upload_server.peer.outcome = "delay"
    results = []

    async def finish():
        results.append(await upload_server.finish(handle))

    async with anyio.create_task_group() as group:
        group.start_soon(finish)
        with anyio.fail_after(10):
            while not upload_server.peer.entered.is_set():
                await anyio.sleep(0.05)
        if fault == "receipt":
            (upload_server.staging / (handle + ".receipt.pending")).mkdir()
        else:
            photo = upload_server.staging / (handle + ".photo")
            photo.rename(upload_server.staging / (handle + ".retained-photo"))
            photo.mkdir()
        upload_server.peer.release.set()
    failed = results[0]
    assert failed["state"] == "failed"
    assert failed["error"]["code"] == code
    assert await upload_server.status(handle) == failed
    assert await upload_server.finish(handle) == failed
    assert len(upload_server.peer.assignments) == 1
    for _ in range(19):
        await upload_server.start(b"", byteLength=FILE)
    rejected(await upload_server.call("image_upload_start", {
        "recipeId": "r", "byteLength": 1, "mediaType": "image/jpeg", "sha256": "0" * 64,
    }), "upload-capacity-exceeded")
    if fault == "deletion":
        assert (upload_server.staging / (handle + ".retained-photo")).read_bytes() == data
        assert len(list(upload_server.staging.glob("*.receipt.json"))) == 1
    else:
        assert (upload_server.staging / (handle + ".photo")).read_bytes() == data
        assert not list(upload_server.staging.glob("*.receipt.json"))


@pytest.mark.parametrize("mode,enabled", [
    ("production", True), ("testing", False), ("backup", True),
])
async def test_upload_discovery_is_disabled_outside_explicit_isolated_gate(mode, enabled):
    root = Path("target") / ("gate-" + uuid.uuid4().hex)
    root.mkdir(parents=True)
    try:
        with disposable_server(root.resolve(), mode, enabled) as server:
            tools = {tool["name"] for tool in (await server.rpc("tools/list", {}))["tools"]}
            assert not TOOLS & tools
            assert "get_recipe_schema" in tools
            assert server.peer.requests == []
    finally:
        shutil.rmtree(root)
