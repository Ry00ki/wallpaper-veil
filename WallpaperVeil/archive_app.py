#!/usr/bin/env python3
"""Preserve an app as a verified ZIP instead of a searchable app copy."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile


def manifest(root: Path) -> dict:
    result = {}
    for base, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(base) / name
            relative = str(path.relative_to(root))
            if path.is_symlink():
                result[relative] = ('link', os.readlink(path))
            elif path.is_file():
                result[relative] = ('file', hashlib.sha256(path.read_bytes()).hexdigest(),
                                    stat.S_IMODE(path.stat().st_mode))
            elif path.is_dir():
                result[relative] = ('directory', stat.S_IMODE(path.stat().st_mode))
            else:
                raise RuntimeError(f'Unsupported archive entry: {relative}')
    return result


def archive_app(app: Path, destination: Path) -> dict:
    """Archive and read back all files, links and modes; leave the source intact."""
    app = app.expanduser().absolute()
    destination = destination.expanduser().absolute()
    if app.suffix != '.app' or app.is_symlink() or not (app/'Contents/Info.plist').is_file():
        raise RuntimeError('Expected an existing app bundle, not a link')
    if destination.suffix != '.zip' or destination.exists() or destination.is_relative_to(app):
        raise RuntimeError('Choose a new ZIP path outside the app')
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    before = manifest(app)
    stage = destination.with_name('.' + destination.name + '.partial')
    if stage.exists():
        raise RuntimeError('An incomplete archive already exists; inspect it first')
    try:
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr',
                        '--keepParent', str(app), str(stage)], check=True)
        with tempfile.TemporaryDirectory(prefix='.wallpaper-veil-archive-',
                                          dir=destination.parent) as temporary:
            subprocess.run(['/usr/bin/ditto', '--noqtn', '-x', '-k', str(stage), temporary], check=True)
            after = manifest(Path(temporary)/app.name)
        if before != after or before != manifest(app):
            raise RuntimeError('Archive read-back or unchanged-source verification failed')
        stage.chmod(0o600)
        stage.rename(destination)
    except BaseException:
        if stage.exists():
            stage.unlink()
        raise
    return {'source': str(app), 'archive': str(destination), 'entries': len(before),
            'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
            'contentLinksAndModesVerified': True, 'sourceRemoved': False}
