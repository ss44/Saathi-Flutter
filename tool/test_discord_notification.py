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
from typing import Any

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
            'GITHUB_EVENT_NAME': 'push',
            'GITHUB_REPOSITORY': 'example/repository',
            'GH_TOKEN': 'test-github-credential',
            'DISCORD_WEBHOOK_URL': 'https://discord.com/api/webhooks/123/test-webhook-credential',
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.calls = []
        self.saved: Any = None
        self.pr = {'number': 17, 'state': 'closed', 'merged_at': '2026-11-16T00:00:00Z',
                   'merge_commit_sha': 'a' * 40,
                   'base': {'ref': 'main', 'repo': {'full_name': 'example/repository'}},
                   'title': 'CI: Full title 🐍', 'body': 'Complete description\nsecond line'}

    def fake_json(self, opener, url, payload=None, headers=None, attachment=None) -> Any:
        self.calls.append((url, payload, headers))
        if url.startswith('https://api.github.com/'):
            return self.pr if '/pulls/17' in url else [dict(self.pr, title='abbreviated', body='abbreviated')]
        if payload is not None:
            self.saved = dict(payload, id='123456789')
            if attachment:
                self.blob = attachment[1]
                self.saved['attachments'] = [{'filename': attachment[0], 'size': len(self.blob),
                    'url': 'https://cdn.discordapp.com/attachments/1/2/report.md'}]
            return self.saved
        return self.saved

    def run_main(self):
        with patch.dict(self.scope['main'].__globals__, {
                'read_json': self.fake_json, 'read_bytes': lambda *a: self.blob}):
            self.scope['main']()

    def test_merge_posts_random_gif_pr_link_and_verifies(self):
        self.run_main()
        self.assertEqual(len(self.calls), 4)
        self.assertIn('/pulls/17', self.calls[1][0])
        self.assertIn(self.pr['title'], self.saved['content'])
        self.assertNotIn(self.pr['body'], self.saved['content'])
        self.assertIn('/commits/' + 'a' * 40 + '/pulls', self.calls[0][0])
        self.assertIn('https://github.com/example/repository/pull/17', self.saved['content'])
        self.assertEqual(self.saved['allowed_mentions'], {'parse': []})
        self.assertIn(self.saved['embeds'][0]['image']['url'], self.scope['GIFS'])
        self.assertTrue(self.calls[2][0].endswith('?wait=true'))
        self.assertTrue(self.calls[3][0].endswith('/messages/123456789'))
        self.assertIsNone(self.calls[2][2])

    def test_discord_trims_outer_whitespace_without_changing_text(self):
        self.pr['title'] = 'CI: Full title 🐍\n\n'
        original = self.fake_json

        def normalized(opener, url, payload=None, headers=None, attachment=None):
            result = original(opener, url, payload, headers, attachment)
            if '/messages/' in url:
                return dict(result, content=result['content'].strip())
            return result

        with patch.dict(self.scope['main'].__globals__, {'read_json': normalized}):
            self.scope['main']()
        self.assertNotIn(self.pr['body'], self.saved['content'])
        self.assertEqual(sum(payload is not None for _, payload, _ in self.calls), 1)

    def test_unused_description_is_neither_read_nor_validated(self):
        for body in (None, '', {'invalid': 'unused'}, 42):
            with self.subTest(body=body):
                self.pr['body'] = body
                self.run_main()
                self.assertEqual(self.saved['content'],
                    'Job done! 🎉 PR #17 merged.\nhttps://github.com/example/repository/pull/17\n\n' + self.pr['title'])
                self.assertNotIn('attachments', self.saved)
        del self.pr['body']
        self.run_main()

    def test_long_hostile_unicode_description_is_omitted_without_attachment(self):
        self.pr['body'] = '🦊' * 1200 + '\n$(touch /not-executed) @everyone <@123> 漢字'
        self.run_main()
        self.assertIn(self.pr['title'], self.saved['content'])
        self.assertNotIn(self.pr['body'], self.saved['content'])
        self.assertNotIn('attachments', self.saved)
        self.assertEqual(self.saved['allowed_mentions'], {'parse': []})

    def test_shared_sender_long_build_failure_is_complete_attachment(self):
        report = 'Native build cycle: failure\nhttps://github.com/ss44/Saathi-Flutter/actions/runs/321\n\n' + (
            'Failed job 🦊 漢字 @everyone $(exit 1)\nCompile: failure\n'
            'https://github.com/ss44/Saathi-Flutter/actions/runs/321/job/1\n' * 40)
        send = self.scope['send_notification']
        with patch.dict(send.__globals__, {'read_json': self.fake_json,
                'read_bytes': lambda *a: self.blob}):
            send(None, os.environ['DISCORD_WEBHOOK_URL'], report,
                 self.scope['FAILURE_GIFS'], 'native-run-321.md')
        self.assertEqual(self.blob, report.encode('utf-8'))
        self.assertEqual(self.saved['attachments'][0]['filename'], 'native-run-321.md')
        self.assertIn('attached', self.saved['content'])
        self.assertEqual(self.saved['allowed_mentions'], {'parse': []})
        self.assertIn(self.saved['embeds'][0]['image']['url'], self.scope['FAILURE_GIFS'])
        self.assertLessEqual(len(self.saved['content'].encode('utf-16-le')) // 2, 2000)

    def build_fixture(self, conclusion='success', jobs=None):
        os.environ['GITHUB_EVENT_NAME'] = 'workflow_run'
        os.environ['GITHUB_REPOSITORY'] = 'ss44/Saathi-Flutter'
        self.build_run = {'id': 321, 'workflow_id': 99, 'name': 'Desktop and Android binary releases',
            'path': '.github/workflows/release-desktop.yml', 'status': 'completed',
            'conclusion': conclusion, 'run_attempt': 1, 'head_sha': 'a' * 40,
            'repository': {'full_name': 'ss44/Saathi-Flutter'},
            'head_repository': {'full_name': 'ss44/Saathi-Flutter'}}
        self.event_file.write_text(json.dumps({'action': 'completed', 'workflow_run': self.build_run}))
        self.build_jobs = jobs if jobs is not None else [
            {'id': 1, 'run_id': 321, 'name': 'Build android', 'conclusion': 'success', 'steps': []},
            {'id': 2, 'run_id': 321, 'name': 'publish', 'conclusion': 'success', 'steps': []}]
        original = self.fake_json
        def transport(opener, url, payload=None, headers=None, attachment=None):
            if 'api.github.com' not in url:
                return original(opener, url, payload, headers, attachment=attachment)
            self.calls.append((url, payload, headers))
            if '/workflows/' in url:
                return {'id': 99, 'name': self.build_run['name'], 'path': self.build_run['path']}
            if '/jobs?' in url:
                page = int(url.rsplit('page=', 1)[1])
                return {'total_count': len(self.build_jobs), 'jobs': self.build_jobs[(page-1)*100:page*100]}
            return self.build_run
        return transport

    def test_native_success(self):
        transport = self.build_fixture()
        with patch.dict(self.scope['main'].__globals__, {'read_json': transport}):
            self.scope['main']()
        self.assertIn('Native build cycle succeeded', self.saved['content'])
        self.assertIn('/actions/runs/321', self.saved['content'])
        self.assertNotIn('pull/', self.saved['content'])

    def test_native_skipped_is_not_new_release(self):
        transport = self.build_fixture(jobs=[{'id': 1, 'run_id': 321,
            'name': 'Build android', 'conclusion': 'skipped', 'steps': []}])
        with patch.dict(self.scope['main'].__globals__, {'read_json': transport}):
            self.scope['main']()
        self.assertIn('skipped', self.saved['content'])
        self.assertIn('not evidence of a new release', self.saved['content'])

    def test_native_failures_statuses_and_pagination(self):
        for status in ('failure', 'timed_out', 'cancelled'):
            with self.subTest(status=status):
                transport = self.build_fixture(status, jobs=[
                    {'id': i + 1, 'run_id': 321, 'name': 'prepare', 'conclusion': 'success', 'steps': []}
                    for i in range(100)] + [{'id': 101, 'run_id': 321, 'name': 'Build android',
                    'conclusion': status, 'steps': [{'name': 'Compile', 'conclusion': status}]}])
                with patch.dict(self.scope['main'].__globals__, {'read_json': transport}):
                    self.scope['main']()
                self.assertIn(status, self.saved['content'])
                self.assertIn('Compile', self.saved['content'])
                self.assertIn('/job/101', self.saved['content'])
                self.assertIn(self.saved['embeds'][0]['image']['url'], self.scope['FAILURE_GIFS'])
                self.assertTrue(any('page=2' in c[0] for c in self.calls))

    def test_native_no_details_is_honest(self):
        transport = self.build_fixture('failure', jobs=[])
        with patch.dict(self.scope['main'].__globals__, {'read_json': transport}):
            self.scope['main']()
        self.assertIn('No failed job/step details', self.saved['content'])

    def test_other_workflow_never_notifies(self):
        transport = self.build_fixture()
        self.build_run['name'] = 'Verify Saathi'
        self.event_file.write_text(json.dumps({'action': 'completed', 'workflow_run': self.build_run}))
        with patch.dict(self.scope['main'].__globals__, {'read_json': transport}):
            self.scope['main']()
        self.assertIsNone(self.saved)

    def test_full_metadata_identity_rechecked(self):
        original = self.fake_json
        def transport(opener, url, payload=None, headers=None):
            result = original(opener, url, payload, headers)
            return dict(result, merge_commit_sha='b' * 40) if '/pulls/17' in url else result
        with patch.dict(self.scope['main'].__globals__, {'read_json': transport}):
            with self.assertRaisesRegex(RuntimeError, 'identity'):
                self.scope['main']()
        self.assertIsNone(self.saved)

    def test_hostile_inline_metadata_is_only_data(self):
        self.pr['title'] = '${{ secrets.NOT_A_SECRET }}; $(exit 1) @everyone'
        self.pr['body'] = '<@123> `shell` 🐍 漢字'
        self.run_main()
        self.assertIn(self.pr['title'], self.saved['content'])
        self.assertNotIn(self.pr['body'], self.saved['content'])
        self.assertEqual(self.saved['allowed_mentions'], {'parse': []})

    def test_original_branch_guard(self):
        self.pr['base']['ref'] = 'other'
        self.run_main()
        self.assertEqual(len(self.calls), 1)

    def test_build_identity_rejected(self):
        for field, value in [('workflow_id', 100), ('path', 'other.yml'),
                             ('repository', {'full_name': 'other/repo'}),
                             ('run_attempt', 2)]:
            with self.subTest(field=field):
                self.saved = None
                transport = self.build_fixture()
                def altered(opener, url, payload=None, headers=None):
                    result = transport(opener, url, payload, headers)
                    if url.endswith('/runs/321'):
                        return dict(result, **{field: value})
                    return result
                with patch.dict(self.scope['main'].__globals__, {'read_json': altered}):
                    with self.assertRaisesRegex(RuntimeError, 'identity'):
                        self.scope['main']()
                self.assertIsNone(self.saved)

    def test_missing_job_pages_fail_closed(self):
        transport = self.build_fixture()
        def altered(opener, url, payload=None, headers=None):
            result = transport(opener, url, payload, headers)
            return dict(result, total_count=100) if '/jobs?' in url else result
        with patch.dict(self.scope['main'].__globals__, {'read_json': altered}):
            with self.assertRaisesRegex(RuntimeError, 'Incomplete'):
                self.scope['main']()
        self.assertIsNone(self.saved)

    def test_credentials_only_to_github_not_discord(self):
        self.run_main()
        for url, payload, headers in self.calls:
            if url.startswith('https://api.github.com/'):
                self.assertEqual(headers['Authorization'], 'Bearer test-github-credential')
            else:
                self.assertIsNone(headers)
        self.assertEqual(sum(payload is not None for _, payload, _ in self.calls), 1)

    def test_unicode_boundary_and_attachment_bound(self):
        send = self.scope['send_notification']
        with patch.dict(send.__globals__, {'read_json': self.fake_json}):
            send(None, os.environ['DISCORD_WEBHOOK_URL'], '🦊' * 1000, self.scope['GIFS'], 'test.md')
        self.assertEqual(self.saved['content'], '🦊' * 1000)
        self.calls.clear()
        with patch.dict(send.__globals__, {'MAX_ATTACHMENT': 2000, 'read_json': self.fake_json}):
            with self.assertRaisesRegex(RuntimeError, 'attachment limit'):
                send(None, os.environ['DISCORD_WEBHOOK_URL'], 'header\n\n' + '🦊' * 1001, self.scope['GIFS'], 'test.md')
        self.assertEqual(self.calls, [])

    def test_attachment_readback_rejects_corruption_and_untrusted_url(self):
        send = self.scope['send_notification']
        for corruption in ('filename', 'size', 'url', 'bytes'):
            with self.subTest(corruption=corruption):
                def transport(opener, url, payload=None, headers=None, attachment=None):
                    result = self.fake_json(opener, url, payload, headers)
                    if attachment:
                        item = {'filename': attachment[0], 'size': len(attachment[1]),
                                'url': 'https://cdn.discordapp.com/attachments/1/2/test.md'}
                        if corruption != 'bytes':
                            item[corruption] = {'filename': 'wrong.md', 'size': 1,
                                                'url': 'https://evil.example/file'}[corruption]
                        self.saved['attachments'] = [item]
                    return result
                with patch.dict(send.__globals__, {'read_json': transport,
                                                     'read_bytes': lambda *a: b'wrong'}):
                    with self.assertRaisesRegex(RuntimeError, 'attachment'):
                        send(None, os.environ['DISCORD_WEBHOOK_URL'], 'Header\n\n' + 'long' * 1000,
                             self.scope['GIFS'], 'test.md')

    def test_multipart_wire_format_and_public_get_no_auth(self):
        requests = []
        class Opener:
            def open(self, request, timeout):
                requests.append(request)
                return io.BytesIO(b'{}')
        self.scope['read_json'](Opener(), 'https://discord.com/api/webhooks/123/synthetic',
                                {'content': 'data', 'allowed_mentions': {'parse': []}},
                                attachment=('test.md', 'Complete 🐍'.encode()))
        request = requests[0]
        self.assertIn('multipart/form-data; boundary=', request.get_header('Content-type'))
        self.assertIn(b'name="payload_json"', request.data)
        self.assertIn(b'name="files[0]"; filename="test.md"', request.data)
        self.assertIn('Complete 🐍'.encode(), request.data)
        self.assertIsNone(request.get_header('Authorization'))
        self.scope['read_bytes'](Opener(), 'https://cdn.discordapp.com/attachments/1/2/test.md')
        self.assertIsNone(requests[1].get_header('Authorization'))

    def test_no_redirect_handler_and_no_uncertain_post_retry(self):
        self.assertIsNone(self.scope['NoRedirect']().redirect_request(None, None, 302, '', {}, 'https://evil.example'))
        calls = []
        class Broken:
            def open(self, *a, **kw):
                calls.append(1)
                raise OSError('private network detail')
        with self.assertRaisesRegex(RuntimeError, 'suppressed'):
            self.scope['read_json'](Broken(), 'https://discord.com/api/webhooks/123/synthetic', {'content': 'data'})
        self.assertEqual(calls, [1])

    def test_long_native_failure_complete_report_without_raw_logs(self):
        name = 'Failed 🐍 event ' * 250
        transport = self.build_fixture('failure', jobs=[{'id': 1, 'run_id': 321,
            'name': name, 'conclusion': 'failure', 'logs': 'DO-NOT-POST-RAW-LOGS',
            'steps': [{'name': 'Compile', 'conclusion': 'failure'}]}])
        with patch.dict(self.scope['main'].__globals__, {'read_json': transport,
                'read_bytes': lambda *a: self.blob}):
            self.scope['main']()
        report = self.blob.decode('utf-8')
        self.assertIn(name, report)
        self.assertIn('Compile', report)
        self.assertNotIn('DO-NOT-POST-RAW-LOGS', report)
        self.assertIn('attached', self.saved['content'])
        self.assertFalse(any('/logs' in call[0] for call in self.calls))

    def test_skipped_cycle_distinct_and_noncanonical_scope_ignored(self):
        transport = self.build_fixture('skipped', jobs=[])
        with patch.dict(self.scope['main'].__globals__, {'read_json': transport}):
            self.scope['main']()
        self.assertIn('cycle: skipped', self.saved['content'])
        self.saved = None
        transport = self.build_fixture()
        os.environ['GITHUB_REPOSITORY'] = 'other/repository'
        with patch.dict(self.scope['main'].__globals__, {'read_json': transport}):
            self.scope['main']()
        self.assertIsNone(self.saved)

    def test_workflow_run_trigger_has_one_native_source(self):
        text = WORKFLOW.read_text()
        self.assertIn("  workflow_run:\n    workflows: ['Desktop and Android binary releases']\n    types: [completed]", text)
        self.assertIn('  actions: read', text)
        self.assertNotIn('write', text)
        self.assertNotIn('workflow_dispatch:', text)

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
