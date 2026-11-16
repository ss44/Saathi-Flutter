"""Coverage gate behavior, using real small app trees and LCOV inputs."""
from pathlib import Path
import tempfile
import unittest

import check_coverage


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'lib').mkdir()
        (self.root / 'lib/app.dart').write_text('int answer() => 42;\n')
        self.report = self.root / 'lcov.info'

    def check(self, text, minimum='85'):
        self.report.write_text(text)
        return check_coverage.check(self.report, self.root, minimum)

    def test_exact_threshold_and_duplicate_lines(self):
        record = 'SF:lib/app.dart\n' + ''.join(
            f'DA:{line},{int(line <= 17)}\n' for line in range(1, 21)
        ) + 'end_of_record\n'
        self.assertEqual(self.check(record + record), (17, 20, []))

    def test_below_threshold_does_not_round_up(self):
        with self.assertRaisesRegex(ValueError, 'below'):
            self.check('SF:lib/app.dart\nDA:1,1\nDA:2,0\nend_of_record\n', '50.00001')

    def test_repeated_hits_merge_and_external_sources_do_not_count(self):
        text = ('SF:lib/app.dart\nDA:1,0\nend_of_record\n'
                'SF:lib/app.dart\nDA:1,2\nend_of_record\n'
                'SF:/sdk/external.dart\nDA:1,0\nend_of_record\n')
        self.assertEqual(self.check(text), (1, 1, []))

    def test_invalid_reports_fail_closed(self):
        for text in ['', 'garbage', 'SF:lib/app.dart\n',
                     'SF:lib/app.dart\nend_of_record\n',
                     'SF:lib/app.dart\nDA:0,1\nend_of_record\n',
                     'SF:lib/app.dart\nDA:1,-1\nend_of_record\n',
                     'SF:lib/app.dart\nDA:1,1\nwat\nend_of_record\n']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.check(text)

    def test_missing_logic_fails_but_verified_barrel_is_audited(self):
        extra = self.root / 'lib/anything.dart'
        text = 'SF:lib/app.dart\nDA:1,1\nend_of_record\n'
        extra.write_text("/// docs\nlibrary;\nexport 'app.dart';\n")
        self.assertEqual(self.check(text)[2], ['lib/anything.dart'])
        for source in ['int hidden() => 1;', "export 'app.dart';\nvoid hidden() {}", '',
                       "const hidden = 'https://example.com';"]:
            extra.write_text(source)
            with self.subTest(source=source), self.assertRaisesRegex(ValueError, 'missing app source'):
                self.check(text)

    def test_threshold_is_bounded_decimal(self):
        for minimum in ['NaN', 'Infinity', '-1', '101', 'abc', '1e999999', '0' * 10000]:
            with self.subTest(minimum=minimum[:20]), self.assertRaises(ValueError):
                self.check('SF:lib/app.dart\nDA:1,1\nend_of_record\n', minimum)

    def test_inconsistent_summaries_are_malformed(self):
        for summary in ['LF:2', 'LH:0', 'LF:1\nLF:1']:
            with self.subTest(summary=summary), self.assertRaises(ValueError):
                self.check('SF:lib/app.dart\nDA:1,1\n' + summary + '\nend_of_record\n')

    def test_report_size_is_bounded(self):
        self.report.write_bytes(b' ' * (check_coverage.MAX_REPORT_BYTES + 1))
        with self.assertRaisesRegex(ValueError, '32 MiB'):
            check_coverage.check(self.report, self.root)

    def test_missing_report(self):
        with self.assertRaises(ValueError):
            check_coverage.check(self.report, self.root, '85')


if __name__ == '__main__':
    unittest.main()
