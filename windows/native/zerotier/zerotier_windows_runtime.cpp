#ifdef _WIN32_WINNT
#undef _WIN32_WINNT
#endif
#define _WIN32_WINNT 0x0600

#ifdef WINVER
#undef WINVER
#endif
#define WINVER 0x0600

#ifdef NTDDI_VERSION
#undef NTDDI_VERSION
#endif
#define NTDDI_VERSION 0x06000000

#include <WinSock2.h>
#include <Windows.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <shellapi.h>
#include <ws2tcpip.h>

#include <ZeroTierSockets.h>

#include "native/zerotier/zerotier_windows_runtime.h"

#include "native/zerotier/zerotier_windows_privileged_mount_ipc.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <optional>
#include <sstream>
#include <iostream>
#include <limits>
#include <vector>

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "Shell32.lib")

namespace {

using EncodableList = flutter::EncodableList;
using EncodableMap = flutter::EncodableMap;
using EncodableValue = flutter::EncodableValue;

ZeroTierWindowsRuntime* g_runtime_instance = nullptr;
std::mutex g_runtime_callback_mutex;
std::condition_variable g_runtime_callback_cv;
bool g_runtime_callback_shutting_down = false;
size_t g_runtime_callback_active_count = 0;

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

std::string FormatNetworkIdHex(uint64_t network_id) {
  std::ostringstream stream;
  stream << std::hex << std::nouppercase << network_id;
  return stream.str();
}

std::filesystem::path CurrentExecutablePath() {
  std::wstring buffer(MAX_PATH, L'\0');
  while (true) {
    const DWORD length =
        GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return {};
    }
    if (length < buffer.size() - 1) {
      buffer.resize(length);
      return std::filesystem::path(buffer);
    }
    buffer.resize(buffer.size() * 2);
  }
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

std::string BoolLabel(bool value);

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

std::string PeerRoleToString(zts_peer_role_t role) {
  switch (role) {
    case ZTS_PEER_ROLE_LEAF:
      return "leaf";
    case ZTS_PEER_ROLE_MOON:
      return "moon";
    case ZTS_PEER_ROLE_PLANET:
      return "planet";
    default:
      return "unknown";
  }
}

std::string PeerSummary(const zts_peer_info_t* peer) {
  if (peer == nullptr) {
    return "peer=null";
  }
  std::ostringstream stream;
  stream << "peer_id=" << FormatNetworkIdHex(peer->peer_id)
         << " role=" << PeerRoleToString(peer->role)
         << " latency_ms=" << peer->latency
         << " version=" << peer->ver_major << "."
         << peer->ver_minor << "." << peer->ver_rev
         << " path_count=" << peer->path_count;
  if (peer->path_count > 0) {
    stream << " paths=omitted_live_event";
  }
  return stream.str();
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

std::string ResolveLocalMountState(
    const ZeroTierWindowsNetworkRecord& network,
    bool has_virtual_adapter) {
  if (network.status == "ACCESS_DENIED" ||
      IsTerminalNetworkFailureStatus(network.status)) {
    return "not_ready";
  }
  if (network.assigned_addresses.empty()) {
    if (network.status == "REQUESTING_CONFIGURATION" || network.status == "OK" ||
        network.status == "UNKNOWN") {
      return "awaiting_address";
    }
    return "not_ready";
  }
  if (network.matched_interface_name.empty()) {
    return has_virtual_adapter ? "ip_not_bound" : "missing_adapter";
  }
  if (!network.system_ip_bound) {
    if (!network.matched_interface_up) {
      return "adapter_down";
    }
    return "ip_not_bound";
  }
  if (network.route_expected && !network.system_route_bound) {
    return "route_not_bound";
  }
  return "ready";
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
  if (network.local_mount_state == "ip_not_bound" ||
      network.local_mount_state == "adapter_down" ||
      network.local_mount_state == "missing_adapter" ||
      network.local_mount_state == "route_not_bound") {
    return true;
  }
  return false;
}

bool IsJoinClosedLoopReady(const ZeroTierWindowsNetworkRecord& network,
                           bool allow_mount_degraded) {
  (void)allow_mount_degraded;
  if (network.local_interface_ready) {
    return true;
  }
  if (network.status == "OK" && network.is_authorized && network.is_connected &&
      network.system_ip_bound && !network.assigned_addresses.empty()) {
    return true;
  }
  // On some Windows/Wintun setups, node_online can flap even after
  // network/auth/connect and local mount have converged.
  if (network.status == "OK" && network.is_authorized && network.is_connected &&
      network.local_mount_state == "ready" &&
      !network.assigned_addresses.empty()) {
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

std::string BoolLabel(bool value) {
  return value ? "true" : "false";
}

std::string SummarizeUdpEndpointsForPid(DWORD pid, int expected_port) {
  ULONG table_size = 0;
  DWORD result = GetExtendedUdpTable(nullptr, &table_size, TRUE, AF_INET,
                                     UDP_TABLE_OWNER_PID, 0);
  if (result != ERROR_INSUFFICIENT_BUFFER || table_size == 0) {
    std::ostringstream stream;
    stream << "udp_table_error=" << result;
    return stream.str();
  }

  std::vector<unsigned char> buffer(table_size);
  auto* table =
      reinterpret_cast<MIB_UDPTABLE_OWNER_PID*>(buffer.data());
  result = GetExtendedUdpTable(table, &table_size, TRUE, AF_INET,
                               UDP_TABLE_OWNER_PID, 0);
  if (result != NO_ERROR) {
    std::ostringstream stream;
    stream << "udp_table_error=" << result;
    return stream.str();
  }

  std::vector<std::string> entries;
  bool matched_expected_port = false;
  for (DWORD index = 0; index < table->dwNumEntries; ++index) {
    const auto& row = table->table[index];
    if (row.dwOwningPid != pid) {
      continue;
    }
    IN_ADDR address = {};
    address.S_un.S_addr = row.dwLocalAddr;
    char addr_text[INET_ADDRSTRLEN] = {0};
    inet_ntop(AF_INET, &address, addr_text, sizeof(addr_text));
    const int local_port = ntohs(static_cast<u_short>(row.dwLocalPort));
    matched_expected_port = matched_expected_port || (expected_port > 0 && local_port == expected_port);
    std::ostringstream entry;
    entry << addr_text << ":" << local_port;
    entries.push_back(entry.str());
  }

  if (entries.empty()) {
    return "udp_endpoints=-";
  }
  std::ostringstream stream;
  stream << "udp_endpoints=";
  for (size_t index = 0; index < entries.size(); ++index) {
    if (index > 0) {
      stream << "|";
    }
    stream << entries[index];
  }
  stream << " expected_port=" << expected_port
         << " expected_match=" << BoolLabel(matched_expected_port);
  return stream.str();
}

void LogNodeTrace(const std::string& message) {
  std::clog << "[ZT/NODE] " << Iso8601NowUtc() << " " << message << std::endl;
}

std::optional<uint8_t> ExtractIpv4PrefixLength(const zts_sockaddr_storage& address) {
  const zts_sockaddr* sockaddr =
      reinterpret_cast<const zts_sockaddr*>(&address);
  if (sockaddr->sa_family != ZTS_AF_INET) {
    return std::nullopt;
  }
  const auto* ipv4 = reinterpret_cast<const zts_sockaddr_in*>(&address);
  const uint16_t netmask_bits = ntohs(ipv4->sin_port);
  if (netmask_bits > 32) {
    return std::nullopt;
  }
  return static_cast<uint8_t>(netmask_bits);
}

uint8_t ClampIpv4PrefixLength(uint8_t prefix_length) {
  return prefix_length > 32 ? 32 : prefix_length;
}

uint32_t PrefixMaskNetworkOrder(uint8_t prefix_length) {
  const uint8_t clamped = ClampIpv4PrefixLength(prefix_length);
  if (clamped == 0) {
    return 0;
  }
  const uint32_t mask_host_order = (clamped == 32)
                                       ? 0xFFFFFFFFu
                                       : (0xFFFFFFFFu << (32 - clamped));
  return htonl(mask_host_order);
}

bool ParseIpv4(const std::string& text, in_addr* output) {
  if (output == nullptr || text.empty()) {
    return false;
  }
  in_addr parsed = {};
  if (inet_pton(AF_INET, text.c_str(), &parsed) != 1) {
    return false;
  }
  *output = parsed;
  return true;
}

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (size <= 1) {
    return std::wstring();
  }
  std::wstring output(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, output.data(), size);
  if (!output.empty() && output.back() == L'\0') {
    output.pop_back();
  }
  return output;
}

std::string WideToUtf8(const std::wstring& text) {
  if (text.empty()) {
    return std::string();
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 1) {
    return std::string();
  }
  std::string output(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, output.data(), size, nullptr,
                      nullptr);
  if (!output.empty() && output.back() == '\0') {
    output.pop_back();
  }
  return output;
}

std::wstring EscapePowerShellSingleQuotedLiteral(const std::wstring& input) {
  std::wstring escaped;
  escaped.reserve(input.size() + 8);
  for (const wchar_t ch : input) {
    escaped.push_back(ch);
    if (ch == L'\'') {
      escaped.push_back(L'\'');
    }
  }
  return escaped;
}

std::wstring EscapePowerShellSingleQuotedLiteral(const std::string& input) {
  return EscapePowerShellSingleQuotedLiteral(Utf8ToWide(input));
}

std::string GuidToString(const GUID& guid) {
  char text[64] = {0};
  std::snprintf(text, sizeof(text),
                "{%08lX-%04hX-%04hX-%02hhX%02hhX-%02hhX%02hhX%02hhX%02hhX%02hhX%02hhX}",
                guid.Data1, guid.Data2, guid.Data3, guid.Data4[0],
                guid.Data4[1], guid.Data4[2], guid.Data4[3], guid.Data4[4],
                guid.Data4[5], guid.Data4[6], guid.Data4[7]);
  return text;
}

struct AdapterBindingProbe {
  bool found = false;
  uint32_t if_index = 0;
  uint64_t luid = 0;
  std::string alias;
  std::string interface_guid;
  std::string adapter_name;
  std::string description;
};

AdapterBindingProbe ProbeAdapterBinding(uint32_t if_index) {
  AdapterBindingProbe probe;
  probe.if_index = if_index;
  ULONG size = 0;
  if (GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_ALL_INTERFACES, nullptr,
                           nullptr, &size) != ERROR_BUFFER_OVERFLOW) {
    return probe;
  }
  std::vector<unsigned char> buffer(size);
  IP_ADAPTER_ADDRESSES* addrs =
      reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  if (GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_ALL_INTERFACES, nullptr,
                           addrs, &size) != NO_ERROR) {
    return probe;
  }
  for (const IP_ADAPTER_ADDRESSES* adapter = addrs; adapter != nullptr;
       adapter = adapter->Next) {
    if (adapter->IfIndex != if_index) {
      continue;
    }
    probe.found = true;
    probe.luid = adapter->Luid.Value;
    probe.alias = WideToUtf8(adapter->FriendlyName == nullptr
                                 ? std::wstring()
                                 : std::wstring(adapter->FriendlyName));
    probe.adapter_name = adapter->AdapterName == nullptr ? "" : adapter->AdapterName;
    probe.description = WideToUtf8(adapter->Description == nullptr
                                       ? std::wstring()
                                       : std::wstring(adapter->Description));
    GUID interface_guid = {};
    if (ConvertInterfaceLuidToGuid(&adapter->Luid, &interface_guid) == NO_ERROR) {
      probe.interface_guid = GuidToString(interface_guid);
    }
    return probe;
  }
  return probe;
}

void AppendAdapterBindingScript(std::wostringstream* script, uint32_t if_index,
                                const AdapterBindingProbe& probe) {
  if (script == nullptr) {
    return;
  }
  *script << L"Write-Output 'TRACE=adapter_binding_probe_start'; "
          << L"Write-Output 'GAA_FOUND=" << (probe.found ? L"true" : L"false")
          << L"'; "
          << L"Write-Output 'GAA_IFINDEX=" << probe.if_index << L"'; "
          << L"Write-Output 'GAA_LUID=" << probe.luid << L"'; "
          << L"Write-Output 'GAA_ALIAS="
          << EscapePowerShellSingleQuotedLiteral(probe.alias) << L"'; "
          << L"Write-Output 'GAA_INTERFACE_GUID="
          << EscapePowerShellSingleQuotedLiteral(probe.interface_guid) << L"'; "
          << L"$ipIf = Get-NetIPInterface -InterfaceIndex " << if_index
          << L" -AddressFamily IPv4 -ErrorAction SilentlyContinue; "
          << L"if ($ipIf) { $ipIf | Select-Object InterfaceIndex,InterfaceAlias,InterfaceGuid,AddressFamily,ConnectionState,NlMtu,InterfaceMetric | Format-List | Out-String | Write-Output } else { Write-Output 'NETIPIF_FOUND=false' }; "
          << L"$adapterByGuid = $null; $adapterByAlias = $null; ";
  if (!probe.interface_guid.empty()) {
    *script << L"$adapterByGuid = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq '"
            << EscapePowerShellSingleQuotedLiteral(probe.interface_guid)
            << L"' } | Select-Object -First 1; ";
  }
  if (!probe.alias.empty()) {
    *script << L"$adapterByAlias = Get-NetAdapter -Name '"
            << EscapePowerShellSingleQuotedLiteral(probe.alias)
            << L"' -ErrorAction SilentlyContinue; ";
  }
  *script << L"$bindAdapter = if ($adapterByGuid) { $adapterByGuid } elseif ($adapterByAlias) { $adapterByAlias } else { $null }; "
          << L"if ($bindAdapter) { Write-Output ('BIND_ALIAS=' + $bindAdapter.Name); Write-Output ('BIND_GUID=' + $bindAdapter.InterfaceGuid); Write-Output ('BIND_IFINDEX=' + $bindAdapter.ifIndex) } else { Write-Output 'BIND_ADAPTER_FOUND=false' }; "
          << L"if (-not $bindAdapter) { throw 'adapter binding target not visible via InterfaceGuid/InterfaceAlias' }; "
          << L"$bindAlias = $bindAdapter.Name; ";
}

bool IsProcessElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return false;
  }
  TOKEN_ELEVATION elevation = {};
  DWORD bytes_returned = 0;
  const BOOL ok = GetTokenInformation(token, TokenElevation, &elevation,
                                      sizeof(elevation), &bytes_returned);
  CloseHandle(token);
  return ok && elevation.TokenIsElevated != 0;
}

bool ParseTruthyEnvValue(const char* value) {
  if (value == nullptr) {
    return false;
  }
  std::string normalized(value);
  std::transform(normalized.begin(), normalized.end(), normalized.begin(),
                 [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
  return normalized == "1" || normalized == "true" || normalized == "yes" ||
         normalized == "on";
}

enum class PowerShellMountResult {
  kFailed = 0,
  kExists = 1,
  kCreated = 2,
};

bool IsPrivilegedMountExecutorEnabled() {
  char* raw = nullptr;
  size_t raw_size = 0;
  if (_dupenv_s(&raw, &raw_size, "ZT_WIN_ENABLE_PRIVILEGED_MOUNT_EXECUTOR") !=
          0 ||
      raw == nullptr) {
    return true;
  }
  const bool enabled = ParseTruthyEnvValue(raw);
  free(raw);
  return enabled;
}

bool IsPrivilegedMountServiceEnabled() {
  char* raw = nullptr;
  size_t raw_size = 0;
  if (_dupenv_s(&raw, &raw_size, "ZT_WIN_ENABLE_PRIVILEGED_MOUNT_SERVICE") !=
          0 ||
      raw == nullptr) {
    return true;
  }
  const bool enabled = ParseTruthyEnvValue(raw);
  free(raw);
  return enabled;
}

std::wstring TrimQuotedServicePath(const std::wstring& raw_path) {
  std::wstring value = raw_path;
  while (!value.empty() && iswspace(value.front())) {
    value.erase(value.begin());
  }
  while (!value.empty() && iswspace(value.back())) {
    value.pop_back();
  }
  if (value.size() >= 2 && value.front() == L'"') {
    const size_t closing_quote = value.find(L'"', 1);
    if (closing_quote != std::wstring::npos) {
      value = value.substr(1, closing_quote - 1);
    }
  } else {
    const size_t exe_pos = value.find(L".exe");
    if (exe_pos != std::wstring::npos) {
      value = value.substr(0, exe_pos + 4);
    }
  }
  return value;
}

std::filesystem::path StandaloneMountHelperPath() {
  const std::filesystem::path current = CurrentExecutablePath();
  if (current.empty()) {
    return {};
  }
  const std::filesystem::path helper_dir = current.parent_path();
  const std::filesystem::path preferred = helper_dir / L"zt_mount_helper_v6.exe";
  if (std::filesystem::exists(preferred)) {
    return preferred;
  }
  const std::filesystem::path prior = helper_dir / L"zt_mount_helper_v2.exe";
  if (std::filesystem::exists(prior)) {
    return prior;
  }
  const std::filesystem::path legacy = helper_dir / L"zt_mount_helper.exe";
  if (std::filesystem::exists(legacy)) {
    return legacy;
  }
  return helper_dir / L"zt_mount_service.exe";
}

bool IsStandaloneMountHelperEnabled() {
  char* raw = nullptr;
  size_t raw_size = 0;
  if (_dupenv_s(&raw, &raw_size, "ZT_WIN_ENABLE_STANDALONE_MOUNT_HELPER") != 0 ||
      raw == nullptr) {
    return true;
  }
  const bool enabled = ParseTruthyEnvValue(raw);
  free(raw);
  return enabled;
}

bool EnsurePrivilegedMountServiceBinaryCurrent(std::string* detail) {
  if (detail != nullptr) {
    detail->clear();
  }
  if (!IsPrivilegedMountServiceEnabled()) {
    if (detail != nullptr) {
      *detail = "service_disabled_by_env";
    }
    return true;
  }

  const std::filesystem::path expected_path = StandaloneMountHelperPath();
  if (expected_path.empty() || !std::filesystem::exists(expected_path)) {
    if (detail != nullptr) {
      *detail = "expected_helper_missing";
    }
    return false;
  }

  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (scm == nullptr) {
    if (detail != nullptr) {
      *detail = "open_scm_failed:" + std::to_string(GetLastError());
    }
    return false;
  }

  SC_HANDLE service =
      OpenServiceW(scm, L"ZeroTierMountService", SERVICE_QUERY_CONFIG | SERVICE_CHANGE_CONFIG);
  if (service == nullptr) {
    const DWORD open_error = GetLastError();
    CloseServiceHandle(scm);
    if (open_error == ERROR_SERVICE_DOES_NOT_EXIST) {
      if (detail != nullptr) {
        *detail = "service_absent";
      }
      return true;
    }
    if (open_error == ERROR_ACCESS_DENIED) {
      if (detail != nullptr) {
        *detail = "service_sync_skipped_access_denied";
      }
      return true;
    }
    if (detail != nullptr) {
      *detail = "open_service_failed:" + std::to_string(open_error);
    }
    return false;
  }

  DWORD bytes_needed = 0;
  QueryServiceConfigW(service, nullptr, 0, &bytes_needed);
  if (bytes_needed == 0) {
    const DWORD query_error = GetLastError();
    CloseServiceHandle(service);
    CloseServiceHandle(scm);
    if (detail != nullptr) {
      *detail = "query_service_size_failed:" + std::to_string(query_error);
    }
    return false;
  }

  std::vector<unsigned char> buffer(bytes_needed);
  QUERY_SERVICE_CONFIGW* config =
      reinterpret_cast<QUERY_SERVICE_CONFIGW*>(buffer.data());
  if (!QueryServiceConfigW(service, config, bytes_needed, &bytes_needed)) {
    const DWORD query_error = GetLastError();
    CloseServiceHandle(service);
    CloseServiceHandle(scm);
    if (detail != nullptr) {
      *detail = "query_service_failed:" + std::to_string(query_error);
    }
    return false;
  }

  const std::wstring current_path = TrimQuotedServicePath(
      config->lpBinaryPathName == nullptr ? L"" : config->lpBinaryPathName);
  std::error_code current_ec;
  std::error_code expected_ec;
  const std::filesystem::path normalized_current =
      std::filesystem::weakly_canonical(current_path, current_ec);
  const std::filesystem::path normalized_expected =
      std::filesystem::weakly_canonical(expected_path, expected_ec);
  const std::wstring current_cmp =
      current_ec ? current_path : normalized_current.wstring();
  const std::wstring expected_cmp =
      expected_ec ? expected_path.wstring() : normalized_expected.wstring();

  if (_wcsicmp(current_cmp.c_str(), expected_cmp.c_str()) == 0) {
    CloseServiceHandle(service);
    CloseServiceHandle(scm);
    if (detail != nullptr) {
      *detail = "service_path_current";
    }
    return true;
  }

  const std::wstring quoted_expected = L"\"" + expected_path.wstring() + L"\"";
  const BOOL config_ok = ChangeServiceConfigW(
      service, SERVICE_NO_CHANGE, SERVICE_NO_CHANGE, SERVICE_NO_CHANGE,
      quoted_expected.c_str(), nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);
  const DWORD config_error = config_ok ? NO_ERROR : GetLastError();
  CloseServiceHandle(service);
  CloseServiceHandle(scm);

  if (detail != nullptr) {
    *detail = "service_repoint "
              "from=" +
              WideToUtf8(current_cmp) + " to=" + WideToUtf8(expected_cmp) +
              " result=" + std::to_string(config_error);
  }
  return config_ok == TRUE;
}

bool CreateTempBinaryFilePath(const wchar_t* prefix,
                              std::wstring* file_path,
                              DWORD* error_code) {
  if (file_path == nullptr) {
    if (error_code != nullptr) {
      *error_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }
  file_path->clear();
  if (error_code != nullptr) {
    *error_code = ERROR_GEN_FAILURE;
  }
  wchar_t temp_path[MAX_PATH] = {0};
  const DWORD temp_path_len = GetTempPathW(MAX_PATH, temp_path);
  if (temp_path_len == 0 || temp_path_len >= MAX_PATH) {
    if (error_code != nullptr) {
      *error_code = GetLastError();
    }
    return false;
  }
  wchar_t temp_file[MAX_PATH] = {0};
  if (GetTempFileNameW(temp_path, prefix, 0, temp_file) == 0) {
    if (error_code != nullptr) {
      *error_code = GetLastError();
    }
    return false;
  }
  *file_path = temp_file;
  if (error_code != nullptr) {
    *error_code = NO_ERROR;
  }
  return true;
}

bool WriteBinaryFile(const std::wstring& path, const void* bytes, size_t size) {
  if (path.empty() || bytes == nullptr || size == 0) {
    return false;
  }
  std::ofstream output(std::filesystem::path(path),
                       std::ios::binary | std::ios::trunc);
  if (!output.is_open()) {
    return false;
  }
  output.write(reinterpret_cast<const char*>(bytes),
               static_cast<std::streamsize>(size));
  output.close();
  return output.good();
}

bool ReadBinaryFile(const std::wstring& path, void* bytes, size_t size) {
  if (path.empty() || bytes == nullptr || size == 0) {
    return false;
  }
  std::ifstream input(std::filesystem::path(path), std::ios::binary);
  if (!input.is_open()) {
    return false;
  }
  input.read(reinterpret_cast<char*>(bytes), static_cast<std::streamsize>(size));
  if (!input.good() && !input.eof()) {
    return false;
  }
  return input.gcount() == static_cast<std::streamsize>(size);
}

bool RunStandaloneMountHelperRequest(
    const ztwin::privileged_mount::Request& request,
    ztwin::privileged_mount::Response* response, DWORD* launch_error_code,
    std::string* helper_debug) {
  if (launch_error_code != nullptr) {
    *launch_error_code = ERROR_GEN_FAILURE;
  }
  if (helper_debug != nullptr) {
    helper_debug->clear();
  }
  if (response == nullptr) {
    if (launch_error_code != nullptr) {
      *launch_error_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }
  if (IsProcessElevated() || !IsPrivilegedMountExecutorEnabled() ||
      !IsStandaloneMountHelperEnabled()) {
    if (launch_error_code != nullptr) {
      *launch_error_code = ERROR_SERVICE_DISABLED;
    }
    return false;
  }

  const std::filesystem::path helper_path = StandaloneMountHelperPath();
  if (helper_path.empty() || !std::filesystem::exists(helper_path)) {
    if (launch_error_code != nullptr) {
      *launch_error_code = ERROR_FILE_NOT_FOUND;
    }
    if (helper_debug != nullptr) {
      *helper_debug = "helper_path_missing";
    }
    return false;
  }

  std::wstring request_path;
  DWORD request_path_error = NO_ERROR;
  if (!CreateTempBinaryFilePath(L"ztr", &request_path, &request_path_error)) {
    if (launch_error_code != nullptr) {
      *launch_error_code = request_path_error;
    }
    return false;
  }
  std::wstring response_path;
  DWORD response_path_error = NO_ERROR;
  if (!CreateTempBinaryFilePath(L"zts", &response_path, &response_path_error)) {
    DeleteFileW(request_path.c_str());
    if (launch_error_code != nullptr) {
      *launch_error_code = response_path_error;
    }
    return false;
  }
  if (!WriteBinaryFile(request_path, &request, sizeof(request))) {
    DeleteFileW(request_path.c_str());
    DeleteFileW(response_path.c_str());
    if (launch_error_code != nullptr) {
      *launch_error_code = ERROR_WRITE_FAULT;
    }
    return false;
  }

  const std::wstring parameters =
      L"--single-request --request-file \"" + request_path +
      L"\" --response-file \"" + response_path + L"\"";
  const std::wstring helper_dir = helper_path.parent_path().wstring();
  const std::wstring helper_file = helper_path.wstring();

  SHELLEXECUTEINFOW info = {};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOCLOSEPROCESS;
  info.hwnd = nullptr;
  info.lpVerb = L"runas";
  info.lpFile = helper_file.c_str();
  info.lpParameters = parameters.c_str();
  info.lpDirectory = helper_dir.c_str();
  info.nShow = SW_HIDE;

  const BOOL launched = ShellExecuteExW(&info);
  if (!launched) {
    const DWORD launch_error = GetLastError();
    DeleteFileW(request_path.c_str());
    DeleteFileW(response_path.c_str());
    if (launch_error_code != nullptr) {
      *launch_error_code = launch_error;
    }
    if (helper_debug != nullptr) {
      std::ostringstream stream;
      stream << "helper_launch_failed error=" << launch_error;
      *helper_debug = stream.str();
    }
    return false;
  }

  DWORD process_exit_code = ERROR_GEN_FAILURE;
  const DWORD wait_result = WaitForSingleObject(info.hProcess, 30000);
  if (wait_result == WAIT_OBJECT_0) {
    GetExitCodeProcess(info.hProcess, &process_exit_code);
  } else if (wait_result == WAIT_TIMEOUT) {
    process_exit_code = WAIT_TIMEOUT;
    TerminateProcess(info.hProcess, WAIT_TIMEOUT);
  } else {
    process_exit_code = GetLastError();
  }
  CloseHandle(info.hProcess);

  bool response_loaded = false;
  if (wait_result == WAIT_OBJECT_0 && process_exit_code == 0) {
    response_loaded = ReadBinaryFile(response_path, response, sizeof(*response));
  }

  DeleteFileW(request_path.c_str());
  DeleteFileW(response_path.c_str());
  if (launch_error_code != nullptr) {
    *launch_error_code = process_exit_code;
  }
  if (helper_debug != nullptr) {
    std::ostringstream stream;
    stream << "helper=" << helper_path.u8string()
           << " wait_result=" << wait_result
           << " exit_code=" << process_exit_code
           << " response_loaded=" << BoolLabel(response_loaded);
    *helper_debug = stream.str();
  }
  return response_loaded;
}

PowerShellMountResult MountResultFromServiceResult(
    ztwin::privileged_mount::Result service_result) {
  switch (service_result) {
    case ztwin::privileged_mount::Result::kSuccess:
      return PowerShellMountResult::kCreated;
    case ztwin::privileged_mount::Result::kAlreadyExists:
      return PowerShellMountResult::kExists;
    case ztwin::privileged_mount::Result::kFailed:
    case ztwin::privileged_mount::Result::kNotFound:
    case ztwin::privileged_mount::Result::kUnavailable:
    case ztwin::privileged_mount::Result::kInvalidRequest:
    case ztwin::privileged_mount::Result::kPermissionDenied:
    default:
      return PowerShellMountResult::kFailed;
  }
}

bool TryPrivilegedMountServiceRequest(
    ztwin::privileged_mount::Command command, uint64_t network_id,
    uint32_t if_index, const std::string& value, uint8_t prefix_length,
    DWORD* service_error_code, DWORD* native_error_code,
    PowerShellMountResult* mount_result, std::string* service_message) {
  if (service_error_code != nullptr) {
    *service_error_code = ERROR_GEN_FAILURE;
  }
  if (native_error_code != nullptr) {
    *native_error_code = NO_ERROR;
  }
  if (mount_result != nullptr) {
    *mount_result = PowerShellMountResult::kFailed;
  }
  if (if_index == 0 || value.empty()) {
    if (service_error_code != nullptr) {
      *service_error_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }

  ztwin::privileged_mount::Request request = {};
  request.command = static_cast<uint32_t>(command);
  request.network_id = network_id;
  request.if_index = if_index;
  request.prefix_length = prefix_length;
  request.request_id =
      static_cast<uint64_t>(GetTickCount64()) ^
      (static_cast<uint64_t>(if_index) << 32) ^
      static_cast<uint64_t>(network_id & 0xFFFFFFFFULL);
  strncpy_s(request.value, value.c_str(), _TRUNCATE);

  ztwin::privileged_mount::Response response = {};
  std::string helper_debug;
  if (RunStandaloneMountHelperRequest(request, &response, service_error_code,
                                      &helper_debug)) {
    if (service_error_code != nullptr) {
      *service_error_code = response.service_error;
    }
    if (native_error_code != nullptr) {
      *native_error_code = response.native_error;
    }
    if (service_message != nullptr) {
      *service_message =
          std::string(response.message,
                      strnlen_s(response.message, sizeof(response.message))) +
          (helper_debug.empty() ? "" : " helper_debug=" + helper_debug);
    }
    const auto result =
        static_cast<ztwin::privileged_mount::Result>(response.result);
    if (mount_result != nullptr) {
      *mount_result = MountResultFromServiceResult(result);
    }
    return result == ztwin::privileged_mount::Result::kSuccess ||
           result == ztwin::privileged_mount::Result::kAlreadyExists;
  }
  if (service_message != nullptr && !helper_debug.empty()) {
    *service_message = helper_debug;
  }

  if (!IsPrivilegedMountServiceEnabled()) {
    if (service_error_code != nullptr) {
      *service_error_code = ERROR_SERVICE_DISABLED;
    }
    return false;
  }

  DWORD transport_error = NO_ERROR;
  const bool transport_ok = ztwin::privileged_mount::SendRequest(
      request, &response, 3000, &transport_error);
  if (!transport_ok) {
    if (service_error_code != nullptr) {
      *service_error_code = transport_error;
    }
    return false;
  }

  if (service_error_code != nullptr) {
    *service_error_code = response.service_error;
  }
  if (native_error_code != nullptr) {
    *native_error_code = response.native_error;
  }
  if (service_message != nullptr) {
    service_message->assign(
        response.message, strnlen_s(response.message, sizeof(response.message)));
  }

  const auto result =
      static_cast<ztwin::privileged_mount::Result>(response.result);
  if (mount_result != nullptr) {
    *mount_result = MountResultFromServiceResult(result);
  }
  return result == ztwin::privileged_mount::Result::kSuccess ||
         result == ztwin::privileged_mount::Result::kAlreadyExists;
}

bool CreateTempPowerShellScriptPath(const wchar_t* prefix,
                                    std::wstring* script_path,
                                    DWORD* error_code) {
  if (script_path == nullptr) {
    if (error_code != nullptr) {
      *error_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }
  script_path->clear();
  if (error_code != nullptr) {
    *error_code = ERROR_GEN_FAILURE;
  }

  wchar_t temp_path[MAX_PATH] = {0};
  const DWORD temp_path_len = GetTempPathW(MAX_PATH, temp_path);
  if (temp_path_len == 0 || temp_path_len >= MAX_PATH) {
    if (error_code != nullptr) {
      *error_code = GetLastError();
    }
    return false;
  }

  wchar_t temp_file[MAX_PATH] = {0};
  if (GetTempFileNameW(temp_path, prefix, 0, temp_file) == 0) {
    if (error_code != nullptr) {
      *error_code = GetLastError();
    }
    return false;
  }

  std::filesystem::path target_path(temp_file);
  target_path += L".ps1";
  const std::wstring target_wide = target_path.wstring();
  if (!MoveFileExW(temp_file, target_wide.c_str(), MOVEFILE_REPLACE_EXISTING)) {
    if (error_code != nullptr) {
      *error_code = GetLastError();
    }
    DeleteFileW(temp_file);
    return false;
  }

  *script_path = target_wide;
  if (error_code != nullptr) {
    *error_code = NO_ERROR;
  }
  return true;
}

std::filesystem::path RuntimePowerShellLogDirectory() {
  char* local_app_data = nullptr;
  size_t env_size = 0;
  const errno_t env_result =
      _dupenv_s(&local_app_data, &env_size, "LOCALAPPDATA");
  std::filesystem::path root =
      env_result != 0 || local_app_data == nullptr
          ? std::filesystem::temp_directory_path()
          : std::filesystem::path(local_app_data);
  if (local_app_data != nullptr) {
    free(local_app_data);
  }
  std::filesystem::path dir =
      root / "FileTransferFlutter" / "zerotier" / "logs" / "powershell";
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  return dir;
}

std::wstring BuildRuntimePowerShellLogPath() {
  SYSTEMTIME st = {};
  GetLocalTime(&st);
  std::wostringstream name;
  name << L"zt_runtime_ps_" << st.wYear
       << (st.wMonth < 10 ? L"0" : L"") << st.wMonth
       << (st.wDay < 10 ? L"0" : L"") << st.wDay << L"_"
       << (st.wHour < 10 ? L"0" : L"") << st.wHour
       << (st.wMinute < 10 ? L"0" : L"") << st.wMinute
       << (st.wSecond < 10 ? L"0" : L"") << st.wSecond << L"_"
       << GetCurrentProcessId() << L"_" << GetCurrentThreadId() << L".log";
  return (RuntimePowerShellLogDirectory() / name.str()).wstring();
}

void AppendTextFile(const std::wstring& path, const std::string& content) {
  std::ofstream file(std::filesystem::path(path),
                     std::ios::binary | std::ios::app);
  if (file.is_open()) {
    file.write(content.data(), static_cast<std::streamsize>(content.size()));
  }
}

bool RunPowerShellScriptElevated(const std::wstring& script, DWORD* exit_code) {
  if (exit_code != nullptr) {
    *exit_code = ERROR_GEN_FAILURE;
  }
  if (script.empty()) {
    if (exit_code != nullptr) {
      *exit_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }

  std::wstring temp_script_path;
  DWORD temp_path_error = NO_ERROR;
  if (!CreateTempPowerShellScriptPath(L"ztm", &temp_script_path,
                                      &temp_path_error)) {
    if (exit_code != nullptr) {
      *exit_code = temp_path_error;
    }
    return false;
  }
  std::ofstream temp_script(std::filesystem::path(temp_script_path),
                            std::ios::binary | std::ios::trunc);
  if (!temp_script.is_open()) {
    if (exit_code != nullptr) {
      *exit_code = ERROR_OPEN_FAILED;
    }
    DeleteFileW(temp_script_path.c_str());
    return false;
  }
  const std::string utf8_body = WideToUtf8(script);
  const std::wstring log_path = BuildRuntimePowerShellLogPath();
  const std::string utf8_log_path =
      WideToUtf8(EscapePowerShellSingleQuotedLiteral(log_path));
  const std::string utf8_script =
      "\xEF\xBB\xBF$__ztLogPath='" + utf8_log_path +
      "'\r\nStart-Transcript -Path $__ztLogPath -Force | Out-Null\r\n& { " +
      utf8_body + " }\r\n";
  temp_script.write(utf8_script.data(),
                    static_cast<std::streamsize>(utf8_script.size()));
  temp_script.close();

  std::wstring parameters =
      L"-NoProfile -ExecutionPolicy Bypass -File \"" +
      temp_script_path + L"\"";

  SHELLEXECUTEINFOW info = {};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOCLOSEPROCESS;
  info.hwnd = nullptr;
  info.lpVerb = L"runas";
  info.lpFile = L"powershell.exe";
  info.lpParameters = parameters.c_str();
  info.lpDirectory = nullptr;
  info.nShow = SW_HIDE;

  const BOOL launched = ShellExecuteExW(&info);
  if (!launched) {
    if (exit_code != nullptr) {
      *exit_code = GetLastError();
    }
    DeleteFileW(temp_script_path.c_str());
    return false;
  }

  DWORD process_exit_code = ERROR_GEN_FAILURE;
  const DWORD wait_result = WaitForSingleObject(info.hProcess, 30000);
  if (wait_result == WAIT_OBJECT_0) {
    GetExitCodeProcess(info.hProcess, &process_exit_code);
  } else if (wait_result == WAIT_TIMEOUT) {
    process_exit_code = WAIT_TIMEOUT;
    TerminateProcess(info.hProcess, WAIT_TIMEOUT);
  } else {
    process_exit_code = GetLastError();
  }

  CloseHandle(info.hProcess);
  DeleteFileW(temp_script_path.c_str());
  if (exit_code != nullptr) {
    *exit_code = process_exit_code;
  }
  return wait_result == WAIT_OBJECT_0 && process_exit_code == 0;
}

std::string EscapePowerShellDoubleQuotedLiteral(const std::wstring& input) {
  std::string escaped = WideToUtf8(input);
  std::string output;
  output.reserve(escaped.size() + 8);
  for (const char ch : escaped) {
    if (ch == '`' || ch == '"' || ch == '$') {
      output.push_back('`');
    }
    output.push_back(ch);
  }
  return output;
}

std::string FirewallRuleNameForProgram(const std::filesystem::path& program_path,
                                       const char* suffix) {
  std::ostringstream stream;
  stream << "ZeroTier LibZT Host "
         << program_path.filename().u8string()
         << " " << suffix;
  return stream.str();
}

bool RunPowerShellScript(const std::wstring& script, DWORD* exit_code,
                         bool allow_privileged_executor);

bool EnsureFirewallRulesForCurrentHostExe(DWORD* helper_exit_code,
                                          std::string* helper_debug) {
  if (helper_exit_code != nullptr) {
    *helper_exit_code = ERROR_GEN_FAILURE;
  }
  if (helper_debug != nullptr) {
    helper_debug->clear();
  }

  const std::filesystem::path exe_path = CurrentExecutablePath();
  if (exe_path.empty() || !std::filesystem::exists(exe_path)) {
    if (helper_exit_code != nullptr) {
      *helper_exit_code = ERROR_FILE_NOT_FOUND;
    }
    if (helper_debug != nullptr) {
      *helper_debug = "host_exe_missing";
    }
    return false;
  }

  ztwin::privileged_mount::Request request = {};
  request.command = static_cast<uint32_t>(
      ztwin::privileged_mount::Command::kEnsureFirewallHostExe);
  request.request_id =
      (static_cast<uint64_t>(GetTickCount64()) << 16) ^ 0x46574CULL;
  strncpy_s(request.value, exe_path.u8string().c_str(), _TRUNCATE);

  ztwin::privileged_mount::Response response = {};
  DWORD launch_error = ERROR_GEN_FAILURE;
  std::string helper_detail;
  const bool loaded = RunStandaloneMountHelperRequest(request, &response,
                                                      &launch_error,
                                                      &helper_detail);
  DWORD effective_exit_code = loaded ? response.service_error : launch_error;
  bool fallback_attempted = false;
  bool fallback_ok = false;
  DWORD fallback_exit_code = ERROR_GEN_FAILURE;
  if (!(loaded && (response.result ==
                       static_cast<uint32_t>(ztwin::privileged_mount::Result::kSuccess) ||
                   response.result ==
                       static_cast<uint32_t>(ztwin::privileged_mount::Result::kAlreadyExists)))) {
    const std::string exe = EscapePowerShellDoubleQuotedLiteral(exe_path.wstring());
    const std::string in_name = FirewallRuleNameForProgram(exe_path,"Inbound");
    const std::string out_name = FirewallRuleNameForProgram(exe_path,"Outbound");
    const std::string script =
        "$ErrorActionPreference='Stop'\n"
        "$exe=\"" + exe + "\"\n"
        "$inName=\"" + in_name + "\"\n"
        "$outName=\"" + out_name + "\"\n"
        "function Ensure-UdpProgramRule([string]$name,[string]$direction,[string]$program){\n"
        "  $rule = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Select-Object -First 1\n"
        "  if ($rule) {\n"
        "    $app = ($rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Select-Object -First 1).Program\n"
        "    $port = ($rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue | Select-Object -First 1).Protocol\n"
        "    if ($rule.Direction -eq $direction -and $rule.Action -eq 'Allow' -and $app -ieq $program -and ($port -eq 'UDP' -or $port -eq 17)) { return 'present' }\n"
        "    $rule | Remove-NetFirewallRule -ErrorAction Stop | Out-Null\n"
        "  }\n"
        "  New-NetFirewallRule -DisplayName $name -Direction $direction -Program $program -Protocol UDP -Action Allow -Profile Any -ErrorAction Stop | Out-Null\n"
        "  return 'created'\n"
        "}\n"
        "Ensure-UdpProgramRule $inName 'Inbound' $exe | Out-String | Write-Output\n"
        "Ensure-UdpProgramRule $outName 'Outbound' $exe | Out-String | Write-Output\n";
    fallback_attempted = true;
    fallback_ok = RunPowerShellScript(Utf8ToWide(script), &fallback_exit_code, true);
    if (fallback_ok && fallback_exit_code == NO_ERROR) {
      effective_exit_code = NO_ERROR;
    }
  }
  if (helper_exit_code != nullptr) {
    *helper_exit_code = effective_exit_code;
  }
  if (helper_debug != nullptr) {
    std::ostringstream stream;
    stream << "host_exe=" << exe_path.u8string()
           << " loaded=" << BoolLabel(loaded)
           << " launch_or_service_error="
           << (loaded ? response.service_error : launch_error);
    if (!helper_detail.empty()) {
      stream << " helper=" << helper_detail;
    }
    if (loaded) {
      const std::string message(
          response.message, strnlen_s(response.message, sizeof(response.message)));
      if (!message.empty()) {
        stream << " response=" << message;
      }
    }
    if (fallback_attempted) {
      stream << " fallback_powershell=" << BoolLabel(fallback_ok)
             << " fallback_exit_code=" << fallback_exit_code;
    }
    *helper_debug = stream.str();
  }
  return effective_exit_code == NO_ERROR;
}

bool RunPowerShellScript(const std::wstring& script, DWORD* exit_code,
                         bool allow_privileged_executor = false) {
  if (exit_code != nullptr) {
    *exit_code = ERROR_GEN_FAILURE;
  }
  if (script.empty()) {
    if (exit_code != nullptr) {
      *exit_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }

  if (allow_privileged_executor && !IsProcessElevated() &&
      IsPrivilegedMountExecutorEnabled()) {
    return RunPowerShellScriptElevated(script, exit_code);
  }

  std::wstring temp_script_path;
  DWORD temp_path_error = NO_ERROR;
  if (!CreateTempPowerShellScriptPath(L"ztm", &temp_script_path,
                                      &temp_path_error)) {
    if (exit_code != nullptr) {
      *exit_code = temp_path_error;
    }
    return false;
  }
  const std::string utf8_body = WideToUtf8(script);
  const std::string utf8_script = "\xEF\xBB\xBF& { " + utf8_body + " }\r\n";
  std::ofstream temp_script(std::filesystem::path(temp_script_path),
                            std::ios::binary | std::ios::trunc);
  if (!temp_script.is_open()) {
    DeleteFileW(temp_script_path.c_str());
    if (exit_code != nullptr) {
      *exit_code = ERROR_OPEN_FAILED;
    }
    return false;
  }
  temp_script.write(utf8_script.data(),
                    static_cast<std::streamsize>(utf8_script.size()));
  temp_script.close();

  const std::wstring log_path = BuildRuntimePowerShellLogPath();
  AppendTextFile(log_path, "---- script_path ----\r\n" +
                               WideToUtf8(temp_script_path) +
                               "\r\n---- script_content ----\r\n" + utf8_body +
                               "\r\n---- output ----\r\n");

  SECURITY_ATTRIBUTES attr = {};
  attr.nLength = sizeof(attr);
  attr.bInheritHandle = TRUE;
  HANDLE log_handle = CreateFileW(
      log_path.c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, &attr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (log_handle == INVALID_HANDLE_VALUE) {
    DeleteFileW(temp_script_path.c_str());
    if (exit_code != nullptr) {
      *exit_code = GetLastError();
    }
    return false;
  }

  std::wstring command_line =
      L"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" +
      temp_script_path + L"\"";
  std::vector<wchar_t> command_line_buffer(command_line.begin(),
                                           command_line.end());
  command_line_buffer.push_back(L'\0');

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  startup.hStdOutput = log_handle;
  startup.hStdError = log_handle;
  PROCESS_INFORMATION process = {};
  if (!CreateProcessW(nullptr, command_line_buffer.data(), nullptr, nullptr, TRUE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
    const DWORD create_error = GetLastError();
    CloseHandle(log_handle);
    DeleteFileW(temp_script_path.c_str());
    if (exit_code != nullptr) {
      *exit_code = create_error;
    }
    return false;
  }

  const DWORD wait_result = WaitForSingleObject(process.hProcess, 30000);
  DWORD process_exit_code = ERROR_GEN_FAILURE;
  if (wait_result == WAIT_OBJECT_0) {
    GetExitCodeProcess(process.hProcess, &process_exit_code);
  } else if (wait_result == WAIT_TIMEOUT) {
    process_exit_code = WAIT_TIMEOUT;
    TerminateProcess(process.hProcess, WAIT_TIMEOUT);
  } else {
    process_exit_code = GetLastError();
  }

  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  CloseHandle(log_handle);
  AppendTextFile(log_path, "\r\nexit_code=" +
                               std::to_string(process_exit_code) +
                               "\r\n---- end ----\r\n");
  DeleteFileW(temp_script_path.c_str());

  if (exit_code != nullptr) {
    *exit_code = process_exit_code;
  }
  return wait_result == WAIT_OBJECT_0 && process_exit_code == 0;
}

PowerShellMountResult TryAddIpViaPowerShell(uint64_t network_id,
                                            uint32_t if_index,
                                            const std::string& ip_text,
                                            uint8_t prefix_length,
                                            DWORD* ps_exit_code,
                                            bool allow_privileged_executor,
                                            std::string* executor_used) {
  if (executor_used != nullptr) {
    *executor_used = "powershell";
  }
  const std::wstring ip_wide = Utf8ToWide(ip_text);
  if (if_index == 0 || ip_wide.empty()) {
    if (ps_exit_code != nullptr) {
      *ps_exit_code = ERROR_INVALID_PARAMETER;
    }
    return PowerShellMountResult::kFailed;
  }
  if (allow_privileged_executor) {
    DWORD service_error = NO_ERROR;
    DWORD native_error = NO_ERROR;
    PowerShellMountResult service_result = PowerShellMountResult::kFailed;
    std::string service_message;
    if (TryPrivilegedMountServiceRequest(
            ztwin::privileged_mount::Command::kEnsureIpV4, network_id, if_index,
            ip_text, prefix_length, &service_error, &native_error, &service_result,
            &service_message)) {
      if (executor_used != nullptr) {
        *executor_used = "service";
      }
      if (ps_exit_code != nullptr) {
        *ps_exit_code = 0;
      }
      std::ostringstream stream;
      stream << "ip_bind_service_result"
             << " network_id=" << FormatNetworkIdHex(network_id)
             << " if_index=" << if_index
             << " ip=" << ip_text
             << "/" << static_cast<int>(prefix_length)
             << " service_error=" << service_error
             << " native_error=" << native_error
             << " service_result=" << static_cast<int>(service_result)
             << " service_message="
             << (service_message.empty() ? "-" : service_message);
      LogNodeTrace(stream.str());
      return service_result;
    }
    std::ostringstream stream;
    stream << "ip_bind_service_unavailable"
           << " network_id=" << FormatNetworkIdHex(network_id)
           << " if_index=" << if_index
           << " ip=" << ip_text
           << "/" << static_cast<int>(prefix_length)
           << " service_error=" << service_error
           << " native_error=" << native_error
           << " service_message="
           << (service_message.empty() ? "-" : service_message);
    LogNodeTrace(stream.str());
  }
  const std::wstring escaped_ip = EscapePowerShellSingleQuotedLiteral(ip_wide);
  const AdapterBindingProbe adapter_probe = ProbeAdapterBinding(if_index);

  std::wostringstream script;
  script << L"try { ";
  AppendAdapterBindingScript(&script, if_index, adapter_probe);
  script << L"$existing = Get-NetIPAddress -InterfaceAlias $bindAlias"
         << L" -AddressFamily IPv4 -IPAddress '" << escaped_ip
         << L"' -ErrorAction SilentlyContinue; "
         << L"if (-not $existing) { "
         << L"New-NetIPAddress -InterfaceAlias $bindAlias"
         << L" -IPAddress '" << escaped_ip
         << L"' -PrefixLength " << static_cast<int>(prefix_length)
         << L" -AddressFamily IPv4 -Type Unicast -ErrorAction Stop | Out-Null "
         << L"$verified = Get-NetIPAddress -InterfaceAlias $bindAlias"
         << L" -AddressFamily IPv4 -IPAddress '" << escaped_ip
         << L"' -ErrorAction SilentlyContinue; "
         << L"if (-not $verified) { throw 'New-NetIPAddress completed but verification by InterfaceAlias failed' }; "
         << L"Write-Output ('VERIFY_ALIAS=' + $verified.InterfaceAlias); "
         << L"Write-Output ('VERIFY_IFINDEX=' + $verified.InterfaceIndex); "
         << L"exit 2 "
         << L"}; "
         << L"Write-Output ('VERIFY_ALIAS=' + $existing.InterfaceAlias); "
         << L"Write-Output ('VERIFY_IFINDEX=' + $existing.InterfaceIndex); "
         << L"exit 0 "
         << L"} catch { Write-Output ('ERR_MSG=' + $_.Exception.Message); Write-Output ('ERR_FQID=' + $_.FullyQualifiedErrorId); exit 1 }";
  const bool success = RunPowerShellScript(script.str(), ps_exit_code,
                                           allow_privileged_executor);
  if (success) {
    return PowerShellMountResult::kExists;
  }
  if (ps_exit_code != nullptr && *ps_exit_code == 2) {
    return PowerShellMountResult::kCreated;
  }
  return PowerShellMountResult::kFailed;
}

PowerShellMountResult TryAddRouteViaPowerShell(uint32_t if_index,
                                               const std::string& cidr,
                                               DWORD* ps_exit_code,
                                               bool allow_privileged_executor,
                                               uint64_t network_id,
                                               std::string* executor_used) {
  if (executor_used != nullptr) {
    *executor_used = "powershell";
  }
  const std::wstring cidr_wide = Utf8ToWide(cidr);
  if (if_index == 0 || cidr_wide.empty()) {
    if (ps_exit_code != nullptr) {
      *ps_exit_code = ERROR_INVALID_PARAMETER;
    }
    return PowerShellMountResult::kFailed;
  }
  if (allow_privileged_executor) {
    DWORD service_error = NO_ERROR;
    DWORD native_error = NO_ERROR;
    PowerShellMountResult service_result = PowerShellMountResult::kFailed;
    std::string service_message;
    if (TryPrivilegedMountServiceRequest(
            ztwin::privileged_mount::Command::kEnsureRouteV4, network_id, if_index,
            cidr, 0, &service_error, &native_error, &service_result,
            &service_message)) {
      if (executor_used != nullptr) {
        *executor_used = "service";
      }
      if (ps_exit_code != nullptr) {
        *ps_exit_code = 0;
      }
      return service_result;
    }
  }
  const std::wstring escaped_cidr =
      EscapePowerShellSingleQuotedLiteral(cidr_wide);

  std::wostringstream script;
  script << L"try { "
         << L"$existing = Get-NetRoute -InterfaceIndex " << if_index
         << L" -AddressFamily IPv4 -DestinationPrefix '" << escaped_cidr
         << L"' -ErrorAction SilentlyContinue; "
         << L"if (-not $existing) { "
         << L"New-NetRoute -InterfaceIndex " << if_index
         << L" -AddressFamily IPv4 -DestinationPrefix '" << escaped_cidr
         << L"' -NextHop '0.0.0.0' -RouteMetric 5 -PolicyStore ActiveStore "
         << L"-ErrorAction Stop | Out-Null "
         << L"exit 2 "
         << L"}; "
         << L"exit 0 "
         << L"} catch { exit 1 }";
  const bool success = RunPowerShellScript(script.str(), ps_exit_code,
                                           allow_privileged_executor);
  if (success) {
    return PowerShellMountResult::kExists;
  }
  if (ps_exit_code != nullptr && *ps_exit_code == 2) {
    return PowerShellMountResult::kCreated;
  }
  return PowerShellMountResult::kFailed;
}

bool TryRemoveIpViaPowerShell(uint64_t network_id, uint32_t if_index,
                              const std::string& ip_text, DWORD* ps_exit_code,
                              bool allow_privileged_executor,
                              std::string* executor_used) {
  if (executor_used != nullptr) {
    *executor_used = "powershell";
  }
  const std::wstring ip_wide = Utf8ToWide(ip_text);
  if (if_index == 0 || ip_wide.empty()) {
    if (ps_exit_code != nullptr) {
      *ps_exit_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }
  if (allow_privileged_executor) {
    DWORD service_error = NO_ERROR;
    DWORD native_error = NO_ERROR;
    PowerShellMountResult ignored_result = PowerShellMountResult::kFailed;
    std::string service_message;
    if (TryPrivilegedMountServiceRequest(
            ztwin::privileged_mount::Command::kRemoveIpV4, network_id, if_index,
            ip_text, 0, &service_error, &native_error, &ignored_result,
            &service_message)) {
      if (executor_used != nullptr) {
        *executor_used = "service";
      }
      if (ps_exit_code != nullptr) {
        *ps_exit_code = 0;
      }
      return true;
    }
  }
  const std::wstring escaped_ip = EscapePowerShellSingleQuotedLiteral(ip_wide);
  const AdapterBindingProbe adapter_probe = ProbeAdapterBinding(if_index);

  std::wostringstream script;
  script << L"try { ";
  AppendAdapterBindingScript(&script, if_index, adapter_probe);
  script << L"$existing = Get-NetIPAddress -InterfaceAlias $bindAlias"
         << L" -AddressFamily IPv4 -IPAddress '" << escaped_ip
         << L"' -ErrorAction SilentlyContinue; "
         << L"if ($existing) { "
         << L"$existing | Remove-NetIPAddress -Confirm:$false -ErrorAction Stop "
         << L"}; "
         << L"exit 0 "
         << L"} catch { Write-Output ('ERR_MSG=' + $_.Exception.Message); Write-Output ('ERR_FQID=' + $_.FullyQualifiedErrorId); exit 1 }";
  return RunPowerShellScript(script.str(), ps_exit_code,
                             allow_privileged_executor);
}

bool TryRemoveRouteViaPowerShell(uint64_t network_id, uint32_t if_index,
                                 const std::string& cidr, DWORD* ps_exit_code,
                                 bool allow_privileged_executor,
                                 std::string* executor_used) {
  if (executor_used != nullptr) {
    *executor_used = "powershell";
  }
  const std::wstring cidr_wide = Utf8ToWide(cidr);
  if (if_index == 0 || cidr_wide.empty()) {
    if (ps_exit_code != nullptr) {
      *ps_exit_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }
  if (allow_privileged_executor) {
    DWORD service_error = NO_ERROR;
    DWORD native_error = NO_ERROR;
    PowerShellMountResult ignored_result = PowerShellMountResult::kFailed;
    std::string service_message;
    if (TryPrivilegedMountServiceRequest(
            ztwin::privileged_mount::Command::kRemoveRouteV4, network_id,
            if_index, cidr, 0, &service_error, &native_error, &ignored_result,
            &service_message)) {
      if (executor_used != nullptr) {
        *executor_used = "service";
      }
      if (ps_exit_code != nullptr) {
        *ps_exit_code = 0;
      }
      return true;
    }
  }
  const std::wstring escaped_cidr =
      EscapePowerShellSingleQuotedLiteral(cidr_wide);

  std::wostringstream script;
  script << L"try { "
         << L"$existing = Get-NetRoute -InterfaceIndex " << if_index
         << L" -AddressFamily IPv4 -DestinationPrefix '" << escaped_cidr
         << L"' -ErrorAction SilentlyContinue; "
         << L"if ($existing) { "
         << L"$existing | Remove-NetRoute -Confirm:$false -ErrorAction Stop "
         << L"}; "
         << L"exit 0 "
         << L"} catch { exit 1 }";
  return RunPowerShellScript(script.str(), ps_exit_code,
                             allow_privileged_executor);
}

enum class EnsureRouteResult {
  kFailed = 0,
  kExists = 1,
  kCreated = 2,
};

EnsureRouteResult EnsureOnLinkIpv4Route(uint32_t if_index,
                                        uint32_t destination_network_order,
                                        uint8_t prefix_length,
                                        DWORD* native_error_code) {
  if (native_error_code != nullptr) {
    *native_error_code = NO_ERROR;
  }
  if (if_index == 0) {
    if (native_error_code != nullptr) {
      *native_error_code = ERROR_INVALID_PARAMETER;
    }
    return EnsureRouteResult::kFailed;
  }

  const uint32_t route_mask = PrefixMaskNetworkOrder(prefix_length);
  ULONG route_table_size = 0;
  if (GetIpForwardTable(nullptr, &route_table_size, FALSE) ==
      ERROR_INSUFFICIENT_BUFFER) {
    std::vector<unsigned char> route_table_buffer(route_table_size);
    MIB_IPFORWARDTABLE* route_table =
        reinterpret_cast<MIB_IPFORWARDTABLE*>(route_table_buffer.data());
    if (GetIpForwardTable(route_table, &route_table_size, FALSE) == NO_ERROR) {
      for (DWORD i = 0; i < route_table->dwNumEntries; ++i) {
        const MIB_IPFORWARDROW& row = route_table->table[i];
        if (row.dwForwardIfIndex != if_index ||
            row.dwForwardDest != destination_network_order ||
            row.dwForwardMask != route_mask ||
            row.dwForwardNextHop != htonl(INADDR_ANY)) {
          continue;
        }
        return EnsureRouteResult::kExists;
      }
    }
  }

  MIB_IPFORWARDROW route_row = {};
  route_row.dwForwardDest = destination_network_order;
  route_row.dwForwardMask = route_mask;
  route_row.dwForwardPolicy = 0;
  route_row.dwForwardNextHop = htonl(INADDR_ANY);
  route_row.dwForwardIfIndex = if_index;
  route_row.dwForwardType = MIB_IPROUTE_TYPE_DIRECT;
  route_row.dwForwardProto = MIB_IPPROTO_NETMGMT;
  route_row.dwForwardAge = INFINITE;
  route_row.dwForwardNextHopAS = 0;
  route_row.dwForwardMetric1 = 5;
  route_row.dwForwardMetric2 = static_cast<DWORD>(-1);
  route_row.dwForwardMetric3 = static_cast<DWORD>(-1);
  route_row.dwForwardMetric4 = static_cast<DWORD>(-1);
  route_row.dwForwardMetric5 = static_cast<DWORD>(-1);

  const DWORD result = CreateIpForwardEntry(&route_row);
  if (result == NO_ERROR || result == ERROR_OBJECT_ALREADY_EXISTS) {
    return result == NO_ERROR ? EnsureRouteResult::kCreated
                              : EnsureRouteResult::kExists;
  }
  if (native_error_code != nullptr) {
    *native_error_code = result;
  }
  return EnsureRouteResult::kFailed;
}

bool RemoveOnLinkIpv4Route(uint32_t if_index, uint32_t destination_network_order,
                           uint8_t prefix_length) {
  ULONG route_table_size = 0;
  if (GetIpForwardTable(nullptr, &route_table_size, FALSE) !=
      ERROR_INSUFFICIENT_BUFFER) {
    return false;
  }

  std::vector<unsigned char> route_table_buffer(route_table_size);
  MIB_IPFORWARDTABLE* route_table =
      reinterpret_cast<MIB_IPFORWARDTABLE*>(route_table_buffer.data());
  if (GetIpForwardTable(route_table, &route_table_size, FALSE) != NO_ERROR) {
    return false;
  }

  bool removed = false;
  const uint32_t route_mask = PrefixMaskNetworkOrder(prefix_length);
  for (DWORD i = 0; i < route_table->dwNumEntries; ++i) {
    MIB_IPFORWARDROW entry = route_table->table[i];
    if (entry.dwForwardIfIndex != if_index ||
        entry.dwForwardDest != destination_network_order ||
        entry.dwForwardMask != route_mask ||
        entry.dwForwardNextHop != htonl(INADDR_ANY)) {
      continue;
    }
    if (DeleteIpForwardEntry(&entry) == NO_ERROR) {
      removed = true;
    }
  }
  return removed;
}

enum class EnsureIpResult {
  kFailed = 0,
  kExists = 1,
  kCreated = 2,
};

EnsureIpResult EnsureIpv4AddressOnInterface(uint32_t if_index,
                                            uint32_t address_network_order,
                                            uint8_t prefix_length,
                                            uint32_t* created_context,
                                            DWORD* native_error_code) {
  if (created_context != nullptr) {
    *created_context = 0;
  }
  if (native_error_code != nullptr) {
    *native_error_code = NO_ERROR;
  }
  if (if_index == 0) {
    if (native_error_code != nullptr) {
      *native_error_code = ERROR_INVALID_PARAMETER;
    }
    return EnsureIpResult::kFailed;
  }

  ULONG ip_table_size = 0;
  if (GetIpAddrTable(nullptr, &ip_table_size, FALSE) == ERROR_INSUFFICIENT_BUFFER) {
    std::vector<unsigned char> ip_table_buffer(ip_table_size);
    MIB_IPADDRTABLE* ip_table =
        reinterpret_cast<MIB_IPADDRTABLE*>(ip_table_buffer.data());
    if (GetIpAddrTable(ip_table, &ip_table_size, FALSE) == NO_ERROR) {
      for (DWORD i = 0; i < ip_table->dwNumEntries; ++i) {
        const MIB_IPADDRROW& row = ip_table->table[i];
        if (row.dwIndex == if_index && row.dwAddr == address_network_order) {
          return EnsureIpResult::kExists;
        }
      }
    }
  }

  ULONG context = 0;
  ULONG instance = 0;
  const DWORD mask = PrefixMaskNetworkOrder(prefix_length);
  const DWORD add_result =
      AddIPAddress(address_network_order, mask, if_index, &context, &instance);
  if (add_result == NO_ERROR) {
    if (created_context != nullptr) {
      *created_context = context;
    }
    return EnsureIpResult::kCreated;
  }
  if (native_error_code != nullptr) {
    *native_error_code = add_result;
  }

  ip_table_size = 0;
  if (GetIpAddrTable(nullptr, &ip_table_size, FALSE) == ERROR_INSUFFICIENT_BUFFER) {
    std::vector<unsigned char> ip_table_buffer(ip_table_size);
    MIB_IPADDRTABLE* ip_table =
        reinterpret_cast<MIB_IPADDRTABLE*>(ip_table_buffer.data());
    if (GetIpAddrTable(ip_table, &ip_table_size, FALSE) == NO_ERROR) {
      for (DWORD i = 0; i < ip_table->dwNumEntries; ++i) {
        const MIB_IPADDRROW& row = ip_table->table[i];
        if (row.dwIndex == if_index && row.dwAddr == address_network_order) {
          return EnsureIpResult::kExists;
        }
      }
    }
  }
  return EnsureIpResult::kFailed;
}

bool RemoveIpv4AddressOnInterface(uint32_t nte_context, uint32_t if_index,
                                  uint32_t address_network_order) {
  (void)if_index;
  (void)address_network_order;
  if (nte_context != 0) {
    return DeleteIPAddress(nte_context) == NO_ERROR;
  }
  return false;
}

bool EnsureInterfaceAdminUp(uint32_t if_index) {
  if (if_index == 0) {
    return false;
  }
  MIB_IFROW row = {};
  row.dwIndex = if_index;
  if (GetIfEntry(&row) != NO_ERROR) {
    return false;
  }
  if (row.dwAdminStatus != MIB_IF_ADMIN_STATUS_UP) {
    row.dwAdminStatus = MIB_IF_ADMIN_STATUS_UP;
    if (SetIfEntry(&row) != NO_ERROR) {
      return false;
    }
    Sleep(150);
    row = {};
    row.dwIndex = if_index;
    if (GetIfEntry(&row) != NO_ERROR) {
      return false;
    }
  }
  return row.dwAdminStatus == MIB_IF_ADMIN_STATUS_UP;
}

void ResetJoinTrace(ZeroTierWindowsNetworkRecord* network) {
  if (network == nullptr) {
    return;
  }
  network->join_trace_active = true;
  network->join_trace_started_at_utc = Iso8601NowUtc();
  network->join_event_sequence.clear();
  network->join_saw_req_config = false;
  network->join_saw_ready_ip4 = false;
  network->join_saw_ready_ip6 = false;
  network->join_saw_ready_ip4_ip6 = false;
  network->join_saw_network_ok = false;
  network->join_saw_network_down = false;
  network->join_saw_addr_added_ip4 = false;
  network->join_saw_addr_added_ip6 = false;
}

void AppendJoinTraceEvent(ZeroTierWindowsNetworkRecord* network,
                          int event_code,
                          const char* event_name) {
  if (network == nullptr) {
    return;
  }
  const std::string label =
      event_name == nullptr ? ("EVENT_" + std::to_string(event_code))
                            : std::string(event_name);
  if (!network->join_event_sequence.empty()) {
    network->join_event_sequence.append(" -> ");
  }
  network->join_event_sequence.append(label);
  switch (event_code) {
    case ZTS_EVENT_NETWORK_REQ_CONFIG:
      network->join_saw_req_config = true;
      break;
    case ZTS_EVENT_NETWORK_READY_IP4:
      network->join_saw_ready_ip4 = true;
      break;
    case ZTS_EVENT_NETWORK_READY_IP6:
      network->join_saw_ready_ip6 = true;
      break;
    case ZTS_EVENT_NETWORK_READY_IP4_IP6:
      network->join_saw_ready_ip4_ip6 = true;
      network->join_saw_ready_ip4 = true;
      network->join_saw_ready_ip6 = true;
      break;
    case ZTS_EVENT_NETWORK_OK:
      network->join_saw_network_ok = true;
      break;
    case ZTS_EVENT_NETWORK_DOWN:
      network->join_saw_network_down = true;
      break;
    case ZTS_EVENT_ADDR_ADDED_IP4:
      network->join_saw_addr_added_ip4 = true;
      break;
    case ZTS_EVENT_ADDR_ADDED_IP6:
      network->join_saw_addr_added_ip6 = true;
      break;
    default:
      break;
  }
}

}  // namespace

ZeroTierWindowsRuntime::ZeroTierWindowsRuntime() {
  {
    std::scoped_lock lock(g_runtime_callback_mutex);
    g_runtime_instance = this;
    g_runtime_callback_shutting_down = false;
    g_runtime_callback_active_count = 0;
  }
  adapter_probe_.summary = "Adapter bridge not initialized yet.";
  tap_backend_ = CreateWindowsTapBackendFromEnv();
  if (tap_backend_) {
    tap_backend_id_ = tap_backend_->BackendId();
    LogNodeTrace("tap_backend_selected backend=" + tap_backend_id_);
  }
}

ZeroTierWindowsRuntime::~ZeroTierWindowsRuntime() {
  {
    std::scoped_lock lock(mutex_);
    if (node_started_ || node_online_) {
      std::ostringstream stream;
      stream << "runtime_destruct"
             << " node_started=" << BoolLabel(node_started_)
             << " node_online=" << BoolLabel(node_online_)
             << " node_offline=" << BoolLabel(node_offline_)
             << " trigger=process_exit_or_plugin_teardown"
             << " last_control_hint="
             << (last_node_control_hint_.empty() ? "-" : last_node_control_hint_)
             << " last_control_at="
             << (last_node_control_at_utc_.empty() ? "-" : last_node_control_at_utc_)
             << " service_state=" << BuildServiceState()
             << " tracked_networks=" << SummarizeTrackedNetworksLocked();
      LogNodeTrace(stream.str());
    }
  }
  std::unique_lock<std::mutex> lock(g_runtime_callback_mutex);
  if (g_runtime_instance == this) {
    g_runtime_callback_shutting_down = true;
    suppress_libzt_events_ = true;
    g_runtime_instance = nullptr;
    g_runtime_callback_cv.wait(lock, []() {
      return g_runtime_callback_active_count == 0;
    });
  }
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

  {
    std::scoped_lock lock(g_runtime_callback_mutex);
    suppress_libzt_events_ = false;
  }

  bool emit_start_event = false;
  bool restarted_from_offline = false;
  {
    std::scoped_lock lock(mutex_);
    SetLastNodeControlHintLocked(node_started_ ? "startNode.recovery"
                                               : "startNode.request");
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
      stop_requested_ = true;
      std::scoped_lock api_lock(api_mutex_);
      const int stop_result = zts_node_stop();
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

  {
    std::scoped_lock lock(mutex_);
    std::ostringstream stream;
    stream << "control=startNode"
           << " restarted_from_offline=" << BoolLabel(restarted_from_offline)
           << " node_started=" << BoolLabel(node_started_)
           << " node_online=" << BoolLabel(node_online_)
           << " node_offline=" << BoolLabel(node_offline_)
           << " service_state=" << BuildServiceState()
           << " tracked_networks=" << SummarizeTrackedNetworksLocked();
    LogNodeTrace(stream.str());
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
  std::vector<uint64_t> networks_to_cleanup;
  {
    std::scoped_lock lock(mutex_);
    SetLastNodeControlHintLocked("stopNode.request");
    for (const auto& entry : mounted_system_ips_) {
      networks_to_cleanup.push_back(entry.first);
    }
    for (const auto& entry : mounted_system_routes_) {
      if (std::find(networks_to_cleanup.begin(), networks_to_cleanup.end(),
                    entry.first) == networks_to_cleanup.end()) {
        networks_to_cleanup.push_back(entry.first);
      }
    }
    stop_requested_ = true;
    {
      std::scoped_lock callback_lock(g_runtime_callback_mutex);
      suppress_libzt_events_ = true;
    }
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
  LogNodeTrace("control=stopNode requested");
  for (const uint64_t network_id : networks_to_cleanup) {
    RemoveMountedSystemIpsForNetwork(network_id, "stopNode");
    RemoveMountedSystemRoutesForNetwork(network_id, "stopNode");
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
  if (node_started_ || node_online_) {
    std::ostringstream stream;
    stream << "event_callback_cleared"
           << " node_started=" << BoolLabel(node_started_)
           << " node_online=" << BoolLabel(node_online_)
           << " node_offline=" << BoolLabel(node_offline_)
           << " trigger=plugin_or_runner_detach"
           << " last_control_hint="
           << (last_node_control_hint_.empty() ? "-" : last_node_control_hint_)
           << " tracked_networks=" << SummarizeTrackedNetworksLocked();
    LogNodeTrace(stream.str());
  }
  event_callback_ = nullptr;
}

bool ZeroTierWindowsRuntime::JoinNetworkAndWaitForIp(uint64_t network_id,
                                                     int timeout_ms,
                                                     bool allow_mount_degraded,
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

  PruneKnownNetworksForJoin(network_id);

  uint64_t join_generation = 0;
  bool emit_existing_network_online = false;
  flutter::EncodableMap existing_network_payload;
  std::string join_existing_snapshot;
  bool join_existing_snapshot_available = false;
  {
    std::scoped_lock lock(mutex_);
    leaving_networks_.erase(network_id);
    leave_request_sources_.erase(network_id);
    pending_leave_generations_.erase(network_id);
    pending_join_networks_.insert(network_id);
    SetLastNodeControlHintLocked("joinNetwork.request:" + ToHexNetworkId(network_id));
    RememberKnownNetworkLocked(network_id);
    ClearLastErrorLocked();
    auto existing = networks_.find(network_id);
    if (existing != networks_.end()) {
      std::ostringstream stream;
      stream << "network_id=" << ToHexNetworkId(network_id)
             << " status=" << existing->second.status
             << " connected=" << BoolLabel(existing->second.is_connected)
             << " authorized=" << BoolLabel(existing->second.is_authorized)
             << " local_ready="
             << BoolLabel(existing->second.local_interface_ready)
             << " mount=" << existing->second.local_mount_state
             << " addrs=" << existing->second.assigned_addresses.size()
             << " addresses=" << JoinAddresses(existing->second.assigned_addresses);
      join_existing_snapshot = stream.str();
      join_existing_snapshot_available = true;
    }
    if (existing != networks_.end() &&
        existing->second.local_interface_ready) {
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
      networks_[network_id].local_interface_ready = false;
      networks_[network_id].matched_interface_name.clear();
      networks_[network_id].matched_interface_if_index = 0;
      networks_[network_id].matched_interface_up = false;
      networks_[network_id].local_mount_state = "awaiting_address";
      ResetJoinTrace(&networks_[network_id]);
    }
  }

  if (join_existing_snapshot_available) {
    LogNodeTrace("join_request_existing " + join_existing_snapshot);
  } else {
    LogNodeTrace("join_request_existing network_id=" + ToHexNetworkId(network_id) +
                 " status=missing");
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
  LogNodeTrace("join_request_result network_id=" + ToHexNetworkId(network_id) +
               " zts_net_join=" + std::to_string(result));
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
    state_cv_.wait_for(lock, wait_slice, [this, network_id, allow_mount_degraded]() {
      const auto network_it = networks_.find(network_id);
      if (network_it == networks_.end()) {
        return !last_error_.empty() || !node_started_;
      }

      const ZeroTierWindowsNetworkRecord& network = network_it->second;
      if (network.status == "ACCESS_DENIED" ||
          IsTerminalNetworkFailureStatus(network.status)) {
        return true;
      }
      if (IsJoinClosedLoopReady(network, allow_mount_degraded)) {
        return true;
      }
      return !last_error_.empty() || !node_started_;
    });

    const auto network_it = networks_.find(network_id);
    if (network_it != networks_.end()) {
      const ZeroTierWindowsNetworkRecord& network = network_it->second;
      if (IsJoinClosedLoopReady(network, allow_mount_degraded)) {
        ClearLastErrorLocked();
        pending_join_networks_.erase(network_id);
        if (error_message != nullptr) {
          error_message->clear();
        }
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

  std::string message =
      "Timed out waiting for ZeroTier to mount the managed address on a Windows adapter.";
  const auto timed_out_network_it = networks_.find(network_id);
  if (!node_started_) {
    message = "ZeroTier node stopped before the network became ready.";
  } else if (!node_online_) {
    message =
        "ZeroTier node stayed offline while waiting for the network to become ready.";
  } else if (timed_out_network_it != networks_.end()) {
    const ZeroTierWindowsNetworkRecord& network = timed_out_network_it->second;
    if (network.join_saw_network_ok &&
        !network.join_saw_ready_ip4 &&
        !network.join_saw_ready_ip6 &&
        !network.join_saw_ready_ip4_ip6 &&
        !network.join_saw_addr_added_ip4 &&
        !network.join_saw_addr_added_ip6) {
      message =
          "ZeroTier reported NETWORK_OK, but no READY_IP4/IP6 or ADDR_ADDED event was observed.";
    }
  }
  SetLastErrorLocked(message);
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
    SetLastNodeControlHintLocked(
        "leaveNetwork.request:" + ToHexNetworkId(network_id) + ":" +
        (source.empty() ? "unknown" : source));
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

  RemoveMountedSystemIpsForNetwork(network_id, "leaveRequested");
  RemoveMountedSystemRoutesForNetwork(network_id, "leaveRequested");

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
  ForgetKnownNetworkLocked(network_id);
  networks_.erase(network_id);
  pending_join_networks_.erase(network_id);
  leaving_networks_.erase(network_id);
  leave_request_sources_.erase(network_id);
  pending_leave_generations_.erase(network_id);
  lock.unlock();
  EmitError(message, network_id_hex);
  return false;
}

void ZeroTierWindowsRuntime::PruneKnownNetworksForJoin(uint64_t target_network_id) {
  if (target_network_id == 0) {
    return;
  }

  std::vector<uint64_t> networks_to_prune;
  {
    std::scoped_lock lock(mutex_);
    LoadKnownNetworkIdsLocked();
    for (const uint64_t known_network_id : known_network_ids_) {
      if (known_network_id == 0 || known_network_id == target_network_id) {
        continue;
      }
      networks_to_prune.push_back(known_network_id);
    }
  }

  for (const uint64_t stale_network_id : networks_to_prune) {
    {
      std::scoped_lock lock(mutex_);
      pending_join_networks_.erase(stale_network_id);
      leaving_networks_.erase(stale_network_id);
      leave_request_sources_.erase(stale_network_id);
      pending_leave_generations_.erase(stale_network_id);
    }

    RemoveMountedSystemIpsForNetwork(stale_network_id, "pruneBeforeJoin");
    RemoveMountedSystemRoutesForNetwork(stale_network_id, "pruneBeforeJoin");

    int leave_result = ZTS_ERR_OK;
    {
      std::scoped_lock api_lock(api_mutex_);
      leave_result = zts_net_leave(stale_network_id);
    }

    {
      std::scoped_lock lock(mutex_);
      ForgetKnownNetworkLocked(stale_network_id);
      networks_.erase(stale_network_id);
      pending_join_networks_.erase(stale_network_id);
      leaving_networks_.erase(stale_network_id);
      leave_request_sources_.erase(stale_network_id);
      pending_leave_generations_.erase(stale_network_id);
    }

    std::ostringstream stream;
    stream << "join_prune_stale_network"
           << " target=" << ToHexNetworkId(target_network_id)
           << " stale=" << ToHexNetworkId(stale_network_id)
           << " zts_net_leave=" << leave_result;
    LogNodeTrace(stream.str());
  }
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
  ZeroTierWindowsRuntime* runtime = nullptr;
  {
    std::unique_lock<std::mutex> lock(g_runtime_callback_mutex);
    if (g_runtime_callback_shutting_down || g_runtime_instance == nullptr ||
        g_runtime_instance->suppress_libzt_events_) {
      return;
    }
    runtime = g_runtime_instance;
    ++g_runtime_callback_active_count;
  }

  runtime->ProcessEvent(message_ptr);

  {
    std::scoped_lock lock(g_runtime_callback_mutex);
    if (g_runtime_callback_active_count > 0) {
      --g_runtime_callback_active_count;
    }
  }
  g_runtime_callback_cv.notify_all();
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

flutter::EncodableMap ZeroTierWindowsRuntime::ProbeNetworkStateNow(
    uint64_t network_id) {
  RefreshSnapshot();

  int status_code = 0;
  int transport_ready = 0;
  zts_sockaddr_storage assigned_addrs[ZTS_MAX_ASSIGNED_ADDRESSES] = {};
  unsigned int assigned_addr_count = ZTS_MAX_ASSIGNED_ADDRESSES;
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

  EncodableList live_addresses;
  if (addr_result == ZTS_ERR_OK) {
    for (unsigned int i = 0; i < assigned_addr_count; ++i) {
      const std::string address = ExtractAddress(assigned_addrs[i]);
      if (!address.empty()) {
        live_addresses.emplace_back(address);
      }
    }
  }

  EncodableMap result{
      {EncodableValue("networkId"), EncodableValue(ToHexNetworkId(network_id))},
      {EncodableValue("statusCode"), EncodableValue(status_code)},
      {EncodableValue("status"),
       EncodableValue(NetworkStatusToString(status_code))},
      {EncodableValue("transportReady"), EncodableValue(transport_ready)},
      {EncodableValue("addrResult"), EncodableValue(addr_result)},
      {EncodableValue("addrResultName"),
       EncodableValue(ErrorCodeToString(addr_result))},
      {EncodableValue("assignedAddrCount"),
       EncodableValue(static_cast<int64_t>(assigned_addr_count))},
      {EncodableValue("networkType"), EncodableValue(network_type)},
      {EncodableValue("nameResult"), EncodableValue(name_result)},
      {EncodableValue("liveAssignedAddresses"),
       EncodableValue(live_addresses)},
  };

  std::scoped_lock lock(mutex_);
  const auto it = networks_.find(network_id);
  if (it != networks_.end()) {
    result[EncodableValue("runtimeRecord")] =
        EncodableValue(BuildNetworkMap(it->second));
  }
  result[EncodableValue("serviceState")] = EncodableValue(BuildServiceState());
  result[EncodableValue("nodeOnline")] = EncodableValue(node_online_);
  result[EncodableValue("nodeStarted")] = EncodableValue(node_started_);
  result[EncodableValue("lastError")] = EncodableValue(last_error_);
  result[EncodableValue("networkNameFromProbe")] =
      EncodableValue(name_result == ZTS_ERR_OK ? std::string(network_name_buffer)
                                               : std::string());
  return result;
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
    case ZTS_EVENT_NETWORK_UPDATE:
      return "ZTS_EVENT_NETWORK_UPDATE";
    case ZTS_EVENT_NETWORK_ACCESS_DENIED:
      return "ZTS_EVENT_NETWORK_ACCESS_DENIED";
    case ZTS_EVENT_NETWORK_READY_IP4:
      return "ZTS_EVENT_NETWORK_READY_IP4";
    case ZTS_EVENT_NETWORK_READY_IP6:
      return "ZTS_EVENT_NETWORK_READY_IP6";
    case ZTS_EVENT_NETWORK_READY_IP4_IP6:
      return "ZTS_EVENT_NETWORK_READY_IP4_IP6";
    case ZTS_EVENT_NETWORK_DOWN:
      return "ZTS_EVENT_NETWORK_DOWN";
    case ZTS_EVENT_ADDR_ADDED_IP4:
      return "ZTS_EVENT_ADDR_ADDED_IP4";
    case ZTS_EVENT_ADDR_ADDED_IP6:
      return "ZTS_EVENT_ADDR_ADDED_IP6";
    case ZTS_EVENT_PEER_DIRECT:
      return "ZTS_EVENT_PEER_DIRECT";
    case ZTS_EVENT_PEER_RELAY:
      return "ZTS_EVENT_PEER_RELAY";
    case ZTS_EVENT_PEER_UNREACHABLE:
      return "ZTS_EVENT_PEER_UNREACHABLE";
    case ZTS_EVENT_PEER_PATH_DISCOVERED:
      return "ZTS_EVENT_PEER_PATH_DISCOVERED";
    case ZTS_EVENT_PEER_PATH_DEAD:
      return "ZTS_EVENT_PEER_PATH_DEAD";
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

  const bool process_elevated = IsProcessElevated();
  EncodableMap permission_state{
      {EncodableValue("isGranted"), EncodableValue(process_elevated)},
      {EncodableValue("requiresManualSetup"), EncodableValue(!process_elevated)},
      {EncodableValue("isFirewallSupported"), EncodableValue(true)},
      {EncodableValue("summary"),
       EncodableValue(process_elevated
                          ? "Windows libzt runtime is active."
                          : "Administrator privileges are required for Windows IP and route mounting.")},
  };
  const EncodableMap adapter_payload = BuildAdapterDiagnosticsPayloadLocked();
  const auto summary_it =
      adapter_payload.find(EncodableValue("summary"));
  if (summary_it != adapter_payload.end() &&
      std::holds_alternative<std::string>(summary_it->second) &&
      process_elevated) {
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
      {EncodableValue("transportDiagnostics"),
       EncodableValue(BuildTransportDiagnosticsSummaryLocked())},
      {EncodableValue("peerDiagnostics"),
       EncodableValue(BuildRecentPeerDiagnosticsLocked())},
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
  EncodableList mount_candidate_names;
  for (const auto& item : network.mount_candidate_names) {
    mount_candidate_names.emplace_back(item);
  }
  return EncodableMap{
      {EncodableValue("networkId"), EncodableValue(ToHexNetworkId(network.network_id))},
      {EncodableValue("networkName"), EncodableValue(network.network_name)},
      {EncodableValue("status"), EncodableValue(network.status)},
      {EncodableValue("assignedAddresses"), EncodableValue(assigned_addresses)},
      {EncodableValue("isAuthorized"), EncodableValue(network.is_authorized)},
      {EncodableValue("isConnected"), EncodableValue(network.is_connected)},
      {EncodableValue("localInterfaceReady"),
       EncodableValue(network.local_interface_ready)},
      {EncodableValue("matchedInterfaceName"),
       EncodableValue(network.matched_interface_name)},
      {EncodableValue("matchedInterfaceIfIndex"),
       EncodableValue(static_cast<int64_t>(network.matched_interface_if_index))},
      {EncodableValue("matchedInterfaceUp"),
       EncodableValue(network.matched_interface_up)},
      {EncodableValue("mountDriverKind"),
       EncodableValue(network.mount_driver_kind)},
      {EncodableValue("mountCandidateNames"),
       EncodableValue(mount_candidate_names)},
      {EncodableValue("expectedRouteCount"),
       EncodableValue(network.expected_route_count)},
      {EncodableValue("routeExpected"),
       EncodableValue(network.route_expected)},
      {EncodableValue("systemIpBound"),
       EncodableValue(network.system_ip_bound)},
      {EncodableValue("systemRouteBound"),
       EncodableValue(network.system_route_bound)},
      {EncodableValue("tapMediaStatus"),
       EncodableValue(network.tap_media_status)},
      {EncodableValue("tapDeviceInstanceId"),
       EncodableValue(network.tap_device_instance_id)},
      {EncodableValue("tapNetCfgInstanceId"),
       EncodableValue(network.tap_netcfg_instance_id)},
      {EncodableValue("localMountState"),
       EncodableValue(network.local_mount_state)},
      {EncodableValue("lastEventCode"),
       EncodableValue(network.last_event_code)},
      {EncodableValue("lastEventName"),
       EncodableValue(network.last_event_name)},
      {EncodableValue("lastEventAtUtc"),
       EncodableValue(network.last_event_at_utc)},
      {EncodableValue("lastEventStatusCode"),
       EncodableValue(network.last_event_status_code)},
      {EncodableValue("lastEventNetworkType"),
       EncodableValue(network.last_event_network_type)},
      {EncodableValue("lastEventNetconfRev"),
       EncodableValue(network.last_event_netconf_rev)},
      {EncodableValue("lastEventAssignedAddrCount"),
       EncodableValue(network.last_event_assigned_addr_count)},
      {EncodableValue("lastEventTransportReady"),
       EncodableValue(network.last_event_transport_ready)},
      {EncodableValue("lastProbeStatusCode"),
       EncodableValue(network.last_probe_status_code)},
      {EncodableValue("lastProbeAtUtc"),
       EncodableValue(network.last_probe_at_utc)},
      {EncodableValue("lastProbeTransportReady"),
       EncodableValue(network.last_probe_transport_ready)},
      {EncodableValue("lastProbeAddrResult"),
       EncodableValue(network.last_probe_addr_result)},
      {EncodableValue("lastProbeAddrResultName"),
       EncodableValue(network.last_probe_addr_result_name)},
      {EncodableValue("lastProbeAssignedAddrCount"),
       EncodableValue(network.last_probe_assigned_addr_count)},
      {EncodableValue("lastProbeNetworkType"),
       EncodableValue(network.last_probe_network_type)},
      {EncodableValue("lastProbePendingJoin"),
       EncodableValue(network.last_probe_pending_join)},
      {EncodableValue("joinTraceStartedAtUtc"),
       EncodableValue(network.join_trace_started_at_utc)},
      {EncodableValue("joinEventSequence"),
       EncodableValue(network.join_event_sequence)},
      {EncodableValue("joinSawReqConfig"),
       EncodableValue(network.join_saw_req_config)},
      {EncodableValue("joinSawReadyIp4"),
       EncodableValue(network.join_saw_ready_ip4)},
      {EncodableValue("joinSawReadyIp6"),
       EncodableValue(network.join_saw_ready_ip6)},
      {EncodableValue("joinSawReadyIp4Ip6"),
       EncodableValue(network.join_saw_ready_ip4_ip6)},
      {EncodableValue("joinSawNetworkOk"),
       EncodableValue(network.join_saw_network_ok)},
      {EncodableValue("joinSawNetworkDown"),
       EncodableValue(network.join_saw_network_down)},
      {EncodableValue("joinSawAddrAddedIp4"),
       EncodableValue(network.join_saw_addr_added_ip4)},
      {EncodableValue("joinSawAddrAddedIp6"),
       EncodableValue(network.join_saw_addr_added_ip6)},
      {EncodableValue("joinTraceActive"),
       EncodableValue(network.join_trace_active)},
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
      {EncodableValue("stopRequested"), EncodableValue(stop_requested_)},
      {EncodableValue("pendingJoinCount"),
       EncodableValue(static_cast<int64_t>(pending_join_networks_.size()))},
      {EncodableValue("knownNetworkCount"),
       EncodableValue(static_cast<int64_t>(known_network_ids_.size()))},
      {EncodableValue("joinedNetworkCount"),
       EncodableValue(static_cast<int64_t>(networks_.size()))},
      {EncodableValue("lastError"),
       last_error_.empty() ? EncodableValue() : EncodableValue(last_error_)},
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
        {EncodableValue("lastEventName"),
         EncodableValue(network.last_event_name)},
        {EncodableValue("lastProbeAddrResultName"),
         EncodableValue(network.last_probe_addr_result_name)},
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
      {EncodableValue("localInterfaceReady"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.local_interface_ready)},
      {EncodableValue("matchedInterfaceName"),
       EncodableValue(network_it == networks_.end()
                          ? ""
                          : network_it->second.matched_interface_name)},
      {EncodableValue("matchedInterfaceIfIndex"),
       EncodableValue(network_it == networks_.end()
                          ? static_cast<int64_t>(0)
                          : static_cast<int64_t>(
                                network_it->second.matched_interface_if_index))},
      {EncodableValue("matchedInterfaceUp"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.matched_interface_up)},
      {EncodableValue("mountDriverKind"),
       EncodableValue(network_it == networks_.end()
                          ? "unknown"
                          : network_it->second.mount_driver_kind)},
      {EncodableValue("expectedRouteCount"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.expected_route_count)},
      {EncodableValue("routeExpected"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.route_expected)},
      {EncodableValue("systemIpBound"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.system_ip_bound)},
      {EncodableValue("systemRouteBound"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.system_route_bound)},
      {EncodableValue("tapMediaStatus"),
       EncodableValue(network_it == networks_.end()
                          ? "unknown"
                          : network_it->second.tap_media_status)},
      {EncodableValue("tapDeviceInstanceId"),
       EncodableValue(network_it == networks_.end()
                          ? ""
                          : network_it->second.tap_device_instance_id)},
      {EncodableValue("tapNetCfgInstanceId"),
       EncodableValue(network_it == networks_.end()
                          ? ""
                          : network_it->second.tap_netcfg_instance_id)},
      {EncodableValue("localMountState"),
       EncodableValue(network_it == networks_.end()
                          ? "unknown"
                          : network_it->second.local_mount_state)},
      {EncodableValue("networkAddressCount"),
       EncodableValue(static_cast<int>(
           network_it == networks_.end()
               ? 0
               : network_it->second.assigned_addresses.size()))},
      {EncodableValue("networkAddresses"), EncodableValue(network_addresses)},
      {EncodableValue("lastEventCode"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.last_event_code)},
      {EncodableValue("lastEventName"),
       EncodableValue(network_it == networks_.end()
                          ? ""
                          : network_it->second.last_event_name)},
      {EncodableValue("lastEventAtUtc"),
       EncodableValue(network_it == networks_.end()
                          ? ""
                          : network_it->second.last_event_at_utc)},
      {EncodableValue("lastEventStatusCode"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.last_event_status_code)},
      {EncodableValue("lastEventNetworkType"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.last_event_network_type)},
      {EncodableValue("lastEventNetconfRev"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.last_event_netconf_rev)},
      {EncodableValue("lastEventAssignedAddrCount"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.last_event_assigned_addr_count)},
      {EncodableValue("lastEventTransportReady"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.last_event_transport_ready)},
      {EncodableValue("lastProbeStatusCode"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.last_probe_status_code)},
      {EncodableValue("lastProbeAtUtc"),
       EncodableValue(network_it == networks_.end()
                          ? ""
                          : network_it->second.last_probe_at_utc)},
      {EncodableValue("lastProbeTransportReady"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.last_probe_transport_ready)},
      {EncodableValue("lastProbeAddrResult"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.last_probe_addr_result)},
      {EncodableValue("lastProbeAddrResultName"),
       EncodableValue(network_it == networks_.end()
                          ? ""
                          : network_it->second.last_probe_addr_result_name)},
      {EncodableValue("lastProbeAssignedAddrCount"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.last_probe_assigned_addr_count)},
      {EncodableValue("lastProbeNetworkType"),
       EncodableValue(network_it == networks_.end()
                          ? 0
                          : network_it->second.last_probe_network_type)},
      {EncodableValue("lastProbePendingJoin"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.last_probe_pending_join)},
      {EncodableValue("joinTraceStartedAtUtc"),
       EncodableValue(network_it == networks_.end()
                          ? ""
                          : network_it->second.join_trace_started_at_utc)},
      {EncodableValue("joinEventSequence"),
       EncodableValue(network_it == networks_.end()
                          ? ""
                          : network_it->second.join_event_sequence)},
      {EncodableValue("joinSawReqConfig"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.join_saw_req_config)},
      {EncodableValue("joinSawReadyIp4"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.join_saw_ready_ip4)},
      {EncodableValue("joinSawReadyIp6"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.join_saw_ready_ip6)},
      {EncodableValue("joinSawReadyIp4Ip6"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.join_saw_ready_ip4_ip6)},
      {EncodableValue("joinSawNetworkOk"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.join_saw_network_ok)},
      {EncodableValue("joinSawNetworkDown"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.join_saw_network_down)},
      {EncodableValue("joinSawAddrAddedIp4"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.join_saw_addr_added_ip4)},
      {EncodableValue("joinSawAddrAddedIp6"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.join_saw_addr_added_ip6)},
      {EncodableValue("joinTraceActive"),
       EncodableValue(network_it == networks_.end()
                          ? false
                          : network_it->second.join_trace_active)},
      {EncodableValue("adapterBridge"),
       EncodableValue(BuildAdapterDiagnosticsPayloadLocked())},
  };
}

flutter::EncodableMap
ZeroTierWindowsRuntime::BuildAdapterDiagnosticsPayloadLocked() const {
  EncodableList adapters;
  for (const auto& adapter : adapter_probe_.adapters) {
    EncodableList ipv4_addresses;
    for (const auto& address : adapter.ipv4_addresses) {
      ipv4_addresses.emplace_back(address);
    }
    adapters.emplace_back(EncodableMap{
        {EncodableValue("adapterName"), EncodableValue(adapter.adapter_name)},
        {EncodableValue("friendlyName"), EncodableValue(adapter.friendly_name)},
        {EncodableValue("description"), EncodableValue(adapter.description)},
        {EncodableValue("ifIndex"),
         EncodableValue(static_cast<int64_t>(adapter.if_index))},
        {EncodableValue("luid"),
         EncodableValue(static_cast<int64_t>(adapter.luid))},
        {EncodableValue("operStatus"), EncodableValue(adapter.oper_status)},
        {EncodableValue("isUp"), EncodableValue(adapter.is_up)},
        {EncodableValue("isVirtual"), EncodableValue(adapter.is_virtual)},
        {EncodableValue("isMountCandidate"),
         EncodableValue(adapter.is_mount_candidate)},
        {EncodableValue("matchesExpectedIp"),
         EncodableValue(adapter.matches_expected_ip)},
        {EncodableValue("hasExpectedRoute"),
         EncodableValue(adapter.has_expected_route)},
        {EncodableValue("driverKind"), EncodableValue(adapter.driver_kind)},
        {EncodableValue("mediaStatus"), EncodableValue(adapter.media_status)},
        {EncodableValue("tapDeviceInstanceId"),
         EncodableValue(adapter.device_instance_id)},
        {EncodableValue("tapNetCfgInstanceId"),
         EncodableValue(adapter.netcfg_instance_id)},
        {EncodableValue("driverServiceName"),
         EncodableValue(adapter.driver_service_name)},
        {EncodableValue("ipv4Addresses"), EncodableValue(ipv4_addresses)},
    });
  }
  EncodableList adapter_names;
  for (const auto& item : adapter_probe_.virtual_adapter_names) {
    adapter_names.emplace_back(item);
  }
  EncodableList matched_adapter_names;
  for (const auto& item : adapter_probe_.matched_adapter_names) {
    matched_adapter_names.emplace_back(item);
  }
  EncodableList mount_candidate_names;
  for (const auto& item : adapter_probe_.mount_candidate_names) {
    mount_candidate_names.emplace_back(item);
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
      {EncodableValue("mountBackend"), EncodableValue(tap_backend_id_)},
      {EncodableValue("hasVirtualAdapter"),
       EncodableValue(adapter_probe_.has_virtual_adapter)},
      {EncodableValue("hasMountCandidate"),
       EncodableValue(adapter_probe_.has_mount_candidate)},
      {EncodableValue("hasExpectedNetworkIp"),
       EncodableValue(adapter_probe_.has_expected_network_ip)},
      {EncodableValue("hasExpectedRoute"),
       EncodableValue(adapter_probe_.has_expected_route)},
      {EncodableValue("virtualAdapterNames"), EncodableValue(adapter_names)},
      {EncodableValue("matchedAdapterNames"),
       EncodableValue(matched_adapter_names)},
      {EncodableValue("mountCandidateNames"),
       EncodableValue(mount_candidate_names)},
      {EncodableValue("detectedIpv4Addresses"), EncodableValue(detected_ips)},
      {EncodableValue("expectedIpv4Addresses"), EncodableValue(expected_ips)},
      {EncodableValue("adapters"), EncodableValue(adapters)},
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

  std::string service_sync_detail;
  if (!EnsurePrivilegedMountServiceBinaryCurrent(&service_sync_detail)) {
    SetLastErrorLocked("privileged mount service sync failed: " +
                       service_sync_detail);
    if (error_message != nullptr) {
      *error_message = last_error_;
    }
    return false;
  }
  if (!service_sync_detail.empty()) {
    LogNodeTrace("privileged_mount_service_sync detail=" + service_sync_detail);
  }

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
  if (tap_backend_ != nullptr) {
    LoadKnownNetworkIdsLocked();
    std::vector<uint64_t> prepare_network_ids;
    prepare_network_ids.reserve(known_network_ids_.size());
    for (const uint64_t network_id : known_network_ids_) {
      prepare_network_ids.push_back(network_id);
    }
    std::string backend_action;
    const bool backend_changed = tap_backend_->EnsureAdapterPresent(
        adapter_probe_, prepare_network_ids, {}, &backend_action);
    if (backend_changed) {
      std::ostringstream stream;
      stream << "tap_backend_ensure_adapter"
             << " phase=prepare"
             << " backend=" << tap_backend_id_
             << " changed=" << BoolLabel(backend_changed)
             << " has_virtual_adapter="
             << BoolLabel(adapter_probe_.has_virtual_adapter)
             << " has_mount_candidate="
             << BoolLabel(adapter_probe_.has_mount_candidate)
             << " has_expected_network_ip="
             << BoolLabel(adapter_probe_.has_expected_network_ip)
             << " action=" << (backend_action.empty() ? "-" : backend_action);
      LogNodeTrace(stream.str());
    }
    if (backend_changed) {
      constexpr int kProbeRetryCount = 6;
      for (int attempt = 0; attempt < kProbeRetryCount; ++attempt) {
        adapter_probe_ = adapter_bridge_.Refresh({});
        if (adapter_probe_.has_virtual_adapter || adapter_probe_.has_mount_candidate) {
          break;
        }
        Sleep(250);
      }
    }
  }
  {
    const std::filesystem::path host_exe = CurrentExecutablePath();
    DWORD firewall_helper_exit = NO_ERROR;
    std::string firewall_helper_debug;
    const bool firewall_ready =
        EnsureFirewallRulesForCurrentHostExe(&firewall_helper_exit,
                                             &firewall_helper_debug);
    std::ostringstream stream;
    stream << "firewall_host_rule"
           << " exe="
           << (host_exe.empty() ? "-" : host_exe.u8string())
           << " ready=" << BoolLabel(firewall_ready)
           << " helper_exit_code=" << firewall_helper_exit
           << " detail="
           << (firewall_helper_debug.empty() ? "-" : firewall_helper_debug);
    LogNodeTrace(stream.str());
  }
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
    StartNode();
  }

  std::unique_lock lock(mutex_);
  const bool ready = state_cv_.wait_for(lock, std::chrono::seconds(20), [this]() {
    return node_online_ || !last_error_.empty() || !node_started_;
  });

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
  const char* event_name = EventCodeToString(event->event_code);
  const bool should_log_event =
      event->event_code == ZTS_EVENT_NODE_OFFLINE ||
      event->event_code == ZTS_EVENT_NODE_DOWN;
  if (event_name != nullptr && should_log_event) {
    std::ostringstream stream;
    stream << "libzt_event"
           << " code=" << event->event_code
           << " name=" << event_name;
    if (event->node != nullptr) {
      stream << " node_id=" << ToHexNetworkId(event->node->node_id)
             << " port=" << event->node->port_primary;
    }
    if (event->peer != nullptr) {
      stream << " " << PeerSummary(event->peer);
    }
    LogNodeTrace(stream.str());
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
    if (event->peer != nullptr && event->peer->peer_id != 0) {
      observed_peer_ids_.insert(event->peer->peer_id);
    }
  }

  if (event->network != nullptr) {
    UpdateNetworkFromLibztMessage(message_ptr);
  }
  if (event->addr != nullptr) {
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
#if defined(ZT_VERBOSE_PACKET_LOGGING)
        std::ostringstream stream;
        stream << "node_online"
               << " trigger=" << DescribeNodeTriggerLocked("nodeOnline")
               << " last_control_hint="
               << (last_node_control_hint_.empty() ? "-" : last_node_control_hint_)
               << " last_control_at="
               << (last_node_control_at_utc_.empty() ? "-" : last_node_control_at_utc_)
               << " service_state=" << BuildServiceState()
               << " tracked_networks=" << SummarizeTrackedNetworksLocked()
               << " transport=" << BuildTransportDiagnosticsSummaryLocked()
               << " peers=" << BuildRecentPeerDiagnosticsLocked()
               << " sockets="
               << SummarizeUdpEndpointsForPid(GetCurrentProcessId(), node_port_);
        LogNodeTrace(stream.str());
#endif
      }
      EmitEvent(BuildEvent("nodeOnline", "ZeroTier node is online.", "",
                           payload));
      break;
    }
    case ZTS_EVENT_NODE_OFFLINE: {
      const std::string message = "ZeroTier node is offline.";
      flutter::EncodableMap payload;
      std::vector<uint64_t> pending_join_ids;
      std::string last_join_probe;
      {
        std::scoped_lock lock(mutex_);
        node_online_ = false;
        node_offline_ = true;
        ClearLastErrorLocked();
        payload = BuildNodeDiagnosticsPayloadLocked(event->event_code);
        pending_join_ids.assign(pending_join_networks_.begin(),
                                pending_join_networks_.end());
        std::ostringstream stream;
        stream << "node_offline"
               << " trigger=" << DescribeNodeTriggerLocked("nodeOffline")
               << " last_control_hint="
               << (last_node_control_hint_.empty() ? "-" : last_node_control_hint_)
               << " last_control_at="
               << (last_node_control_at_utc_.empty() ? "-" : last_node_control_at_utc_)
               << " pending_join_count=" << pending_join_networks_.size()
               << " leave_request_count=" << leave_request_sources_.size()
               << " service_state=" << BuildServiceState()
               << " node_started=" << BoolLabel(node_started_)
               << " node_online=" << BoolLabel(node_online_)
               << " node_offline=" << BoolLabel(node_offline_)
               << " last_error=" << (last_error_.empty() ? "-" : last_error_)
               << " tracked_networks=" << SummarizeTrackedNetworksLocked()
               << " transport=" << BuildTransportDiagnosticsSummaryLocked()
               << " peers=" << BuildRecentPeerDiagnosticsLocked()
               << " sockets="
               << SummarizeUdpEndpointsForPid(GetCurrentProcessId(), node_port_);
        LogNodeTrace(stream.str());
        if (last_node_control_hint_.rfind("joinNetwork.request:", 0) == 0) {
          const std::string network_id_hex =
              last_node_control_hint_.substr(
                  std::string("joinNetwork.request:").size());
          if (!network_id_hex.empty()) {
            std::stringstream parser;
            parser << std::hex << network_id_hex;
            uint64_t parsed_network_id = 0;
            parser >> parsed_network_id;
            if (parsed_network_id != 0) {
              last_join_probe = BuildLiveNetworkProbeSummary(parsed_network_id);
            }
          }
        }
      }
      if (!last_join_probe.empty()) {
        LogNodeTrace("node_offline_last_join_probe " + last_join_probe);
      }
      for (const uint64_t pending_network_id : pending_join_ids) {
        LogNodeTrace("node_offline_pending_join_probe " +
                     BuildLiveNetworkProbeSummary(pending_network_id));
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
        std::ostringstream stream;
        stream << "node_down"
               << " trigger=" << DescribeNodeTriggerLocked("nodeDown")
               << " last_control_hint="
               << (last_node_control_hint_.empty() ? "-" : last_node_control_hint_)
               << " last_control_at="
               << (last_node_control_at_utc_.empty() ? "-" : last_node_control_at_utc_)
               << " emit_error=" << BoolLabel(emit_error)
               << " tracked_networks=" << SummarizeTrackedNetworksLocked();
        LogNodeTrace(stream.str());
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
      bool log_join_event = false;
      {
        std::scoped_lock lock(mutex_);
        ClearLastErrorLocked();
        log_join_event =
            event->network != nullptr &&
            pending_join_networks_.find(event->network->net_id) !=
                pending_join_networks_.end();
        payload = BuildNetworkDiagnosticsPayloadLocked(
            event->network == nullptr ? 0 : event->network->net_id,
            event->event_code, "networkRequestConfig");
      }
      if (log_join_event && event->network != nullptr) {
        LogNodeTrace("join_event event=REQ_CONFIG " +
                     BuildLiveNetworkProbeSummary(event->network->net_id));
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
      bool log_join_event = false;
      flutter::EncodableMap payload;
      {
        std::scoped_lock lock(mutex_);
        ClearLastErrorLocked();
        if (event->network != nullptr &&
            leaving_networks_.find(event->network->net_id) != leaving_networks_.end()) {
          suppress_event = true;
        }
        log_join_event =
            event->network != nullptr &&
            pending_join_networks_.find(event->network->net_id) !=
                pending_join_networks_.end();
        payload = BuildNetworkDiagnosticsPayloadLocked(
            event->network == nullptr ? 0 : event->network->net_id,
            event->event_code, "networkReady");
        if (event->event_code == ZTS_EVENT_NETWORK_OK &&
            event->network != nullptr) {
          const auto network_it = networks_.find(event->network->net_id);
          if (network_it != networks_.end() &&
              pending_join_networks_.find(event->network->net_id) !=
                  pending_join_networks_.end() &&
              !network_it->second.join_saw_ready_ip4 &&
              !network_it->second.join_saw_ready_ip6 &&
              !network_it->second.join_saw_ready_ip4_ip6 &&
              !network_it->second.join_saw_addr_added_ip4 &&
              !network_it->second.join_saw_addr_added_ip6) {
          }
        }
      }
      if (log_join_event && event->network != nullptr) {
        const char* join_event_name = EventCodeToString(event->event_code);
        LogNodeTrace(
            std::string("join_event event=") +
            (join_event_name == nullptr ? "UNKNOWN" : join_event_name) + " " +
            BuildLiveNetworkProbeSummary(event->network->net_id));
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
      bool suppress_transient_network_down_error = false;
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
            suppress_transient_network_down_error =
                it->second.system_ip_bound ||
                (!it->second.assigned_addresses.empty() &&
                 it->second.matched_interface_if_index != 0);
            it->second.status = "NETWORK_DOWN";
            it->second.is_connected = false;
            it->second.is_authorized = false;
            if (!suppress_transient_network_down_error) {
              it->second.assigned_addresses.clear();
            }
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
        if (suppress_transient_network_down_error) {
          LogNodeTrace("network_down_transient_suppressed network_id=" +
                       (event->network == nullptr ? ""
                                                  : ToHexNetworkId(event->network->net_id)));
          break;
        }
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

  int transport_ready = 0;
  {
    std::scoped_lock api_lock(api_mutex_);
    transport_ready = zts_net_transport_is_ready(event->network->net_id);
  }
  std::scoped_lock lock(mutex_);
  const zts_net_info_t* network = event->network;
  if (leaving_networks_.find(network->net_id) != leaving_networks_.end()) {
    return;
  }
  auto& record = networks_[network->net_id];
  const ZeroTierWindowsNetworkRecord previous_record = record;
  const bool join_trace_active =
      previous_record.join_trace_active ||
      pending_join_networks_.find(network->net_id) != pending_join_networks_.end();
  RememberKnownNetworkLocked(network->net_id);
  ZeroTierWindowsNetworkRecord next_record;
  next_record.network_id = network->net_id;
  next_record.network_name = network->name == nullptr ? "" : network->name;
  next_record.status = NetworkStatusToString(network->status);
  const bool stale_addresses = ShouldTreatAddressesAsStale(next_record.status);
  next_record.last_event_code = event->event_code;
  next_record.last_event_name =
      EventCodeToString(event->event_code) == nullptr
          ? "UNKNOWN_EVENT"
          : EventCodeToString(event->event_code);
  next_record.last_event_at_utc = Iso8601NowUtc();
  next_record.last_event_status_code = network->status;
  next_record.last_event_network_type = network->type;
  next_record.last_event_netconf_rev = network->netconf_rev;
  next_record.last_event_assigned_addr_count =
      static_cast<int>(network->assigned_addr_count);
  next_record.last_event_transport_ready = transport_ready;
  next_record.join_trace_started_at_utc = previous_record.join_trace_started_at_utc;
  next_record.join_event_sequence = previous_record.join_event_sequence;
  next_record.join_saw_req_config = previous_record.join_saw_req_config;
  next_record.join_saw_ready_ip4 = previous_record.join_saw_ready_ip4;
  next_record.join_saw_ready_ip6 = previous_record.join_saw_ready_ip6;
  next_record.join_saw_ready_ip4_ip6 = previous_record.join_saw_ready_ip4_ip6;
  next_record.join_saw_network_ok = previous_record.join_saw_network_ok;
  next_record.join_saw_network_down = previous_record.join_saw_network_down;
  next_record.join_saw_addr_added_ip4 = previous_record.join_saw_addr_added_ip4;
  next_record.join_saw_addr_added_ip6 = previous_record.join_saw_addr_added_ip6;
  next_record.join_trace_active = join_trace_active;
  if (join_trace_active && next_record.join_trace_started_at_utc.empty()) {
    next_record.join_trace_started_at_utc = Iso8601NowUtc();
  }
  if (join_trace_active) {
    AppendJoinTraceEvent(&next_record, event->event_code,
                         EventCodeToString(event->event_code));
  }
  next_record.is_authorized =
      network->status == ZTS_NETWORK_STATUS_OK ||
      network->type == ZTS_NETWORK_TYPE_PUBLIC;
  next_record.is_connected =
      !stale_addresses &&
      (transport_ready > 0 || network->assigned_addr_count > 0);
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
      previous_record.local_interface_ready &&
      next_record.status == "REQUESTING_CONFIGURATION" &&
      !next_record.is_connected && next_record.assigned_addresses.empty();
  if (!should_keep_previous_ready_state) {
    next_record.last_probe_status_code = previous_record.last_probe_status_code;
    next_record.last_probe_at_utc = previous_record.last_probe_at_utc;
    next_record.last_probe_transport_ready =
        previous_record.last_probe_transport_ready;
    next_record.last_probe_addr_result = previous_record.last_probe_addr_result;
    next_record.last_probe_addr_result_name =
        previous_record.last_probe_addr_result_name;
    next_record.last_probe_assigned_addr_count =
        previous_record.last_probe_assigned_addr_count;
    next_record.last_probe_network_type =
        previous_record.last_probe_network_type;
    next_record.last_probe_pending_join =
        previous_record.last_probe_pending_join;
    record = std::move(next_record);
  }
  if (record.local_interface_ready || record.is_connected ||
      !record.assigned_addresses.empty()) {
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
  if (record.join_trace_active ||
      pending_join_networks_.find(event->addr->net_id) != pending_join_networks_.end()) {
    if (record.join_trace_started_at_utc.empty()) {
      record.join_trace_started_at_utc = Iso8601NowUtc();
    }
    record.join_trace_active = true;
    AppendJoinTraceEvent(&record, event->event_code,
                         EventCodeToString(event->event_code));
  }
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

std::string ZeroTierWindowsRuntime::ExpectedWintunAdapterNameForNetwork(
    uint64_t network_id) const {
  return "FileTransferFlutter-" + ToHexNetworkId(network_id);
}

bool ZeroTierWindowsRuntime::TryBindSystemIpForNetwork(
    uint64_t network_id, const ZeroTierWindowsNetworkRecord& record,
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter,
    const std::map<std::string, uint8_t>& managed_prefix_hints,
    std::vector<MountedSystemIp>* created_ips) {
  if (created_ips != nullptr) {
    created_ips->clear();
  }
  if (record.assigned_addresses.empty() || adapter.if_index == 0) {
    return false;
  }

  bool bound_any = false;
  for (const auto& address : record.assigned_addresses) {
    in_addr parsed = {};
    if (!ParseIpv4(address, &parsed)) {
      std::ostringstream stream;
      stream << "ip_bind_skip"
             << " network_id=" << ToHexNetworkId(network_id)
             << " if_index=" << adapter.if_index
             << " address=" << address
             << " reason=parse_ipv4_failed";
      LogNodeTrace(stream.str());
      continue;
    }
    uint8_t prefix = 24;
    const auto managed_prefix_it = managed_prefix_hints.find(address);
    if (managed_prefix_it != managed_prefix_hints.end()) {
      prefix = ClampIpv4PrefixLength(managed_prefix_it->second);
    } else {
      const auto adapter_prefix_it = adapter.ipv4_prefix_lengths.find(address);
      if (adapter_prefix_it != adapter.ipv4_prefix_lengths.end()) {
        prefix = ClampIpv4PrefixLength(adapter_prefix_it->second);
      }
    }

    uint32_t created_context = 0;
    DWORD native_error = NO_ERROR;
    const EnsureIpResult ip_result = EnsureIpv4AddressOnInterface(
        adapter.if_index, parsed.S_un.S_addr, prefix, &created_context,
        &native_error);
    {
      std::ostringstream stream;
      stream << "ip_bind_attempt"
             << " network_id=" << ToHexNetworkId(network_id)
             << " if_index=" << adapter.if_index
             << " adapter_name="
             << (!adapter.friendly_name.empty()
                     ? adapter.friendly_name
                     : (!adapter.description.empty() ? adapter.description
                                                     : adapter.adapter_name))
             << " address=" << address
             << "/" << static_cast<int>(prefix)
             << " native_result=" << static_cast<int>(ip_result)
             << " native_error=" << native_error
             << " native_reason="
             << (native_error == ERROR_ACCESS_DENIED && !IsProcessElevated()
                     ? "permission_denied_non_elevated"
                     : "-")
             << " process_elevated=" << BoolLabel(IsProcessElevated())
             << " privileged_executor="
             << BoolLabel(IsPrivilegedMountExecutorEnabled())
             << " privileged_service="
             << BoolLabel(IsPrivilegedMountServiceEnabled());
      LogNodeTrace(stream.str());
    }
    if (ip_result == EnsureIpResult::kFailed) {
      const bool process_elevated = IsProcessElevated();
      const bool privileged_executor_enabled = IsPrivilegedMountExecutorEnabled();
      if (!process_elevated && !privileged_executor_enabled) {
        std::ostringstream stream;
        stream << "ip_bind_failed"
               << " network_id=" << ToHexNetworkId(network_id)
               << " if_index=" << adapter.if_index
               << " address=" << address
               << "/" << static_cast<int>(prefix)
               << " fallback_skipped=true"
               << " reason=not_elevated_and_no_executor"
               << " native_error=" << native_error;
        LogNodeTrace(stream.str());
        continue;
      }

      DWORD ps_exit_code = ERROR_GEN_FAILURE;
      std::string mount_executor = "powershell";
      const PowerShellMountResult ps_result =
          TryAddIpViaPowerShell(network_id, adapter.if_index, address, prefix,
                                &ps_exit_code, true, &mount_executor);
      {
        std::ostringstream stream;
        stream << "ip_bind_fallback"
               << " network_id=" << ToHexNetworkId(network_id)
               << " if_index=" << adapter.if_index
               << " address=" << address
               << "/" << static_cast<int>(prefix)
               << " executor=" << mount_executor
               << " ps_result=" << static_cast<int>(ps_result)
               << " ps_exit_code=" << ps_exit_code;
        LogNodeTrace(stream.str());
      }
      if (ps_result == PowerShellMountResult::kCreated ||
          ps_result == PowerShellMountResult::kExists) {
        bound_any = true;
        if (ps_result == PowerShellMountResult::kCreated && created_ips != nullptr) {
          created_ips->push_back(MountedSystemIp{
              adapter.if_index, parsed.S_un.S_addr, prefix, 0});
        }
      }
      continue;
    }
    bound_any = true;
    {
      std::ostringstream stream;
      stream << "ip_bind_success"
             << " network_id=" << ToHexNetworkId(network_id)
             << " if_index=" << adapter.if_index
             << " address=" << address
             << "/" << static_cast<int>(prefix)
             << " created_context=" << created_context
             << " created=" << BoolLabel(ip_result == EnsureIpResult::kCreated);
      LogNodeTrace(stream.str());
    }
    if (ip_result == EnsureIpResult::kCreated && created_ips != nullptr) {
      created_ips->push_back(MountedSystemIp{
          adapter.if_index, parsed.S_un.S_addr, prefix, created_context});
    }
  }
  return bound_any;
}

void ZeroTierWindowsRuntime::CleanupStaleSystemIpStateForNetwork(
    uint64_t network_id, const ZeroTierWindowsNetworkRecord& record,
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter,
    const std::map<std::string, uint8_t>& managed_prefix_hints) {
  if (adapter.if_index == 0) {
    return;
  }

  std::map<uint32_t, uint8_t> expected_ipv4_prefixes;
  for (const auto& address : record.assigned_addresses) {
    in_addr parsed = {};
    if (!ParseIpv4(address, &parsed)) {
      continue;
    }
    uint8_t prefix = 24;
    const auto managed_prefix_it = managed_prefix_hints.find(address);
    if (managed_prefix_it != managed_prefix_hints.end()) {
      prefix = ClampIpv4PrefixLength(managed_prefix_it->second);
    } else {
      const auto adapter_prefix_it = adapter.ipv4_prefix_lengths.find(address);
      if (adapter_prefix_it != adapter.ipv4_prefix_lengths.end()) {
        prefix = ClampIpv4PrefixLength(adapter_prefix_it->second);
      }
    }
    expected_ipv4_prefixes[parsed.S_un.S_addr] = prefix;
  }

  std::vector<MountedSystemIp> stale_ips;
  for (const auto& existing_address : adapter.ipv4_addresses) {
    in_addr parsed = {};
    if (!ParseIpv4(existing_address, &parsed)) {
      continue;
    }
    const uint32_t address_ipv4 = parsed.S_un.S_addr;
    const auto expected_it = expected_ipv4_prefixes.find(address_ipv4);
    uint8_t existing_prefix = 24;
    const auto adapter_prefix_it = adapter.ipv4_prefix_lengths.find(existing_address);
    if (adapter_prefix_it != adapter.ipv4_prefix_lengths.end()) {
      existing_prefix = ClampIpv4PrefixLength(adapter_prefix_it->second);
    }
    if (expected_it != expected_ipv4_prefixes.end() &&
        expected_it->second == existing_prefix) {
      continue;
    }
    stale_ips.push_back(
        MountedSystemIp{adapter.if_index, address_ipv4, existing_prefix, 0});
  }

  for (const auto& stale_ip : stale_ips) {
    char ip_text[INET_ADDRSTRLEN] = {0};
    in_addr ip_addr = {};
    ip_addr.S_un.S_addr = stale_ip.address_ipv4;
    inet_ntop(AF_INET, &ip_addr, ip_text, static_cast<DWORD>(sizeof(ip_text)));

    std::ostringstream stream;
    stream << "ip_cleanup_stale"
           << " network_id=" << ToHexNetworkId(network_id)
           << " if_index=" << stale_ip.if_index
           << " address=" << ip_text
           << "/" << static_cast<int>(stale_ip.prefix_length);
    LogNodeTrace(stream.str());

    DWORD ps_exit_code = NO_ERROR;
    std::string remove_executor = "-";
    const bool removed = TryRemoveIpViaPowerShell(network_id, stale_ip.if_index,
                                                  ip_text, &ps_exit_code, true,
                                                  &remove_executor);

    std::ostringstream remove_stream;
    remove_stream << "ip_cleanup_stale_result"
                  << " network_id=" << ToHexNetworkId(network_id)
                  << " if_index=" << stale_ip.if_index
                  << " address=" << ip_text
                  << "/" << static_cast<int>(stale_ip.prefix_length)
                  << " removed=" << BoolLabel(removed)
                  << " executor=" << remove_executor
                  << " ps_exit_code=" << ps_exit_code;
    LogNodeTrace(remove_stream.str());

    const uint32_t mask = PrefixMaskNetworkOrder(stale_ip.prefix_length);
    const uint32_t destination = stale_ip.address_ipv4 & mask;
    char destination_text[INET_ADDRSTRLEN] = {0};
    in_addr destination_addr = {};
    destination_addr.S_un.S_addr = destination;
    inet_ntop(AF_INET, &destination_addr, destination_text,
              static_cast<DWORD>(sizeof(destination_text)));
    const std::string cidr = std::string(destination_text) + "/" +
                             std::to_string(static_cast<int>(stale_ip.prefix_length));
    DWORD route_exit_code = NO_ERROR;
    std::string route_executor = "-";
    const bool route_removed = TryRemoveRouteViaPowerShell(
        network_id, stale_ip.if_index, cidr, &route_exit_code, true,
        &route_executor);

    std::ostringstream route_stream;
    route_stream << "route_cleanup_stale_result"
                 << " network_id=" << ToHexNetworkId(network_id)
                 << " if_index=" << stale_ip.if_index
                 << " cidr=" << cidr
                 << " removed=" << BoolLabel(route_removed)
                 << " executor=" << route_executor
                 << " ps_exit_code=" << route_exit_code;
    LogNodeTrace(route_stream.str());
  }
}

void ZeroTierWindowsRuntime::CleanupManagedIpv4OnForeignAdaptersForNetwork(
    uint64_t network_id, const ZeroTierWindowsNetworkRecord& record,
    const ZeroTierWindowsAdapterBridge::AdapterRecord& selected_adapter,
    const std::vector<ZeroTierWindowsAdapterBridge::AdapterRecord>& adapters,
    const std::map<std::string, uint8_t>& managed_prefix_hints) {
  if (selected_adapter.if_index == 0 || record.assigned_addresses.empty()) {
    return;
  }

  std::map<uint32_t, uint8_t> expected_ipv4_prefixes;
  for (const auto& address : record.assigned_addresses) {
    in_addr parsed = {};
    if (!ParseIpv4(address, &parsed)) {
      continue;
    }
    uint8_t prefix = 24;
    const auto managed_prefix_it = managed_prefix_hints.find(address);
    if (managed_prefix_it != managed_prefix_hints.end()) {
      prefix = ClampIpv4PrefixLength(managed_prefix_it->second);
    }
    expected_ipv4_prefixes[parsed.S_un.S_addr] = prefix;
  }

  for (const auto& adapter : adapters) {
    if (adapter.if_index == 0 || adapter.if_index == selected_adapter.if_index) {
      continue;
    }
    if (adapter.driver_kind != "wintun" && adapter.driver_kind != "wireguard") {
      continue;
    }
    for (const auto& existing_address : adapter.ipv4_addresses) {
      in_addr parsed = {};
      if (!ParseIpv4(existing_address, &parsed)) {
        continue;
      }
      const auto expected_it = expected_ipv4_prefixes.find(parsed.S_un.S_addr);
      if (expected_it == expected_ipv4_prefixes.end()) {
        continue;
      }
      uint8_t prefix = expected_it->second;
      const auto adapter_prefix_it = adapter.ipv4_prefix_lengths.find(existing_address);
      if (adapter_prefix_it != adapter.ipv4_prefix_lengths.end()) {
        prefix = ClampIpv4PrefixLength(adapter_prefix_it->second);
      }
      std::ostringstream stream;
      stream << "ip_cleanup_foreign_adapter"
             << " network_id=" << ToHexNetworkId(network_id)
             << " selected_if_index=" << selected_adapter.if_index
             << " foreign_if_index=" << adapter.if_index
             << " foreign_adapter="
             << (!adapter.friendly_name.empty()
                     ? adapter.friendly_name
                     : (!adapter.description.empty() ? adapter.description
                                                     : adapter.adapter_name))
             << " address=" << existing_address
             << "/" << static_cast<int>(prefix);
      LogNodeTrace(stream.str());
      DWORD ps_exit_code = NO_ERROR;
      std::string remove_executor = "-";
      const bool removed = TryRemoveIpViaPowerShell(
          network_id, adapter.if_index, existing_address, &ps_exit_code, true,
          &remove_executor);
      std::ostringstream result_stream;
      result_stream << "ip_cleanup_foreign_adapter_result"
                    << " network_id=" << ToHexNetworkId(network_id)
                    << " foreign_if_index=" << adapter.if_index
                    << " address=" << existing_address
                    << "/" << static_cast<int>(prefix)
                    << " removed=" << BoolLabel(removed)
                    << " executor=" << remove_executor
                    << " ps_exit_code=" << ps_exit_code;
      LogNodeTrace(result_stream.str());
    }
  }
}

bool ZeroTierWindowsRuntime::TryMountSystemRoutesForNetwork(
    uint64_t network_id, const ZeroTierWindowsNetworkRecord& record,
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter,
    const std::map<std::string, uint8_t>& managed_prefix_hints,
    std::vector<MountedSystemRoute>* created_routes,
    std::vector<MountedSystemRoute>* confirmed_routes) {
  if (created_routes != nullptr) {
    created_routes->clear();
  }
  if (confirmed_routes != nullptr) {
    confirmed_routes->clear();
  }
  if (!record.route_expected || record.assigned_addresses.empty() ||
      adapter.if_index == 0) {
    return false;
  }

  bool mounted_any_route = false;
  std::set<std::string> attempted_cidrs;

  for (const auto& address : record.assigned_addresses) {
    in_addr parsed = {};
    if (!ParseIpv4(address, &parsed)) {
      continue;
    }
    uint8_t prefix = 24;
    const auto managed_prefix_it = managed_prefix_hints.find(address);
    if (managed_prefix_it != managed_prefix_hints.end()) {
      prefix = ClampIpv4PrefixLength(managed_prefix_it->second);
    } else {
      const auto adapter_prefix_it = adapter.ipv4_prefix_lengths.find(address);
      if (adapter_prefix_it != adapter.ipv4_prefix_lengths.end()) {
        prefix = ClampIpv4PrefixLength(adapter_prefix_it->second);
      }
    }

    const uint32_t mask = PrefixMaskNetworkOrder(prefix);
    const uint32_t destination = parsed.S_un.S_addr & mask;

    char destination_text[INET_ADDRSTRLEN] = {0};
    in_addr destination_addr = {};
    destination_addr.S_un.S_addr = destination;
    inet_ntop(AF_INET, &destination_addr, destination_text,
              static_cast<DWORD>(sizeof(destination_text)));
    std::ostringstream cidr_stream;
    cidr_stream << destination_text << "/" << static_cast<int>(prefix);
    const std::string cidr = cidr_stream.str();
    if (!attempted_cidrs.insert(cidr).second) {
      continue;
    }

    DWORD native_error = NO_ERROR;
    const EnsureRouteResult route_result = EnsureOnLinkIpv4Route(
        adapter.if_index, destination, prefix, &native_error);
    if (route_result == EnsureRouteResult::kFailed) {
      const bool process_elevated = IsProcessElevated();
      const bool privileged_executor_enabled = IsPrivilegedMountExecutorEnabled();
      if (!process_elevated && !privileged_executor_enabled) {
        continue;
      }

      DWORD ps_exit_code = ERROR_GEN_FAILURE;
      std::string mount_executor = "powershell";
      const PowerShellMountResult ps_result =
          TryAddRouteViaPowerShell(adapter.if_index, cidr, &ps_exit_code, true,
                                   network_id, &mount_executor);
      if (ps_result == PowerShellMountResult::kCreated ||
          ps_result == PowerShellMountResult::kExists) {
        mounted_any_route = true;
        if (confirmed_routes != nullptr) {
          confirmed_routes->push_back(
              MountedSystemRoute{adapter.if_index, destination, prefix});
        }
        if (ps_result == PowerShellMountResult::kCreated &&
            created_routes != nullptr) {
          created_routes->push_back(
              MountedSystemRoute{adapter.if_index, destination, prefix});
        }
      }
      continue;
    }

    mounted_any_route = true;
    if (confirmed_routes != nullptr) {
      confirmed_routes->push_back(
          MountedSystemRoute{adapter.if_index, destination, prefix});
    }
    if (route_result == EnsureRouteResult::kCreated && created_routes != nullptr) {
      created_routes->push_back(
          MountedSystemRoute{adapter.if_index, destination, prefix});
    }
  }

  return mounted_any_route;
}

void ZeroTierWindowsRuntime::RecordMountedSystemRoutesLocked(
    uint64_t network_id, const std::vector<MountedSystemRoute>& created_routes) {
  if (network_id == 0 || created_routes.empty()) {
    return;
  }
  std::vector<MountedSystemRoute>& persisted = mounted_system_routes_[network_id];
  for (const auto& route : created_routes) {
    const bool already_tracked = std::any_of(
        persisted.begin(), persisted.end(),
        [&route](const MountedSystemRoute& existing) {
          return existing.if_index == route.if_index &&
                 existing.destination_ipv4 == route.destination_ipv4 &&
                 existing.prefix_length == route.prefix_length;
        });
    if (!already_tracked) {
      persisted.push_back(route);
    }
  }
}

void ZeroTierWindowsRuntime::RecordConfirmedSystemRoutesLocked(
    uint64_t network_id, const std::vector<MountedSystemRoute>& confirmed_routes) {
  if (network_id == 0 || confirmed_routes.empty()) {
    return;
  }
  std::vector<MountedSystemRoute>& persisted =
      confirmed_system_routes_[network_id];
  for (const auto& route : confirmed_routes) {
    const bool already_tracked = std::any_of(
        persisted.begin(), persisted.end(),
        [&route](const MountedSystemRoute& existing) {
          return existing.if_index == route.if_index &&
                 existing.destination_ipv4 == route.destination_ipv4 &&
                 existing.prefix_length == route.prefix_length;
        });
    if (!already_tracked) {
      persisted.push_back(route);
    }
  }
}

void ZeroTierWindowsRuntime::RecordMountedSystemIpsLocked(
    uint64_t network_id, const std::vector<MountedSystemIp>& created_ips) {
  if (network_id == 0 || created_ips.empty()) {
    return;
  }
  std::vector<MountedSystemIp>& persisted = mounted_system_ips_[network_id];
  for (const auto& ip : created_ips) {
    const bool already_tracked = std::any_of(
        persisted.begin(), persisted.end(), [&ip](const MountedSystemIp& existing) {
          return existing.if_index == ip.if_index &&
                 existing.address_ipv4 == ip.address_ipv4 &&
                 existing.prefix_length == ip.prefix_length;
        });
    if (!already_tracked) {
      persisted.push_back(ip);
    }
  }
}

void ZeroTierWindowsRuntime::RemoveMountedSystemRoutesForNetwork(
    uint64_t network_id, const std::string& source) {
  std::vector<MountedSystemRoute> routes;
  {
    std::scoped_lock lock(mutex_);
    confirmed_system_routes_.erase(network_id);
    const auto it = mounted_system_routes_.find(network_id);
    if (it != mounted_system_routes_.end()) {
      routes = it->second;
      mounted_system_routes_.erase(it);
    }
  }
  if (routes.empty()) {
    return;
  }

  for (const auto& route : routes) {
    char destination_text[INET_ADDRSTRLEN] = {0};
    in_addr destination_addr = {};
    destination_addr.S_un.S_addr = route.destination_ipv4;
    inet_ntop(AF_INET, &destination_addr, destination_text,
              static_cast<DWORD>(sizeof(destination_text)));
    const std::string cidr = std::string(destination_text) + "/" +
                             std::to_string(static_cast<int>(route.prefix_length));
    bool removed = RemoveOnLinkIpv4Route(route.if_index, route.destination_ipv4,
                                         route.prefix_length);
    DWORD ps_exit_code = NO_ERROR;
    std::string remove_executor = "-";
    if (!removed) {
      removed = TryRemoveRouteViaPowerShell(network_id, route.if_index, cidr,
                                            &ps_exit_code, true,
                                            &remove_executor);
    }
  }
}

void ZeroTierWindowsRuntime::RemoveMountedSystemIpsForNetwork(
    uint64_t network_id, const std::string& source) {
  std::vector<MountedSystemIp> ips;
  {
    std::scoped_lock lock(mutex_);
    const auto it = mounted_system_ips_.find(network_id);
    if (it == mounted_system_ips_.end()) {
      return;
    }
    ips = it->second;
    mounted_system_ips_.erase(it);
  }

  for (const auto& ip : ips) {
    char ip_text[INET_ADDRSTRLEN] = {0};
    in_addr ip_addr = {};
    ip_addr.S_un.S_addr = ip.address_ipv4;
    inet_ntop(AF_INET, &ip_addr, ip_text, static_cast<DWORD>(sizeof(ip_text)));
    bool removed = RemoveIpv4AddressOnInterface(ip.nte_context, ip.if_index,
                                                ip.address_ipv4);
    DWORD ps_exit_code = NO_ERROR;
    std::string remove_executor = "-";
    if (!removed) {
      removed = TryRemoveIpViaPowerShell(network_id, ip.if_index, ip_text,
                                         &ps_exit_code, true, &remove_executor);
    }
  }
}

void ZeroTierWindowsRuntime::RefreshSnapshot() {
  std::vector<uint64_t> known_network_ids;
  std::map<uint64_t, ZeroTierWindowsNetworkRecord> previous_networks;
  std::map<uint64_t, std::vector<MountedSystemRoute>> confirmed_routes_snapshot;
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
    confirmed_routes_snapshot = confirmed_system_routes_;
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
  std::map<uint64_t, std::map<std::string, uint8_t>> managed_ipv4_prefix_hints;
  std::map<uint64_t, std::vector<MountedSystemIp>> created_ips_by_network;
  std::map<uint64_t, std::vector<MountedSystemRoute>> created_routes_by_network;
  std::map<uint64_t, std::vector<MountedSystemRoute>> confirmed_routes_by_network;
  std::set<uint64_t> missing_network_ids;
  std::vector<std::string> expected_addresses;
  const bool process_elevated = IsProcessElevated();
  const bool privileged_executor_enabled = IsPrivilegedMountExecutorEnabled();
  const bool privileged_mount_service_enabled =
      IsPrivilegedMountServiceEnabled();
  const bool can_attempt_privileged_mount =
      process_elevated || privileged_executor_enabled ||
      privileged_mount_service_enabled;

  for (const uint64_t network_id : known_network_ids) {
    int status_code = 0;
    int transport_ready = 0;
    zts_sockaddr_storage assigned_addrs[ZTS_MAX_ASSIGNED_ADDRESSES] = {};
    unsigned int assigned_addr_count = ZTS_MAX_ASSIGNED_ADDRESSES;
    std::vector<std::string> assigned_addresses;
    int addr_result = ZTS_ERR_SERVICE;
    int network_type = 0;
    int route_count = 0;
    int name_result = ZTS_ERR_SERVICE;
    char network_name_buffer[ZTS_MAX_NETWORK_SHORT_NAME_LENGTH + 1] = {0};
    {
      std::scoped_lock api_lock(api_mutex_);
      status_code = zts_net_get_status(network_id);
      transport_ready = zts_net_transport_is_ready(network_id);
      addr_result =
          zts_addr_get_all(network_id, assigned_addrs, &assigned_addr_count);
      network_type = zts_net_get_type(network_id);
      route_count = zts_core_query_route_count(network_id);
      name_result = zts_net_get_name(network_id, network_name_buffer,
                                     ZTS_MAX_NETWORK_SHORT_NAME_LENGTH);
    }
    if (addr_result == ZTS_ERR_OK) {
      for (unsigned int i = 0; i < assigned_addr_count; ++i) {
        const std::string address = ExtractAddress(assigned_addrs[i]);
        if (!address.empty()) {
          assigned_addresses.push_back(address);
          const auto prefix = ExtractIpv4PrefixLength(assigned_addrs[i]);
          if (prefix.has_value()) {
            managed_ipv4_prefix_hints[network_id][address] =
                ClampIpv4PrefixLength(*prefix);
          }
        }
      }
    }

    const std::string normalized_status = NetworkStatusToString(status_code);
    const bool stale_addresses = ShouldTreatAddressesAsStale(normalized_status);
    const bool has_transport = !stale_addresses && transport_ready > 0;
    const bool has_assigned_address =
        !stale_addresses && !assigned_addresses.empty();
    const auto previous_it = previous_networks.find(network_id);
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
        retained.last_probe_status_code = status_code;
        retained.last_probe_at_utc = Iso8601NowUtc();
        retained.last_probe_transport_ready = transport_ready;
        retained.last_probe_addr_result = addr_result;
        retained.last_probe_addr_result_name = ErrorCodeToString(addr_result);
        retained.last_probe_assigned_addr_count =
            static_cast<int>(assigned_addr_count);
        retained.last_probe_network_type = network_type;
        retained.last_probe_pending_join = pending_join_network_ids.find(network_id) !=
                                           pending_join_network_ids.end();
        retained.expected_route_count = std::max(0, route_count);
        retained.route_expected = retained.expected_route_count > 0;
        refreshed_networks[network_id] = std::move(retained);
        continue;
      }
      missing_network_ids.insert(network_id);
      continue;
    }
    if (ShouldRetainNetworkDuringStatusRegression(previous_it, previous_networks,
                                                  normalized_status,
                                                  has_transport,
                                                  has_assigned_address)) {
      ZeroTierWindowsNetworkRecord retained = previous_it->second;
      retained.last_probe_status_code = status_code;
      retained.last_probe_at_utc = Iso8601NowUtc();
      retained.last_probe_transport_ready = transport_ready;
      retained.last_probe_addr_result = addr_result;
      retained.last_probe_addr_result_name = ErrorCodeToString(addr_result);
      retained.last_probe_assigned_addr_count =
          static_cast<int>(assigned_addr_count);
      retained.last_probe_network_type = network_type;
      retained.last_probe_pending_join = pending_join_network_ids.find(network_id) !=
                                         pending_join_network_ids.end();
      retained.expected_route_count = std::max(0, route_count);
      retained.route_expected = retained.expected_route_count > 0;
      refreshed_networks[network_id] = std::move(retained);
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
      continue;
    }
    record.last_probe_status_code = status_code;
    record.last_probe_at_utc = Iso8601NowUtc();
    record.last_probe_transport_ready = transport_ready;
    record.last_probe_addr_result = addr_result;
    record.last_probe_addr_result_name = ErrorCodeToString(addr_result);
    record.last_probe_assigned_addr_count = static_cast<int>(assigned_addr_count);
    record.last_probe_network_type = network_type;
    record.last_probe_pending_join = pending_join;
    record.expected_route_count = std::max(0, route_count);
    record.route_expected = record.expected_route_count > 0;
    if (previous_it != previous_networks.end()) {
      record.last_event_code = previous_it->second.last_event_code;
      record.last_event_name = previous_it->second.last_event_name;
      record.last_event_at_utc = previous_it->second.last_event_at_utc;
      record.last_event_status_code = previous_it->second.last_event_status_code;
      record.last_event_network_type = previous_it->second.last_event_network_type;
      record.last_event_netconf_rev = previous_it->second.last_event_netconf_rev;
      record.last_event_assigned_addr_count =
          previous_it->second.last_event_assigned_addr_count;
      record.last_event_transport_ready =
          previous_it->second.last_event_transport_ready;
      record.join_trace_started_at_utc =
          previous_it->second.join_trace_started_at_utc;
      record.join_event_sequence = previous_it->second.join_event_sequence;
      record.join_saw_req_config = previous_it->second.join_saw_req_config;
      record.join_saw_ready_ip4 = previous_it->second.join_saw_ready_ip4;
      record.join_saw_ready_ip6 = previous_it->second.join_saw_ready_ip6;
      record.join_saw_ready_ip4_ip6 =
          previous_it->second.join_saw_ready_ip4_ip6;
      record.join_saw_network_ok = previous_it->second.join_saw_network_ok;
      record.join_saw_network_down = previous_it->second.join_saw_network_down;
      record.join_saw_addr_added_ip4 =
          previous_it->second.join_saw_addr_added_ip4;
      record.join_saw_addr_added_ip6 =
          previous_it->second.join_saw_addr_added_ip6;
      record.join_trace_active = previous_it->second.join_trace_active;
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
  if (tap_backend_ != nullptr) {
    std::vector<uint64_t> active_network_ids;
    active_network_ids.reserve(refreshed_networks.size());
    for (const auto& entry : refreshed_networks) {
      active_network_ids.push_back(entry.first);
    }
    std::string backend_action;
    const bool backend_changed = tap_backend_->EnsureAdapterPresent(
        adapter_probe, active_network_ids, expected_addresses, &backend_action);
    if (backend_changed) {
      std::ostringstream stream;
      stream << "tap_backend_ensure_adapter"
             << " phase=refresh"
             << " backend=" << tap_backend_id_
             << " changed=" << BoolLabel(backend_changed)
             << " expected_addresses=" << JoinAddresses(expected_addresses)
             << " has_virtual_adapter="
             << BoolLabel(adapter_probe.has_virtual_adapter)
             << " has_mount_candidate="
             << BoolLabel(adapter_probe.has_mount_candidate)
             << " has_expected_network_ip="
             << BoolLabel(adapter_probe.has_expected_network_ip)
             << " action=" << (backend_action.empty() ? "-" : backend_action);
      LogNodeTrace(stream.str());
    }
    if (backend_changed) {
      constexpr int kProbeRetryCount = 6;
      for (int attempt = 0; attempt < kProbeRetryCount; ++attempt) {
        adapter_probe = adapter_bridge_.Refresh(expected_addresses);
        if (adapter_probe.has_virtual_adapter || adapter_probe.has_mount_candidate ||
            adapter_probe.has_expected_network_ip) {
          break;
        }
        Sleep(250);
      }
    }
  }

  for (auto& [network_id, record] : refreshed_networks) {
    record.local_interface_ready = false;
    record.matched_interface_name.clear();
    record.matched_interface_if_index = 0;
    record.matched_interface_up = false;
    record.mount_driver_kind = "unknown";
    record.mount_candidate_names = adapter_probe.mount_candidate_names;
    record.system_ip_bound = false;
    record.system_route_bound = !record.route_expected;
    record.tap_media_status = "unknown";
    record.tap_device_instance_id.clear();
    record.tap_netcfg_instance_id.clear();
    const ZeroTierWindowsAdapterBridge::AdapterRecord* selected_adapter =
        nullptr;
    bool selected_exact_match = false;
    bool selected_adapter_has_expected_ip = false;
    bool confirmed_route_bound = !record.route_expected;

    const auto has_confirmed_route = [&](uint32_t if_index) {
      if (!record.route_expected || if_index == 0) {
        return !record.route_expected;
      }
      const auto confirmed_it = confirmed_routes_snapshot.find(network_id);
      if (confirmed_it == confirmed_routes_snapshot.end()) {
        return false;
      }
      for (const auto& address : record.assigned_addresses) {
        in_addr parsed = {};
        if (!ParseIpv4(address, &parsed)) {
          continue;
        }
        uint8_t prefix = 24;
        const auto hints_it = managed_ipv4_prefix_hints.find(network_id);
        if (hints_it != managed_ipv4_prefix_hints.end()) {
          const auto managed_prefix_it = hints_it->second.find(address);
          if (managed_prefix_it != hints_it->second.end()) {
            prefix = ClampIpv4PrefixLength(managed_prefix_it->second);
          }
        }
        const uint32_t destination =
            parsed.S_un.S_addr & PrefixMaskNetworkOrder(prefix);
        const bool matched = std::any_of(
            confirmed_it->second.begin(), confirmed_it->second.end(),
            [&](const MountedSystemRoute& route) {
              return route.if_index == if_index &&
                     route.destination_ipv4 == destination &&
                     route.prefix_length == prefix;
            });
        if (matched) {
          return true;
        }
      }
      return false;
    };

    if (!record.assigned_addresses.empty()) {
      const std::string expected_adapter_name =
          ExpectedWintunAdapterNameForNetwork(network_id);
      const ZeroTierWindowsAdapterBridge::AdapterRecord* exact_match = nullptr;
      int exact_match_score = std::numeric_limits<int>::min();
      bool exact_match_has_expected_ip = false;
      const ZeroTierWindowsAdapterBridge::AdapterRecord* fallback_candidate =
          nullptr;
      int fallback_score = std::numeric_limits<int>::min();
      bool fallback_has_expected_ip = false;
      for (const auto& adapter : adapter_probe.adapters) {
        const bool backend_candidate =
            tap_backend_ == nullptr
                ? adapter.is_mount_candidate
                : tap_backend_->IsUsableMountCandidate(adapter);
        const std::string backend_decision =
            tap_backend_ == nullptr
                ? (adapter.is_mount_candidate ? "accept:no_backend_mount_candidate"
                                              : "reject:not_mount_candidate")
                : tap_backend_->DescribeMountCandidateDecision(adapter);
        const int backend_score =
            tap_backend_ == nullptr ? 0 : tap_backend_->FallbackScore(adapter);
        const std::string adapter_display_name =
            !adapter.friendly_name.empty()
                ? adapter.friendly_name
                : (!adapter.description.empty() ? adapter.description
                                                : adapter.adapter_name);
        const bool matches_expected_adapter_name =
            _stricmp(adapter_display_name.c_str(),
                     expected_adapter_name.c_str()) == 0;
        const bool matched = std::any_of(
            record.assigned_addresses.begin(), record.assigned_addresses.end(),
            [&adapter](const std::string& address) {
              return std::find(adapter.ipv4_addresses.begin(),
                               adapter.ipv4_addresses.end(),
                               address) != adapter.ipv4_addresses.end();
            });
        {
          std::ostringstream stream;
          stream << "adapter_probe_candidate"
                 << " network_id=" << ToHexNetworkId(network_id)
                 << " if_index=" << adapter.if_index
                 << " adapter_name="
                 << (!adapter.friendly_name.empty()
                         ? adapter.friendly_name
                         : (!adapter.description.empty() ? adapter.description
                                                         : adapter.adapter_name))
                 << " is_mount_candidate=" << BoolLabel(adapter.is_mount_candidate)
                 << " backend_candidate=" << BoolLabel(backend_candidate)
                 << " backend=" << tap_backend_id_
                 << " backend_decision=" << backend_decision
                 << " backend_score=" << backend_score
                 << " matches_expected_adapter_name="
                 << BoolLabel(matches_expected_adapter_name)
                 << " matched_expected_ip=" << BoolLabel(matched)
                 << " is_up=" << BoolLabel(adapter.is_up)
                 << " media_status=" << adapter.media_status
                 << " driver_kind=" << adapter.driver_kind
                 << " has_expected_route="
                 << BoolLabel(adapter.has_expected_route);
          LogNodeTrace(stream.str());
        }
        if (!backend_candidate) {
          continue;
        }
        const int effective_score =
            backend_score + (matches_expected_adapter_name ? 1000 : 0);
        if (matched || matches_expected_adapter_name) {
          if (exact_match == nullptr ||
              effective_score > exact_match_score ||
              (effective_score == exact_match_score &&
               !exact_match->is_up && adapter.is_up)) {
            exact_match = &adapter;
            exact_match_score = effective_score;
            exact_match_has_expected_ip = matched;
          }
          continue;
        }
        if (fallback_candidate == nullptr ||
            effective_score > fallback_score ||
            (effective_score == fallback_score &&
             !fallback_candidate->is_up && adapter.is_up)) {
          fallback_candidate = &adapter;
          fallback_score = effective_score;
          fallback_has_expected_ip = matched;
        }
      }

      selected_adapter = exact_match != nullptr ? exact_match : fallback_candidate;
      selected_exact_match = exact_match != nullptr;
      selected_adapter_has_expected_ip =
          exact_match != nullptr ? exact_match_has_expected_ip
                                 : fallback_has_expected_ip;
      {
        std::ostringstream stream;
        stream << "adapter_probe_selected"
               << " network_id=" << ToHexNetworkId(network_id)
               << " selection=" << (selected_exact_match ? "exact" : "fallback");
        if (selected_adapter != nullptr) {
          stream << " if_index=" << selected_adapter->if_index
                 << " adapter_name="
                 << (!selected_adapter->friendly_name.empty()
                         ? selected_adapter->friendly_name
                         : (!selected_adapter->description.empty()
                                ? selected_adapter->description
                                : selected_adapter->adapter_name))
                 << " is_up=" << BoolLabel(selected_adapter->is_up)
                 << " media_status=" << selected_adapter->media_status
                 << " driver_kind=" << selected_adapter->driver_kind
                 << " selected_exact_match=" << BoolLabel(selected_exact_match);
        } else {
          stream << " if_index=0 adapter_name=-";
        }
        stream << " assigned_addresses=" << JoinAddresses(record.assigned_addresses);
        LogNodeTrace(stream.str());
      }
      if (selected_adapter != nullptr) {
        record.matched_interface_name =
            !selected_adapter->friendly_name.empty()
                ? selected_adapter->friendly_name
                : (!selected_adapter->description.empty()
                       ? selected_adapter->description
                       : selected_adapter->adapter_name);
        record.matched_interface_up = selected_adapter->is_up;
        record.matched_interface_if_index = selected_adapter->if_index;
        record.mount_driver_kind = selected_adapter->driver_kind;
        record.tap_media_status = selected_adapter->media_status;
        record.tap_device_instance_id = selected_adapter->device_instance_id;
        record.tap_netcfg_instance_id = selected_adapter->netcfg_instance_id;
        confirmed_route_bound = has_confirmed_route(selected_adapter->if_index);
        record.system_ip_bound = selected_adapter_has_expected_ip;
        record.system_route_bound =
            confirmed_route_bound ||
            (selected_adapter_has_expected_ip &&
             selected_adapter->has_expected_route);
        record.local_interface_ready =
            selected_adapter_has_expected_ip;
      }
    }

    bool selected_adapter_admin_ready = false;
    if (selected_adapter != nullptr && selected_adapter->if_index != 0 &&
        !record.matched_interface_up) {
      selected_adapter_admin_ready =
          EnsureInterfaceAdminUp(selected_adapter->if_index);
      std::ostringstream stream;
      stream << "adapter_probe_admin_up"
             << " network_id=" << ToHexNetworkId(network_id)
             << " if_index=" << selected_adapter->if_index
             << " result="
             << (selected_adapter_admin_ready ? "success" : "failed")
             << " oper_status_preserved="
             << (record.matched_interface_up ? "up" : "down")
             << " media_status=" << record.tap_media_status;
      LogNodeTrace(stream.str());
    }

    const bool adapter_available_for_mount =
        record.matched_interface_up || selected_adapter_admin_ready;

    if (!record.system_ip_bound && selected_adapter != nullptr &&
        selected_adapter->if_index != 0 && adapter_available_for_mount) {
      if (!can_attempt_privileged_mount) {
        const std::string message =
            "permission_denied_for_ip_mount: Windows IP mounting requires administrator privileges.";
        {
          std::scoped_lock lock(mutex_);
          SetLastErrorLocked(message);
        }
      } else {
        const auto hints_it = managed_ipv4_prefix_hints.find(network_id);
        const std::map<std::string, uint8_t> empty_prefix_hints;
        const std::map<std::string, uint8_t>& prefix_hints =
            hints_it == managed_ipv4_prefix_hints.end() ? empty_prefix_hints
                                                        : hints_it->second;
        CleanupManagedIpv4OnForeignAdaptersForNetwork(
            network_id, record, *selected_adapter, adapter_probe.adapters,
            prefix_hints);
        CleanupStaleSystemIpStateForNetwork(network_id, record,
                                            *selected_adapter, prefix_hints);
        std::vector<MountedSystemIp> created_ips;
        const bool ip_bound = TryBindSystemIpForNetwork(
            network_id, record, *selected_adapter, prefix_hints, &created_ips);
        if (!created_ips.empty()) {
          created_ips_by_network[network_id] = std::move(created_ips);
        }
        if (ip_bound) {
          record.system_ip_bound = true;
          if (record.matched_interface_up &&
              (selected_exact_match ||
               !record.matched_interface_name.empty())) {
            record.local_interface_ready = true;
          }
        } else {
          std::ostringstream stream;
          stream << "ip_bind_result"
                 << " network_id=" << ToHexNetworkId(network_id)
                 << " if_index=" << selected_adapter->if_index
                 << " adapter_name=" << record.matched_interface_name
                 << " ip_bound=false"
                 << " local_interface_ready="
                 << BoolLabel(record.local_interface_ready)
                 << " assigned_addresses="
                 << JoinAddresses(record.assigned_addresses);
          LogNodeTrace(stream.str());
        }
      }
    }
    if (record.route_expected && !record.system_route_bound &&
        record.system_ip_bound && selected_adapter != nullptr &&
        selected_adapter->if_index != 0 && adapter_available_for_mount) {
      if (!can_attempt_privileged_mount) {
        const std::string message =
            "permission_denied_for_route_mount: Windows route mounting requires administrator privileges.";
        {
          std::scoped_lock lock(mutex_);
          SetLastErrorLocked(message);
        }
      } else {
        const auto hints_it = managed_ipv4_prefix_hints.find(network_id);
        const std::map<std::string, uint8_t> empty_prefix_hints;
        std::vector<MountedSystemRoute> created_routes;
        std::vector<MountedSystemRoute> confirmed_routes;
        const bool mount_ok = TryMountSystemRoutesForNetwork(
            network_id, record, *selected_adapter,
            hints_it == managed_ipv4_prefix_hints.end() ? empty_prefix_hints
                                                        : hints_it->second,
            &created_routes, &confirmed_routes);
        if (!created_routes.empty()) {
          created_routes_by_network[network_id] = std::move(created_routes);
        }
        if (!confirmed_routes.empty()) {
          confirmed_routes_snapshot[network_id] = confirmed_routes;
          confirmed_routes_by_network[network_id] = std::move(confirmed_routes);
        }
        if (mount_ok) {
          record.system_route_bound = true;
        }
      }
    }

    record.local_mount_state =
        ResolveLocalMountState(record, adapter_probe.has_virtual_adapter);
  }

  for (const uint64_t network_id : missing_network_ids) {
    RemoveMountedSystemIpsForNetwork(network_id, "snapshotMissing");
    RemoveMountedSystemRoutesForNetwork(network_id, "snapshotMissing");
  }

  std::scoped_lock lock(mutex_);
  node_id_ = IsUsableNodeId(node_id) ? node_id : 0;
  node_port_ = node_port;
  if (node_started_ && node_id_ != 0) {
    node_online_ = node_online;
    if (node_online) {
      node_offline_ = false;
    }
  }
  for (const uint64_t network_id : missing_network_ids) {
    ForgetKnownNetworkLocked(network_id);
    networks_.erase(network_id);
    leave_request_sources_.erase(network_id);
    pending_leave_generations_.erase(network_id);
  }
  for (const auto& [network_id, created_ips] : created_ips_by_network) {
    RecordMountedSystemIpsLocked(network_id, created_ips);
  }
  for (const auto& [network_id, created_routes] : created_routes_by_network) {
    RecordMountedSystemRoutesLocked(network_id, created_routes);
  }
  for (const auto& [network_id, confirmed_routes] : confirmed_routes_by_network) {
    RecordConfirmedSystemRoutesLocked(network_id, confirmed_routes);
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

void ZeroTierWindowsRuntime::SetLastNodeControlHintLocked(
    const std::string& hint) {
  last_node_control_hint_ = hint;
  last_node_control_at_utc_ = Iso8601NowUtc();
}

std::string ZeroTierWindowsRuntime::DescribeNodeTriggerLocked(
    const std::string& event_name) const {
  if (event_name == "nodeDown" && stop_requested_) {
    return "explicit_stop_requested";
  }
  if (stop_requested_) {
    return "stop_requested";
  }
  if (!pending_join_networks_.empty()) {
    return "during_join_or_recovery";
  }
  if (!leave_request_sources_.empty()) {
    return "during_leave";
  }
  if (!node_started_) {
    return "node_not_started";
  }
  return "libzt_transport_or_host_runtime";
}

std::string ZeroTierWindowsRuntime::SummarizeTrackedNetworksLocked() const {
  if (networks_.empty()) {
    return "-";
  }
  std::ostringstream stream;
  bool first = true;
  for (const auto& [network_id, network] : networks_) {
    if (!first) {
      stream << ";";
    }
    first = false;
    stream << ToHexNetworkId(network_id)
           << ":" << network.status
           << ":connected=" << BoolLabel(network.is_connected)
           << ":mount=" << network.local_mount_state
           << ":addrs=" << network.assigned_addresses.size();
  }
  return stream.str();
}

std::string ZeroTierWindowsRuntime::BuildTransportDiagnosticsSummaryLocked() const {
  zts_stats_counter_t stats = {};
  int stats_result = ZTS_ERR_SERVICE;
  uint64_t live_node_id = 0;
  int live_node_port = 0;
  {
    std::scoped_lock api_lock(api_mutex_);
    stats_result = zts_stats_get_all(&stats);
    live_node_id = zts_node_get_id();
    live_node_port = zts_node_get_port();
  }

  std::ostringstream stream;
  stream << "node_id=" << ToHexNetworkId(node_id_)
         << " node_port=" << node_port_
         << " live_node_id=" << ToHexNetworkId(live_node_id)
         << " live_node_port=" << live_node_port
         << " stats_result=" << ErrorCodeToString(stats_result);
  if (stats_result == ZTS_ERR_OK) {
    stream << " udp_tx=" << stats.udp_tx
           << " udp_rx=" << stats.udp_rx
           << " udp_drop=" << stats.udp_drop
           << " udp_err=" << stats.udp_err
           << " link_tx=" << stats.link_tx
           << " link_rx=" << stats.link_rx
           << " link_drop=" << stats.link_drop
           << " link_err=" << stats.link_err;
  }
  if (!networks_.empty()) {
    stream << " nets=";
    bool first = true;
    for (const auto& [network_id, network] : networks_) {
      if (!first) {
        stream << "|";
      }
      first = false;
      int live_status = 0;
      int live_transport = 0;
      int live_route_count = 0;
      int live_name_result = ZTS_ERR_SERVICE;
      char live_name[ZTS_MAX_NETWORK_SHORT_NAME_LENGTH + 1] = {0};
      {
        std::scoped_lock api_lock(api_mutex_);
        live_status = zts_net_get_status(network_id);
        live_transport = zts_net_transport_is_ready(network_id);
        live_route_count = zts_core_query_route_count(network_id);
        live_name_result =
            zts_net_get_name(network_id, live_name,
                             ZTS_MAX_NETWORK_SHORT_NAME_LENGTH);
      }
      stream << ToHexNetworkId(network_id)
             << ":transport_evt=" << network.last_event_transport_ready
             << ",transport_probe=" << network.last_probe_transport_ready
             << ",transport_live=" << live_transport
             << ",status=" << network.status
             << ",status_live=" << NetworkStatusToString(live_status)
             << ",route_count_live=" << live_route_count
             << ",name_result_live=" << ErrorCodeToString(live_name_result)
             << ",name_live="
             << (live_name_result == ZTS_ERR_OK ? std::string(live_name)
                                                : std::string())
             << ",mount=" << network.local_mount_state;
    }
  }
  return stream.str();
}

std::string ZeroTierWindowsRuntime::BuildRecentPeerDiagnosticsLocked() const {
  if (observed_peer_ids_.empty()) {
    return "-";
  }

  std::ostringstream stream;
  bool first_peer = true;
  for (const uint64_t peer_id : observed_peer_ids_) {
    int path_count = 0;
    {
      std::scoped_lock api_lock(api_mutex_);
      path_count = zts_core_query_path_count(peer_id);
    }
    if (!first_peer) {
      stream << ";";
    }
    first_peer = false;
    stream << FormatNetworkIdHex(peer_id)
           << ":path_count=" << path_count;
    if (path_count < 0) {
      stream << "(" << ErrorCodeToString(path_count) << ")";
    }
    if (path_count > 0) {
      stream << ",paths=";
      for (int index = 0; index < path_count; ++index) {
        char path_buffer[256] = {0};
        int path_result = ZTS_ERR_SERVICE;
        {
          std::scoped_lock api_lock(api_mutex_);
          path_result = zts_core_query_path(
              peer_id, static_cast<unsigned int>(index), path_buffer,
              static_cast<unsigned int>(sizeof(path_buffer)));
        }
        if (index > 0) {
          stream << "|";
        }
        if (path_result >= 0 && path_buffer[0] != '\0') {
          stream << path_buffer;
        } else {
          stream << "query_failed:" << ErrorCodeToString(path_result);
        }
      }
    }
  }
  return stream.str();
}

std::string ZeroTierWindowsRuntime::BuildLiveNetworkProbeSummary(
    uint64_t network_id) const {
  if (network_id == 0) {
    return "network_id=0";
  }

  int status_code = 0;
  int transport_ready = 0;
  zts_sockaddr_storage assigned_addrs[ZTS_MAX_ASSIGNED_ADDRESSES] = {};
  unsigned int assigned_addr_count = ZTS_MAX_ASSIGNED_ADDRESSES;
  int addr_result = ZTS_ERR_SERVICE;
  int route_count = 0;
  {
    std::scoped_lock api_lock(api_mutex_);
    status_code = zts_net_get_status(network_id);
    transport_ready = zts_net_transport_is_ready(network_id);
    addr_result =
        zts_addr_get_all(network_id, assigned_addrs, &assigned_addr_count);
    route_count = zts_core_query_route_count(network_id);
  }

  std::vector<std::string> assigned_addresses;
  if (addr_result == ZTS_ERR_OK) {
    for (unsigned int i = 0; i < assigned_addr_count; ++i) {
      const std::string address = ExtractAddress(assigned_addrs[i]);
      if (!address.empty()) {
        assigned_addresses.push_back(address);
      }
    }
  }

  std::ostringstream stream;
  stream << "network_id=" << ToHexNetworkId(network_id)
         << " status=" << NetworkStatusToString(status_code)
         << " status_code=" << status_code
         << " transport_ready=" << transport_ready
         << " addr_result=" << ErrorCodeToString(addr_result)
         << " assigned_addr_count=" << assigned_addr_count
         << " route_count=" << route_count
         << " addresses=" << JoinAddresses(assigned_addresses);
  return stream.str();
}

std::string ZeroTierWindowsRuntime::KnownNetworksPath() const {
  return RuntimeRootPath() + "\\known_networks.txt";
}
