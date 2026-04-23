#ifndef FLUTTER_RUNNER_ZEROTIER_WINDOWS_ADAPTER_BRIDGE_H_
#define FLUTTER_RUNNER_ZEROTIER_WINDOWS_ADAPTER_BRIDGE_H_

#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <vector>

class ZeroTierWindowsAdapterBridge {
 public:
  struct AdapterRecord {
    std::string adapter_name;
    std::string friendly_name;
    std::string description;
    uint32_t if_index = 0;
    uint64_t luid = 0;
    std::string oper_status = "unknown";
    bool is_up = false;
    bool is_virtual = false;
    bool is_mount_candidate = false;
    bool matches_expected_ip = false;
    bool has_expected_route = false;
    std::string driver_kind = "unknown";
    std::string media_status = "unknown";
    std::string netcfg_instance_id;
    std::string device_instance_id;
    std::string driver_service_name;
    std::vector<std::string> ipv4_addresses;
    std::map<std::string, uint8_t> ipv4_prefix_lengths;
  };

  struct ProbeResult {
    bool initialized = false;
    bool has_virtual_adapter = false;
    bool has_mount_candidate = false;
    bool has_expected_network_ip = false;
    bool has_expected_route = false;
    std::vector<std::string> virtual_adapter_names;
    std::vector<std::string> matched_adapter_names;
    std::vector<std::string> mount_candidate_names;
    std::vector<std::string> detected_ipv4_addresses;
    std::vector<std::string> expected_ipv4_addresses;
    std::vector<AdapterRecord> adapters;
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
