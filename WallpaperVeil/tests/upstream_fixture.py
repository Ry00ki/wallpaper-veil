"""Small Git-history fixture for upstream verification; no native builds."""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

import upstream


def make_project(directory: Path) -> tuple[Path, str, str]:
    project = directory / "project"
    project.mkdir()
    policy = copy.deepcopy(upstream.DEFAULT_POLICY)
    for entry in upstream.object_entries(policy, include_bootstrap=True):
        raw = b"fixture setup\n" if entry["path"] == "Hammerspoon/setup.lua" else ("fixture: " + entry["path"] + "\n").encode()
        path = project / entry["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        path.chmod(0o755 if entry["mode"] == "100755" else 0o644)
        entry["blob"] = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\x00" + raw).hexdigest()
    def git(*args: str) -> str:
        return subprocess.check_output(["/usr/bin/git", "-C", str(project), *args], text=True).strip()
    subprocess.run(["/usr/bin/git", "init", "-q", str(project)], check=True)
    git("add", ".")
    git("-c", "user.name=Wallpaper Veil tests", "-c", "user.email=tests@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-qm", "fixture native baseline")
    commit = git("rev-parse", "HEAD")
    policy["upstream"].update(commit=commit, tree=git("rev-parse", "HEAD^{tree}"))
    git("tag", policy["upstream"]["tag"])
    for relative in policy["retiredSourcePaths"]:
        path = project / relative
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()
    (project / "engine").mkdir()
    raw = (json.dumps(policy, indent=2) + "\n").encode()
    (project / "engine/upstream.json").write_bytes(raw)
    git("add", "-A")
    git("-c", "user.name=Wallpaper Veil tests", "-c", "user.email=tests@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-qm", "fixture product-only checkout")
    return project, commit, hashlib.sha256(raw).hexdigest()
