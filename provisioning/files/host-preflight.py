#!/usr/bin/python3
"""Refuse foreign/conflicting installations rather than adopt or reset them."""

from pathlib import Path
import json
import re
import shutil
import subprocess
import sys


def validate_upgrade(actual, requested, allow_upgrade):
    def components(value):
        match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)\+k3s(\d+)", value)
        if not match:
            raise ValueError("unrecognized k3s version")
        return tuple(int(part) for part in match.groups())

    before, after = components(actual), components(requested)
    if after < before:
        raise ValueError("k3s downgrade is not supported; recover matching state explicitly")
    if actual != requested and not allow_upgrade:
        raise ValueError("k3s version change requires allow_k3s_upgrade=true and verified backup")


def preflight(root, version, allow_upgrade):
    for name in ("ufw.service", "firewalld.service"):
        result = subprocess.run(
            ["systemctl", "is-active", name], capture_output=True, text=True,
        )
        if result.returncode not in (0, 3, 4):
            raise ValueError(f"cannot inspect {name}: {result.stderr}")
        if result.returncode == 0:
            raise ValueError(f"{name} is active; resolve firewall ownership first")
    unit = Path("/etc/systemd/system/k3s.service")
    binary = Path("/usr/local/bin/k3s")
    managed = unit.exists() and "recipe-db-storage-guard" in unit.read_text()
    if shutil.which("nft"):
        tables = json.loads(subprocess.run(
            ["nft", "--json", "list", "tables"], check=True,
            capture_output=True, text=True,
        ).stdout)["nftables"]
        allowed = {("inet", "recipe_db")}
        if managed:
            allowed.update((family, name) for family in ("ip", "ip6")
                           for name in ("filter", "nat", "mangle", "raw"))
        for item in tables:
            table = item.get("table")
            if table and (table["family"], table["name"]) not in allowed:
                raise ValueError("unmanaged nftables table; resolve firewall ownership first")
    if unit.exists() and not managed:
        raise ValueError("existing k3s unit is not managed by this playbook")
    if Path("/var/lib/rancher/k3s").exists():
        raise ValueError("foreign/default k3s state exists; no automatic migration or reset")
    if Path(root + "/k3s").exists() and any(Path(root + "/k3s").iterdir()) and not managed:
        raise ValueError("existing runtime state has no managed service; recover explicitly")
    if binary.exists():
        actual = subprocess.run(
            [str(binary), "--version"], check=True, capture_output=True, text=True,
        ).stdout.splitlines()[0].split()[2]
        if not managed:
            raise ValueError("existing unmanaged k3s binary")
        validate_upgrade(actual, version, allow_upgrade)
    elif managed:
        raise ValueError("managed service is missing its binary; investigate before repair")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 4:
            raise ValueError("usage: host-preflight DATA_ROOT VERSION yes|no")
        preflight(sys.argv[1], sys.argv[2], sys.argv[3] == "yes")
        print("No conflicting host services or unmanaged k3s state")
    except (ValueError, OSError, subprocess.CalledProcessError, IndexError) as error:
        print(f"recipe-db host preflight failed: {error}", file=sys.stderr)
        sys.exit(1)
