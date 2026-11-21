"""Source-pinned notes across actual Git releases, without GitHub writes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release_pipeline as rp


class SourceNotesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        real_command = rp.command
        self.command_patch = patch.object(
            rp, 'command', side_effect=lambda *args: real_command(
                'git', '-C', str(self.repo), *args[1:]))
        self.command_patch.start()
        self.addCleanup(self.command_patch.stop)

    def git(self, *args):
        return subprocess.check_output(
            ['git', '-C', str(self.repo), *args], text=True,
            stderr=subprocess.PIPE).strip()

    def commit(self, notes=None, raw=None, subject="fixture"):
        path = self.repo / 'assets/changelog.json'
        path.parent.mkdir(exist_ok=True)
        if notes is not None or raw is not None:
            path.write_text(raw if raw is not None else json.dumps(
                {'schema': 1, 'unreleased': notes, 'releases': []}))
        (self.repo / 'sequence').write_text(self.git('rev-list', '--all', '--count'))
        self.git('add', '.')
        self.git('commit', '-qm', subject)
        return self.git('rev-parse', 'HEAD')

    def release(self, tag, date):
        self.git('tag', '-a', tag, '-m', 'annotated fixture')
        return dict(tag_name=tag, published_at=date, draft=False,
                    target_commitish='main', body='- deliberately wrong notes')

    def test_first_release_keeps_curated_bootstrap_not_commit_history(self):
        self.commit(['A'], subject='CHAT: Earlier technical title (#1)')
        source = self.commit(['A', 'B'], subject='CHAT: Latest technical title (#2)')
        (self.repo / 'assets/changelog.json').write_text('invalid worktree')
        self.assertEqual(rp.select_release_notes(source, []), ['A', 'B'])

    def test_missing_historical_file_is_first_notes_not_git_failure(self):
        self.commit()
        previous = self.release('v2026.47.1', '2026-11-16')
        source = self.commit(['First notes'], subject='CHAT: First notes (#2)')
        self.assertEqual(rp.select_release_notes(source, [previous]), ['First notes'])

    def test_bad_json_missing_objects_and_nonancestor_fail_closed(self):
        original = self.commit(['A'])
        previous = self.release('v2026.47.1', '2026-11-16')
        malformed = self.commit(raw='{bad json')
        with self.assertRaises(ValueError):
            rp.select_release_notes(malformed, [])
        bad_previous = self.release('v2026.47.2', '2026-11-17')
        source = self.commit(['B'])
        with self.assertRaises(ValueError):
            rp.select_release_notes(source, [bad_previous])
        with self.assertRaises(subprocess.CalledProcessError):
            rp.select_release_notes('f' * 40, [previous])
        self.git('checkout', '--orphan', 'other')
        other = self.commit(['Different root'])
        with self.assertRaisesRegex(ValueError, 'ancestor'):
            rp.select_release_notes(other, [previous])
        self.assertNotEqual(original, other)

    def test_only_published_canonical_sources_contribute_once(self):
        first_source = self.commit(['A'])
        first = self.release('v2026.47.1', '2026-11-16')
        duplicate = self.release('v2026.47.2', '2026-11-17')
        self.commit(['Never published'])
        self.commit(raw=json.dumps({
            'schema': 1, 'unreleased': ['A', 'Never published', 'Archived draft', 'C'],
            'releases': [{'version': '2026.47.99', 'changes': ['Archived draft']}],
        }))
        source = self.git('rev-parse', 'HEAD')
        ignored = [dict(tag_name='v2026.47.99', draft=True),
                   dict(tag_name='not-weekly', draft=False)]
        with patch.object(rp, 'source_notes', wraps=rp.source_notes) as read:
            self.assertEqual(rp.select_release_notes(
                source, [first, duplicate] + ignored),
                ['fixture'])
        self.assertEqual(read.call_count, 2)
        self.assertEqual(read.call_args_list[1].args, (first_source,))
        self.assertEqual(rp.select_release_notes(source, ignored),
                         ['A', 'Never published', 'Archived draft', 'C'])

    def test_older_published_errors_cannot_hide_behind_valid_latest(self):
        original = self.commit(['A'])
        older = self.release('v2026.47.1', '2026-11-16')
        self.commit(['B'])
        latest = self.release('v2026.47.2', '2026-11-17')
        source = self.commit(['C'])
        self.git('tag', '-d', older['tag_name'])
        with self.assertRaises(subprocess.CalledProcessError):
            rp.select_release_notes(source, [latest, older])
        for raw in ['{bad json', '{"schema": 2, "unreleased": []}',
                    '{"schema": 1, "unreleased": [42]}']:
            self.git('checkout', '--detach', original)
            malformed = self.commit(raw=raw)
            self.git('tag', '-f', older['tag_name'], malformed)
            with self.assertRaisesRegex(ValueError, 'ancestor'):
                rp.select_release_notes(source, [latest, older])
            # The same malformed source made reachable must fail on its data.
            self.git('checkout', '--detach', malformed)
            reachable = self.commit(['C'])
            self.git('tag', '-f', latest['tag_name'], reachable)
            with self.assertRaises(ValueError):
                rp.select_release_notes(reachable, [latest, older])
            self.git('tag', '-f', latest['tag_name'], source)

    def test_prepare_uses_real_source_delta_and_skips_unchanged_before_allocation(self):
        self.commit(['Old'])
        previous = self.release('v2026.47.1', '2026-11-16')
        source = self.commit(['Old', 'New'], subject='CHAT: New (#2)')
        draft = None
        writes = []

        def api(endpoint, method='GET', payload=None):
            nonlocal draft
            if '?' in endpoint:
                return [previous]
            if method == 'POST':
                writes.append(payload)
                draft = dict(payload, id=123, assets=[])
            return draft

        with patch.object(rp, 'api', api):
            rp.prepare('fixture/repo', source, 7, '123')
        self.assertEqual(len(writes), 1)
        self.assertIn('- New\n', writes[0]['body'])
        self.assertNotIn('- Old\n', writes[0]['body'])
        self.assertEqual(writes[0]['target_commitish'], source)
        self.git('tag', '-f', 'v2026.47.1', source)
        with patch.object(rp, 'api', api), patch.object(rp, 'version_info') as allocate, \
                patch.object(rp, 'select_release_notes') as notes:
            result = rp.prepare('fixture/repo', source, 7, '124')
        self.assertEqual(result['release_required'], 'false')
        allocate.assert_not_called()
        notes.assert_not_called()
        self.assertEqual(len(writes), 1)

    def test_schema_validation_missing_tags_and_git_failure_are_not_empty_notes(self):
        source = self.commit(['A'])
        previous = self.release('v2026.47.1', '2026-11-16')
        for raw in ['[]', '{"schema": 2, "unreleased": []}',
                    '{"schema": 1, "unreleased": [42]}']:
            bad = self.commit(raw=raw)
            with self.assertRaises(ValueError):
                rp.select_release_notes(bad, [previous])
        self.git('tag', '-d', previous['tag_name'])
        with self.assertRaises(subprocess.CalledProcessError):
            rp.select_release_notes(source, [previous])
        self.git('tag', previous['tag_name'], source)
        original = rp.command

        def broken(*args):
            if 'merge-base' in args:
                raise subprocess.CalledProcessError(128, args)
            return original(*args)

        with patch.object(rp, 'command', side_effect=broken):
            with self.assertRaises(subprocess.CalledProcessError):
                rp.select_release_notes(source, [previous])

    def test_git_errors_propagate(self):
        with patch.object(rp, 'command', side_effect=RuntimeError('unreadable Git data')):
            with self.assertRaisesRegex(RuntimeError, 'Git'):
                rp.select_release_notes('a' * 40, [])


class BodyTests(unittest.TestCase):
    def test_explicit_notes_and_honest_empty_block(self):
        self.assertIn('- New only\n', rp.release_body('123', ['New only']))
        body = rp.release_body('123', [])
        self.assertIn('No additional change notes for this version.', body)
        self.assertNotIn('Swipe', body)

    def test_replace_only_human_block_and_reject_ambiguous_markers(self):
        start = '<!-- saathi-changes:start -->'
        end = '<!-- saathi-changes:end -->'
        body = f'Heading\n{start}\n- Old\n{end}\nboilerplate\n{rp.marker("123")}\n'
        changed = rp.replace_human_block(body, ['New'])
        self.assertEqual(changed, body.replace('- Old', '- New'))
        for invalid in [body + start, body + end, body.replace(end, ''), end + start]:
            with self.assertRaises(ValueError):
                rp.replace_human_block(invalid, ['New'])
        for notes in [['bad\nline'], ['<!-- injection -->'], [42], ['']]:
            with self.assertRaises(ValueError):
                rp.replace_human_block(body, notes)


if __name__ == '__main__':
    unittest.main()
