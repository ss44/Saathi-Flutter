"""Exercises actual ephemeral OpenSSL signing material; never prints credentials."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
import zipfile

import generate_android_signing as signing


@unittest.skipUnless(shutil.which('openssl'), 'OpenSSL is required')
class AndroidSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.output = Path(cls.temporary.name) / 'private-signing'
        cls.bundle = signing.generate(cls.output)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_bundle_contains_recoverable_keystore_and_credentials(self):
        with zipfile.ZipFile(self.bundle) as bundle:
            self.assertIsNone(bundle.testzip())
            self.assertIn('saathi-release.p12', bundle.namelist())
            self.assertIn('signing-credentials.txt', bundle.namelist())
            self.assertIn('github-secrets.json', bundle.namelist())
        self.assertFalse((self.output / 'working-key.pem').exists())

    def test_real_pkcs12_password_and_certificate_fingerprint_verify(self):
        secret = json.loads((self.output / 'github-secrets.json').read_text())
        completed = subprocess.run(['openssl', 'pkcs12', '-in', str(self.output / 'saathi-release.p12'),
            '-passin', f'file:{self.output / "keystore-password.txt"}', '-info', '-noout'], capture_output=True)
        self.assertEqual(completed.returncode, 0, 'Generated PKCS12 must pass MAC/password verification')
        certificate = subprocess.run(['openssl', 'x509', '-in', str(self.output / 'certificate.pem'), '-outform', 'DER'], capture_output=True, check=True).stdout
        self.assertEqual(secret['ANDROID_SIGNING_CERT_SHA256'], hashlib.sha256(certificate).hexdigest())
        self.assertEqual(secret['ANDROID_KEY_ALIAS'], 'saathi-release')
        self.assertGreaterEqual(len(secret['ANDROID_KEYSTORE_PASSWORD']), 32)
        self.assertEqual(secret['ANDROID_KEYSTORE_PASSWORD'], secret['ANDROID_KEY_PASSWORD'])

    @unittest.skipIf(os.name == 'nt', 'POSIX mode assertion')
    def test_all_private_artifacts_are_owner_only(self):
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o700)
        for file in self.output.iterdir():
            self.assertEqual(stat.S_IMODE(file.stat().st_mode), 0o600)

    def test_existing_signing_identity_is_never_overwritten(self):
        original = hashlib.sha256((self.output / 'saathi-release.p12').read_bytes()).hexdigest()
        with self.assertRaises(FileExistsError):
            signing.generate(self.output)
        self.assertEqual(hashlib.sha256((self.output / 'saathi-release.p12').read_bytes()).hexdigest(), original)


if __name__ == '__main__':
    unittest.main()
