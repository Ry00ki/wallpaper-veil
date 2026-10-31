"""Adversarial native ZIP/bundle/atomic-swap checks. No app launches or preferences."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import plistlib
import stat
import struct
import subprocess
import tempfile
import unittest
import zipfile
import zlib

ROOT = 'Wallpaper Veil.app/'
INFO = ROOT + 'Contents/Info.plist'
INNER_INFO = ROOT + 'Contents/Helpers/Wallpaper Veil Runtime.app/Contents/Info.plist'


@unittest.skipUnless(platform.system() == 'Darwin', 'Native updater tests require macOS')
class NativeUpdatePackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiled = tempfile.TemporaryDirectory(prefix='wallpaper-veil-native-update-')
        cls.binary = Path(cls.compiled.name) / 'package-tests'
        subprocess.run(['/usr/bin/xcrun', 'clang', '-fobjc-arc', '-Wno-deprecated-declarations',
                        str(Path(__file__).with_suffix('.m')), '-framework', 'Foundation',
                        '-framework', 'AppKit', '-framework', 'Security', '-lz', '-o', str(cls.binary)],
                       check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.compiled.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='wallpaper-veil-package-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def invoke(self, operation, *paths, good=True):
        result = subprocess.run([str(self.binary), operation, *map(str, paths)], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, good, result.stdout + result.stderr)
        return result

    def archive(self, additions=(), *, compression=zipfile.ZIP_DEFLATED):
        path = self.root / 'fixture.zip'
        with zipfile.ZipFile(path, 'w', compression=compression) as z:
            for name, content, mode in [(INFO, b'outer', stat.S_IFREG | 0o644),
                    (INNER_INFO, b'inner', stat.S_IFREG | 0o644), *additions]:
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = mode << 16
                entry.compress_type = compression
                z.writestr(entry, content)
        return path

    def mutate(self, archive, offset, value):
        data = bytearray(archive.read_bytes()); data[offset:offset+len(value)] = value; archive.write_bytes(data)

    def test_regular_stored_and_deflated_files_extract_exactly(self):
        for method in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            with self.subTest(method=method):
                archive = self.archive([(ROOT+'Contents/data', b'photos'*10000, stat.S_IFREG | 0o644),
                    (ROOT+'Contents/executable', b'code', stat.S_IFREG | 0o755)], compression=method)
                self.invoke('inspect', archive)
                out = self.root / str(method); out.mkdir(mode=0o700)
                self.invoke('extract', archive, out)
                self.assertEqual((out / ROOT / 'Contents/data').read_bytes(), b'photos'*10000)
                self.assertTrue((out / ROOT / 'Contents/executable').stat().st_mode & 0o111)

    def test_data_descriptors_are_supported_and_must_match(self):
        class Streaming(io.BytesIO):
            def seekable(self): return False
            def seek(self, *args): raise io.UnsupportedOperation()
        stream = Streaming()
        with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as z:
            z.writestr(INFO, b'outer'); z.writestr(INNER_INFO, b'inner')
        path = self.root / 'descriptor.zip'; path.write_bytes(stream.getvalue())
        self.invoke('inspect', path)
        data=path.read_bytes(); where=data.index(b'PK\x07\x08')
        self.mutate(path,where+4,b'\x00\x00\x00\x00')
        self.invoke('inspect',path,good=False)

    def test_existing_private_destination_is_never_overwritten(self):
        archive=self.archive(); out=self.root/'output';out.mkdir(mode=0o700)
        marker=out/'keep';marker.write_text('original')
        self.invoke('extract',archive,out,good=False)
        self.assertEqual(marker.read_text(),'original')
        link=self.root/'linked';link.symlink_to(out,target_is_directory=True)
        self.invoke('extract',archive,link,good=False)

    def test_unsafe_paths_and_file_types_are_rejected_before_extraction(self):
        paths=['../outside','/outside','C:/outside',ROOT+'../outside',ROOT+'Contents//x',ROOT+'Contents/./x',
               ROOT+'Contents/a\\b',ROOT+'Contents/x:y',ROOT+'Contents/line\nx','Another.app/x']
        for name in paths:
            with self.subTest(name=name): self.invoke('inspect',self.archive([(name,b'x',stat.S_IFREG|0o644)]),good=False)
        for mode in (stat.S_IFCHR|0o600,stat.S_IFIFO|0o600,stat.S_IFSOCK|0o600,stat.S_IFREG|0o4755):
            with self.subTest(mode=mode): self.invoke('inspect',self.archive([(ROOT+'Contents/unsafe',b'x',mode)]),good=False)

    def test_duplicate_unicode_case_and_implicit_parent_aliases_are_rejected(self):
        for first,second in [('same','same'),('Capital','capital'),('caf\u00e9','cafe\u0301'),('Folder/a','folder/b'),('Stra\u00dfe/a','STRASSE/b')]:
            with self.subTest(first=first,second=second):
                self.invoke('inspect',self.archive([(ROOT+'Contents/'+first,b'1',stat.S_IFREG|0o644),
                    (ROOT+'Contents/'+second,b'2',stat.S_IFREG|0o644)]),good=False)

    def test_internal_symlinks_extract_last_without_following_them(self):
        archive=self.archive([(ROOT+'Contents/F/Versions/A/code',b'code',stat.S_IFREG|0o755),
            (ROOT+'Contents/F/Versions/Current',b'A',stat.S_IFLNK|0o777),
            (ROOT+'Contents/F/code',b'Versions/Current/code',stat.S_IFLNK|0o777)])
        self.invoke('inspect',archive);out=self.root/'output';out.mkdir(mode=0o700);self.invoke('extract',archive,out)
        self.assertEqual(os.readlink(out/ROOT/'Contents/F/code'),'Versions/Current/code')
        self.assertEqual((out/ROOT/'Contents/F/code').read_bytes(),b'code')

    def test_symlink_escape_cycles_dangling_and_descendant_writes_are_rejected(self):
        cases=[[(ROOT+'Contents/link',b'../../outside',stat.S_IFLNK|0o777)],
               [(ROOT+'Contents/link',b'/tmp/outside',stat.S_IFLNK|0o777)],
               [(ROOT+'Contents/link',b'missing',stat.S_IFLNK|0o777)],
               [(ROOT+'Contents/a',b'b',stat.S_IFLNK|0o777),(ROOT+'Contents/b',b'a',stat.S_IFLNK|0o777)],
               [(ROOT+'Contents/link',b'.',stat.S_IFLNK|0o777),(ROOT+'Contents/link/child',b'bad',stat.S_IFREG|0o644)]]
        for additions in cases:
            with self.subTest(additions=additions): self.invoke('inspect',self.archive(additions),good=False)

    def test_crc_corruption_local_headers_and_compression_mismatch_are_rejected(self):
        for offset,value in [(8,struct.pack('<H',99)),(6,struct.pack('<H',1)),(30,b'X'),(14,b'\0'*4)]:
            with self.subTest(offset=offset):
                archive=self.archive(compression=zipfile.ZIP_STORED);self.mutate(archive,offset,value);self.invoke('inspect',archive,good=False)
        archive=self.archive(compression=zipfile.ZIP_STORED);data=archive.read_bytes();where=data.index(b'outer');self.mutate(archive,where,b'X');self.invoke('inspect',archive,good=False)

    def test_bad_offsets_overlaps_zip64_multidisk_and_trailing_data_are_rejected(self):
        for field,value in [(42,struct.pack('<I',0xffffffff)),(20,struct.pack('<I',0xffffffff)),(6,struct.pack('<H',45)),(34,struct.pack('<H',1))]:
            with self.subTest(field=field):
                archive=self.archive();data=archive.read_bytes();where=data.index(b'PK\x01\x02');self.mutate(archive,where+field,value);self.invoke('inspect',archive,good=False)
        archive=self.archive();data=archive.read_bytes();first=data.index(b'PK\x01\x02');second=data.index(b'PK\x01\x02',first+4);self.mutate(archive,second+42,data[first+42:first+46]);self.invoke('inspect',archive,good=False)
        archive=self.archive();archive.write_bytes(archive.read_bytes()+b'trailing');self.invoke('inspect',archive,good=False)

    def test_declared_small_decompression_bomb_is_bounded(self):
        archive=self.archive([(ROOT+'Contents/bomb',b'x'*2000000,stat.S_IFREG|0o644)])
        data=archive.read_bytes();position=data.rindex(b'PK\x01\x02');local=struct.unpack_from('<I',data,position+42)[0]
        self.mutate(archive,position+24,struct.pack('<I',1));self.mutate(archive,local+22,struct.pack('<I',1));self.invoke('inspect',archive,good=False)

    def test_excessive_entries_and_unknown_extra_fields_are_rejected(self):
        archive=self.archive([(ROOT+f'Contents/x{i}',b'',stat.S_IFREG|0o644) for i in range(4096)])
        self.invoke('inspect',archive,good=False)
        path=self.root/'extra.zip'
        with zipfile.ZipFile(path,'w') as z:
            entry=zipfile.ZipInfo(INFO);entry.extra=struct.pack('<HH',0x7075,0);z.writestr(entry,b'outer');z.writestr(INNER_INFO,b'inner')
        self.invoke('inspect',path,good=False)

    def test_atomic_swap_round_trip_and_missing_candidate_leave_original_safe(self):
        target=self.root/'target';candidate=self.root/'candidate';target.mkdir();candidate.mkdir()
        (target/'marker').write_text('old');(candidate/'marker').write_text('new')
        self.invoke('swap',target,candidate);self.assertEqual((target/'marker').read_text(),'new');self.assertEqual((candidate/'marker').read_text(),'old')
        self.invoke('swap',target,candidate);self.assertEqual((target/'marker').read_text(),'old')
        self.invoke('swap',target,self.root/'missing',good=False);self.assertEqual((target/'marker').read_text(),'old')

    def make_bundle(self, directory=None, version='1.0.0', build='10'):
        app=(directory or self.root)/'Wallpaper Veil.app';inner=app/'Contents/Helpers/Wallpaper Veil Runtime.app'
        for directory in (app/'Contents/MacOS',app/'Contents/Resources',inner/'Contents/MacOS',inner/'Contents/Resources/WallpaperVeil'):
            directory.mkdir(parents=True,exist_ok=True)
        (app/'Contents/MacOS/WallpaperVeil').write_bytes(b'outer native executable')
        (inner/'Contents/MacOS/WallpaperVeilRuntime').write_bytes(b'inner native executable')
        (inner/'Contents/Resources/setup.lua').write_bytes(b'bootstrap')
        (inner/'Contents/Resources/WallpaperVeil/init.lua').write_bytes(b'app code')
        sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
        provenance={'bundle_id':'com.ry00ki.wallpaperveil.launcher','runtime_bundle_id':'com.ry00ki.wallpaperveil',
            'version':version,'build':build,'release_tag':'v'+version,'release_channel':'stable',
            'source':{'local_head':'a'*40,'worktree_status':[]},
            'bundled_lua_hashes':{'WallpaperVeil/init.lua':sha(inner/'Contents/Resources/WallpaperVeil/init.lua')},
            'bundled_setup_sha256':sha(inner/'Contents/Resources/setup.lua')}
        for bundle,identity,executable in [(app,'com.ry00ki.wallpaperveil.launcher','WallpaperVeil'),(inner,'com.ry00ki.wallpaperveil','WallpaperVeilRuntime')]:
            info={'CFBundleIdentifier':identity,'CFBundleExecutable':executable,'CFBundleShortVersionString':version,
                  'CFBundleVersion':build,'WVReleaseTag':'v'+version,'WVReleaseChannel':'stable','LSMinimumSystemVersion':'13.0'}
            (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            (bundle/'Contents/Resources/wallpaper-veil-build.json').write_text(json.dumps(provenance))
        receipt=copy.deepcopy(provenance);receipt.update(signed_launcher_sha256=sha(app/'Contents/MacOS/WallpaperVeil'),signed_engine_sha256=sha(inner/'Contents/MacOS/WallpaperVeilRuntime'))
        release={'tag':'v'+version,'version':version,'channel':'stable','buildReceipt':receipt}
        path=self.root/'release.json';path.write_text(json.dumps(release));return app,inner,path,release

    def test_complete_bundle_receipt_identity_and_hashes_match(self):
        app,_,path,_=self.make_bundle();self.invoke('bundle',app,path)
        self.invoke('signature',app,good=False) # no fixture bypass in this operation

    def test_bundle_version_source_code_setup_and_executable_tampering_fail(self):
        app,inner,path,release=self.make_bundle()
        for change in ('tag','receiptHash','source','code','setup','extraLua','nestedProvenance','info'):
            with self.subTest(change=change):
                backup={p:p.read_bytes() for p in app.rglob('*') if p.is_file()};original=copy.deepcopy(release)
                if change=='tag': release['tag']='v2.0.0'
                elif change=='receiptHash': release['buildReceipt']['signed_launcher_sha256']='0'*64
                elif change=='source': release['buildReceipt']['source']['local_head']='b'*40
                elif change=='code': (inner/'Contents/Resources/WallpaperVeil/init.lua').write_bytes(b'changed')
                elif change=='setup': (inner/'Contents/Resources/setup.lua').write_bytes(b'changed')
                elif change=='extraLua': (inner/'Contents/Resources/WallpaperVeil/extra.lua').write_bytes(b'code')
                elif change=='nestedProvenance': (inner/'Contents/Resources/wallpaper-veil-build.json').write_text('{}')
                elif change=='info': (inner/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'evil'}))
                path.write_text(json.dumps(release));self.invoke('bundle',app,path,good=False)
                for p in app.rglob('*'):
                    if p.is_file() and p not in backup:p.unlink()
                for p,data in backup.items():p.write_bytes(data)
                release=original


    def transaction(self, phase, swapped=False):
        old,_,_,old_release=self.make_bundle(self.root/'installed','0.9.0','9')
        new,_,_,new_release=self.make_bundle(self.root/'replacement','1.0.0','10')
        job=self.root/'job';job.mkdir(mode=0o700)
        request={'schema':1,'jobDir':str(job),'nonce':'a'*64,'targetApp':str(old),'candidateApp':str(new),
            'replacementDirectory':str(new.parent),'oldTag':'v0.9.0','oldBuild':'9','tag':'v1.0.0','build':'10',
            'sourceCommit':'a'*40,'oldPID':42,'createdAt':1000,
            'oldLauncherSHA256':old_release['buildReceipt']['signed_launcher_sha256'],
            'oldRuntimeSHA256':old_release['buildReceipt']['signed_engine_sha256'],
            'newLauncherSHA256':new_release['buildReceipt']['signed_launcher_sha256'],
            'newRuntimeSHA256':new_release['buildReceipt']['signed_engine_sha256']}
        # Versions differ even though fixture native executable bytes are equal.
        if swapped:self.invoke('swap',old,new)
        (job/'journal.json').write_text(json.dumps({'phase':phase,'nonce':request['nonce']}));(job/'journal.json').chmod(0o600)
        path=job/'fixture.json';path.write_text(json.dumps(request));return request,path,old,new,job

    def test_recovery_before_swap_relaunches_original_without_replacement(self):
        for phase in ('prepared','waiting','cancelled','swapping'):
            with self.subTest(phase=phase):
                holder=self.root;self.root=holder/phase;self.root.mkdir()
                r,path,target,candidate,job=self.transaction(phase)
                self.invoke('recover',path)
                self.assertEqual(plistlib.loads((target/'Contents/Info.plist').read_bytes())['WVReleaseTag'],'v0.9.0')
                self.assertEqual(plistlib.loads((job/'launches.plist').read_bytes()),['old'])
                self.root=holder

    def test_recovery_after_swap_without_ack_atomically_rolls_back_and_relaunches_old(self):
        for phase in ('swapping','swapped','launching','rollingBack','recoveryRequired'):
            with self.subTest(phase=phase):
                holder=self.root;self.root=holder/phase;self.root.mkdir()
                r,path,target,candidate,job=self.transaction(phase,swapped=True)
                self.invoke('recover',path)
                self.assertEqual(plistlib.loads((target/'Contents/Info.plist').read_bytes())['WVReleaseTag'],'v0.9.0')
                self.assertEqual(json.loads((job/'journal.json').read_text())['phase'],'rolledBack')
                self.assertEqual(plistlib.loads((job/'launches.plist').read_bytes()),['old'])
                self.root=holder

    def test_failed_new_launch_and_missing_health_ack_use_actual_rollback_path(self):
        r,path,target,candidate,job=self.transaction('launching',swapped=True)
        self.invoke('launchFailure',path)
        self.assertEqual(plistlib.loads((target/'Contents/Info.plist').read_bytes())['WVReleaseTag'],'v0.9.0')
        self.assertEqual(plistlib.loads((job/'launches.plist').read_bytes()),['new','old'])
        self.assertEqual(json.loads((job/'journal.json').read_text())['phase'],'rolledBack')

    def test_failed_candidate_shutdown_retains_both_versions_and_requires_recovery(self):
        r,path,target,candidate,job=self.transaction('launching',swapped=True);r['fixtureStopFailure']=True;path.write_text(json.dumps(r))
        self.invoke('rollback',path,good=False)
        self.assertEqual(plistlib.loads((target/'Contents/Info.plist').read_bytes())['WVReleaseTag'],'v1.0.0')
        self.assertEqual(plistlib.loads((candidate/'Contents/Info.plist').read_bytes())['WVReleaseTag'],'v0.9.0')
        self.assertEqual(json.loads((job/'journal.json').read_text())['phase'],'recoveryRequired')
        self.assertFalse((job/'launches.plist').exists())

    def test_recovery_with_changed_bundle_preserves_backup_without_guessing(self):
        r,path,target,candidate,job=self.transaction('swapped',swapped=True)
        (candidate/'Contents/MacOS/WallpaperVeil').write_bytes(b'tampered')
        self.invoke('recover',path,good=False)
        self.assertEqual(plistlib.loads((target/'Contents/Info.plist').read_bytes())['WVReleaseTag'],'v1.0.0')
        self.assertTrue(candidate.exists());self.assertFalse((job/'launches.plist').exists())

    def test_passive_health_receipt_binds_nonce_version_process_path_and_freshness(self):
        r,path,_,_,_=self.transaction('launching',swapped=True)
        executable=r['targetApp']+'/Contents/Helpers/Wallpaper Veil Runtime.app/Contents/MacOS/WallpaperVeilRuntime'
        health={'ok':True,'nonce':r['nonce'],'tag':r['tag'],'build':r['build'],'sourceCommit':r['sourceCommit'],
            'pid':43,'executablePath':executable,'installedAppPath':r['targetApp']}
        process={'pid':43,'executablePath':executable,'bundlePath':r['targetApp']+'/Contents/Helpers/Wallpaper Veil Runtime.app',
            'bundleID':'com.ry00ki.wallpaperveil','launchTime':1001}
        r.update(fixtureHealth=health,fixtureProcess=process);path.write_text(json.dumps(r));self.invoke('health',path)
        for key,value in [('nonce','b'*64),('tag','v9.0.0'),('build','1'),('sourceCommit','b'*40),('pid',42),
                ('executablePath','/tmp/other'),('installedAppPath','/tmp/other'),('ok',False)]:
            with self.subTest(key=key):
                bad=copy.deepcopy(r);bad['fixtureHealth'][key]=value;path.write_text(json.dumps(bad));self.invoke('health',path,good=False)
        bad=copy.deepcopy(r);bad['fixtureProcess']['launchTime']=1;path.write_text(json.dumps(bad));self.invoke('health',path,good=False)
        bad=copy.deepcopy(r);bad['fixtureProcess']['bundleID']='other';path.write_text(json.dumps(bad));self.invoke('health',path,good=False)


    def test_publisher_identity_cannot_be_removed_or_changed_after_developer_id_upgrade(self):
        self.invoke('signer','','');self.invoke('signer','','NEWTEAM')
        self.invoke('signer','TEAM','TEAM');self.invoke('signer','TEAM','',good=False);self.invoke('signer','TEAM','OTHER',good=False)
        app,_,_,_=self.make_bundle()
        self.invoke('publisher',app,'FAKETEAM00',good=False)
        self.invoke('publisher',app,'unsafe\"rule',good=False)

    @unittest.skipIf(os.getuid()==0,'Permission test needs an ordinary user')
    def test_unwritable_install_parent_fails_before_quit_or_swap(self):
        parent=self.root/'applications';parent.mkdir();app=parent/'Wallpaper Veil.app';app.mkdir()
        self.invoke('writable',app);parent.chmod(0o500)
        try:self.invoke('writable',app,good=False)
        finally:parent.chmod(0o700)

    def test_private_request_validation_accepts_fractional_timestamp_and_rejects_bad_types(self):
        r,path,_,_,job=self.transaction('prepared')
        r.update(helperPath=str(job/'WallpaperVeilUpdater'),helperSHA256='0'*64,release={},createdAt=1000.125)
        record=job/'request.json';record.write_text(json.dumps(r));record.chmod(0o600)
        self.invoke('request',job)
        for key,value in [('createdAt',None),('oldPID',True),('schema',True),('release',[]),('targetApp','/tmp/../Wallpaper Veil.app'),('helperSHA256','short')]:
            with self.subTest(key=key):
                bad=copy.deepcopy(r);bad[key]=value;record.write_text(json.dumps(bad));self.invoke('request',job,good=False)
        record.write_text(json.dumps(r));record.chmod(0o644);self.invoke('request',job,good=False)


if __name__=='__main__': unittest.main()
