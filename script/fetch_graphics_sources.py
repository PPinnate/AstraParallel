#!/usr/bin/env python3
"""Fetch hash-pinned source and apply Astra patches without building or deploying."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "script/graphics-sources.lock.json"

def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

def safe_extract(archive, destination, prefix):
    """Extract only contained regular files/directories and safe relative links."""
    links = []
    with tarfile.open(archive, "r|gz") as stream:
        for member in stream:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or not name.parts or name.parts[0] != prefix:
                raise RuntimeError("Unsafe or unexpected archive member")
            rel = Path(*name.parts[1:])
            if not rel.parts:
                continue
            target = destination / rel
            if not target.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError("Archive path escapes destination")
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o755 if member.mode & stat.S_IXUSR else 0o644)
            elif member.issym():
                link = Path(member.linkname)
                if link.is_absolute() or not (target.parent / link).resolve().is_relative_to(destination.resolve()):
                    raise RuntimeError("Archive symlink escapes destination")
                links.append((target, member.linkname))
            else:
                raise RuntimeError("Unsupported archive member type")
    for target, value in links:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(value)

def verify_changes(tree, records):
    for name, record in records.items():
        path = tree / name
        if record["mode"] == "120000":
            data = os.readlink(path).encode()
            actual_mode = "120000"
        else:
            if not path.is_file() or path.is_symlink():
                raise RuntimeError("Missing expected source file: " + name)
            data = path.read_bytes()
            actual_mode = "100755" if path.stat().st_mode & stat.S_IXUSR else "100644"
        if hashlib.sha256(data).hexdigest() != record["sha256"] or actual_mode != record["mode"]:
            raise RuntimeError("Patched source does not match the recorded hash/mode: " + name)

def reconstruct(name, record, state, archive_directory):
    parent = ROOT / "vendor/graphics"
    destination = parent / name
    if destination.exists() or destination.is_symlink():
        raise RuntimeError("Refusing to overwrite existing source: vendor/graphics/" + name)
    archive = archive_directory / record["archive_name"]
    if not archive.is_file():
        raise RuntimeError("Source archive unavailable: " + record["archive_name"])
    if digest(archive) != record["archive_sha256"]:
        raise RuntimeError("Source archive SHA-256 mismatch: " + name)
    with tempfile.TemporaryDirectory(prefix=".fetch-", dir=parent) as scratch:
        tree = Path(scratch) / name
        tree.mkdir()
        safe_extract(archive, tree, record["archive_root"])
        labels = ["baseline"] + (["development"] if state == "development" else [])
        patch_environment = dict(os.environ)
        # Apply relative to this extracted source, even inside a parent clone.
        patch_environment["GIT_CEILING_DIRECTORIES"] = str(tree.parent.resolve())
        for label in labels:
            patch = ROOT / record[label + "_patch"]
            if digest(patch) != record[label + "_patch_sha256"]:
                raise RuntimeError("Patch SHA-256 mismatch: " + name + " / " + label)
            if patch.stat().st_size:
                subprocess.run(["git", "apply", "--check", str(patch)], cwd=tree, env=patch_environment, check=True)
                subprocess.run(["git", "apply", str(patch)], cwd=tree, env=patch_environment, check=True)
            verify_changes(tree, record[label + "_files"])
        for p in tree.rglob("*"):
            if p.is_symlink() and (not p.resolve().is_relative_to(tree.resolve()) or not p.resolve().exists()):
                raise RuntimeError("Reconstructed source contains an escaping or broken link")
        tree.rename(destination)
    print(json.dumps({"component": name, "state": state, "archive_verified": True,
                      "patches_verified": labels, "destination": "vendor/graphics/" + name}), flush=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", choices=["all", "dxmt", "virglrenderer", "neptune"], default="all")
    parser.add_argument("--state", choices=["baseline", "development"], default="baseline")
    parser.add_argument("--offline-archives", type=Path)
    args = parser.parse_args()
    records = json.loads(LOCK.read_text())["components"]
    names = list(records) if args.component == "all" else [args.component]
    parent = ROOT / "vendor/graphics"
    parent.mkdir(parents=True, exist_ok=True)
    for name in names:
        if (parent / name).exists() or (parent / name).is_symlink():
            raise RuntimeError("Source already exists; use a separate workspace: " + name)
    if args.offline_archives:
        for name in names:
            reconstruct(name, records[name], args.state, args.offline_archives.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix=".fetch-download-", dir=parent) as scratch:
            directory = Path(scratch)
            for name in names:
                record = records[name]
                if not record["archive_url"].startswith("https://github.com/"):
                    raise RuntimeError("Source URL is outside the pinned GitHub upstreams")
                request = urllib.request.Request(record["archive_url"], headers={"User-Agent": "AstraParallel-source-fetch"})
                archive = directory / record["archive_name"]
                print("Downloading pinned " + name + " source", flush=True)
                with urllib.request.urlopen(request, timeout=60) as response, archive.open("xb") as output:
                    shutil.copyfileobj(response, output)
                reconstruct(name, record, args.state, directory)

if __name__ == "__main__":
    main()
