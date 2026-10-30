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


def read_build_report(app: Path) -> dict:
    report_path = app.with_suffix('.build.json')
    if not report_path.is_file():
        raise RuntimeError('The builder report is missing; refusing an undocumented preview')
    report = json.loads(report_path.read_text())
    embedded = json.loads((app / 'Contents/Resources/wallpaper-veil-build.json').read_text())
    nested = json.loads((app / 'Contents/Helpers/Wallpaper Veil Runtime.app/Contents/Resources/wallpaper-veil-build.json').read_text())
    if nested != embedded or any(report.get(key) != value for key, value in embedded.items()):
        raise RuntimeError('Builder report does not match the signed application provenance')
    binaries = {'signed_launcher_sha256': app / 'Contents/MacOS/WallpaperVeil',
                'signed_engine_sha256': app / 'Contents/Helpers/Wallpaper Veil Runtime.app/Contents/MacOS/WallpaperVeilRuntime'}
    for key, path in binaries.items():
        if report.get(key) != hashlib.sha256(path.read_bytes()).hexdigest():
            raise RuntimeError('Builder report does not match the signed application executables')
    runtime = report.get('runtime', {})
    origin = runtime.get('origin')
    source_built = report.get('engine_recompiled_from_source')
    if (origin not in {'official-release', 'source-build'} or type(source_built) is not bool
            or source_built != (origin == 'source-build')
            or runtime.get('engine_recompiled_from_source') is not source_built):
        raise RuntimeError('Builder runtime origin and source-build flags disagree')
    if source_built and not isinstance(runtime.get('source_manifest'), dict):
        raise RuntimeError('Source-built application is missing its engine manifest')
    if not source_built and not isinstance(runtime.get('release_pin'), dict):
        raise RuntimeError('Official-runtime application is missing its release pin')
    return report


def package(app: Path, destination: Path) -> Path:
    if platform.system() != 'Darwin':
        raise RuntimeError('Native signature verification requires macOS')
    if app.name != 'Wallpaper Veil.app':
        raise RuntimeError('The app bundle must be named Wallpaper Veil.app')
    if destination == app or destination.is_relative_to(app):
        raise RuntimeError('Artifact output must remain outside the signed app bundle')
    destination.mkdir(parents=True, exist_ok=True)
    verify(app)
    report = read_build_report(app)
    archive = destination / 'wallpaper-veil-preview.zip'
    if archive.exists():
        raise RuntimeError('Choose an artifact directory without an existing preview ZIP')
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr', '--keepParent',
                    str(app), str(archive)], check=True)
    with tempfile.TemporaryDirectory(prefix='wallpaper-veil-extraction-', suffix='.noindex') as temporary:
        extracted = Path(temporary)
        subprocess.run(['/usr/bin/ditto', '--noqtn', '-x', '-k', str(archive), str(extracted)], check=True)
        verify(extracted / app.name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(f'{digest}  {archive.name}\n')
    shutil.copy2(app.with_suffix('.build.json'), destination / 'wallpaper-veil-build.json')
    runtime = report['runtime']
    if runtime['origin'] == 'source-build':
        receipt_name, receipt = 'wallpaper-veil-source-engine.json', runtime['source_manifest']
    else:
        receipt_name, receipt = 'wallpaper-veil-runtime-pin.json', runtime['release_pin']
    (destination / receipt_name).write_text(json.dumps(receipt, indent=2) + '\n')
    summary = {
        'project': 'Wallpaper Veil', 'archive': archive.name, 'sha256': digest,
        'extracted_signatures_verified': True, 'app_launched': False,
        'runtime_origin': runtime['origin'],
        'engine_recompiled_from_source': report['engine_recompiled_from_source'],
        'launcher_recompiled_from_source': report['launcher_recompiled_from_source'],
        'ui_recompiled_from_source': report['ui_recompiled_from_source'],
        'distribution': 'Experimental preview, ad hoc signed; not Developer ID signed or notarized',
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
