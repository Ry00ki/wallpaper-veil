#!/usr/bin/env python3
"""Build a Wallpaper Veil prototype using an existing native runtime.

The launcher and UI bridge are compiled locally. The native engine is copied
from either the pinned official release or a verified source-engine build. This script never launches an app, writes application
preferences, changes login items, or modifies the source runtime installation.
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
import uuid

from runtime_provenance import verify_runtime

APP_ID = "com.ry00ki.wallpaperveil"
LAUNCHER_ID = "com.ry00ki.wallpaperveil.launcher"
APP_NAME = "Wallpaper Veil"
HELPER_RELATIVE_PATH = "Contents/Helpers/Wallpaper Veil Runtime.app"
SOURCE_COMMIT = "1469832361b4c3687ec7d589c1b4efe4d3b742ee"
RUNTIME_VERSION = "1.1.1"
RUNTIME_BUILD = "6936"


def run(*args: str, capture: bool = False) -> str:
    result = subprocess.run(list(map(str, args)), check=True, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else ""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def checked_source(project: Path) -> dict:
    actual = run("/usr/bin/git", "-C", str(project), "rev-parse", "HEAD", capture=True)
    tag = run("/usr/bin/git", "-C", str(project), "rev-parse", "1.1.1^{commit}", capture=True)
    if tag != SOURCE_COMMIT:
        raise RuntimeError("The local source fork's 1.1.1 tag does not match the audited upstream commit")
    # Own committed project work may advance HEAD after the initial source fork.
    run("/usr/bin/git", "-C", str(project), "merge-base", "--is-ancestor", SOURCE_COMMIT, actual)
    return {"upstream_tag": "1.1.1", "upstream_commit": tag, "local_head": actual,
            "local_branch": run("/usr/bin/git", "-C", str(project), "branch", "--show-current", capture=True),
            "worktree_status": run("/usr/bin/git", "-C", str(project), "status", "--porcelain", capture=True).splitlines()}


def bundled_setup(original: str) -> str:
    split = "local preload = function(m) return function() return require(m) end end"
    if original.count(split) != 1 or "return require'hs._coresetup'.setup(...)" not in original:
        raise RuntimeError("Unrecognised native runtime setup.lua; refusing an unverified bootstrap patch")
    tail = original.split(split, 1)[1]
    tail = tail.replace("return require'hs._coresetup'.setup(...)",
        "return require'hs._coresetup'.setup(modpath, frameworkspath, prettypath, fullpath, "
        "configdir, docstringspath, true, autoload_extensions)")
    return '''-- Wallpaper Veil bundled native-runtime bootstrap.
-- All executable Lua/native modules are bundled; state lives in Application Support.
local modpath, frameworkspath, prettypath, fullpath, configdir, docstringspath, hasinitfile, autoload_extensions = ...
local code = assert(os.getenv("WV_APP_CODE"), "Wallpaper Veil launcher is required")
local support = assert(os.getenv("WV_APPLICATION_SUPPORT"), "Wallpaper Veil state path is missing")
assert(code == hs.processInfo.resourcePath .. "/WallpaperVeil", "Unexpected application code path")
assert(hs.processInfo.bundleID == "com.ry00ki.wallpaperveil", "Unexpected application identity")
configdir = support .. "/runtime"
fullpath = code .. "/init.lua"
prettypath = fullpath
hasinitfile = true
package.path = table.concat({code .. "/?.lua", code .. "/?/init.lua", modpath .. "/?.lua", modpath .. "/?/init.lua"}, ";")
package.cpath = frameworkspath .. "/?.dylib"
local preload = function(m) return function() return require(m) end end
''' + tail


def sign_bundle(app: Path) -> None:
    """Sign nested files and containers inside out, retaining executable layout."""
    magic = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
             b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
    binaries = []
    for path in app.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            if stream.read(4) in magic:
                binaries.append(path)
    # Main executables also seal their app containers. Sign every nested
    # library first, including app-owned modules at the same directory depth.
    for path in sorted(binaries, key=lambda p: (p.name in {"WallpaperVeil", "WallpaperVeilRuntime"}, -len(p.parts))):
        args = ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none"]
        if path.name == "WallpaperVeilRuntime":
            args += ["--identifier", APP_ID]
        elif path.name == "WallpaperVeil":
            args += ["--identifier", LAUNCHER_ID]
        run(*args, str(path))
    containers = [p for p in app.rglob("*") if p.is_dir() and not p.is_symlink()
                  and p.suffix in {".framework", ".app", ".xpc"}]
    for path in sorted(containers, key=lambda p: len(p.parts), reverse=True):
        run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(path))
    run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(app))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))


# Add this function beside the existing builder helpers. Path, shutil and the
# existing sha256(path) helper are already imported/defined in build_local.py.
def bundle_component_notices(project: Path, acknowledgements: Path) -> dict:
    """Copy vendor legal files byte-for-byte, preserving source-relative paths."""
    roots = ("extensions", "LuaSkin", "Pods")
    stems = ("LICENSE", "LICENCE", "COPYING", "COPYRIGHT", "NOTICE", "UNLICENSE")
    def conventional_name(name: str) -> bool:
        upper = name.upper()
        return any(upper == stem or any(upper.startswith(stem + separator)
                   for separator in (".", "-", "_")) for stem in stems)

    files = set()
    for prefix in roots:
        directory = project / prefix
        if not directory.is_dir():
            raise RuntimeError(f"Required component source directory missing: {prefix}")
        for source in directory.rglob("*"):
            if source.is_file() and not source.is_symlink() and conventional_name(source.name):
                files.add(source)

    # Upstream Lua's complete licence lives in this documentation page, not a
    # conventional LICENSE file. Do not substitute a copy of its source headers.
    lua_legal = project / "LuaSkin/lua-5.4.7/doc/readme.html"
    if not lua_legal.is_file() or lua_legal.is_symlink():
        raise RuntimeError("Audited Lua 5.4.7 legal documentation is missing")
    files.add(lua_legal)
    required = (
        "extensions/menubar/LICENSE",
        "extensions/screen/LICENSE",
        "extensions/httpserver/LICENSE.timeout3",
        "extensions/network/ping/LICENSE.SimplePing",
        "extensions/mouse/manymouse/LICENSE.txt",
        "Pods/Sentry/LICENSE.md",
        "Pods/SocketRocket/LICENSE-examples",
        "Pods/Sparkle/LICENSE",
    )
    for relative in required:
        if project / relative not in files:
            raise RuntimeError(f"Required component legal notice missing: {relative}")

    destination = acknowledgements / "Components"
    counts = {prefix: 0 for prefix in roots}
    manifest = []
    for source in sorted(files):
        relative = source.relative_to(project)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        counts[relative.parts[0]] += 1
        manifest.append({"path": relative.as_posix(), "sha256": sha256(target)})
    return {"counts": counts, "total": len(manifest), "files": manifest}



def build(output: Path, runtime: Path, own: Path, source_manifest: Path | None = None,
          source_archive: Path | None = None) -> dict:
    project = own.parent
    if platform.system() != "Darwin":
        raise RuntimeError("This prototype must be built on macOS")
    documents = (Path.home() / "Documents").resolve()
    if output.is_relative_to(documents) or project.resolve().is_relative_to(documents):
        raise RuntimeError("Wallpaper Veil source and build output must remain outside Documents")
    if output.suffix != ".app":
        raise RuntimeError("--output must name a .app bundle")
    if runtime == output or output.is_relative_to(runtime):
        raise RuntimeError("Build output must not replace or sit inside the source runtime")
    source = checked_source(project)
    original_info = plistlib.loads((runtime / "Contents/Info.plist").read_bytes())
    runtime_receipt = verify_runtime(project, runtime, source_manifest, source_archive)
    source_built = runtime_receipt["engine_recompiled_from_source"]
    prototype_type = (("source-built native engine" if source_built else "binary-runtime prototype")
                      + " with NSWorkspace launcher and nested native application")
    app_sources = own / "app"
    if not (app_sources / "init.lua").is_file():
        raise RuntimeError("WallpaperVeil/app/init.lua is missing")
    if not (own / "launcher.m").is_file():
        raise RuntimeError("WallpaperVeil/launcher.m is missing")
    if output.exists():
        marker = output / "Contents/Resources/wallpaper-veil-build.json"
        if not marker.is_file() or json.loads(marker.read_text()).get("bundle_id") not in {APP_ID, LAUNCHER_ID}:
            raise RuntimeError("Refusing to replace an existing bundle without Wallpaper Veil build provenance")
    output.parent.mkdir(parents=True, exist_ok=True)
    stage_root = Path(tempfile.mkdtemp(prefix=".wallpaper-veil-stage-", dir=output.parent))
    stage = stage_root / output.name
    try:
        contents = stage / "Contents"
        outer_resources = contents / "Resources"
        macos = contents / "MacOS"
        outer_resources.mkdir(parents=True)
        macos.mkdir()
        helper = stage / HELPER_RELATIVE_PATH
        helper.parent.mkdir(parents=True)
        run("/usr/bin/ditto", "--noqtn", str(runtime), str(helper))
        runtime_contents = helper / "Contents"
        resources = runtime_contents / "Resources"
        engine = runtime_contents / "MacOS/WallpaperVeilRuntime"
        (runtime_contents / "MacOS" / original_info["CFBundleExecutable"]).rename(engine)
        code = resources / "WallpaperVeil"
        code.mkdir()
        code_hashes = {}
        for path in sorted(app_sources.rglob("*.lua")):
            if path.is_symlink():
                raise RuntimeError(f"Application source must not be a symlink: {path}")
            target = code / path.relative_to(app_sources)
            target.parent.mkdir(parents=True, exist_ok=True)
            text = path.read_text()
            text = text.replace('"org.hammerspoon.Hammerspoon"', "hs.processInfo.bundleID")
            text = text.replace("'org.hammerspoon.Hammerspoon'", "hs.processInfo.bundleID")
            text = text.replace("Show Hammerspoon icon", "Show engine menu icon")
            target.write_text(text)
            code_hashes[str(target.relative_to(resources))] = sha256(target)
        old_setup = (resources / "setup.lua").read_text()
        (resources / "setup.lua").write_text(bundled_setup(old_setup))
        acknowledgements = resources / "Acknowledgements"
        acknowledgements.mkdir(exist_ok=True)
        if source_manifest is not None:
            receipt_directory = acknowledgements / "SourceEngine"
            receipt_directory.mkdir(exist_ok=True)
            shutil.copy2(source_manifest, receipt_directory / "source-engine-manifest.json")
        for name, target_name in [
            ("LICENSE", "LICENSE"), ("CREDITS.md", "CREDITS.md"),
            ("LICENSES/Hammerspoon-MIT.txt", "Hammerspoon-MIT.txt"),
            ("WallpaperVeil/LICENSE", "Wallpaper-Veil-MIT.txt"),
            ("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.md"),
            ("Pods/Target Support Files/Pods-Hammerspoon/Pods-Hammerspoon-acknowledgements.markdown",
             "Pods-Hammerspoon-acknowledgements.markdown"),
            ("Pods/Target Support Files/Pods-Hammerspoon/Pods-Hammerspoon-acknowledgements.plist",
             "Pods-Hammerspoon-acknowledgements.plist"),
        ]:
            path = project / name
            if not path.is_file():
                raise RuntimeError(f"Required licence or credit file is missing: {name}")
            shutil.copy2(path, acknowledgements / target_name)
        component_notices = bundle_component_notices(project, acknowledgements)
        removed_login_helpers = []
        login_items = runtime_contents / "Library/LoginItems"
        if login_items.exists():
            removed_login_helpers = [str(p.relative_to(runtime_contents)) for p in login_items.iterdir()]
            shutil.rmtree(login_items)
        info = dict(original_info)
        info.pop("CFBundleIconName", None)
        for key in ["CFBundleDocumentTypes", "CFBundleURLTypes", "NSServices", "UTExportedTypeDeclarations",
                    "UTImportedTypeDeclarations", "INIntentsSupported", "NSUserActivityTypes", "OSAScriptingDefinition",
                    "SUFeedURL", "SUScheduledCheckInterval", "SUPublicEDKey", "NSAppTransportSecurity",
                    "NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSLocationAlwaysUsageDescription"]:
            info.pop(key, None)
        info.update({"CFBundleIdentifier": APP_ID, "CFBundleName": APP_NAME, "CFBundleDisplayName": APP_NAME,
                     "CFBundleExecutable": "WallpaperVeilRuntime", "CFBundleShortVersionString": "0.1.4", "CFBundleVersion": "5",
                     "CFBundleIconFile": "WallpaperVeil.icns",
                     "LSApplicationCategoryType": "public.app-category.utilities", "NSPrincipalClass": "NSApplication",
                     "NSAppleScriptEnabled": False, "SUEnableAutomaticChecks": False,
                     "SUAllowsAutomaticUpdates": False, "SUAutomaticallyUpdate": False, "SUSendProfileInfo": False,
                     "NSAppleEventsUsageDescription": "Wallpaper Veil uses macOS automation for desktop controls.",
                     "WVPrototypeType": prototype_type,
                     "WVRuntimeOrigin": runtime_receipt["origin"],
                     "WVRuntimeVersion": RUNTIME_VERSION, "WVRuntimeBuild": RUNTIME_BUILD,
                     "WVReleaseTag": "v0.1.4-preview.1", "WVReleaseChannel": "preview",
                     "WVUpstreamSourceCommit": SOURCE_COMMIT,
                     "NSHumanReadableCopyright": "Wallpaper Veil. Includes Hammerspoon and third-party software; see bundled acknowledgements."})
        with (runtime_contents / "Info.plist").open("wb") as stream:
            plistlib.dump(info, stream)
        outer_info = {
            "CFBundleDevelopmentRegion": "en", "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundlePackageType": "APPL", "CFBundleIdentifier": LAUNCHER_ID,
            "CFBundleName": APP_NAME, "CFBundleDisplayName": APP_NAME,
            "CFBundleExecutable": "WallpaperVeil", "CFBundleShortVersionString": "0.1.4", "CFBundleVersion": "5",
            "LSUIElement": True, "LSMinimumSystemVersion": original_info.get("LSMinimumSystemVersion", "13.0"),
            "LSApplicationCategoryType": "public.app-category.utilities", "NSPrincipalClass": "NSApplication",
            "NSHumanReadableCopyright": info["NSHumanReadableCopyright"],
            "WVPrototypeType": info["WVPrototypeType"], "WVRuntimeBundleIdentifier": APP_ID,
            "WVRuntimeRelativePath": HELPER_RELATIVE_PATH,
            "WVReleaseTag": "v0.1.4-preview.1", "WVReleaseChannel": "preview",
        }
        icon = own / "assets/WallpaperVeil.icns"
        if not icon.is_file():
            raise RuntimeError("The original Wallpaper Veil app icon is missing")
        for destination in (resources, outer_resources):
            shutil.copy2(icon, destination / icon.name)
        outer_info["CFBundleIconFile"] = "WallpaperVeil.icns"
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(outer_info, stream)
        clang = run("/usr/bin/xcrun", "--find", "clang", capture=True)
        sdk = run("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path", capture=True)
        run(clang, "-isysroot", sdk, "-fobjc-arc", "-O2", "-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=13.0",
            "-framework", "Foundation", "-framework", "AppKit", "-framework", "ServiceManagement", str(own / "launcher.m"), "-o", str(macos / "WallpaperVeil"))
        run(clang, "-isysroot", sdk, "-fobjc-arc", "-O2", "-arch", "arm64", "-arch", "x86_64",
            "-mmacosx-version-min=13.0", "-bundle", "-undefined", "dynamic_lookup",
            "-I", str(project / "LuaSkin/lua-5.4.7/src"), "-framework", "Foundation", "-framework", "AppKit", "-framework", "ServiceManagement",
            str(own / "native_ui.m"), "-o", str(runtime_contents / "Frameworks/libWallpaperVeilUI.dylib"))
        provenance = {
            "bundle_id": LAUNCHER_ID, "runtime_bundle_id": APP_ID, "name": APP_NAME, "version": "0.1.4", "build": "5",
            "release_tag": "v0.1.4-preview.1", "release_channel": "preview",
            "built_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "type": prototype_type,
            "runtime_relative_path": HELPER_RELATIVE_PATH,
            "launch_method": "NSWorkspace.openApplicationAtURL with early arguments and controlled WV environment",
            "launcher_is_permanent_supervisor": False,
            "engine_recompiled_from_source": source_built, "launcher_recompiled_from_source": True, "ui_recompiled_from_source": True,
            "source": source,
            "runtime": {"input_bundle_name": runtime.name, **runtime_receipt},
            "source_hashes": {"launcher.m": sha256(own / "launcher.m"), "build_local.py": sha256(Path(__file__)),
                              "native_ui.m": sha256(own / "native_ui.m"), "WallpaperVeil.icns": sha256(icon),
                              "runtime_provenance.py": sha256(own / "runtime_provenance.py"),
                              **({"update_check.h": sha256(own / "update_check.h")}
                                 if (own / "update_check.h").is_file() else {})},
            "component_notices": component_notices,
            "bundled_lua_hashes": code_hashes,
            "bundled_setup_sha256": sha256(resources / "setup.lua"),
            "launcher_architectures": run("/usr/bin/lipo", "-archs", str(macos / "WallpaperVeil"), capture=True),
            "login_helper_policy": "Copied LoginItems removed; app-owned SMAppService registration targets the outer launcher only when requested",
            "removed_login_helpers": removed_login_helpers,
            "distribution": "Ad hoc signed for local testing; not Developer ID signed or notarized",
            "application_launched_by_builder": False,
        }
        write_json(outer_resources / "wallpaper-veil-build.json", provenance)
        write_json(resources / "wallpaper-veil-build.json", provenance)
        sign_bundle(stage)
        prior = None
        if output.exists():
            prior = output.parent / (".wallpaper-veil-previous-" + uuid.uuid4().hex + ".app")
            output.rename(prior)
        try:
            stage.rename(output)
        except BaseException:
            if prior:
                prior.rename(output)
            raise
        if prior:
            shutil.rmtree(prior)
        report = dict(provenance)
        report.update({"output_bundle_name": output.name, "codesign_verified_deep_strict": True,
                       "signed_launcher_sha256": sha256(output / "Contents/MacOS/WallpaperVeil"),
                       "signed_engine_sha256": sha256(output / HELPER_RELATIVE_PATH / "Contents/MacOS/WallpaperVeilRuntime")})
        report_path = output.with_suffix(".build.json")
        write_json(report_path, report)
        print(json.dumps({"app": str(output), "report": str(report_path), "codesign_verified_deep_strict": True,
                          "type": provenance["type"], "app_launched": False}, indent=2))
        return report
    finally:
        shutil.rmtree(stage_root, ignore_errors=True)


def main() -> int:
    own = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=own.parent.parent / "build.noindex/Wallpaper Veil.app")
    parser.add_argument("--runtime", type=Path, required=True,
                        help="Pinned official runtime or an extracted, verified source-engine archive")
    parser.add_argument("--source-engine-manifest", type=Path,
                        help="Source-engine manifest; requires --source-engine-archive")
    parser.add_argument("--source-engine-archive", type=Path,
                        help="Original source-engine ZIP bound to its manifest")
    args = parser.parse_args()
    try:
        build(args.output.expanduser().resolve(), args.runtime.expanduser().resolve(), own,
              args.source_engine_manifest.expanduser().resolve() if args.source_engine_manifest else None,
              args.source_engine_archive.expanduser().resolve() if args.source_engine_archive else None)
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
