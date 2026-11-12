"""Synthetic fixtures test release tooling, not native desktop compilation."""
import datetime as dt
import hashlib
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

import desktop_release as release


class DesktopReleaseTests(unittest.TestCase):
    def test_manual_calver_is_semver_compatible(self):
        result = release.version_info(None, 42, dt.date(2026, 1, 2))
        self.assertEqual(result, {'version': '2026.1.2', 'build': 42, 'tag': 'v2026.1.2+42'})

    def test_tag_values_are_preserved_not_silently_normalized(self):
        result = release.version_info('v2026.11.12+7', 99, dt.date(2026, 11, 12))
        self.assertEqual(result['tag'], 'v2026.11.12+7')
        self.assertEqual(result['build'], 7)
        for tag in ['v2026.01.02+7', 'v2026.2.30+7', 'v2026.1.2+0', 'v2026.1.2+65536', 'v2026.1.2+01', 'v2026.1.2+7;echo bad']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.version_info(tag, 1, dt.date(2026, 1, 2))

    def test_manual_build_number_is_bounded_for_windows(self):
        for value in [0, -1, 65536]:
            with self.assertRaises(ValueError):
                release.version_info(None, value, dt.date(2026, 1, 2))

    def test_windows_package_contains_the_entire_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / 'bundle'
            (bundle / 'data').mkdir(parents=True)
            (bundle / 'saathi.exe').write_bytes(b'fixture executable')
            (bundle / 'flutter_windows.dll').write_bytes(b'fixture runtime')
            (bundle / 'data/icudtl.dat').write_bytes(b'fixture data')
            archive = release.package_bundle('windows-x64', bundle, root / 'out', 'v2026.1.2+1')
            with zipfile.ZipFile(archive) as packed:
                self.assertEqual(packed.testzip(), None)
                names = packed.namelist()
                self.assertIn('Saathi/saathi.exe', names)
                self.assertIn('Saathi/flutter_windows.dll', names)
                self.assertIn('Saathi/data/icudtl.dat', names)
                self.assertIn('Saathi/RUNNING.txt', names)

    def test_linux_package_preserves_executable_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / 'bundle'
            (bundle / 'lib').mkdir(parents=True)
            (bundle / 'data').mkdir()
            (bundle / 'lib/libflutter_linux_gtk.so').write_bytes(b'fixture engine')
            (bundle / 'data/icudtl.dat').write_bytes(b'fixture ICU')
            executable = bundle / 'saathi'
            executable.write_bytes(b'fixture executable')
            executable.chmod(0o755)
            (bundle / 'lib/libexample.so.1').write_bytes(b'fixture library')
            (bundle / 'lib/libexample.so').symlink_to('libexample.so.1')
            archive = release.package_bundle('linux-x64', bundle, root / 'out', 'v2026.1.2+1')
            with tarfile.open(archive) as packed:
                self.assertTrue(packed.getmember('Saathi/saathi').mode & 0o111)
                self.assertTrue(packed.getmember('Saathi/lib/libexample.so').issym())
                self.assertEqual(packed.getmember('Saathi/lib/libexample.so').linkname, 'libexample.so.1')

    def test_incomplete_or_duplicate_package_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle = root / 'bundle'
            bundle.mkdir()
            with self.assertRaises(ValueError):
                release.package_bundle('windows-x64', bundle, root / 'out', 'v2026.1.2+1')
            (bundle / 'saathi.exe').write_bytes(b'fixture')
            with self.assertRaises(ValueError):
                release.package_bundle('windows-x64', bundle, root / 'out', 'v2026.1.2+1')

    def test_checksums_cover_three_expected_artifacts_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tag = 'v2026.1.2+1'
            names = release.expected_assets(tag)
            for name in names:
                (root / name).write_bytes(name.encode())
            checksum = release.write_checksums(root, tag)
            lines = checksum.read_text().splitlines()
            self.assertEqual(len(lines), 3)
            for name in names:
                self.assertIn(f'{hashlib.sha256(name.encode()).hexdigest()}  {name}', lines)
            (root / names[0]).unlink()
            with self.assertRaises(ValueError):
                release.write_checksums(root, tag)


if __name__ == '__main__':
    unittest.main()
