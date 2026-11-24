"""Compile/test pure local shortcut policy; no native window or input capture."""
from pathlib import Path
import subprocess
import tempfile
import unittest

class ShortcutRecorderTests(unittest.TestCase):
    def test_physical_chords(self):
        own = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="wallpaper-veil-shortcut-policy-") as directory:
            executable = Path(directory) / "shortcut-policy"
            subprocess.run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra",
                "-I", str(own / "native"), str(own / "tests/test_shortcut_recorder.m"),
                "-framework", "AppKit", "-o", str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

if __name__ == "__main__":
    unittest.main()
