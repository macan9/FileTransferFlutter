#include "native/zerotier/zerotier_windows_plugin.h"

#include <flutter/encodable_value.h>

#include <thread>
#include <utility>

constexpr UINT kFlushEventsMessage = WM_APP + 0x4A1;
constexpr UINT kFlushMethodResultsMessage = WM_APP + 0x4A2;

struct ZeroTierWindowsPluginState {
  ZeroTierWindowsPluginState() : network_manager(&runtime) {}

  ZeroTierWindowsRuntime runtime;
  ZeroTierWindowsNetworkManager network_manager;
  ZeroTierWindowsFirewallManager firewall_manager;
  std::mutex event_mutex;
  std::deque<flutter::EncodableMap> pending_events;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink;
  std::mutex method_result_mutex;
  std::deque<PendingMethodResult> pending_method_results;
  HWND window_handle = nullptr;

  void QueueEvent(const flutter::EncodableMap& event) {
    {
      std::scoped_lock lock(event_mutex);
      pending_events.push_back(event);
    }

    if (window_handle != nullptr) {
      PostMessage(window_handle, kFlushEventsMessage, 0, 0);
    }
  }

  void QueueMethodResult(PendingMethodResult pending_result) {
    {
      std::scoped_lock lock(method_result_mutex);
      pending_method_results.push_back(std::move(pending_result));
    }

    if (window_handle != nullptr) {
      PostMessage(window_handle, kFlushMethodResultsMessage, 0, 0);
    }
  }

  void FlushQueuedEvents() {
    if (!event_sink) {
      return;
    }

    std::deque<flutter::EncodableMap> items;
    {
      std::scoped_lock lock(event_mutex);
      items.swap(pending_events);
    }

    for (const auto& event : items) {
      event_sink->Success(flutter::EncodableValue(event));
    }
  }

  void FlushQueuedMethodResults() {
    std::deque<PendingMethodResult> items;
    {
      std::scoped_lock lock(method_result_mutex);
      items.swap(pending_method_results);
    }

    for (auto& pending_result : items) {
      if (pending_result.result == nullptr) {
        continue;
      }
      if (pending_result.success) {
        if (pending_result.value.has_value()) {
          pending_result.result->Success(std::move(*pending_result.value));
        } else {
          pending_result.result->Success();
        }
      } else {
        pending_result.result->Error(pending_result.error_code,
                                     pending_result.error_message);
      }
    }
  }
};

namespace {

constexpr char kMethodChannelName[] =
    "file_transfer_flutter/zerotier/methods";
constexpr char kEventChannelName[] = "file_transfer_flutter/zerotier/events";

std::string ReadStringArgument(const flutter::EncodableMap& arguments,
                               const char* key) {
  const auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end() || !std::holds_alternative<std::string>(it->second)) {
    return "";
  }
  return std::get<std::string>(it->second);
}

int ReadIntArgument(const flutter::EncodableMap& arguments, const char* key) {
  const auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end()) {
    return 0;
  }
  if (std::holds_alternative<int32_t>(it->second)) {
    return std::get<int32_t>(it->second);
  }
  if (std::holds_alternative<int64_t>(it->second)) {
    return static_cast<int>(std::get<int64_t>(it->second));
  }
  return 0;
}

bool ReadBoolArgument(const flutter::EncodableMap& arguments, const char* key,
                      bool fallback = false) {
  const auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end()) {
    return fallback;
  }
  if (std::holds_alternative<bool>(it->second)) {
    return std::get<bool>(it->second);
  }
  if (std::holds_alternative<int32_t>(it->second)) {
    return std::get<int32_t>(it->second) != 0;
  }
  if (std::holds_alternative<int64_t>(it->second)) {
    return std::get<int64_t>(it->second) != 0;
  }
  return fallback;
}

}  // namespace

ZeroTierWindowsPlugin::ZeroTierWindowsPlugin()
    : state_(std::make_shared<ZeroTierWindowsPluginState>()) {
  std::weak_ptr<ZeroTierWindowsPluginState> weak_state = state_;
  state_->runtime.SetEventCallback([weak_state](const flutter::EncodableMap& event) {
    if (auto state = weak_state.lock()) {
      state->QueueEvent(event);
    }
  });
}

ZeroTierWindowsPlugin::~ZeroTierWindowsPlugin() {
  if (state_) {
    state_->runtime.ClearEventCallback();
    state_->window_handle = nullptr;
  }
  if (registrar_ != nullptr && window_proc_delegate_id_ != 0) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_id_);
  }
}

void ZeroTierWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<ZeroTierWindowsPlugin>();
  plugin->AttachRegistrar(registrar);

  auto method_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), kMethodChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), kEventChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  auto* plugin_ptr = plugin.get();
  method_channel->SetMethodCallHandler(
      [plugin_ptr](const MethodCall& call, std::unique_ptr<MethodResult> result) {
        plugin_ptr->HandleMethodCall(call, std::move(result));
      });

  event_channel->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [plugin_ptr](const flutter::EncodableValue* arguments,
                       std::unique_ptr<EventSink>&& events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            return plugin_ptr->OnListen(arguments, std::move(events));
          },
          [plugin_ptr](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            return plugin_ptr->OnCancel(arguments);
          }));

  registrar->AddPlugin(std::move(plugin));
}

void ZeroTierWindowsPlugin::AttachRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar_ = registrar;
  if (registrar_ == nullptr) {
    return;
  }

  if (auto* view = registrar_->GetView(); view != nullptr) {
    window_handle_ = view->GetNativeWindow();
    if (state_) {
      state_->window_handle = window_handle_;
    }
  }

  window_proc_delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
}

void ZeroTierWindowsPlugin::HandleMethodCall(
    const MethodCall& call,
    std::unique_ptr<MethodResult> result) {
  const std::string method_name = call.method_name();
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableMap empty_arguments;
  const flutter::EncodableMap& args =
      arguments == nullptr ? empty_arguments : *arguments;
  if (!state_) {
    result->Error("plugin_unavailable", "ZeroTier plugin state is unavailable.");
    return;
  }

  if (method_name == "detectStatus") {
    HandleRuntimeStatusCall(
        std::move(result),
        [](ZeroTierWindowsRuntime& runtime) { return runtime.DetectStatus(); });
    return;
  }
  if (method_name == "prepareEnvironment") {
    HandleRuntimeStatusCall(std::move(result), [](ZeroTierWindowsRuntime& runtime) {
      return runtime.PrepareEnvironment();
    });
    return;
  }
  if (method_name == "startNode") {
    HandleRuntimeStatusCall(
        std::move(result),
        [](ZeroTierWindowsRuntime& runtime) { return runtime.StartNode(); });
    return;
  }
  if (method_name == "stopNode") {
    HandleRuntimeStatusCall(
        std::move(result),
        [](ZeroTierWindowsRuntime& runtime) { return runtime.StopNode(); });
    return;
  }
  if (method_name == "joinNetworkAndWaitForIp") {
    HandleJoinNetworkCall(args, std::move(result));
    return;
  }
  if (method_name == "leaveNetwork") {
    HandleLeaveNetworkCall(args, std::move(result));
    return;
  }
  if (method_name == "listNetworks") {
    result->Success(flutter::EncodableValue(state_->network_manager.ListNetworks()));
    return;
  }
  if (method_name == "getNetworkDetail") {
    const std::string network_id = ReadStringArgument(args, "networkId");
    const auto network = state_->network_manager.GetNetworkDetail(network_id);
    if (network.has_value()) {
      result->Success(flutter::EncodableValue(*network));
    } else {
      result->Success();
    }
    return;
  }
  if (method_name == "probeNetworkStateNow") {
    const std::string network_id = ReadStringArgument(args, "networkId");
    result->Success(
        flutter::EncodableValue(state_->network_manager.ProbeNetworkStateNow(network_id)));
    return;
  }
  if (method_name == "applyFirewallRules") {
    std::vector<ZeroTierWindowsFirewallPortRule> ports;
    const auto ports_it = args.find(flutter::EncodableValue("allowedInboundPorts"));
    if (ports_it != args.end() &&
        std::holds_alternative<flutter::EncodableList>(ports_it->second)) {
      const auto& values = std::get<flutter::EncodableList>(ports_it->second);
      for (const auto& value : values) {
        if (!std::holds_alternative<flutter::EncodableMap>(value)) {
          continue;
        }
        const auto& item = std::get<flutter::EncodableMap>(value);
        const std::string protocol = ReadStringArgument(item, "protocol");
        const int port = ReadIntArgument(item, "port");
        if (!protocol.empty() && port > 0) {
          ZeroTierWindowsFirewallPortRule rule;
          rule.protocol = protocol;
          rule.port = port;
          ports.push_back(rule);
        }
      }
    }
    std::string error_message;
    if (state_->firewall_manager.ApplyRules(ReadStringArgument(args, "ruleScopeId"),
                                            ReadStringArgument(args, "peerZeroTierIp"),
                                            ports, &error_message)) {
      result->Success();
    } else {
      result->Error("firewall_apply_failed", error_message);
    }
    return;
  }
  if (method_name == "removeFirewallRules") {
    std::string error_message;
    if (state_->firewall_manager.RemoveRules(ReadStringArgument(args, "ruleScopeId"),
                                             &error_message)) {
      result->Success();
    } else {
      result->Error("firewall_remove_failed", error_message);
    }
    return;
  }

  result->NotImplemented();
}

void ZeroTierWindowsPlugin::HandleJoinNetworkCall(
    const flutter::EncodableMap& args,
    std::unique_ptr<MethodResult> result) {
  const std::string network_id = ReadStringArgument(args, "networkId");
  const int timeout_ms = ReadIntArgument(args, "timeoutMs");
  const bool allow_mount_degraded =
      ReadBoolArgument(args, "allowMountDegraded", false);
  std::weak_ptr<ZeroTierWindowsPluginState> weak_state = state_;
  std::thread([weak_state, network_id, timeout_ms, allow_mount_degraded,
               result = std::move(result)]() mutable {
    auto state = weak_state.lock();
    if (!state || result == nullptr) {
      return;
    }
    std::string error_message;
    const bool success = state->network_manager.JoinNetworkAndWaitForIp(
        network_id, timeout_ms, allow_mount_degraded, &error_message);
    if (success) {
      result->Success();
    } else {
      result->Error("join_failed", error_message);
    }
  }).detach();
}

void ZeroTierWindowsPlugin::HandleLeaveNetworkCall(
    const flutter::EncodableMap& args,
    std::unique_ptr<MethodResult> result) {
  const std::string network_id = ReadStringArgument(args, "networkId");
  const std::string source = ReadStringArgument(args, "source");
  std::weak_ptr<ZeroTierWindowsPluginState> weak_state = state_;
  std::thread([weak_state, network_id, source,
               result = std::move(result)]() mutable {
    auto state = weak_state.lock();
    if (!state || result == nullptr) {
      return;
    }
    std::string error_message;
    const bool success =
        state->network_manager.LeaveNetwork(network_id, source, &error_message);
    if (success) {
      result->Success();
    } else {
      result->Error("leave_failed", error_message);
    }
  }).detach();
}

void ZeroTierWindowsPlugin::HandleRuntimeStatusCall(
    std::unique_ptr<MethodResult> result,
    std::function<flutter::EncodableMap(ZeroTierWindowsRuntime&)> work) {
  std::weak_ptr<ZeroTierWindowsPluginState> weak_state = state_;
  std::thread([weak_state, work = std::move(work),
               result = std::move(result)]() mutable {
    auto state = weak_state.lock();
    if (!state || result == nullptr) {
      return;
    }
    flutter::EncodableMap payload = work(state->runtime);
    result->Success(flutter::EncodableValue(payload));
  }).detach();
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
ZeroTierWindowsPlugin::OnListen(const flutter::EncodableValue* /*arguments*/,
                                std::unique_ptr<EventSink>&& events) {
  if (state_) {
    state_->event_sink = std::move(events);
    state_->FlushQueuedEvents();
  }
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
ZeroTierWindowsPlugin::OnCancel(const flutter::EncodableValue* /*arguments*/) {
  if (state_) {
    state_->event_sink.reset();
  }
  return nullptr;
}

void ZeroTierWindowsPlugin::QueueEvent(const flutter::EncodableMap& event) {
  if (state_) {
    state_->QueueEvent(event);
  }
}

void ZeroTierWindowsPlugin::QueueMethodResult(PendingMethodResult pending_result) {
  if (state_) {
    state_->QueueMethodResult(std::move(pending_result));
  }
}

void ZeroTierWindowsPlugin::FlushQueuedEvents() {
  if (state_) {
    state_->FlushQueuedEvents();
  }
}

void ZeroTierWindowsPlugin::FlushQueuedMethodResults() {
  if (state_) {
    state_->FlushQueuedMethodResults();
  }
}

std::optional<LRESULT> ZeroTierWindowsPlugin::HandleWindowProc(
    HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (hwnd == window_handle_ && message == kFlushEventsMessage) {
    FlushQueuedEvents();
  }
  if (hwnd == window_handle_ && message == kFlushMethodResultsMessage) {
    FlushQueuedMethodResults();
  }
  return std::nullopt;
}
