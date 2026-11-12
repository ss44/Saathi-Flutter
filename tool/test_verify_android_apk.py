"""Contract fixtures for Android SDK verification; not real APK signing tests."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr
from io import StringIO
from unittest.mock import patch

import verify_android_apk as verifier


class VerifyApkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.apk = self.root / 'fixture.apk'
        self.apk.write_bytes(b'explicit synthetic fixture; not an Android APK')
        tools = self.root / 'sdk/build-tools/35.0.0'
        tools.mkdir(parents=True)
        (tools / 'apksigner').touch()
        (tools / 'aapt2').touch()
        self.arguments = (self.apk, self.root / 'sdk', 'io.github.ss44.saathi', '2026.46.1', 2026460001, 'a' * 64)

    def outputs(self, digest='a' * 64, package='io.github.ss44.saathi', version='2026.46.1', build=2026460001):
        return [subprocess.CompletedProcess([], 0, stdout=f'Verifies\nSigner #1 certificate SHA-256 digest: {digest}\n'),
                subprocess.CompletedProcess([], 0, stdout=f"package: name='{package}' versionCode='{build}' versionName='{version}'\n")]

    def test_metadata_and_signature_fixture_requires_checked_native_commands(self):
        with patch.object(verifier.subprocess, 'run', side_effect=self.outputs()) as run:
            verifier.verify(*self.arguments)
        self.assertEqual(run.call_count, 2)
        for call in run.call_args_list:
            self.assertTrue(call.kwargs['check'])
        self.assertIn('verify', run.call_args_list[0].args[0])
        self.assertIn('badging', run.call_args_list[1].args[0])

    def test_accepts_sdk37_scheme_prefixed_certificate_labels(self):
        # SDK37 actual output is "V2 Signer: certificate SHA-256 digest: ...".
        for label in ('V1 Signer:', 'V2 Signer:', 'V3.0 Signer:', 'V3.1 Signer:', 'V3.2 Signer:', 'V4 Signer:'):
            outputs = self.outputs()
            outputs[0].stdout = (
                f"Verifies\n{label} certificate SHA-256 digest: {'a' * 64}\n"
                f"Source Stamp Signer: certificate SHA-256 digest: {'b' * 64}\n"
            )
            with self.subTest(label=label), patch.object(verifier.subprocess, 'run', side_effect=outputs):
                verifier.verify(*self.arguments)

    def test_does_not_ignore_mismatched_or_unknown_scheme_signers(self):
        for label in ('V2 Signer:', 'V3.0 Signer:', 'V9 Signer:'):
            outputs = self.outputs()
            outputs[0].stdout += f"{label} certificate SHA-256 digest: {'b' * 64}\n"
            with self.subTest(label=label), redirect_stderr(StringIO()), patch.object(verifier.subprocess, 'run', side_effect=outputs):
                with self.assertRaisesRegex(ValueError, 'certificate'):
                    verifier.verify(*self.arguments)

    def test_failed_identity_check_reports_actual_public_signer_output(self):
        report = StringIO()
        with redirect_stderr(report), patch.object(verifier.subprocess, 'run', side_effect=self.outputs(digest='b' * 64)):
            with self.assertRaisesRegex(ValueError, 'certificate'):
                verifier.verify(*self.arguments)
        self.assertIn('Parsed APK signer count: 1', report.getvalue())
        self.assertIn('Signer #1 certificate SHA-256 digest: ' + 'b' * 64, report.getvalue())

    def test_rejects_other_signing_key(self):
        with patch.object(verifier.subprocess, 'run', side_effect=self.outputs(digest='b' * 64)):
            with self.assertRaisesRegex(ValueError, 'certificate'):
                verifier.verify(*self.arguments)

    def test_accepts_v31_sdk_range_labels_without_confusing_source_stamp(self):
        # Labels come from AOSP ApkSignerTool's V3/V3.1 printCertificate paths.
        for dev_release in ('', ' (dev release=true)'):
            outputs = self.outputs()
            outputs[0].stdout = (
                f"Signer (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: {'a' * 64}\n"
                f"Signer (minSdkVersion=33{dev_release}, maxSdkVersion=2147483647) certificate SHA-256 digest: {'a' * 64}\n"
                f"Source Stamp Signer certificate SHA-256 digest: {'b' * 64}\n"
            )
            with self.subTest(dev_release=dev_release), patch.object(verifier.subprocess, 'run', side_effect=outputs):
                verifier.verify(*self.arguments)

    def test_rejects_unexpected_ranged_or_unrecognized_signer_even_with_expected_numbered_signer(self):
        for label in ('Signer (minSdkVersion=33, maxSdkVersion=2147483647)', 'Signer unknown-format'):
            outputs = self.outputs()
            outputs[0].stdout += f"{label} certificate SHA-256 digest: {'b' * 64}\n"
            with self.subTest(label=label), patch.object(verifier.subprocess, 'run', side_effect=outputs):
                with self.assertRaisesRegex(ValueError, 'certificate'):
                    verifier.verify(*self.arguments)

    def test_rejects_wrong_package_version_or_build(self):
        for index, outputs in enumerate((self.outputs(package='other.app'), self.outputs(version='2026.46.2'), self.outputs(build=1))):
            with self.subTest(mismatch=index), patch.object(verifier.subprocess, 'run', side_effect=outputs):
                with self.assertRaisesRegex(ValueError, 'metadata'):
                    verifier.verify(*self.arguments)

    def test_rejects_native_signature_failure(self):
        with patch.object(verifier.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, ['apksigner'])):
            with self.assertRaises(subprocess.CalledProcessError):
                verifier.verify(*self.arguments)

    def test_rejects_unconfigured_certificate_and_missing_sdk(self):
        for arguments in (self.arguments[:-1] + ('',), (self.apk, self.root / 'missing-sdk', *self.arguments[2:])):
            with self.subTest(arguments='missing required verification prerequisite'):
                with self.assertRaises(ValueError):
                    verifier.verify(*arguments)


if __name__ == '__main__':
    unittest.main()
