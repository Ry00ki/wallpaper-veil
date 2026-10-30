"""Reject package receipts that disagree with signed application provenance."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("package_preview", Path(__file__).resolve().parents[1] / "ci/package_preview.py")
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


class PackageReceiptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wallpaper-veil-package-test-", suffix=".noindex")
        self.addCleanup(temporary.cleanup)
        self.app = Path(temporary.name) / "Wallpaper Veil.app"
        self.helper = self.app / "Contents/Helpers/Wallpaper Veil Runtime.app"
        for bundle in (self.app, self.helper):
            (bundle / "Contents/Resources").mkdir(parents=True)
            (bundle / "Contents/MacOS").mkdir()
        (self.app / "Contents/MacOS/WallpaperVeil").write_bytes(b"fixture launcher")
        (self.helper / "Contents/MacOS/WallpaperVeilRuntime").write_bytes(b"fixture source engine")
        self.embedded = {"bundle_id": "com.ry00ki.wallpaperveil.launcher", "engine_recompiled_from_source": True,
                         "runtime": {"origin": "source-build", "engine_recompiled_from_source": True,
                                     "source_manifest": {"schema": 1}}}
        self.report = {"signed_launcher_sha256": hashlib.sha256(b"fixture launcher").hexdigest(),
                       "signed_engine_sha256": hashlib.sha256(b"fixture source engine").hexdigest()}

    def write(self):
        for bundle in (self.app, self.helper):
            (bundle / "Contents/Resources/wallpaper-veil-build.json").write_text(json.dumps(self.embedded))
        self.app.with_suffix(".build.json").write_text(json.dumps({**self.embedded, **self.report}))

    def test_source_receipt_survives_package_validation(self):
        self.write()
        self.assertTrue(package.read_build_report(self.app)["engine_recompiled_from_source"])

    def test_official_receipt_survives_package_validation(self):
        self.embedded.update(engine_recompiled_from_source=False,
                             runtime={"origin": "official-release", "engine_recompiled_from_source": False,
                                      "release_pin": {"sha256": "release pin"}})
        self.write()
        self.assertFalse(package.read_build_report(self.app)["engine_recompiled_from_source"])

    def test_external_report_cannot_relabel_source_as_official(self):
        self.write()
        path = self.app.with_suffix(".build.json")
        report = json.loads(path.read_text())
        report["engine_recompiled_from_source"] = False
        path.write_text(json.dumps(report))
        with self.assertRaisesRegex(RuntimeError, "signed application provenance"):
            package.read_build_report(self.app)

    def test_engine_hash_must_match_application(self):
        self.write()
        (self.helper / "Contents/MacOS/WallpaperVeilRuntime").write_bytes(b"other engine")
        with self.assertRaisesRegex(RuntimeError, "executables"):
            package.read_build_report(self.app)

    def test_runtime_origin_and_flags_must_agree(self):
        self.embedded["runtime"]["origin"] = "official-release"
        self.write()
        with self.assertRaisesRegex(RuntimeError, "flags disagree"):
            package.read_build_report(self.app)

    def test_nested_provenance_must_match_outer(self):
        self.write()
        (self.helper / "Contents/Resources/wallpaper-veil-build.json").write_text("{}")
        with self.assertRaisesRegex(RuntimeError, "signed application provenance"):
            package.read_build_report(self.app)

    def test_source_receipt_cannot_drop_the_engine_manifest(self):
        self.embedded["runtime"].pop("source_manifest")
        self.write()
        with self.assertRaisesRegex(RuntimeError, "engine manifest"):
            package.read_build_report(self.app)


if __name__ == "__main__":
    unittest.main()
