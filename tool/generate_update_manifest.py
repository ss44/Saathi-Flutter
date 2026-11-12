#!/usr/bin/env python3
"""Create a bounded v1 update manifest. Does NOT sign or verify APK signing."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from urllib.parse import quote

MAX_APK_BYTES = 150 * 1024 * 1024
SEMVER = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?')


def generate(owner, repo, version, build, channel, apk):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,38}', owner):
        raise ValueError('Invalid GitHub owner')
    if not re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]{0,99}', repo):
        raise ValueError('Invalid GitHub repository')
    match = SEMVER.fullmatch(version)
    if not match or not 1 <= build <= 2100000000:
        raise ValueError('Invalid semantic version or Android build number')
    prerelease = match.group(4)
    if prerelease and any(re.fullmatch(r'0[0-9]+', part) for part in prerelease.split('.')):
        raise ValueError('Leading zeros in prerelease')
    if channel not in ('stable', 'beta') or (channel == 'stable' and prerelease):
        raise ValueError('Stable channel cannot contain a prerelease')
    apk = Path(apk)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', apk.name) or '..' in apk.name or apk.suffix != '.apk':
        raise ValueError('Invalid APK asset name')
    size = apk.stat().st_size
    if not 0 < size <= MAX_APK_BYTES:
        raise ValueError('APK exceeds update size limit or is empty')
    digest = hashlib.sha256()
    with apk.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    tag = f'v{version}'
    return {
        'schema': 1, 'version': version, 'build': build, 'channel': channel,
        'platform': 'android',
        'asset': {'name': apk.name, 'size': size, 'sha256': digest.hexdigest(),
            'url': f'https://github.com/{owner}/{repo}/releases/download/{quote(tag, safe="")}/{quote(apk.name, safe="")}'},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('owner', 'repo', 'version', 'apk', 'output'):
        parser.add_argument(f'--{name}', required=True)
    parser.add_argument('--build', type=int, required=True)
    parser.add_argument('--channel', choices=['stable', 'beta'], default='stable')
    args = parser.parse_args()
    try:
        manifest = generate(args.owner, args.repo, args.version, args.build, args.channel, args.apk)
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print('Created manifest; this tool does not verify APK signing. Verify with apksigner before publication.', file=sys.stderr)


if __name__ == '__main__':
    main()
