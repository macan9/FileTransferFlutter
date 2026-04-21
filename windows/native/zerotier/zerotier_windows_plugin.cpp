#include "native/zerotier/zerotier_windows_plugin.h"

#include <flutter/encodable_value.h>

#include <thread>
#include <utility>

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

}  // namespace

ZeroTierWindowsPlugin::ZeroTierWindowsPlugin() : network_manager_(&runtime_) {
  runtime_.SetEventCallback([this](const flutter::EncodableMap& event) {
    QueueEvent(event);
  });
}

ZeroTierWindowsPlugin::~ZeroTierWindowsPlugin() {
  runtime_.ClearEventCallback();
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

  if (method_name == "detectStatus") {
    result->Success(flutter::EncodableValue(runtime_.DetectStatus()));
    return;
  }
  if (method_name == "prepareEnvironment") {
    result->Success(flutter::EncodableValue(runtime_.PrepareEnvironment()));
    return;
  }
  if (method_name == "startNode") {
    result->Success(flutter::EncodableValue(runtime_.StartNode()));
    return;
  }
  if (method_name == "stopNode") {
    result->Success(flutter::EncodableValue(runtime_.StopNode()));
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
    result->Success(flutter::EncodableValue(network_manager_.ListNetworks()));
    return;
  }
  if (method_name == "getNetworkDetail") {
    const std::string network_id = ReadStringArgument(args, "networkId");
    const auto network = network_manager_.GetNetworkDetail(network_id);
    if (network.has_value()) {
      result->Success(flutter::EncodableValue(*network));
    } else {
      result->Success();
    }
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
    if (firewall_manager_.ApplyRules(ReadStringArgument(args, "ruleScopeId"),
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
    if (firewall_manager_.RemoveRules(ReadStringArgument(args, "ruleScopeId"),
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
  auto* plugin = this;
  std::thread([plugin, network_id, timeout_ms,
               result = std::move(result)]() mutable {
    std::string error_message;
    const bool success = plugin->network_manager_.JoinNetworkAndWaitForIp(
        network_id, timeout_ms, &error_message);
    plugin->QueueMethodResult(PendingMethodResult{
        std::move(result),
        success,
        "join_failed",
        error_message,
    });
  }).detach();
}

void ZeroTierWindowsPlugin::HandleLeaveNetworkCall(
    const flutter::EncodableMap& args,
    std::unique_ptr<MethodResult> result) {
  const std::string network_id = ReadStringArgument(args, "networkId");
  const std::string source = ReadStringArgument(args, "source");
  auto* plugin = this;
  std::thread([plugin, network_id, source, result = std::move(result)]() mutable {
    std::string error_message;
    const bool success =
        plugin->network_manager_.LeaveNetwork(network_id, source, &error_message);
    plugin->QueueMethodResult(PendingMethodResult{
        std::move(result),
        success,
        "leave_failed",
        error_message,
    });
  }).detach();
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
ZeroTierWindowsPlugin::OnListen(const flutter::EncodableValue* /*arguments*/,
                                std::unique_ptr<EventSink>&& events) {
  event_sink_ = std::move(events);
  FlushQueuedEvents();
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
ZeroTierWindowsPlugin::OnCancel(const flutter::EncodableValue* /*arguments*/) {
  event_sink_.reset();
  return nullptr;
}

void ZeroTierWindowsPlugin::QueueEvent(const flutter::EncodableMap& event) {
  {
    std::scoped_lock lock(event_mutex_);
    pending_events_.push_back(event);
  }

  if (window_handle_ != nullptr) {
    PostMessage(window_handle_, kFlushEventsMessage, 0, 0);
  }
}

void ZeroTierWindowsPlugin::QueueMethodResult(PendingMethodResult pending_result) {
  {
    std::scoped_lock lock(method_result_mutex_);
    pending_method_results_.push_back(std::move(pending_result));
  }

  if (window_handle_ != nullptr) {
    PostMessage(window_handle_, kFlushMethodResultsMessage, 0, 0);
  }
}

void ZeroTierWindowsPlugin::FlushQueuedEvents() {
  if (!event_sink_) {
    return;
  }

  std::deque<flutter::EncodableMap> pending_events;
  {
    std::scoped_lock lock(event_mutex_);
    pending_events.swap(pending_events_);
  }

  for (const auto& event : pending_events) {
    event_sink_->Success(flutter::EncodableValue(event));
  }
}

void ZeroTierWindowsPlugin::FlushQueuedMethodResults() {
  std::deque<PendingMethodResult> pending_method_results;
  {
    std::scoped_lock lock(method_result_mutex_);
    pending_method_results.swap(pending_method_results_);
  }

  for (auto& pending_result : pending_method_results) {
    if (pending_result.result == nullptr) {
      continue;
    }
    if (pending_result.success) {
      pending_result.result->Success();
    } else {
      pending_result.result->Error(pending_result.error_code,
                                   pending_result.error_message);
    }
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
