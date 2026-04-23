#include "native/zerotier/zerotier_windows_adapter_bridge.h"

#include <WinSock2.h>
#include <Windows.h>
#include <iphlpapi.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <set>
#include <sstream>
#include <vector>

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")

namespace {

std::string ToLower(std::string text) {
  std::transform(text.begin(), text.end(), text.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return text;
}

std::string Trim(const std::string& text) {
  size_t begin = 0;
  while (begin < text.size() && std::isspace(static_cast<unsigned char>(text[begin])) != 0) {
    ++begin;
  }
  size_t end = text.size();
  while (end > begin &&
         std::isspace(static_cast<unsigned char>(text[end - 1])) != 0) {
    --end;
  }
  return text.substr(begin, end - begin);
}

std::string WideToUtf8(const wchar_t* text) {
  if (text == nullptr || *text == L'\0') {
    return "";
  }
  const int required = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0,
                                           nullptr, nullptr);
  if (required <= 1) {
    return "";
  }
  std::string result(static_cast<size_t>(required), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, result.data(), required, nullptr,
                      nullptr);
  result.pop_back();
  return result;
}

bool ContainsSubstring(const std::string& text,
                       std::initializer_list<const char*> needles) {
  for (const char* needle : needles) {
    if (needle == nullptr || *needle == '\0') {
      continue;
    }
    if (text.find(needle) != std::string::npos) {
      return true;
    }
  }
  return false;
}

std::string AdapterDisplayName(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& record) {
  if (!record.friendly_name.empty()) {
    return record.friendly_name;
  }
  if (!record.description.empty()) {
    return record.description;
  }
  return record.adapter_name;
}

bool LooksLikeMountCandidateAdapter(const std::string& text) {
  const std::string lowered = ToLower(text);
  if (lowered.empty()) {
    return false;
  }
  if (ContainsSubstring(lowered,
                        {"vmware", "hyper-v", "vethernet", "virtualbox",
                         "bluetooth", "loopback", "pseudo-interface"})) {
    return false;
  }
  return ContainsSubstring(
      lowered, {"zerotier", "libzt", "tap-windows", "tap windows",
                "tap-windows adapter", "tap adapter", "wintun",
                "wireguard", "openvpn", "filetransferflutter"});
}

bool LooksLikeVirtualAdapter(const std::string& text) {
  const std::string lowered = ToLower(text);
  return LooksLikeMountCandidateAdapter(lowered);
}

std::string OperStatusToString(IF_OPER_STATUS status) {
  switch (status) {
    case IfOperStatusUp:
      return "up";
    case IfOperStatusDown:
      return "down";
    case IfOperStatusTesting:
      return "testing";
    case IfOperStatusUnknown:
      return "unknown";
    case IfOperStatusDormant:
      return "dormant";
    case IfOperStatusNotPresent:
      return "not_present";
    case IfOperStatusLowerLayerDown:
      return "lower_layer_down";
    default:
      return "unknown";
  }
}

std::string Join(const std::vector<std::string>& values) {
  if (values.empty()) {
    return "-";
  }
  std::ostringstream stream;
  for (size_t i = 0; i < values.size(); ++i) {
    if (i > 0) {
      stream << ",";
    }
    stream << values[i];
  }
  return stream.str();
}

std::string NormalizeGuidToken(const std::string& token) {
  if (token.empty()) {
    return "";
  }
  std::string result;
  result.reserve(token.size());
  for (char ch : token) {
    if (ch == '{' || ch == '}') {
      continue;
    }
    result.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(ch))));
  }
  return result;
}

std::string BracedGuid(const std::string& guid) {
  if (guid.empty()) {
    return "";
  }
  return "{" + guid + "}";
}

std::string ReadRegistryStringValue(HKEY root_key, const std::string& sub_key,
                                    const char* value_name) {
  if (value_name == nullptr || sub_key.empty()) {
    return "";
  }
  char buffer[1024] = {0};
  DWORD type = 0;
  DWORD data_size = static_cast<DWORD>(sizeof(buffer) - 1);
  const LONG result = RegGetValueA(root_key, sub_key.c_str(), value_name,
                                   RRF_RT_REG_SZ, &type, buffer, &data_size);
  if (result != ERROR_SUCCESS) {
    return "";
  }
  buffer[sizeof(buffer) - 1] = '\0';
  return Trim(buffer);
}

std::string ClassifyDriverKind(const std::string& friendly_name,
                               const std::string& description,
                               const std::string& adapter_name,
                               const std::string& device_instance_id,
                               const std::string& driver_service_name) {
  const std::string merged =
      ToLower(friendly_name + " " + description + " " + adapter_name + " " +
              device_instance_id + " " + driver_service_name);
  if (ContainsSubstring(merged, {"zerotier"})) {
    return "zerotier";
  }
  if (ContainsSubstring(merged, {"tap-windows", "tap windows", "tap adapter"})) {
    return "tap-windows";
  }
  if (ContainsSubstring(merged, {"wintun"})) {
    return "wintun";
  }
  if (ContainsSubstring(merged, {"filetransferflutter"})) {
    return "wintun";
  }
  if (ContainsSubstring(merged, {"wireguard"})) {
    return "wireguard";
  }
  if (ContainsSubstring(merged, {"openvpn"})) {
    return "openvpn";
  }
  if (ContainsSubstring(merged, {"hyper-v", "vethernet", "vmware", "virtualbox"})) {
    return "hypervisor-virtual";
  }
  if (ContainsSubstring(merged, {"ethernet"})) {
    return "ethernet";
  }
  return "unknown";
}

void LoadAdapterRegistryMetadata(ZeroTierWindowsAdapterBridge::AdapterRecord* record) {
  if (record == nullptr) {
    return;
  }
  const std::string guid = NormalizeGuidToken(record->adapter_name);
  if (guid.empty()) {
    return;
  }
  record->netcfg_instance_id = BracedGuid(guid);
  const std::string connection_key =
      "SYSTEM\\CurrentControlSet\\Control\\Network\\{4D36E972-E325-11CE-BFC1-08002BE10318}\\" +
      record->netcfg_instance_id + "\\Connection";
  const std::string pnp_instance_id =
      ReadRegistryStringValue(HKEY_LOCAL_MACHINE, connection_key, "PnpInstanceID");
  if (!pnp_instance_id.empty()) {
    record->device_instance_id = pnp_instance_id;
    const std::string enum_key =
        "SYSTEM\\CurrentControlSet\\Enum\\" + pnp_instance_id;
    const std::string service_name =
        ReadRegistryStringValue(HKEY_LOCAL_MACHINE, enum_key, "Service");
    if (!service_name.empty()) {
      record->driver_service_name = service_name;
    }
  }
}

bool AdapterHasExpectedRoute(uint32_t if_index,
                             const std::set<std::string>& expected_ipv4_set) {
  if (if_index == 0 || expected_ipv4_set.empty()) {
    return false;
  }
  std::vector<uint32_t> expected_ips_network_order;
  expected_ips_network_order.reserve(expected_ipv4_set.size());
  for (const auto& expected : expected_ipv4_set) {
    in_addr address = {};
    if (inet_pton(AF_INET, expected.c_str(), &address) == 1) {
      expected_ips_network_order.push_back(address.S_un.S_addr);
    }
  }
  if (expected_ips_network_order.empty()) {
    return false;
  }

  ULONG route_table_size = 0;
  if (GetIpForwardTable(nullptr, &route_table_size, FALSE) != ERROR_INSUFFICIENT_BUFFER) {
    return false;
  }
  std::vector<unsigned char> route_table_buffer(route_table_size);
  MIB_IPFORWARDTABLE* route_table =
      reinterpret_cast<MIB_IPFORWARDTABLE*>(route_table_buffer.data());
  if (GetIpForwardTable(route_table, &route_table_size, FALSE) != NO_ERROR) {
    return false;
  }

  bool found = false;
  for (DWORD index = 0; index < route_table->dwNumEntries && !found; ++index) {
    const MIB_IPFORWARDROW& route = route_table->table[index];
    if (route.dwForwardIfIndex != if_index) {
      continue;
    }
    // Skip default route; it is too broad for "managed route bound" probing.
    if (route.dwForwardMask == 0) {
      continue;
    }
    for (const uint32_t ip_network_order : expected_ips_network_order) {
      if ((ip_network_order & route.dwForwardMask) ==
          (route.dwForwardDest & route.dwForwardMask)) {
        found = true;
        break;
      }
    }
  }
  return found;
}

bool AppendIpv4Address(const IP_ADAPTER_UNICAST_ADDRESS* address,
                       std::vector<std::string>* output,
                       std::map<std::string, uint8_t>* prefix_lengths) {
  if (address == nullptr || address->Address.lpSockaddr == nullptr ||
      output == nullptr || prefix_lengths == nullptr) {
    return false;
  }
  if (address->Address.lpSockaddr->sa_family != AF_INET) {
    return false;
  }
  char buffer[INET_ADDRSTRLEN] = {0};
  const sockaddr_in* ipv4 =
      reinterpret_cast<const sockaddr_in*>(address->Address.lpSockaddr);
  const PCSTR result = inet_ntop(AF_INET, &(ipv4->sin_addr), buffer,
                                 static_cast<DWORD>(sizeof(buffer)));
  if (result == nullptr || buffer[0] == '\0') {
    return false;
  }
  output->push_back(buffer);
  uint8_t prefix_length = address->OnLinkPrefixLength;
  if (prefix_length > 32) {
    prefix_length = 32;
  }
  (*prefix_lengths)[buffer] = prefix_length;
  return true;
}

}  // namespace

bool ZeroTierWindowsAdapterBridge::Initialize(std::string* error_message) {
  const ProbeResult probe = Probe({});
  {
    std::scoped_lock lock(mutex_);
    last_probe_ = probe;
    last_probe_.initialized = true;
  }
  if (error_message != nullptr) {
    error_message->clear();
  }
  return true;
}

ZeroTierWindowsAdapterBridge::ProbeResult ZeroTierWindowsAdapterBridge::Refresh(
    const std::vector<std::string>& expected_ipv4_addresses) {
  ProbeResult probe = Probe(expected_ipv4_addresses);
  {
    std::scoped_lock lock(mutex_);
    probe.initialized = last_probe_.initialized;
    last_probe_ = probe;
  }
  return probe;
}

ZeroTierWindowsAdapterBridge::ProbeResult ZeroTierWindowsAdapterBridge::LastProbe() const {
  std::scoped_lock lock(mutex_);
  return last_probe_;
}

ZeroTierWindowsAdapterBridge::ProbeResult ZeroTierWindowsAdapterBridge::Probe(
    const std::vector<std::string>& expected_ipv4_addresses) const {
  ProbeResult result;
  result.expected_ipv4_addresses = expected_ipv4_addresses;
  std::set<std::string> expected_set;
  for (const auto& address : expected_ipv4_addresses) {
    const std::string trimmed = Trim(address);
    if (!trimmed.empty()) {
      expected_set.insert(trimmed);
    }
  }

  ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_INCLUDE_ALL_INTERFACES;
  ULONG buffer_size = 15 * 1024;
  std::vector<unsigned char> buffer(buffer_size);
  DWORD api_result = GetAdaptersAddresses(
      AF_UNSPEC, flags, nullptr,
      reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data()), &buffer_size);
  if (api_result == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(buffer_size);
    api_result = GetAdaptersAddresses(
        AF_UNSPEC, flags, nullptr,
        reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data()), &buffer_size);
  }
  if (api_result != NO_ERROR) {
    std::ostringstream summary;
    summary << "GetAdaptersAddresses failed: " << api_result;
    result.summary = summary.str();
    return result;
  }

  std::set<std::string> detected_ip_set;
  std::vector<std::string> matched_adapters;
  std::vector<std::string> mount_candidate_adapters;
  for (PIP_ADAPTER_ADDRESSES adapter =
           reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());
       adapter != nullptr; adapter = adapter->Next) {
    ZeroTierWindowsAdapterBridge::AdapterRecord record;
    record.adapter_name = adapter->AdapterName == nullptr ? "" : adapter->AdapterName;
    record.friendly_name = WideToUtf8(adapter->FriendlyName);
    record.description = WideToUtf8(adapter->Description);
    record.if_index = adapter->IfIndex;
    record.luid = adapter->Luid.Value;
    record.oper_status = OperStatusToString(adapter->OperStatus);
    record.media_status = record.oper_status;
    record.is_up = adapter->OperStatus == IfOperStatusUp;
    LoadAdapterRegistryMetadata(&record);
    record.driver_kind =
        ClassifyDriverKind(record.friendly_name, record.description,
                           record.adapter_name, record.device_instance_id,
                           record.driver_service_name);
    record.is_mount_candidate =
        LooksLikeMountCandidateAdapter(record.friendly_name) ||
        LooksLikeMountCandidateAdapter(record.description) ||
        LooksLikeMountCandidateAdapter(record.adapter_name) ||
        LooksLikeMountCandidateAdapter(record.device_instance_id) ||
        LooksLikeMountCandidateAdapter(record.driver_service_name);
    record.is_virtual =
        LooksLikeVirtualAdapter(record.friendly_name) ||
        LooksLikeVirtualAdapter(record.description) ||
        LooksLikeVirtualAdapter(record.adapter_name);

    for (IP_ADAPTER_UNICAST_ADDRESS* unicast = adapter->FirstUnicastAddress;
         unicast != nullptr; unicast = unicast->Next) {
      AppendIpv4Address(unicast, &record.ipv4_addresses,
                        &record.ipv4_prefix_lengths);
    }
    for (const auto& address : record.ipv4_addresses) {
      detected_ip_set.insert(address);
      if (expected_set.find(address) != expected_set.end()) {
        record.matches_expected_ip = true;
      }
    }

    if (record.is_virtual) {
      result.has_virtual_adapter = true;
      const std::string display_name = AdapterDisplayName(record);
      if (!display_name.empty()) {
        result.virtual_adapter_names.push_back(display_name);
      }
    }
    if (record.is_mount_candidate) {
      result.has_mount_candidate = true;
      const std::string display_name = AdapterDisplayName(record);
      if (!display_name.empty()) {
        mount_candidate_adapters.push_back(display_name);
      }
    }
    if (record.matches_expected_ip) {
      result.has_expected_network_ip = true;
      record.has_expected_route = AdapterHasExpectedRoute(record.if_index, expected_set);
      result.has_expected_route = result.has_expected_route || record.has_expected_route;
      matched_adapters.push_back(AdapterDisplayName(record));
    }

    if (record.is_virtual || record.is_mount_candidate ||
        record.matches_expected_ip ||
        !record.ipv4_addresses.empty()) {
      result.adapters.push_back(std::move(record));
    }
  }

  result.detected_ipv4_addresses.assign(detected_ip_set.begin(),
                                        detected_ip_set.end());
  std::sort(result.detected_ipv4_addresses.begin(),
            result.detected_ipv4_addresses.end());
  std::sort(result.virtual_adapter_names.begin(), result.virtual_adapter_names.end());
  result.virtual_adapter_names.erase(
      std::unique(result.virtual_adapter_names.begin(),
                  result.virtual_adapter_names.end()),
      result.virtual_adapter_names.end());
  result.mount_candidate_names = std::move(mount_candidate_adapters);
  std::sort(result.mount_candidate_names.begin(), result.mount_candidate_names.end());
  result.mount_candidate_names.erase(
      std::unique(result.mount_candidate_names.begin(),
                  result.mount_candidate_names.end()),
      result.mount_candidate_names.end());
  result.matched_adapter_names = matched_adapters;
  std::sort(result.matched_adapter_names.begin(), result.matched_adapter_names.end());
  result.matched_adapter_names.erase(
      std::unique(result.matched_adapter_names.begin(),
                  result.matched_adapter_names.end()),
      result.matched_adapter_names.end());

  std::ostringstream summary;
  summary << "virtual_adapter=" << (result.has_virtual_adapter ? "true" : "false")
          << " mount_candidate="
          << (result.has_mount_candidate ? "true" : "false")
          << " expected_ip_bound="
          << (result.has_expected_network_ip ? "true" : "false")
          << " expected_route_bound="
          << (result.has_expected_route ? "true" : "false")
          << " expected_ips=" << Join(result.expected_ipv4_addresses)
          << " matched_adapters=" << Join(result.matched_adapter_names)
          << " mount_candidates=" << Join(result.mount_candidate_names)
          << " virtual_names=" << Join(result.virtual_adapter_names)
          << " detected_ips=" << Join(result.detected_ipv4_addresses)
          << " adapter_records=" << result.adapters.size();
  result.summary = summary.str();
  return result;
}
