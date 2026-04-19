#include "native/zerotier/zerotier_windows_runtime.h"

#include <ZeroTierSockets.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <iomanip>
#include <optional>
#include <sstream>

namespace {

using EncodableList = flutter::EncodableList;
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;

ZeroTierWindowsRuntime* g_runtime_instance = nullptr;

std::string Iso8601NowUtc() {
  using namespace std::chrono;
  const auto now = system_clock::now();
  const std::time_t current_time = system_clock::to_time_t(now);
  std::tm utc_time{};
  gmtime_s(&utc_time, &current_time);

  std::ostringstream stream;
  stream << std::put_time(&utc_time, "%Y-%m-%dT%H:%M:%SZ");
  return stream.str();
}

std::string NetworkStatusToString(int status) {
  switch (status) {
    case ZTS_NETWORK_STATUS_REQUESTING_CONFIGURATION:
      return "REQUESTING_CONFIGURATION";
    case ZTS_NETWORK_STATUS_OK:
      return "OK";
    case ZTS_NETWORK_STATUS_ACCESS_DENIED:
      return "ACCESS_DENIED";
    case ZTS_NETWORK_STATUS_NOT_FOUND:
      return "NOT_FOUND";
    case ZTS_NETWORK_STATUS_PORT_ERROR:
      return "PORT_ERROR";
    case ZTS_NETWORK_STATUS_CLIENT_TOO_OLD:
      return "CLIENT_TOO_OLD";
    default:
      return "UNKNOWN";
  }
}

std::string ExtractAddress(const zts_sockaddr_storage& address) {
  char buffer[ZTS_IP_MAX_STR_LEN] = {0};
  const zts_sockaddr* sockaddr =
      reinterpret_cast<const zts_sockaddr*>(&address);
  if (sockaddr->sa_family == ZTS_AF_INET) {
    const auto* ipv4 =
        reinterpret_cast<const zts_sockaddr_in*>(&address);
    zts_inet_ntop(ZTS_AF_INET, &(ipv4->sin_addr), buffer, ZTS_INET_ADDRSTRLEN);
    return buffer;
  }
  if (sockaddr->sa_family == ZTS_AF_INET6) {
    const auto* ipv6 =
        reinterpret_cast<const zts_sockaddr_in6*>(&address);
    zts_inet_ntop(ZTS_AF_INET6, &(ipv6->sin6_addr), buffer,
                  ZTS_INET6_ADDRSTRLEN);
    return buffer;
  }
  return "";
}

}  // namespace

ZeroTierWindowsRuntime::ZeroTierWindowsRuntime() {
  g_runtime_instance = this;
}

flutter::EncodableMap ZeroTierWindowsRuntime::DetectStatus() const {
  std::scoped_lock lock(mutex_);
  return BuildStatus();
}

flutter::EncodableMap ZeroTierWindowsRuntime::PrepareEnvironment() {
  std::string error_message;
  if (!EnsurePrepared(&error_message)) {
    EmitError(error_message);
  } else {
    EmitEvent(BuildEvent("environmentReady", "Windows libzt environment ready."));
  }
  std::scoped_lock lock(mutex_);
  return BuildStatus();
}

flutter::EncodableMap ZeroTierWindowsRuntime::StartNode() {
  std::string error_message;
  if (!EnsurePrepared(&error_message)) {
    EmitError(error_message);
    std::scoped_lock lock(mutex_);
    return BuildStatus();
  }

  bool emit_start_event = false;
  {
    std::scoped_lock lock(mutex_);
    if (!node_started_) {
      const int result = zts_node_start();
      if (result != ZTS_ERR_OK) {
        last_error_ = "zts_node_start failed: " + std::to_string(result);
        error_message = last_error_;
      } else {
        node_started_ = true;
        stop_requested_ = false;
        last_error_.clear();
        emit_start_event = true;
      }
    }
  }
  if (!error_message.empty()) {
    EmitError(error_message);
    std::scoped_lock lock(mutex_);
    return BuildStatus();
  }

  if (emit_start_event) {
    EmitEvent(BuildEvent("nodeStarted", "Windows libzt node start requested."));
  }
  std::scoped_lock lock(mutex_);
  return BuildStatus();
}

flutter::EncodableMap ZeroTierWindowsRuntime::StopNode() {
  std::string error_message;
  {
    std::scoped_lock lock(mutex_);
    stop_requested_ = true;
    if (node_started_) {
      const int result = zts_node_stop();
      if (result != ZTS_ERR_OK) {
        last_error_ = "zts_node_stop failed: " + std::to_string(result);
        error_message = last_error_;
      }
    }
    node_started_ = false;
    node_online_ = false;
  }
  state_cv_.notify_all();
  if (!error_message.empty()) {
    EmitError(error_message);
  }
  EmitEvent(BuildEvent("nodeStopped", "Windows libzt node stopped."));
  std::scoped_lock lock(mutex_);
  return BuildStatus();
}

void ZeroTierWindowsRuntime::SetEventCallback(EventCallback callback) {
  std::scoped_lock lock(mutex_);
  event_callback_ = std::move(callback);
}

void ZeroTierWindowsRuntime::ClearEventCallback() {
  std::scoped_lock lock(mutex_);
  event_callback_ = nullptr;
}

bool ZeroTierWindowsRuntime::JoinNetworkAndWaitForIp(uint64_t network_id,
                                                     int timeout_ms,
                                                     std::string* error_message) {
  if (network_id == 0) {
    if (error_message != nullptr) {
      *error_message = "ZeroTier network id is invalid.";
    }
    EmitError(*error_message);
    return false;
  }

  if (!EnsurePrepared(error_message)) {
    return false;
  }
  if (!EnsureNodeReady(error_message)) {
    EmitError(error_message == nullptr ? "ZeroTier node is not ready."
                                       : *error_message,
              ToHexNetworkId(network_id));
    return false;
  }

  {
    std::scoped_lock lock(mutex_);
    auto existing = networks_.find(network_id);
    if (existing != networks_.end() &&
        !existing->second.assigned_addresses.empty()) {
      return true;
    }
    networks_[network_id].network_id = network_id;
    networks_[network_id].status = "REQUESTING_CONFIGURATION";
  }

  const int result = zts_net_join(network_id);
  if (result != ZTS_ERR_OK) {
    if (error_message != nullptr) {
      *error_message = "zts_net_join failed: " + std::to_string(result);
    }
    EmitError(*error_message, ToHexNetworkId(network_id));
    return false;
  }

  EmitEvent(BuildEvent("networkJoining", "Joining ZeroTier network.",
                       ToHexNetworkId(network_id)));
  return true;
}

bool ZeroTierWindowsRuntime::LeaveNetwork(uint64_t network_id,
                                          std::string* error_message) {
  const int result = zts_net_leave(network_id);
  if (result != ZTS_ERR_OK) {
    if (error_message != nullptr) {
      *error_message = "zts_net_leave failed: " + std::to_string(result);
    }
    EmitError(*error_message, ToHexNetworkId(network_id));
    return false;
  }

  {
    std::scoped_lock lock(mutex_);
    networks_.erase(network_id);
  }
  state_cv_.notify_all();
  EmitEvent(BuildEvent("networkLeft", "Left ZeroTier network.",
                       ToHexNetworkId(network_id)));
  return true;
}

flutter::EncodableList ZeroTierWindowsRuntime::ListNetworks() const {
  std::scoped_lock lock(mutex_);
  flutter::EncodableList networks;
  for (const auto& [_, network] : networks_) {
    networks.emplace_back(BuildNetworkMap(network));
  }
  return networks;
}

std::optional<flutter::EncodableMap> ZeroTierWindowsRuntime::GetNetworkDetail(
    uint64_t network_id) const {
  std::scoped_lock lock(mutex_);
  const auto it = networks_.find(network_id);
  if (it == networks_.end()) {
    return std::nullopt;
  }
  return BuildNetworkMap(it->second);
}

void ZeroTierWindowsRuntime::HandleLibztEvent(void* message_ptr) {
  if (g_runtime_instance != nullptr) {
    g_runtime_instance->ProcessEvent(message_ptr);
  }
}

flutter::EncodableMap ZeroTierWindowsRuntime::BuildStatus() const {
  EncodableList joined_networks;
  for (const auto& [_, network] : networks_) {
    joined_networks.emplace_back(BuildNetworkMap(network));
  }

  EncodableMap permission_state{
      {EncodableValue("isGranted"), EncodableValue(true)},
      {EncodableValue("requiresManualSetup"), EncodableValue(false)},
      {EncodableValue("isFirewallSupported"), EncodableValue(true)},
      {EncodableValue("summary"),
       EncodableValue("Windows libzt runtime is active.")},
  };

  std::ostringstream version_stream;
  version_stream << "libzt/" << major_version_ << "." << minor_version_;

  return EncodableMap{
      {EncodableValue("nodeId"),
       EncodableValue(node_id_ == 0 ? "" : ToHexNetworkId(node_id_))},
      {EncodableValue("version"), EncodableValue(version_stream.str())},
      {EncodableValue("serviceState"),
       EncodableValue(environment_prepared_
                          ? (node_online_ ? "running"
                                          : (node_started_ ? "starting"
                                                           : "prepared"))
                          : "unavailable")},
      {EncodableValue("permissionState"), EncodableValue(permission_state)},
      {EncodableValue("isNodeRunning"),
       EncodableValue(node_started_ || node_online_)},
      {EncodableValue("joinedNetworks"), EncodableValue(joined_networks)},
      {EncodableValue("lastError"),
       last_error_.empty() ? EncodableValue() : EncodableValue(last_error_)},
      {EncodableValue("updatedAt"), EncodableValue(Iso8601NowUtc())},
  };
}

flutter::EncodableMap ZeroTierWindowsRuntime::BuildEvent(
    const std::string& type, const std::string& message,
    const std::string& network_id, const flutter::EncodableMap& payload) const {
  EncodableMap event{
      {EncodableValue("type"), EncodableValue(type)},
      {EncodableValue("occurredAt"), EncodableValue(Iso8601NowUtc())},
      {EncodableValue("payload"), EncodableValue(payload)},
  };
  if (!message.empty()) {
    event[EncodableValue("message")] = EncodableValue(message);
  }
  if (!network_id.empty()) {
    event[EncodableValue("networkId")] = EncodableValue(network_id);
  }
  return event;
}

flutter::EncodableMap ZeroTierWindowsRuntime::BuildNetworkMap(
    const ZeroTierWindowsNetworkRecord& network) const {
  EncodableList assigned_addresses;
  for (const auto& address : network.assigned_addresses) {
    assigned_addresses.emplace_back(address);
  }
  return EncodableMap{
      {EncodableValue("networkId"), EncodableValue(ToHexNetworkId(network.network_id))},
      {EncodableValue("networkName"), EncodableValue(network.network_name)},
      {EncodableValue("status"), EncodableValue(network.status)},
      {EncodableValue("assignedAddresses"), EncodableValue(assigned_addresses)},
      {EncodableValue("isAuthorized"), EncodableValue(network.is_authorized)},
      {EncodableValue("isConnected"), EncodableValue(network.is_connected)},
  };
}

bool ZeroTierWindowsRuntime::EnsurePrepared(std::string* error_message) {
  std::scoped_lock lock(mutex_);
  if (environment_prepared_) {
    return true;
  }

  try {
    std::filesystem::create_directories(RuntimeRootPath());
    std::filesystem::create_directories(NodeStoragePath());
    std::filesystem::create_directories(LogsPath());
  } catch (const std::exception& error) {
    last_error_ = error.what();
    if (error_message != nullptr) {
      *error_message = last_error_;
    }
    return false;
  }

  storage_path_ = NodeStoragePath();
  logs_path_ = LogsPath();

  const int storage_result = zts_init_from_storage(storage_path_.c_str());
  if (storage_result != ZTS_ERR_OK) {
    last_error_ = "zts_init_from_storage failed: " + std::to_string(storage_result);
    if (error_message != nullptr) {
      *error_message = last_error_;
    }
    return false;
  }

  const int callback_result = zts_init_set_event_handler(&HandleLibztEvent);
  if (callback_result != ZTS_ERR_OK) {
    last_error_ =
        "zts_init_set_event_handler failed: " + std::to_string(callback_result);
    if (error_message != nullptr) {
      *error_message = last_error_;
    }
    return false;
  }

  environment_prepared_ = true;
  handler_registered_ = true;
  last_error_.clear();
  return true;
}

bool ZeroTierWindowsRuntime::EnsureNodeReady(std::string* error_message) {
  bool should_start = false;
  {
    std::scoped_lock lock(mutex_);
    should_start = !node_started_;
  }

  if (should_start) {
    StartNode();
  }

  std::unique_lock lock(mutex_);
  const bool ready = state_cv_.wait_for(lock, std::chrono::seconds(20), [this]() {
    return node_online_ || node_id_ != 0 || !last_error_.empty();
  });

  if (!ready || (!node_online_ && node_id_ == 0)) {
    if (error_message != nullptr) {
      *error_message = last_error_.empty()
                           ? "ZeroTier node is not ready for network join yet."
                           : last_error_;
    }
    return false;
  }

  return true;
}

void ZeroTierWindowsRuntime::ProcessEvent(void* message_ptr) {
  if (message_ptr == nullptr) {
    return;
  }

  auto* event = reinterpret_cast<zts_event_msg_t*>(message_ptr);
  {
    std::scoped_lock lock(mutex_);
    if (event->node != nullptr) {
      node_id_ = event->node->node_id;
      node_port_ = event->node->port_primary;
      major_version_ = event->node->ver_major;
      minor_version_ = event->node->ver_minor;
    } else if (node_started_) {
      node_id_ = zts_node_get_id();
      node_port_ = zts_node_get_port();
    }
  }

  if (event->network != nullptr) {
    UpdateNetworkFromLibztMessage(message_ptr);
  }
  if (event->addr != nullptr) {
    UpdateAddressFromLibztMessage(message_ptr);
  }

  switch (event->event_code) {
    case ZTS_EVENT_NODE_ONLINE: {
      {
        std::scoped_lock lock(mutex_);
        node_online_ = true;
      }
      EmitEvent(BuildEvent("nodeStarted", "ZeroTier node is online."));
      break;
    }
    case ZTS_EVENT_NODE_OFFLINE: {
      {
        std::scoped_lock lock(mutex_);
        node_online_ = false;
      }
      EmitError("ZeroTier node is offline.");
      break;
    }
    case ZTS_EVENT_NODE_DOWN: {
      {
        std::scoped_lock lock(mutex_);
        node_started_ = false;
        node_online_ = false;
      }
      EmitEvent(BuildEvent("nodeStopped", "ZeroTier node is down."));
      break;
    }
    case ZTS_EVENT_NETWORK_REQ_CONFIG: {
      EmitEvent(BuildEvent("networkJoining", "Waiting for network configuration.",
                           event->network == nullptr ? "" : ToHexNetworkId(event->network->net_id)));
      break;
    }
    case ZTS_EVENT_NETWORK_ACCESS_DENIED: {
      EmitEvent(BuildEvent("networkWaitingAuthorization",
                           "ZeroTier network requires authorization.",
                           event->network == nullptr ? "" : ToHexNetworkId(event->network->net_id)));
      break;
    }
    case ZTS_EVENT_NETWORK_READY_IP4:
    case ZTS_EVENT_NETWORK_READY_IP6:
    case ZTS_EVENT_NETWORK_READY_IP4_IP6:
    case ZTS_EVENT_NETWORK_OK: {
      EmitEvent(BuildEvent("networkOnline", "ZeroTier network is online.",
                           event->network == nullptr ? "" : ToHexNetworkId(event->network->net_id)));
      break;
    }
    case ZTS_EVENT_ADDR_ADDED_IP4:
    case ZTS_EVENT_ADDR_ADDED_IP6: {
      std::string network_id =
          event->addr == nullptr ? "" : ToHexNetworkId(event->addr->net_id);
      EmitEvent(BuildEvent("ipAssigned", "Managed address assigned.", network_id));
      break;
    }
    case ZTS_EVENT_NETWORK_NOT_FOUND:
    case ZTS_EVENT_NETWORK_CLIENT_TOO_OLD:
    case ZTS_EVENT_NETWORK_DOWN:
    case ZTS_EVENT_NODE_FATAL_ERROR: {
      EmitError("ZeroTier runtime reported an error.",
                event->network == nullptr ? "" : ToHexNetworkId(event->network->net_id));
      break;
    }
    default:
      break;
  }

  state_cv_.notify_all();
}

void ZeroTierWindowsRuntime::UpdateNetworkFromLibztMessage(
    const void* message_ptr) {
  const auto* event = reinterpret_cast<const zts_event_msg_t*>(message_ptr);
  if (event == nullptr || event->network == nullptr) {
    return;
  }

  std::scoped_lock lock(mutex_);
  const zts_net_info_t* network = event->network;
  auto& record = networks_[network->net_id];
  record.network_id = network->net_id;
  record.network_name = network->name == nullptr ? "" : network->name;
  record.status = NetworkStatusToString(network->status);
  record.is_authorized =
      network->status == ZTS_NETWORK_STATUS_OK ||
      network->type == ZTS_NETWORK_TYPE_PUBLIC;
  record.is_connected = zts_net_transport_is_ready(network->net_id) == ZTS_ERR_OK ||
                        network->assigned_addr_count > 0;
  record.assigned_addresses.clear();
  for (unsigned int i = 0; i < network->assigned_addr_count; ++i) {
    const std::string address = ExtractAddress(network->assigned_addrs[i]);
    if (!address.empty()) {
      record.assigned_addresses.push_back(address);
    }
  }
}

void ZeroTierWindowsRuntime::UpdateAddressFromLibztMessage(
    const void* message_ptr) {
  const auto* event = reinterpret_cast<const zts_event_msg_t*>(message_ptr);
  if (event == nullptr || event->addr == nullptr) {
    return;
  }

  std::scoped_lock lock(mutex_);
  auto& record = networks_[event->addr->net_id];
  record.network_id = event->addr->net_id;
  const std::string address = ExtractAddress(event->addr->addr);
  if (!address.empty() &&
      std::find(record.assigned_addresses.begin(), record.assigned_addresses.end(),
                address) == record.assigned_addresses.end()) {
    record.assigned_addresses.push_back(address);
  }
  record.is_connected = !record.assigned_addresses.empty();
}

void ZeroTierWindowsRuntime::EmitEvent(const flutter::EncodableMap& event) const {
  EventCallback callback;
  {
    std::scoped_lock lock(mutex_);
    callback = event_callback_;
  }
  if (callback) {
    callback(event);
  }
}

void ZeroTierWindowsRuntime::EmitError(const std::string& message,
                                       const std::string& network_id) const {
  EmitEvent(BuildEvent("error", message, network_id));
}

std::string ZeroTierWindowsRuntime::RuntimeRootPath() const {
  char* local_app_data = nullptr;
  size_t env_size = 0;
  const errno_t env_result =
      _dupenv_s(&local_app_data, &env_size, "LOCALAPPDATA");
  const std::string root =
      env_result != 0 || local_app_data == nullptr ? "." : std::string(local_app_data);
  if (local_app_data != nullptr) {
    free(local_app_data);
  }
  return root + "\\FileTransferFlutter\\zerotier";
}

std::string ZeroTierWindowsRuntime::NodeStoragePath() const {
  return RuntimeRootPath() + "\\node";
}

std::string ZeroTierWindowsRuntime::LogsPath() const {
  return RuntimeRootPath() + "\\logs";
}

std::string ZeroTierWindowsRuntime::ToHexNetworkId(uint64_t network_id) const {
  std::ostringstream stream;
  stream << std::hex << std::nouppercase << network_id;
  return stream.str();
}
