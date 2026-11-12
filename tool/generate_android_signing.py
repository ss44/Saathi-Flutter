#!/usr/bin/env python3
"""Generate a private, reusable Android PKCS12 signing identity and backup.

Never run this into the repository. Never overwrite or rotate a shipped key.
The generated ZIP contains BOTH the keystore and password: store it in a vault.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import zipfile


def _write_private(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as output:
        output.write(value)


def _openssl(*arguments):
    # Suppress key-generation progress; credentials are read through files, never argv.
    return subprocess.run(['openssl', *map(str, arguments)], capture_output=True, check=True).stdout


def generate(output):
    output = Path(output).expanduser().resolve()
    repository = Path(__file__).resolve().parents[1]
    if output == repository or repository in output.parents:
        raise ValueError('Signing identities must be generated outside the repository')
    # Intentionally fail on any pre-existing path. A second key cannot upgrade APKs
    # signed by the first key, so never silently replace a signing identity.
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(output, 0o700)
    previous_umask = os.umask(0o077)
    key = output / 'working-key.pem'
    password_file = output / 'keystore-password.txt'
    working_password = output / 'working-password.txt'
    certificate = output / 'certificate.pem'
    keystore = output / 'saathi-release.p12'
    password = secrets.token_urlsafe(36)
    alias = 'saathi-release'
    try:
        _write_private(password_file, password + '\n')
        # OpenSSL shares the BIO when passin/passout name the same file, reading
        # two successive lines. Separate temporary inputs avoid that ambiguity.
        _write_private(working_password, password + '\n')
        _openssl('req', '-x509', '-newkey', 'rsa:4096', '-sha256', '-days', '10000',
                 '-subj', '/CN=Saathi Standalone Signing/O=Saathi/OU=Local Testing',
                 '-keyout', key, '-out', certificate, '-passout', f'file:{working_password}')
        _openssl('pkcs12', '-export', '-name', alias, '-inkey', key, '-in', certificate,
                 '-out', keystore, '-passin', f'file:{working_password}', '-passout', f'file:{password_file}',
                 '-keypbe', 'AES-256-CBC', '-certpbe', 'AES-256-CBC', '-macalg', 'SHA256')
        _openssl('pkcs12', '-in', keystore, '-passin', f'file:{password_file}', '-info', '-noout')
        fingerprint = hashlib.sha256(_openssl('x509', '-in', certificate, '-outform', 'DER')).hexdigest()
        _write_private(output / 'signing-credentials.txt',
                       f'Format: PKCS12\nKey alias: {alias}\nKeystore password: {password}\nKey password: {password}\nCertificate SHA-256: {fingerprint}\n')
        _write_private(output / 'github-secrets.json', json.dumps({
            'ANDROID_KEYSTORE_BASE64': base64.b64encode(keystore.read_bytes()).decode('ascii'),
            'ANDROID_KEYSTORE_PASSWORD': password,
            'ANDROID_KEY_ALIAS': alias,
            'ANDROID_KEY_PASSWORD': password,
            'ANDROID_SIGNING_CERT_SHA256': fingerprint,
        }, indent=2) + '\n')
        _write_private(output / 'README.txt',
            'PRIVATE SAATHI ANDROID SIGNING BACKUP\n\n'
            'This ZIP contains the encrypted PKCS12 keystore AND its passwords.\n'
            'Treat the entire bundle as a secret. Save it as a private Bitwarden\n'
            'attachment/secure note. Never upload it to GitHub source or a release.\n\n'
            'Keep this identity for EVERY standalone APK update, including local testing.\n'
            'A different key cannot upgrade an installed app signed by this one.\n'
            'The certificate is self-signed, which is normal for standalone APKs.\n'
            'Google Play distribution/signing is separate and not configured here.\n\n'
            'saathi-release.p12 = encrypted private key and certificate\n'
            'signing-credentials.txt = alias, passwords, public fingerprint\n'
            'github-secrets.json = exact five Actions secrets for release workflow\n'
            'keystore-password.txt = OpenSSL password-file input\n'
            'certificate.pem = public certificate only\n\n'
            'Import the five values from github-secrets.json into repository Actions\n'
            'secrets through a secure UI/API, never through a chat or commit.\n')
        archive = output / 'Saathi-Android-signing-backup.zip'
        with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED) as backup:
            for path in sorted(output.iterdir()):
                if path not in (archive, key, working_password):
                    backup.write(path, path.name)
        with zipfile.ZipFile(archive) as backup:
            if backup.testzip() is not None:
                raise ValueError('Signing backup failed integrity verification')
        for path in output.iterdir():
            os.chmod(path, 0o600)
        return archive
    finally:
        key.unlink(missing_ok=True)
        working_password.unlink(missing_ok=True)
        os.umask(previous_umask)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    archive = generate(arguments.output)
    print(f'Private signing backup generated and verified: {archive}')
    print('Credentials were not printed. Store the entire backup in your vault.')


if __name__ == '__main__':
    main()
