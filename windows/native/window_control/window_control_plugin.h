#ifndef FLUTTER_RUNNER_WINDOW_CONTROL_PLUGIN_H_
#define FLUTTER_RUNNER_WINDOW_CONTROL_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>

class WindowControlPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit WindowControlPlugin(flutter::PluginRegistrarWindows* registrar);
  ~WindowControlPlugin() override = default;

  WindowControlPlugin(const WindowControlPlugin&) = delete;
  WindowControlPlugin& operator=(const WindowControlPlugin&) = delete;

 private:
  using MethodCall = flutter::MethodCall<flutter::EncodableValue>;
  using MethodResult = flutter::MethodResult<flutter::EncodableValue>;

  void HandleMethodCall(const MethodCall& call,
                        std::unique_ptr<MethodResult> result);
  HWND GetMainWindow() const;
  void RestoreMainWindow();
  void MinimizeMainWindow();
  void HideMainWindow();

  flutter::PluginRegistrarWindows* registrar_ = nullptr;
};

#endif  // FLUTTER_RUNNER_WINDOW_CONTROL_PLUGIN_H_
