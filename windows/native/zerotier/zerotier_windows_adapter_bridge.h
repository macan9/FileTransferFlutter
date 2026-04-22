#ifndef FLUTTER_RUNNER_ZEROTIER_WINDOWS_ADAPTER_BRIDGE_H_
#define FLUTTER_RUNNER_ZEROTIER_WINDOWS_ADAPTER_BRIDGE_H_

#include <mutex>
#include <string>
#include <vector>

class ZeroTierWindowsAdapterBridge {
 public:
  struct ProbeResult {
    bool initialized = false;
    bool has_virtual_adapter = false;
    bool has_expected_network_ip = false;
    std::vector<std::string> virtual_adapter_names;
    std::vector<std::string> detected_ipv4_addresses;
    std::vector<std::string> expected_ipv4_addresses;
    std::string summary;
  };

  ZeroTierWindowsAdapterBridge() = default;

  bool Initialize(std::string* error_message);
  ProbeResult Refresh(const std::vector<std::string>& expected_ipv4_addresses);
  ProbeResult LastProbe() const;

 private:
  ProbeResult Probe(const std::vector<std::string>& expected_ipv4_addresses) const;

  mutable std::mutex mutex_;
  ProbeResult last_probe_;
};

#endif  // FLUTTER_RUNNER_ZEROTIER_WINDOWS_ADAPTER_BRIDGE_H_
