"""Release contract checks; actionlint validates YAML/expressions separately."""
from pathlib import Path
import unittest


class AndroidReleaseWorkflowTests(unittest.TestCase):
    def test_lipo_input_precedes_variadic_architecture_arguments(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/release-desktop.yml').read_text()
        for binary in ('Contents/MacOS/Saathi', 'Contents/Frameworks/App.framework/App', 'Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS'):
            expected = f'lipo "$APP/{binary}" -verify_arch x86_64 arm64'
            self.assertTrue(expected in workflow, f'Invalid lipo argument order for {binary}')

    def test_unpublished_draft_is_read_by_id_not_a_nonexistent_git_tag(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/release-desktop.yml').read_text()
        self.assertTrue('--json databaseId --jq' in workflow, 'Resolve the draft release database ID')
        self.assertTrue('gh api "repos/$REPOSITORY/releases/$RELEASE_ID"' in workflow, 'Read draft by ID before publishing')
        self.assertFalse('gh api "repos/$REPOSITORY/releases/tags/$RELEASE_TAG"' in workflow, 'Draft tag may not exist until publication')

    def test_android_is_signed_configured_verified_and_published(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/release-desktop.yml').read_text()
        for required in (
            'android_build: ${{ steps.calver.outputs.android_build }}',
            'platform: android',
            'ANDROID_KEYSTORE_BASE64', 'ANDROID_KEYSTORE_PASSWORD',
            'ANDROID_KEY_ALIAS', 'ANDROID_KEY_PASSWORD', 'ANDROID_SIGNING_CERT_SHA256',
            'flutter build apk --release',
            '--build-number "$ANDROID_BUILD"',
            '--dart-define=SAATHI_UPDATE_CHANNEL=beta',
            '--dart-define=SAATHI_UPDATE_OWNER="$UPDATE_OWNER"',
            '--dart-define=SAATHI_UPDATE_REPO="$UPDATE_REPO"',
            'tool/verify_android_apk.py',
            'saathi-update-beta.json',
            'rm -f android/key.properties "$RUNNER_TEMP/saathi-release.p12"',
            'dist/*.apk dist/saathi-update-beta.json',
        ):
            with self.subTest(required=required):
                self.assertTrue(required in workflow, f'Missing release contract: {required}')


if __name__ == '__main__':
    unittest.main()
