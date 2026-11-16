"""Keep both verification jobs independent of runner Python packages."""
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class PythonTestDependenciesTests(unittest.TestCase):
    def test_verification_installs_pinned_dependencies_before_branding(self):
        for filename, job in [('verify.yml', 'flutter'),
                              ('release-desktop.yml', 'verify')]:
            with self.subTest(workflow=filename):
                workflow = (ROOT / '.github/workflows' / filename).read_text()
                match = re.search(
                    rf'^  {job}:\n(.*?)(?=^  \w[^\n]*:|\Z)',
                    workflow, re.MULTILINE | re.DOTALL,
                )
                assert match is not None, f'Missing verification job: {job}'
                block = match.group(1)
                steps = re.split(r'^      - ', block, flags=re.MULTILINE)[1:]
                setup = next((i for i, step in enumerate(steps)
                              if 'uses: actions/setup-python@' in step), None)
                install = next((i for i, step in enumerate(steps)
                                if 'run: python3 -m pip install -r tool/requirements-test.txt' in step), None)
                branding = next(i for i, step in enumerate(steps)
                                if 'run: python3 -m unittest discover -s test/branding -v' in step)
                assert setup is not None, 'verification must set up Python'
                assert install is not None, 'verification must install test dependencies'
                self.assertLess(setup, install)
                self.assertLess(install, branding)
                self.assertRegex(steps[setup], r'actions/setup-python@[0-9a-f]{40}\b')
                self.assertIn("python-version: '3.13'", steps[setup])
                for index in (setup, install, branding):
                    self.assertNotRegex(steps[index], r'\b(if|continue-on-error):')
        requirements_path = ROOT / 'tool/requirements-test.txt'
        self.assertTrue(requirements_path.is_file(), 'test dependencies must be declared')
        requirements = requirements_path.read_text()
        self.assertEqual([line for line in requirements.splitlines()
                          if line and not line.startswith('#')], ['Pillow==13.0.0'])


if __name__ == '__main__':
    unittest.main()
