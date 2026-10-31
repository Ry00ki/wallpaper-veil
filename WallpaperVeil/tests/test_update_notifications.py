"""Offline native notification tests using only an in-memory preferences store."""
import platform
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "Foundation tests require macOS")
class NativeUpdateNotificationTests(unittest.TestCase):
    def test_preferences_reload_failures_and_startup_selection(self):
        source = Path(__file__).with_suffix(".m")
        with tempfile.TemporaryDirectory(prefix="wallpaper-veil-notifications-", suffix=".noindex") as temporary:
            binary = Path(temporary) / "test_update_notifications"
            subprocess.run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra",
                            str(source), "-framework", "Foundation", "-o", str(binary)],
                           check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("native notification assertions", result.stdout)


if __name__ == "__main__":
    unittest.main()
