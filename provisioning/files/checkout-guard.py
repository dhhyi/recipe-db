#!/usr/bin/env python3
"""Refuse checkout changes while its code or another maintenance operation is active."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import secrets
import stat
import subprocess
import sys
import tempfile


CHECKOUT = Path("/opt/recipe-db")
STATE = Path("/var/lib/recipe-db-backup/maintenance/backup-state.json")
TERMINAL_FAILURES = {
    "post-release-backup-failed", "post-release-backup-recovery-required",
    "post-release-backup-manifest-failed", "post-release-storage-version-failed",
    "recovery-closeout-pending",
}


def validate(revision, holder, checkout=CHECKOUT, state_path=STATE, proc=Path("/proc"),
             ignored_pids=()):
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
    validate_processes(checkout, proc, ignored_pids)


def validate_processes(checkout, proc, ignored_pids=()):
    if not checkout.exists():
        return
    expected = str(checkout)
    for process in proc.iterdir():
        if not process.name.isdecimal() or int(process.name) in {os.getpid(), *ignored_pids}:
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


def private_json(path, owner=None):
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise ValueError("private preparation files must not traverse symlinks")
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != (os.geteuid() if owner is None else owner) \
            or info.st_mode & 0o077 or info.st_size > 16 * 1024 * 1024:
        raise ValueError("preparation requires private owned regular files")
    raw = path.read_bytes()
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("private preparation state must be an object")
    return value, hashlib.sha256(raw).hexdigest()


def inspect_closeout_claim(state_path=STATE):
    state, state_hash = private_json(state_path, owner=0)
    claim, _ = private_json(state_path.parent.parent / "release-command.json", owner=0)
    holder, token = claim.get("holder"), claim.get("token")
    source = state.get("source")
    if not isinstance(holder, str) or not re.fullmatch(r"backup-[0-9]+-[0-9]+", holder) \
            or not isinstance(token, str) \
            or not re.fullmatch(r"[0-9a-f]{48}:[A-Za-z0-9-]+:[0-9a-f]{64}:[0-9a-f]{40}", token) \
            or token.split(":")[2] != state_hash \
            or state.get("backupId") != holder or state.get("stateVersion") != 2 \
            or state.get("status") != "recovery-required" or state.get("phase") not in TERMINAL_FAILURES \
            or not isinstance(source, dict) or claim.get("source") != source \
            or source.get("target") != "pi" \
            or not isinstance(source.get("artifact"), str) \
            or not re.fullmatch(r"ghcr[.]io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}", source["artifact"]) \
            or not isinstance(source.get("revision"), str) \
            or not re.fullmatch(r"[0-9a-f]{40}", source["revision"]) \
            or not isinstance(state.get("configSha256"), str) \
            or not re.fullmatch(r"[0-9a-f]{64}", state["configSha256"]) \
            or claim.get("configSha256") != state["configSha256"]:
        raise ValueError("private claim does not match an interrupted closeout tooling preparation")
    return {"holder": holder, "token": token}


def output(arguments):
    return subprocess.check_output(arguments, timeout=30).decode().strip()


def installed_release_files():
    return runpy.run_path("/usr/local/sbin/recipe-db-release-files")


def validate_closeout(revision, holder, confirmation, token, checkout=CHECKOUT,
                      state_path=STATE, proc=Path("/proc"), ignored_pids=()):
    if not re.fullmatch(r"[0-9a-f]{40}", revision) \
            or not re.fullmatch(r"backup-[0-9]+-[0-9]+", holder) \
            or confirmation != f"PREPARE-CLOSEOUT-{holder}":
        raise ValueError("closeout preparation requires its exact holder, approval and immutable revision")
    validate_processes(checkout, proc, ignored_pids)
    for directory in (state_path.parent, state_path.parent.parent):
        info = directory.stat()
        if directory.is_symlink() or not stat.S_ISDIR(info.st_mode) \
                or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError("retained preparation directories must be private and owned")
    state, state_hash = private_json(state_path)
    source, candidate = state.get("source"), state.get("candidate")
    artifact_pattern = r"ghcr[.]io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}"
    if state.get("stateVersion") != 2 or state.get("backupId") != holder \
            or state.get("status") != "recovery-required" or state.get("phase") not in TERMINAL_FAILURES \
            or not isinstance(source, dict) or not isinstance(candidate, dict) \
            or any(not isinstance(identity.get(key), str)
                   or not re.fullmatch(pattern, identity[key])
                   for identity in (source, candidate)
                   for key, pattern in (("artifact", artifact_pattern), ("revision", r"[0-9a-f]{40}"))) \
            or source["artifact"] == candidate["artifact"] \
            or source.get("target") != "pi" \
            or any(not isinstance(source.get(key), str) or not source[key]
                   for key in ("cluster", "context", "namespace")) \
            or not re.fullmatch(r"[0-9a-f]{64}", state.get("configSha256", "")):
        raise ValueError("preparation requires the exact terminal retained failed-release identities")
    marker = state_path.parent.parent / "release-command.json"
    if token is None:
        if marker.exists() or marker.is_symlink():
            raise ValueError("stop and abandon the retained workstation file claim before preparation")
    else:
        claim, _ = private_json(marker)
        if claim.get("token") != token or claim.get("holder") != holder \
                or claim.get("source") != source or claim.get("configSha256") != state["configSha256"]:
            raise ValueError("closeout preparation does not own the exact private file claim")
    if output(["systemctl", "show", "--property=ActiveState", "--value",
               "recipe-db-backup.service"]) not in {"inactive", "failed"}:
        raise ValueError("closeout preparation requires an idle backup service")
    timer = dict(line.split("=", 1) for line in output([
        "systemctl", "show", "--property=ActiveState", "--property=UnitFileState",
        "--property=LoadState", "recipe-db-backup.timer",
    ]).splitlines())
    if timer != {"ActiveState": "inactive", "UnitFileState": "disabled", "LoadState": "loaded"}:
        raise ValueError("closeout preparation requires the timer already stopped and disabled")
    lease = json.loads(output([
        "/usr/local/bin/k3s", "kubectl", "--kubeconfig", "/etc/rancher/k3s/k3s.yaml",
        "--namespace", "kube-system", "--request-timeout=10s",
        "get", "lease", "recipe-db-deploy", "-o", "json",
    ]))
    if not isinstance(lease, dict):
        raise ValueError("primary terminal release Lease must be an object")
    metadata = lease.get("metadata") or {}
    annotations = metadata.get("annotations") or {}
    uid = metadata.get("uid", "")
    if lease.get("apiVersion") != "coordination.k8s.io/v1" or lease.get("kind") != "Lease" \
            or metadata.get("name") != "recipe-db-deploy" or metadata.get("namespace") != "kube-system" \
            or metadata.get("deletionTimestamp") is not None \
            or not isinstance(uid, str) or not re.fullmatch(r"[A-Za-z0-9-]+", uid) \
            or (metadata.get("labels") or {}).get("app.kubernetes.io/part-of") != "recipe-db" \
            or (lease.get("spec") or {}).get("holderIdentity") != holder \
            or annotations.get("recipe-db/operation") != "backup" \
            or annotations.get("recipe-db/release") != source["artifact"] \
            or annotations.get("recipe-db/phase") not in {state["phase"], "recovery-required"}:
        raise ValueError("closeout preparation requires the exact primary terminal release Lease")
    if token is not None:
        fields = token.split(":")
        if len(fields) != 4 or not re.fullmatch(r"[0-9a-f]{48}", fields[0]) \
                or fields[1:] != [uid, state_hash, revision]:
            raise ValueError("preparation Lease UID, retained state or reviewed revision changed")
    helper = installed_release_files()
    config = helper["backup"]["safe_config"]("/etc/recipe-db/backup.json")
    if config["stateDirectory"] != str(state_path.parent.parent) \
            or helper["config_info"]()["configSha256"] != state["configSha256"]:
        raise ValueError("installed private backup configuration changed")
    documents = helper["managed"]([
        "yq", "-o=json", "eval-all", "[.]", "/etc/recipe-db/backup-values.yaml",
    ])
    values, = json.loads(documents)
    if not isinstance(values, dict) \
            or any(values.get(key) != source[key] for key in ("target", "cluster", "context", "namespace")):
        raise ValueError("private backup target differs from the retained release")
    return state, state_hash, uid, helper, config


def prepare_closeout(revision, holder, confirmation, checkout=CHECKOUT,
                     state_path=STATE, proc=Path("/proc")):
    descriptor = os.open(state_path.parent.parent / "run.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        validate_owner(state_path, proc)
        state, state_hash, uid, helper, config = validate_closeout(
            revision, holder, confirmation, None, checkout, state_path, proc,
            ignored_pids=(os.getppid(),),
        )
        token = f"{secrets.token_hex(24)}:{uid}:{state_hash}:{revision}"
        old_revision = output(["/usr/bin/git", "-C", str(checkout), "rev-parse", "HEAD"])
        if not re.fullmatch(r"[0-9a-f]{40}", old_revision):
            raise ValueError("managed checkout does not have an immutable revision")
        result = helper["handle"]({
            "operation": "begin", "revision": old_revision, "action": "release-closeout-prepare",
            "token": token,
        }, config)
        if result["state"] != state:
            raise ValueError("retained release changed while claiming its preparation")
        return {"token": token}
    finally:
        os.close(descriptor)


def process_identity(pid, proc):
    try:
        started = (proc / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()[19]
    except FileNotFoundError:
        return None
    return {"pid": pid, "started": started}


def validate_owner(state_path, proc):
    owner_path = state_path.parent.parent / "checkout-owner.json"
    owner = process_identity(os.getppid(), proc)
    if owner is None:
        raise ValueError("checkout task process identity is unavailable")
    if owner_path.is_symlink():
        raise ValueError("checkout task owner must not be a symlink")
    if owner_path.exists():
        previous = json.loads(owner_path.read_text())
        if previous != owner and process_identity(previous["pid"], proc) == previous:
            raise ValueError("another Ansible checkout task is still active")
    return owner_path, owner


def guarded_git(arguments, revision, holder, checkout=CHECKOUT, state_path=STATE, proc=Path("/proc"),
                *, closeout_holder="", closeout_confirmation="", closeout_token=""):
    descriptor = os.open(state_path.parent.parent / "run.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        owner_path, owner = validate_owner(state_path, proc)
        if closeout_holder or closeout_confirmation or closeout_token:
            if holder or not closeout_token:
                raise ValueError("dedicated closeout preparation requires its own exact claim")
            validate_closeout(revision, closeout_holder, closeout_confirmation, closeout_token,
                              checkout, state_path, proc, ignored_pids=(os.getppid(),))
        else:
            validate(revision, holder, checkout, state_path, proc, ignored_pids=(os.getppid(),))
        with tempfile.NamedTemporaryFile(mode="w", dir=owner_path.parent, delete=False) as temporary:
            json.dump(owner, temporary)
        try:
            os.replace(temporary.name, owner_path)
        finally:
            Path(temporary.name).unlink(missing_ok=True)
        return subprocess.run(["/usr/bin/git", *arguments], check=False, pass_fds=(descriptor,)).returncode
    finally:
        os.close(descriptor)


def main():
    if Path(__file__).name == "recipe-db-checkout-git":
        try:
            return guarded_git(sys.argv[1:], os.environ["RECIPE_DB_CHECKOUT_REVISION"],
                               os.environ.get("RECIPE_DB_CHECKOUT_HOLDER", ""),
                               closeout_holder=os.environ.get("RECIPE_DB_CLOSEOUT_HOLDER", ""),
                               closeout_confirmation=os.environ.get("RECIPE_DB_CLOSEOUT_CONFIRMATION", ""),
                               closeout_token=os.environ.get("RECIPE_DB_CLOSEOUT_TOKEN", ""))
        except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
            print(f"checkout guard: {error}", file=sys.stderr)
            return 1
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision")
    parser.add_argument("--maintenance-holder")
    parser.add_argument("--prepare-closeout", action="store_true")
    parser.add_argument("--closeout-holder")
    parser.add_argument("--closeout-confirmation")
    parser.add_argument("--closeout-token")
    parser.add_argument("--inspect-closeout-claim", action="store_true")
    args = parser.parse_args()
    if args.inspect_closeout_claim:
        if args.prepare_closeout or any(value is not None for value in (
            args.revision, args.maintenance_holder, args.closeout_holder,
            args.closeout_confirmation, args.closeout_token,
        )):
            parser.error("--inspect-closeout-claim cannot be combined with preparation or checkout arguments")
    elif args.revision is None:
        parser.error("--revision is required outside read-only claim inspection")
    try:
        if args.inspect_closeout_claim:
            print(json.dumps(inspect_closeout_claim()))
        elif args.prepare_closeout:
            if args.maintenance_holder or args.closeout_token:
                raise ValueError("preparation cannot reuse an existing command claim")
            print(json.dumps(prepare_closeout(
                args.revision, args.closeout_holder or "", args.closeout_confirmation or "",
            )))
        elif args.closeout_holder or args.closeout_confirmation or args.closeout_token:
            if args.maintenance_holder or not args.closeout_token:
                raise ValueError("dedicated closeout validation requires its own exact claim")
            validate_closeout(args.revision, args.closeout_holder or "",
                              args.closeout_confirmation or "", args.closeout_token)
        else:
            validate(args.revision, args.maintenance_holder or "")
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        print(f"checkout guard: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
