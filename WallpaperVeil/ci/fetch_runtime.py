#!/usr/bin/env python3
"""Fetch the pinned official native runtime; never launch it or change settings."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import platform
import plistlib
import subprocess
import tempfile
import urllib.request
import zipfile


def fetch(destination: Path) -> Path:
    if platform.system() != 'Darwin':
        raise RuntimeError('Native runtime extraction and signature checks require macOS')
    pin = json.loads(Path(__file__).with_name('runtime.json').read_text())
    if destination.exists() and any(destination.iterdir()):
        raise RuntimeError('Choose an empty runtime extraction directory')
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='wallpaper-veil-runtime-') as temporary:
        archive = Path(temporary) / pin['asset_name']
        digest = hashlib.sha256()
        length = 0
        request = urllib.request.Request(pin['download_url'], headers={'User-Agent': 'Wallpaper-Veil-build'})
        with urllib.request.urlopen(request, timeout=60) as response, archive.open('wb') as target:
            if not response.geturl().startswith('https://'):
                raise RuntimeError('Refusing a non-HTTPS download redirect')
            for block in iter(lambda: response.read(1024 * 1024), b''):
                length += len(block)
                digest.update(block)
                target.write(block)
        if digest.hexdigest() != pin['sha256'] or length != pin['size_bytes']:
            raise RuntimeError('The official runtime archive does not match the pinned digest and size')
        with zipfile.ZipFile(archive) as entries:
            for info in entries.infolist():
                path = PurePosixPath(info.filename)
                if path.is_absolute() or '..' in path.parts:
                    raise RuntimeError('Unexpected unsafe path in the runtime archive')
        subprocess.run(['/usr/bin/ditto', '--noqtn', '-x', '-k', str(archive), str(destination)], check=True)
    app = destination / 'Hammerspoon.app'
    metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if (metadata.get('CFBundleIdentifier') != 'org.hammerspoon.Hammerspoon'
            or metadata.get('CFBundleShortVersionString') != pin['version']
            or metadata.get('CFBundleVersion') != pin['build']):
        raise RuntimeError('The extracted native runtime identity does not match its pin')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print(f'Verified pinned native runtime {pin["version"]} ({pin["sha256"]})')
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    fetch(args.destination.expanduser().resolve())


if __name__ == '__main__':
    main()
