#include "native/zerotier/zerotier_windows_runtime.h"

#include <ZeroTierSockets.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <optional>
#include <sstream>
#include <iostream>

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

bool ShouldTreatAddressesAsStale(const std::string& status) {
  return status == "ACCESS_DENIED" || IsTerminalNetworkFailureStatus(status);
}

bool ShouldRetainNetworkDuringProbeFailure(
    const std::map<uint64_t, ZeroTierWindowsNetworkRecord>::const_iterator&
        previous_it,
    const std::map<uint64_t, ZeroTierWindowsNetworkRecord>& previous_networks) {
  if (previous_it == previous_networks.end()) {
    return false;
  }

  const ZeroTierWindowsNetworkRecord& previous = previous_it->second;
  return previous.is_authorized || previous.is_connected ||
         !previous.assigned_addresses.empty() ||
         previous.status == "OK" ||
         previous.status == "REQUESTING_CONFIGURATION";
}

bool ShouldRetainNetworkDuringStatusRegression(
    const std::map<uint64_t, ZeroTierWindowsNetworkRecord>::const_iterator&
        previous_it,
    const std::map<uint64_t, ZeroTierWindowsNetworkRecord>& previous_networks,
    const std::string& current_status, bool has_transport,
    bool has_assigned_address) {
  if (previous_it == previous_networks.end()) {
    return false;
  }

  const ZeroTierWindowsNetworkRecord& previous = previous_it->second;
  const bool previous_ready = previous.status == "OK" &&
                              (previous.is_connected ||
                               !previous.assigned_addresses.empty());
  const bool current_not_ready = !has_transport && !has_assigned_address &&
                                 current_status == "REQUESTING_CONFIGURATION";
  return previous_ready && current_not_ready;
}

bool IsEmptyShellNetwork(const ZeroTierWindowsNetworkRecord& network) {
  if (network.status == "ACCESS_DENIED" ||
      IsTerminalNetworkFailureStatus(network.status)) {
    return true;
  }
  if (network.is_connected || !network.assigned_addresses.empty()) {
    return false;
  }
  return network.status == "REQUESTING_CONFIGURATION" ||
         network.status == "UNKNOWN" || network.status == "NETWORK_DOWN";
}

bool ShouldExposeNetworkRecord(
    uint64_t network_id, const ZeroTierWindowsNetworkRecord& network,
    const std::set<uint64_t>& pending_join_networks,
    const std::set<uint64_t>& leaving_networks) {
  if (leaving_networks.find(network_id) != leaving_networks.end()) {
    return false;
  }
  if (network.is_connected || !network.assigned_addresses.empty()) {
    return true;
  }
  if (pending_join_networks.find(network_id) != pending_join_networks.end()) {
    return true;
  }
  if (network.status == "OK" && network.is_authorized) {
    return true;
  }
  if (network.status == "ACCESS_DENIED") {
    return true;
  }
  return false;
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

bool IsUsableNodeId(uint64_t node_id) {
  return node_id != 0 && node_id != UINT64_MAX && node_id != (UINT64_MAX - 1);
}

std::string JoinAddresses(const std::vector<std::string>& addresses) {
  if (addresses.empty()) {
    return "-";
  }

  std::ostringstream stream;
  for (size_t index = 0; index < addresses.size(); ++index) {
    if (index > 0) {
      stream << ",";
    }
    stream << addresses[index];
  }
  return stream.str();
}

}  // namespace

ZeroTierWindowsRuntime::ZeroTierWindowsRuntime() {
  g_runtime_instance = this;
  adapter_probe_.summary = "Adapter bridge not initialized yet.";
}

flutter::EncodableMap ZeroTierWindowsRuntime::DetectStatus() {
  RefreshSnapshot();
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
  bool restarted_from_offline = false;
  {
    std::scoped_lock lock(mutex_);
    if (!node_online_ || !networks_.empty() || node_offline_) {
      std::clog << "[ZT/WIN] StartNode request"
                << " node_started=" << (node_started_ ? "true" : "false")
                << " node_online=" << (node_online_ ? "true" : "false")
                << " node_offline=" << (node_offline_ ? "true" : "false")
                << " stop_requested=" << (stop_requested_ ? "true" : "false")
                << " known_networks=" << known_network_ids_.size()
                << " joined_networks=" << networks_.size()
                << std::endl;
    }
    if (node_online_) {
      ClearLastErrorLocked();
    } else if (!node_started_) {
      std::scoped_lock api_lock(api_mutex_);
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
      std::clog << "[ZT/WIN] StartNode attempting in-process recovery"
                << " because node_started is already true"
                << " while node_online=" << (node_online_ ? "true" : "false")
                << " node_offline=" << (node_offline_ ? "true" : "false")
                << std::endl;
      stop_requested_ = true;
      std::scoped_lock api_lock(api_mutex_);
      const int stop_result = zts_node_stop();
      std::clog << "[ZT/WIN] StartNode recovery stop result"
                << " code=" << stop_result
                << std::endl;
      if (stop_result != ZTS_ERR_OK) {
        SetLastErrorLocked("zts_node_stop failed during recovery: " +
                           std::to_string(stop_result));
        stop_requested_ = false;
        error_message = last_error_;
      } else {
        node_started_ = false;
        node_online_ = false;
        node_offline_ = false;
        networks_.clear();
        leaving_networks_.clear();
        leave_request_sources_.clear();
        pending_leave_generations_.clear();
        network_generations_.clear();

        const int start_result = zts_node_start();
        std::clog << "[ZT/WIN] StartNode recovery start result"
                  << " code=" << start_result
                  << std::endl;
        if (start_result != ZTS_ERR_OK) {
          SetLastErrorLocked("zts_node_start failed during recovery: " +
                             std::to_string(start_result));
          stop_requested_ = false;
          error_message = last_error_;
        } else {
          node_started_ = true;
          node_offline_ = false;
          stop_requested_ = false;
          restarted_from_offline = true;
          emit_start_event = true;
          ClearLastErrorLocked();
        }
      }
    }
  }
  if (!error_message.empty()) {
    EmitError(error_message);
    std::scoped_lock lock(mutex_);
    return BuildStatus();
  }

  if (emit_start_event) {
    EmitEvent(BuildEvent(
        "nodeStarted",
        restarted_from_offline ? "Windows libzt node restart requested."
                               : "Windows libzt node start requested."));
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
      std::scoped_lock api_lock(api_mutex_);
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
    pending_join_networks_.insert(network_id);
    RememberKnownNetworkLocked(network_id);
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

  int result = ZTS_ERR_OK;
  {
    std::scoped_lock api_lock(api_mutex_);
    result = zts_net_join(network_id);
  }
  std::clog << "[ZT/WIN] JoinNetwork request"
            << " network_id=" << ToHexNetworkId(network_id)
            << " result=" << result
            << " timeout_ms=" << timeout_ms
            << std::endl;
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
  const auto probe_interval = std::chrono::milliseconds(1000);
  std::unique_lock lock(mutex_);
  while (std::chrono::steady_clock::now() < deadline) {
    lock.unlock();
    RefreshSnapshot();
    lock.lock();

    const auto now = std::chrono::steady_clock::now();
    if (now >= deadline) {
      break;
    }
    const auto remaining = deadline - now;
    const auto wait_slice =
        remaining < probe_interval ? remaining : probe_interval;
    state_cv_.wait_for(lock, wait_slice, [this, network_id]() {
      const auto network_it = networks_.find(network_id);
      if (network_it == networks_.end()) {
        return !last_error_.empty() || !node_started_;
      }

      const ZeroTierWindowsNetworkRecord& network = network_it->second;
      if (network.status == "ACCESS_DENIED" ||
          IsTerminalNetworkFailureStatus(network.status)) {
        return true;
      }
      if (!network.assigned_addresses.empty()) {
        return true;
      }
      if (network.status == "OK" && network.is_authorized && node_online_) {
        return true;
      }
      return !last_error_.empty() || !node_started_;
    });

    const auto network_it = networks_.find(network_id);
    if (network_it != networks_.end()) {
      const ZeroTierWindowsNetworkRecord& network = network_it->second;
      std::clog << "[ZT/WIN] JoinNetwork wait snapshot"
                << " network_id=" << ToHexNetworkId(network_id)
                << " status=" << network.status
                << " authorized=" << (network.is_authorized ? "true" : "false")
                << " connected=" << (network.is_connected ? "true" : "false")
                << " address_count=" << network.assigned_addresses.size()
                << " addresses=" << JoinAddresses(network.assigned_addresses)
                << " node_started=" << (node_started_ ? "true" : "false")
                << " node_online=" << (node_online_ ? "true" : "false")
                << " last_error=" << (last_error_.empty() ? "-" : last_error_)
                << std::endl;
      if (!network.assigned_addresses.empty()) {
        ClearLastErrorLocked();
        pending_join_networks_.erase(network_id);
        if (error_message != nullptr) {
          error_message->clear();
        }
        return true;
      }
      if (network.status == "OK" && network.is_authorized && node_online_) {
        ClearLastErrorLocked();
        pending_join_networks_.erase(network_id);
        if (error_message != nullptr) {
          error_message->clear();
        }
        std::clog << "[ZT/WIN] JoinNetwork accepting local-mounted pending state"
                  << " network_id=" << ToHexNetworkId(network_id)
                  << " because network is authorized and OK"
                  << std::endl;
        return true;
      }
      if (network.status == "ACCESS_DENIED" ||
          IsTerminalNetworkFailureStatus(network.status)) {
        const std::string message = ComposeJoinFailureMessage(network);
        SetLastErrorLocked(message);
        pending_join_networks_.erase(network_id);
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
      pending_join_networks_.erase(network_id);
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
      pending_join_networks_.erase(network_id);
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
  const auto timed_out_network_it = networks_.find(network_id);
  if (timed_out_network_it != networks_.end()) {
    const ZeroTierWindowsNetworkRecord& network = timed_out_network_it->second;
    std::clog << "[ZT/WIN] JoinNetwork timed out"
              << " network_id=" << ToHexNetworkId(network_id)
              << " status=" << network.status
              << " authorized=" << (network.is_authorized ? "true" : "false")
              << " connected=" << (network.is_connected ? "true" : "false")
              << " address_count=" << network.assigned_addresses.size()
              << " addresses=" << JoinAddresses(network.assigned_addresses)
              << " node_started=" << (node_started_ ? "true" : "false")
              << " node_online=" << (node_online_ ? "true" : "false")
              << std::endl;
  } else {
    std::clog << "[ZT/WIN] JoinNetwork timed out"
              << " network_id=" << ToHexNetworkId(network_id)
              << " status=missing"
              << " node_started=" << (node_started_ ? "true" : "false")
              << " node_online=" << (node_online_ ? "true" : "false")
              << std::endl;
  }
  if (error_message != nullptr) {
    *error_message = message;
  }
  pending_join_networks_.erase(network_id);
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
    LoadKnownNetworkIdsLocked();
    pending_join_networks_.erase(network_id);
    leaving_networks_.insert(network_id);
    leave_request_sources_[network_id] =
        source.empty() ? "unknown" : source;
    leave_generation = NextNetworkGenerationLocked(network_id);
    pending_leave_generations_[network_id] = leave_generation;
    ClearLastErrorLocked();
  }

  const std::string network_id_hex = ToHexNetworkId(network_id);

  int result = ZTS_ERR_OK;
  {
    std::scoped_lock api_lock(api_mutex_);
    result = zts_net_leave(network_id);
  }
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
      const auto network_it = networks_.find(network_id);
      if (network_it == networks_.end()) {
        return true;
      }
      return IsEmptyShellNetwork(network_it->second) || !last_error_.empty();
    });

    const auto network_it = networks_.find(network_id);
    if (network_it == networks_.end() ||
        IsEmptyShellNetwork(network_it->second)) {
      if (network_it != networks_.end()) {
        ForgetKnownNetworkLocked(network_id);
        networks_.erase(network_it);
      }
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
  for (const auto& [network_id, network] : networks_) {
    if (!ShouldExposeNetworkRecord(network_id, network, pending_join_networks_,
                                   leaving_networks_)) {
      continue;
    }
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
  if (!ShouldExposeNetworkRecord(network_id, it->second, pending_join_networks_,
                                 leaving_networks_)) {
    return std::nullopt;
  }
  return BuildNetworkMap(it->second);
}

void ZeroTierWindowsRuntime::HandleLibztEvent(void* message_ptr) {
  if (g_runtime_instance != nullptr) {
    g_runtime_instance->ProcessEvent(message_ptr);
  }
}

std::string ErrorCodeToString(int code) {
  switch (code) {
    case ZTS_ERR_OK:
      return "ZTS_ERR_OK";
    case ZTS_ERR_SOCKET:
      return "ZTS_ERR_SOCKET";
    case ZTS_ERR_SERVICE:
      return "ZTS_ERR_SERVICE";
    case ZTS_ERR_ARG:
      return "ZTS_ERR_ARG";
    case ZTS_ERR_NO_RESULT:
      return "ZTS_ERR_NO_RESULT";
    case ZTS_ERR_GENERAL:
      return "ZTS_ERR_GENERAL";
    default:
      return "UNKNOWN_ERROR";
  }
}

const char* EventCodeToString(int code) {
  switch (code) {
    case ZTS_EVENT_NODE_UP:
      return "ZTS_EVENT_NODE_UP";
    case ZTS_EVENT_NODE_ONLINE:
      return "ZTS_EVENT_NODE_ONLINE";
    case ZTS_EVENT_NODE_OFFLINE:
      return "ZTS_EVENT_NODE_OFFLINE";
    case ZTS_EVENT_NODE_DOWN:
      return "ZTS_EVENT_NODE_DOWN";
    case ZTS_EVENT_NETWORK_NOT_FOUND:
      return "ZTS_EVENT_NETWORK_NOT_FOUND";
    case ZTS_EVENT_NETWORK_REQ_CONFIG:
      return "ZTS_EVENT_NETWORK_REQ_CONFIG";
    case ZTS_EVENT_NETWORK_OK:
      return "ZTS_EVENT_NETWORK_OK";
    case ZTS_EVENT_NETWORK_ACCESS_DENIED:
      return "ZTS_EVENT_NETWORK_ACCESS_DENIED";
    case ZTS_EVENT_NETWORK_DOWN:
      return "ZTS_EVENT_NETWORK_DOWN";
    case ZTS_EVENT_ADDR_ADDED_IP4:
      return "ZTS_EVENT_ADDR_ADDED_IP4";
    case ZTS_EVENT_ADDR_ADDED_IP6:
      return "ZTS_EVENT_ADDR_ADDED_IP6";
    case ZTS_EVENT_NODE_FATAL_ERROR:
      return "ZTS_EVENT_NODE_FATAL_ERROR";
    default:
      return nullptr;
  }
}

flutter::EncodableMap ZeroTierWindowsRuntime::BuildStatus() const {
  EncodableList joined_networks;
  for (const auto& [network_id, network] : networks_) {
    if (!ShouldExposeNetworkRecord(network_id, network, pending_join_networks_,
                                   leaving_networks_)) {
      continue;
    }
    joined_networks.emplace_back(BuildNetworkMap(network));
  }

  EncodableMap permission_state{
      {EncodableValue("isGranted"), EncodableValue(true)},
      {EncodableValue("requiresManualSetup"), EncodableValue(false)},
      {EncodableValue("isFirewallSupported"), EncodableValue(true)},
      {EncodableValue("summary"),
       EncodableValue("Windows libzt runtime is active.")},
  };
  const EncodableMap adapter_payload = BuildAdapterDiagnosticsPayloadLocked();
  const auto summary_it =
      adapter_payload.find(EncodableValue("summary"));
  if (summary_it != adapter_payload.end() &&
      std::holds_alternative<std::string>(summary_it->second)) {
    permission_state[EncodableValue("summary")] =
        EncodableValue(std::get<std::string>(summary_it->second));
  }

  std::ostringstream version_stream;
  version_stream << "libzt/" << major_version_ << "." << minor_version_;

  return EncodableMap{
      {EncodableValue("nodeId"),
       EncodableValue(IsUsableNodeId(node_id_) ? ToHexNetworkId(node_id_) : "")},
      {EncodableValue("version"), EncodableValue(version_stream.str())},
      {EncodableValue("serviceState"), EncodableValue(BuildServiceState())},
      {EncodableValue("permissionState"), EncodableValue(permission_state)},
      {EncodableValue("isNodeRunning"),
       EncodableValue(node_started_ || node_online_)},
      {EncodableValue("joinedNetworks"), EncodableValue(joined_networks)},
      {EncodableValue("adapterBridge"), EncodableValue(adapter_payload)},
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
       EncodableValue(IsUsableNodeId(node_id_) ? ToHexNetworkId(node_id_) : "")},
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
  EncodableList network_addresses;
  if (network_it != networks_.end()) {
    for (const auto& address : network_it->second.assigned_addresses) {
      network_addresses.emplace_back(address);
    }
  }

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
      {EncodableValue("networkAuthorized"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.is_authorized)},
      {EncodableValue("networkConnected"),
       EncodableValue(network_it == networks_.end() ? false
                                                    : network_it->second.is_connected)},
      {EncodableValue("networkAddressCount"),
       EncodableValue(static_cast<int>(
           network_it == networks_.end()
               ? 0
               : network_it->second.assigned_addresses.size()))},
      {EncodableValue("networkAddresses"), EncodableValue(network_addresses)},
      {EncodableValue("adapterBridge"),
       EncodableValue(BuildAdapterDiagnosticsPayloadLocked())},
  };
}

flutter::EncodableMap
ZeroTierWindowsRuntime::BuildAdapterDiagnosticsPayloadLocked() const {
  EncodableList adapter_names;
  for (const auto& item : adapter_probe_.virtual_adapter_names) {
    adapter_names.emplace_back(item);
  }
  EncodableList detected_ips;
  for (const auto& item : adapter_probe_.detected_ipv4_addresses) {
    detected_ips.emplace_back(item);
  }
  EncodableList expected_ips;
  for (const auto& item : adapter_probe_.expected_ipv4_addresses) {
    expected_ips.emplace_back(item);
  }
  return EncodableMap{
      {EncodableValue("initialized"), EncodableValue(adapter_probe_.initialized)},
      {EncodableValue("hasVirtualAdapter"),
       EncodableValue(adapter_probe_.has_virtual_adapter)},
      {EncodableValue("hasExpectedNetworkIp"),
       EncodableValue(adapter_probe_.has_expected_network_ip)},
      {EncodableValue("virtualAdapterNames"), EncodableValue(adapter_names)},
      {EncodableValue("detectedIpv4Addresses"), EncodableValue(detected_ips)},
      {EncodableValue("expectedIpv4Addresses"), EncodableValue(expected_ips)},
      {EncodableValue("summary"), EncodableValue(adapter_probe_.summary)},
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

  std::scoped_lock api_lock(api_mutex_);
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
  std::string bridge_error;
  if (!adapter_bridge_.Initialize(&bridge_error)) {
    SetLastErrorLocked("adapter bridge initialize failed: " + bridge_error);
    if (error_message != nullptr) {
      *error_message = last_error_;
    }
    return false;
  }
  adapter_probe_ = adapter_bridge_.LastProbe();
  std::clog << "[ZT/WIN] AdapterBridge initialized"
            << " summary=" << adapter_probe_.summary
            << std::endl;
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
    should_start = !node_started_ || (node_started_ && node_offline_);
  }

  if (should_start) {
    std::clog << "[ZT/WIN] EnsureNodeReady requesting StartNode"
              << " because node_started=" << (node_started_ ? "true" : "false")
              << " node_offline=" << (node_offline_ ? "true" : "false")
              << std::endl;
    StartNode();
  }

  std::unique_lock lock(mutex_);
  std::clog << "[ZT/WIN] EnsureNodeReady waiting"
            << " node_started=" << (node_started_ ? "true" : "false")
            << " node_online=" << (node_online_ ? "true" : "false")
            << " node_offline=" << (node_offline_ ? "true" : "false")
            << " last_error=" << (last_error_.empty() ? "-" : last_error_)
            << std::endl;
  const bool ready = state_cv_.wait_for(lock, std::chrono::seconds(20), [this]() {
    return node_online_ || !last_error_.empty() || !node_started_;
  });

  std::clog << "[ZT/WIN] EnsureNodeReady finished"
            << " ready=" << (ready ? "true" : "false")
            << " node_started=" << (node_started_ ? "true" : "false")
            << " node_online=" << (node_online_ ? "true" : "false")
            << " node_offline=" << (node_offline_ ? "true" : "false")
            << " last_error=" << (last_error_.empty() ? "-" : last_error_)
            << std::endl;

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
  if (const char* event_name = EventCodeToString(event->event_code);
      event_name != nullptr) {
    std::clog << "[ZT/WIN] libzt event"
              << " code=" << event->event_code
              << " name=" << event_name
              << " node_started=" << (node_started_ ? "true" : "false")
              << " node_online=" << (node_online_ ? "true" : "false")
              << " node_offline=" << (node_offline_ ? "true" : "false")
              << " network_ptr=" << (event->network != nullptr ? "yes" : "no")
              << " addr_ptr=" << (event->addr != nullptr ? "yes" : "no")
              << std::endl;
  }
  {
    std::scoped_lock lock(mutex_);
    if (event->node != nullptr) {
      node_id_ = event->node->node_id;
      node_port_ = event->node->port_primary;
      major_version_ = event->node->ver_major;
      minor_version_ = event->node->ver_minor;
    } else if (node_started_) {
      std::scoped_lock api_lock(api_mutex_);
      node_id_ = zts_node_get_id();
      node_port_ = zts_node_get_port();
    }
    if (!IsUsableNodeId(node_id_)) {
      node_id_ = 0;
    }
  }

  if (event->network != nullptr) {
    std::clog << "[ZT/WIN] Event network snapshot"
              << " network_id=" << ToHexNetworkId(event->network->net_id)
              << " status=" << NetworkStatusToString(event->network->status)
              << " type=" << event->network->type
              << " mtu=" << event->network->mtu
              << " dhcp=" << event->network->dhcp
              << " bridge=" << event->network->bridge
              << " broadcast=" << event->network->broadcast_enabled
              << " port_error=" << event->network->port_error
              << " netconf_rev=" << event->network->netconf_rev
              << " assigned_addr_count=" << event->network->assigned_addr_count
              << std::endl;
    UpdateNetworkFromLibztMessage(message_ptr);
  }
  if (event->addr != nullptr) {
    std::clog << "[ZT/WIN] Event address snapshot"
              << " network_id=" << ToHexNetworkId(event->addr->net_id)
              << " family=" << event->addr->addr.ss_family
              << " address=" << ExtractAddress(event->addr->addr)
              << std::endl;
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
          ForgetKnownNetworkLocked(event->network->net_id);
          networks_.erase(event->network->net_id);
          emit_network_left = true;
          left_network_id = ToHexNetworkId(event->network->net_id);
          leave_request_sources_.erase(event->network->net_id);
          ClearLastErrorLocked();
        }
        if (event->network != nullptr && !emit_network_left) {
          auto it = networks_.find(event->network->net_id);
          if (it != networks_.end()) {
            it->second.status = "NETWORK_DOWN";
            it->second.is_connected = false;
            it->second.is_authorized = false;
            it->second.assigned_addresses.clear();
          }
        }
      }
      if (emit_network_left) {
        {
          std::scoped_lock lock(mutex_);
          pending_join_networks_.erase(event->network->net_id);
        }
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
  const ZeroTierWindowsNetworkRecord previous_record = record;
  RememberKnownNetworkLocked(network->net_id);
  ZeroTierWindowsNetworkRecord next_record;
  next_record.network_id = network->net_id;
  next_record.network_name = network->name == nullptr ? "" : network->name;
  next_record.status = NetworkStatusToString(network->status);
  const bool stale_addresses = ShouldTreatAddressesAsStale(next_record.status);
  next_record.is_authorized =
      network->status == ZTS_NETWORK_STATUS_OK ||
      network->type == ZTS_NETWORK_TYPE_PUBLIC;
  {
    std::scoped_lock api_lock(api_mutex_);
    next_record.is_connected =
        !stale_addresses &&
        (zts_net_transport_is_ready(network->net_id) > 0 ||
         network->assigned_addr_count > 0);
  }
  next_record.assigned_addresses.clear();
  if (!stale_addresses) {
    for (unsigned int i = 0; i < network->assigned_addr_count; ++i) {
      const std::string address = ExtractAddress(network->assigned_addrs[i]);
      if (!address.empty()) {
        next_record.assigned_addresses.push_back(address);
      }
    }
  }
  const bool should_keep_previous_ready_state =
      previous_record.status == "OK" &&
      (previous_record.is_connected ||
       !previous_record.assigned_addresses.empty()) &&
      next_record.status == "REQUESTING_CONFIGURATION" &&
      !next_record.is_connected && next_record.assigned_addresses.empty();
  if (should_keep_previous_ready_state) {
    std::clog << "[ZT/WIN] UpdateNetworkFromEvent keeping previous ready state"
              << " network_id=" << ToHexNetworkId(network->net_id)
              << " previous_status=" << previous_record.status
              << " incoming_status=" << next_record.status
              << " reason=transientRegression"
              << std::endl;
  } else {
    record = std::move(next_record);
  }
  std::clog << "[ZT/WIN] UpdateNetworkFromEvent"
            << " network_id=" << ToHexNetworkId(network->net_id)
            << " raw_status=" << network->status
            << " status=" << record.status
            << " type=" << network->type
            << " authorized=" << (record.is_authorized ? "true" : "false")
            << " connected=" << (record.is_connected ? "true" : "false")
            << " assigned_addr_count=" << network->assigned_addr_count
            << " addresses=" << JoinAddresses(record.assigned_addresses)
            << std::endl;
  if (record.is_connected || !record.assigned_addresses.empty() ||
      (record.status == "OK" && record.is_authorized)) {
    pending_join_networks_.erase(network->net_id);
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
  RememberKnownNetworkLocked(event->addr->net_id);
  record.network_id = event->addr->net_id;
  if (ShouldTreatAddressesAsStale(record.status)) {
    record.assigned_addresses.clear();
    record.is_connected = false;
    return;
  }
  const std::string address = ExtractAddress(event->addr->addr);
  if (!address.empty() &&
      std::find(record.assigned_addresses.begin(), record.assigned_addresses.end(),
                address) == record.assigned_addresses.end()) {
    record.assigned_addresses.push_back(address);
  }
  record.is_connected = !record.assigned_addresses.empty();
  std::clog << "[ZT/WIN] UpdateAddressFromEvent"
            << " network_id=" << ToHexNetworkId(event->addr->net_id)
            << " family=" << event->addr->addr.ss_family
            << " address=" << (address.empty() ? "-" : address)
            << " address_count=" << record.assigned_addresses.size()
            << " connected=" << (record.is_connected ? "true" : "false")
            << " addresses=" << JoinAddresses(record.assigned_addresses)
            << std::endl;
  if (record.is_connected || !record.assigned_addresses.empty()) {
    pending_join_networks_.erase(event->addr->net_id);
  }
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

void ZeroTierWindowsRuntime::RefreshSnapshot() {
  std::vector<uint64_t> known_network_ids;
  std::map<uint64_t, ZeroTierWindowsNetworkRecord> previous_networks;
  std::set<uint64_t> pending_join_network_ids;
  bool previous_node_started = false;
  bool previous_node_online = false;
  bool previous_node_offline = false;
  uint64_t previous_node_id = 0;
  int previous_node_port = 0;
  {
    std::scoped_lock lock(mutex_);
    if (!environment_prepared_) {
      return;
    }
    LoadKnownNetworkIdsLocked();
    known_network_ids.assign(known_network_ids_.begin(), known_network_ids_.end());
    previous_networks = networks_;
    pending_join_network_ids = pending_join_networks_;
    previous_node_started = node_started_;
    previous_node_online = node_online_;
    previous_node_offline = node_offline_;
    previous_node_id = node_id_;
    previous_node_port = node_port_;
  }

  uint64_t node_id = 0;
  int node_port = 0;
  bool node_online = false;
  {
    std::scoped_lock api_lock(api_mutex_);
    node_id = zts_node_get_id();
    node_port = zts_node_get_port();
    node_online = zts_node_is_online() == 1;
  }
  std::map<uint64_t, ZeroTierWindowsNetworkRecord> refreshed_networks;
  std::set<uint64_t> missing_network_ids;
  std::vector<std::string> expected_addresses;

  for (const uint64_t network_id : known_network_ids) {
    int status_code = 0;
    int transport_ready = 0;
    zts_sockaddr_storage assigned_addrs[ZTS_MAX_ASSIGNED_ADDRESSES] = {};
    unsigned int assigned_addr_count = ZTS_MAX_ASSIGNED_ADDRESSES;
    std::vector<std::string> assigned_addresses;
    int addr_result = ZTS_ERR_SERVICE;
    int network_type = 0;
    int name_result = ZTS_ERR_SERVICE;
    char network_name_buffer[ZTS_MAX_NETWORK_SHORT_NAME_LENGTH + 1] = {0};
    {
      std::scoped_lock api_lock(api_mutex_);
      status_code = zts_net_get_status(network_id);
      transport_ready = zts_net_transport_is_ready(network_id);
      addr_result =
          zts_addr_get_all(network_id, assigned_addrs, &assigned_addr_count);
      network_type = zts_net_get_type(network_id);
      name_result = zts_net_get_name(network_id, network_name_buffer,
                                     ZTS_MAX_NETWORK_SHORT_NAME_LENGTH);
    }
    if (addr_result == ZTS_ERR_OK) {
      for (unsigned int i = 0; i < assigned_addr_count; ++i) {
        const std::string address = ExtractAddress(assigned_addrs[i]);
        if (!address.empty()) {
          assigned_addresses.push_back(address);
        }
      }
    }

    const std::string normalized_status = NetworkStatusToString(status_code);
    const bool stale_addresses = ShouldTreatAddressesAsStale(normalized_status);
    const bool has_transport = !stale_addresses && transport_ready > 0;
    const bool has_assigned_address =
        !stale_addresses && !assigned_addresses.empty();
    const auto previous_it = previous_networks.find(network_id);
    const bool current_connected = has_transport || has_assigned_address;
    const bool should_log_probe =
        previous_it == previous_networks.end() ||
        previous_it->second.status != NetworkStatusToString(status_code) ||
        previous_it->second.is_connected != current_connected ||
        previous_it->second.assigned_addresses != assigned_addresses ||
        addr_result != ZTS_ERR_NO_RESULT;
    if (should_log_probe) {
      std::clog << "[ZT/WIN] RefreshSnapshot network probe"
                << " network_id=" << ToHexNetworkId(network_id)
                << " status_code=" << status_code
                << " status=" << normalized_status
                << " transport_ready=" << transport_ready
                << " addr_result=" << addr_result
                << " addr_result_name=" << ErrorCodeToString(addr_result)
                << " addr_count=" << assigned_addr_count
                << " network_type=" << network_type
                << " name_result=" << name_result
                << " has_transport=" << (has_transport ? "true" : "false")
                << " has_assigned_address="
                << (has_assigned_address ? "true" : "false")
                << " addresses=" << JoinAddresses(assigned_addresses)
                << std::endl;
    }
    if (status_code < 0 && !has_transport && !has_assigned_address) {
      if (ShouldRetainNetworkDuringProbeFailure(previous_it, previous_networks)) {
        ZeroTierWindowsNetworkRecord retained = previous_it->second;
        if (name_result == ZTS_ERR_OK) {
          retained.network_name = network_name_buffer;
        }
        if (!retained.is_authorized) {
          retained.is_authorized = retained.status == "OK";
        }
        retained.is_connected = false;
        if (retained.status.empty() || retained.status == "UNKNOWN") {
          retained.status = "UNKNOWN";
        }
        refreshed_networks[network_id] = std::move(retained);
        std::clog << "[ZT/WIN] RefreshSnapshot retained pending network"
                  << " network_id=" << ToHexNetworkId(network_id)
                  << " previous_status=" << previous_it->second.status
                  << " reason=transientProbeFailure"
                  << std::endl;
        continue;
      }
      missing_network_ids.insert(network_id);
      continue;
    }
    if (ShouldRetainNetworkDuringStatusRegression(previous_it, previous_networks,
                                                  normalized_status,
                                                  has_transport,
                                                  has_assigned_address)) {
      refreshed_networks[network_id] = previous_it->second;
      std::clog << "[ZT/WIN] RefreshSnapshot retained network"
                << " network_id=" << ToHexNetworkId(network_id)
                << " previous_status=" << previous_it->second.status
                << " current_status=" << normalized_status
                << " reason=transientStatusRegression"
                << std::endl;
      continue;
    }

    ZeroTierWindowsNetworkRecord record;
    record.network_id = network_id;
    record.network_name =
        name_result == ZTS_ERR_OK ? network_name_buffer : std::string();
    record.status = normalized_status;
    record.assigned_addresses =
        stale_addresses ? std::vector<std::string>{}
                        : std::move(assigned_addresses);
    record.is_connected = has_transport || has_assigned_address;
    record.is_authorized =
        status_code == ZTS_NETWORK_STATUS_OK ||
        network_type == ZTS_NETWORK_TYPE_PUBLIC;
    const bool pending_join =
        pending_join_network_ids.find(network_id) != pending_join_network_ids.end();
    if (IsEmptyShellNetwork(record) && !pending_join) {
      missing_network_ids.insert(network_id);
      std::clog << "[ZT/WIN] RefreshSnapshot dropping empty-shell network"
                << " network_id=" << ToHexNetworkId(network_id)
                << " status=" << record.status
                << " reason=noPendingJoin"
                << std::endl;
      continue;
    }
    refreshed_networks[network_id] = std::move(record);
  }

  for (const auto& [_, record] : refreshed_networks) {
    if (record.status != "OK") {
      continue;
    }
    for (const auto& address : record.assigned_addresses) {
      expected_addresses.push_back(address);
    }
  }
  ZeroTierWindowsAdapterBridge::ProbeResult adapter_probe =
      adapter_bridge_.Refresh(expected_addresses);
  std::clog << "[ZT/WIN] AdapterBridge probe"
            << " summary=" << adapter_probe.summary
            << std::endl;

  std::scoped_lock lock(mutex_);
  node_id_ = IsUsableNodeId(node_id) ? node_id : 0;
  node_port_ = node_port;
  if (node_started_ && node_id_ != 0) {
    node_online_ = node_online;
    if (node_online) {
      node_offline_ = false;
    }
  }
  if (previous_node_started != node_started_ ||
      previous_node_online != node_online_ ||
      previous_node_offline != node_offline_ ||
      previous_node_id != node_id_ ||
      previous_node_port != node_port_ ||
      previous_networks.size() != refreshed_networks.size()) {
    std::clog << "[ZT/WIN] RefreshSnapshot"
              << " node_id=" << (node_id_ == 0 ? std::string("-") : ToHexNetworkId(node_id_))
              << " node_port=" << node_port_
              << " node_started=" << (node_started_ ? "true" : "false")
              << " node_online=" << (node_online_ ? "true" : "false")
              << " node_offline=" << (node_offline_ ? "true" : "false")
              << " known_networks=" << known_network_ids_.size()
              << " joined_networks=" << refreshed_networks.size()
              << std::endl;
  }
  for (const uint64_t network_id : missing_network_ids) {
    ForgetKnownNetworkLocked(network_id);
    networks_.erase(network_id);
    leave_request_sources_.erase(network_id);
    pending_leave_generations_.erase(network_id);
  }
  for (auto& [network_id, record] : refreshed_networks) {
    networks_[network_id] = std::move(record);
  }
  adapter_probe_ = std::move(adapter_probe);
}

void ZeroTierWindowsRuntime::LoadKnownNetworkIdsLocked() {
  if (known_network_ids_loaded_) {
    return;
  }
  known_network_ids_loaded_ = true;

  std::ifstream stream(KnownNetworksPath());
  if (!stream.is_open()) {
    return;
  }

  std::string line;
  while (std::getline(stream, line)) {
    std::stringstream parser;
    parser << std::hex << line;
    uint64_t network_id = 0;
    parser >> network_id;
    if (network_id != 0) {
      known_network_ids_.insert(network_id);
    }
  }
}

void ZeroTierWindowsRuntime::PersistKnownNetworkIdsLocked() const {
  std::error_code error;
  std::filesystem::create_directories(RuntimeRootPath(), error);

  std::ofstream stream(KnownNetworksPath(), std::ios::trunc);
  if (!stream.is_open()) {
    return;
  }
  for (const uint64_t network_id : known_network_ids_) {
    stream << ToHexNetworkId(network_id) << '\n';
  }
}

void ZeroTierWindowsRuntime::RememberKnownNetworkLocked(uint64_t network_id) {
  if (network_id == 0) {
    return;
  }
  LoadKnownNetworkIdsLocked();
  if (known_network_ids_.insert(network_id).second) {
    PersistKnownNetworkIdsLocked();
  }
}

void ZeroTierWindowsRuntime::ForgetKnownNetworkLocked(uint64_t network_id) {
  if (network_id == 0) {
    return;
  }
  LoadKnownNetworkIdsLocked();
  if (known_network_ids_.erase(network_id) > 0) {
    PersistKnownNetworkIdsLocked();
  }
}

std::string ZeroTierWindowsRuntime::KnownNetworksPath() const {
  return RuntimeRootPath() + "\\known_networks.txt";
}
