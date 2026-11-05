import importlib.util
from pathlib import Path
import shlex
import subprocess
import tomllib
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
        self.environment.filters["quote"] = shlex.quote
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

    def test_backup_systemd_contract_is_private_bounded_and_non_catching_up(self):
        service = self.render("recipe-db-backup.service.j2")
        timer = self.render("recipe-db-backup.timer.j2")
        self.assertIn("ConditionPathExists=/etc/recipe-db/backup.json", service)
        self.assertIn("UMask=0077", service)
        self.assertIn("TimeoutStartSec=2h", service)
        self.assertIn("Environment=KUBECONFIG=/etc/recipe-db/backup-kubeconfig.yaml", service)
        self.assertIn("ExecStart=/usr/local/sbin/recipe-db-backup-upload nightly", service)
        self.assertIn("ReadWritePaths=/var/lib/recipe-db-backup", service)
        self.assertIn("OnCalendar=*-*-* 02:15:00", timer)
        self.assertIn("Persistent=false", timer)
        self.assertIn("RandomizedDelaySec=15min", timer)
        self.assertEqual(self.defaults["rclone_version"], "1.75.2")
        self.assertEqual(self.defaults["rclone_sha256"],
                         "b8ba161d5c837206fad79ff1aabf0a81aa02a5fb164cdbc0ff5db4160aecd278")
        tasks = next(task["block"] for task in self.play["tasks"] if "block" in task)
        private_dirs = next(task for task in tasks if task.get("name") == "Create private backup configuration and state directories")
        self.assertEqual(private_dirs["ansible.builtin.file"]["mode"], "0700")
        installs = [task for task in tasks if task.get("name") == "Install nightly backup service and timer"]
        self.assertEqual(len(installs), 1)
        copy_kubeconfig = next(task for task in tasks
                               if task.get("name") == "Copy the root-only local kubeconfig for the backup service")
        self.assertTrue(copy_kubeconfig["no_log"])
        self.assertEqual(copy_kubeconfig["ansible.builtin.copy"]["mode"], "0600")
        self.assertEqual(copy_kubeconfig["ansible.builtin.copy"]["dest"],
                         "/etc/recipe-db/backup-kubeconfig.yaml")
        context_task = next(task for task in tasks if task.get("name") == "Name the local backup kubeconfig context")
        self.assertEqual(context_task["environment"]["KUBECONFIG"],
                         "/etc/recipe-db/backup-kubeconfig.yaml")
        rclone_task = next(task for task in tasks if task.get("name") == "Download checksum-pinned ARM64 rclone package")
        self.assertIn("{{ rclone_sha256 }}", rclone_task["ansible.builtin.get_url"]["checksum"])
        self.assertEqual(rclone_task["ansible.builtin.get_url"]["url"],
                         "https://downloads.rclone.org/v{{ rclone_version }}/rclone-v{{ rclone_version }}-linux-arm64.deb")

    def test_startup_guard_has_no_separate_mount(self):
        unit = self.render("k3s.service.j2")
        self.assertIn(f"ExecStartPre=/usr/local/sbin/recipe-db-storage-guard {UUID} /srv/recipe-db", unit)
        self.assertIn("Requires=recipe-db-firewall.service", unit)
        self.assertNotIn(".mount", unit)
        self.assertNotIn("k3s-killall", unit)

    def test_backup_toolchain_is_pinned_and_has_no_development_hooks(self):
        config = tomllib.loads(self.render("backup-toolchain.toml.j2"))
        self.assertEqual(config, {"tools": {
            "jq": "1.8.2", "yq": "4.54.1", "ytt": "0.55.4",
            "aqua:oras-project/oras": "1.3.6",
            "aqua:kubernetes/kubernetes/kubectl": "1.35.5",
        }})
        self.assertEqual(self.defaults["backup_mise_version"], "2026.10.21")
        self.assertEqual(self.defaults["backup_mise_sha256"],
                         "a7c96627e56c075543fe1c1aafeb289d2588d6ddfd4d705fce4ae140c57e190c")
        self.assertEqual(self.defaults["backup_capture_revision"], "")
        self.assertEqual(self.defaults["backup_toolchain_environment"], {
            "MISE_CONFIG_DIR": "/etc/recipe-db/backup-toolchain",
            "MISE_DATA_DIR": "/var/lib/recipe-db-backup/tooling/data",
            "MISE_STATE_DIR": "/var/lib/recipe-db-backup/tooling/state",
            "MISE_CACHE_DIR": "/var/lib/recipe-db-backup/tooling/cache",
            "MISE_IGNORED_CONFIG_PATHS": "/opt/recipe-db/mise.toml",
        })

    def test_backup_toolchain_adopts_existing_installation_and_refuses_dirty_checkout(self):
        tasks = yaml.safe_load((ROOT / "backup-toolchain.yml").read_text())
        by_name = {task["name"]: task for task in tasks}
        download = by_name["Download checksum-pinned ARM64 Mise binary"]["ansible.builtin.get_url"]
        self.assertEqual(download["checksum"], "sha256:{{ backup_mise_sha256 }}")
        self.assertTrue(download["url"].endswith("-linux-arm64"))
        install = by_name["Install checksum-pinned Mise"]["ansible.builtin.copy"]
        self.assertTrue(install["remote_src"])
        self.assertEqual(install["dest"], "/usr/local/bin/mise")
        probe = by_name["Inspect missing backup capture tools"]
        self.assertEqual(probe["ansible.builtin.command"]["argv"][-3:], ["ls", "--missing", "--json"])
        self.assertFalse(probe["changed_when"])
        install = by_name["Install missing pinned backup capture tools"]
        self.assertEqual(install["when"], "backup_missing_tools.stdout | from_json | length > 0")
        self.assertEqual(install["environment"], "{{ backup_toolchain_environment }}")
        checkout = by_name["Check out the explicitly selected immutable backup capture release"]
        self.assertEqual(checkout["when"], "backup_capture_revision != ''")
        self.assertEqual(checkout["ansible.builtin.git"]["version"], "{{ backup_capture_revision }}")
        self.assertFalse(checkout["ansible.builtin.git"]["force"])
        self.assertFalse(checkout["ansible.builtin.git"]["recursive"])
        self.assertFalse(any("ansible.builtin.shell" in task for task in tasks))
        contents = (ROOT / "backup-toolchain.yml").read_text()
        self.assertNotIn("mise run", contents)
        self.assertNotIn("rclone.conf", contents)
        self.assertNotIn("backup.json", contents)

    def test_backup_toolchain_maintenance_excludes_scheduled_and_active_capture(self):
        host_tasks = next(task["block"] for task in self.play["tasks"] if "block" in task)
        maintenance = next(task for task in host_tasks
                           if task["name"] == "Provision the backup capture toolchain and selected release checkout")
        self.assertEqual(maintenance["block"][1]["ansible.builtin.systemd_service"]["state"], "stopped")
        self.assertEqual(maintenance["always"][0]["ansible.builtin.systemd_service"]["state"], "started")
        self.assertIn("backup_timer_active.rc", maintenance["always"][0]["when"])
        tasks = yaml.safe_load((ROOT / "backup-toolchain.yml").read_text())
        self.assertEqual(tasks[0]["ansible.builtin.command"],
                         "systemctl show --property=ActiveState --value recipe-db-backup.service")
        self.assertIn("backup_service_active.stdout not in ['inactive', 'failed']", tasks[0]["failed_when"])

    def test_capture_wrapper_uses_private_inputs_and_isolated_toolchain(self):
        command = self.render("recipe-db-backup-capture.j2")
        subprocess.run(["bash", "-n"], input=command, text=True, check=True)
        self.assertIn('! -e $1 && ! -L $1', command)
        for key, value in self.defaults["backup_toolchain_environment"].items():
            self.assertIn(f"export {key}={shlex.quote(value)}", command)
        self.assertIn("export HOME=/root", command)
        self.assertIn('KUBECONFIG="${KUBECONFIG:-/etc/recipe-db/backup-kubeconfig.yaml}"', command)
        self.assertIn("exec /usr/local/bin/mise exec -- bash /opt/recipe-db/.scripts/production-k3d.sh", command)
        self.assertIn('backup /etc/recipe-db/backup-values.yaml "$release" "$1"', command)
        self.assertIn("release=$(cat /etc/recipe-db/backup-release-ref)", command)
        self.assertNotIn("mise run", command)

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
        self.assertNotIn("8081", rules)
        self.assertNotIn("8443", rules)
        self.assertFalse(self.defaults["public_https_enabled"])

    def test_public_https_is_ipv4_only_and_limited_to_dedicated_dnat_ports(self):
        self.values["public_https_enabled"] = True
        rules = self.render("firewall.nft.j2")
        self.assertIn('meta nfproto ipv4 tcp dport { 8081, 8443 } accept comment "recipe-db-public-https"', rules)
        self.assertIn("ct status dnat ct original ip daddr 192.168.1.218 ct original proto-dst { 8081, 8443 } accept", rules)
        self.assertLess(rules.index('ct original proto-dst { 8081, 8443 }'),
                        rules.index('ct state new ip daddr'))
        for line in rules.splitlines():
            if "recipe-db-public-https" in line:
                self.assertNotIn("ip6", line)
                self.assertNotIn("udp", line)
                self.assertNotIn("6443", line)
                self.assertNotIn("8472", line)
        self.assertIn("ip saddr 192.168.1.0/24 tcp dport 22 accept", rules)
        self.values["public_https_enabled"] = False
        self.assertNotIn("recipe-db-public-https", self.render("firewall.nft.j2"))

    def test_firewall_only_run_retains_input_and_lockout_guards(self):
        assertions = self.play["tasks"][0]["ansible.builtin.assert"]["that"]
        self.assertIn("public_https_enabled is boolean", assertions)
        for name in (
            "Validate explicit operator inputs and supported host",
            "Verify root identity before making changes",
            "Verify private network inputs and current SSH source",
            "Stop after read-only preflight when requested",
        ):
            task = next(task for task in self.play["tasks"] if task["name"] == name)
            self.assertEqual(task["tags"], "firewall")
        tasks = next(task["block"] for task in self.play["tasks"] if "block" in task)
        tagged = {task["name"] for task in tasks if task.get("tags") == "firewall"}
        self.assertEqual(tagged, {
            "Install private host firewall configuration",
            "Install firewall service without replacing other nftables tables",
            "Validate firewall syntax before activation",
            "Enable private firewall",
        })

    def test_storage_preflight_can_inspect_root_only_runtime_directories(self):
        task = next(task for task in self.play["tasks"]
                    if task["name"] == "Verify root identity before making changes")
        self.assertTrue(task["become"])
        self.assertFalse(task["changed_when"])
        self.assertIn("--preflight", task["ansible.builtin.script"]["cmd"])

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

    def test_host_packages_do_not_require_unavailable_update_notifier(self):
        tasks = next(task["block"] for task in self.play["tasks"] if "block" in task)
        packages = next(task["ansible.builtin.apt"]["name"] for task in tasks if "ansible.builtin.apt" in task)
        self.assertIn("unattended-upgrades", packages)
        self.assertNotIn("update-notifier-common", packages)

    def test_application_compatibility_does_not_override_the_default_pi_kernel(self):
        contents = (ROOT / "site.yml").read_text()
        self.assertNotIn("/boot/firmware/config.txt", contents)
        self.assertNotIn("kernel8.img", contents)
        self.assertNotIn("getconf PAGESIZE", contents)

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
