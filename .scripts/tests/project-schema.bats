#!/usr/bin/env bats

load test_helper

@test "project schema requires authoritative storage versions and rejects invalid versions" {
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
assert "storageVersion" in required
forbidden = set(rule["else"]["not"]["required"])
assert "storageVersion" in forbidden
version = schema["properties"]["storageVersion"]
assert version["type"] == "integer"
assert version["minimum"] == 1


def valid(project):
    if "integration" in project and (
        project.get("category") != "test" or not isinstance(project["integration"], str)
    ):
        return False
    owns_data = project.get("backupRole") in data_roles
    if owns_data and not required <= project.keys():
        return False
    if not owns_data and forbidden & project.keys():
        return False
    if "storageVersion" in project:
        value = project["storageVersion"]
        if type(value) is not int or value < version["minimum"]:
            return False
    return True


for role in data_roles:
    declaration = {"backupRole": role, "storageVersion": 1}
    assert valid(declaration)
    for invalid_storage in [0, -1, 1.5, "1", True, None]:
        assert not valid(declaration | {"storageVersion": invalid_storage})
    assert not valid({"backupRole": role})

assert valid({"backupRole": "derived-stateless"})
assert valid({"backupRole": "excluded-external-cache"})
assert valid({})
assert not valid({"backupRole": "derived-stateless", "storageVersion": 1})
assert not valid({"backupRole": "excluded-external-cache", "storageVersion": 1})
assert not valid({"storageVersion": 1})

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
