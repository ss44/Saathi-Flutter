"""Offline change-aware orchestration contracts."""
import datetime as dt
import unittest
from unittest.mock import patch
from pathlib import Path
import tempfile
import hashlib
import release_pipeline as rp

SHA = 'a' * 40


class PlanningTests(unittest.TestCase):
    def plan(self, releases=(), tags=(), tree=lambda ref: ref):
        return rp.plan(list(releases), list(tags), SHA, 7, '123', tree,
                       dt.date(2026, 11, 12))

    def test_first_release(self):
        result = self.plan()
        self.assertEqual(result['tag'], 'v2026.46.1')
        self.assertEqual(result['commit'], SHA)
        self.assertEqual(result['release_required'], 'true')

    def release(self, **values):
        return dict(id=12, tag_name='v2026.45.3', draft=False,
                    published_at='2026-11-02T09:00:00Z',
                    target_commitish='main', body='') | values

    def test_unchanged_tree_includes_beta(self):
        release = self.release(prerelease=True)
        refs = []
        result = self.plan([release], tree=lambda ref: refs.append(ref) or 'same-tree')
        self.assertEqual(result['release_required'], 'false')
        self.assertEqual(refs, [SHA, 'refs/tags/v2026.45.3'])

    def test_changed_tree_new_week_draft_and_git_tags_reserve(self):
        draft = self.release(draft=True, tag_name='v2026.46.2')
        result = self.plan([self.release(), draft], ['v2026.46.4'])
        self.assertEqual(result['tag'], 'v2026.46.5')

    def test_own_rerun_reuses_draft(self):
        draft = self.release(draft=True, tag_name='v2026.45.3',
                             target_commitish=SHA, body=rp.marker('123'))
        self.assertEqual(self.plan([draft])['release_id'], 12)
        self.assertEqual(self.plan([draft])['tag'], 'v2026.45.3')
        draft['draft'] = False
        with self.assertRaisesRegex(ValueError, 'immutable'):
            self.plan([draft])

    def test_source_and_history_errors_fail_closed(self):
        with self.assertRaises(ValueError):
            rp.plan([], [], 'main', 7, '123', lambda ref: ref)
        def broken(ref):
            raise RuntimeError('missing tag history')
        with self.assertRaisesRegex(RuntimeError, 'history'):
            self.plan([self.release()], tree=broken)

    def test_paginated_inventory_and_api_failure(self):
        calls = []
        def api(endpoint):
            calls.append(endpoint)
            return [self.release()] * 100 if endpoint.endswith('&page=1') else []
        self.assertEqual(len(rp.inventory(api, 'owner/repo')), 100)
        self.assertEqual(len(calls), 2)
        with self.assertRaises(RuntimeError):
            rp.inventory(lambda endpoint: (_ for _ in ()).throw(RuntimeError('API failed')), 'o/r')

    def test_current_release_inventory_reserves_next_increment(self):
        current = self.release(tag_name='v2026.46.2', prerelease=True)
        self.assertEqual(self.plan([current])['tag'], 'v2026.46.3')
        self.assertEqual(self.plan([current], tree=lambda ref: 'identical')['release_required'], 'false')

    def test_owned_draft_wrong_source_rejected(self):
        draft = self.release(draft=True, body=rp.marker('123'), target_commitish='b' * 40)
        with self.assertRaisesRegex(ValueError, 'source mismatch'):
            self.plan([draft])

    def test_publish_refuses_published_release_before_upload(self):
        published = self.release(prerelease=True, assets=[], target_commitish=SHA,
                                 body=rp.marker('123'))
        with patch.object(rp, 'api', return_value=published), patch.object(rp, 'command') as upload:
            with self.assertRaisesRegex(ValueError, 'already published'):
                rp.publish('o/r', 12, published['tag_name'], SHA, '123', 'unused')
            upload.assert_not_called()

    def test_partial_assets_fail_closed_before_any_upload(self):
        with self.assertRaisesRegex(ValueError, 'fresh workflow run'):
            rp.require_empty_assets({'assets': [{'name': 'partial.apk'}]})

    def test_draft_created_with_exact_source_and_read_back(self):
        events = []
        draft = self.release(id=15, draft=True, prerelease=True, assets=[],
                             tag_name='v2026.46.1', target_commitish=SHA,
                             body=rp.marker('123'))
        def api(endpoint, method='GET', payload=None):
            events.append((endpoint, method, payload))
            if '?' in endpoint:
                return []
            if method == 'POST':
                self.assertTrue(payload['draft'])
                self.assertTrue(payload['prerelease'])
                self.assertEqual(payload['target_commitish'], SHA)
            return draft.copy()
        with patch.object(rp, 'api', api), patch.object(rp, 'command', return_value=''):
            # version_info owns the clock; pin it through the imported function.
            original = rp.version_info
            with patch.object(rp, 'version_info', side_effect=lambda tag, run, **kw: original(tag, run, today=dt.date(2026, 11, 12), existing_tags=kw.get('existing_tags', []))):
                result = rp.prepare('o/r', SHA, 7, '123')
        self.assertEqual(result['release_id'], 15)
        self.assertEqual([e[1] for e in events], ['GET', 'POST', 'GET'])

    def test_publish_exact_six_digests_before_promotion_and_readback(self):
        self.exercise_publication()

    def test_bad_uploaded_digest_never_publishes(self):
        self.exercise_publication(bad_digest=True)

    def exercise_publication(self, bad_digest=False):
        tag = 'v2026.46.1'
        events = []
        assets = []
        draft = self.release(draft=True, prerelease=True, assets=assets,
                             tag_name=tag, target_commitish=SHA, body=rp.marker('123'))
        def api(endpoint, method='GET', payload=None):
            events.append(method)
            self.assertEqual(endpoint, 'repos/o/r/releases/12')
            if method == 'PATCH':
                self.assertEqual(len(assets), 6)
                self.assertEqual(payload, {'draft': False})
                draft['draft'] = False
            return draft.copy()
        def upload(*args):
            events.append('UPLOAD')
            path = Path(args[-1])
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            assets.append(dict(name=path.name, size=path.stat().st_size,
                               digest='sha256:' + ('bad' if bad_digest else digest)))
            return '{}'
        with tempfile.TemporaryDirectory() as temporary:
            for name in rp.expected_assets(tag) + ['SHA256SUMS']:
                (Path(temporary) / name).write_bytes(b'synthetic fixture')
            with patch.object(rp, 'api', api), patch.object(rp, 'command', upload):
                if bad_digest:
                    with self.assertRaisesRegex(ValueError, 'digest'):
                        rp.publish('o/r', 12, tag, SHA, '123', temporary)
                    self.assertNotIn('PATCH', events)
                else:
                    rp.publish('o/r', 12, tag, SHA, '123', temporary)
                    self.assertEqual(events, ['GET'] + ['UPLOAD'] * 6 + ['GET', 'PATCH', 'GET'])


if __name__ == '__main__':
    unittest.main()
