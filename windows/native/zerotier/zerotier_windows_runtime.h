#ifndef FLUTTER_RUNNER_ZEROTIER_WINDOWS_RUNTIME_H_
#define FLUTTER_RUNNER_ZEROTIER_WINDOWS_RUNTIME_H_

#include <flutter/encodable_value.h>

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "native/zerotier/zerotier_windows_adapter_bridge.h"
#include "native/zerotier/zerotier_windows_tap_backend.h"

struct ZeroTierWindowsNetworkRecord {
  uint64_t network_id = 0;
  std::string network_name;
  std::string status = "UNKNOWN";
  std::vector<std::string> assigned_addresses;
  bool is_authorized = false;
  bool is_connected = false;
  bool local_interface_ready = false;
  std::string matched_interface_name;
  uint32_t matched_interface_if_index = 0;
  bool matched_interface_up = false;
  std::string mount_driver_kind = "unknown";
  std::vector<std::string> mount_candidate_names;
  int expected_route_count = 0;
  bool route_expected = false;
  bool system_ip_bound = false;
  bool system_route_bound = false;
  std::string tap_media_status = "unknown";
  std::string tap_device_instance_id;
  std::string tap_netcfg_instance_id;
  std::string local_mount_state = "unknown";
  int last_event_code = 0;
  std::string last_event_name;
  std::string last_event_at_utc;
  int last_event_status_code = 0;
  int last_event_network_type = 0;
  int last_event_netconf_rev = 0;
  int last_event_assigned_addr_count = 0;
  int last_event_transport_ready = 0;
  int last_probe_status_code = 0;
  std::string last_probe_at_utc;
  int last_probe_transport_ready = 0;
  int last_probe_addr_result = 0;
  std::string last_probe_addr_result_name;
  int last_probe_assigned_addr_count = 0;
  int last_probe_network_type = 0;
  bool last_probe_pending_join = false;
  std::string join_trace_started_at_utc;
  std::string join_event_sequence;
  bool join_saw_req_config = false;
  bool join_saw_ready_ip4 = false;
  bool join_saw_ready_ip6 = false;
  bool join_saw_ready_ip4_ip6 = false;
  bool join_saw_network_ok = false;
  bool join_saw_network_down = false;
  bool join_saw_addr_added_ip4 = false;
  bool join_saw_addr_added_ip6 = false;
  bool join_trace_active = false;
};

class ZeroTierWindowsRuntime {
 public:
  using EventCallback = std::function<void(const flutter::EncodableMap&)>;

  ZeroTierWindowsRuntime();
  ~ZeroTierWindowsRuntime();

  flutter::EncodableMap DetectStatus();
  flutter::EncodableMap PrepareEnvironment();
  flutter::EncodableMap StartNode();
  flutter::EncodableMap StopNode();
  void ShutdownForProcessExit();

  void SetEventCallback(EventCallback callback);
  void ClearEventCallback();

  bool JoinNetworkAndWaitForIp(uint64_t network_id, int timeout_ms,
                               bool allow_mount_degraded,
                               std::string* error_message);
  bool LeaveNetwork(uint64_t network_id, const std::string& source,
                    std::string* error_message);

  flutter::EncodableList ListNetworks() const;
  std::optional<flutter::EncodableMap> GetNetworkDetail(uint64_t network_id) const;
  flutter::EncodableMap ProbeNetworkStateNow(uint64_t network_id);

 private:
  struct MountedSystemRoute {
    uint32_t if_index = 0;
    uint32_t destination_ipv4 = 0;  // network order
    uint8_t prefix_length = 0;
  };
  struct MountedSystemIp {
    uint32_t if_index = 0;
    uint32_t address_ipv4 = 0;  // network order
    uint8_t prefix_length = 0;
    uint32_t nte_context = 0;
  };

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
  void SetLastNodeControlHintLocked(const std::string& hint);
  std::string DescribeNodeTriggerLocked(const std::string& event_name) const;
  std::string SummarizeTrackedNetworksLocked() const;
  std::string BuildTransportDiagnosticsSummaryLocked() const;
  std::string BuildRecentPeerDiagnosticsLocked() const;
  std::string BuildLiveNetworkProbeSummary(uint64_t network_id) const;
  std::string BuildServiceState() const;
  void SetLastErrorLocked(const std::string& message);
  void ClearLastErrorLocked();

  bool EnsurePrepared(std::string* error_message);
  bool EnsureNodeReady(std::string* error_message);
  void PruneKnownNetworksForJoin(uint64_t target_network_id);
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
  std::string ExpectedWintunAdapterNameForNetwork(uint64_t network_id) const;
  bool TryMountSystemRoutesForNetwork(
      uint64_t network_id, const ZeroTierWindowsNetworkRecord& record,
      const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter,
      const std::map<std::string, uint8_t>& managed_prefix_hints,
      std::vector<MountedSystemRoute>* created_routes,
      std::vector<MountedSystemRoute>* confirmed_routes);
  bool TryBindSystemIpForNetwork(
      uint64_t network_id, const ZeroTierWindowsNetworkRecord& record,
      const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter,
      const std::map<std::string, uint8_t>& managed_prefix_hints,
      std::vector<MountedSystemIp>* created_ips);
  void CleanupStaleSystemIpStateForNetwork(
      uint64_t network_id, const ZeroTierWindowsNetworkRecord& record,
      const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter,
      const std::map<std::string, uint8_t>& managed_prefix_hints);
  void CleanupManagedIpv4OnForeignAdaptersForNetwork(
      uint64_t network_id, const ZeroTierWindowsNetworkRecord& record,
      const ZeroTierWindowsAdapterBridge::AdapterRecord& selected_adapter,
      const std::vector<ZeroTierWindowsAdapterBridge::AdapterRecord>& adapters,
      const std::map<std::string, uint8_t>& managed_prefix_hints);
  void RecordMountedSystemRoutesLocked(
      uint64_t network_id, const std::vector<MountedSystemRoute>& created_routes);
  void RecordConfirmedSystemRoutesLocked(
      uint64_t network_id,
      const std::vector<MountedSystemRoute>& confirmed_routes);
  void RecordMountedSystemIpsLocked(
      uint64_t network_id, const std::vector<MountedSystemIp>& created_ips);
  void RemoveMountedSystemRoutesForNetwork(uint64_t network_id,
                                           const std::string& source);
  void RemoveMountedSystemIpsForNetwork(uint64_t network_id,
                                        const std::string& source);

  mutable std::mutex mutex_;
  mutable std::recursive_mutex api_mutex_;
  mutable std::condition_variable state_cv_;
  std::map<uint64_t, ZeroTierWindowsNetworkRecord> networks_;
  std::set<uint64_t> pending_join_networks_;
  std::set<uint64_t> leaving_networks_;
  std::set<uint64_t> known_network_ids_;
  std::map<uint64_t, std::string> leave_request_sources_;
  std::map<uint64_t, std::vector<MountedSystemIp>> mounted_system_ips_;
  std::map<uint64_t, std::vector<MountedSystemRoute>> mounted_system_routes_;
  std::map<uint64_t, std::vector<MountedSystemRoute>> confirmed_system_routes_;
  std::map<uint64_t, uint64_t> network_generations_;
  std::map<uint64_t, uint64_t> pending_leave_generations_;
  std::set<uint64_t> observed_peer_ids_;
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
  bool suppress_libzt_events_ = false;
  uint64_t next_network_generation_ = 0;
  int major_version_ = 0;
  int minor_version_ = 0;
  std::string last_node_control_hint_ = "runtime.init";
  std::string last_node_control_at_utc_;
  ZeroTierWindowsAdapterBridge adapter_bridge_;
  ZeroTierWindowsAdapterBridge::ProbeResult adapter_probe_;
  std::unique_ptr<ZeroTierWindowsTapBackend> tap_backend_;
  std::string tap_backend_id_ = "wintun";
};

#endif  // FLUTTER_RUNNER_ZEROTIER_WINDOWS_RUNTIME_H_
