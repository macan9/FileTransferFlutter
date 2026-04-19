#ifndef FLUTTER_RUNNER_ZEROTIER_WINDOWS_NETWORK_MANAGER_H_
#define FLUTTER_RUNNER_ZEROTIER_WINDOWS_NETWORK_MANAGER_H_

#include <flutter/encodable_value.h>

#include <optional>
#include <string>

#include "native/zerotier/zerotier_windows_runtime.h"

class ZeroTierWindowsNetworkManager {
 public:
  explicit ZeroTierWindowsNetworkManager(ZeroTierWindowsRuntime* runtime);

  flutter::EncodableList ListNetworks() const;
  std::optional<flutter::EncodableMap> GetNetworkDetail(
      const std::string& network_id) const;
  bool JoinNetworkAndWaitForIp(const std::string& network_id, int timeout_ms,
                               std::string* error_message);
  bool LeaveNetwork(const std::string& network_id, std::string* error_message);

 private:
  uint64_t ParseNetworkId(const std::string& network_id) const;

  ZeroTierWindowsRuntime* runtime_;
};

#endif  // FLUTTER_RUNNER_ZEROTIER_WINDOWS_NETWORK_MANAGER_H_
