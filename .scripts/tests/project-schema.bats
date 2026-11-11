#!/usr/bin/env bats

load test_helper

@test "project schema requires authoritative storage declarations and rejects invalid versions" {
  run python3 - << 'PY'
import json
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
assert version["type"] == "integer" and version["minimum"] == 1


def valid(project):
    owns_data = project.get("backupRole") in data_roles
    if owns_data and not required <= project.keys():
        return False
    if owns_data and not isinstance(project["backupData"], dict):
        return False
    if not owns_data and forbidden & project.keys():
        return False
    if "storageVersion" in project:
        value = project["storageVersion"]
        if type(value) is not int or value < version["minimum"]:
            return False
    return True


for role in data_roles:
    declaration = {"backupRole": role, "backupData": {"kind": "json"}, "storageVersion": 1}
    assert valid(declaration)
    assert not valid(declaration | {"storageVersion": 0})
    assert not valid(declaration | {"storageVersion": -1})
    assert not valid(declaration | {"storageVersion": 1.5})
    assert not valid(declaration | {"storageVersion": "1"})
    assert not valid(declaration | {"storageVersion": True})
    assert not valid(declaration | {"storageVersion": None})
    assert not valid(declaration | {"storageVersion": 1} | {"backupData": None})
    assert not valid({"backupRole": role, "backupData": {"kind": "json"}})
    assert not valid({"backupRole": role, "storageVersion": 1})

assert valid({"backupRole": "derived-stateless"})
assert valid({"backupRole": "excluded-external-cache"})
assert valid({})
assert not valid({"backupRole": "derived-stateless", "storageVersion": 1})
assert not valid({"backupRole": "excluded-external-cache", "storageVersion": 1})
assert not valid({"storageVersion": 1})
PY
  [ "$status" -eq 0 ]
}
