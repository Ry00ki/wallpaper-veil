"""Native fixture transport tests; no network, app, OS preferences or hardware."""
import platform
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "Foundation tests require macOS")
class NativeUpdateDownloadTests(unittest.TestCase):
    def test_streaming_integrity_cancellation_retry_and_cleanup(self):
        source = Path(__file__).with_suffix(".m")
        native = source.parent.parent / "native/update_download.m"
        with tempfile.TemporaryDirectory(prefix="wallpaper-veil-download-tests-", suffix=".noindex") as temporary:
            binary = Path(temporary) / "test_update_download"
            subprocess.run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra",
                            str(source), str(native), "-framework", "Foundation", "-o", str(binary)],
                           check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=25)
            self.assertIn("native download assertions", result.stdout)


if __name__ == "__main__":
    unittest.main()
