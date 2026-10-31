"""Pinned upstream build inputs, recovered from retained Git history.

The maintained checkout contains product code, not a second full Hammerspoon
source tree. Native engine compilation still uses the audited historical tag.
Only declared headers and legal documents are materialized for product builds.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess

POLICY_PATH = Path(__file__).resolve().parents[1] / "engine/upstream.json"
# Qualification boundary, not an independently configurable version. A baseline
# or input change requires a reviewed policy/digest and engine requalification.
# Descriptive integration-map edits update this digest without changing the
# pinned native baseline, build recipe or retained input qualification.
QUALIFIED_POLICY_SHA256 = "89a78d40ab7fb6c8aec5e53bed2307b83f28a443fb1c8b783a6e560a2fd7ff91"


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def _relative(value: object) -> str:
    _require(isinstance(value, str) and bool(value), "Invalid upstream input path")
    path = PurePosixPath(value)
    _require(not path.is_absolute() and path.as_posix() == value
             and all(part not in ("", ".", "..") for part in path.parts)
             and not any(char in value for char in ("\\", "\x00", "\n", "\r", ":")),
             "Unsafe upstream input path")
    return value


def _entry(value: object) -> dict:
    _require(isinstance(value, dict) and set(value) == {"path", "blob", "mode"},
             "Invalid upstream object declaration")
    _relative(value["path"])
    _require(isinstance(value["blob"], str) and re.fullmatch(r"[0-9a-f]{40}", value["blob"]) is not None,
             "Invalid upstream Git blob identity")
    _require(value["mode"] in ("100644", "100755"), "Upstream inputs must be regular files")
    return value


def object_entries(policy: dict, *, include_bootstrap: bool = False) -> list[dict]:
    values = [*policy["headers"], *policy["componentNotices"],
              *policy["podAcknowledgements"], policy["licence"]]
    if include_bootstrap:
        values.append(policy["qualification"]["bootstrap"])
    return values


def load_policy(project: Path | None = None) -> dict:
    """Read the single qualified policy; reject silent native-origin changes."""
    path = Path(project) / "engine/upstream.json" if project is not None else POLICY_PATH
    _require(path.is_file() and not path.is_symlink() and not path.parent.is_symlink(),
             "The qualified engine/upstream.json is missing or symlinked")
    raw = path.read_bytes()
    _require(hashlib.sha256(raw).hexdigest() == QUALIFIED_POLICY_SHA256,
             "Upstream policy changed; review and qualify the new engine inputs")
    try:
        policy = json.loads(raw)
    except (ValueError, UnicodeError) as error:
        raise RuntimeError("Invalid upstream policy JSON") from error
    keys = {"schema", "upstream", "qualification", "patches", "headers", "componentNotices",
            "podAcknowledgements", "licence", "retiredSourcePaths", "maintainedEngineFiles", "integration"}
    _require(isinstance(policy, dict) and set(policy) == keys
             and type(policy["schema"]) is int and policy["schema"] == 1,
             "Unsupported upstream policy schema")
    origin = policy["upstream"]
    _require(isinstance(origin, dict) and set(origin) == {"repository", "tag", "commit", "tree", "build"},
             "Invalid upstream origin declaration")
    _require(origin["repository"] == "https://github.com/Hammerspoon/hammerspoon.git"
             and isinstance(origin["tag"], str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", origin["tag"]) is not None
             and isinstance(origin["build"], str) and re.fullmatch(r"[1-9][0-9]*", origin["build"]) is not None,
             "Unqualified upstream repository/version/build")
    for name in ("commit", "tree"):
        _require(isinstance(origin[name], str) and re.fullmatch(r"[0-9a-f]{40}", origin[name]) is not None,
                 "Invalid upstream commit/tree identity")
    _require(policy["patches"] == [], "No native engine patches are qualified for this baseline")
    qualification = policy["qualification"]
    _require(isinstance(qualification, dict)
             and set(qualification) == {"nativeBinaryCount", "componentNoticeCount", "architectures", "bootstrap"},
             "Invalid engine qualification declaration")
    for name in ("nativeBinaryCount", "componentNoticeCount"):
        _require(type(qualification[name]) is int and qualification[name] > 0,
                 "Invalid engine qualification inventory count")
    _require(qualification["architectures"] == ["arm64", "x86_64"],
             "The qualified native engine must support both architectures")
    _require(isinstance(policy["headers"], list) and len(policy["headers"]) == 3,
             "The qualified Lua C header inventory changed")
    _require(isinstance(policy["componentNotices"], list)
             and len(policy["componentNotices"]) == qualification["componentNoticeCount"],
             "The qualified component legal inventory changed")
    _require(isinstance(policy["podAcknowledgements"], list) and len(policy["podAcknowledgements"]) == 2,
             "The qualified Pods acknowledgement inventory changed")
    entries = [_entry(value) for value in object_entries(policy, include_bootstrap=True)]
    _require(len({value["path"] for value in entries}) == len(entries),
             "Duplicate upstream input declaration")
    for key in ("retiredSourcePaths", "maintainedEngineFiles"):
        _require(isinstance(policy[key], list) and bool(policy[key])
                 and all(isinstance(value, str) for value in policy[key])
                 and len(set(policy[key])) == len(policy[key]), "Invalid engine layout declaration")
        for value in policy[key]:
            _relative(value)
    _require("engine/upstream.json" in policy["maintainedEngineFiles"], "Policy must declare its own input path")
    return policy


def policy_identity(policy: dict) -> dict:
    """Portable provenance; never include an extracted developer path."""
    return {"policyPath": "engine/upstream.json", "policySHA256": QUALIFIED_POLICY_SHA256,
            **policy["upstream"], "patches": list(policy["patches"])}


def _git(project: Path, *args: str) -> bytes:
    return subprocess.check_output(["/usr/bin/git", "-C", str(project), *args], stderr=subprocess.PIPE)


def _git_text(project: Path, *args: str) -> str:
    return _git(project, *args).decode("utf-8").strip()


def _tree(project: Path, commit: str, paths: list[str]) -> dict[str, tuple[str, str, str]]:
    result = {}
    for record in _git(project, "ls-tree", "-rz", commit, "--", *paths).split(b"\x00"):
        if not record:
            continue
        metadata, name = record.split(b"\t", 1)
        mode, kind, blob = metadata.decode("ascii").split()
        result[name.decode("utf-8")] = (mode, kind, blob)
    return result


def validate_checkout(project: Path, *, expected_commit: str | None = None) -> dict:
    """Verify retained history and prohibit unregistered native override trees."""
    project = Path(project).resolve()
    policy = load_policy(project)
    origin = policy["upstream"]
    if expected_commit is not None:
        _require(expected_commit == origin["commit"], "Caller and qualified upstream source disagree")
    _require(_git_text(project, "rev-parse", f"refs/tags/{origin['tag']}^{{commit}}") == origin["commit"],
             "The retained upstream tag does not match the qualified commit")
    _require(_git_text(project, "rev-parse", origin["commit"] + "^{tree}") == origin["tree"],
             "The retained upstream source tree does not match qualification")
    _git(project, "merge-base", "--is-ancestor", origin["commit"], "HEAD")
    for relative in policy["retiredSourcePaths"]:
        path = project / relative
        _require(not path.exists() and not path.is_symlink(),
                 f"Unregistered native override at {relative}; use a reviewed engine policy/recipe")
    _require(not _git_text(project, "ls-files", "--cached", "--", *policy["retiredSourcePaths"]),
             "Retired upstream source remains in the maintained Git index")
    allowed = set(policy["maintainedEngineFiles"])
    for path in (project / "engine").rglob("*"):
        _require(not path.is_symlink(), "Engine metadata must not contain symlinks")
        if path.is_file():
            _require(path.relative_to(project).as_posix() in allowed,
                     "Undeclared engine file or patch; qualify it before building")
    entries = object_entries(policy, include_bootstrap=True)
    actual = _tree(project, origin["commit"], [value["path"] for value in entries])
    expected = {value["path"]: (value["mode"], "blob", value["blob"]) for value in entries}
    _require(actual == expected, "Pinned upstream header/legal/bootstrap objects do not match policy")
    stems = ("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "UNLICENSE")
    inventory = _tree(project, origin["commit"], ["extensions", "LuaSkin", "Pods"])
    legal = set()
    for path, (mode, kind, blob) in inventory.items():
        name = PurePosixPath(path).name.upper()
        conventional = any(name == stem or any(name.startswith(stem + separator)
                           for separator in ".-_") for stem in stems)
        if conventional or path == "LuaSkin/lua-5.4.7/doc/readme.html":
            _require(kind == "blob" and mode in ("100644", "100755"),
                     "Pinned component legal documents must be regular files")
            legal.add(path)
    _require(legal == {value["path"] for value in policy["componentNotices"]},
             "Pinned component legal inventory is incomplete")
    return policy


def read_object(project: Path, policy: dict, entry: dict) -> bytes:
    """Retrieve and content-verify one regular Git object without a checkout."""
    _entry(entry)
    raw = _git(Path(project), "show", policy["upstream"]["commit"] + ":" + entry["path"])
    blob = hashlib.sha1(b"blob " + str(len(raw)).encode("ascii") + b"\x00" + raw).hexdigest()
    _require(blob == entry["blob"], "Materialized upstream object does not match its declared identity")
    return raw


def materialize_inputs(project: Path, destination: Path) -> dict:
    """Recover only declared headers/notices to an empty build staging folder."""
    policy = validate_checkout(project)
    destination = Path(destination)
    _require(not destination.is_symlink(), "Upstream staging must not be a symlink")
    _require(not destination.exists() or (destination.is_dir() and not any(destination.iterdir())),
             "Upstream inputs require a fresh empty staging directory")
    destination.mkdir(parents=True, exist_ok=True)
    files = []
    for entry in sorted(object_entries(policy), key=lambda value: value["path"]):
        raw = read_object(project, policy, entry)
        target = destination / entry["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
        target.chmod(0o755 if entry["mode"] == "100755" else 0o644)
        files.append({**entry, "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)})
    return {"root": destination, "policy": policy, "identity": policy_identity(policy), "files": files}


DEFAULT_POLICY = load_policy()
SOURCE_COMMIT = DEFAULT_POLICY["upstream"]["commit"]
ENGINE_TAG = DEFAULT_POLICY["upstream"]["tag"]
ENGINE_BUILD = DEFAULT_POLICY["upstream"]["build"]
EXPECTED_ARCHITECTURES = set(DEFAULT_POLICY["qualification"]["architectures"])
