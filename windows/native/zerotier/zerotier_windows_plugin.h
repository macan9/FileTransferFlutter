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
#include <string>
#include <vector>

#include "native/zerotier/zerotier_windows_firewall_manager.h"
#include "native/zerotier/zerotier_windows_network_manager.h"
#include "native/zerotier/zerotier_windows_runtime.h"

class ZeroTierWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  ZeroTierWindowsPlugin();
  ~ZeroTierWindowsPlugin() override;

  ZeroTierWindowsPlugin(const ZeroTierWindowsPlugin&) = delete;
  ZeroTierWindowsPlugin& operator=(const ZeroTierWindowsPlugin&) = delete;

 private:
  static constexpr UINT kFlushEventsMessage = WM_APP + 0x4A1;
  static constexpr UINT kFlushMethodResultsMessage = WM_APP + 0x4A2;

  using EventSink = flutter::EventSink<flutter::EncodableValue>;
  using MethodResult = flutter::MethodResult<flutter::EncodableValue>;
  using MethodCall = flutter::MethodCall<flutter::EncodableValue>;
  struct PendingMethodResult {
    std::unique_ptr<MethodResult> result;
    bool success = false;
    std::string error_code;
    std::string error_message;
  };

  void AttachRegistrar(flutter::PluginRegistrarWindows* registrar);
  void HandleMethodCall(const MethodCall& call,
                        std::unique_ptr<MethodResult> result);
  void HandleJoinNetworkCall(const flutter::EncodableMap& args,
                             std::unique_ptr<MethodResult> result);
  void HandleLeaveNetworkCall(const flutter::EncodableMap& args,
                              std::unique_ptr<MethodResult> result);
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

  ZeroTierWindowsRuntime runtime_;
  ZeroTierWindowsNetworkManager network_manager_;
  ZeroTierWindowsFirewallManager firewall_manager_;
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  HWND window_handle_ = nullptr;
  int window_proc_delegate_id_ = 0;
  std::mutex event_mutex_;
  std::deque<flutter::EncodableMap> pending_events_;
  std::unique_ptr<EventSink> event_sink_;
  std::mutex method_result_mutex_;
  std::deque<PendingMethodResult> pending_method_results_;
};

#endif  // FLUTTER_RUNNER_ZEROTIER_WINDOWS_PLUGIN_H_
