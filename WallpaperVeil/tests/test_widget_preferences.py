"""Native widget-preference checks use a memory backend, never system settings."""
import platform
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "Foundation tests require macOS")
class NativeWidgetPreferenceTests(unittest.TestCase):
    def test_fixed_key_reset_verification_and_failures(self):
        source = Path(__file__).with_suffix(".m")
        with tempfile.TemporaryDirectory(prefix="wallpaper-veil-widget-prefs-") as temporary:
            binary = Path(temporary) / "test_widget_preferences"
            subprocess.run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra",
                            str(source), "-framework", "Foundation", "-o", str(binary)],
                           check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("native widget-preference assertions", result.stdout)


if __name__ == "__main__":
    unittest.main()
