"""Portable, adversarial fixtures for the one-copy application contract."""
from __future__ import annotations

import copy
import importlib.util
import plistlib
from pathlib import Path
import stat
import tempfile
import unittest
import warnings
import zipfile

SPEC = importlib.util.spec_from_file_location(
    'standalone_contract', Path(__file__).resolve().parents[1] / 'standalone_contract.py')
contract = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(contract)


class BundleContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Wallpaper Veil.app'
        self.facts = {}
        self.main = self.bundle(self.app, 'Launcher')
        self.helper = self.app / 'Contents/Helpers/Runtime.app'
        self.runtime = self.bundle(self.helper, 'Runtime')

    def binary(self, path, dependencies=(), rpaths=(), architectures=('arm64', 'x86_64')):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(bytes.fromhex('cafebabe') + b'fixture')
        path.chmod(0o755)
        self.facts[path.resolve()] = {arch: {'dependencies': list(dependencies),
                                            'rpaths': list(rpaths)} for arch in architectures}
        return path

    def bundle(self, path, executable):
        (path / 'Contents').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': executable}))
        return self.binary(path / 'Contents/MacOS' / executable,
                           ['/System/Library/Frameworks/AppKit.framework/AppKit'],
                           ['@executable_path/../Frameworks'])

    def audit(self):
        return contract.audit_bundle(self.app, inspector=lambda p: copy.deepcopy(self.facts[p]))

    def test_nested_bundle_and_framework_relative_links_are_self_contained(self):
        library = self.helper / 'Contents/Frameworks/Example.framework/Versions/A/Example'
        self.binary(library, ['/usr/lib/libSystem.B.dylib'])
        (library.parent.parent / 'Current').symlink_to('A', target_is_directory=True)
        (library.parent.parent.parent / 'Example').symlink_to('Versions/Current/Example')
        for facts in self.facts[self.runtime.resolve()].values():
            facts['dependencies'].append('@rpath/Example.framework/Example')
        result = self.audit()
        self.assertEqual(result['native_binary_count'], 3)
        self.assertEqual(result['relative_symlinks_checked'], 2)
        self.assertFalse(result['application_launched'])
        self.assertFalse(result['relocated_launch_tested'])

    def test_library_runpath_can_be_loader_relative(self):
        a = self.helper / 'Contents/Frameworks/A.dylib'
        b = self.helper / 'Contents/Frameworks/private/B.dylib'
        self.binary(a, ['@rpath/B.dylib'], ['@loader_path/private'])
        self.binary(b)
        self.audit()

    def test_an_external_homebrew_dependency_is_rejected(self):
        for facts in self.facts[self.runtime.resolve()].values():
            facts['dependencies'] = ['/opt/homebrew/lib/libexample.dylib']
        with self.assertRaisesRegex(RuntimeError, 'outside macOS'):
            self.audit()

    def test_an_unused_developer_runpath_is_rejected(self):
        for facts in self.facts[self.runtime.resolve()].values():
            facts['rpaths'].append('/Users/developer/build/Frameworks')
        with self.assertRaisesRegex(RuntimeError, 'external or unsupported'):
            self.audit()

    def test_a_missing_bundled_dependency_is_rejected(self):
        for facts in self.facts[self.runtime.resolve()].values():
            facts['dependencies'] = ['@rpath/Missing.dylib']
        with self.assertRaisesRegex(RuntimeError, 'cannot resolve'):
            self.audit()

    def test_component_needs_matching_architecture_and_its_own_app_runpath(self):
        self.binary(self.app / 'Contents/Frameworks/OnlyOuter.dylib')
        for facts in self.facts[self.runtime.resolve()].values():
            facts['dependencies'] = ['@rpath/OnlyOuter.dylib']
        with self.assertRaisesRegex(RuntimeError, 'cannot resolve'):
            self.audit()
        lib = self.helper / 'Contents/Frameworks/OnlyOuter.dylib'
        self.binary(lib, architectures=('arm64',))
        with self.assertRaisesRegex(RuntimeError, 'cannot resolve'):
            self.audit()

    def test_loader_path_cannot_escape_the_application(self):
        for facts in self.facts[self.main.resolve()].values():
            facts['dependencies'] = ['@loader_path/../../../../outside.dylib']
        with self.assertRaisesRegex(RuntimeError, 'escapes'):
            self.audit()

    def test_a_relative_external_symlink_is_rejected(self):
        external = self.root / 'outside'; external.write_text('outside')
        (self.app / 'outside').symlink_to('../outside')
        with self.assertRaisesRegex(RuntimeError, 'escapes'):
            self.audit()

    def test_an_absolute_internal_symlink_is_not_relocatable(self):
        (self.app / 'absolute').symlink_to(self.main)
        with self.assertRaisesRegex(RuntimeError, 'absolute'):
            self.audit()

    def test_dangling_and_cyclic_links_are_rejected(self):
        link = self.app / 'link'; link.symlink_to('missing')
        with self.assertRaisesRegex(RuntimeError, 'dangling or cyclic'):
            self.audit()
        link.unlink(); link.symlink_to('link')
        with self.assertRaisesRegex(RuntimeError, 'dangling or cyclic'):
            self.audit()

    def test_app_main_must_be_executable(self):
        self.main.chmod(0o644)
        with self.assertRaisesRegex(RuntimeError, 'executable is missing'):
            self.audit()


class ArchiveContractTests(unittest.TestCase):
    ROOT = 'Wallpaper Veil.app'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'app.zip'

    def archive(self, entries=(), links=(), complete=True):
        with zipfile.ZipFile(self.path, 'w') as source:
            if complete:
                source.writestr(self.ROOT + '/Contents/Info.plist',
                                plistlib.dumps({'CFBundleExecutable': 'Launcher'}))
                source.writestr(self.ROOT + '/Contents/MacOS/Launcher', b'native fixture')
            for name, value in entries:
                source.writestr(name, value)
            for name, value in links:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                source.writestr(info, value)
        return self.path

    def test_archive_has_one_complete_app_root_and_internal_framework_link(self):
        self.archive([(self.ROOT + '/Contents/Frameworks/Foo/Versions/A/Foo', 'data')],
                     [(self.ROOT + '/Contents/Frameworks/Foo/Versions/Current', 'A'),
                      (self.ROOT + '/Contents/Frameworks/Foo/Foo', 'Versions/Current/Foo')])
        result = contract.validate_archive(self.path)
        self.assertTrue(result['single_app_root_verified'])
        self.assertEqual(result['internal_symlinks_checked'], 2)

    def test_extra_top_level_content_is_rejected(self):
        self.archive([('install.py', 'not needed')])
        with self.assertRaisesRegex(RuntimeError, 'only one top-level'):
            contract.validate_archive(self.path)

    def test_path_traversal_is_rejected(self):
        self.archive([(self.ROOT + '/../outside', 'bad')])
        with self.assertRaisesRegex(RuntimeError, 'Unsafe'):
            contract.validate_archive(self.path)

    def test_duplicate_entries_are_rejected(self):
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            self.archive([(self.ROOT + '/Contents/MacOS/Launcher', 'duplicate')])
        with self.assertRaisesRegex(RuntimeError, 'Duplicate'):
            contract.validate_archive(self.path)

    def test_case_aliases_are_rejected_before_extraction(self):
        # Default macOS volumes map these distinct ZIP names to the same file.
        # A second executable spelling must not replace the declared launcher.
        self.archive([(self.ROOT + '/Contents/MacOS/launcher', 'replacement')])
        with self.assertRaisesRegex(RuntimeError, 'ambiguous'):
            contract.validate_archive(self.path)

    def test_unicode_normalization_aliases_are_rejected_before_extraction(self):
        self.archive([(self.ROOT + '/Contents/Resources/caf\u00e9.png', 'composed'),
                      (self.ROOT + '/Contents/Resources/cafe\u0301.png', 'decomposed')])
        with self.assertRaisesRegex(RuntimeError, 'ambiguous'):
            contract.validate_archive(self.path)

    def test_relative_escape_via_symlink_chain_is_rejected(self):
        self.archive(links=[(self.ROOT + '/Contents/A', 'B/../../..'),
                            (self.ROOT + '/Contents/B', 'MacOS')])
        with self.assertRaisesRegex(RuntimeError, 'escapes'):
            contract.validate_archive(self.path)

    def test_absolute_dangling_and_cyclic_links_are_rejected(self):
        for target, message in [('/tmp/outside', 'absolute'), ('missing', 'Dangling'),
                                ('link', 'Cyclic')]:
            with self.subTest(target=target):
                self.archive(links=[(self.ROOT + '/link', target)])
                with self.assertRaisesRegex(RuntimeError, message):
                    contract.validate_archive(self.path)

    def test_metadata_and_declared_executable_are_required(self):
        self.archive(complete=False)
        with self.assertRaisesRegex(RuntimeError, 'metadata'):
            contract.validate_archive(self.path)
        self.archive([(self.ROOT + '/Contents/Info.plist',
                       plistlib.dumps({'CFBundleExecutable': 'Missing'}))], complete=False)
        with self.assertRaisesRegex(RuntimeError, 'declared executable'):
            contract.validate_archive(self.path)


if __name__ == '__main__':
    unittest.main()
