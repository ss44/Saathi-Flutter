#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <memory>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Keep one preferences writer per desktop session. A second launch only
  // activates the existing window, never starts another Flutter engine.
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, FALSE, L"Local\\io.github.ss44.saathi");
  if (!instance_mutex) {
    return EXIT_FAILURE;
  }
  const bool already_running = ::GetLastError() == ERROR_ALREADY_EXISTS;
  // Declared before the engine/window so the mutex survives their destruction.
  std::unique_ptr<void, decltype(&::CloseHandle)>
      instance_guard(instance_mutex, ::CloseHandle);
  if (already_running) {
    HWND existing_window =
        ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Saathi");
    if (existing_window) {
      if (::IsIconic(existing_window)) {
        ::ShowWindow(existing_window, SW_RESTORE);
      }
      ::SetForegroundWindow(existing_window);
    }
    return EXIT_SUCCESS;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Saathi", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
