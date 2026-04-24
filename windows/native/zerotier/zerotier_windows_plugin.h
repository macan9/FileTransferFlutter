#ifndef FLUTTER_RUNNER_ZEROTIER_WINDOWS_PLUGIN_H_
#define FLUTTER_RUNNER_ZEROTIER_WINDOWS_PLUGIN_H_

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/plugin_registrar.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <deque>
#include <functional>
#include <mutex>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "native/zerotier/zerotier_windows_firewall_manager.h"
#include "native/zerotier/zerotier_windows_network_manager.h"
#include "native/zerotier/zerotier_windows_runtime.h"

struct PendingMethodResult {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  bool success = false;
  std::string error_code;
  std::string error_message;
  std::optional<flutter::EncodableValue> value;
};

struct ZeroTierWindowsPluginState;

class ZeroTierWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  ZeroTierWindowsPlugin();
  ~ZeroTierWindowsPlugin() override;

  ZeroTierWindowsPlugin(const ZeroTierWindowsPlugin&) = delete;
  ZeroTierWindowsPlugin& operator=(const ZeroTierWindowsPlugin&) = delete;

 private:
  using EventSink = flutter::EventSink<flutter::EncodableValue>;
  using MethodResult = flutter::MethodResult<flutter::EncodableValue>;
  using MethodCall = flutter::MethodCall<flutter::EncodableValue>;

  void AttachRegistrar(flutter::PluginRegistrarWindows* registrar);
  void HandleMethodCall(const MethodCall& call,
                        std::unique_ptr<MethodResult> result);
  void HandleJoinNetworkCall(const flutter::EncodableMap& args,
                             std::unique_ptr<MethodResult> result);
  void HandleLeaveNetworkCall(const flutter::EncodableMap& args,
                              std::unique_ptr<MethodResult> result);
  void HandleRuntimeStatusCall(
      std::unique_ptr<MethodResult> result,
      std::function<flutter::EncodableMap(ZeroTierWindowsRuntime&)> work);
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnListen(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<EventSink>&& events);
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> OnCancel(
      const flutter::EncodableValue* arguments);
  void QueueEvent(const flutter::EncodableMap& event);
  void FlushQueuedEvents();
  void QueueMethodResult(PendingMethodResult pending_result);
  void FlushQueuedMethodResults();
  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                          LPARAM lparam);

  std::shared_ptr<ZeroTierWindowsPluginState> state_;
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  HWND window_handle_ = nullptr;
  int window_proc_delegate_id_ = 0;
};

#endif  // FLUTTER_RUNNER_ZEROTIER_WINDOWS_PLUGIN_H_
