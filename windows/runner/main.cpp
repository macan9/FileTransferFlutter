#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <functional>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kRunnerWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

std::wstring BuildSingleInstanceMutexName() {
  wchar_t executable_path[MAX_PATH];
  DWORD path_length =
      GetModuleFileNameW(nullptr, executable_path, MAX_PATH);
  if (path_length == 0 || path_length >= MAX_PATH) {
    return L"Local\\FileTransferFlutter_MaGeToolbox_SingleInstance_Fallback";
  }

  const std::wstring resolved_path(executable_path, path_length);
  const size_t path_hash = std::hash<std::wstring>{}(resolved_path);
  return L"Local\\FileTransferFlutter_MaGeToolbox_SingleInstance_" +
         std::to_wstring(path_hash);
}

void RestoreExistingWindowIfPresent() {
  HWND existing_window = FindWindow(kRunnerWindowClassName, nullptr);
  if (!existing_window) {
    return;
  }

  if (IsIconic(existing_window)) {
    ShowWindow(existing_window, SW_RESTORE);
  }
  ShowWindow(existing_window, SW_RESTORE);
  ShowWindow(existing_window, SW_SHOW);
  ShowWindow(existing_window, SW_SHOWNORMAL);
  SetForegroundWindow(existing_window);
  BringWindowToTop(existing_window);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const std::wstring mutex_name = BuildSingleInstanceMutexName();
  HANDLE single_instance_mutex =
      CreateMutex(nullptr, TRUE, mutex_name.c_str());
  if (single_instance_mutex != nullptr && GetLastError() == ERROR_ALREADY_EXISTS) {
    RestoreExistingWindowIfPresent();
    CloseHandle(single_instance_mutex);
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
  if (!window.Create(L"\u5C0F\u9A6C\u5DE5\u5177\u7BB1", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    ReleaseMutex(single_instance_mutex);
    CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
