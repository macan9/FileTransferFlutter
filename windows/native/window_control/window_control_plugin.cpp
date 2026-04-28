#include "native/window_control/window_control_plugin.h"

namespace {

constexpr char kChannelName[] = "file_transfer_flutter/window_control";

}  // namespace

void WindowControlPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<WindowControlPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

WindowControlPlugin::WindowControlPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

void WindowControlPlugin::HandleMethodCall(
    const MethodCall& call,
    std::unique_ptr<MethodResult> result) {
  if (call.method_name() == "restore") {
    RestoreMainWindow();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (call.method_name() == "minimize") {
    MinimizeMainWindow();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  result->NotImplemented();
}

HWND WindowControlPlugin::GetMainWindow() const {
  return ::GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
}

void WindowControlPlugin::RestoreMainWindow() {
  HWND window = GetMainWindow();
  if (window == nullptr) {
    return;
  }

  WINDOWPLACEMENT placement;
  placement.length = sizeof(WINDOWPLACEMENT);
  if (::GetWindowPlacement(window, &placement)) {
    const RECT& normal_position = placement.rcNormalPosition;
    if (normal_position.left < -10000 || normal_position.top < -10000) {
      ::SetWindowPos(window, nullptr, 100, 100, 680, 780,
                     SWP_NOZORDER | SWP_NOACTIVATE);
    }
  }

  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else {
    ::ShowWindow(window, SW_SHOWNORMAL);
  }

  ::SetForegroundWindow(window);
  ::SetActiveWindow(window);
  ::BringWindowToTop(window);
  ::UpdateWindow(window);
}

void WindowControlPlugin::MinimizeMainWindow() {
  HWND window = GetMainWindow();
  if (window == nullptr) {
    return;
  }

  ::ShowWindow(window, SW_MINIMIZE);
}
