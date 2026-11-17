"""Native source contracts, not proof of OS activation or native execution."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SingleInstanceTests(unittest.TestCase):
    def test_linux_reuses_registered_application_and_existing_window(self):
        source = (ROOT / 'linux/runner/my_application.cc').read_text()
        self.assertNotIn('G_APPLICATION_NON_UNIQUE', source)
        activate = source.split('static void my_application_activate', 1)[1].split(
            '// Implements GApplication::local_command_line.', 1)[0]
        self.assertLess(activate.index('gtk_application_get_active_window'),
                        activate.index('gtk_application_window_new'))
        self.assertIn('gtk_window_present(existing_window);', activate)
        self.assertIn('return;', activate.split('gtk_application_window_new')[0])

    def test_windows_gates_engine_creation_and_activates_existing_window(self):
        source = (ROOT / 'windows/runner/main.cpp').read_text()
        before_engine = source.split('flutter::DartProject project', 1)[0]
        self.assertIn('CreateMutexW', before_engine)
        self.assertIn('ERROR_ALREADY_EXISTS', before_engine)
        self.assertIn('if (!instance_mutex)', before_engine)
        self.assertIn('FindWindowW', before_engine)
        self.assertIn('SetForegroundWindow', before_engine)
        self.assertIn('SW_RESTORE', before_engine)
        self.assertIn('std::unique_ptr<void, decltype(&::CloseHandle)>', before_engine)
        self.assertIn('instance_guard(instance_mutex, ::CloseHandle)', before_engine)


if __name__ == '__main__':
    unittest.main()
