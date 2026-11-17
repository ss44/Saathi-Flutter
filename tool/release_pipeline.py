#!/usr/bin/env python3
"""Fail-closed weekly release orchestration; GitHub access is via gh REST."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess

from desktop_release import expected_assets, file_digest, tag_parts, version_info


def marker(run_id):
    if not re.fullmatch(r'[0-9]+', str(run_id)):
        raise ValueError('Invalid workflow run ID')
    return f'<!-- saathi-release-run:{run_id} -->'


def plan(releases, tags, commit, run_number, run_id, tree, today=None):
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Source must be an exact full commit SHA')
    owned = [r for r in releases if marker(run_id) in (r.get('body') or '')]
    if owned:
        if len(owned) != 1 or not owned[0]['draft']:
            raise ValueError('Published releases are immutable; use a fresh workflow run')
        release = owned[0]
        if release['target_commitish'] != commit:
            raise ValueError('Owned draft source mismatch')
        result = version_info(release['tag_name'], run_number)
        return dict(result, release_required='true', release_id=release['id'], commit=commit)
    published = []
    for release in releases:
        tags.append(release['tag_name'])  # Drafts also reserve their versions.
        try:
            tag_parts(release['tag_name'])
        except ValueError:
            continue
        if not release['draft']:
            published.append(release)
    if published:
        latest = max(published, key=lambda r: r['published_at'])
        # Resolve the actual peeled tag, never target_commitish (which can be main).
        if tree(commit) == tree('refs/tags/' + latest['tag_name']):
            return dict(release_required='false', release_id='', commit=commit,
                        version='', build='', android_build='', tag='')
    result = version_info(None, run_number, today=today, existing_tags=tags)
    return dict(result, release_required='true', release_id='', commit=commit)


def inventory(api, repository):
    releases = []
    for page in range(1, 10001):
        batch = api(f'repos/{repository}/releases?per_page=100&page={page}')
        if not isinstance(batch, list):
            raise ValueError('Invalid release history response')
        releases.extend(batch)
        if len(batch) < 100:
            return releases
    raise ValueError('Release history pagination limit exceeded')


def require_empty_assets(release):
    if release['assets']:
        raise ValueError('Draft already has assets; refusing to clobber. Start a fresh workflow run (not a rerun) to reserve a new version; retain the failed draft.')


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def api(endpoint, method='GET', payload=None):
    args = ['gh', 'api', '--method', method, endpoint]
    if payload is not None:
        args += ['--input', '-']
    return json.loads(subprocess.check_output(args, input=json.dumps(payload) if payload is not None else None, text=True))


def validate_draft(release, tag, commit, run_id):
    if (not release['draft'] or release['tag_name'] != tag
            or release['target_commitish'] != commit
            or marker(run_id) not in (release.get('body') or '')
            or not release['prerelease']):
        raise ValueError('Draft identity/source/ownership mismatch or already published; refusing mutation')
    if type(release['id']) is not int:
        raise ValueError('REST release ID must be numeric')


def require_source_tag(repository, tag, commit, *, create=False):
    """Verify the remote peeled tag, optionally creating an absent ref once.

    Lookup/creation errors propagate: never overwrite a ref or retry a write.
    Recheck before promotion and afterward; tag protection is still required to
    prevent another authorized writer moving a tag between these checks.
    """
    tag_parts(tag)
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Source must be an exact full commit SHA')
    endpoint = f'repos/{repository}/git/matching-refs/tags/{tag}'
    rows = api(endpoint)
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise ValueError('Invalid remote tag inventory')
    refs = [row for row in rows if row.get('ref') == 'refs/tags/' + tag]
    if not refs and create:
        api(f'repos/{repository}/git/refs', 'POST',
            {'ref': 'refs/tags/' + tag, 'sha': commit})
        return require_source_tag(repository, tag, commit)
    if len(refs) != 1:
        raise ValueError('Missing or ambiguous remote source tag')
    obj = refs[0].get('object')
    seen = set()
    for _ in range(16):
        if not isinstance(obj, dict) or not isinstance(obj.get('sha'), str):
            raise ValueError('Invalid remote tag object')
        sha = obj['sha']
        if not re.fullmatch(r'[0-9a-f]{40}', sha) or sha in seen:
            raise ValueError('Invalid or cyclic remote tag object')
        seen.add(sha)
        if obj.get('type') == 'commit':
            if sha != commit:
                raise ValueError('Remote release tag does not match built source')
            return
        if obj.get('type') != 'tag':
            raise ValueError('Remote release tag must resolve to a commit')
        annotated = api(f'repos/{repository}/git/tags/{sha}')
        obj = annotated.get('object') if isinstance(annotated, dict) else None
    raise ValueError('Remote tag annotation depth exceeded')


CHANGES_START = '<!-- saathi-changes:start -->'
CHANGES_END = '<!-- saathi-changes:end -->'


def validate_notes(notes):
    if not isinstance(notes, list) or not all(
            isinstance(note, str) and note.strip() and '\n' not in note
            and '\r' not in note and '<!--' not in note for note in notes):
        raise ValueError('Invalid unreleased change notes')
    return notes


def source_notes(commit, *, historical=False):
    """Read a committed blob; only an absent historical path means no notes.

    Missing objects, invalid JSON/schema and Git failures always propagate.
    """
    entry = command('git', 'ls-tree', commit, '--', 'assets/changelog.json')
    if not entry:
        if historical:
            return []
        raise ValueError('Selected source has no assets/changelog.json')
    changelog = json.loads(command('git', 'show', commit + ':assets/changelog.json'))
    if not isinstance(changelog, dict) or changelog.get('schema') != 1:
        raise ValueError('Invalid source changelog schema')
    return validate_notes(changelog.get('unreleased'))


def select_release_notes(commit, releases):
    """Subtract all published canonical sources, not just the latest source.

    Only tagged published sources establish the ledger: neither release bodies,
    mutable target_commitish nor unshipped commits/archived entries do. Every
    eligible tag must resolve to a commit ancestral to the selected source.
    """
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Source must be an exact full commit SHA')
    current = source_notes(commit)
    old = set()
    sources = {commit: current}
    for release in releases:
        if release['draft']:
            continue
        try:
            tag_parts(release['tag_name'])
        except ValueError:
            continue
        baseline = command('git', 'rev-parse', '--verify',
                           'refs/tags/' + release['tag_name'] + '^{commit}')
        try:
            command('git', 'merge-base', '--is-ancestor', baseline, commit)
        except subprocess.CalledProcessError as error:
            if error.returncode == 1:
                raise ValueError('Previous published source is not an ancestor') from error
            raise
        if baseline not in sources:
            sources[baseline] = source_notes(baseline, historical=True)
        old.update(sources[baseline])
    return [note for note in current if note not in old]


def human_block(notes):
    notes = validate_notes(notes)
    displayed = notes or ['No additional change notes for this version.']
    return '\n' + ''.join('- ' + note + '\n' for note in displayed)


def replace_human_block(body, notes):
    """Pure metadata repair: preserve every byte outside one marked block."""
    if body.count(CHANGES_START) != 1 or body.count(CHANGES_END) != 1:
        raise ValueError('Expected exactly one start and end change marker')
    start = body.index(CHANGES_START) + len(CHANGES_START)
    end = body.index(CHANGES_END)
    if end < start:
        raise ValueError('Reversed change markers')
    return body[:start] + human_block(notes) + body[end:]


def release_body(run_id, notes):
    """Explicit selected human notes, separate from distribution instructions."""
    human = "## What's new\n" + CHANGES_START + human_block(notes) + CHANGES_END + '\n\n'
    return human + Path('docs/DESKTOP_RELEASE_NOTES.md').read_text() + '\n' + marker(run_id)


def prepare(repository, commit, run_number, run_id):
    releases = inventory(api, repository)
    tags = command('git', 'tag', '--list').splitlines()
    def tree(ref):
        # ^{commit} peels annotated tags; ^{tree} compares every tracked path.
        resolved = command('git', 'rev-parse', '--verify', ref + '^{commit}')
        return command('git', 'rev-parse', '--verify', resolved + '^{tree}')
    result = plan(releases, tags, commit, run_number, run_id, tree)
    if result['release_required'] == 'true':
        if not result['release_id']:
            body = release_body(run_id, select_release_notes(commit, releases))
            created = api(f'repos/{repository}/releases', 'POST', dict(
                tag_name=result['tag'], target_commitish=commit,
                name='Saathi ' + result['version'], body=body, draft=True, prerelease=True))
            if type(created['id']) is not int:
                raise ValueError('REST release ID must be numeric')
            result['release_id'] = created['id']
        release = api(f"repos/{repository}/releases/{result['release_id']}")
        validate_draft(release, result['tag'], commit, run_id)
        require_empty_assets(release)
    return result


def publish(repository, release_id, tag, commit, run_id, directory):
    endpoint = f'repos/{repository}/releases/{int(release_id)}'
    release = api(endpoint)
    validate_draft(release, tag, commit, run_id)
    require_empty_assets(release)
    directory = Path(directory)
    names = set(expected_assets(tag) + ['SHA256SUMS'])
    files = {p.name: p for p in directory.iterdir() if p.is_file()}
    if set(files) != names or len(list(directory.iterdir())) != 6:
        raise ValueError('Expected exactly six release files')
    require_source_tag(repository, tag, commit, create=True)
    for name in sorted(names):
        # Numeric ID upload avoids tag lookup for a not-yet-published draft.
        upload = f'https://uploads.github.com/repos/{repository}/releases/{int(release_id)}/assets?name={name}'
        command('gh', 'api', '--method', 'POST', upload,
                '-H', 'Content-Type: application/octet-stream', '--input', str(files[name]))
    release = api(endpoint)
    validate_draft(release, tag, commit, run_id)
    assets = release['assets']
    if len(assets) != 6 or {a['name'] for a in assets} != names:
        raise ValueError('Uploaded asset set mismatch; draft retained')
    for asset in assets:
        file = files[asset['name']]
        if asset['size'] != file.stat().st_size or asset.get('digest') != 'sha256:' + file_digest(file):
            raise ValueError('Uploaded asset size/digest mismatch or absent digest; draft retained')
    require_source_tag(repository, tag, commit)
    api(endpoint, 'PATCH', {'draft': False})
    published = api(endpoint)
    if published['draft'] or published['tag_name'] != tag or len(published['assets']) != 6:
        raise ValueError('Published release readback failed')
    require_source_tag(repository, tag, commit)
    print(f'Published {tag} from {commit}: all six assets verified.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'publish'])
    parser.add_argument('--repository', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--run-number', type=int)
    parser.add_argument('--release-id', type=int)
    parser.add_argument('--tag')
    parser.add_argument('--directory', default='dist')
    args = parser.parse_args()
    if args.operation == 'prepare':
        result = prepare(args.repository, args.commit, args.run_number, args.run_id)
        lines = ''.join(f'{key}={value}\n' for key, value in result.items())
        print(lines, end='')
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
            output.write(lines)
        summary = ('No tracked-tree changes since latest published weekly release; skipping version allocation, draft, verification, builds and publication.'
                   if result['release_required'] == 'false' else
                   f"Reserved hidden draft {result['tag']} for exact source {args.commit} before verification/builds.")
        with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as output:
            output.write(summary + '\n')
    else:
        publish(args.repository, args.release_id, args.tag, args.commit, args.run_id, args.directory)


if __name__ == '__main__':
    main()
