"""Verify runtime identity and retain the origin of copied native code."""
from __future__ import annotations

import hashlib
import json
import os
import posixpath
from pathlib import Path, PurePosixPath
import plistlib
import re
import struct
import stat
import subprocess
import zipfile

from upstream import (SOURCE_COMMIT, ENGINE_TAG, ENGINE_BUILD, EXPECTED_ARCHITECTURES,
                      validate_checkout, policy_identity)


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
        return digest.hexdigest()


def _sha(value: object, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise RuntimeError(f"Invalid {label} SHA-256")
    return value


def architectures(path: Path) -> list[str]:
    """Read Mach-O CPU types without executing the supplied native binary."""
    with path.open("rb") as stream:
        header = stream.read(8)
        if len(header) != 8:
            raise RuntimeError(f"Truncated native executable: {path.name}")
        magic = header[:4]
        if magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                     b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
            endian = ">" if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf") else "<"
            count = struct.unpack(endian + "I", header[4:])[0]
            if not 1 <= count <= 32:
                raise RuntimeError("Invalid universal architecture count")
            width = 32 if magic in (b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca") else 20
            entries = stream.read(count * width)
            if len(entries) != count * width:
                raise RuntimeError("Truncated universal architecture table")
            cpus = [struct.unpack_from(endian + "I", entries, i * width)[0] for i in range(count)]
        elif magic in (b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
                       b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe"):
            endian = ">" if magic in (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf") else "<"
            cpus = [struct.unpack(endian + "I", header[4:])[0]]
        else:
            raise RuntimeError("Runtime executable is not Mach-O")
    names = {0x01000007: "x86_64", 0x0100000C: "arm64"}
    if len(cpus) != len(set(cpus)) or any(cpu not in names for cpu in cpus):
        raise RuntimeError("Unsupported or duplicate runtime architecture")
    return sorted(names[cpu] for cpu in cpus)


def _command(*args: object) -> str:
    result = subprocess.run([str(a) for a in args], check=True, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.stdout.strip()


def verify_archive_bundle(archive_path: Path, runtime: Path) -> None:
    """Bind every file and symlink of the extracted input to its source ZIP."""
    root = runtime.resolve()
    expected = {}
    try:
        with zipfile.ZipFile(archive_path) as archive:
            aliases = set()
            for entry in archive.infolist():
                name = entry.filename
                normalized = name.rstrip("/")
                path = PurePosixPath(normalized)
                if (not normalized or path.is_absolute() or ".." in path.parts
                        or "\\" in name or "\x00" in name
                        or posixpath.normpath(normalized) != normalized
                        or not path.parts or path.parts[0] != "Hammerspoon.app"):
                    raise RuntimeError("Unsafe path in source-engine archive")
                alias = normalized.casefold()
                if alias in aliases:
                    raise RuntimeError("Duplicate or ambiguous path in source-engine archive")
                aliases.add(alias)
                kind = stat.S_IFMT(entry.external_attr >> 16)
                directory = entry.is_dir() or kind == stat.S_IFDIR
                if normalized == "Hammerspoon.app":
                    if not directory:
                        raise RuntimeError("Source-engine archive root must be a directory")
                    continue
                relative = PurePosixPath(*path.parts[1:]).as_posix()
                if kind == stat.S_IFLNK:
                    if entry.file_size > 4096:
                        raise RuntimeError("Invalid source-engine symlink target")
                    target = archive.read(entry).decode("utf-8")
                    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(relative), target))
                    if (not target or posixpath.isabs(target) or "\\" in target
                            or resolved == ".." or resolved.startswith("../")):
                        raise RuntimeError("Source-engine symlink escapes its bundle")
                    expected[relative] = ("symlink", target, entry)
                elif directory:
                    expected[relative] = ("directory", None, entry)
                elif kind in (0, stat.S_IFREG):
                    expected[relative] = ("file", None, entry)
                else:
                    raise RuntimeError("Unsupported source-engine archive entry type")
            # Some ZIP writers omit explicit directory entries.
            for relative in list(expected):
                for parent in PurePosixPath(relative).parents:
                    if parent == PurePosixPath("."):
                        break
                    name = parent.as_posix()
                    if name in expected and expected[name][0] != "directory":
                        raise RuntimeError("Archive entry descends through a non-directory")
                    expected.setdefault(name, ("directory", None, None))
            actual = {path.relative_to(runtime).as_posix(): path for path in runtime.rglob("*")}
            if set(actual) != set(expected):
                raise RuntimeError("Extracted source-engine inventory differs from its archive")
            for relative, path in actual.items():
                try:
                    if not path.resolve(strict=True).is_relative_to(root):
                        raise RuntimeError("Extracted source-engine symlink escapes its bundle")
                except (OSError, RuntimeError) as error:
                    raise RuntimeError("Invalid or escaping source-engine bundle path") from error
                kind, target, entry = expected[relative]
                if kind == "symlink":
                    if not path.is_symlink() or os.readlink(path) != target:
                        raise RuntimeError("Extracted source-engine symlink differs from its archive")
                elif kind == "directory":
                    if path.is_symlink() or not path.is_dir():
                        raise RuntimeError("Extracted source-engine directory differs from its archive")
                else:
                    if path.is_symlink() or not path.is_file() or path.stat().st_size != entry.file_size:
                        raise RuntimeError("Extracted source-engine file differs from its archive")
                    with archive.open(entry) as stream:
                        digest = hashlib.sha256()
                        for block in iter(lambda: stream.read(1024 * 1024), b""):
                            digest.update(block)
                    if digest.hexdigest() != sha256(path):
                        raise RuntimeError("Extracted source-engine file differs from its archive")
    except (zipfile.BadZipFile, KeyError, UnicodeDecodeError) as error:
        raise RuntimeError("Source-engine archive has invalid bundle contents") from error


def verify_runtime(project: Path, runtime: Path, manifest_path: Path | None = None, archive_path: Path | None = None) -> dict:
    """Fail closed on origin, source, content, architecture, and signature mismatches.

    A source manifest describes the original CI-built input. Product signing
    changes its executable hash later; retain this input receipt separately.
    """
    if (manifest_path is None) != (archive_path is None):
        raise RuntimeError("Source builds require both --source-engine-manifest and --source-engine-archive")
    policy = validate_checkout(project, expected_commit=SOURCE_COMMIT)
    pin = json.loads((project / "WallpaperVeil/ci/runtime.json").read_text())
    if pin.get("version") != policy["upstream"]["tag"] or pin.get("build") != policy["upstream"]["build"]:
        raise RuntimeError("Official runtime and qualified upstream policy disagree")
    runtime_root = runtime.resolve()
    for relative in ("Contents/Info.plist", "Contents/MacOS/Hammerspoon", "Contents/Resources/setup.lua"):
        path = runtime / relative
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(runtime_root):
            raise RuntimeError("Runtime metadata, engine, and bootstrap must remain inside the bundle")
    info = plistlib.loads((runtime / "Contents/Info.plist").read_bytes())
    expected = ("org.hammerspoon.Hammerspoon", "Hammerspoon", pin["version"], pin["build"])
    actual = tuple(str(info.get(key, "")) for key in
                   ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion"))
    if actual != expected:
        raise RuntimeError("Native runtime identity/version/build does not match the audited input")
    engine = runtime / "Contents/MacOS/Hammerspoon"
    setup = runtime / "Contents/Resources/setup.lua"
    if engine.is_symlink() or setup.is_symlink():
        raise RuntimeError("Native engine and bootstrap must be regular bundled files")
    actual_architectures = architectures(engine)
    if set(actual_architectures) != EXPECTED_ARCHITECTURES:
        raise RuntimeError("The runtime must contain both arm64 and x86_64")
    engine_sha = sha256(engine)
    setup_sha = sha256(setup)
    receipt = {"origin": "official-release", "version": pin["version"], "build": pin["build"],
               "original_engine_sha256": engine_sha, "original_setup_sha256": setup_sha,
               "architectures": actual_architectures, "engine_recompiled_from_source": False}

    if manifest_path is None:
        if engine_sha != _sha(pin.get("engine_sha256"), "official engine"):
            raise RuntimeError("Runtime differs from the pinned official engine; source builds require --source-engine-manifest")
        if setup_sha != _sha(pin.get("setup_sha256"), "official bootstrap"):
            raise RuntimeError("Runtime bootstrap differs from the pinned official release")
        receipt["release_pin"] = pin
    else:
        raw_manifest = manifest_path.read_bytes()
        manifest = json.loads(raw_manifest)
        if not isinstance(manifest, dict) or (type(manifest.get("schema")) is not int or manifest.get("schema") != 1) or manifest.get("kind") != "source-built-native-engine-proof":
            raise RuntimeError("Unsupported source-engine manifest schema/kind")
        if (manifest.get("upstreamCommit") != SOURCE_COMMIT or manifest.get("nativeCodeHead") != SOURCE_COMMIT
                or manifest.get("upstreamTag") != policy["upstream"]["tag"]):
            raise RuntimeError("Source-engine native source does not match the audited baseline")
        if (manifest.get("configuration") != "Debug" or manifest.get("scheme") != "Release"
                or manifest.get("signing") != "ad-hoc" or manifest.get("sanitizers") is not False
                or manifest.get("telemetryDSNCompiled") is not False
                or manifest.get("updaterFrameworkIncluded") is not False):
            raise RuntimeError("Source-engine recipe does not match the qualified developer build")
        if not re.fullmatch(r"[0-9a-f]{40}", str(manifest.get("workflowCommit", ""))):
            raise RuntimeError("Source-engine workflow commit is missing or invalid")
        declared = manifest.get("engine")
        if not isinstance(declared, dict):
            raise RuntimeError("Source-engine executable metadata is missing")
        if (declared.get("bundleID") != expected[0] or declared.get("version") != pin["version"]
                or str(declared.get("build")) != pin["build"]):
            raise RuntimeError("Source manifest and runtime bundle identity disagree")
        declared_architectures = declared.get("architectures")
        if (not isinstance(declared_architectures, list)
                or len(declared_architectures) != 2
                or not all(isinstance(value, str) for value in declared_architectures)
                or set(declared_architectures) != EXPECTED_ARCHITECTURES):
            raise RuntimeError("Source manifest must declare both supported architectures")
        if engine_sha != _sha(declared.get("sha256"), "source engine"):
            raise RuntimeError("Source-engine executable hash does not match its manifest")
        baseline_setup = subprocess.check_output(
            ["/usr/bin/git", "-C", str(project), "show", SOURCE_COMMIT + ":Hammerspoon/setup.lua"])
        baseline_setup_sha = hashlib.sha256(baseline_setup).hexdigest()
        if setup_sha != baseline_setup_sha or ("setupSHA256" in declared and declared["setupSHA256"] != setup_sha):
            raise RuntimeError("Source-engine bootstrap does not match the audited native source")
        # Native source is the verified historical tag, never an unregistered
        # checkout copy or an undisclosed patch. The product has its own HEAD.
        if type(manifest.get("compiledMachOCount")) is not int or manifest["compiledMachOCount"] != 95:
            raise RuntimeError("Source-engine native binary inventory does not match the qualified baseline")
        magic = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe",
                                                  "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
        native_files = []
        for path in runtime.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            if not path.resolve().is_relative_to(runtime_root):
                raise RuntimeError("A runtime resource escapes its bundle")
            with path.open("rb") as stream:
                if stream.read(4) not in magic:
                    continue
            if set(architectures(path)) != EXPECTED_ARCHITECTURES:
                raise RuntimeError("Every source-engine native component must contain both architectures")
            native_files.append(path)
        if len(native_files) != manifest["compiledMachOCount"]:
            raise RuntimeError("Source-engine native component count does not match its manifest")
        archive = manifest.get("archive")
        if (not isinstance(archive, dict) or archive.get("name") != "wallpaper-veil-source-engine.zip"
                or type(archive.get("bytes")) is not int or archive["bytes"] <= 0):
            raise RuntimeError("Source-engine archive provenance is missing or invalid")
        expected_archive_sha = _sha(archive.get("sha256"), "source-engine archive")
        if archive_path.stat().st_size != archive["bytes"] or sha256(archive_path) != expected_archive_sha:
            raise RuntimeError("Source-engine archive bytes/hash do not match the manifest")
        verify_archive_bundle(archive_path, runtime)
        if (runtime / "Contents/Frameworks/Sparkle.framework").exists():
            raise RuntimeError("The source-engine input unexpectedly includes the upstream updater")
        receipt.update({"origin": "source-build", "engine_recompiled_from_source": True,
                        "source_manifest_sha256": hashlib.sha256(raw_manifest).hexdigest(),
                        "source_manifest": manifest, "native_source_tree_matches": True,
                        "native_source_scope": "qualified historical Git tree",
                        "source_archive_inventory_verified": True})

    _command("/usr/bin/codesign", "--verify", "--deep", "--strict", runtime)
    receipt["upstream_policy"] = policy_identity(policy)
    receipt["codesign_verified_deep_strict"] = True
    return receipt
