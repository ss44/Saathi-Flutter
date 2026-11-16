"""Fail-closed LCOV app-line coverage gate; no third-party dependencies."""
import argparse
from decimal import Decimal, InvalidOperation
from pathlib import Path
import re
import sys

MAX_REPORT_BYTES = 32 * 1024 * 1024


def check(report: Path, root: Path, minimum: str = '85') -> tuple[int, int, list[str]]:
    """Return covered/total distinct app lines and audited non-executable files."""
    if not re.fullmatch(r'[0-9]{1,3}(?:\.[0-9]{1,6})?', minimum):
        raise ValueError('minimum must be a plain decimal with at most six fractional digits')
    try:
        threshold = Decimal(minimum)
    except InvalidOperation as error:
        raise ValueError('minimum must be a decimal percentage') from error
    if not threshold.is_finite() or not 0 <= threshold <= 100:
        raise ValueError('minimum must be between 0 and 100')
    try:
        if report.stat().st_size > MAX_REPORT_BYTES:
            raise ValueError('coverage report exceeds 32 MiB')
        text = report.read_text(encoding='utf-8')
    except (OSError, UnicodeError) as error:
        raise ValueError(f'cannot read coverage report: {error}') from error
    root = root.resolve()
    app = root / 'lib'
    if not app.is_dir():
        raise ValueError('app root must contain lib/')
    app_files = {path.resolve() for path in app.rglob('*.dart')}
    lines: dict[tuple[Path, int], bool] = {}
    seen: set[Path] = set()
    current = None
    record_lines = 0
    records = 0
    record_hits: dict[int, bool] = {}
    summaries: dict[str, int] = {}
    for number, entry in enumerate(text.splitlines(), 1):
        if not entry:
            continue
        if len(entry) > 16384:
            raise ValueError(f'oversized LCOV entry at {number}')
        if entry.startswith('TN:') and current is None:
            continue
        if entry.startswith('SF:'):
            if current is not None or not entry[3:].strip():
                raise ValueError(f'malformed SF at {number}')
            source = Path(entry[3:])
            current = (source if source.is_absolute() else root / source).resolve()
            record_lines = 0
            record_hits = {}
            summaries = {}
        elif entry == 'end_of_record':
            if current is None or record_lines == 0:
                raise ValueError(f'empty or malformed record at {number}')
            if ('LF' in summaries and summaries['LF'] != len(record_hits)) or (
                'LH' in summaries and summaries['LH'] != sum(record_hits.values())
            ):
                raise ValueError(f'inconsistent line summary at {number}')
            if current in app_files:
                seen.add(current)
            current = None
            records += 1
        elif entry.startswith('DA:'):
            match = re.fullmatch(r'DA:([1-9][0-9]{0,8}),([0-9]{1,18})(?:,[a-fA-F0-9]+)?', entry)
            if current is None or match is None:
                raise ValueError(f'malformed DA at {number}')
            line, hits = int(match[1]), int(match[2])
            record_hits[line] = record_hits.get(line, False) or hits > 0
            if current in app_files:
                key = current, line
                lines[key] = lines.get(key, False) or hits > 0
            elif current.is_relative_to(app):
                raise ValueError(f'unknown app source: {current}')
            record_lines += 1
        elif current is not None and re.fullmatch(r'(?:LF|LH):[0-9]{1,9}', entry):
            key, value = entry.split(':')
            if key in summaries:
                raise ValueError(f'duplicate line summary at {number}')
            summaries[key] = int(value)
        elif current is None or not re.fullmatch(
            r'(?:FNF|FNH|BRF|BRH):[0-9]+|FN:[0-9]+,.+|FNDA:[0-9]+,.+|BRDA:[0-9]+,[0-9]+,[0-9]+,(?:-|[0-9]+)', entry
        ):
            raise ValueError(f'malformed LCOV entry at {number}')
    if current is not None or not records or not lines:
        raise ValueError('empty, incomplete or missing app line coverage')
    audited = []
    for path in sorted(app_files - seen):
        source = path.read_text(encoding='utf-8')
        # Preserve strings before stripping comments; never hide executable tokens.
        source = re.sub(r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\"|//[^\n]*|/\*[\s\S]*?\*/",
                        lambda match: '' if match[0].startswith(('//', '/*')) else match[0], source)
        directive = r"(?:library(?:\s+[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)?\s*;|export\s+'[^'\n]+'\s*;)"
        if not source.strip() or not re.fullmatch(r'\s*(?:' + directive + r'\s*)+', source):
            raise ValueError(f'missing app source in LCOV: {path.relative_to(root)}')
        audited.append(str(path.relative_to(root)))
    covered, total = sum(lines.values()), len(lines)
    if Decimal(covered) * 100 < threshold * total:
        raise ValueError(f'app line coverage {covered}/{total} below {threshold}%')
    return covered, total, audited


def main() -> int:
    """Validate one complete report against a bounded decimal threshold."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--minimum', default='85')
    args = parser.parse_args()
    try:
        covered, total, audited = check(args.report, args.root, args.minimum)
    except ValueError as error:
        print(f'Coverage gate failed: {error}', file=sys.stderr)
        return 1
    print(f'App Dart line coverage: {covered}/{total} = {Decimal(covered) * 100 / total}% (minimum {args.minimum}%)')
    for path in audited:
        print(f'Audited non-executable directives only: {path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
