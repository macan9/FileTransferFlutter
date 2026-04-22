#include "native/zerotier/zerotier_windows_runtime.h"

#include <chrono>
#include <cstring>
#include <cstdint>
#include <iostream>
#include <optional>
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

void PrintStatus(const EncodableMap& status, const std::string& tag) {
  std::cout << "[smoke] " << tag
            << " serviceState=" << ReadString(status, "serviceState")
            << " nodeId=" << ReadString(status, "nodeId")
            << " isNodeRunning="
            << (ReadBool(status, "isNodeRunning") ? "true" : "false")
            << " joinedNetworks=" << ReadList(status, "joinedNetworks").size()
            << " lastError=" << ReadString(status, "lastError")
            << std::endl;
}

}  // namespace

int main() {
  int join_timeout_ms = 45000;
  std::string probe_network_id;
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
      std::stoull(network_id, nullptr, 16), join_timeout_ms, &join_error);
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
}
