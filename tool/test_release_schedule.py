"""Binary releases are weekly/on-demand, not triggered by source pushes."""
from pathlib import Path
import re
import unittest


class ReleaseScheduleTests(unittest.TestCase):
    def test_release_trigger_is_weekly_and_manual_only(self):
        workflow = (Path(__file__).resolve().parents[1] / '.github/workflows/release-desktop.yml').read_text()
        match = re.search(r'^on:\n(.*?)(?=^\S|\Z)', workflow, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match, 'GitHub Actions triggers must be explicit')
        assert match is not None
        triggers = match.group(1)
        self.assertIn('  workflow_dispatch:', triggers)
        self.assertIn('  schedule:', triggers)
        self.assertIn("cron: '0 9 * * 1'", triggers)
        self.assertNotRegex(triggers, r'(?m)^  (push|pull_request):')


if __name__ == '__main__':
    unittest.main()
