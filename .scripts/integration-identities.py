#!/usr/bin/env python3
import argparse
import http.client
import json
import re
import socket
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote


DIGEST_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
MANIFEST_TYPES = {
    "application/vnd.docker.distribution.manifest.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
}
INDEX_TYPES = {
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.index.v1+json",
}


class PreparationError(ValueError):
    pass


def read_json(path, description):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise PreparationError(f"cannot read {description} {path}: {error}") from error


def checked_digest(value, description):
    if not isinstance(value, str) or not DIGEST_PATTERN.fullmatch(value):
        raise PreparationError(f"missing or invalid {description}: {value!r}")
    return value


def run_docker(arguments):
    try:
        result = subprocess.run(
            ["docker", *arguments], capture_output=True, check=False, text=True
        )
    except OSError as error:
        raise PreparationError(f"cannot run docker {' '.join(arguments)}: {error}") from error
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise PreparationError(
            f"docker {' '.join(arguments)} failed"
            + (f": {detail}" if detail else "")
        )
    return result.stdout


def platform_parts(platform):
    parts = platform.split("/")
    if len(parts) not in (2, 3) or not all(parts):
        raise PreparationError(f"invalid selected platform: {platform!r}")
    return parts[0], parts[1], parts[2] if len(parts) == 3 else None


def normalized_architecture(value):
    return {"aarch64": "arm64", "x86_64": "amd64"}.get(value, value)


def inspect_image(image, platform, docker=run_docker):
    output = docker(["image", "inspect", image])
    try:
        images = json.loads(output)
    except json.JSONDecodeError as error:
        raise PreparationError(f"invalid Docker image inspection for {image}: {error}") from error
    if not isinstance(images, list) or len(images) != 1 or not isinstance(images[0], dict):
        raise PreparationError(f"image is missing or ambiguous in Docker: {image}")

    details = images[0]
    wanted_os, wanted_arch, wanted_variant = platform_parts(platform)
    actual_os = details.get("Os")
    actual_arch = normalized_architecture(details.get("Architecture", ""))
    actual_variant = details.get("Variant") or None
    if (actual_os, actual_arch) != (wanted_os, wanted_arch) or (
        wanted_variant and actual_variant != wanted_variant
    ):
        actual = "/".join(part for part in (actual_os, actual_arch, actual_variant) if part)
        raise PreparationError(
            f"prepared image {image} uses {actual}, expected selected platform {platform}"
        )
    return details


def inspect_local_index(image):
    client, daemon = socket.socketpair()
    try:
        # Use the Docker CLI's active context rather than assuming a local socket.
        with subprocess.Popen(
            ["docker", "system", "dial-stdio"],
            stdin=daemon,
            stdout=daemon,
            stderr=subprocess.PIPE,
        ) as process:
            daemon.close()
            try:
                client.settimeout(30)
                path = quote(image, safe="")
                client.sendall(
                    f"GET /v1.48/images/{path}/json?manifests=true HTTP/1.1\r\n"
                    "Host: localhost\r\nConnection: close\r\n\r\n".encode()
                )
                response = http.client.HTTPResponse(client)
                response.begin()
                body = response.read()
                if response.status != 200:
                    raise PreparationError(
                        f"Docker image manifest inspection failed for {image}: "
                        f"HTTP {response.status}: {body.decode(errors='replace')}"
                    )
                try:
                    return json.loads(body)
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise PreparationError(
                        f"invalid Docker image manifest inspection for {image}: {error}"
                    ) from error
            finally:
                client.close()
    except (OSError, http.client.HTTPException) as error:
        raise PreparationError(f"cannot inspect local image manifests for {image}: {error}") from error
    finally:
        client.close()
        daemon.close()


def selected_local_manifest(image, index_digest, platform, local_index):
    local = local_index(image)
    descriptor = local.get("Descriptor") if isinstance(local, dict) else None
    if not isinstance(descriptor, dict) or descriptor.get("digest") != index_digest:
        raise PreparationError(f"prepared image {image} no longer matches its image index")
    os_name, architecture, variant = platform_parts(platform)
    manifests = local.get("Manifests")
    if not isinstance(manifests, list):
        raise PreparationError(f"local image manifests are missing for {image}")
    candidates = []
    for manifest in manifests:
        if not isinstance(manifest, dict) or manifest.get("Kind") != "image":
            continue
        entry = manifest.get("Descriptor")
        image_data = manifest.get("ImageData")
        entry_platform = image_data.get("Platform") if isinstance(image_data, dict) else None
        if not isinstance(entry, dict) or not isinstance(entry_platform, dict):
            continue
        if (
            entry_platform.get("os") == os_name
            and normalized_architecture(entry_platform.get("architecture", "")) == architecture
            and (variant is None or entry_platform.get("variant") == variant)
        ):
            candidates.append(manifest)
    if len(candidates) != 1:
        reason = "missing" if not candidates else "ambiguous"
        raise PreparationError(f"{reason} runnable image manifest for {image} on {platform}")
    selected = candidates[0]
    descriptor = selected["Descriptor"]
    if not selected.get("Available") or descriptor.get("mediaType") not in MANIFEST_TYPES:
        raise PreparationError(f"selected image manifest is not available for {image}")
    return checked_digest(descriptor.get("digest"), f"selected manifest digest for {image}")


def project_image_identity(
    project, services, build_metadata, platform, docker=run_docker,
    local_index=inspect_local_index,
):
    service = services.get(project)
    image = service.get("image") if isinstance(service, dict) else None
    if not isinstance(image, str) or not image:
        raise PreparationError(f"required Compose service image is missing: {project}")

    result = build_metadata.get(project)
    if not isinstance(result, dict):
        raise PreparationError(f"build metadata is missing for required image: {project}")
    digest = checked_digest(result.get("containerimage.digest"), f"manifest digest for {project}")
    descriptor = result.get("containerimage.descriptor")
    if not isinstance(descriptor, dict):
        raise PreparationError(f"runnable manifest descriptor is missing for required image: {project}")
    media_type = descriptor.get("mediaType")
    if media_type not in MANIFEST_TYPES | INDEX_TYPES:
        raise PreparationError(
            f"build metadata for {project} is not a runnable image manifest: {media_type!r}"
        )
    descriptor_digest = checked_digest(
        descriptor.get("digest"), f"descriptor digest for {project}"
    )
    if digest != descriptor_digest:
        raise PreparationError(f"ambiguous manifest digest in build metadata for {project}")

    details = inspect_image(image, platform, docker)
    if media_type in INDEX_TYPES:
        local_descriptor = details.get("Descriptor")
        if isinstance(local_descriptor, dict) and local_descriptor.get("digest") != digest:
            raise PreparationError(
                f"prepared image {project} no longer matches the image used for its identity"
            )
        return selected_local_manifest(image, digest, platform, local_index)

    local_descriptor = details.get("Descriptor")
    if isinstance(local_descriptor, dict):
        if (
            local_descriptor.get("mediaType") in MANIFEST_TYPES
            and local_descriptor.get("digest") == digest
        ):
            return digest
        raise PreparationError(
            f"prepared image {project} no longer matches the image used for its identity"
        )
    config_digest = checked_digest(
        result.get("containerimage.config.digest"), f"config digest for {project}"
    )
    if details.get("Id") != config_digest:
        raise PreparationError(
            f"prepared image {project} no longer matches the image used for its identity"
        )
    return digest


def raw_registry_manifest(image, docker):
    output = docker(["buildx", "imagetools", "inspect", "--raw", image])
    try:
        manifest = json.loads(output)
    except json.JSONDecodeError as error:
        raise PreparationError(f"invalid registry manifest for {image}: {error}") from error
    if not isinstance(manifest, dict):
        raise PreparationError(f"invalid registry manifest for {image}")
    return manifest


def nats_image_identity(image, platform, docker=run_docker, local_index=inspect_local_index):
    if "@" not in image:
        raise PreparationError(f"NATS image must be pinned by digest: {image}")
    pinned_digest = checked_digest(image.rsplit("@", 1)[1], "pinned NATS image digest")
    details = inspect_image(image, platform, docker)
    repository_digests = details.get("RepoDigests") or []
    if not any(
        isinstance(repository_digest, str)
        and repository_digest.rsplit("@", 1)[-1] == pinned_digest
        for repository_digest in repository_digests
    ):
        raise PreparationError(f"prepared NATS image does not match its pinned digest: {image}")

    root = raw_registry_manifest(image, docker)
    manifests = root.get("manifests")
    if manifests is None:
        if root.get("mediaType") not in MANIFEST_TYPES:
            raise PreparationError(
                f"NATS registry reference is not a runnable image manifest: {image}"
            )
        selected_digest = pinned_digest
        selected_manifest = root
    else:
        os_name, architecture, variant = platform_parts(platform)
        candidates = []
        if isinstance(manifests, list):
            for entry in manifests:
                entry_platform = entry.get("platform") if isinstance(entry, dict) else None
                if not isinstance(entry_platform, dict):
                    continue
                if (
                    entry_platform.get("os") == os_name
                    and normalized_architecture(entry_platform.get("architecture", ""))
                    == architecture
                    and (variant is None or entry_platform.get("variant") == variant)
                ):
                    candidates.append(entry)
        if len(candidates) != 1:
            reason = "missing" if not candidates else "ambiguous"
            raise PreparationError(
                f"{reason} runnable NATS manifest for selected platform {platform}: {image}"
            )
        selected = candidates[0]
        selected_digest = checked_digest(selected.get("digest"), "selected NATS manifest digest")
        if selected.get("mediaType") not in MANIFEST_TYPES:
            raise PreparationError(
                f"selected NATS image descriptor is not runnable: {selected.get('mediaType')!r}"
            )
        repository = image.rsplit("@", 1)[0]
        selected_manifest = raw_registry_manifest(
            f"{repository}@{selected_digest}", docker
        )

    if selected_manifest.get("mediaType") not in MANIFEST_TYPES:
        raise PreparationError(f"selected NATS image is not a runnable manifest: {image}")
    config_digest = checked_digest(
        selected_manifest.get("config", {}).get("digest"), "selected NATS config digest"
    )
    local_descriptor = details.get("Descriptor")
    if isinstance(local_descriptor, dict):
        matches = (
            local_descriptor.get("mediaType") in MANIFEST_TYPES
            and local_descriptor.get("digest") == selected_digest
        )
        if (
            not matches
            and local_descriptor.get("mediaType") in INDEX_TYPES
            and local_descriptor.get("digest") == pinned_digest
        ):
            matches = (
                selected_local_manifest(image, pinned_digest, platform, local_index)
                == selected_digest
            )
    else:
        matches = details.get("Id") == config_digest
    if not matches:
        raise PreparationError(
            f"prepared NATS image no longer matches the selected platform manifest: {image}"
        )
    return selected_digest


def collect(metadata_path, graph_path, compose_path, build_path, platform, output_dir, docker=run_docker):
    graph = read_json(graph_path, "dependency graph")
    compose = read_json(compose_path, "Compose configuration")
    build = read_json(build_path, "Buildx metadata")
    services = compose.get("services", {})
    if not isinstance(services, dict):
        raise PreparationError("Compose configuration has no service map")
    platform_parts(platform)
    projects = read_json_lines(metadata_path)
    suites = sorted(
        name
        for name, project in projects.items()
        if project.get("category") == "test"
        and isinstance(project.get("integration"), str)
        and project["integration"].strip()
    )

    identities = {}
    for suite in suites:
        resolved = graph.get("resolved", {}).get(suite)
        if not isinstance(resolved, dict):
            raise PreparationError(f"resolved dependency set is missing for suite: {suite}")
        project_names = set(resolved.get("projects", []))
        project_names.add(suite)
        image_identities = []
        for project in sorted(project_names):
            image_identities.append(
                {
                    "name": project,
                    "digest": project_image_identity(project, services, build, platform, docker),
                }
            )
        if "nats" in resolved.get("synthetic", []):
            nats = services.get("nats")
            image = nats.get("image") if isinstance(nats, dict) else None
            if not isinstance(image, str) or not image:
                raise PreparationError("required Compose service image is missing: nats")
            image_identities.append(
                {"name": "nats", "digest": nats_image_identity(image, platform, docker)}
            )
        identities[suite] = {
            "platform": platform,
            "images": sorted(image_identities, key=lambda item: item["name"]),
        }

    destination = Path(output_dir)
    destination.mkdir(parents=True, exist_ok=True)
    for suite, identity in identities.items():
        path = destination / f"{suite}.json"
        temporary = path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(identity, sort_keys=True, separators=(",", ":")) + "\n")
        temporary.replace(path)


def read_json_lines(path):
    projects = {}
    for line_number, line in enumerate(Path(path).read_text().splitlines(), start=1):
        if not line.strip():
            continue
        try:
            project = json.loads(line)
        except json.JSONDecodeError as error:
            raise PreparationError(f"{path}:{line_number}: invalid project JSON: {error}") from error
        if not isinstance(project, dict) or not isinstance(project.get("name"), str):
            raise PreparationError(f"{path}:{line_number}: invalid project metadata")
        projects[project["name"]] = project
    return projects


def main():
    parser = argparse.ArgumentParser(description="Collect selected-platform integration image identities.")
    parser.add_argument("--metadata", required=True, help="JSONL project metadata.")
    parser.add_argument("--graph", required=True, help="Resolved dependency graph JSON.")
    parser.add_argument("--compose-config", required=True, help="Generated Compose config JSON.")
    parser.add_argument("--build-metadata", required=True, help="Buildx metadata JSON.")
    parser.add_argument("--platform", required=True, help="Selected execution platform.")
    parser.add_argument("--output-dir", required=True, help="Directory for suite identity inputs.")
    args = parser.parse_args()

    try:
        collect(
            args.metadata,
            args.graph,
            args.compose_config,
            args.build_metadata,
            args.platform,
            args.output_dir,
        )
    except (OSError, json.JSONDecodeError, PreparationError) as error:
        print(f"Integration identity preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
