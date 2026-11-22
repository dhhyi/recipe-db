#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path


SYNTHETIC_DEPENDENCIES = {"nats"}


class MetadataError(ValueError):
    pass


def load_metadata(path, schema_path):
    schema = json.loads(Path(schema_path).read_text())
    categories = schema["properties"]["category"]["enum"]
    projects = {}

    for line_number, line in enumerate(Path(path).read_text().splitlines(), start=1):
        if not line.strip():
            continue
        try:
            project = json.loads(line)
        except json.JSONDecodeError as error:
            raise MetadataError(f"{path}:{line_number}: invalid project JSON: {error}") from error
        if not isinstance(project, dict):
            raise MetadataError(f"{path}:{line_number}: project metadata must be an object")

        name = project.get("name")
        if not isinstance(name, str) or not name:
            raise MetadataError(f"{path}:{line_number}: project name must be a non-empty string")
        if name in projects:
            raise MetadataError(f"duplicate project name: {name}")

        category = project.get("category")
        if category is not None and (
            not isinstance(category, str) or category not in categories
        ):
            raise MetadataError(f"project {name} has unknown category: {category}")
        declarations = project.get("integrationDependencies", [])
        if not isinstance(declarations, list):
            raise MetadataError(f"project {name} integrationDependencies must be an array")
        if any(not isinstance(item, str) or not item for item in declarations):
            raise MetadataError(
                f"project {name} integrationDependencies must contain non-empty names"
            )
        if len(set(declarations)) != len(declarations):
            raise MetadataError(f"project {name} integrationDependencies contains duplicates")
        projects[name] = {
            "category": category,
            "integrationDependencies": declarations,
        }

    collisions = (set(projects) & set(categories)) | (set(projects) & SYNTHETIC_DEPENDENCIES)
    if collisions:
        raise MetadataError(
            "project names collide with category or synthetic dependencies: "
            + ", ".join(sorted(collisions))
        )
    collisions = set(categories) & SYNTHETIC_DEPENDENCIES
    if collisions:
        raise MetadataError(
            "category names collide with synthetic dependencies: " + ", ".join(sorted(collisions))
        )

    valid_names = set(projects) | set(categories) | SYNTHETIC_DEPENDENCIES
    for name, project in projects.items():
        for dependency in project["integrationDependencies"]:
            if dependency not in valid_names:
                raise MetadataError(
                    f"project {name} declares unknown integration dependency: {dependency}"
                )

    return categories, projects


def resolve(start_names, categories, projects):
    visited = set()
    reached_projects = set()
    reached_synthetic = set()

    def visit(name):
        if name in visited:
            return
        visited.add(name)

        if name in SYNTHETIC_DEPENDENCIES:
            reached_synthetic.add(name)
            return
        if name in categories:
            matching_projects = sorted(
                project_name
                for project_name, project in projects.items()
                if project["category"] == name
            )
            for project_name in matching_projects:
                visit(project_name)
            return

        project = projects[name]
        reached_projects.add(name)
        for dependency in sorted(project["integrationDependencies"]):
            visit(dependency)

    for name in sorted(start_names):
        visit(name)

    return {
        "projects": sorted(reached_projects),
        "synthetic": sorted(reached_synthetic),
    }


def graph(path, schema_path):
    categories, projects = load_metadata(path, schema_path)
    resolved = {
        name: resolve(project["integrationDependencies"], categories, projects)
        for name, project in sorted(projects.items())
    }
    return {
        "categories": sorted(categories),
        "projects": projects,
        "resolved": resolved,
    }


def main():
    parser = argparse.ArgumentParser(description="Resolve integration image dependencies.")
    parser.add_argument("--metadata", required=True, help="JSONL project metadata.")
    parser.add_argument(
        "--schema", default=".scripts/project-schema.json", help="Project metadata JSON Schema."
    )
    args = parser.parse_args()

    try:
        result = graph(args.metadata, args.schema)
    except (OSError, json.JSONDecodeError, KeyError, MetadataError) as error:
        print(f"Invalid integration dependency graph: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
