import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined


ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "files" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


storage = load_script("storage-guard")
network = load_script("network-preflight")
host = load_script("host-preflight")
UUID = "02f61d5e-92cb-4f9c-a781-099d97795020"


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.mounts = [{"uuid": UUID, "fstype": "ext4", "source": "/dev/sda2"} for _ in range(5)]
        self.devices = [{"name": "sda", "tran": "usb", "children": [{"name": "sda2"}]}]

    def test_correct_usb_root(self):
        storage.validate_identity(UUID, "/srv/recipe-db", self.mounts, self.devices)

    def test_wrong_or_missing_uuid(self):
        for value in ("", "REPLACE-ME", "11111111-1111-1111-1111-111111111111"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                storage.validate_identity(value, "/srv/recipe-db", self.mounts, self.devices)

    def test_every_runtime_path_must_match(self):
        for index in range(5):
            with self.subTest(index=index):
                mounts = [entry.copy() for entry in self.mounts]
                mounts[index]["uuid"] = "different"
                with self.assertRaises(ValueError):
                    storage.validate_identity(UUID, "/srv/recipe-db", mounts, self.devices)

    def test_no_non_usb_or_wrong_filesystem(self):
        self.devices[0]["tran"] = "mmc"
        with self.assertRaises(ValueError):
            storage.validate_identity(UUID, "/srv/recipe-db", self.mounts, self.devices)
        self.devices[0]["tran"] = "usb"
        self.mounts[0]["fstype"] = "btrfs"
        with self.assertRaises(ValueError):
            storage.validate_identity(UUID, "/srv/recipe-db", self.mounts, self.devices)

    def test_unsafe_data_paths(self):
        for path in ("/", "/srv", "/srv/../etc", "/srv/recipe-db/child", "/srv/with space"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                storage.validate_identity(UUID, path, self.mounts, self.devices)


class NetworkTests(unittest.TestCase):
    def test_private_source_and_ipv6_ula(self):
        network.validate_networks(["192.168.1.0/24", "fd00::/64"], ["192.168.1.0/24"], "192.168.1.50")
        network.validate_networks(["fd00::/64"], ["fd00::/64"], "fd00::1")

    def test_reject_lockout_and_public_ranges(self):
        for admin, app, source in (
            ([], ["192.168.1.0/24"], "192.168.1.5"),
            (["0.0.0.0/0"], ["192.168.1.0/24"], "192.168.1.5"),
            (["::/0"], ["fd00::/64"], "fd00::1"),
            (["192.168.2.0/24"], ["192.168.1.0/24"], "192.168.1.5"),
            (["192.168.1.0/24"], ["8.8.8.0/24"], "192.168.1.5"),
            (["192.168.1.0/24"], ["192.168.1.4/24"], "192.168.1.5"),
        ):
            with self.subTest(admin=admin), self.assertRaises(ValueError):
                network.validate_networks(admin, app, source)


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.play = yaml.safe_load((ROOT / "site.yml").read_text())[0]
        self.defaults = yaml.safe_load((ROOT / "group_vars/pi.yml").read_text())
        self.environment = Environment(
            loader=FileSystemLoader(ROOT / "templates"), undefined=StrictUndefined,
        )
        self.values = dict(
            self.defaults, expected_root_uuid=UUID, inventory_hostname="recipe-db-pi",
            ansible_facts={"default_ipv4": {"address": "192.168.1.218"}},
            admin_networks=["192.168.1.0/24"], application_networks=["192.168.1.0/24"],
        )

    def render(self, name):
        return self.environment.get_template(name).render(self.values)

    def test_private_k3s_config_and_log_bounds(self):
        config = yaml.safe_load(self.render("k3s-config.yaml.j2"))
        # Binding only loopback breaks kubernetes.default.svc for cluster pods.
        self.assertEqual(config["bind-address"], "0.0.0.0")
        self.assertEqual(config["write-kubeconfig-mode"], "0600")
        self.assertEqual(config["data-dir"], "/srv/recipe-db/k3s")
        self.assertEqual(config["default-local-storage-path"], "/srv/recipe-db/storage")
        self.assertEqual(config["kubelet-arg"], [
            "root-dir=/srv/recipe-db/kubelet",
            "container-log-max-size=10Mi", "container-log-max-files=3",
        ])
        for key in ("cluster-init", "datastore-endpoint", "disable", "server", "node-ip", "advertise-address"):
            self.assertNotIn(key, config)

    def test_startup_guard_has_no_separate_mount(self):
        unit = self.render("k3s.service.j2")
        self.assertIn(f"ExecStartPre=/usr/local/sbin/recipe-db-storage-guard {UUID} /srv/recipe-db", unit)
        self.assertIn("Requires=recipe-db-firewall.service", unit)
        self.assertNotIn(".mount", unit)
        self.assertNotIn("k3s-killall", unit)

    def test_firewall_does_not_flush_cluster_rules_or_expose_admin(self):
        rules = self.render("firewall.nft.j2")
        self.assertNotIn("flush ruleset", rules)
        self.assertIn("destroy table inet recipe_db", rules)
        self.assertIn("policy drop", rules)
        self.assertIn("ip saddr 192.168.1.0/24 tcp dport 22 accept", rules)
        self.assertNotIn("6443 accept", rules)
        self.assertNotIn("8472 accept", rules)
        self.assertNotIn("10250 accept", rules)
        self.assertIn('iifname { "cni0", "flannel.1" } accept', rules)
        self.assertIn("ct original proto-dst { 80, 443 } accept", rules)
        self.assertNotIn("192.168.1.218", rules)

    def test_unsupported_target_and_readonly_preflight(self):
        assertions = self.play["tasks"][0]["ansible.builtin.assert"]["that"]
        self.assertIn("ansible_facts.architecture == 'aarch64'", assertions)
        self.assertIn("ansible_facts.distribution_release == 'trixie'", assertions)
        tasks = self.play["tasks"]
        end = next(i for i, task in enumerate(tasks) if task.get("ansible.builtin.meta") == "end_host")
        self.assertTrue(all(not any(key in task for key in (
            "ansible.builtin.apt", "ansible.builtin.copy", "ansible.builtin.file",
            "ansible.builtin.template", "ansible.builtin.systemd_service",
        )) for task in tasks[:end]))

    def test_no_destructive_or_unattended_reboot_tasks(self):
        contents = (ROOT / "site.yml").read_text()
        for forbidden in ("ansible.builtin.filesystem", "ansible.builtin.parted",
                          "ansible.builtin.reboot", "state: absent", "k3s-uninstall",
                          "cluster-reset", "mkfs"):
            self.assertNotIn(forbidden, contents)
        self.assertIn('Unattended-Upgrade::Automatic-Reboot "false"', contents)
        self.assertIn('SystemMaxUse={{ journal_max_use }}', contents)
        self.assertIn('checksum: "sha256:{{ k3s_sha256 }}"', contents)

    def test_foreign_state_is_refused(self):
        with patch.object(host.subprocess, "run") as run, patch.object(host, "Path") as path, \
                patch.object(host.shutil, "which", return_value=None):
            run.return_value.returncode = 3
            path.return_value.exists.return_value = True
            path.return_value.read_text.return_value = "unmanaged unit"
            with self.assertRaisesRegex(ValueError, "not managed"):
                host.preflight("/srv/recipe-db", "v1.35.5+k3s1", False)

    def test_upgrades_require_approval_and_never_implicitly_downgrade(self):
        host.validate_upgrade("v1.35.5+k3s1", "v1.35.5+k3s1", False)
        host.validate_upgrade("v1.35.5+k3s1", "v1.35.6+k3s1", True)
        for before, after, allow in (
            ("v1.35.5+k3s1", "v1.35.6+k3s1", False),
            ("v1.35.5+k3s1", "v1.35.4+k3s1", True),
            ("unknown", "v1.35.5+k3s1", True),
        ):
            with self.subTest(before=before, after=after), self.assertRaises(ValueError):
                host.validate_upgrade(before, after, allow)

    def test_startup_refuses_missing_directories(self):
        with patch.object(storage.Path, "is_dir", return_value=False):
            with self.assertRaisesRegex(ValueError, "missing"):
                storage.inspect(UUID, "/srv/recipe-db")

    def test_startup_refuses_symbolic_links(self):
        with patch.object(storage.Path, "is_dir", return_value=True), \
                patch.object(storage.Path, "exists", return_value=True), \
                patch.object(storage.Path, "resolve", return_value=Path("/unexpected")), \
                patch.object(storage.subprocess, "run") as run:
            run.return_value.stdout = '{"filesystems":[{"source":"/dev/sda2","uuid":"' + UUID + '","fstype":"ext4"}]}'
            with self.assertRaisesRegex(ValueError, "symbolic"):
                storage.inspect(UUID, "/srv/recipe-db")


if __name__ == "__main__":
    unittest.main()
