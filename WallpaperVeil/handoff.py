#!/usr/bin/env python3
"""Reversible local Wallpaper Veil install, preflight and runtime handoff."""
from __future__ import annotations
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
from archive_app import archive_app
import subprocess
import time
import uuid

PROJECT = Path.home() / 'Developer/Wallpaper Veil'
BUILT = PROJECT / 'build.noindex/Wallpaper Veil.app'
APP = Path.home() / 'Applications/Wallpaper Veil.app'
SUPPORT = Path.home() / 'Library/Application Support/Wallpaper Veil'
STOCK = Path('/Applications/Hammerspoon.app')
APP_ID = 'com.ry00ki.wallpaperveil'

def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)

def alive(pid):
    try: os.kill(int(pid), 0); return True
    except (ProcessLookupError, ValueError): return False

def executable(pid):
    p=subprocess.run(['/bin/ps','-ww','-p',str(pid),'-o','comm='],capture_output=True,text=True)
    return p.stdout.strip()

def own_pid():
    try:
        pid=int((SUPPORT/'runtime.pid').read_text().strip())
        return pid if alive(pid) and executable(pid).startswith(str(APP)+'/') and Path(executable(pid)).name=='WallpaperVeilRuntime' else None
    except (OSError,ValueError): return None

def stop(pid):
    if not pid or not alive(pid): return
    os.kill(pid,signal.SIGTERM)
    limit=time.monotonic()+8
    while alive(pid) and time.monotonic()<limit: time.sleep(.1)
    if alive(pid): raise RuntimeError(f'Process {pid} did not stop cleanly')

def stock_pids():
    p=subprocess.run(['/usr/bin/pgrep','-x','Hammerspoon'],capture_output=True,text=True)
    if p.returncode not in (0,1): raise RuntimeError(p.stderr)
    return [int(x) for x in p.stdout.split() if executable(x)==str(STOCK/'Contents/MacOS/Hammerspoon')]

def receipt(name,data):
    directory=PROJECT/'receipts';directory.mkdir(parents=True,exist_ok=True)
    path=directory/name
    path.write_text(json.dumps(data,indent=2,ensure_ascii=False)+'\n');path.chmod(0o600)

def wait_report(name,started,timeout=20):
    p=SUPPORT/name;limit=time.monotonic()+timeout
    while time.monotonic()<limit:
        if p.exists() and p.stat().st_mtime>=started-.2:
            try: return json.loads(p.read_text())
            except json.JSONDecodeError: pass
        time.sleep(.15)
    log=SUPPORT/'logs/runtime.log'
    tail=log.read_text()[-6000:] if log.exists() else 'No runtime log'
    raise RuntimeError(f'No fresh {name}.\n{tail}')

def launch(*arguments):
    run(['/usr/bin/open','-n',str(APP),'--args',*arguments])

def install():
    if not BUILT.is_dir(): raise RuntimeError('Build the app first')
    info=plistlib.loads((BUILT/'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') not in {APP_ID,APP_ID+'.launcher'}: raise RuntimeError('Unexpected build identity')
    if own_pid(): raise RuntimeError('Close the current Wallpaper Veil before replacing its bundle')
    APP.parent.mkdir(exist_ok=True)
    stage=APP.parent/f'.WallpaperVeil-install-{uuid.uuid4().hex}.app'
    run(['/usr/bin/ditto','--noqtn',BUILT,stage])
    if APP.exists():
        marker=APP/'Contents/Resources/wallpaper-veil-build.json'
        if not marker.is_file() or json.loads(marker.read_text()).get('bundle_id') not in {APP_ID,APP_ID+'.launcher'}:
            raise RuntimeError('Refusing to replace an unrecognised existing app')
        backup=PROJECT/'backups'/f'Wallpaper Veil-{int(time.time())}.app.zip'
        backup.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        archive_app(APP,backup)
    else:
        backup=None
    run(['/usr/bin/codesign','--verify','--deep','--strict',stage],capture_output=True)
    previous=APP.parent/f'.WallpaperVeil-previous-{uuid.uuid4().hex}'
    if APP.exists(): APP.rename(previous)
    try:
        stage.rename(APP)
    except BaseException:
        if previous.exists(): previous.rename(APP)
        raise
    if previous.exists(): shutil.rmtree(previous)
    shutil.rmtree(BUILT)
    return {'installedApp':str(APP),'buildApp':str(BUILT),'signatureVerified':True,
            'previousAppArchive':str(backup) if backup else None,'buildCopyRemoved':True}

def preflight():
    if own_pid(): raise RuntimeError('A Wallpaper Veil is already running')
    started=time.time();launch('--verify-only')
    result=wait_report('diagnostics.json',started)
    if not result.get('ok') or result.get('mode')!='preflight':
        raise RuntimeError('Preflight failed: '+json.dumps(result))
    p=result['process']
    if p.get('bundleID')!=APP_ID or p.get('settingsDomain')!=APP_ID:
        raise RuntimeError('Incorrect runtime or preferences identity')
    if not p.get('resourcePath','').startswith(str(APP)):
        raise RuntimeError('Preflight did not use the installed bundle')
    limit=time.monotonic()+8
    while own_pid() and time.monotonic()<limit: time.sleep(.1)
    if own_pid(): raise RuntimeError('Preflight did not exit cleanly')
    receipt('preflight.json',result)
    return result

def handoff():
    if own_pid(): raise RuntimeError('Close Wallpaper Veil before a fresh handoff test')
    health=None
    original=stock_pids();state={'startedAtUTC':dt.datetime.now(dt.timezone.utc).isoformat(),
        'originalPids':original,'originalApp':str(STOCK),'targetApp':str(APP),
        'originalConfigurationChanged':False,'loginItemsChanged':False}
    receipt('handoff.json',state)
    try:
        for pid in original: stop(pid)
        started=time.time();launch('--self-test')
        health=wait_report('diagnostics.json',started)
        if not health.get('ok'): raise RuntimeError('Startup checks failed: '+json.dumps(health.get('checks',health)))
        tests=wait_report('acceptance.json',started,25)
        if not tests.get('ok'): raise RuntimeError('Acceptance failed: '+json.dumps(tests))
        state.update({'startupChecksPassed':True,'acceptancePassed':True,
            'accessibilityGranted':health.get('accessibilityGranted',False),'pid':own_pid(),
            'stockStopped':not stock_pids(),'tests':tests})
        receipt('handoff.json',state);receipt('startup.json',health);receipt('acceptance.json',tests)
        return state
    except BaseException as error:
        # A failed acceptance test restores its temporary settings itself. Keep a
        # healthy standalone running when no legacy app was active to return to.
        keep_running=not original and bool(health and health.get('ok')) and own_pid() is not None
        restored=False
        if not keep_running:
            stop(own_pid())
            if original:
                run(['/usr/bin/open',STOCK]);restored=True
        state.update({'error':str(error),'rolledBack':restored,
                      'standaloneKeptRunning':keep_running})
        receipt('handoff.json',state)
        raise

def rollback():
    # Legacy cleanup may have archived this app. Validate recovery before
    # stopping Wallpaper Veil; never silently resurrect an archived installation.
    info_path=STOCK/'Contents/Info.plist'
    if not info_path.is_file():
        raise RuntimeError('Legacy app is absent. Restore your explicit app/config/preferences backup first; Wallpaper Veil remains running.')
    info=plistlib.loads(info_path.read_bytes())
    if info.get('CFBundleIdentifier')!='org.hammerspoon.Hammerspoon':
        raise RuntimeError('Unexpected legacy application identity; Wallpaper Veil remains running')
    stop(own_pid());run(['/usr/bin/open',STOCK])
    return {'originalAppRelaunched':str(STOCK),'configurationChanged':False}

def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=['install','preflight','handoff','rollback','status'])
    args=parser.parse_args()
    if args.mode=='install': value=install()
    elif args.mode=='preflight': value=preflight()
    elif args.mode=='handoff': value=handoff()
    elif args.mode=='rollback': value=rollback()
    else: value={'wallpaperVeilPid':own_pid(),'originalPids':stock_pids()}
    print(json.dumps(value,indent=2,ensure_ascii=False))

if __name__=='__main__': main()
