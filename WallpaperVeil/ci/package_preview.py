#!/usr/bin/env python3
"""Archive Wallpaper Veil and verify its extracted signatures without launching it."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile


def verify(app: Path) -> None:
    helper = app / 'Contents/Helpers/Wallpaper Veil Runtime.app'
    expected = [(app, 'com.ry00ki.wallpaperveil.launcher', 'WallpaperVeil'),
                (helper, 'com.ry00ki.wallpaperveil', 'WallpaperVeilRuntime')]
    for bundle, identity, executable in expected:
        metadata = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        if metadata.get('CFBundleIdentifier') != identity or metadata.get('CFBundleExecutable') != executable:
            raise RuntimeError('Unexpected Wallpaper Veil bundle layout or executable identity')
        if not (bundle / 'Contents/MacOS' / executable).is_file():
            raise RuntimeError('A declared native executable is missing')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], check=True)


def package(app: Path, destination: Path) -> Path:
    if platform.system() != 'Darwin':
        raise RuntimeError('Native signature verification requires macOS')
    if app.name != 'Wallpaper Veil.app':
        raise RuntimeError('The app bundle must be named Wallpaper Veil.app')
    if destination == app or destination.is_relative_to(app):
        raise RuntimeError('Artifact output must remain outside the signed app bundle')
    destination.mkdir(parents=True, exist_ok=True)
    verify(app)
    archive = destination / 'wallpaper-veil-private-preview.zip'
    if archive.exists():
        raise RuntimeError('Choose an artifact directory without an existing preview ZIP')
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent',
                    str(app), str(archive)], check=True)
    with tempfile.TemporaryDirectory(prefix='wallpaper-veil-extraction-') as temporary:
        extracted = Path(temporary)
        subprocess.run(['/usr/bin/ditto', '--noqtn', '-x', '-k', str(archive), str(extracted)], check=True)
        verify(extracted / app.name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(f'{digest}  {archive.name}\n')
    build_report = app.with_suffix('.build.json')
    if not build_report.is_file():
        raise RuntimeError('The builder report is missing; refusing an undocumented preview')
    shutil.copy2(build_report, destination / 'wallpaper-veil-build.json')
    shutil.copy2(Path(__file__).with_name('runtime.json'), destination / 'wallpaper-veil-runtime-pin.json')
    summary = {
        'project': 'Wallpaper Veil', 'archive': archive.name, 'sha256': digest,
        'extracted_signatures_verified': True, 'app_launched': False,
        'engine_recompiled_from_source': False, 'launcher_recompiled_from_source': True,
        'ui_recompiled_from_source': True,
        'distribution': 'Private local preview, ad hoc signed; not notarized or App Store approved',
    }
    (destination / 'wallpaper-veil-package.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return archive


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    package(args.app.expanduser().resolve(), args.destination.expanduser().resolve())


if __name__ == '__main__':
    main()
