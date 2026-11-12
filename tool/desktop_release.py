#!/usr/bin/env python3
"""CalVer metadata, complete desktop bundles, and release checksums (stdlib only)."""
import argparse
import datetime as dt
import hashlib
import os
from pathlib import Path
import re
import tarfile
import zipfile


def tag_parts(tag):
    match = re.fullmatch(r'v([1-9][0-9]{3})\.([1-9][0-9]?)\.([1-9][0-9]*)', tag)
    if not match:
        raise ValueError('Tag must be vYEAR.WEEK.INCREMENT, without leading zeroes')
    year, week, increment = map(int, match.groups())
    dt.date.fromisocalendar(year, week, 1)  # Reject nonexistent ISO week 53/54.
    if not 1 <= increment <= 65535:
        raise ValueError('Weekly increment must be between 1 and 65535')
    return year, week, increment


def version_info(tag, run_number, today=None, existing_tags=()):
    today = today or dt.datetime.now(dt.timezone.utc).date()
    build = int(run_number)
    if not 1 <= build <= 65535:
        raise ValueError('Internal desktop build number must be between 1 and 65535')
    if tag:
        year, week, increment = tag_parts(tag)
    else:
        year, week, _ = today.isocalendar()
        increments = []
        for existing in existing_tags:
            try:
                tag_year, tag_week, value = tag_parts(existing)
            except ValueError:
                continue  # Ignore legacy date tags and unrelated project tags.
            if (tag_year, tag_week) == (year, week):
                increments.append(value)
        increment = max(increments, default=0) + 1
        if increment > 65535:
            raise ValueError('Weekly increment exhausted')
    version = f'{year}.{week}.{increment}'
    return {'version': version, 'build': build, 'tag': f'v{version}'}


def validated_tag(tag):
    if version_info(tag, 1)['tag'] != tag:
        raise ValueError('Noncanonical release tag')
    return tag


def expected_assets(tag):
    validated_tag(tag)
    return [f'Saathi-{tag[1:]}-linux-x64.tar.gz',
            f'Saathi-{tag[1:]}-macos-universal.zip',
            f'Saathi-{tag[1:]}-windows-x64.zip']


def package_bundle(platform, bundle, output, tag):
    validated_tag(tag)
    bundle, output = Path(bundle), Path(output)
    if not bundle.is_dir():
        raise ValueError('Build bundle does not exist')
    required = {'windows-x64': ['saathi.exe', 'flutter_windows.dll', 'data/icudtl.dat'],
                'linux-x64': ['saathi', 'lib/libflutter_linux_gtk.so', 'data/icudtl.dat']}
    if platform not in required:
        raise ValueError('Use macOS ditto for .app packaging to preserve framework symlinks')
    for name in required[platform]:
        if not (bundle / name).is_file():
            raise ValueError(f'Incomplete {platform} bundle: missing {name}')
    # Do not mutate the build output merely to add packaging instructions.
    instructions = (
        'Saathi standalone desktop preview\n\n'
        'Keep this entire directory together; the executable needs its libraries and data.\n'
        'This build is not production-signed. Windows may show SmartScreen warnings.\n'
        'Linux: run ./saathi in a desktop session. Requires compatible GTK 3, libsecret,\n'
        'libstdc++ and a running Secret Service/keyring for API-key storage.\n'
        'Linux x64 is 64-bit x86, NOT 32-bit i386. Built on Ubuntu 22.04.\n'
        'No automatic desktop replacement/installer is included.\n'
    ).encode()
    output.mkdir(parents=True, exist_ok=True)
    suffix = '.zip' if platform == 'windows-x64' else '.tar.gz'
    archive = output / f'Saathi-{tag[1:]}-{platform}{suffix}'
    if archive.exists():
        raise ValueError('Refusing to overwrite an existing release artifact')
    if platform == 'windows-x64':
        with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED) as packed:
            for path in sorted(bundle.rglob('*')):
                if path.is_file():
                    packed.write(path, Path('Saathi') / path.relative_to(bundle))
            packed.writestr('Saathi/RUNNING.txt', instructions)
    else:
        import io
        with tarfile.open(archive, 'x:gz', dereference=False) as packed:
            packed.add(bundle, arcname='Saathi')
            info = tarfile.TarInfo('Saathi/RUNNING.txt')
            info.size, info.mode = len(instructions), 0o644
            packed.addfile(info, io.BytesIO(instructions))
    return archive


def file_digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def write_checksums(directory, tag):
    directory = Path(directory)
    names = expected_assets(tag)
    for name in names:
        if not (directory / name).is_file() or (directory / name).stat().st_size == 0:
            raise ValueError(f'Missing release artifact: {name}')
    actual = sorted(p.name for p in directory.iterdir() if p.suffix == '.zip' or p.name.endswith('.tar.gz'))
    if actual != sorted(names):
        raise ValueError('Unexpected release archive set')
    result = directory / 'SHA256SUMS'
    result.write_text(''.join(f'{file_digest(directory / name)}  {name}\n' for name in sorted(names)), encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    metadata = commands.add_parser('metadata')
    metadata.add_argument('--tag', default='')
    metadata.add_argument('--run-number', type=int, required=True)
    metadata.add_argument('--tags-file', type=Path)
    package = commands.add_parser('package')
    package.add_argument('--platform', choices=['windows-x64', 'linux-x64'], required=True)
    package.add_argument('--bundle', type=Path, required=True)
    package.add_argument('--output', type=Path, required=True)
    package.add_argument('--tag', required=True)
    checksums = commands.add_parser('checksums')
    checksums.add_argument('--directory', type=Path, required=True)
    checksums.add_argument('--tag', required=True)
    args = parser.parse_args()
    if args.command == 'metadata':
        tags = args.tags_file.read_text(encoding='utf-8').splitlines() if args.tags_file else []
        values = version_info(args.tag or None, args.run_number, existing_tags=tags)
        lines = ''.join(f'{key}={value}\n' for key, value in values.items())
        print(lines, end='')
        if os.environ.get('GITHUB_OUTPUT'):
            with Path(os.environ['GITHUB_OUTPUT']).open('a', encoding='utf-8') as output:
                output.write(lines)
    elif args.command == 'package':
        print(package_bundle(args.platform, args.bundle, args.output, args.tag))
    else:
        print(write_checksums(args.directory, args.tag))


if __name__ == '__main__':
    main()
