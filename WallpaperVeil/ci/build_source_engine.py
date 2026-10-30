#!/usr/bin/env python3
"""Compile the audited native engine and package a documented developer artifact.

This never launches an application, registers a login item, changes preferences,
publishes a release, or imports signing credentials. Wallpaper Veil's product
builder consumes the resulting engine and provenance separately.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile

ENGINE_COMMIT = "1469832361b4c3687ec7d589c1b4efe4d3b742ee"
ENGINE_TAG = "1.1.1"
ENGINE_BUILD = "6936"
BASELINE_WORKFLOW_COMMIT = "872baf51a351dda0f3b4e9c9daffedbac69889b9"
UPSTREAM_URL = "https://github.com/Hammerspoon/hammerspoon.git"
ARCHITECTURES = {"arm64", "x86_64"}
MACHO_MAGIC = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
)}


def run(*args: object, cwd: Path | None = None) -> str:
    return subprocess.check_output([str(arg) for arg in args], cwd=cwd,
                                   text=True).strip()


def require(condition: bool, description: str) -> None:
    if not condition:
        raise RuntimeError(description)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def compile_command(derived: Path, jobs: int) -> list[str]:
    """The universal Debug recipe qualified by the baseline workflow above."""
    return [
        "/usr/bin/xcodebuild", "-workspace", "Hammerspoon.xcworkspace",
        "-scheme", "Release", "-configuration", "Debug",
        "-enableAddressSanitizer", "NO", "-enableUndefinedBehaviorSanitizer", "NO",
        "-enableThreadSanitizer", "NO", "-destination", "generic/platform=macOS",
        "-derivedDataPath", str(derived), "-jobs", str(jobs),
        "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM=",
        "ENABLE_USER_SCRIPT_SANDBOXING=NO", "CLANG_ENABLE_EXPLICIT_MODULES=NO",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER=NO",
        "GCC_TREAT_WARNINGS_AS_ERRORS=NO", "COMPILER_INDEX_STORE_ENABLE=NO", "build",
    ]


def compile_engine(source: Path, derived: Path, output: Path, jobs: int) -> None:
    # Direct build bypasses upstream Release token assertions, archive export,
    # Developer ID signing, notarization, and crash-symbol upload. The upstream
    # Release scheme with Debug configuration avoids its development sanitizers
    # and excludes the prebuilt Sparkle framework. Warnings remain in build.log;
    # blanket warnings-as-errors are disabled for newer SDK diagnostics.
    print("Compiling the pinned native engine for arm64 and x86_64", flush=True)
    with (output / "build.log").open("w") as log:
        with subprocess.Popen(compile_command(derived, jobs), cwd=source,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, errors="replace") as process:
            assert process.stdout is not None
            for line in process.stdout:
                log.write(line)
                print(line, end="")
            result = process.wait()
    if result:
        raise subprocess.CalledProcessError(result, compile_command(derived, jobs))


def bundle_legal_notices(source: Path, resources: Path) -> list[dict]:
    notices = resources / "Acknowledgements/SourceEngine"
    pods = source / "Pods/Target Support Files/Pods-Hammerspoon"
    (notices / "Pods").mkdir(parents=True)
    for path in sorted(pods.glob("*acknowledgements*")):
        if path.is_file() and not path.is_symlink():
            shutil.copy2(path, notices / "Pods" / path.name)
    require(len(list((notices / "Pods").iterdir())) == 2,
            "The audited CocoaPods acknowledgements are missing")
    shutil.copy2(source / "LICENSE", notices / "Hammerspoon-MIT.txt")
    stems = ("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "UNLICENSE")
    legal_files = []
    for root in ("extensions", "LuaSkin", "Pods"):
        for path in sorted((source / root).rglob("*")):
            upper = path.name.upper()
            conventional = any(upper == stem or any(upper.startswith(stem + separator)
                               for separator in ".-_") for stem in stems)
            lua_notice = path == source / "LuaSkin/lua-5.4.7/doc/readme.html"
            if path.is_file() and not path.is_symlink() and (conventional or lua_notice):
                relative = path.relative_to(source)
                destination = notices / "Components" / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
                legal_files.append({"path": relative.as_posix(), "sha256": sha256(path)})
    require(len(legal_files) == 81, "The audited set of 81 component notices changed")
    return sorted(legal_files, key=lambda value: value["path"])


def macho_files(app: Path) -> list[Path]:
    result = []
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC:
                    result.append(path)
    return result


def validate_and_sign(app: Path, source: Path) -> tuple[dict, list[Path]]:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == "org.hammerspoon.Hammerspoon",
            "Unexpected native engine identity")
    require(info.get("CFBundleShortVersionString") == ENGINE_TAG and
            str(info.get("CFBundleVersion")) == ENGINE_BUILD,
            "Native engine version or build does not match the pinned source")
    require((source / "Hammerspoon/secrets.h").read_bytes().strip() == b"",
            "The native engine must be compiled without a telemetry DSN")
    require(not (app / "Contents/Frameworks/Sparkle.framework").exists(),
            "A Debug source engine must not embed the prebuilt updater")
    resources = app / "Contents/Resources"
    for name in ("MainMenu.nib", "PreferencesWindow.nib", "ConsoleWindow.nib",
                 "HSChooserWindow.nib", "setup.lua", "docs.json"):
        require((resources / name).exists(), f"Missing compiled engine resource: {name}")
    frameworks = app / "Contents/Frameworks"
    for name in ("libscreen.dylib", "libscreenwatcher.dylib", "libcanvas.dylib",
                 "libmenubar.dylib", "libsettings.dylib"):
        require((frameworks / "hs" / name).is_file(), f"Missing engine module: {name}")
    require((frameworks / "LuaSkin.framework/LuaSkin").is_file(), "LuaSkin is missing")
    binaries = macho_files(app)
    require(len(binaries) == 95, "The audited set of 95 native binaries changed")
    for path in sorted(binaries, key=lambda value: -len(value.parts)):
        dependencies = run("/usr/bin/otool", "-L", path)
        require(not any(name in dependencies for name in
                        ("libclang_rt.asan", "libclang_rt.ubsan", "libclang_rt.tsan")),
                f"Unexpected sanitizer runtime: {path.relative_to(app)}")
        require(set(run("/usr/bin/lipo", "-archs", path).split()) == ARCHITECTURES,
                f"Native binary is not universal: {path.relative_to(app)}")
        run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", path)
    containers = [path for path in app.rglob("*") if path.is_dir() and not path.is_symlink()
                  and path.suffix in {".framework", ".app", ".xpc"}]
    for path in sorted(containers, key=lambda value: -len(value.parts)) + [app]:
        run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", path)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
    return info, binaries


def package_engine(source: Path, derived: Path, output: Path, project: Path) -> dict:
    app = derived / "Build/Products/Debug/Hammerspoon.app"
    resources = app / "Contents/Resources"
    legal_files = bundle_legal_notices(source, resources)
    info, binaries = validate_and_sign(app, source)
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    archive = output / "wallpaper-veil-source-engine.zip"
    run("/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", app, archive)
    with tempfile.TemporaryDirectory(prefix="wallpaper-veil-engine-extraction-", suffix=".noindex") as temporary:
        extracted = Path(temporary)
        run("/usr/bin/ditto", "--noqtn", "-x", "-k", archive, extracted)
        extracted_app = extracted / app.name
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", extracted_app)
        require(sha256(extracted_app / "Contents/MacOS" / info["CFBundleExecutable"]) == sha256(executable),
                "Extracted engine executable changed")
    workflow_commit = os.getenv("GITHUB_SHA") or run("/usr/bin/git", "-C", project, "rev-parse", "HEAD")
    clang = run("/usr/bin/xcrun", "clang", "--version")
    # InstalledDir may contain a developer-selected compiler path. The version
    # lines identify the toolchain without recording a personal filesystem path.
    clang = "\n".join(line for line in clang.splitlines() if not line.startswith("InstalledDir:"))
    manifest = {
        "schema": 1, "kind": "source-built-native-engine-proof",
        "productIntegrated": False, "runtimeLaunched": False,
        "builtAtUTC": dt.datetime.now(dt.timezone.utc).isoformat(),
        "configuration": "Debug", "scheme": "Release", "sanitizers": False,
        "explicitClangModules": False,
        "compatibilitySettings": {"CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "NO",
                                  "GCC_TREAT_WARNINGS_AS_ERRORS": "NO"},
        "upstreamCommit": ENGINE_COMMIT, "upstreamTag": ENGINE_TAG,
        "nativeCodeHead": run("/usr/bin/git", "-C", source, "rev-parse", "HEAD"),
        "sourceTree": "pinned-upstream-baseline", "workflowCommit": workflow_commit,
        "workflow": {"repository": os.getenv("GITHUB_REPOSITORY"), "commit": workflow_commit,
                     "runID": os.getenv("GITHUB_RUN_ID"), "runAttempt": os.getenv("GITHUB_RUN_ATTEMPT")},
        "recipe": {"path": "WallpaperVeil/ci/build_source_engine.py", "sha256": sha256(Path(__file__)),
                   "baselineWorkflowCommit": BASELINE_WORKFLOW_COMMIT},
        "signing": "ad-hoc", "telemetryDSNCompiled": False, "updaterFrameworkIncluded": False,
        "engine": {"sha256": sha256(executable), "architectures": sorted(ARCHITECTURES),
                   "bundleID": info["CFBundleIdentifier"], "version": info["CFBundleShortVersionString"],
                   "build": str(info["CFBundleVersion"]), "setupSHA256": sha256(resources / "setup.lua")},
        "toolchain": {"xcode": run("/usr/bin/xcodebuild", "-version"),
                      "sdk": run("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"),
                      "clang": clang, "hostArchitecture": run("/usr/bin/uname", "-m")},
        "compiledMachOCount": len(binaries), "componentLegalNotices": legal_files,
        "archive": {"name": archive.name, "sha256": sha256(archive), "bytes": archive.stat().st_size},
        "qualification": ["source compilation", "both architectures", "compiled nib resources",
                          "empty telemetry header", "no linked ASan/UBSan/TSan runtime",
                          "deep strict ad-hoc signature", "extracted archive signature"],
        "pendingQualification": ["Wallpaper Veil product integration", "local application startup",
                                 "existing application acceptance and UI checks"],
    }
    (output / "source-engine-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output / (archive.name + ".sha256")).write_text(manifest["archive"]["sha256"] + "  " + archive.name + "\n")
    print(json.dumps({name: manifest[name] for name in ("kind", "nativeCodeHead", "engine", "compiledMachOCount")}, indent=2))
    return manifest


def build(project: Path, destination: Path, jobs: int = 3) -> dict:
    require(platform.system() == "Darwin", "A full macOS Xcode installation is required")
    require(1 <= jobs <= 16, "--jobs must be between 1 and 16")
    documents = (Path.home() / "Documents").resolve()
    require(not project.is_relative_to(documents) and not destination.is_relative_to(documents),
            "Source and build output must remain outside Documents")
    require(not destination.exists() or not any(destination.iterdir()),
            "Choose an empty source-engine artifact directory")
    destination.mkdir(parents=True, exist_ok=True)
    run("/usr/bin/git", "-C", project, "fetch", "--no-tags", UPSTREAM_URL,
        f"refs/tags/{ENGINE_TAG}:refs/tags/{ENGINE_TAG}")
    require(run("/usr/bin/git", "-C", project, "rev-parse", f"{ENGINE_TAG}^{{commit}}") == ENGINE_COMMIT,
            "The fetched upstream tag does not match its audited commit")
    with tempfile.TemporaryDirectory(prefix="wallpaper-veil-source-engine-", suffix=".noindex") as temporary:
        root = Path(temporary)
        source, derived = root / "source", root / "derived"
        run("/usr/bin/git", "-C", project, "worktree", "add", "--detach", source, ENGINE_COMMIT)
        try:
            require(run("/usr/bin/git", "-C", source, "describe", "--tags", "--abbrev=0") == ENGINE_TAG,
                    "Native build requires the audited numeric upstream version tag")
            require(run("/usr/bin/git", "-C", source, "rev-list", "HEAD", "--count") == ENGINE_BUILD,
                    "Complete native source history is required for the audited build number")
            require((source / "Podfile.lock").read_bytes() == (source / "Pods/Manifest.lock").read_bytes(),
                    "Vendored Pods do not match Podfile.lock")
            for path in ("Pods/Pods.xcodeproj/project.pbxproj", "LuaSkin/lua-5.4.7/src/lua.h"):
                require((source / path).is_file(), f"Missing checked-in dependency: {path}")
            print(run("/usr/bin/xcodebuild", "-version"), flush=True)
            for tool in ("ibtool", "actool", "intentbuilderc"):
                run("/usr/bin/xcrun", "--find", tool)
            compile_engine(source, derived, destination, jobs)
            return package_engine(source, derived, destination, project)
        finally:
            run("/usr/bin/git", "-C", project, "worktree", "remove", "--force", source)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()
    try:
        build(args.project.expanduser().resolve(), args.destination.expanduser().resolve(), args.jobs)
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Source engine build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
