"""Validate the single release edit point before a native candidate is built."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from build_local import release_metadata


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wallpaper-veil-version-test-")
        self.addCleanup(temporary.cleanup)
        self.own = Path(temporary.name)
        self.value = {"version": "0.1.4", "build": "5", "release_tag": "v0.1.4-preview.1", "release_channel": "preview"}

    def read(self):
        (self.own / "version.json").write_text(json.dumps(self.value))
        return release_metadata(self.own)

    def test_valid_preview_release(self):
        self.assertEqual(self.read(), self.value)

    def test_valid_stable_release(self):
        self.value.update(release_channel="stable", release_tag="v0.1.4")
        self.assertEqual(self.read(), self.value)

    def test_tag_version_and_channel_must_match(self):
        for changes in ({"release_tag": "v0.1.3-preview.1"}, {"release_tag": "v0.1.4"},
                        {"release_channel": "stable"}, {"release_channel": "nightly"},
                        {"release_tag": "v0.1.4-preview.0"}):
            with self.subTest(changes=changes):
                original = self.value.copy()
                self.value.update(changes)
                with self.assertRaises(RuntimeError):
                    self.read()
                self.value = original

    def test_build_must_be_a_positive_integer_string(self):
        for value in (0, 5, True, "0", "-1", "05", "5.0", ""):
            with self.subTest(value=value):
                self.value["build"] = value
                with self.assertRaises(RuntimeError):
                    self.read()

    def test_version_must_be_three_canonical_numeric_components(self):
        for value in ("1.2", "1.2.3.4", "01.2.3", "1.2.3-preview.1", "v1.2.3", ""):
            with self.subTest(value=value):
                self.value["version"] = value
                with self.assertRaises(RuntimeError):
                    self.read()

    def test_missing_or_unknown_release_fields_are_rejected(self):
        self.value["releaseTag"] = self.value.pop("release_tag")
        with self.assertRaises(RuntimeError):
            self.read()


if __name__ == "__main__":
    unittest.main()
