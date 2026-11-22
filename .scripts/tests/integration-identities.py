import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "integration_identities", ROOT / ".scripts/integration-identities.py"
)
identities = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(identities)


def digest(character):
    return f"sha256:{character * 64}"


def image_details(image_id, architecture="arm64", repo_digests=None):
    return {
        "Os": "linux",
        "Architecture": architecture,
        "Id": image_id,
        "RepoDigests": repo_digests or [],
    }


class IntegrationIdentitiesTest(unittest.TestCase):
    def setUp(self):
        self.config_digest = digest("a")
        self.manifest_digest = digest("b")
        self.platform = "linux/arm64"
        self.service_image = "example.invalid/suite:built"
        self.metadata = {
            "suite": {
                "containerimage.digest": self.manifest_digest,
                "containerimage.config.digest": self.config_digest,
                "containerimage.descriptor": {
                    "digest": self.manifest_digest,
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                },
            }
        }

    def project_services(self):
        return {"suite": {"image": self.service_image}}

    def docker_for_project(self, architecture="arm64"):
        def docker(arguments):
            self.assertEqual(arguments, ["image", "inspect", self.service_image])
            return json.dumps([image_details(self.config_digest, architecture)])

        return docker

    def test_project_identity_is_selected_runnable_manifest(self):
        result = identities.project_image_identity(
            "suite", self.project_services(), self.metadata, self.platform,
            self.docker_for_project(),
        )
        self.assertEqual(result, self.manifest_digest)

    def test_project_identity_accepts_loaded_manifest_descriptor(self):
        del self.metadata["suite"]["containerimage.config.digest"]

        def docker(arguments):
            details = image_details(self.manifest_digest)
            details["Descriptor"] = {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": self.manifest_digest,
            }
            return json.dumps([details])

        self.assertEqual(
            identities.project_image_identity(
                "suite", self.project_services(), self.metadata, self.platform, docker
            ),
            self.manifest_digest,
        )

        def mismatched_docker(arguments):
            details = image_details(self.config_digest)
            details["Descriptor"] = {
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "digest": digest("9"),
            }
            return json.dumps([details])

        with self.assertRaisesRegex(identities.PreparationError, "no longer matches"):
            identities.project_image_identity(
                "suite", self.project_services(), self.metadata, self.platform,
                mismatched_docker,
            )

    def test_project_identity_rejects_missing_ambiguous_or_wrong_platform_metadata(self):
        with self.assertRaisesRegex(identities.PreparationError, "build metadata is missing"):
            identities.project_image_identity(
                "suite", self.project_services(), {}, self.platform, self.docker_for_project()
            )

        with self.assertRaisesRegex(identities.PreparationError, "service image is missing"):
            identities.project_image_identity(
                "suite", {}, self.metadata, self.platform, self.docker_for_project()
            )

        self.metadata["suite"]["containerimage.descriptor"]["mediaType"] = \
            "application/example.invalid"
        with self.assertRaisesRegex(identities.PreparationError, "not a runnable image manifest"):
            identities.project_image_identity(
                "suite", self.project_services(), self.metadata, self.platform,
                self.docker_for_project(),
            )

        self.metadata["suite"]["containerimage.descriptor"]["mediaType"] = \
            "application/vnd.oci.image.manifest.v1+json"
        with self.assertRaisesRegex(identities.PreparationError, "uses linux/amd64"):
            identities.project_image_identity(
                "suite", self.project_services(), self.metadata, self.platform,
                self.docker_for_project("amd64"),
            )

    def test_project_index_selects_the_loaded_runnable_manifest(self):
        index_digest = digest("c")
        self.metadata["suite"]["containerimage.digest"] = index_digest
        self.metadata["suite"]["containerimage.descriptor"] = {
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "digest": index_digest,
        }
        selected = {
            "Kind": "image",
            "Available": True,
            "Descriptor": {
                "digest": self.manifest_digest,
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
            },
            "ImageData": {"Platform": {"os": "linux", "architecture": "arm64"}},
        }
        attestation = {
            "Kind": "attestation",
            "Descriptor": {"digest": digest("d")},
        }
        local = {"Descriptor": {"digest": index_digest}, "Manifests": [selected, attestation]}

        def identity():
            return identities.project_image_identity(
                "suite", self.project_services(), self.metadata, self.platform,
                self.docker_for_project(), lambda image: local,
            )

        self.assertEqual(identity(), self.manifest_digest)
        local["Manifests"][1]["Descriptor"]["digest"] = digest("e")
        local["Descriptor"]["digest"] = digest("8")
        self.metadata["suite"]["containerimage.digest"] = digest("8")
        self.metadata["suite"]["containerimage.descriptor"]["digest"] = digest("8")
        self.assertEqual(identity(), self.manifest_digest)
        selected["Descriptor"]["digest"] = digest("f")
        self.assertEqual(identity(), digest("f"))

        local["Manifests"].append(selected.copy())
        with self.assertRaisesRegex(identities.PreparationError, "ambiguous runnable"):
            identity()
        local["Manifests"].pop()
        selected["ImageData"]["Platform"]["architecture"] = "amd64"
        with self.assertRaisesRegex(identities.PreparationError, "missing runnable"):
            identity()
        selected["ImageData"]["Platform"]["architecture"] = "arm64"
        selected["Available"] = False
        with self.assertRaisesRegex(identities.PreparationError, "not available"):
            identity()
        selected["Available"] = True
        local["Descriptor"]["digest"] = digest("9")
        with self.assertRaisesRegex(identities.PreparationError, "no longer matches"):
            identity()
        local["Descriptor"] = "invalid"
        with self.assertRaisesRegex(identities.PreparationError, "no longer matches"):
            identity()

    def nats_fixture(self, manifests=None):
        self.index_digest = digest("c")
        self.arm_manifest_digest = digest("d")
        self.amd_manifest_digest = digest("e")
        self.nats_config_digest = digest("f")
        self.nats_image = f"nats:2-alpine@{self.index_digest}"
        if manifests is None:
            manifests = [
                {
                    "digest": self.amd_manifest_digest,
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                    "platform": {"os": "linux", "architecture": "amd64"},
                },
                {
                    "digest": self.arm_manifest_digest,
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                    "platform": {"os": "linux", "architecture": "arm64", "variant": "v8"},
                },
            ]
        root = {"mediaType": "application/vnd.oci.image.index.v1+json", "manifests": manifests}
        child = {
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": {"digest": self.nats_config_digest},
        }

        def docker(arguments):
            if arguments == ["image", "inspect", self.nats_image]:
                return json.dumps(
                    [
                        image_details(
                            self.nats_config_digest,
                            repo_digests=[f"nats@{self.index_digest}"],
                        )
                    ]
                )
            if arguments == ["buildx", "imagetools", "inspect", "--raw", self.nats_image]:
                return json.dumps(root)
            if arguments == [
                "buildx",
                "imagetools",
                "inspect",
                "--raw",
                f"nats:2-alpine@{self.arm_manifest_digest}",
            ]:
                return json.dumps(child)
            raise AssertionError(f"unexpected Docker command: {arguments}")

        return docker

    def test_nats_selects_the_runnable_manifest_for_the_execution_platform(self):
        docker = self.nats_fixture()
        result = identities.nats_image_identity(
            self.nats_image, self.platform, docker
        )
        self.assertEqual(result, self.arm_manifest_digest)

    def test_nats_index_matches_the_locally_loaded_platform_manifest(self):
        original = self.nats_fixture()

        def docker(arguments):
            if arguments == ["image", "inspect", self.nats_image]:
                details = image_details(
                    self.index_digest, repo_digests=[f"nats@{self.index_digest}"]
                )
                details["Descriptor"] = {
                    "mediaType": "application/vnd.oci.image.index.v1+json",
                    "digest": self.index_digest,
                }
                return json.dumps([details])
            return original(arguments)

        local = {
            "Descriptor": {"digest": self.index_digest},
            "Manifests": [{
                "Kind": "image",
                "Available": True,
                "Descriptor": {
                    "digest": self.arm_manifest_digest,
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                },
                "ImageData": {"Platform": {"os": "linux", "architecture": "arm64"}},
            }],
        }
        self.assertEqual(
            identities.nats_image_identity(
                self.nats_image, self.platform, docker, lambda image: local
            ),
            self.arm_manifest_digest,
        )
        local["Manifests"][0]["Descriptor"]["digest"] = digest("9")
        with self.assertRaisesRegex(identities.PreparationError, "no longer matches"):
            identities.nats_image_identity(
                self.nats_image, self.platform, docker, lambda image: local
            )

    def test_nats_index_changes_preserve_selected_manifest_identity(self):
        docker = self.nats_fixture()
        original = identities.nats_image_identity(self.nats_image, self.platform, docker)
        docker = self.nats_fixture()
        original_docker = docker
        root_json = json.loads(
            original_docker(
                ["buildx", "imagetools", "inspect", "--raw", self.nats_image]
            )
        )
        root_json["annotations"] = {"org.opencontainers.image.created": "later"}

        def changed_index(arguments):
            if arguments == ["buildx", "imagetools", "inspect", "--raw", self.nats_image]:
                return json.dumps(root_json)
            return original_docker(arguments)

        self.assertEqual(
            identities.nats_image_identity(self.nats_image, self.platform, changed_index),
            original,
        )

    def test_missing_and_ambiguous_nats_platform_manifests_fail(self):
        self.nats_fixture()
        missing = [
            {
                "digest": self.amd_manifest_digest,
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "platform": {"os": "linux", "architecture": "amd64"},
            }
        ]
        with self.assertRaisesRegex(identities.PreparationError, "missing runnable NATS"):
            identities.nats_image_identity(
                self.nats_image, self.platform, self.nats_fixture(missing)
            )

        duplicate = [
            {
                "digest": digest("1"),
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "platform": {"os": "linux", "architecture": "arm64"},
            },
            {
                "digest": digest("2"),
                "mediaType": "application/vnd.oci.image.manifest.v1+json",
                "platform": {"os": "linux", "architecture": "arm64"},
            },
        ]
        with self.assertRaisesRegex(identities.PreparationError, "ambiguous runnable NATS"):
            identities.nats_image_identity(
                self.nats_image, self.platform, self.nats_fixture(duplicate)
            )

    def test_identity_files_ignore_attestations_and_indexes_but_track_selected_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = root / "projects.jsonl"
            metadata.write_text(
                json.dumps(
                    {
                        "name": "suite",
                        "category": "test",
                        "integration": "run",
                        "integrationDependencies": [],
                    }
                )
                + "\n"
            )
            graph = root / "graph.json"
            graph.write_text(json.dumps({"resolved": {"suite": {"projects": [], "synthetic": []}}}))
            compose = root / "compose.json"
            compose.write_text(json.dumps({"services": self.project_services()}))
            build = root / "build.json"
            build.write_text(json.dumps(self.metadata))

            first = root / "first"
            identities.collect(
                metadata, graph, compose, build, self.platform, first,
                self.docker_for_project(),
            )
            original = (first / "suite.json").read_text()

            self.metadata["suite"]["buildx.build.provenance"] = {"attestation": "changed"}
            self.metadata["suite"]["containerimage.index.digest"] = digest("9")
            self.metadata["suite"]["containerimage.descriptor"]["annotations"] = {
                "org.opencontainers.image.created": "later"
            }
            build.write_text(json.dumps(self.metadata))
            second = root / "second"
            identities.collect(
                metadata, graph, compose, build, self.platform, second,
                self.docker_for_project(),
            )
            self.assertEqual((second / "suite.json").read_text(), original)
            self.assertEqual(
                json.loads(original),
                {"platform": self.platform, "images": [{"name": "suite", "digest": self.manifest_digest}]},
            )

            changed_digest = digest("8")
            self.metadata["suite"]["containerimage.digest"] = changed_digest
            self.metadata["suite"]["containerimage.descriptor"]["digest"] = changed_digest
            build.write_text(json.dumps(self.metadata))
            third = root / "third"
            identities.collect(
                metadata, graph, compose, build, self.platform, third,
                self.docker_for_project(),
            )
            self.assertNotEqual((third / "suite.json").read_text(), original)

    def test_collection_includes_transitive_project_and_nats_images_once(self):
        nats_docker = self.nats_fixture()
        suite_projects = ["suite", "app", "transitive"]
        services = {
            project: {"image": f"example.invalid/{project}:test"}
            for project in suite_projects
        }
        services["nats"] = {"image": self.nats_image}
        build_metadata = {}
        expected_digests = {}
        for index, project in enumerate(suite_projects):
            manifest_digest = digest(chr(ord("1") + index))
            expected_digests[project] = manifest_digest
            build_metadata[project] = {
                "containerimage.digest": manifest_digest,
                "containerimage.config.digest": self.config_digest,
                "containerimage.descriptor": {
                    "digest": manifest_digest,
                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                },
            }

        def docker(arguments):
            if arguments[:2] == ["image", "inspect"] and arguments[2] != self.nats_image:
                return json.dumps([image_details(self.config_digest)])
            return nats_docker(arguments)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            metadata = root / "projects.jsonl"
            metadata.write_text(
                "\n".join(
                    json.dumps(
                        {
                            "name": project,
                            "category": "test" if project == "suite" else "backend",
                            "integration": "run" if project == "suite" else None,
                        }
                    )
                    for project in suite_projects
                )
                + "\n"
            )
            graph = root / "graph.json"
            graph.write_text(
                json.dumps(
                    {
                        "resolved": {
                            "suite": {
                                "projects": ["app", "transitive", "app"],
                                "synthetic": ["nats"],
                            }
                        }
                    }
                )
            )
            compose = root / "compose.json"
            compose.write_text(json.dumps({"services": services}))
            build = root / "build.json"
            build.write_text(json.dumps(build_metadata))
            output = root / "identities"

            identities.collect(
                metadata, graph, compose, build, self.platform, output, docker
            )

            self.assertEqual(
                json.loads((output / "suite.json").read_text()),
                {
                    "platform": self.platform,
                    "images": [
                        {"name": "app", "digest": expected_digests["app"]},
                        {"name": "nats", "digest": self.arm_manifest_digest},
                        {"name": "suite", "digest": expected_digests["suite"]},
                        {"name": "transitive", "digest": expected_digests["transitive"]},
                    ],
                },
            )


if __name__ == "__main__":
    unittest.main()
