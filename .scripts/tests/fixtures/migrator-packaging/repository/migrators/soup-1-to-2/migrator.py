import json
import os
import tempfile
from pathlib import Path


DATA = Path("/data")
VERSION = DATA / "storage-version"
RECIPE = DATA / "recipe.json"


def atomic_write(path, contents):
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, delete=False
    ) as temporary:
        temporary.write(contents)
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, path)


def main():
    if VERSION.read_text(encoding="utf-8") != "1\n":
        raise ValueError("expected storage version 1")
    recipe = json.loads(RECIPE.read_text(encoding="utf-8"))
    if set(recipe) != {"id", "name"} or not all(
        isinstance(recipe[key], str) and recipe[key] for key in ("id", "name")
    ):
        raise ValueError("invalid version-1 recipe")

    converted = {"id": recipe["id"], "title": recipe["name"]}
    if set(converted) != {"id", "title"} or any(
        not isinstance(value, str) or not value for value in converted.values()
    ):
        raise ValueError("invalid version-2 recipe")
    atomic_write(RECIPE, json.dumps(converted, separators=(",", ":")) + "\n")
    atomic_write(VERSION, "2\n")


if __name__ == "__main__":
    main()
