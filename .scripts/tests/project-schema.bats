#!/usr/bin/env bats

load test_helper

@test "project schema requires authoritative storage declarations and rejects invalid versions" {
  run python3 - << 'PY'
import json
from pathlib import Path

schema = json.loads(Path(".scripts/project-schema.json").read_text())
integration_rule = next(
    item for item in schema["allOf"]
    if item.get("if", {}).get("required") == ["integration"]
)
assert integration_rule["then"]["properties"]["category"]["const"] == "test"
integration_categories = schema["properties"]["category"]["enum"]

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
assert set(version["required"]) == {"value"}
assert version["properties"]["value"]["type"] == "integer"
assert version["properties"]["value"]["minimum"] == 1


def valid(project):
    if "integration" in project and (
        project.get("category") != "test" or not isinstance(project["integration"], str)
    ):
        return False
    owns_data = project.get("backupRole") in data_roles
    if owns_data and not required <= project.keys():
        return False
    if owns_data and not isinstance(project["backupData"], dict):
        return False
    if not owns_data and forbidden & project.keys():
        return False
    if "storageVersion" in project:
        declaration = project["storageVersion"]
        if not isinstance(declaration, dict) or set(declaration) != {"value"}:
            return False
        value = declaration["value"]
        if type(value) is not int or value < version["properties"]["value"]["minimum"]:
            return False
    return True


for role in data_roles:
    storage = {"value": 1}
    declaration = {"backupRole": role, "backupData": {"kind": "json"}, "storageVersion": storage}
    assert valid(declaration)
    for invalid_storage in [
        storage | {"value": 0},
        storage | {"value": -1},
        storage | {"value": 1.5},
        storage | {"value": "1"},
        storage | {"value": True},
        storage | {"value": None},
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

assert schema["properties"]["check"]["type"] == "string"
assert schema["properties"]["test"]["type"] == "string"
assert schema["properties"]["integration"]["type"] == "string"
assert "minLength" not in schema["properties"]["integration"]
assert valid({"category": "test"})
assert valid({"category": "test", "integration": ""})
for category in integration_categories:
    project = {"category": category, "integration": "echo tests"}
    assert valid(project) == (category == "test")
PY
  [ "$status" -eq 0 ]
}
