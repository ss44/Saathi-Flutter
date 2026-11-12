#!/usr/bin/env python3
"""Verify a real APK using Android SDK apksigner and aapt2 before upload."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

from generate_update_manifest import MAX_APK_BYTES


def verify(apk, sdk, package, version, build, certificate_sha256):
    apk, sdk = Path(apk), Path(sdk)
    expected = certificate_sha256.strip().replace(':', '').lower()
    if not re.fullmatch('[0-9a-f]{64}', expected):
        raise ValueError('A valid expected signing certificate SHA-256 is required')
    if not apk.is_file() or not 0 < apk.stat().st_size <= MAX_APK_BYTES:
        raise ValueError('APK missing, empty, or over updater download size limit')
    candidates = [tool for tool in (sdk / 'build-tools').glob('*/apksigner') if tool.is_file()]
    if not candidates:
        raise ValueError('Android SDK apksigner is required; unsigned fallback is forbidden')
    signer = max(candidates, key=lambda tool: tuple(int(part) for part in re.findall(r'\d+', tool.parent.name)))
    verification = subprocess.run([str(signer), 'verify', '--verbose', '--print-certs', str(apk)],
                                  capture_output=True, text=True, check=True)
    # AOSP prints SDK-range labels instead of numbered signers for v3.1 APKs.
    # Parse every signer digest, not Source Stamp certificates or just one range.
    signer_line = re.compile(r'Signer (?:#\d+|\(minSdkVersion=\d+(?: \(dev release=true\))?, maxSdkVersion=\d+\)) certificate SHA-256 digest: ([0-9a-fA-F]{64})')
    signers = set()
    for line in verification.stdout.splitlines():
        line = line.strip()
        if line.startswith('Signer ') and ' certificate SHA-256 digest:' in line:
            match = signer_line.fullmatch(line)
            if match is None:
                raise ValueError('Unrecognized APK signing certificate output; refusing partial signer verification')
            signers.add(match.group(1).lower())
    if signers != {expected}:
        # verify/print-certs only exposes public APK certificate data, never keys.
        print(f'Parsed APK signer count: {len(signers)}; SDK tool: {signer}', file=sys.stderr)
        print('Native apksigner stdout:\n' + (verification.stdout or '')[-6000:], file=sys.stderr)
        print('Native apksigner stderr:\n' + (verification.stderr or '')[-6000:], file=sys.stderr)
        raise ValueError('APK signing certificate does not match the configured release identity')
    aapt = next((signer.parent / name for name in ('aapt2', 'aapt') if (signer.parent / name).is_file()), None)
    if aapt is None:
        raise ValueError('Android SDK aapt2/aapt is required to verify APK metadata')
    badging = subprocess.run([str(aapt), 'dump', 'badging', str(apk)], capture_output=True, text=True, check=True).stdout
    package_line = next((line for line in badging.splitlines() if line.startswith('package: ')), '')
    fields = dict(re.findall(r"([A-Za-z]+)='([^']*)'", package_line))
    if (fields.get('name'), fields.get('versionName'), fields.get('versionCode')) != (package, version, str(build)):
        raise ValueError('APK package/version/build metadata does not match the intended release')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--package', default='io.github.ss44.saathi')
    parser.add_argument('--version', required=True)
    parser.add_argument('--build', type=int, required=True)
    arguments = parser.parse_args()
    try:
        verify(arguments.apk, arguments.sdk, arguments.package, arguments.version, arguments.build,
               os.environ.get('ANDROID_SIGNING_CERT_SHA256', ''))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.error(str(error))
    print('Verified APK signature, signer identity, package, version, and build using Android SDK tools.')


if __name__ == '__main__':
    main()
