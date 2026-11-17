#!/usr/bin/env python3
"""Bounded private file operations for the workstation release controller."""

import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import stat
import subprocess
import sys


HERE = Path(__file__).resolve().parent
backup = runpy.run_path(str(HERE / (
    "recipe-db-backup-upload" if Path(__file__).name == "recipe-db-release-files" else "backup-upload.py"
)))
BASE = Path("/var/lib/recipe-db-backup")
VALUES = Path("/etc/recipe-db/backup-values.yaml")
REFERENCE = Path("/etc/recipe-db/backup-release-ref")
CHECKOUT = Path("/opt/recipe-db")
LIMIT = backup["MAX_MANIFEST_BYTES"]


def private_read(path):
    backup["absolute_path"](str(path))
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() \
            or info.st_mode & 0o077 or info.st_size > LIMIT:
        raise ValueError("private file ownership, permissions or size is invalid")
    return path.read_bytes()


def digest(content):
    return hashlib.sha256(content).hexdigest()


def managed(command, **kwargs):
    environment = {
        "PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": "/root",
        "MISE_CONFIG_DIR": "/etc/recipe-db/backup-toolchain",
        "MISE_DATA_DIR": str(BASE / "tooling/data"),
        "MISE_STATE_DIR": str(BASE / "tooling/state"),
        "MISE_CACHE_DIR": str(BASE / "tooling/cache"),
        "MISE_IGNORED_CONFIG_PATHS": str(CHECKOUT / "mise.toml"),
    }
    return subprocess.run(
        ["/usr/local/bin/mise", "exec", "--", *command], cwd=BASE,
        env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        check=True, timeout=30, **kwargs,
    ).stdout


def config_info():
    raw = private_read(VALUES)
    documents = managed(["yq", "-o=json", "eval-all", "[.]", str(VALUES)])
    canonical = managed(
        ["jq", "-e", 'if length == 1 then .[0] else error("expected one document") end'],
        input=documents,
    )
    config = json.loads(canonical)
    hashes = {}
    for key, path in config["secrets"].items():
        if key not in {"auth-accounts.json", "google-oauth-client-secret",
                       "oauth2-cookie-secret", "acme-account-email"} \
                or path != f"/etc/recipe-db/application-inputs/{key}":
            raise ValueError("unsupported installed application input")
        hashes[key] = digest(private_read(Path(path)))
    return {"values": base64.b64encode(raw).decode(), "inputs": hashes,
            "configSha256": digest(canonical)}


def write_bytes(path, content):
    temporary = path.with_name(path.name + ".release-next")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary.exists():
            temporary.unlink()


def handle(request, config):
    base = Path(config["stateDirectory"])
    maintenance = backup["maintenance_state_path"](config)
    marker = base / "release-command.json"
    state_path = maintenance / "backup-state.json"
    operation = request["operation"]
    if operation == "info":
        revision = subprocess.check_output(
            ["git", "-C", str(CHECKOUT), "rev-parse", "HEAD"], timeout=10,
        ).decode().strip()
        return dict(config_info(), fileProtocolVersion=1, toolingRevision=revision,
                    helperSha256=digest(Path(__file__).read_bytes()),
                    publisherSha256=digest(Path(backup["__file__"]).read_bytes()))
    content = private_read(state_path)
    state = json.loads(content)
    if operation == "status":
        return {key: state.get(key) for key in
                ("backupId", "status", "phase", "candidate", "toolingRevision",
                 "backupAlignment", "postReleaseBackup")}
    if operation == "evidence":
        result = {key: state.get(key) for key in
                  ("status", "phase", "candidate", "acceptedAt", "websiteCheck",
                   "postCheckDisposition")}
        result["postReleaseBackup"] = {
            key: (state.get("postReleaseBackup") or {}).get(key)
            for key in ("artifact", "revision", "status", "storageVersions")
        }
        return result
    if operation == "align":
        if marker.exists():
            raise ValueError("stop the workstation release command before backup alignment")
        candidate = state.get("candidate") or {}
        website = state.get("websiteCheck") or {}
        disposition = state.get("postCheckDisposition") or {}
        eligible = (
            (state.get("status"), state.get("phase")) == ("access-open", "website-passed")
            and website.get("outcome") == "passed"
        ) or (
            (state.get("status"), state.get("phase")) == (
                "post-check-disposition", "accept-partial-failure")
            and website.get("outcome") == "failed"
            and disposition.get("choice") == "accept-partial-failure"
        )
        revision = subprocess.check_output(
            ["git", "-C", str(CHECKOUT), "rev-parse", "HEAD"], timeout=10,
        ).decode().strip()
        if not eligible or state.get("backupId") != request["holder"] \
                or candidate.get("artifact") != request["artifact"] \
                or candidate.get("revision") != request["revision"] \
                or revision != request["revision"] or state.get("toolingRevision") != revision \
                or state.get("configSha256") != config_info()["configSha256"] \
                or state.get("postReleaseBackup") is not None:
            raise ValueError("candidate, website, tooling or unchanged backup values gate is incomplete")
        reference = private_read(REFERENCE).decode().strip()
        if reference not in (state["source"]["artifact"], candidate["artifact"]):
            raise ValueError("installed backup reference belongs to another release")
        write_bytes(REFERENCE, (candidate["artifact"] + "\n").encode())
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        write_bytes(REFERENCE.with_name("backup-configured-at"), (now + "\n").encode())
        state["backupAlignment"] = {
            "artifact": candidate["artifact"], "revision": revision, "alignedAt": now,
        }
        backup["atomic_json"](state_path, state)
        return {"status": "backup-inputs-aligned", "backupId": state["backupId"]}
    if operation == "begin":
        if marker.exists() or marker.is_symlink():
            previous = json.loads(private_read(marker))
            raise ValueError(
                f"release command already retained: {previous['holder']} {previous['token']}; "
                "confirm that workstation command stopped before abandoning its file claim"
            )
        if request["revision"] != subprocess.check_output(
            ["git", "-C", str(CHECKOUT), "rev-parse", "HEAD"], timeout=10,
        ).decode().strip():
            raise ValueError("workstation and managed Pi tooling revisions differ")
        claim = {"holder": state["backupId"], "token": request["token"],
                 "source": state["source"], "configSha256": state["configSha256"]}
        result = {"state": state, "expected": digest(content), "manifest": None, "retained": None,
                  "postManifest": None}
        for key, path in (
            ("manifest", maintenance / "manifest.json"),
            ("postManifest", maintenance / "post-release-backup/manifest.json"),
            ("retained", maintenance.with_name(maintenance.name + ".previous-runtime-secret.json")),
        ):
            if key == "retained" and request["action"] != "release-stage":
                continue
            if path.exists() or path.is_symlink():
                result[key] = json.loads(private_read(path))
        backup["atomic_json"](marker, claim)
        return result
    claim = json.loads(private_read(marker))
    if request["token"] != claim["token"] or state["backupId"] != claim["holder"]:
        raise ValueError("private file claim does not belong to this command")
    if operation == "end":
        marker.unlink()
        return {}
    if operation == "abandon":
        if request["confirmation"] != f"ABANDON-{claim['holder']}-{claim['token']}-AFTER-COMMAND-STOPPED":
            raise ValueError("abandon requires the exact holder, token and stopped-command confirmation")
        marker.unlink()
        return {}
    if digest(content) != request["expected"]:
        raise ValueError("authoritative Pi state changed; stop and inspect before continuing")
    if operation == "checkpoint":
        updated = request["state"]
        if updated["backupId"] != claim["holder"] or updated["source"] != claim["source"] \
                or updated["configSha256"] != claim["configSha256"]:
            raise ValueError("release state identity changed")
        backup["atomic_json"](state_path, updated)
        return {"expected": digest(private_read(state_path))}
    if operation == "retain":
        retained = request["retained"]
        if retained["backupId"] != claim["holder"] or retained["source"] != claim["source"]:
            raise ValueError("retained credential identity changed")
        destination = maintenance.with_name(maintenance.name + ".previous-runtime-secret.json")
        if destination.exists() or destination.is_symlink():
            if json.loads(private_read(destination)) != retained:
                raise ValueError("previous runtime credentials were already retained with different data")
        else:
            backup["atomic_json"](destination, retained)
        return {}
    if operation not in {"prune", "finalize"} or (
        state.get("status"), state.get("phase")
    ) != ("release-published", "published-cleanup-pending"):
        raise ValueError("private cleanup requires verified publication")
    if operation == "prune":
        for path in maintenance.iterdir():
            if path.name == "backup-state.json":
                continue
            if path.is_symlink():
                raise ValueError("unexpected symlink in retained release data")
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
    else:
        maintenance.with_name(maintenance.name + ".previous-runtime-secret.json").unlink(missing_ok=True)
        state_path.unlink()
        maintenance.rmdir()
        marker.unlink()
    return {}


def main():
    os.umask(0o077)
    request = json.loads(sys.stdin.buffer.readline(LIMIT + 1))
    config = backup["safe_config"]("/etc/recipe-db/backup.json")
    if request["operation"] in {"info", "status", "evidence"}:
        print(json.dumps(handle(request, config), separators=(",", ":")))
        return
    descriptor = backup["acquire_run_lock"](config)
    try:
        result = handle(request, config)
    finally:
        os.close(descriptor)
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError,
            backup["BackupError"]) as error:
        print(f"release files: {error}", file=sys.stderr)
        sys.exit(1)
