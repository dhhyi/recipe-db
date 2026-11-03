"""Run the isolated cache experiment; all generated state lives in a new /tmp directory."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

from merge import Invalid, merge, references, snapshot


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def entry(cache, kind, key):
    return cache / kind / key[:2] / key


def outputs(output_base):
    directory = output_base / "execroot/cache_union/bazel-out/k8-fastbuild/bin"
    return {
        path.name: {
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "executable": bool(path.stat().st_mode & 0o111),
        }
        for path in directory.glob("*.out")
    }


def run():
    work = Path(tempfile.mkdtemp(prefix="bazel-cache-merge-"))
    print(f"Evidence directory: {work}", flush=True)
    workspace = work / "workspace"
    shutil.copytree(HERE / "fixture", workspace)
    (workspace / ".scripts").mkdir()
    for source, target in ((".scripts/bazel.sh", ".scripts/bazel.sh"),
                           ("mise.toml", "mise.toml"), (".bazelversion", ".bazelversion")):
        shutil.copyfile(ROOT / source, workspace / target)
    (workspace / "WORKSPACE").write_text('workspace(name = "cache_union")\n')
    launcher = workspace / ".scripts/bazel.sh"
    version = subprocess.check_output(
        ["bash", str(launcher), "--batch", "version"], cwd=workspace, text=True
    )
    (work / "version.txt").write_text(version)
    assert "Build label: " + (ROOT / ".bazelversion").read_text().strip() in version
    evidence = {}

    def build(name, cache, targets, expected=None):
        base = work / f"output-{name}"
        assert not base.exists()
        command = [
            "bash", str(launcher), "--batch", "--ignore_all_rc_files",
            "--host_jvm_args=-Dbazel.DigestFunction=SHA256",
            f"--output_base={base}", "build", "--enable_bzlmod=false",
            "--enable_workspace=true", "--incompatible_autoload_externally=",
            "--action_env=PATH",
            "--remote_verify_downloads=true", f"--disk_cache={cache}",
            f"--execution_log_json_file={work / (name + '-execution.json')}",
        ] + targets
        result = subprocess.run(command, cwd=workspace, text=True, capture_output=True)
        (work / f"{name}.log").write_text(result.stdout + result.stderr)
        (work / f"{name}-command.json").write_text(json.dumps(command, indent=2))
        log = work / f"{name}-execution.json"
        # The expanded execution log is a stream of JSON objects, not an array.
        records = []
        if log.exists():
            text = log.read_text()
            decoder = json.JSONDecoder()
            while text.strip():
                record, end = decoder.raw_decode(text.lstrip())
                records.append(record)
                text = text.lstrip()[end:]
        executed = sorted(
            r["targetLabel"] for r in records
            if r.get("mnemonic") in ("Genrule", "CacheUnion") and not r.get("cacheHit", False)
        )
        hits = sorted(
            r["targetLabel"] for r in records
            if r.get("mnemonic") in ("Genrule", "CacheUnion") and r.get("cacheHit", False)
        )
        evidence[name] = {
            "returncode": result.returncode, "executed": executed,
            "hits": hits, "outputs": outputs(base),
        }
        print(name, json.dumps(evidence[name]), flush=True)
        (work / "evidence.json").write_text(json.dumps(evidence, indent=2))
        if expected is not None:
            assert result.returncode == 0, result.stderr
            assert executed == sorted(expected), (name, executed, expected)
        return base

    main, pr = work / "main", work / "pr"
    build("main", main, ["//:shared", "//:main"], ["//:main", "//:shared"])
    build("pr", pr, ["//:shared", "//:pr"], ["//:pr", "//:shared"])
    union = work / "union"
    evidence["merge"] = merge(main, pr, union)
    with tarfile.open(work / "union.tar.gz", "w:gz") as archive:
        archive.add(union, arcname="cache")
    evidence["merge"]["archive_bytes"] = (work / "union.tar.gz").stat().st_size
    # Every consumer gets its own copy, keeping completed source snapshots unchanged.
    def copied(name):
        cache = work / f"cache-{name}"
        shutil.copytree(union, cache)
        return cache

    build("combined", copied("combined"), ["//:combined"], ["//:combined"])
    assert evidence["combined"]["hits"] == ["//:main", "//:pr", "//:shared"]
    build("clean", work / "clean", ["//:combined"],
          ["//:combined", "//:main", "//:pr", "//:shared"])
    assert evidence["combined"]["outputs"] == evidence["clean"]["outputs"]
    assert evidence["combined"]["outputs"]["main.out"]["executable"]
    assert not evidence["combined"]["outputs"]["pr.out"]["executable"]
    assert not evidence["combined"]["outputs"]["shared.out"]["executable"]
    (workspace / "pr.txt").write_text("pr changed\n")
    build("changed", copied("changed"), ["//:combined"], ["//:combined", "//:pr"])
    assert evidence["changed"]["hits"] == ["//:main", "//:shared"]
    build("changed-clean", work / "changed-clean", ["//:combined"],
          ["//:combined", "//:main", "//:pr", "//:shared"])
    assert evidence["changed"]["outputs"] == evidence["changed-clean"]["outputs"]
    (workspace / "pr.txt").write_text("pr\n")

    # Find real AC entries by declared output, not guessed action hashes.
    entries, _ = snapshot(main)
    main_key = next(
        key for key, data in entries["ac"].items() if b"main.out" in data
    )
    blob_key, _ = references(entries["ac"][main_key])[0]
    for name in ("missing", "corrupt", "malformed"):
        cache = copied(name)
        if name == "missing":
            entry(cache, "cas", blob_key).unlink()
        elif name == "corrupt":
            entry(cache, "cas", blob_key).write_bytes(b"broken\n")
        else:
            entry(cache, "ac", main_key).write_bytes(b"\x12\xff")
        try:
            merge(cache, pr, work / f"rejected-{name}")
        except Invalid as error:
            evidence[f"merge-{name}"] = str(error).replace(str(work), "$WORK")
        else:
            raise AssertionError(f"merger accepted {name}")
        build(name, cache, ["//:combined"])
        # A success is only safe when the damaged action actually ran and bytes/modes match.
        if evidence[name]["returncode"] == 0:
            assert "//:main" in evidence[name]["executed"], evidence[name]
            assert evidence[name]["outputs"] == evidence["clean"]["outputs"]

    # Same action key, different valid metadata; main's result is retained.
    altered = work / "altered"
    shutil.copytree(main, altered)
    ac = entry(altered, "ac", main_key)
    ac.write_bytes(ac.read_bytes() + b"\x2a\x09alternate")  # stdout_raw, field 5
    conflict = work / "conflict"
    evidence["conflict"] = merge(main, altered, conflict)
    assert entry(conflict, "ac", main_key).read_bytes() == entries["ac"][main_key]
    build("conflict", conflict, ["//:main"], [])
    (work / "evidence.json").write_text(json.dumps(evidence, indent=2))
    print("PASS; evidence retained at", work, flush=True)
    return work


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
    run()
