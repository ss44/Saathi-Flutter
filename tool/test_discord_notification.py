"""Exercise the exact inline notifier without network or production secrets."""
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import tempfile
import textwrap
import unittest
from unittest.mock import patch

WORKFLOW = Path(__file__).resolve().parents[1] / '.github/workflows/discord-pr-merged.yml'


class DiscordNotificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        workflow = WORKFLOW.read_text()
        script = textwrap.dedent(workflow.split("          python3 - <<'PY'\n", 1)[1]).rsplit('\nPY', 1)[0]
        script_file = root / 'notify.py'
        script_file.write_text(script)
        self.scope = runpy.run_path(str(script_file))
        self.event_file = root / 'event.json'
        self.event_file.write_text(json.dumps({'ref': 'refs/heads/main', 'after': 'a' * 40}))
        self.env = patch.dict(os.environ, {
            'GITHUB_EVENT_PATH': str(self.event_file),
            'GITHUB_REPOSITORY': 'example/repository',
            'GH_TOKEN': 'test-github-credential',
            'DISCORD_WEBHOOK_URL': 'https://discord.com/api/webhooks/123/test-webhook-credential',
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.calls = []
        self.saved = None
        self.pr = {'number': 17, 'state': 'closed', 'merged_at': '2026-11-16T00:00:00Z',
                   'merge_commit_sha': 'a' * 40,
                   'base': {'ref': 'main', 'repo': {'full_name': 'example/repository'}}}

    def fake_json(self, opener, url, payload=None, headers=None):
        self.calls.append((url, payload, headers))
        if url.startswith('https://api.github.com/'):
            return [self.pr]
        if payload is not None:
            self.saved = dict(payload, id='123456789')
            return self.saved
        return self.saved

    def run_main(self):
        with patch.dict(self.scope['main'].__globals__, {'read_json': self.fake_json}):
            self.scope['main']()

    def test_merge_posts_random_gif_pr_link_and_verifies(self):
        self.run_main()
        self.assertEqual(len(self.calls), 3)
        self.assertIn('/commits/' + 'a' * 40 + '/pulls', self.calls[0][0])
        self.assertIn('https://github.com/example/repository/pull/17', self.saved['content'])
        self.assertEqual(self.saved['allowed_mentions'], {'parse': []})
        self.assertIn(self.saved['embeds'][0]['image']['url'], self.scope['GIFS'])
        self.assertTrue(self.calls[1][0].endswith('?wait=true'))
        self.assertTrue(self.calls[2][0].endswith('/messages/123456789'))
        self.assertIsNone(self.calls[1][2])

    def test_closed_unmerged_pr_does_not_post(self):
        self.pr['merged_at'] = None
        self.run_main()
        self.assertEqual(len(self.calls), 1)

    def test_other_commit_does_not_post(self):
        self.pr['merge_commit_sha'] = 'b' * 40
        self.run_main()
        self.assertEqual(len(self.calls), 1)

    def test_other_base_repository_does_not_post(self):
        self.pr['base']['repo']['full_name'] = 'other/repository'
        self.run_main()
        self.assertEqual(len(self.calls), 1)

    def test_direct_push_does_not_post(self):
        with patch.dict(self.scope['main'].__globals__, {'read_json': lambda *a, **kw: []}):
            self.scope['main']()

    def test_wrong_branch_does_not_send_or_query(self):
        self.event_file.write_text(json.dumps({'ref': 'refs/heads/feature', 'after': 'a' * 40}))
        self.run_main()
        self.assertEqual(self.calls, [])

    def test_untrusted_webhook_rejected_without_network(self):
        os.environ['DISCORD_WEBHOOK_URL'] = 'https://evil.example/hook'
        with self.assertRaisesRegex(ValueError, 'webhook'):
            self.run_main()
        self.assertEqual(self.calls, [])

    def test_invalid_identity_fails_closed(self):
        os.environ['GITHUB_REPOSITORY'] = 'example/repository?injection=yes'
        with self.assertRaises(ValueError):
            self.run_main()
        self.assertEqual(self.calls, [])

    def test_network_exception_does_not_expose_credentials(self):
        class Broken:
            def open(self, *args, **kwargs):
                raise OSError(os.environ['DISCORD_WEBHOOK_URL'])
        with self.assertRaises(RuntimeError) as caught:
            self.scope['read_json'](Broken(), os.environ['DISCORD_WEBHOOK_URL'])
        self.assertNotIn('test-webhook-credential', str(caught.exception))
        self.assertIsNone(caught.exception.__cause__)

    def test_readback_mismatch_fails(self):
        original = self.fake_json
        def mismatch(opener, url, payload=None, headers=None):
            result = original(opener, url, payload, headers)
            if '/messages/' in url:
                return dict(result, content='different')
            return result
        with patch.dict(self.scope['main'].__globals__, {'read_json': mismatch}):
            with self.assertRaisesRegex(RuntimeError, 'readback'):
                self.scope['main']()

    def test_workflow_uses_trusted_main_without_checkout(self):
        text = WORKFLOW.read_text()
        self.assertIn('push:\n    branches: [main]', text)
        self.assertNotIn('pull_request_target:', text)
        self.assertNotIn('uses:', text)
        self.assertIn('contents: read', text)
        self.assertIn('pull-requests: read', text)
        self.assertIn('secrets.DISCORD_PR_WEBHOOK_URL', text)
        self.assertNotIn('github.event.pull_request.title', text)


if __name__ == '__main__':
    unittest.main()
