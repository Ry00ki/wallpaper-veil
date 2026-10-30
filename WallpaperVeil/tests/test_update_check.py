"""Offline native release-comparison tests; no app, network or display access."""
import platform
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "Foundation tests require macOS")
class NativeUpdateCheckTests(unittest.TestCase):
    def test_release_rules_and_api_failures(self):
        source = Path(__file__).with_suffix(".m")
        with tempfile.TemporaryDirectory(prefix="wallpaper-veil-updates-") as temporary:
            binary = Path(temporary) / "test_update_check"
            subprocess.run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra",
                            str(source), "-framework", "Foundation", "-o", str(binary)],
                           check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("native update-check assertions", result.stdout)


if __name__ == "__main__":
    unittest.main()
