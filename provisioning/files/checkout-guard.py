#!/usr/bin/env python3
"""Refuse checkout changes while its code or another maintenance operation is active."""

import argparse
import json
import os
from pathlib import Path
import re
import sys


CHECKOUT = Path("/opt/recipe-db")
STATE = Path("/var/lib/recipe-db-backup/maintenance/backup-state.json")


def validate(revision, holder, checkout=CHECKOUT, state_path=STATE, proc=Path("/proc")):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("checkout revision must be a full immutable Git commit")
    if holder and not re.fullmatch(r"backup-[0-9]+-[0-9]+", holder):
        raise ValueError("maintenance confirmation must name the exact backup holder")
    command = state_path.parent.parent / "release-command.json"
    if command.exists() or command.is_symlink():
        raise ValueError("stop the workstation release command before changing its checkout")
    if state_path.is_symlink():
        raise ValueError("maintenance state must not be a symlink")
    if state_path.exists():
        state = json.loads(state_path.read_text())
        if not isinstance(state, dict):
            raise ValueError("maintenance state must be an object")
        recovered = (state.get("status"), state.get("phase")) in {
            ("recovered", "safely-recovered"), ("failed", "safely-recovered"),
        }
        if not recovered:
            if not holder or state.get("backupId") != holder:
                raise ValueError("active maintenance requires its exact holder confirmation")
            pinned = state.get("toolingRevision")
            if pinned and pinned != revision:
                raise ValueError("active release requires its recorded tooling revision")
    elif holder:
        raise ValueError("no retained maintenance operation matches the confirmation")
    if not checkout.exists():
        return
    expected = str(checkout)
    for process in proc.iterdir():
        if not process.name.isdecimal() or int(process.name) == os.getpid():
            continue
        try:
            cwd = os.readlink(process / "cwd")
            arguments = (process / "cmdline").read_bytes().split(b"\0")
        except FileNotFoundError:
            continue
        if cwd == expected or cwd.startswith(expected + "/") or any(
            os.fsdecode(argument) == expected
            or os.fsdecode(argument).startswith(expected + "/")
            for argument in arguments if argument
        ):
            raise ValueError("a process is using the managed checkout; stop it before changing revision")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--maintenance-holder", default="")
    args = parser.parse_args()
    try:
        validate(args.revision, args.maintenance_holder)
    except (OSError, ValueError, TypeError) as error:
        print(f"checkout guard: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
