"""Synthetic fixtures test release tooling, not native desktop compilation."""
import datetime as dt
import hashlib
import os
import subprocess
import sys
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

import desktop_release as release


class DesktopReleaseTests(unittest.TestCase):
    def test_manual_calver_uses_iso_year_week_and_first_increment(self):
        result = release.version_info(None, 42, dt.date(2026, 11, 12))
        self.assertEqual(result, {'version': '2026.46.1', 'build': 42, 'tag': 'v2026.46.1'})

    def test_weekly_increment_follows_existing_tags_and_resets_next_week(self):
        tags = ['v2026.46.1', 'v2026.46.2', 'v2026.45.9', 'v2026.11.12+42', 'bad']
        self.assertEqual(release.version_info(None, 43, dt.date(2026, 11, 12), tags)['version'], '2026.46.3')
        self.assertEqual(release.version_info(None, 44, dt.date(2026, 11, 16), tags)['version'], '2026.47.1')

    def test_iso_week_year_handles_new_year_boundary(self):
        result = release.version_info(None, 45, dt.date(2027, 1, 1))
        self.assertEqual(result['version'], '2026.53.1')
        self.assertEqual(release.version_info(None, 46, dt.date(2027, 1, 4))['version'], '2027.1.1')

    def test_tag_values_are_preserved_not_silently_normalized(self):
        result = release.version_info('v2026.46.7', 99, dt.date(2026, 11, 12))
        self.assertEqual(result['tag'], 'v2026.46.7')
        self.assertEqual(result['version'], '2026.46.7')
        self.assertEqual(result['build'], 99)
        for tag in ['v2026.046.7', 'v2026.54.1', 'v2027.53.1', 'v2026.46.0', 'v2026.46.65536', 'v2026.46.01', 'v2026.46.1;echo bad', 'v2026.11.12+7']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.version_info(tag, 1, dt.date(2026, 11, 12))

    def test_weekly_increment_exhaustion_is_rejected(self):
        with self.assertRaises(ValueError):
            release.version_info(None, 50, dt.date(2026, 11, 12), ['v2026.46.65535'])

    def test_cli_consumes_tag_inventory_and_writes_github_outputs(self):
        year, week, _ = dt.datetime.now(dt.timezone.utc).date().isocalendar()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inventory, output = root / 'tags', root / 'outputs'
            inventory.write_text(f'v{year}.{week}.1\nv{year}.{week}.2\n', encoding='utf-8')
            command = [sys.executable, str(Path(release.__file__)), 'metadata', '--run-number', '20', '--tags-file', str(inventory)]
            result = subprocess.run(command, env={**os.environ, 'GITHUB_OUTPUT': str(output)}, capture_output=True, text=True, check=True)
            self.assertIn(f'version={year}.{week}.3\n', result.stdout)
            self.assertIn('build=20\n', result.stdout)
            self.assertEqual(output.read_text(), result.stdout)

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
            archive = release.package_bundle('windows-x64', bundle, root / 'out', 'v2026.1.1')
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
            archive = release.package_bundle('linux-x64', bundle, root / 'out', 'v2026.1.1')
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
                release.package_bundle('windows-x64', bundle, root / 'out', 'v2026.1.1')
            (bundle / 'saathi.exe').write_bytes(b'fixture')
            with self.assertRaises(ValueError):
                release.package_bundle('windows-x64', bundle, root / 'out', 'v2026.1.1')

    def test_checksums_cover_three_expected_artifacts_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tag = 'v2026.1.1'
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
