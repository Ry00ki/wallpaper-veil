"""Read-only checks for a relocatable, self-contained macOS app and its ZIP.

This checks bundle paths and native load commands, not application startup,
Gatekeeper acceptance, permissions, hardware behavior or arbitrary Lua execution.
"""
from __future__ import annotations

import plistlib
import posixpath
import re
import stat
import subprocess
import zipfile
from pathlib import Path, PurePosixPath
from typing import Callable

MACHO_MAGIC = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}
_LOAD_COMMANDS = {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
                  "LC_LAZY_LOAD_DYLIB", "LC_LOAD_UPWARD_DYLIB"}


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def _within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _system(path: str | Path) -> bool:
    value = posixpath.normpath(str(path))
    return value.startswith("/System/Library/") or value.startswith("/usr/lib/")


def inspect_macho(path: Path) -> dict:
    """Return each architecture's real load dependencies and runpaths on macOS."""
    architectures = subprocess.check_output(
        ["/usr/bin/lipo", "-archs", str(path)], text=True).strip().split()
    _require(bool(architectures), "A native executable has no declared architectures")
    output = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True)
    result = {arch: {"dependencies": [], "rpaths": []} for arch in architectures}
    current, command = architectures[0], None
    for line in output.splitlines():
        header = re.search(r"\(architecture ([^)]+)\):$", line)
        if header:
            current, command = header.group(1), None
            _require(current in result, "Inconsistent native architecture inspection")
            continue
        value = line.strip()
        if value.startswith("cmd "):
            command = value[4:]
        elif command == "LC_RPATH" and value.startswith("path "):
            result[current]["rpaths"].append(value[5:].rsplit(" (offset ", 1)[0])
            command = None
        elif command in _LOAD_COMMANDS and value.startswith("name "):
            result[current]["dependencies"].append(value[5:].rsplit(" (offset ", 1)[0])
            command = None
    return result


def _main_executable(binary: Path, app: Path) -> Path:
    for parent in binary.parents:
        if parent.suffix in {".app", ".xpc"}:
            info_path = parent / "Contents/Info.plist"
            _require(info_path.is_file(), "An executable app container has no Info.plist")
            info = plistlib.loads(info_path.read_bytes())
            name = info.get("CFBundleExecutable")
            _require(isinstance(name, str) and name and Path(name).name == name,
                     "An app container has an invalid executable name")
            executable = (parent / "Contents/MacOS" / name).resolve()
            _require(_within(executable, app) and executable.is_file()
                     and bool(executable.stat().st_mode & 0o111),
                     "An app container's executable is missing or outside the app")
            return executable
    raise RuntimeError("A native component has no containing application")


def _expand(value: str, binary: Path, executable: Path, app: Path) -> Path:
    if value == "@loader_path" or value.startswith("@loader_path/"):
        target = binary.parent / value[len("@loader_path"):].lstrip("/")
    elif value == "@executable_path" or value.startswith("@executable_path/"):
        target = executable.parent / value[len("@executable_path"):].lstrip("/")
    elif value.startswith("/") and _system(value):
        return Path(posixpath.normpath(value))
    else:
        raise RuntimeError("A native component declares an external or unsupported load path")
    target = target.resolve()
    _require(_within(target, app) or _system(target),
             "A native load path escapes the application bundle")
    return target


def audit_bundle(app: Path, *, inspector: Callable[[Path], dict] = inspect_macho) -> dict:
    """Reject external/absolute symlinks and unresolved non-system native loads.

    ``inspector`` is injectable for portable fixture tests. Actual packaging uses
    lipo/otool against every Mach-O file, without executing application code.
    """
    app = Path(app).expanduser().absolute()
    _require(not app.is_symlink() and app.is_dir() and app.suffix == ".app",
             "Expected a real app bundle directory")
    app = app.resolve()
    binaries, links = [], 0
    for path in app.rglob("*"):
        if path.is_symlink():
            links += 1
            _require(not Path(path.readlink()).is_absolute(),
                     "An absolute bundle symlink prevents relocation")
            try:
                destination = path.resolve(strict=True)
            except (OSError, RuntimeError) as error:
                raise RuntimeError("A bundle symlink is dangling or cyclic") from error
            _require(_within(destination, app), "A bundle symlink escapes the app")
        elif path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC:
                    binaries.append(path.resolve())
        else:
            _require(path.is_dir(), "An app bundle contains a special filesystem entry")
    _require(bool(binaries), "The app bundle contains no native executables")
    inspected = {path: inspector(path) for path in binaries}
    checked_dependencies, checked_rpaths = 0, 0
    for binary, slices in inspected.items():
        _require(isinstance(slices, dict) and bool(slices), "Native architecture data is missing")
        executable = _main_executable(binary, app)
        _require(executable in inspected, "An app's main executable is not a bundled native binary")
        for arch, facts in slices.items():
            _require(arch in inspected[executable], "A component architecture lacks an app executable")
            values = [*facts["rpaths"], *inspected[executable][arch]["rpaths"]]
            rpaths = [_expand(value, binary if index < len(facts["rpaths"]) else executable,
                               executable, app) for index, value in enumerate(values)]
            checked_rpaths += len(facts["rpaths"])
            for dependency in facts["dependencies"]:
                checked_dependencies += 1
                if dependency.startswith("/"):
                    _require(_system(dependency), "A native dependency requires software outside macOS/the app")
                    continue
                if dependency.startswith("@rpath/"):
                    suffix = dependency[len("@rpath/"):]
                    candidates = [(base / suffix).resolve() for base in rpaths]
                else:
                    candidates = [_expand(dependency, binary, executable, app)]
                resolved = False
                for candidate in candidates:
                    if _system(candidate):
                        resolved = True  # System libraries may live in the dyld shared cache.
                        break
                    if (_within(candidate, app) and candidate.is_file()
                            and candidate in inspected and arch in inspected[candidate]):
                        resolved = True
                        break
                _require(resolved, "A native dependency cannot resolve to macOS or a bundled matching-architecture binary")
    return {"schema": 1, "bundle_paths_internal": True, "relative_symlinks_checked": links,
            "native_binary_count": len(binaries), "native_dependencies_checked": checked_dependencies,
            "native_runpaths_checked": checked_rpaths, "native_dependency_closure_verified": True,
            "application_launched": False, "relocated_launch_tested": False}


def _member_name(value: str) -> str:
    _require(isinstance(value, str) and value and not value.startswith("/")
             and not any(char in value for char in ("\\", "\x00", ":")),
             "Unsafe application ZIP path")
    value = value[:-1] if value.endswith("/") else value
    _require(all(part not in ("", ".", "..") for part in value.split("/")),
             "Unsafe application ZIP path")
    return value


def validate_archive(archive: Path, expected_root: str = "Wallpaper Veil.app") -> dict:
    """Verify one complete top-level app and internal, relocatable ZIP symlinks."""
    _require(_member_name(expected_root) == expected_root and "/" not in expected_root
             and expected_root.endswith(".app"), "Invalid expected application ZIP root")
    with zipfile.ZipFile(archive) as source:
        members, links = {}, {}
        for item in source.infolist():
            name = _member_name(item.filename)
            _require(name.split("/", 1)[0] == expected_root,
                     "The application ZIP must contain only one top-level app")
            _require(name not in members, "Duplicate application ZIP entry")
            members[name] = item
            mode = item.external_attr >> 16
            kind = stat.S_IFMT(mode)
            _require(kind in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK),
                     "The application ZIP contains a special filesystem entry")
            if stat.S_ISLNK(mode):
                try:
                    target = source.read(item).decode("utf-8")
                except UnicodeError as error:
                    raise RuntimeError("Invalid ZIP symlink target") from error
                _require(target and not target.startswith("/")
                         and not any(char in target for char in ("\\", "\x00", ":")),
                         "An application ZIP symlink is absolute or invalid")
                links[name] = target

        def resolve(name: str) -> str:
            pending = list(PurePosixPath(name).parts)
            parts, seen = [], set()
            while pending:
                part = pending.pop(0)
                if part in ("", "."):
                    continue
                if part == "..":
                    _require(len(parts) > 1, "An application ZIP symlink escapes its app")
                    parts.pop()
                    continue
                parts.append(part)
                current = "/".join(parts)
                if current in links:
                    _require(current not in seen, "Cyclic application ZIP symlink")
                    seen.add(current)
                    pending = list(PurePosixPath(links[current]).parts) + pending
                    parts.pop()
            resolved = "/".join(parts)
            _require(resolved == expected_root or resolved.startswith(expected_root + "/"),
                     "An application ZIP symlink escapes its app")
            return resolved

        for name in links:
            target = resolve(name)
            _require(target in members or any(member.startswith(target + "/") for member in members),
                     "Dangling application ZIP symlink")
        info_name = expected_root + "/Contents/Info.plist"
        _require(info_name in members, "The application ZIP has no app metadata")
        info = plistlib.loads(source.read(members[info_name]))
        executable = info.get("CFBundleExecutable")
        _require(isinstance(executable, str) and executable and PurePosixPath(executable).name == executable,
                 "The application ZIP has an invalid executable declaration")
        executable_name = expected_root + "/Contents/MacOS/" + executable
        _require(executable_name in members and resolve(executable_name) in members,
                 "The application ZIP has no declared executable")
    return {"single_app_root_verified": True, "root": expected_root,
            "entries_checked": len(members), "internal_symlinks_checked": len(links)}
