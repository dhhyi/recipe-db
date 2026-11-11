#!/usr/bin/env bats

load test_helper

@test "project schema requires authoritative storage declarations and rejects invalid versions" {
  run python3 - << 'PY'
import json
import re
from pathlib import Path

schema = json.loads(Path(".scripts/project-schema.json").read_text())

data_roles = ["authoritative-read-only", "cleanup-participant"]
rule = next(
    item for item in schema["allOf"]
    if item.get("if", {}).get("properties", {}).get("backupRole", {}).get("enum")
)
assert rule["if"]["properties"]["backupRole"]["enum"] == data_roles
required = set(rule["then"]["required"])
assert {"backupData", "storageVersion"} <= required
forbidden = set(rule["else"]["not"]["required"])
assert "storageVersion" in forbidden
version = schema["properties"]["storageVersion"]
assert version["type"] == "object"
assert set(version["required"]) == {"value", "file", "template"}
assert version["properties"]["value"]["type"] == "integer"
assert version["properties"]["value"]["minimum"] == 1


def valid(project):
    owns_data = project.get("backupRole") in data_roles
    if owns_data and not required <= project.keys():
        return False
    if owns_data and not isinstance(project["backupData"], dict):
        return False
    if not owns_data and forbidden & project.keys():
        return False
    if "storageVersion" in project:
        declaration = project["storageVersion"]
        if not isinstance(declaration, dict) or set(declaration) != {"value", "file", "template"}:
            return False
        value = declaration["value"]
        if type(value) is not int or value < version["properties"]["value"]["minimum"]:
            return False
        if not isinstance(declaration["file"], str) or not re.fullmatch(
            r"[A-Za-z0-9._/-]+", declaration["file"]
        ):
            return False
        if any(part in {"", ".", ".."} for part in declaration["file"].split("/")):
            return False
        if declaration["file"].startswith("/") or "//" in declaration["file"] or declaration["file"].endswith("/"):
            return False
        if not isinstance(declaration["template"], str) or declaration["template"].count(
            "{{STORAGE_VERSION}}"
        ) != 1:
            return False
    return True


for role in data_roles:
    storage = {
        "value": 1,
        "file": "src/storage_version_generated.ml",
        "template": "let value = {{STORAGE_VERSION}}",
    }
    declaration = {"backupRole": role, "backupData": {"kind": "json"}, "storageVersion": storage}
    assert valid(declaration)
    for invalid_storage in [
        storage | {"value": 0},
        storage | {"value": -1},
        storage | {"value": 1.5},
        storage | {"value": "1"},
        storage | {"value": True},
        storage | {"value": None},
        storage | {"file": "../escape.ml"},
        storage | {"file": "/absolute.ml"},
        storage | {"file": "src//generated.ml"},
        storage | {"template": "let value = 1"},
        storage | {"template": "{{STORAGE_VERSION}} {{STORAGE_VERSION}}"},
    ]:
        assert not valid(declaration | {"storageVersion": invalid_storage})
    assert not valid(declaration | {"backupData": None})
    assert not valid({"backupRole": role, "backupData": {"kind": "json"}})
    assert not valid({"backupRole": role, "storageVersion": storage})

assert valid({"backupRole": "derived-stateless"})
assert valid({"backupRole": "excluded-external-cache"})
assert valid({})
assert not valid({"backupRole": "derived-stateless", "storageVersion": storage})
assert not valid({"backupRole": "excluded-external-cache", "storageVersion": storage})
assert not valid({"storageVersion": storage})
PY
  [ "$status" -eq 0 ]
}
