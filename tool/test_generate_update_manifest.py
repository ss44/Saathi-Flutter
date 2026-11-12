"""Executable tests for manifest generation; fixtures are not signed APKs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).with_name('generate_update_manifest.py')


class ManifestTests(unittest.TestCase):
    def run_tool(self, *extra):
        # Runtime TMPDIR is the project's scratch area, not /tmp.
        with tempfile.TemporaryDirectory(prefix='saathi-release-') as work:
            apk = Path(work) / 'Saathi-2026.46.1-android.apk'
            apk.write_bytes(b'manifest fixture only, not installable')
            output = Path(work) / 'saathi-update-stable.json'
            result = subprocess.run([sys.executable, str(TOOL), '--owner', 'example',
                '--repo', 'saathi', '--version', '2026.46.1', '--build', '2026460001',
                '--channel', 'stable', '--apk', str(apk), '--output', str(output),
                *extra], text=True, capture_output=True)
            return result, json.loads(output.read_text()) if output.exists() else None

    def test_generates_exact_manifest(self):
        result, manifest = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        assert manifest is not None
        self.assertEqual(manifest['schema'], 1)
        self.assertEqual(manifest['asset']['sha256'], hashlib.sha256(b'manifest fixture only, not installable').hexdigest())
        self.assertEqual(manifest['version'], '2026.46.1')
        self.assertEqual(manifest['build'], 2026460001)
        self.assertEqual(manifest['asset']['url'], 'https://github.com/example/saathi/releases/download/v2026.46.1/Saathi-2026.46.1-android.apk')
        self.assertIn('does not verify APK signing', result.stderr)

    def test_beta_manifest_accepts_final_weekly_version(self):
        result, manifest = self.run_tool('--channel', 'beta')
        self.assertEqual(result.returncode, 0, result.stderr)
        assert manifest is not None
        self.assertEqual(manifest['channel'], 'beta')
        self.assertEqual(manifest['asset']['url'], 'https://github.com/example/saathi/releases/download/v2026.46.1/Saathi-2026.46.1-android.apk')

    def test_rejects_invalid_repository(self):
        result, manifest = self.run_tool('--repo', '../evil')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(manifest)

    def test_rejects_prerelease_on_stable(self):
        result, manifest = self.run_tool('--version', '1.1.0-beta.1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(manifest)

    def test_rejects_invalid_build(self):
        result, manifest = self.run_tool('--build', '0')
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(manifest)


if __name__ == '__main__':
    unittest.main()
