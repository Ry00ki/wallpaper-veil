"""Adversarial input tests; no native code, applications or hardware are run."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
import stat
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

OWN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OWN))
import runtime_provenance as runtime


def universal(suffix=b""):
    return (struct.pack(">II", 0xCAFEBABE, 2)
            + b"".join(struct.pack(">IIIII", cpu, 0, 0, 0, 0) for cpu in (0x01000007, 0x0100000C))
            + suffix)


class RuntimeInputTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wallpaper-veil-provenance-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        (self.project / "Hammerspoon").mkdir(parents=True)
        (self.project / "Hammerspoon/setup.lua").write_bytes(b"fixture setup\n")
        (self.project / "Hammerspoon/core.m").write_text("// native baseline\n")
        subprocess.run(["/usr/bin/git", "init", "-q", str(self.project)], check=True)
        subprocess.run(["/usr/bin/git", "-C", str(self.project), "add", "Hammerspoon"], check=True)
        subprocess.run(["/usr/bin/git", "-C", str(self.project), "-c", "user.name=Wallpaper Veil tests",
                        "-c", "user.email=tests@example.invalid", "commit", "-qm", "fixture native baseline"], check=True)
        self.commit = subprocess.check_output(["/usr/bin/git", "-C", str(self.project), "rev-parse", "HEAD"], text=True).strip()
        self.addCleanup(patch.stopall)
        patch.object(runtime, "SOURCE_COMMIT", self.commit).start()
        self.app = self.root / "Hammerspoon.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Resources").mkdir()
        self.engine = self.app / "Contents/MacOS/Hammerspoon"
        self.engine.write_bytes(universal(b"source"))
        self.setup = self.app / "Contents/Resources/setup.lua"
        self.setup.write_bytes(b"fixture setup\n")
        (self.setup.parent / "module.lua").write_bytes(b"return true")
        (self.setup.parent / "icon.png").write_bytes(b"fixture icon")
        self.info = {"CFBundleIdentifier": "org.hammerspoon.Hammerspoon", "CFBundleExecutable": "Hammerspoon",
                     "CFBundleShortVersionString": "1.1.1", "CFBundleVersion": "6936"}
        self.write_info()
        self.components = self.app / "Contents/Frameworks/hs"
        self.components.mkdir(parents=True)
        for n in range(94):
            (self.components / f"component{n}.dylib").write_bytes(universal(bytes([n])))
        (self.app / "Contents/Frameworks/CurrentModules").symlink_to("hs", target_is_directory=True)
        self.pin = {"version": "1.1.1", "build": "6936",
                    "engine_sha256": hashlib.sha256(universal(b"official")).hexdigest(),
                    "setup_sha256": runtime.sha256(self.setup)}
        (self.project / "WallpaperVeil/ci").mkdir(parents=True)
        (self.project / "WallpaperVeil/ci/runtime.json").write_text(json.dumps(self.pin))
        self.archive = self.root / "wallpaper-veil-source-engine.zip"
        self.write_archive()
        self.manifest = {
            "schema": 1, "kind": "source-built-native-engine-proof", "upstreamCommit": self.commit,
            "nativeCodeHead": self.commit, "upstreamTag": "1.1.1", "configuration": "Debug", "scheme": "Release",
            "signing": "ad-hoc", "sanitizers": False, "telemetryDSNCompiled": False,
            "updaterFrameworkIncluded": False, "workflowCommit": "a" * 40, "compiledMachOCount": 95,
            "engine": {"bundleID": self.info["CFBundleIdentifier"], "version": "1.1.1", "build": "6936",
                       "sha256": runtime.sha256(self.engine), "architectures": ["x86_64", "arm64"]},
            "archive": {"name": self.archive.name, "bytes": self.archive.stat().st_size, "sha256": runtime.sha256(self.archive)},
        }
        self.manifest_path = self.root / "source-engine-manifest.json"
        self.write_manifest()
        original_run = subprocess.run
        self.signature_failure = False
        def commands(args, **kwargs):
            if args[0] == "/usr/bin/codesign":
                if self.signature_failure:
                    raise subprocess.CalledProcessError(1, args, stderr="invalid signature")
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")
            return original_run(args, **kwargs)
        patch.object(runtime.subprocess, "run", side_effect=commands).start()

    def write_archive(self, overrides=None):
        overrides = overrides or {}
        with zipfile.ZipFile(self.archive, "w") as entries:
            for path in sorted(self.app.rglob("*")):
                relative = path.relative_to(self.app).as_posix()
                name = "Hammerspoon.app/" + relative
                if path.is_symlink():
                    entry = zipfile.ZipInfo(name)
                    entry.create_system = 3
                    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    entries.writestr(entry, os.readlink(path))
                elif relative in overrides:
                    entries.writestr(name, overrides[relative])
                else:
                    entries.write(path, name)

    def update_archive_manifest(self):
        self.manifest["archive"].update(bytes=self.archive.stat().st_size, sha256=runtime.sha256(self.archive))

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest))

    def write_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def verify(self):
        self.write_manifest()
        return runtime.verify_runtime(self.project, self.app, self.manifest_path, self.archive)

    def reject(self):
        with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
            self.verify()

    def test_valid_legacy_source_receipt_retains_original_engine_identity(self):
        receipt = self.verify()
        self.assertEqual(receipt["origin"], "source-build")
        self.assertTrue(receipt["engine_recompiled_from_source"])
        self.assertTrue(receipt["native_source_tree_matches"])
        self.assertEqual(receipt["source_manifest"]["nativeCodeHead"], self.commit)

    def test_valid_new_recipe_setup_hash(self):
        self.manifest["engine"]["setupSHA256"] = runtime.sha256(self.setup)
        self.assertEqual(self.verify()["original_setup_sha256"], runtime.sha256(self.setup))

    def test_source_input_cannot_silently_be_labeled_official(self):
        with self.assertRaisesRegex(RuntimeError, "source builds require"):
            runtime.verify_runtime(self.project, self.app)

    def test_official_mode_requires_pinned_executable_bytes(self):
        self.engine.write_bytes(universal(b"official"))
        receipt = runtime.verify_runtime(self.project, self.app)
        self.assertEqual(receipt["origin"], "official-release")
        self.assertFalse(receipt["engine_recompiled_from_source"])

    def test_source_arguments_must_be_paired(self):
        for manifest, archive in ((self.manifest_path, None), (None, self.archive)):
            with self.subTest(manifest=bool(manifest)):
                with self.assertRaisesRegex(RuntimeError, "both"):
                    runtime.verify_runtime(self.project, self.app, manifest, archive)

    def test_wrong_schema_source_identity_and_recipe_are_rejected(self):
        original = copy.deepcopy(self.manifest)
        cases = {"schema": True, "kind": "release", "upstreamCommit": "b" * 40,
                 "nativeCodeHead": "b" * 40, "upstreamTag": "2.0.0", "configuration": "Release",
                 "scheme": "Hammerspoon", "signing": "Developer ID", "sanitizers": True,
                 "telemetryDSNCompiled": True, "updaterFrameworkIncluded": True, "workflowCommit": "missing"}
        for key, value in cases.items():
            with self.subTest(key=key):
                self.manifest = {**copy.deepcopy(original), key: value}
                self.reject()

    def test_manifest_cannot_invent_bundle_identity_or_architectures(self):
        original = copy.deepcopy(self.manifest["engine"])
        for key, value in {"bundleID": "other.app", "version": "2.0", "build": "1",
                           "architectures": ["arm64", "arm64"], "sha256": "0" * 64}.items():
            with self.subTest(key=key):
                self.manifest["engine"] = {**copy.deepcopy(original), key: value}
                self.reject()

    def test_modified_executable_is_rejected(self):
        self.engine.write_bytes(self.engine.read_bytes() + b"modified")
        self.reject()

    def test_modified_bootstrap_is_rejected(self):
        self.setup.write_bytes(b"external config loader")
        self.reject()

    def test_modified_archive_is_rejected(self):
        self.archive.write_bytes(self.archive.read_bytes() + b"modified")
        self.reject()

    def test_archive_with_a_different_engine_is_rejected_even_if_its_hash_matches(self):
        self.write_archive({"Contents/MacOS/Hammerspoon": universal(b"edited")})
        self.update_archive_manifest()
        self.reject()

    def test_single_architecture_component_is_rejected(self):
        (self.components / "component0.dylib").write_bytes(struct.pack("<II", 0xFEEDFACF, 0x0100000C))
        self.reject()

    def test_removed_component_is_rejected(self):
        (self.components / "component0.dylib").unlink()
        self.reject()

    def test_changed_native_source_requires_a_new_qualified_engine(self):
        (self.project / "Hammerspoon/core.m").write_text("// changed native implementation\n")
        self.reject()

    def test_untracked_native_header_is_rejected(self):
        (self.project / "Hammerspoon/injected.h").write_text("// unbuilt native source\n")
        self.reject()

    def test_signature_failure_is_rejected(self):
        self.signature_failure = True
        self.reject()

    def test_bundle_identity_path_traversal_is_rejected(self):
        self.info["CFBundleExecutable"] = "../../other"
        self.write_info()
        self.reject()

    def test_parent_symlink_cannot_escape_runtime(self):
        external = self.root / "external"
        self.setup.parent.rename(external)
        self.setup.parent.symlink_to(external, target_is_directory=True)
        self.reject()

    def test_same_architecture_module_change_is_rejected(self):
        path = self.components / "component0.dylib"
        path.write_bytes(path.read_bytes()[:-1] + b"x")
        self.reject()

    def test_lua_resource_change_is_rejected(self):
        (self.setup.parent / "module.lua").write_bytes(b"return nil ")
        self.reject()

    def test_binary_resource_change_is_rejected(self):
        (self.setup.parent / "icon.png").write_bytes(b"altered icon")
        self.reject()

    def test_extra_file_is_rejected(self):
        (self.setup.parent / "injected.lua").write_text("return false")
        self.reject()

    def test_missing_resource_is_rejected(self):
        (self.setup.parent / "icon.png").unlink()
        self.reject()

    def test_symlink_target_must_match_archive_even_when_it_stays_inside(self):
        link = self.app / "Contents/Frameworks/CurrentModules"
        link.unlink()
        link.symlink_to("../Frameworks/hs", target_is_directory=True)
        self.reject()

    def test_duplicate_zip_entry_is_rejected(self):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "a") as entries:
                entries.writestr("Hammerspoon.app/Contents/Resources/module.lua", b"return true")
        self.update_archive_manifest()
        self.reject()

    def test_unsafe_zip_paths_are_rejected(self):
        original = self.archive.read_bytes()
        for name in ("Hammerspoon.app/../outside", "/absolute", "other.app/file", "Hammerspoon.app//alias"):
            with self.subTest(name=name):
                self.archive.write_bytes(original)
                with zipfile.ZipFile(self.archive, "a") as entries:
                    entries.writestr(name, b"unsafe")
                self.update_archive_manifest()
                self.reject()

    def test_escaping_archive_symlink_is_rejected(self):
        with zipfile.ZipFile(self.archive, "a") as entries:
            entry = zipfile.ZipInfo("Hammerspoon.app/Contents/escaped")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            entries.writestr(entry, "../../outside")
        self.update_archive_manifest()
        self.reject()


if __name__ == "__main__":
    unittest.main()
