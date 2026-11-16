"""Require <DOMAIN>: <summary>; read untrusted titles only as environment data."""
import os
import re
import sys
import unicodedata


def valid_title(title: str) -> bool:
    """Accept a bounded uppercase domain and a trimmed single-line summary."""
    if not 1 <= len(title) <= 256:
        return False
    if any(unicodedata.category(character).startswith('C') or character in '\u2028\u2029' for character in title):
        return False
    match = re.fullmatch(r'[A-Z][A-Z0-9]*: (\S(?:.*\S)?)', title)
    return match is not None


def main() -> int:
    """Validate PR_TITLE without evaluating or echoing its contents."""
    if valid_title(os.environ.get('PR_TITLE', '')):
        print('PR title format is valid.')
        return 0
    print('PR title must be <DOMAIN>: <summary> (uppercase domain; trimmed single line; max 256 characters).', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
