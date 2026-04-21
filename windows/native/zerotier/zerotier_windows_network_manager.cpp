#include "native/zerotier/zerotier_windows_network_manager.h"

#include <sstream>

ZeroTierWindowsNetworkManager::ZeroTierWindowsNetworkManager(
    ZeroTierWindowsRuntime* runtime)
    : runtime_(runtime) {}

flutter::EncodableList ZeroTierWindowsNetworkManager::ListNetworks() const {
  return runtime_ == nullptr ? flutter::EncodableList{} : runtime_->ListNetworks();
}

std::optional<flutter::EncodableMap>
ZeroTierWindowsNetworkManager::GetNetworkDetail(
    const std::string& network_id) const {
  if (runtime_ == nullptr) {
    return std::nullopt;
  }
  return runtime_->GetNetworkDetail(ParseNetworkId(network_id));
}

bool ZeroTierWindowsNetworkManager::JoinNetworkAndWaitForIp(
    const std::string& network_id, int timeout_ms, std::string* error_message) {
  if (runtime_ == nullptr) {
    if (error_message != nullptr) {
      *error_message = "ZeroTier runtime is unavailable.";
    }
    return false;
  }
  const uint64_t parsed_network_id = ParseNetworkId(network_id);
  if (parsed_network_id == 0) {
    if (error_message != nullptr) {
      *error_message = "ZeroTier network id is invalid.";
    }
    return false;
  }
  return runtime_->JoinNetworkAndWaitForIp(parsed_network_id, timeout_ms,
                                           error_message);
}

bool ZeroTierWindowsNetworkManager::LeaveNetwork(const std::string& network_id,
                                                 const std::string& source,
                                                 std::string* error_message) {
  if (runtime_ == nullptr) {
    if (error_message != nullptr) {
      *error_message = "ZeroTier runtime is unavailable.";
    }
    return false;
  }
  const uint64_t parsed_network_id = ParseNetworkId(network_id);
  if (parsed_network_id == 0) {
    if (error_message != nullptr) {
      *error_message = "ZeroTier network id is invalid.";
    }
    return false;
  }
  return runtime_->LeaveNetwork(parsed_network_id, source, error_message);
}

uint64_t ZeroTierWindowsNetworkManager::ParseNetworkId(
    const std::string& network_id) const {
  std::stringstream stream;
  stream << std::hex << network_id;
  uint64_t value = 0;
  stream >> value;
  return value;
}
