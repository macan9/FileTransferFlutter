#include "native/zerotier/zerotier_windows_runtime.h"

#include <chrono>
#include <exception>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <iomanip>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

using EncodableList = flutter::EncodableList;
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;

std::string ReadString(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end() || !std::holds_alternative<std::string>(it->second)) {
    return "";
  }
  return std::get<std::string>(it->second);
}

bool ReadBool(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) {
    return false;
  }
  if (std::holds_alternative<bool>(it->second)) {
    return std::get<bool>(it->second);
  }
  return false;
}

EncodableList ReadList(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end() || !std::holds_alternative<EncodableList>(it->second)) {
    return EncodableList{};
  }
  return std::get<EncodableList>(it->second);
}

std::optional<EncodableMap> ReadMap(const EncodableValue& value) {
  if (!std::holds_alternative<EncodableMap>(value)) {
    return std::nullopt;
  }
  return std::get<EncodableMap>(value);
}

std::optional<EncodableMap> FindNetworkById(const EncodableMap& status,
                                            const std::string& network_id) {
  const EncodableList networks = ReadList(status, "joinedNetworks");
  for (const auto& item : networks) {
    const std::optional<EncodableMap> network = ReadMap(item);
    if (!network.has_value()) {
      continue;
    }
    if (ReadString(*network, "networkId") == network_id) {
      return network;
    }
  }
  return std::nullopt;
}

std::string ReadPrintable(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) {
    return "";
  }
  if (std::holds_alternative<std::string>(it->second)) {
    return std::get<std::string>(it->second);
  }
  if (std::holds_alternative<int32_t>(it->second)) {
    return std::to_string(std::get<int32_t>(it->second));
  }
  if (std::holds_alternative<int64_t>(it->second)) {
    return std::to_string(std::get<int64_t>(it->second));
  }
  if (std::holds_alternative<bool>(it->second)) {
    return std::get<bool>(it->second) ? "true" : "false";
  }
  return "";
}

std::string FormatUtcNow() {
  const auto now = std::chrono::system_clock::now();
  const std::time_t now_time = std::chrono::system_clock::to_time_t(now);
  std::tm utc_tm{};
#if defined(_WIN32)
  gmtime_s(&utc_tm, &now_time);
#else
  gmtime_r(&now_time, &utc_tm);
#endif
  std::ostringstream stream;
  stream << std::put_time(&utc_tm, "%Y-%m-%dT%H:%M:%SZ");
  return stream.str();
}

std::string SummarizeNetworkIds(const EncodableMap& status) {
  const EncodableList networks = ReadList(status, "joinedNetworks");
  if (networks.empty()) {
    return "-";
  }
  std::ostringstream stream;
  bool first = true;
  for (const auto& item : networks) {
    const std::optional<EncodableMap> network = ReadMap(item);
    if (!network.has_value()) {
      continue;
    }
    const std::string network_id = ReadString(*network, "networkId");
    if (network_id.empty()) {
      continue;
    }
    if (!first) {
      stream << ",";
    }
    stream << network_id;
    first = false;
  }
  return first ? "-" : stream.str();
}

void PrintProbeSummary(const EncodableMap& probe, const std::string& tag) {
  std::cout << "[monitor] ts=" << FormatUtcNow()
            << " tag=" << tag
            << " networkId=" << ReadPrintable(probe, "networkId")
            << " status=" << ReadPrintable(probe, "status")
            << " statusCode=" << ReadPrintable(probe, "statusCode")
            << " transportReady=" << ReadPrintable(probe, "transportReady")
            << " addrResultName=" << ReadPrintable(probe, "addrResultName")
            << " networkName=" << ReadPrintable(probe, "networkNameFromProbe")
            << std::endl;

  const auto runtime_record_it = probe.find(EncodableValue("runtimeRecord"));
  if (runtime_record_it == probe.end()) {
    return;
  }
  const std::optional<EncodableMap> runtime_record =
      ReadMap(runtime_record_it->second);
  if (!runtime_record.has_value()) {
    return;
  }
  std::cout << "[monitor] ts=" << FormatUtcNow()
            << " tag=" << tag << "_runtime"
            << " localMountState="
            << ReadPrintable(*runtime_record, "localMountState")
            << " localInterfaceReady="
            << ReadPrintable(*runtime_record, "localInterfaceReady")
            << " systemIpBound="
            << ReadPrintable(*runtime_record, "systemIpBound")
            << " systemRouteBound="
            << ReadPrintable(*runtime_record, "systemRouteBound")
            << " mountDriverKind="
            << ReadPrintable(*runtime_record, "mountDriverKind")
            << " matchedInterfaceIfIndex="
            << ReadPrintable(*runtime_record, "matchedInterfaceIfIndex")
            << " tapMediaStatus="
            << ReadPrintable(*runtime_record, "tapMediaStatus")
            << " lastEventName="
            << ReadPrintable(*runtime_record, "lastEventName")
            << " lastProbeAddrResultName="
            << ReadPrintable(*runtime_record, "lastProbeAddrResultName")
            << " joinEventSequence="
            << ReadPrintable(*runtime_record, "joinEventSequence")
            << std::endl;
}

void PrintStatus(const EncodableMap& status, const std::string& tag) {
  std::cout << "[smoke] ts=" << FormatUtcNow()
            << " tag=" << tag
            << " serviceState=" << ReadString(status, "serviceState")
            << " nodeId=" << ReadString(status, "nodeId")
            << " isNodeRunning="
            << (ReadBool(status, "isNodeRunning") ? "true" : "false")
            << " joinedNetworks=" << ReadList(status, "joinedNetworks").size()
            << " joinedNetworkIds=" << SummarizeNetworkIds(status)
            << " transport=" << ReadString(status, "transportDiagnostics")
            << " peers=" << ReadString(status, "peerDiagnostics")
            << " lastError=" << ReadString(status, "lastError")
            << std::endl;
}

void PrintMonitorState(const EncodableMap& status, int sample_index,
                       const std::string& phase) {
  std::cout << "[monitor-state] ts=" << FormatUtcNow()
            << " sample=" << sample_index
            << " phase=" << phase
            << " serviceState=" << ReadString(status, "serviceState")
            << " nodeId=" << ReadString(status, "nodeId")
            << " joinedNetworks=" << ReadList(status, "joinedNetworks").size()
            << " transport=" << ReadString(status, "transportDiagnostics")
            << " peers=" << ReadString(status, "peerDiagnostics")
            << " lastError=" << ReadString(status, "lastError")
            << std::endl;
}

}  // namespace

int main() {
  try {
  int join_timeout_ms = 45000;
  int leave_timeout_ms = 30000;
  std::string probe_network_id;
  std::string join_network_id;
  bool require_route_bound = false;
  bool allow_mount_degraded = false;
  bool monitor_until_offline = false;
  bool skip_monitor_probe = false;
  int poll_interval_ms = 1000;
  int max_monitor_seconds = 0;
  for (int index = 1; index < __argc; ++index) {
    const char* argument = __argv[index];
    if (argument == nullptr) {
      continue;
    }
    if (std::strcmp(argument, "--join-timeout-ms") == 0 &&
        index + 1 < __argc) {
      join_timeout_ms = std::max(1000, std::atoi(__argv[++index]));
      continue;
    }
    if (std::strcmp(argument, "--probe-network") == 0 &&
        index + 1 < __argc) {
      probe_network_id = __argv[++index];
      continue;
    }
    if (std::strcmp(argument, "--join-network") == 0 &&
        index + 1 < __argc) {
      join_network_id = __argv[++index];
      continue;
    }
    if (std::strcmp(argument, "--leave-timeout-ms") == 0 &&
        index + 1 < __argc) {
      leave_timeout_ms = std::max(1000, std::atoi(__argv[++index]));
      continue;
    }
    if (std::strcmp(argument, "--require-route-bound") == 0) {
      require_route_bound = true;
      continue;
    }
    if (std::strcmp(argument, "--allow-mount-degraded") == 0) {
      allow_mount_degraded = true;
      continue;
    }
    if (std::strcmp(argument, "--monitor-until-offline") == 0) {
      monitor_until_offline = true;
      continue;
    }
    if (std::strcmp(argument, "--skip-monitor-probe") == 0) {
      skip_monitor_probe = true;
      continue;
    }
    if (std::strcmp(argument, "--poll-interval-ms") == 0 &&
        index + 1 < __argc) {
      poll_interval_ms = std::max(250, std::atoi(__argv[++index]));
      continue;
    }
    if (std::strcmp(argument, "--max-monitor-seconds") == 0 &&
        index + 1 < __argc) {
      max_monitor_seconds = std::max(0, std::atoi(__argv[++index]));
    }
  }

  ZeroTierWindowsRuntime runtime;
  runtime.SetEventCallback([](const EncodableMap& event) {
    std::cout << "[event] type=" << ReadString(event, "type")
              << " networkId=" << ReadString(event, "networkId")
              << " message=" << ReadString(event, "message") << std::endl;
  });

  EncodableMap status = runtime.PrepareEnvironment();
  PrintStatus(status, "prepare");

  status = runtime.StartNode();
  PrintStatus(status, "start");

  for (int attempt = 0; attempt < 20; ++attempt) {
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    status = runtime.DetectStatus();
    if (ReadString(status, "serviceState") == "running") {
      break;
    }
  }
  PrintStatus(status, "detect");

  if (monitor_until_offline && join_network_id.empty() &&
      !probe_network_id.empty()) {
    join_network_id = probe_network_id;
  }

  if (!join_network_id.empty()) {
    std::cout << "[smoke] target network=" << join_network_id << std::endl;
    std::cout << "[smoke] joinTimeoutMs=" << join_timeout_ms << std::endl;

    std::string join_error;
    const bool join_ok = runtime.JoinNetworkAndWaitForIp(
        std::stoull(join_network_id, nullptr, 16), join_timeout_ms,
        allow_mount_degraded, &join_error);
    status = runtime.DetectStatus();
    PrintStatus(status, "post-join-target");
    std::cout << "[smoke] join ok=" << (join_ok ? "true" : "false")
              << " error=" << join_error << std::endl;
    if (!join_ok) {
      return 9;
    }

    const EncodableMap probe = runtime.ProbeNetworkStateNow(
        std::stoull(join_network_id, nullptr, 16));
    const auto runtime_record_it = probe.find(EncodableValue("runtimeRecord"));
    if (runtime_record_it == probe.end()) {
      std::cerr << "[smoke] missing runtimeRecord after join" << std::endl;
      return 10;
    }
    const std::optional<EncodableMap> runtime_record = ReadMap(runtime_record_it->second);
    if (!runtime_record.has_value()) {
      std::cerr << "[smoke] runtimeRecord decode failed" << std::endl;
      return 11;
    }
    const bool system_ip_bound = ReadBool(*runtime_record, "systemIpBound");
    const bool system_route_bound = ReadBool(*runtime_record, "systemRouteBound");
    const std::string local_mount_state = ReadPrintable(*runtime_record, "localMountState");
    std::cout << "[smoke] systemIpBound=" << (system_ip_bound ? "true" : "false")
              << " systemRouteBound=" << (system_route_bound ? "true" : "false")
              << " localMountState=" << local_mount_state
              << " matchedInterfaceIfIndex="
              << ReadPrintable(*runtime_record, "matchedInterfaceIfIndex")
              << " mountDriverKind=" << ReadPrintable(*runtime_record, "mountDriverKind")
              << " routeExpected="
              << ReadPrintable(*runtime_record, "routeExpected")
              << " expectedRouteCount="
              << ReadPrintable(*runtime_record, "expectedRouteCount")
              << " tapMediaStatus=" << ReadPrintable(*runtime_record, "tapMediaStatus")
              << std::endl;
    const bool mount_degraded =
        (local_mount_state == "missing_adapter" ||
         local_mount_state == "awaiting_address" ||
         local_mount_state == "ip_not_bound" ||
         local_mount_state == "route_not_bound");
    if (!system_ip_bound && !(allow_mount_degraded && mount_degraded)) {
      std::cerr << "[smoke] managed IP not bound on system adapter" << std::endl;
      return 12;
    }
    if (require_route_bound && !system_route_bound &&
        !(allow_mount_degraded && mount_degraded)) {
      std::cerr << "[smoke] managed route not bound on system adapter" << std::endl;
      return 13;
    }

    if (monitor_until_offline) {
      probe_network_id = join_network_id;
      std::cout << "[smoke] monitor armed after successful join" << std::endl;
      std::cout << "[smoke] monitor probe network=" << probe_network_id
                << " maxMonitorSeconds=" << max_monitor_seconds
                << " pollIntervalMs=" << poll_interval_ms
                << " skipMonitorProbe="
                << (skip_monitor_probe ? "true" : "false") << std::endl;
      runtime.ClearEventCallback();
      std::cout << "[smoke] event callback disabled before monitor loop"
                << std::endl;
    } else {
      std::string leave_error;
      const bool leave_ok = runtime.LeaveNetwork(
          std::stoull(join_network_id, nullptr, 16), "zt_runtime_smoke_target", &leave_error);
      std::cout << "[smoke] leave ok=" << (leave_ok ? "true" : "false")
                << " error=" << leave_error << std::endl;
      if (!leave_ok) {
        return 14;
      }

      bool left = false;
      const int attempts = std::max(1, leave_timeout_ms / 500);
      for (int attempt = 0; attempt < attempts; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        status = runtime.DetectStatus();
        if (!FindNetworkById(status, join_network_id).has_value()) {
          left = true;
          break;
        }
      }
      PrintStatus(status, "post-leave-target");
      if (!left) {
        std::cerr << "[smoke] network still present after leave timeout" << std::endl;
        return 15;
      }
      std::cout << "[smoke] target join/probe/leave flow passed" << std::endl;
      return 0;
    }
  }

  if (monitor_until_offline) {
    const auto started_at = std::chrono::steady_clock::now();
    int sample_index = 0;
    std::cout << "[smoke] entering monitor loop"
              << " probeNetwork=" << probe_network_id
              << " maxMonitorSeconds=" << max_monitor_seconds
              << std::endl;
    while (true) {
      if (sample_index > 0) {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(poll_interval_ms));
      }
      PrintMonitorState(status, sample_index, "before_detect");
      status = runtime.DetectStatus();
      PrintMonitorState(status, sample_index, "after_detect");
      std::cout << "[monitor] ts=" << FormatUtcNow()
                << " sample=" << sample_index
                << " serviceState=" << ReadString(status, "serviceState")
                << " nodeId=" << ReadString(status, "nodeId")
                << " isNodeRunning="
                << (ReadBool(status, "isNodeRunning") ? "true" : "false")
                << " joinedNetworks=" << ReadList(status, "joinedNetworks").size()
                << " joinedNetworkIds=" << SummarizeNetworkIds(status)
                << " transport=" << ReadString(status, "transportDiagnostics")
                << " peers=" << ReadString(status, "peerDiagnostics")
                << " lastError=" << ReadString(status, "lastError")
                << std::endl;
      if (!probe_network_id.empty() && !skip_monitor_probe) {
        std::cout << "[smoke] probing network " << probe_network_id
                  << " sample=" << sample_index << std::endl;
        const EncodableMap probe =
            runtime.ProbeNetworkStateNow(std::stoull(probe_network_id, nullptr, 16));
        PrintProbeSummary(probe, "probe");
      }

      const std::string service_state = ReadString(status, "serviceState");
      const bool offline_detected =
          service_state == "offline" || service_state == "error";
      if (offline_detected) {
        std::cout << "[monitor] ts=" << FormatUtcNow()
                  << " offline_detected=true"
                  << " serviceState=" << service_state
                  << std::endl;
        if (!probe_network_id.empty() && !skip_monitor_probe) {
          std::cout << "[smoke] collecting offline probe"
                    << " network=" << probe_network_id << std::endl;
          const EncodableMap probe = runtime.ProbeNetworkStateNow(
              std::stoull(probe_network_id, nullptr, 16));
          PrintProbeSummary(probe, "offline_probe");
        }
        return 21;
      }

      if (max_monitor_seconds > 0) {
        const auto elapsed =
            std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - started_at)
                .count();
        if (elapsed >= max_monitor_seconds) {
          std::cout << "[monitor] ts=" << FormatUtcNow()
                    << " max_monitor_reached=true seconds=" << elapsed
                    << std::endl;
          return 0;
        }
      }
      ++sample_index;
    }
  }

  if (!probe_network_id.empty()) {
    const EncodableMap probe =
        runtime.ProbeNetworkStateNow(std::stoull(probe_network_id, nullptr, 16));
    std::cout << "[probe] networkId=" << ReadPrintable(probe, "networkId")
              << " status=" << ReadPrintable(probe, "status")
              << " statusCode=" << ReadPrintable(probe, "statusCode")
              << " transportReady=" << ReadPrintable(probe, "transportReady")
              << " addrResultName=" << ReadPrintable(probe, "addrResultName")
              << " networkNameFromProbe="
              << ReadPrintable(probe, "networkNameFromProbe")
              << std::endl;
    const auto runtime_record_it = probe.find(EncodableValue("runtimeRecord"));
    if (runtime_record_it != probe.end()) {
      const std::optional<EncodableMap> runtime_record =
          ReadMap(runtime_record_it->second);
      if (runtime_record.has_value()) {
        std::cout << "[probe-runtime] localMountState="
                  << ReadPrintable(*runtime_record, "localMountState")
                  << " localInterfaceReady="
                  << ReadPrintable(*runtime_record, "localInterfaceReady")
                  << " mountDriverKind="
                  << ReadPrintable(*runtime_record, "mountDriverKind")
                  << " routeExpected="
                  << ReadPrintable(*runtime_record, "routeExpected")
                  << " expectedRouteCount="
                  << ReadPrintable(*runtime_record, "expectedRouteCount")
                  << " systemIpBound="
                  << ReadPrintable(*runtime_record, "systemIpBound")
                  << " systemRouteBound="
                  << ReadPrintable(*runtime_record, "systemRouteBound")
                  << " tapMediaStatus="
                  << ReadPrintable(*runtime_record, "tapMediaStatus")
                  << " tapDeviceInstanceId="
                  << ReadPrintable(*runtime_record, "tapDeviceInstanceId")
                  << " tapNetCfgInstanceId="
                  << ReadPrintable(*runtime_record, "tapNetCfgInstanceId")
                  << " lastEvent=" << ReadPrintable(*runtime_record, "lastEventName")
                  << " lastEventAddrCount="
                  << ReadPrintable(*runtime_record, "lastEventAssignedAddrCount")
                  << " lastProbeAddrResult="
                  << ReadPrintable(*runtime_record, "lastProbeAddrResultName")
                  << " joinSequence="
                  << ReadPrintable(*runtime_record, "joinEventSequence")
                  << std::endl;
      }
    }
    return 0;
  }

  const EncodableList networks = ReadList(status, "joinedNetworks");
  if (networks.empty()) {
    std::cerr << "[smoke] no joined networks available for leave/join regression"
              << std::endl;
    return 2;
  }

  const std::optional<EncodableMap> first_network = ReadMap(networks.front());
  if (!first_network.has_value()) {
    std::cerr << "[smoke] failed to decode first joined network" << std::endl;
    return 3;
  }
  const std::string network_id = ReadString(*first_network, "networkId");
  if (network_id.empty()) {
    std::cerr << "[smoke] first joined network has empty network id"
              << std::endl;
    return 4;
  }

  std::cout << "[smoke] target network=" << network_id << std::endl;

  std::string leave_error;
  const bool leave_ok =
      runtime.LeaveNetwork(std::stoull(network_id, nullptr, 16),
                           "zt_runtime_smoke", &leave_error);
  std::cout << "[smoke] leave ok=" << (leave_ok ? "true" : "false")
            << " error=" << leave_error << std::endl;
  if (!leave_ok) {
    return 5;
  }

  bool left = false;
  for (int attempt = 0; attempt < 30; ++attempt) {
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    status = runtime.DetectStatus();
    if (!FindNetworkById(status, network_id).has_value()) {
      left = true;
      break;
    }
  }
  PrintStatus(status, "post-leave");
  if (!left) {
    std::cerr << "[smoke] network still present after leave" << std::endl;
    return 6;
  }

  std::cout << "[smoke] joinTimeoutMs=" << join_timeout_ms << std::endl;
  std::string join_error;
  const bool join_ok = runtime.JoinNetworkAndWaitForIp(
      std::stoull(network_id, nullptr, 16), join_timeout_ms,
      allow_mount_degraded, &join_error);
  std::cout << "[smoke] join ok=" << (join_ok ? "true" : "false")
            << " error=" << join_error << std::endl;
  status = runtime.DetectStatus();
  PrintStatus(status, "post-join");
  const std::optional<EncodableMap> joined = FindNetworkById(status, network_id);
  if (!join_ok || !joined.has_value()) {
    std::cerr << "[smoke] join regression failed" << std::endl;
    return 7;
  }

  std::cout << "[smoke] localMountState="
            << ReadString(*joined, "localMountState")
            << " localInterfaceReady="
            << (ReadBool(*joined, "localInterfaceReady") ? "true" : "false")
            << " matchedInterface=" << ReadString(*joined, "matchedInterfaceName")
            << std::endl;
  return ReadBool(*joined, "localInterfaceReady") ? 0 : 8;
  } catch (const std::exception& error) {
    std::cerr << "[smoke] fatal exception=" << error.what() << std::endl;
    return 97;
  } catch (...) {
    std::cerr << "[smoke] fatal exception=unknown" << std::endl;
    return 98;
  }
}
