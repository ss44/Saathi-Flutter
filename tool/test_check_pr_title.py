"""PR title contract; titles are data, never shell programs."""
import os
from pathlib import Path
import subprocess
import sys
import unittest

import check_pr_title


class TitleTests(unittest.TestCase):
    def test_title_contract(self):
        for title in ['CI: Add coverage gate', 'CORE: Fix retry', 'UI: $(touch /tmp/nope)']:
            self.assertTrue(check_pr_title.valid_title(title), title)
        for title in ['', 'ci: fix', 'CI: ', ' CI: Fix', 'CI: Fix ', 'CI:  Fix',
                      'CI:Fix', 'CI: Fix\n', 'CI: Fix\rMore', 'CI: Fix\x00',
                      'CI: Fix\u2028more', 'CI: ' + 'x' * 1000]:
            self.assertFalse(check_pr_title.valid_title(title), repr(title))

    def test_cli_uses_environment_as_data(self):
        script = Path(__file__).with_name('check_pr_title.py')
        for title, expected in [('CI: $(exit 88)', 0), ('bad', 1)]:
            result = subprocess.run([sys.executable, str(script)],
                                    env={**os.environ, 'PR_TITLE': title}, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stderr)


if __name__ == '__main__':
    unittest.main()
