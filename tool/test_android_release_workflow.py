"""Release contract checks; actionlint validates YAML/expressions separately."""
from pathlib import Path
import unittest


class AndroidReleaseWorkflowTests(unittest.TestCase):
    def test_lipo_input_precedes_variadic_architecture_arguments(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/release-desktop.yml').read_text()
        for binary in ('Contents/MacOS/Saathi', 'Contents/Frameworks/App.framework/App', 'Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS'):
            expected = f'lipo "$APP/{binary}" -verify_arch x86_64 arm64'
            self.assertTrue(expected in workflow, f'Invalid lipo argument order for {binary}')

    def test_unpublished_draft_is_read_by_numeric_rest_id(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/release-desktop.yml').read_text()
        self.assertIn('tool/release_pipeline.py publish', workflow)
        self.assertIn('--release-id "$RELEASE_ID"', workflow)
        self.assertNotIn('--json databaseId', workflow)

    def test_change_gate_and_exact_source_pin(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/release-desktop.yml').read_text()
        self.assertIn('tool/release_pipeline.py prepare', workflow)
        self.assertEqual(workflow.count("if: needs.version.outputs.release_required == 'true'"), 3)
        self.assertEqual(workflow.count('ref: ${{ needs.version.outputs.commit }}'), 3)
        self.assertIn('ref: ${{ github.sha }}', workflow)
        self.assertIn('needs: [version, verify, build]', workflow)
        self.assertEqual(workflow.count('contents: write'), 2)

    def test_android_is_signed_configured_verified_and_published(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/release-desktop.yml').read_text()
        for required in (
            'android_build: ${{ steps.calver.outputs.android_build }}',
            'platform: android',
            'ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD',
            'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD', 'ANDROID_SIGNING_CERT_SHA256',
            'flutter build apk --release',
            '--build-name "$APP_VERSION"', '--build-number "$ANDROID_BUILD"',
            '--dart-define=SAATHI_UPDATE_CHANNEL=beta',
            '--dart-define=SAATHI_UPDATE_OWNER="$UPDATE_OWNER"',
            '--dart-define=SAATHI_UPDATE_REPO="$UPDATE_REPO"',
            'tool/verify_android_apk.py', 'tool/generate_update_manifest.py',
            'saathi-update-beta.json',
            'rm -f android/key.properties "$RUNNER_TEMP/saathi-release.p12"',
            'tool/release_pipeline.py publish',
        ):
            with self.subTest(required=required):
                self.assertIn(required, workflow)


if __name__ == '__main__':
    unittest.main()
