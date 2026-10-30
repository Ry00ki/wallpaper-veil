#!/usr/bin/env python3
"""Generate Wallpaper Veil app icons with AppKit and iconutil; no remote assets."""
from pathlib import Path
import argparse
import shutil
import struct
import subprocess
import tempfile

def main():
    own = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=own)
    args = parser.parse_args()
    output = args.output_dir.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    sizes = {
        "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
    }
    with tempfile.TemporaryDirectory(prefix="wallpaper-veil-icon-") as temporary:
        stage = Path(temporary)
        renderer = stage / "render_icon"
        clang = subprocess.check_output(["/usr/bin/xcrun", "--find", "clang"], text=True).strip()
        sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        subprocess.run([clang, "-isysroot", sdk, "-fobjc-arc", "-O2", "-framework", "AppKit",
                        "-framework", "CoreGraphics", str(own / "render_icon.m"), "-o", str(renderer)], check=True)
        iconset = stage / "WallpaperVeil.iconset"
        iconset.mkdir()
        for name, size in sizes.items():
            subprocess.run([str(renderer), str(iconset / name), str(size)], check=True)
        shutil.copy2(iconset / "icon_512x512@2x.png", output / "WallpaperVeil.png")
        retained = output / "WallpaperVeil.iconset"
        if retained.exists():
            shutil.rmtree(retained)
        shutil.copytree(iconset, retained)
        result = subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset),
                                 "-o", str(output / "WallpaperVeil.icns")], capture_output=True, text=True)
        if result.returncode:
            # Some system iconutil encoders reject even their own extracted
            # iconsets. Package the rendered PNG members losslessly instead.
            members = {
                b"icp4": "icon_16x16.png", b"ic11": "icon_16x16@2x.png",
                b"icp5": "icon_32x32.png", b"ic12": "icon_32x32@2x.png",
                b"ic07": "icon_128x128.png", b"ic13": "icon_128x128@2x.png",
                b"ic08": "icon_256x256.png", b"ic14": "icon_256x256@2x.png",
                b"ic09": "icon_512x512.png", b"ic10": "icon_512x512@2x.png",
            }
            chunks = []
            for kind, name in members.items():
                payload = (iconset / name).read_bytes()
                chunks.append(struct.pack(">4sI", kind, len(payload) + 8) + payload)
            payload = b"".join(chunks)
            (output / "WallpaperVeil.icns").write_bytes(struct.pack(">4sI", b"icns", len(payload) + 8) + payload)
        decoded = stage / "validated.iconset"
        subprocess.run(["/usr/bin/iconutil", "-c", "iconset", str(output / "WallpaperVeil.icns"),
                        "-o", str(decoded)], check=True)
        if not (decoded / "icon_512x512@2x.png").is_file():
            raise RuntimeError("The generated icon did not decode at full resolution")
    if own != output:
        shutil.copy2(own / "WallpaperVeil.svg", output / "WallpaperVeil.svg")
    print(output / "WallpaperVeil.icns")

if __name__ == "__main__":
    main()
