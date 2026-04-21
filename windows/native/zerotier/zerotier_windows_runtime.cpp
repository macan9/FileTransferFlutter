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

bool ShouldSuppressNetworkDownError(
    const zts_event_msg_t* event,
    const std::set<uint64_t>& leaving_networks) {
  if (event == nullptr || event->network == nullptr) {
    return false;
  }
  return leaving_networks.find(event->network->net_id) != leaving_networks.end();
}

bool IsTerminalNetworkFailureStatus(const std::string& status) {
  return status == "NOT_FOUND" || status == "PORT_ERROR" ||
         status == "CLIENT_TOO_OLD";
}

std::string ComposeJoinFailureMessage(const ZeroTierWindowsNetworkRecord& network) {
  if (network.status == "ACCESS_DENIED") {
    return "ZeroTier network authorization is still pending.";
  }
  if (network.status == "NOT_FOUND") {
    return "ZeroTier network was not found.";
  }
  if (network.status == "PORT_ERROR") {
    return "ZeroTier reported a port error while joining the network.";
  }
  if (network.status == "CLIENT_TOO_OLD") {
    return "ZeroTier client is too old for this network.";
  }
  return "ZeroTier network failed with status " + network.status + ".";
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
    {
      std::scoped_lock lock(mutex_);
      ClearLastErrorLocked();
    }
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
    if (node_online_) {
      ClearLastErrorLocked();
    } else if (!node_started_) {
      const int result = zts_node_start();
      if (result != ZTS_ERR_OK) {
        SetLastErrorLocked("zts_node_start failed: " + std::to_string(result));
        error_message = last_error_;
      } else {
        node_started_ = true;
        node_offline_ = false;
        stop_requested_ = false;
        ClearLastErrorLocked();
        emit_start_event = true;
      }
    } else {
      ClearLastErrorLocked();
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
    leaving_networks_.clear();
    leave_request_sources_.clear();
    pending_leave_generations_.clear();
    network_generations_.clear();
    networks_.clear();
    if (node_started_) {
      const int result = zts_node_stop();
      if (result != ZTS_ERR_OK) {
        SetLastErrorLocked("zts_node_stop failed: " + std::to_string(result));
        error_message = last_error_;
      }
    }
    node_started_ = false;
    node_online_ = false;
    node_offline_ = false;
    if (error_message.empty()) {
      ClearLastErrorLocked();
    }
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

  uint64_t join_generation = 0;
  bool emit_existing_network_online = false;
  flutter::EncodableMap existing_network_payload;
  {
    std::scoped_lock lock(mutex_);
    leaving_networks_.erase(network_id);
    leave_request_sources_.erase(network_id);
    pending_leave_generations_.erase(network_id);
    ClearLastErrorLocked();
    auto existing = networks_.find(network_id);
    if (existing != networks_.end() &&
        (existing->second.is_connected ||
         !existing->second.assigned_addresses.empty())) {
      join_generation = NextNetworkGenerationLocked(network_id);
      emit_existing_network_online = true;
      existing_network_payload = BuildNetworkDiagnosticsPayloadLocked(
          network_id, 0, "alreadyConnected");
    } else {
      join_generation = NextNetworkGenerationLocked(network_id);
      networks_[network_id].network_id = network_id;
      networks_[network_id].status = "REQUESTING_CONFIGURATION";
      networks_[network_id].is_connected = false;
      networks_[network_id].is_authorized = false;
      networks_[network_id].assigned_addresses.clear();
    }
  }

  if (emit_existing_network_online) {
    EmitEvent(BuildEvent("networkOnline",
                         "ZeroTier network is already online.",
                         ToHexNetworkId(network_id), existing_network_payload));
    if (error_message != nullptr) {
      error_message->clear();
    }
    return true;
  }

  const int result = zts_net_join(network_id);
  if (result != ZTS_ERR_OK) {
    if (error_message != nullptr) {
      *error_message = "zts_net_join failed: " + std::to_string(result);
    }
    EmitError(*error_message, ToHexNetworkId(network_id));
    return false;
  }

  EmitEvent(BuildEvent(
      "networkJoining", "Joining ZeroTier network.", ToHexNetworkId(network_id),
      EncodableMap{
          {EncodableValue("generation"),
           EncodableValue(static_cast<int64_t>(join_generation))},
          {EncodableValue("trigger"), EncodableValue("joinRequested")},
      }));

  const auto timeout = std::chrono::milliseconds(
      timeout_ms > 0 ? timeout_ms : 30000);
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  std::unique_lock lock(mutex_);
  while (std::chrono::steady_clock::now() < deadline) {
    const auto remaining = deadline - std::chrono::steady_clock::now();
    state_cv_.wait_for(lock, remaining, [this, network_id]() {
      const auto network_it = networks_.find(network_id);
      if (network_it == networks_.end()) {
        return !last_error_.empty() || !node_started_;
      }

      const ZeroTierWindowsNetworkRecord& network = network_it->second;
      if (network.is_connected || !network.assigned_addresses.empty()) {
        return true;
      }
      if (network.status == "ACCESS_DENIED" ||
          IsTerminalNetworkFailureStatus(network.status)) {
        return true;
      }
      return !last_error_.empty() || !node_started_;
    });

    const auto network_it = networks_.find(network_id);
    if (network_it != networks_.end()) {
      const ZeroTierWindowsNetworkRecord& network = network_it->second;
      if (network.is_connected || !network.assigned_addresses.empty()) {
        ClearLastErrorLocked();
        if (error_message != nullptr) {
          error_message->clear();
        }
        return true;
      }
      if (network.status == "ACCESS_DENIED" ||
          IsTerminalNetworkFailureStatus(network.status)) {
        const std::string message = ComposeJoinFailureMessage(network);
        SetLastErrorLocked(message);
        if (error_message != nullptr) {
          *error_message = message;
        }
        lock.unlock();
        EmitError(message, ToHexNetworkId(network_id));
        return false;
      }
    }

    if (!last_error_.empty()) {
      if (error_message != nullptr) {
        *error_message = last_error_;
      }
      lock.unlock();
      EmitError(last_error_, ToHexNetworkId(network_id));
      return false;
    }

    if (!node_started_) {
      const std::string message = "ZeroTier node stopped before the network became ready.";
      SetLastErrorLocked(message);
      if (error_message != nullptr) {
        *error_message = message;
      }
      lock.unlock();
      EmitError(message, ToHexNetworkId(network_id));
      return false;
    }
  }

  std::string message = "Timed out waiting for a managed address from ZeroTier.";
  if (!node_started_) {
    message = "ZeroTier node stopped before the network became ready.";
  } else if (!node_online_) {
    message =
        "ZeroTier node stayed offline while waiting for the network to become ready.";
  }
  SetLastErrorLocked(message);
  if (error_message != nullptr) {
    *error_message = message;
  }
  lock.unlock();
  EmitError(message, ToHexNetworkId(network_id));
  return false;
}

bool ZeroTierWindowsRuntime::LeaveNetwork(uint64_t network_id,
                                          const std::string& source,
                                          std::string* error_message) {
  uint64_t leave_generation = 0;
  {
    std::scoped_lock lock(mutex_);
    auto existing = networks_.find(network_id);
    if (existing == networks_.end()) {
      leave_request_sources_.erase(network_id);
      pending_leave_generations_.erase(network_id);
      ClearLastErrorLocked();
      if (error_message != nullptr) {
        error_message->clear();
      }
      return true;
    }
    leaving_networks_.insert(network_id);
    leave_request_sources_[network_id] =
        source.empty() ? "unknown" : source;
    leave_generation = NextNetworkGenerationLocked(network_id);
    pending_leave_generations_[network_id] = leave_generation;
    ClearLastErrorLocked();
  }

  const std::string network_id_hex = ToHexNetworkId(network_id);

  const int result = zts_net_leave(network_id);
  if (result != ZTS_ERR_OK) {
    {
      std::scoped_lock lock(mutex_);
      leaving_networks_.erase(network_id);
      leave_request_sources_.erase(network_id);
      pending_leave_generations_.erase(network_id);
    }
    if (error_message != nullptr) {
      *error_message = "zts_net_leave failed: " + std::to_string(result);
    }
    EmitError(*error_message, network_id_hex);
    return false;
  }

  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(15);
  std::unique_lock lock(mutex_);
  while (std::chrono::steady_clock::now() < deadline) {
    const auto remaining = deadline - std::chrono::steady_clock::now();
    state_cv_.wait_for(lock, remaining, [this, network_id]() {
      return networks_.find(network_id) == networks_.end() || !last_error_.empty();
    });

    if (networks_.find(network_id) == networks_.end()) {
      leaving_networks_.erase(network_id);
      leave_request_sources_.erase(network_id);
      pending_leave_generations_.erase(network_id);
      ClearLastErrorLocked();
      if (error_message != nullptr) {
        error_message->clear();
      }
      return true;
    }

    if (!last_error_.empty()) {
      if (error_message != nullptr) {
        *error_message = last_error_;
      }
      leaving_networks_.erase(network_id);
      leave_request_sources_.erase(network_id);
      pending_leave_generations_.erase(network_id);
      lock.unlock();
      EmitError(last_error_, network_id_hex);
      return false;
    }
  }

  const std::string message =
      "Timed out waiting for ZeroTier to leave the network.";
  SetLastErrorLocked(message);
  if (error_message != nullptr) {
    *error_message = message;
  }
  leaving_networks_.erase(network_id);
  leave_request_sources_.erase(network_id);
  pending_leave_generations_.erase(network_id);
  lock.unlock();
  EmitError(message, network_id_hex);
  return false;
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
      {EncodableValue("serviceState"), EncodableValue(BuildServiceState())},
      {EncodableValue("permissionState"), EncodableValue(permission_state)},
      {EncodableValue("isNodeRunning"),
       EncodableValue(node_started_ || node_online_)},
      {EncodableValue("joinedNetworks"), EncodableValue(joined_networks)},
      {EncodableValue("lastError"),
       last_error_.empty() ? EncodableValue() : EncodableValue(last_error_)},
      {EncodableValue("updatedAt"), EncodableValue(Iso8601NowUtc())},
  };
}

std::string ZeroTierWindowsRuntime::BuildServiceState() const {
  if (!environment_prepared_) {
    return "unavailable";
  }
  if (!last_error_.empty() && !node_online_) {
    return "error";
  }
  if (node_online_) {
    return "running";
  }
  if (node_started_ && node_offline_) {
    return "offline";
  }
  if (node_started_) {
    return "starting";
  }
  return "prepared";
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

flutter::EncodableMap ZeroTierWindowsRuntime::BuildNodeDiagnosticsPayloadLocked(
    int event_code) const {
  return flutter::EncodableMap{
      {EncodableValue("eventCode"), EncodableValue(event_code)},
      {EncodableValue("serviceState"), EncodableValue(BuildServiceState())},
      {EncodableValue("nodeStarted"), EncodableValue(node_started_)},
      {EncodableValue("nodeOnline"), EncodableValue(node_online_)},
      {EncodableValue("nodeOffline"), EncodableValue(node_offline_)},
      {EncodableValue("nodeId"),
       EncodableValue(node_id_ == 0 ? "" : ToHexNetworkId(node_id_))},
      {EncodableValue("nodePort"), EncodableValue(node_port_)},
  };
}

flutter::EncodableMap
ZeroTierWindowsRuntime::BuildNetworkDiagnosticsPayloadLocked(
    uint64_t network_id, int event_code, const std::string& trigger) const {
  EncodableList known_networks;
  for (const auto& [id, network] : networks_) {
    known_networks.emplace_back(EncodableMap{
        {EncodableValue("networkId"), EncodableValue(ToHexNetworkId(id))},
        {EncodableValue("status"), EncodableValue(network.status)},
        {EncodableValue("isConnected"), EncodableValue(network.is_connected)},
        {EncodableValue("addressCount"),
         EncodableValue(static_cast<int>(network.assigned_addresses.size()))},
    });
  }

  const auto leave_source_it = leave_request_sources_.find(network_id);
  const auto generation_it = network_generations_.find(network_id);
  const auto pending_leave_generation_it =
      pending_leave_generations_.find(network_id);
  const auto network_it = networks_.find(network_id);

  return EncodableMap{
      {EncodableValue("eventCode"), EncodableValue(event_code)},
      {EncodableValue("generation"),
       EncodableValue(static_cast<int64_t>(
           pending_leave_generation_it != pending_leave_generations_.end()
               ? pending_leave_generation_it->second
               : (generation_it == network_generations_.end()
                      ? 0
                      : generation_it->second)))},
      {EncodableValue("trigger"), EncodableValue(trigger)},
      {EncodableValue("serviceState"), EncodableValue(BuildServiceState())},
      {EncodableValue("networkId"), EncodableValue(ToHexNetworkId(network_id))},
      {EncodableValue("leaveRequested"),
       EncodableValue(leaving_networks_.find(network_id) != leaving_networks_.end())},
      {EncodableValue("leaveSource"),
       EncodableValue(leave_source_it == leave_request_sources_.end()
                          ? ""
                          : leave_source_it->second)},
      {EncodableValue("pendingLeaveGeneration"),
       EncodableValue(static_cast<int64_t>(
           pending_leave_generation_it == pending_leave_generations_.end()
               ? 0
               : pending_leave_generation_it->second))},
      {EncodableValue("knownNetworks"), EncodableValue(known_networks)},
      {EncodableValue("networkStatus"),
       EncodableValue(network_it == networks_.end() ? "" : network_it->second.status)},
      {EncodableValue("networkConnected"),
       EncodableValue(network_it == networks_.end() ? false
                                                    : network_it->second.is_connected)},
  };
}

uint64_t ZeroTierWindowsRuntime::NextNetworkGenerationLocked(uint64_t network_id) {
  const uint64_t generation = ++next_network_generation_;
  network_generations_[network_id] = generation;
  return generation;
}

bool ZeroTierWindowsRuntime::EnsurePrepared(std::string* error_message) {
  std::scoped_lock lock(mutex_);
  if (environment_prepared_) {
    if (error_message != nullptr) {
      error_message->clear();
    }
    return true;
  }

  try {
    std::filesystem::create_directories(RuntimeRootPath());
    std::filesystem::create_directories(NodeStoragePath());
    std::filesystem::create_directories(LogsPath());
  } catch (const std::exception& error) {
    SetLastErrorLocked(error.what());
    if (error_message != nullptr) {
      *error_message = last_error_;
    }
    return false;
  }

  storage_path_ = NodeStoragePath();
  logs_path_ = LogsPath();

  const int storage_result = zts_init_from_storage(storage_path_.c_str());
  if (storage_result != ZTS_ERR_OK) {
    SetLastErrorLocked("zts_init_from_storage failed: " +
                       std::to_string(storage_result));
    if (error_message != nullptr) {
      *error_message = last_error_;
    }
    return false;
  }

  const int callback_result = zts_init_set_event_handler(&HandleLibztEvent);
  if (callback_result != ZTS_ERR_OK) {
    SetLastErrorLocked("zts_init_set_event_handler failed: " +
                       std::to_string(callback_result));
    if (error_message != nullptr) {
      *error_message = last_error_;
    }
    return false;
  }

  environment_prepared_ = true;
  handler_registered_ = true;
  ClearLastErrorLocked();
  if (error_message != nullptr) {
    error_message->clear();
  }
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
    return node_online_ || !last_error_.empty() || !node_started_;
  });

  if (!ready || !node_online_) {
    if (error_message != nullptr) {
      if (!last_error_.empty()) {
        *error_message = last_error_;
      } else if (node_offline_) {
        *error_message = "ZeroTier node is offline.";
      } else if (!node_started_) {
        *error_message = "ZeroTier node stopped before it became online.";
      } else {
        *error_message = "ZeroTier node is not online yet.";
      }
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
      flutter::EncodableMap payload;
      {
        std::scoped_lock lock(mutex_);
        node_online_ = true;
        node_offline_ = false;
        ClearLastErrorLocked();
        payload = BuildNodeDiagnosticsPayloadLocked(event->event_code);
      }
      EmitEvent(BuildEvent("nodeOnline", "ZeroTier node is online.", "",
                           payload));
      break;
    }
    case ZTS_EVENT_NODE_OFFLINE: {
      const std::string message = "ZeroTier node is offline.";
      flutter::EncodableMap payload;
      {
        std::scoped_lock lock(mutex_);
        node_online_ = false;
        node_offline_ = true;
        ClearLastErrorLocked();
        payload = BuildNodeDiagnosticsPayloadLocked(event->event_code);
      }
      EmitEvent(BuildEvent("nodeOffline", message, "", payload));
      break;
    }
    case ZTS_EVENT_NODE_DOWN: {
      bool emit_error = false;
      flutter::EncodableMap payload;
      {
        std::scoped_lock lock(mutex_);
        node_started_ = false;
        node_online_ = false;
        node_offline_ = false;
        if (stop_requested_) {
          ClearLastErrorLocked();
        } else {
          SetLastErrorLocked("ZeroTier node stopped unexpectedly.");
          emit_error = true;
        }
        payload = BuildNodeDiagnosticsPayloadLocked(event->event_code);
      }
      if (emit_error) {
        EmitEvent(BuildEvent("error", "ZeroTier node stopped unexpectedly.", "",
                             payload));
      }
      EmitEvent(BuildEvent("nodeStopped", "ZeroTier node is down.", "", payload));
      break;
    }
    case ZTS_EVENT_NETWORK_REQ_CONFIG: {
      flutter::EncodableMap payload;
      {
        std::scoped_lock lock(mutex_);
        ClearLastErrorLocked();
        payload = BuildNetworkDiagnosticsPayloadLocked(
            event->network == nullptr ? 0 : event->network->net_id,
            event->event_code, "networkRequestConfig");
      }
      EmitEvent(BuildEvent("networkJoining", "Waiting for network configuration.",
                           event->network == nullptr ? "" : ToHexNetworkId(event->network->net_id),
                           payload));
      break;
    }
    case ZTS_EVENT_NETWORK_ACCESS_DENIED: {
      flutter::EncodableMap payload;
      {
        std::scoped_lock lock(mutex_);
        SetLastErrorLocked("ZeroTier network authorization is still pending.");
        payload = BuildNetworkDiagnosticsPayloadLocked(
            event->network == nullptr ? 0 : event->network->net_id,
            event->event_code, "networkAccessDenied");
      }
      EmitEvent(BuildEvent("networkWaitingAuthorization",
                           "ZeroTier network requires authorization.",
                           event->network == nullptr ? "" : ToHexNetworkId(event->network->net_id),
                           payload));
      break;
    }
    case ZTS_EVENT_NETWORK_READY_IP4:
    case ZTS_EVENT_NETWORK_READY_IP6:
    case ZTS_EVENT_NETWORK_READY_IP4_IP6:
    case ZTS_EVENT_NETWORK_OK: {
      bool suppress_event = false;
      flutter::EncodableMap payload;
      {
        std::scoped_lock lock(mutex_);
        ClearLastErrorLocked();
        if (event->network != nullptr &&
            leaving_networks_.find(event->network->net_id) != leaving_networks_.end()) {
          suppress_event = true;
        }
        payload = BuildNetworkDiagnosticsPayloadLocked(
            event->network == nullptr ? 0 : event->network->net_id,
            event->event_code, "networkReady");
      }
      if (suppress_event) {
        break;
      }
      EmitEvent(BuildEvent("networkOnline", "ZeroTier network is online.",
                           event->network == nullptr ? "" : ToHexNetworkId(event->network->net_id),
                           payload));
      break;
    }
    case ZTS_EVENT_ADDR_ADDED_IP4:
    case ZTS_EVENT_ADDR_ADDED_IP6: {
      bool suppress_event = false;
      std::string network_id =
          event->addr == nullptr ? "" : ToHexNetworkId(event->addr->net_id);
      flutter::EncodableMap payload;
      {
        std::scoped_lock lock(mutex_);
        ClearLastErrorLocked();
        if (event->addr != nullptr &&
            leaving_networks_.find(event->addr->net_id) != leaving_networks_.end()) {
          suppress_event = true;
        }
        payload = BuildNetworkDiagnosticsPayloadLocked(
            event->addr == nullptr ? 0 : event->addr->net_id,
            event->event_code, "addressAdded");
      }
      if (suppress_event) {
        break;
      }
      EmitEvent(BuildEvent("ipAssigned", "Managed address assigned.", network_id,
                           payload));
      break;
    }
    case ZTS_EVENT_NETWORK_NOT_FOUND:
    case ZTS_EVENT_NETWORK_CLIENT_TOO_OLD:
    case ZTS_EVENT_NETWORK_DOWN:
    case ZTS_EVENT_NODE_FATAL_ERROR: {
      bool emit_network_left = false;
      std::string left_network_id;
      flutter::EncodableMap payload;
      if (event->event_code == ZTS_EVENT_NETWORK_DOWN) {
        std::scoped_lock lock(mutex_);
        payload = BuildNetworkDiagnosticsPayloadLocked(
            event->network == nullptr ? 0 : event->network->net_id,
            event->event_code, "networkDown");
        if (ShouldSuppressNetworkDownError(event, leaving_networks_)) {
          leaving_networks_.erase(event->network->net_id);
          networks_.erase(event->network->net_id);
          emit_network_left = true;
          left_network_id = ToHexNetworkId(event->network->net_id);
          leave_request_sources_.erase(event->network->net_id);
          ClearLastErrorLocked();
        }
      }
      if (emit_network_left) {
        EmitEvent(BuildEvent("networkLeft", "Left ZeroTier network.",
                             left_network_id, payload));
        break;
      }
      if (event->event_code == ZTS_EVENT_NETWORK_DOWN) {
        {
          std::scoped_lock lock(mutex_);
          SetLastErrorLocked("ZeroTier runtime reported an unexpected network down.");
        }
        EmitEvent(BuildEvent(
            "error", "ZeroTier runtime reported an unexpected network down.",
            event->network == nullptr ? "" : ToHexNetworkId(event->network->net_id),
            payload));
      } else {
        EmitError("ZeroTier runtime reported an error.",
                  event->network == nullptr ? ""
                                            : ToHexNetworkId(event->network->net_id));
      }
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
  if (leaving_networks_.find(network->net_id) != leaving_networks_.end()) {
    return;
  }
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
  if (leaving_networks_.find(event->addr->net_id) != leaving_networks_.end()) {
    return;
  }
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
                                       const std::string& network_id) {
  if (!message.empty()) {
    std::scoped_lock lock(mutex_);
    SetLastErrorLocked(message);
  }
  EmitEvent(BuildEvent("error", message, network_id));
}

void ZeroTierWindowsRuntime::SetLastErrorLocked(const std::string& message) {
  last_error_ = message;
}

void ZeroTierWindowsRuntime::ClearLastErrorLocked() {
  last_error_.clear();
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
