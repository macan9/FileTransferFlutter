#ifndef FLUTTER_RUNNER_ZEROTIER_WINDOWS_RUNTIME_H_
#define FLUTTER_RUNNER_ZEROTIER_WINDOWS_RUNTIME_H_

#include <flutter/encodable_value.h>

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "native/zerotier/zerotier_windows_adapter_bridge.h"

struct ZeroTierWindowsNetworkRecord {
  uint64_t network_id = 0;
  std::string network_name;
  std::string status = "UNKNOWN";
  std::vector<std::string> assigned_addresses;
  bool is_authorized = false;
  bool is_connected = false;
};

class ZeroTierWindowsRuntime {
 public:
  using EventCallback = std::function<void(const flutter::EncodableMap&)>;

  ZeroTierWindowsRuntime();

  flutter::EncodableMap DetectStatus();
  flutter::EncodableMap PrepareEnvironment();
  flutter::EncodableMap StartNode();
  flutter::EncodableMap StopNode();

  void SetEventCallback(EventCallback callback);
  void ClearEventCallback();

  bool JoinNetworkAndWaitForIp(uint64_t network_id, int timeout_ms,
                               std::string* error_message);
  bool LeaveNetwork(uint64_t network_id, const std::string& source,
                    std::string* error_message);

  flutter::EncodableList ListNetworks() const;
  std::optional<flutter::EncodableMap> GetNetworkDetail(uint64_t network_id) const;

 private:
  static void HandleLibztEvent(void* message_ptr);

  flutter::EncodableMap BuildStatus() const;
  flutter::EncodableMap BuildEvent(const std::string& type,
                                   const std::string& message = "",
                                   const std::string& network_id = "",
                                   const flutter::EncodableMap& payload =
                                       flutter::EncodableMap{}) const;
  flutter::EncodableMap BuildNetworkMap(
      const ZeroTierWindowsNetworkRecord& network) const;
  flutter::EncodableMap BuildNodeDiagnosticsPayloadLocked(int event_code = 0) const;
  flutter::EncodableMap BuildNetworkDiagnosticsPayloadLocked(
      uint64_t network_id, int event_code = 0,
      const std::string& trigger = "") const;
  flutter::EncodableMap BuildAdapterDiagnosticsPayloadLocked() const;
  uint64_t NextNetworkGenerationLocked(uint64_t network_id);
  void RefreshSnapshot();
  void LoadKnownNetworkIdsLocked();
  void PersistKnownNetworkIdsLocked() const;
  void RememberKnownNetworkLocked(uint64_t network_id);
  void ForgetKnownNetworkLocked(uint64_t network_id);
  std::string BuildServiceState() const;
  void SetLastErrorLocked(const std::string& message);
  void ClearLastErrorLocked();

  bool EnsurePrepared(std::string* error_message);
  bool EnsureNodeReady(std::string* error_message);
  void ProcessEvent(void* message_ptr);
  void UpdateNetworkFromLibztMessage(const void* message_ptr);
  void UpdateAddressFromLibztMessage(const void* message_ptr);
  void EmitEvent(const flutter::EncodableMap& event) const;
  void EmitError(const std::string& message,
                 const std::string& network_id = "");

  std::string RuntimeRootPath() const;
  std::string NodeStoragePath() const;
  std::string LogsPath() const;
  std::string KnownNetworksPath() const;
  std::string ToHexNetworkId(uint64_t network_id) const;

  mutable std::mutex mutex_;
  mutable std::recursive_mutex api_mutex_;
  mutable std::condition_variable state_cv_;
  std::map<uint64_t, ZeroTierWindowsNetworkRecord> networks_;
  std::set<uint64_t> pending_join_networks_;
  std::set<uint64_t> leaving_networks_;
  std::set<uint64_t> known_network_ids_;
  std::map<uint64_t, std::string> leave_request_sources_;
  std::map<uint64_t, uint64_t> network_generations_;
  std::map<uint64_t, uint64_t> pending_leave_generations_;
  EventCallback event_callback_;
  std::string last_error_;
  std::string storage_path_;
  std::string logs_path_;
  uint64_t node_id_ = 0;
  int node_port_ = 0;
  bool environment_prepared_ = false;
  bool known_network_ids_loaded_ = false;
  bool handler_registered_ = false;
  bool node_started_ = false;
  bool node_online_ = false;
  bool node_offline_ = false;
  bool stop_requested_ = false;
  uint64_t next_network_generation_ = 0;
  int major_version_ = 0;
  int minor_version_ = 0;
  ZeroTierWindowsAdapterBridge adapter_bridge_;
  ZeroTierWindowsAdapterBridge::ProbeResult adapter_probe_;
};

#endif  // FLUTTER_RUNNER_ZEROTIER_WINDOWS_RUNTIME_H_
