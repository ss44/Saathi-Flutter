"""Offline change-aware orchestration contracts."""
import datetime as dt
import json
import unittest
from unittest.mock import patch
from pathlib import Path
import tempfile
import hashlib
import os
import subprocess
import release_pipeline as rp

SHA = 'a' * 40


class TagProvenanceTests(unittest.TestCase):
    tag = 'v2026.47.1'

    def ref(self, sha=SHA, kind='commit'):
        return {'ref': 'refs/tags/' + self.tag,
                'object': {'type': kind, 'sha': sha}}

    def test_lightweight_and_nested_annotated_tags(self):
        for replies in ([[self.ref()]],
                        [[self.ref('b' * 40, 'tag')],
                         {'object': {'type': 'tag', 'sha': 'c' * 40}},
                         {'object': {'type': 'commit', 'sha': SHA}}]):
            with self.subTest(replies=replies), patch.object(rp, 'api', side_effect=replies) as api:
                rp.require_source_tag('o/r', self.tag, SHA)
                self.assertEqual(api.call_args_list[0].args,
                                 ('repos/o/r/git/matching-refs/tags/' + self.tag,))
                self.assertTrue(all(call.args[1:] == () for call in api.call_args_list))
                if api.call_count > 1:
                    self.assertEqual(api.call_args_list[1].args,
                                     ('repos/o/r/git/tags/' + 'b' * 40,))

    def test_missing_tag_created_once_then_read_back(self):
        with patch.object(rp, 'api', side_effect=[[], self.ref(), [self.ref()]]) as api:
            rp.require_source_tag('o/r', self.tag, SHA, create=True)
        self.assertEqual(api.call_args_list[1].args,
                         ('repos/o/r/git/refs', 'POST',
                          {'ref': 'refs/tags/' + self.tag, 'sha': SHA}))
        self.assertEqual(api.call_count, 3)

    def test_missing_tag_without_creation_and_ambiguous_inventory_fail(self):
        for rows in ([], [self.ref(), self.ref()], {}, [dict(self.ref(), object={})]):
            with self.subTest(rows=rows), patch.object(rp, 'api', return_value=rows) as api:
                with self.assertRaises(ValueError):
                    rp.require_source_tag('o/r', self.tag, SHA)
                self.assertEqual(api.call_count, 1)

    def test_prefix_match_is_not_the_exact_tag(self):
        row = self.ref()
        row['ref'] += '0'
        with patch.object(rp, 'api', return_value=[row]):
            with self.assertRaises(ValueError):
                rp.require_source_tag('o/r', self.tag, SHA)

    def test_wrong_commit_wrong_type_and_annotation_cycle_fail_closed(self):
        for replies in ([[self.ref('b' * 40)]], [[self.ref(SHA, 'tree')]],
                        [[self.ref('b' * 40, 'tag')],
                         {'object': {'type': 'tag', 'sha': 'b' * 40}}]):
            with self.subTest(replies=replies), patch.object(rp, 'api', side_effect=replies):
                with self.assertRaises(ValueError):
                    rp.require_source_tag('o/r', self.tag, SHA)

    def test_lookup_creation_failure_and_changed_creation_readback_propagate(self):
        for replies in ([RuntimeError('lookup failed')],
                        [[], RuntimeError('concurrent tag creation')],
                        [[], self.ref(), [self.ref('b' * 40)]]):
            with self.subTest(replies=replies), patch.object(rp, 'api', side_effect=replies):
                with self.assertRaises((RuntimeError, ValueError)):
                    rp.require_source_tag('o/r', self.tag, SHA, create=True)

    def test_malformed_annotations_and_excessive_depth_fail_closed(self):
        for value in (None, [], {}, {'object': {'type': 'commit', 'sha': '../bad'}}):
            with self.subTest(value=value), patch.object(rp, 'api', side_effect=[
                    [self.ref('b' * 40, 'tag')], value]):
                with self.assertRaises(ValueError):
                    rp.require_source_tag('o/r', self.tag, SHA)
        replies = [[self.ref('b' * 40, 'tag')]] + [
            {'object': {'type': 'tag', 'sha': f'{number:040x}'}}
            for number in range(16)]
        with patch.object(rp, 'api', side_effect=replies) as api:
            with self.assertRaisesRegex(ValueError, 'depth'):
                rp.require_source_tag('o/r', self.tag, SHA)
            self.assertEqual(api.call_count, 17)


class PlanningTests(unittest.TestCase):
    def plan(self, releases=(), tags=(), tree=lambda ref: ref):
        return rp.plan(list(releases), list(tags), SHA, 7, '123', tree,
                       dt.date(2026, 11, 12))

    def test_human_notes_body_preserves_owner_and_boilerplate(self):
        notes = json.loads(Path('assets/changelog.json').read_text())['unreleased']
        body = rp.release_body('123', notes)

        self.assertIn("## What's new", body)
        self.assertIn('<!-- saathi-changes:start -->', body)
        self.assertIn('<!-- saathi-changes:end -->', body)
        for note in notes:
            self.assertIn('- ' + note, body)
        self.assertIn(Path('docs/DESKTOP_RELEASE_NOTES.md').read_text(), body)
        self.assertIn(rp.marker('123'), body)

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
        with patch.object(rp, 'api', api), patch.object(rp, 'command', return_value=''), \
                patch.object(rp, 'select_release_notes', return_value=['Source-pinned note']) as selected:
            # version_info owns the clock; pin it through the imported function.
            original = rp.version_info
            with patch.object(rp, 'version_info', side_effect=lambda tag, run, **kw: original(tag, run, today=dt.date(2026, 11, 12), existing_tags=kw.get('existing_tags', []))):
                result = rp.prepare('o/r', SHA, 7, '123')
        selected.assert_called_once_with(SHA, [])
        self.assertIn('- Source-pinned note\n', events[1][2]['body'])
        self.assertEqual(result['release_id'], 15)
        self.assertEqual([e[1] for e in events], ['GET', 'POST', 'GET'])

    def test_publish_exact_six_digests_before_promotion_and_readback(self):
        self.exercise_publication()

    def test_bad_uploaded_digest_never_publishes(self):
        self.exercise_publication(bad_digest=True)

    def test_tag_mismatch_stops_upload_promotion_or_success_readback(self):
        for stage in (1, 2, 3):
            with self.subTest(stage=stage):
                self.exercise_publication(tag_failure=stage)

    def exercise_publication(self, bad_digest=False, tag_failure=None):
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
        def check_tag(*args, **kwargs):
            events.append('TAG')
            if events.count('TAG') == tag_failure:
                raise ValueError('Remote release tag does not match built source')
        with tempfile.TemporaryDirectory() as temporary:
            for name in rp.expected_assets(tag) + ['SHA256SUMS']:
                (Path(temporary) / name).write_bytes(b'synthetic fixture')
            with patch.object(rp, 'api', api), patch.object(rp, 'command', upload), \
                    patch.object(rp, 'require_source_tag', side_effect=check_tag) as source_tag:
                if tag_failure:
                    with self.assertRaisesRegex(ValueError, 'tag'):
                        rp.publish('o/r', 12, tag, SHA, '123', temporary)
                    if tag_failure == 1:
                        self.assertNotIn('UPLOAD', events)
                    if tag_failure < 3:
                        self.assertNotIn('PATCH', events)
                elif bad_digest:
                    with self.assertRaisesRegex(ValueError, 'digest'):
                        rp.publish('o/r', 12, tag, SHA, '123', temporary)
                    self.assertNotIn('PATCH', events)
                else:
                    rp.publish('o/r', 12, tag, SHA, '123', temporary)
                    self.assertEqual(events, ['GET', 'TAG'] + ['UPLOAD'] * 6 +
                                     ['GET', 'TAG', 'PATCH', 'GET', 'TAG'])
                    self.assertEqual(source_tag.call_count, 3)
                    self.assertEqual(source_tag.call_args_list[0].kwargs, {'create': True})


class CommitRangeNotesTests(unittest.TestCase):
    """Real Git seam: shipped commits change while curated notes stay stale."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        path = self.repo / 'assets/changelog.json'
        path.parent.mkdir()
        path.write_text(json.dumps({'schema': 1, 'unreleased': ['Stale note'],
                                    'releases': []}))
        command = rp.command
        redirect = patch.object(rp, 'command', side_effect=lambda *args: command(
            'git', '-C', str(self.repo), *args[1:]))
        redirect.start()
        self.addCleanup(redirect.stop)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args],
                                       text=True, stderr=subprocess.PIPE).strip()

    def commit(self, subject):
        path = self.repo / 'sequence'
        path.write_text(path.read_text() + 'x' if path.exists() else 'x')
        self.git('add', '.')
        self.git('commit', '-qm', subject)
        return self.git('rev-parse', 'HEAD')

    def release(self, increment, date):
        tag = f'v2026.47.{increment}'
        self.git('tag', '-a', tag, '-m', 'annotated fixture')
        return dict(tag_name=tag, draft=False, published_at=date,
                    target_commitish='wrong-branch', body='wrong notes')

    def test_filtered_range_is_empty_and_git_log_failure_never_falls_back(self):
        self.commit('Initial source')
        previous = self.release(1, '2026-11-19')
        source = self.commit('CI: Refresh automation (#2)')
        self.assertEqual(rp.select_release_notes(source, [previous]), [])
        command = rp.command

        def broken(*args):
            if 'log' in args:
                raise subprocess.CalledProcessError(128, args)
            return command(*args)

        with patch.object(rp, 'command', side_effect=broken):
            with self.assertRaises(subprocess.CalledProcessError):
                rp.select_release_notes(source, [previous])

    def test_subject_markers_fail_closed_and_conventional_breaking_scope_is_kept(self):
        self.commit('Initial source')
        previous = self.release(1, '2026-11-19')
        source = self.commit('fix(chat)!: Preserve input (#2)')
        self.assertEqual(rp.select_release_notes(source, [previous]), ['Preserve input'])
        source = self.commit('CHAT: <!-- saathi-changes:end --> (#3)')
        with self.assertRaises(ValueError):
            rp.select_release_notes(source, [previous])

    def test_consecutive_ranges_ignore_stale_rotated_and_cumulative_ledger(self):
        self.commit('Initial source')
        first = self.release(1, '2026-11-18')
        source = self.commit('CHAT: First shipped change (#2)')
        self.assertEqual(rp.select_release_notes(source, [first]), ['First shipped change'])
        second = self.release(2, '2026-11-19')
        path = self.repo / 'assets/changelog.json'
        for notes in (['Unshipped claim'], ['Stale note', 'Unshipped claim']):
            path.write_text(json.dumps({'schema': 1, 'unreleased': notes, 'releases': []}))
            source = self.commit('CI: Rotate stale curated notes')
        source = self.commit('CHAT: Next shipped change (#3)')
        releases = [second, first, dict(tag_name='v2026.47.99', draft=True),
                    dict(tag_name='legacy', draft=False)]
        self.assertEqual(rp.select_release_notes(source, releases), ['Next shipped change'])
        third = self.release(3, '2026-11-20')
        self.assertEqual(rp.select_release_notes(source, releases + [third]), [])
        # The same title on a distinct later commit is not suppressed across ranges.
        source = self.commit('CHAT: First shipped change (#4)')
        self.assertEqual(rp.select_release_notes(source, releases + [third]),
                         ['First shipped change'])

    def test_merge_wrapper_does_not_repeat_branch_subjects(self):
        base = self.commit('Initial source')
        previous = self.release(1, '2026-11-19')
        branch = self.git('symbolic-ref', '--short', 'HEAD')
        self.git('checkout', '-qb', 'feature')
        self.commit('CHAT: Preserve drafts (#20)')
        self.git('checkout', branch)
        self.git('merge', '--no-ff', '-qm', 'Merge feature branch', 'feature')
        source = self.git('rev-parse', 'HEAD')
        self.assertNotEqual(base, source)
        self.assertEqual(rp.select_release_notes(source, [previous]), ['Preserve drafts'])

    def test_republished_older_source_cannot_replay_already_shipped_commits(self):
        original = self.commit('Initial source')
        first = self.release(1, '2026-11-18')
        self.commit('CHAT: Already shipped (#20)')
        second = self.release(2, '2026-11-19')
        source = self.commit('CHAT: Next change (#21)')
        self.git('tag', '-a', 'v2026.47.3', original, '-m', 'Older snapshot')
        rollback = dict(first, tag_name='v2026.47.3', published_at='2026-11-20')
        with self.assertRaisesRegex(ValueError, 'latest published source'):
            rp.select_release_notes(source, [second, rollback, first])

    def test_filter_and_dedup_are_narrow_and_keep_technical_fallbacks(self):
        self.commit('Earlier change')
        previous = self.release(1, '2026-11-19')
        subjects = [
            'CI: Run builds daily (#10)', 'build(android): Update build tools (#11)',
            'DOCS: Explain setup (#12)', 'test: Adjust fixture (#13)',
            'CHAT: Keep drafts safe (#14)', 'fix(chat): Keep drafts safe (#15)',
            'QUALITY: Harden recovery (#16)', 'chore: Preserve useful detail (#17)',
            'Unclassified technical title (#18)',
        ]
        for subject in subjects:
            self.commit(subject)
        source = self.git('rev-parse', 'HEAD')
        self.assertEqual(rp.select_release_notes(source, [previous]), [
            'Keep drafts safe', 'Harden recovery', 'Preserve useful detail',
            'Unclassified technical title'])

    def test_unchanged_curated_file_uses_distinct_shipped_commit_subjects(self):
        self.commit('UI: Earlier shipped change (#1)')
        previous = self.release(1, '2026-11-19')
        source = self.commit('CHAT: Keep the conversation readable (#2)')
        expected = ['Keep the conversation readable']
        self.assertEqual(rp.select_release_notes(source, [previous]), expected)
        # Neither repeat invocation nor working-tree text changes affect the result.
        (self.repo / 'assets/changelog.json').write_text('not committed')
        self.assertEqual(rp.select_release_notes(source, [previous]), expected)


if __name__ == '__main__':
    unittest.main()
