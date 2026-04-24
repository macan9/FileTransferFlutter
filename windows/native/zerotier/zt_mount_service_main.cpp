#include <WinSock2.h>
#include <WS2tcpip.h>
#include <Windows.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <sddl.h>

#include "native/zerotier/zerotier_windows_privileged_mount_ipc.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "ws2_32.lib")

namespace {

using ztwin::privileged_mount::Command;
using ztwin::privileged_mount::Request;
using ztwin::privileged_mount::Response;
using ztwin::privileged_mount::Result;

SERVICE_STATUS_HANDLE g_status_handle = nullptr;
SERVICE_STATUS g_service_status = {};
HANDLE g_stop_event = nullptr;

using WintunAdapterHandle = void*;
using WintunCreateAdapterFn =
    WintunAdapterHandle(WINAPI*)(const wchar_t*, const wchar_t*, const GUID*);
using WintunOpenAdapterFn = WintunAdapterHandle(WINAPI*)(const wchar_t*);
using WintunCloseAdapterFn = void(WINAPI*)(WintunAdapterHandle);
using WintunGetAdapterLuidFn = void(WINAPI*)(WintunAdapterHandle, NET_LUID*);

struct WintunApi {
  HMODULE module = nullptr;
  std::wstring loaded_from;
  WintunCreateAdapterFn create_adapter = nullptr;
  WintunOpenAdapterFn open_adapter = nullptr;
  WintunCloseAdapterFn close_adapter = nullptr;
  WintunGetAdapterLuidFn get_adapter_luid = nullptr;

  ~WintunApi() {
    if (module != nullptr) {
      FreeLibrary(module);
      module = nullptr;
    }
  }
};

WintunAdapterHandle g_pinned_wintun_handle = nullptr;
bool g_pinned_wintun_created = false;

void SetServiceState(DWORD state, DWORD win32_exit_code, DWORD wait_hint) {
  if (g_status_handle == nullptr) {
    return;
  }
  g_service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
  g_service_status.dwCurrentState = state;
  g_service_status.dwWin32ExitCode = win32_exit_code;
  g_service_status.dwWaitHint = wait_hint;
  g_service_status.dwControlsAccepted =
      state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
  SetServiceStatus(g_status_handle, &g_service_status);
}

void SafeCopyMessage(const std::string& source, char* destination,
                     size_t destination_size) {
  if (destination == nullptr || destination_size == 0) {
    return;
  }
  memset(destination, 0, destination_size);
  const size_t copy_len = std::min(source.size(), destination_size - 1);
  memcpy(destination, source.data(), copy_len);
}

uint32_t PrefixMaskNetworkOrder(uint8_t prefix_length) {
  const uint8_t clamped = prefix_length > 32 ? 32 : prefix_length;
  if (clamped == 0) {
    return 0;
  }
  const uint32_t mask_host_order = (clamped == 32)
                                       ? 0xFFFFFFFFu
                                       : (0xFFFFFFFFu << (32 - clamped));
  return htonl(mask_host_order);
}

bool ParseIpv4(const std::string& ip_text, in_addr* out) {
  if (out == nullptr || ip_text.empty()) {
    return false;
  }
  in_addr parsed = {};
  if (InetPtonA(AF_INET, ip_text.c_str(), &parsed) != 1) {
    return false;
  }
  *out = parsed;
  return true;
}

bool ParseIpv4Cidr(const std::string& cidr, in_addr* network,
                   uint8_t* prefix_length) {
  if (network == nullptr || prefix_length == nullptr) {
    return false;
  }
  const size_t slash_pos = cidr.find('/');
  if (slash_pos == std::string::npos) {
    return false;
  }
  const std::string ip_text = cidr.substr(0, slash_pos);
  const std::string prefix_text = cidr.substr(slash_pos + 1);
  if (prefix_text.empty()) {
    return false;
  }
  int parsed_prefix = std::atoi(prefix_text.c_str());
  if (parsed_prefix < 0 || parsed_prefix > 32) {
    return false;
  }
  in_addr parsed_ip = {};
  if (!ParseIpv4(ip_text, &parsed_ip)) {
    return false;
  }
  *network = parsed_ip;
  *prefix_length = static_cast<uint8_t>(parsed_prefix);
  return true;
}

bool HasIpv4Address(uint32_t if_index, uint32_t address_network_order) {
  ULONG size = 0;
  if (GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_PREFIX, nullptr, nullptr,
                           &size) != ERROR_BUFFER_OVERFLOW) {
    return false;
  }
  std::vector<unsigned char> buffer(size);
  IP_ADAPTER_ADDRESSES* addrs =
      reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  if (GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_PREFIX, nullptr, addrs,
                           &size) != NO_ERROR) {
    return false;
  }
  for (const IP_ADAPTER_ADDRESSES* adapter = addrs; adapter != nullptr;
       adapter = adapter->Next) {
    if (adapter->IfIndex != if_index) {
      continue;
    }
    for (IP_ADAPTER_UNICAST_ADDRESS* unicast = adapter->FirstUnicastAddress;
         unicast != nullptr; unicast = unicast->Next) {
      if (unicast->Address.lpSockaddr == nullptr ||
          unicast->Address.lpSockaddr->sa_family != AF_INET) {
        continue;
      }
      const SOCKADDR_IN* ipv4 =
          reinterpret_cast<const SOCKADDR_IN*>(unicast->Address.lpSockaddr);
      if (ipv4->sin_addr.S_un.S_addr == address_network_order) {
        return true;
      }
    }
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

std::string WideToUtf8(const wchar_t* text) {
  if (text == nullptr || text[0] == L'\0') {
    return "";
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 1) {
    return "";
  }
  std::string output(static_cast<size_t>(size - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, output.data(), size, nullptr,
                      nullptr);
  return output;
}

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) {
    return L"";
  }
  const int required =
      MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (required <= 1) {
    return L"";
  }
  std::wstring output(static_cast<size_t>(required), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, output.data(), required);
  output.pop_back();
  return output;
}

std::wstring CurrentModuleDirectory() {
  std::vector<wchar_t> buffer(MAX_PATH);
  for (;;) {
    DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                      static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return L"";
    }
    if (length < buffer.size() - 1) {
      std::filesystem::path path(buffer.data());
      return path.parent_path().wstring();
    }
    buffer.resize(buffer.size() * 2);
    if (buffer.size() > 32768) {
      return L"";
    }
  }
}

void AddLoadCandidate(std::vector<std::wstring>* candidates,
                      const std::filesystem::path& path) {
  if (candidates == nullptr || path.empty()) {
    return;
  }
  std::error_code canonical_error;
  const std::filesystem::path normalized =
      std::filesystem::weakly_canonical(path, canonical_error);
  const std::wstring value =
      canonical_error ? path.wstring() : normalized.wstring();
  if (value.empty()) {
    return;
  }
  if (std::find(candidates->begin(), candidates->end(), value) ==
      candidates->end()) {
    candidates->push_back(value);
  }
}

std::vector<std::wstring> BuildWintunDllLoadCandidates() {
  std::vector<std::wstring> candidates;

  char* env_value = nullptr;
  size_t env_size = 0;
  if (_dupenv_s(&env_value, &env_size, "ZT_WINTUN_DLL") == 0 &&
      env_value != nullptr && env_value[0] != '\0') {
    const std::wstring env_wide = Utf8ToWide(env_value);
    free(env_value);
    if (!env_wide.empty()) {
      std::filesystem::path env_path(env_wide);
      std::error_code status_error;
      if (std::filesystem::is_directory(env_path, status_error) &&
          !status_error) {
        AddLoadCandidate(&candidates, env_path / L"wintun.dll");
      } else {
        AddLoadCandidate(&candidates, env_path);
      }
    }
  }

  const std::filesystem::path module_dir(CurrentModuleDirectory());
  if (!module_dir.empty()) {
    AddLoadCandidate(&candidates, module_dir / L"wintun.dll");
    AddLoadCandidate(&candidates, module_dir / L"lib" / L"wintun.dll");
    AddLoadCandidate(&candidates, module_dir / L"bin" / L"wintun.dll");
#if defined(_M_ARM64)
    constexpr const wchar_t* kWintunArchDir = L"arm64";
#elif defined(_M_ARM)
    constexpr const wchar_t* kWintunArchDir = L"arm";
#elif defined(_M_IX86)
    constexpr const wchar_t* kWintunArchDir = L"x86";
#else
    constexpr const wchar_t* kWintunArchDir = L"amd64";
#endif
    std::filesystem::path probe = module_dir;
    for (int i = 0; i < 8 && !probe.empty(); ++i) {
      AddLoadCandidate(&candidates,
                       probe / L"third_party" / L"wintun" / L"0.14.1" /
                           L"extract" / L"wintun" / L"bin" / kWintunArchDir /
                           L"wintun.dll");
      probe = probe.parent_path();
    }
  }

  candidates.push_back(L"wintun.dll");
  return candidates;
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

std::string EscapePowerShellSingleQuotedLiteral(const std::string& input) {
  std::string escaped;
  escaped.reserve(input.size());
  for (const char ch : input) {
    escaped.push_back(ch);
    if (ch == '\'') {
      escaped.push_back('\'');
    }
  }
  return escaped;
}

const char* ResultToShortText(Result result) {
  switch (result) {
    case Result::kFailed:
      return "failed";
    case Result::kSuccess:
      return "success";
    case Result::kAlreadyExists:
      return "exists";
    case Result::kNotFound:
      return "not_found";
    case Result::kUnavailable:
      return "unavailable";
    case Result::kInvalidRequest:
      return "invalid";
    case Result::kPermissionDenied:
      return "denied";
  }
  return "unknown";
}

std::string TruncateForMessage(const std::string& text, size_t max_length) {
  if (text.size() <= max_length) {
    return text;
  }
  if (max_length <= 3) {
    return text.substr(0, max_length);
  }
  return text.substr(0, max_length - 3) + "...";
}

struct AdapterVisibilityProbe {
  bool found = false;
  uint32_t if_index = 0;
  uint64_t luid = 0;
  std::string alias;
  std::string adapter_name;
  std::string description;
  std::string interface_guid;
  std::string oper_status;
};

struct WintunAdapterResolution {
  uint32_t if_index = 0;
  NET_LUID luid = {};
  std::string adapter_name;
  std::string description;
  std::string interface_guid;
  std::string oper_status;
};

std::string OperStatusToString(IF_OPER_STATUS status) {
  switch (status) {
    case IfOperStatusUp:
      return "Up";
    case IfOperStatusDown:
      return "Down";
    case IfOperStatusTesting:
      return "Testing";
    case IfOperStatusUnknown:
      return "Unknown";
    case IfOperStatusDormant:
      return "Dormant";
    case IfOperStatusNotPresent:
      return "NotPresent";
    case IfOperStatusLowerLayerDown:
      return "LowerLayerDown";
  }
  return std::to_string(static_cast<int>(status));
}

bool IsInterfaceEnumerableByIfIndex(NET_IFINDEX if_index) {
  if (if_index == 0) {
    return false;
  }
  MIB_IFROW row = {};
  row.dwIndex = if_index;
  return GetIfEntry(&row) == NO_ERROR;
}

bool LooksLikeNamedWintunAdapter(const std::string& desired_name,
                                 const std::string& friendly_name,
                                 const std::string& description,
                                 const std::string& alias) {
  if (_stricmp(friendly_name.c_str(), desired_name.c_str()) == 0 ||
      _stricmp(alias.c_str(), desired_name.c_str()) == 0 ||
      _stricmp(description.c_str(), desired_name.c_str()) == 0) {
    return true;
  }
  return _stricmp(description.c_str(), "wintun userspace tunnel") == 0 ||
         _stricmp(description.c_str(), "wireguard tunnel") == 0;
}

bool ResolveWintunAdapterByName(const std::string& desired_name,
                                WintunAdapterResolution* resolution) {
  if (resolution == nullptr) {
    return false;
  }
  *resolution = WintunAdapterResolution{};
  ULONG size = 0;
  if (GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_ALL_INTERFACES, nullptr,
                           nullptr, &size) != ERROR_BUFFER_OVERFLOW) {
    return false;
  }
  std::vector<unsigned char> buffer(size);
  IP_ADAPTER_ADDRESSES* addrs =
      reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  if (GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_ALL_INTERFACES, nullptr,
                           addrs, &size) != NO_ERROR) {
    return false;
  }
  for (const IP_ADAPTER_ADDRESSES* adapter = addrs; adapter != nullptr;
       adapter = adapter->Next) {
    const std::string friendly_name = WideToUtf8(adapter->FriendlyName);
    const std::string description = WideToUtf8(adapter->Description);
    const std::string alias = adapter->AdapterName == nullptr ? "" : adapter->AdapterName;
    if (!LooksLikeNamedWintunAdapter(desired_name, friendly_name, description,
                                     alias)) {
      continue;
    }
    resolution->if_index = adapter->IfIndex;
    resolution->luid = adapter->Luid;
    resolution->adapter_name = friendly_name;
    resolution->description = description;
    resolution->interface_guid = alias;
    resolution->oper_status = OperStatusToString(adapter->OperStatus);
    return true;
  }
  return false;
}

bool WaitForStableWintunAdapterByName(const std::string& desired_name,
                                      int attempts, DWORD delay_ms,
                                      WintunAdapterResolution* resolution,
                                      std::string* detail) {
  WintunAdapterResolution current;
  for (int attempt = 0; attempt < attempts; ++attempt) {
    if (ResolveWintunAdapterByName(desired_name, &current) &&
        current.if_index != 0) {
      const bool enumerable = IsInterfaceEnumerableByIfIndex(current.if_index);
      if (detail != nullptr) {
        std::ostringstream stream;
        stream << "attempt=" << (attempt + 1)
               << " found=true if_index=" << current.if_index
               << " luid=" << current.luid.Value
               << " oper=" << current.oper_status
               << " enumerable=" << (enumerable ? "true" : "false");
        *detail = stream.str();
      }
      if (enumerable) {
        if (resolution != nullptr) {
          *resolution = current;
        }
        return true;
      }
    } else if (detail != nullptr) {
      std::ostringstream stream;
      stream << "attempt=" << (attempt + 1) << " found=false";
      *detail = stream.str();
    }
    if (attempt + 1 < attempts) {
      Sleep(delay_ms);
    }
  }
  return false;
}

WintunApi* GetSharedWintunApi(std::string* load_message) {
  static WintunApi api;
  static bool attempted_load = false;
  if (!attempted_load) {
    attempted_load = true;
    for (const auto& candidate : BuildWintunDllLoadCandidates()) {
      HMODULE module = LoadLibraryW(candidate.c_str());
      if (module == nullptr) {
        continue;
      }
      api.module = module;
      api.loaded_from = candidate;
      api.create_adapter = reinterpret_cast<WintunCreateAdapterFn>(
          GetProcAddress(module, "WintunCreateAdapter"));
      api.open_adapter = reinterpret_cast<WintunOpenAdapterFn>(
          GetProcAddress(module, "WintunOpenAdapter"));
      api.close_adapter = reinterpret_cast<WintunCloseAdapterFn>(
          GetProcAddress(module, "WintunCloseAdapter"));
      api.get_adapter_luid = reinterpret_cast<WintunGetAdapterLuidFn>(
          GetProcAddress(module, "WintunGetAdapterLUID"));
      if (api.create_adapter != nullptr && api.open_adapter != nullptr &&
          api.close_adapter != nullptr && api.get_adapter_luid != nullptr) {
        break;
      }
      FreeLibrary(module);
      api = WintunApi{};
    }
  }
  if (api.module == nullptr) {
    if (load_message != nullptr) {
      *load_message = "wintun_dll_load_failed";
    }
    return nullptr;
  }
  if (load_message != nullptr) {
    *load_message = "wintun_dll_loaded from=" + WideToUtf8(api.loaded_from.c_str());
  }
  return &api;
}

void TryBringInterfaceUp(NET_IFINDEX if_index) {
  if (if_index == 0) {
    return;
  }
  MIB_IFROW row = {};
  row.dwIndex = if_index;
  if (GetIfEntry(&row) != NO_ERROR) {
    return;
  }
  if (row.dwAdminStatus != MIB_IF_ADMIN_STATUS_UP) {
    row.dwAdminStatus = MIB_IF_ADMIN_STATUS_UP;
    SetIfEntry(&row);
  }
}

AdapterVisibilityProbe ProbeAdapterViaGetAdaptersAddresses(uint32_t if_index) {
  AdapterVisibilityProbe probe;
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
    probe.alias = WideToUtf8(adapter->FriendlyName);
    probe.adapter_name = adapter->AdapterName == nullptr ? "" : adapter->AdapterName;
    probe.description = WideToUtf8(adapter->Description);
    probe.oper_status = OperStatusToString(adapter->OperStatus);
    GUID interface_guid = {};
    if (ConvertInterfaceLuidToGuid(&adapter->Luid, &interface_guid) == NO_ERROR) {
      probe.interface_guid = GuidToString(interface_guid);
    }
    return probe;
  }
  return probe;
}

std::string BuildAdapterVisibilityProbeScript(
    uint32_t if_index, const AdapterVisibilityProbe& probe) {
  std::ostringstream script;
  script << "  Write-Output 'TRACE=adapter_visibility_probe_start'\n"
         << "  Write-Output 'GAA_FOUND=" << (probe.found ? "true" : "false")
         << "'\n"
         << "  Write-Output 'GAA_IFINDEX=" << probe.if_index << "'\n"
         << "  Write-Output 'GAA_LUID=" << probe.luid << "'\n"
         << "  Write-Output 'GAA_ALIAS="
         << EscapePowerShellSingleQuotedLiteral(probe.alias) << "'\n"
         << "  Write-Output 'GAA_INTERFACE_GUID="
         << EscapePowerShellSingleQuotedLiteral(probe.interface_guid) << "'\n"
         << "  Write-Output 'GAA_ADAPTER_NAME="
         << EscapePowerShellSingleQuotedLiteral(probe.adapter_name) << "'\n"
         << "  Write-Output 'GAA_DESCRIPTION="
         << EscapePowerShellSingleQuotedLiteral(probe.description) << "'\n"
         << "  Write-Output 'GAA_OPER_STATUS="
         << EscapePowerShellSingleQuotedLiteral(probe.oper_status) << "'\n"
         << "  $ipIf = Get-NetIPInterface -InterfaceIndex " << if_index
         << " -AddressFamily IPv4 -ErrorAction SilentlyContinue\n"
         << "  if ($ipIf) { $ipIf | Select-Object InterfaceIndex,InterfaceAlias,InterfaceGuid,AddressFamily,ConnectionState,NlMtu,InterfaceMetric | Format-List | Out-String | Write-Output } else { Write-Output 'NETIPIF_FOUND=false' }\n"
         << "  $adapterByGuid = $null\n"
         << "  $adapterByAlias = $null\n";
  if (!probe.interface_guid.empty()) {
    script << "  $adapterByGuid = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq '"
           << EscapePowerShellSingleQuotedLiteral(probe.interface_guid)
           << "' } | Select-Object -First 1\n";
  }
  if (!probe.alias.empty()) {
    script << "  $adapterByAlias = Get-NetAdapter -Name '"
           << EscapePowerShellSingleQuotedLiteral(probe.alias)
           << "' -ErrorAction SilentlyContinue\n";
  }
  script
      << "  $bindAdapter = if ($adapterByGuid) { $adapterByGuid } elseif ($adapterByAlias) { $adapterByAlias } else { $null }\n"
      << "  if ($bindAdapter) { Write-Output ('BIND_ALIAS=' + $bindAdapter.Name); Write-Output ('BIND_GUID=' + $bindAdapter.InterfaceGuid); Write-Output ('BIND_IFINDEX=' + $bindAdapter.ifIndex) } else { Write-Output 'BIND_ADAPTER_FOUND=false' }\n";
  return script.str();
}

bool HasRoute(uint32_t if_index, uint32_t destination_network_order,
              uint8_t prefix_length) {
  ULONG size = 0;
  if (GetIpForwardTable(nullptr, &size, FALSE) != ERROR_INSUFFICIENT_BUFFER) {
    return false;
  }
  std::vector<unsigned char> buffer(size);
  MIB_IPFORWARDTABLE* table =
      reinterpret_cast<MIB_IPFORWARDTABLE*>(buffer.data());
  if (GetIpForwardTable(table, &size, FALSE) != NO_ERROR) {
    return false;
  }
  const uint32_t mask = PrefixMaskNetworkOrder(prefix_length);
  for (DWORD i = 0; i < table->dwNumEntries; ++i) {
    const MIB_IPFORWARDROW& row = table->table[i];
    if (row.dwForwardIfIndex == if_index &&
        row.dwForwardDest == destination_network_order &&
        row.dwForwardMask == mask &&
        row.dwForwardNextHop == htonl(INADDR_ANY)) {
      return true;
    }
  }
  return false;
}

bool RemoveRoute(uint32_t if_index, uint32_t destination_network_order,
                 uint8_t prefix_length) {
  ULONG size = 0;
  if (GetIpForwardTable(nullptr, &size, FALSE) != ERROR_INSUFFICIENT_BUFFER) {
    return false;
  }
  std::vector<unsigned char> buffer(size);
  MIB_IPFORWARDTABLE* table =
      reinterpret_cast<MIB_IPFORWARDTABLE*>(buffer.data());
  if (GetIpForwardTable(table, &size, FALSE) != NO_ERROR) {
    return false;
  }
  const uint32_t mask = PrefixMaskNetworkOrder(prefix_length);
  bool removed = false;
  for (DWORD i = 0; i < table->dwNumEntries; ++i) {
    MIB_IPFORWARDROW row = table->table[i];
    if (row.dwForwardIfIndex != if_index ||
        row.dwForwardDest != destination_network_order ||
        row.dwForwardMask != mask ||
        row.dwForwardNextHop != htonl(INADDR_ANY)) {
      continue;
    }
    if (DeleteIpForwardEntry(&row) == NO_ERROR) {
      removed = true;
    }
  }
  return removed;
}

std::string ServiceLogDirectory() {
  char program_data[MAX_PATH] = {0};
  const DWORD len = GetEnvironmentVariableA("PROGRAMDATA", program_data, MAX_PATH);
  std::filesystem::path root;
  if (len > 0 && len < MAX_PATH) {
    root = std::filesystem::path(program_data);
  } else {
    root = std::filesystem::temp_directory_path();
  }
  std::filesystem::path dir =
      root / "FileTransferFlutter" / "zerotier" / "service_logs";
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  return dir.string();
}

std::string BuildServiceLogPath(const char* command_tag, uint64_t request_id) {
  SYSTEMTIME st = {};
  GetLocalTime(&st);
  std::ostringstream file;
  file << "mountsvc_"
       << st.wYear
       << (st.wMonth < 10 ? "0" : "") << st.wMonth
       << (st.wDay < 10 ? "0" : "") << st.wDay << "_"
       << (st.wHour < 10 ? "0" : "") << st.wHour
       << (st.wMinute < 10 ? "0" : "") << st.wMinute
       << (st.wSecond < 10 ? "0" : "") << st.wSecond
       << "_" << std::hex << request_id << "_" << command_tag << ".log";
  std::filesystem::path path = std::filesystem::path(ServiceLogDirectory()) / file.str();
  return path.string();
}

std::string ComposeMessageWithLogPath(const std::string& base,
                                      const std::string& log_path) {
  if (log_path.empty()) {
    return base;
  }
  return base + " log=" + log_path;
}

bool EnsureDirectoryExists(const std::filesystem::path& path) {
  if (path.empty()) {
    return false;
  }
  std::error_code ec;
  std::filesystem::create_directories(path, ec);
  return !ec && std::filesystem::exists(path);
}

void AppendLogLine(HANDLE handle, const std::string& line) {
  if (handle == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD written = 0;
  WriteFile(handle, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
}

std::string BuildTempPowerShellScriptPath(const char* command_tag,
                                          uint64_t request_id) {
  char temp_dir[MAX_PATH] = {0};
  DWORD dir_len = GetTempPathA(MAX_PATH, temp_dir);
  if (dir_len == 0 || dir_len >= MAX_PATH) {
    return "";
  }
  SYSTEMTIME st = {};
  GetLocalTime(&st);
  std::ostringstream file;
  file << "zt_mountsvc_"
       << st.wYear
       << (st.wMonth < 10 ? "0" : "") << st.wMonth
       << (st.wDay < 10 ? "0" : "") << st.wDay << "_"
       << (st.wHour < 10 ? "0" : "") << st.wHour
       << (st.wMinute < 10 ? "0" : "") << st.wMinute
       << (st.wSecond < 10 ? "0" : "") << st.wSecond
       << "_" << std::hex << request_id << "_"
       << (command_tag == nullptr ? "powershell" : command_tag)
       << ".ps1";
  std::filesystem::path path = std::filesystem::path(temp_dir) / file.str();
  return path.string();
}

bool WriteTextFile(const std::string& path, const std::string& content) {
  HANDLE file = CreateFileA(path.c_str(), GENERIC_WRITE,
                            FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  DWORD total_written = 0;
  const BOOL ok = WriteFile(file, content.data(),
                            static_cast<DWORD>(content.size()), &total_written,
                            nullptr);
  CloseHandle(file);
  return ok == TRUE && total_written == content.size();
}

bool RunPowerShellScript(const std::string& script_content, DWORD* exit_code,
                         const std::string& command_tag, uint64_t request_id,
                         std::string* diagnostics_log_path) {
  if (exit_code != nullptr) {
    *exit_code = ERROR_GEN_FAILURE;
  }
  if (diagnostics_log_path != nullptr) {
    diagnostics_log_path->clear();
  }

  const std::string log_path = BuildServiceLogPath(
      command_tag.empty() ? "powershell" : command_tag.c_str(), request_id);
  if (diagnostics_log_path != nullptr) {
    *diagnostics_log_path = log_path;
  }

  const std::string script_path =
      BuildTempPowerShellScriptPath(command_tag.c_str(), request_id);
  if (script_path.empty()) {
    if (exit_code != nullptr) {
      *exit_code = ERROR_PATH_NOT_FOUND;
    }
    return false;
  }

  SECURITY_ATTRIBUTES attr = {};
  attr.nLength = sizeof(attr);
  attr.bInheritHandle = TRUE;
  attr.lpSecurityDescriptor = nullptr;
  HANDLE log_handle = CreateFileA(
      log_path.c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, &attr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (log_handle == INVALID_HANDLE_VALUE) {
    if (exit_code != nullptr) {
      *exit_code = GetLastError();
    }
    return false;
  }

  SetFilePointer(log_handle, 0, nullptr, FILE_END);
  AppendLogLine(log_handle, "---- script_path ----\r\n" + script_path + "\r\n");
  AppendLogLine(log_handle, "---- script_content ----\r\n" + script_content + "\r\n");

  if (!WriteTextFile(script_path, script_content)) {
    const DWORD script_write_error = GetLastError();
    AppendLogLine(log_handle, "WriteTextFile failed error=" +
                                  std::to_string(script_write_error) + "\r\n");
    CloseHandle(log_handle);
    if (exit_code != nullptr) {
      *exit_code = script_write_error;
    }
    return false;
  }

  const std::string command =
      "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" +
      script_path + "\"";
  AppendLogLine(log_handle, "---- command ----\r\n" + command + "\r\n");

  STARTUPINFOA startup = {};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  startup.hStdOutput = log_handle;
  startup.hStdError = log_handle;
  PROCESS_INFORMATION process = {};
  std::vector<char> cmd(command.begin(), command.end());
  cmd.push_back('\0');
  if (!CreateProcessA(nullptr, cmd.data(), nullptr, nullptr, TRUE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
    const DWORD create_error = GetLastError();
    AppendLogLine(log_handle, "CreateProcessA failed error=" +
                                  std::to_string(create_error) + "\r\n");
    CloseHandle(log_handle);
    std::error_code ec;
    std::filesystem::remove(script_path, ec);
    if (exit_code != nullptr) {
      *exit_code = create_error;
    }
    return false;
  }
  const DWORD wait_result = WaitForSingleObject(process.hProcess, 30000);
  if (wait_result == WAIT_TIMEOUT) {
    AppendLogLine(log_handle, "wait_result=WAIT_TIMEOUT terminating_process=1\r\n");
    TerminateProcess(process.hProcess, WAIT_TIMEOUT);
    WaitForSingleObject(process.hProcess, 5000);
  } else if (wait_result != WAIT_OBJECT_0) {
    AppendLogLine(log_handle, "wait_result=" + std::to_string(wait_result) +
                                  " wait_error=" + std::to_string(GetLastError()) +
                                  "\r\n");
  } else {
    AppendLogLine(log_handle, "wait_result=WAIT_OBJECT_0\r\n");
  }
  DWORD process_exit_code = ERROR_GEN_FAILURE;
  GetExitCodeProcess(process.hProcess, &process_exit_code);
  AppendLogLine(log_handle, "exit_code=" + std::to_string(process_exit_code) +
                                "\r\n---- end ----\r\n");
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  CloseHandle(log_handle);
  std::error_code ec;
  std::filesystem::remove(script_path, ec);
  if (exit_code != nullptr) {
    *exit_code = process_exit_code;
  }
  return process_exit_code == 0;
}

bool RunCommandLineWithLog(const std::wstring& command_line, DWORD* exit_code,
                           const std::string& command_tag, uint64_t request_id,
                           std::string* diagnostics_log_path) {
  if (exit_code != nullptr) {
    *exit_code = ERROR_GEN_FAILURE;
  }
  if (diagnostics_log_path != nullptr) {
    diagnostics_log_path->clear();
  }
  const std::string log_path = BuildServiceLogPath(
      command_tag.empty() ? "command" : command_tag.c_str(), request_id);
  if (diagnostics_log_path != nullptr) {
    *diagnostics_log_path = log_path;
  }

  SECURITY_ATTRIBUTES attr = {};
  attr.nLength = sizeof(attr);
  attr.bInheritHandle = TRUE;
  HANDLE log_handle = CreateFileA(
      log_path.c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, &attr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (log_handle == INVALID_HANDLE_VALUE) {
    if (exit_code != nullptr) {
      *exit_code = GetLastError();
    }
    return false;
  }
  SetFilePointer(log_handle, 0, nullptr, FILE_END);
  AppendLogLine(log_handle, "---- command ----\r\n" +
                                WideToUtf8(command_line.c_str()) + "\r\n");

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  startup.hStdOutput = log_handle;
  startup.hStdError = log_handle;
  PROCESS_INFORMATION process = {};
  std::wstring mutable_command = command_line;
  if (!CreateProcessW(nullptr, mutable_command.data(), nullptr, nullptr, TRUE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
    const DWORD create_error = GetLastError();
    AppendLogLine(log_handle, "CreateProcessW failed error=" +
                                  std::to_string(create_error) + "\r\n");
    CloseHandle(log_handle);
    if (exit_code != nullptr) {
      *exit_code = create_error;
    }
    return false;
  }
  const DWORD wait_result = WaitForSingleObject(process.hProcess, 30000);
  if (wait_result == WAIT_TIMEOUT) {
    AppendLogLine(log_handle, "wait_result=WAIT_TIMEOUT terminating_process=1\r\n");
    TerminateProcess(process.hProcess, WAIT_TIMEOUT);
    WaitForSingleObject(process.hProcess, 5000);
  } else if (wait_result != WAIT_OBJECT_0) {
    AppendLogLine(log_handle, "wait_result=" + std::to_string(wait_result) +
                                  " wait_error=" + std::to_string(GetLastError()) +
                                  "\r\n");
  } else {
    AppendLogLine(log_handle, "wait_result=WAIT_OBJECT_0\r\n");
  }
  DWORD process_exit_code = ERROR_GEN_FAILURE;
  GetExitCodeProcess(process.hProcess, &process_exit_code);
  AppendLogLine(log_handle, "exit_code=" + std::to_string(process_exit_code) +
                                "\r\n---- end ----\r\n");
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  CloseHandle(log_handle);
  if (exit_code != nullptr) {
    *exit_code = process_exit_code;
  }
  return process_exit_code == 0;
}

std::wstring QuoteForCommand(const std::wstring& value) {
  return L"\"" + value + L"\"";
}

int ParsePositiveInt(const std::wstring& text, int default_value) {
  if (text.empty()) {
    return default_value;
  }
  const int parsed = _wtoi(text.c_str());
  return parsed > 0 ? parsed : default_value;
}

int RunPktMonStartMode(const std::wstring& log_dir, int file_size_mb) {
  if (log_dir.empty()) {
    return 2;
  }
  const std::filesystem::path dir(log_dir);
  if (!EnsureDirectoryExists(dir)) {
    return 3;
  }
  const uint64_t request_id = GetTickCount64();
  const std::filesystem::path etl_path = dir / "pktmon_udp_capture.etl";
  DWORD exit_code = ERROR_GEN_FAILURE;
  std::string log_path;
  RunCommandLineWithLog(L"pktmon stop", &exit_code, "pktmon_stop_pre", request_id,
                        &log_path);
  if (!RunCommandLineWithLog(L"pktmon filter remove", &exit_code,
                             "pktmon_filter_remove", request_id, &log_path)) {
    return static_cast<int>(exit_code == ERROR_GEN_FAILURE ? 4 : exit_code);
  }
  if (!RunCommandLineWithLog(L"pktmon filter add libzt_udp -t UDP", &exit_code,
                             "pktmon_filter_add", request_id, &log_path)) {
    return static_cast<int>(exit_code == ERROR_GEN_FAILURE ? 5 : exit_code);
  }
  const std::wstring start_command =
      L"pktmon start --capture --pkt-size 0 --file-name " +
      QuoteForCommand(etl_path.wstring()) + L" --file-size " +
      std::to_wstring(file_size_mb);
  if (!RunCommandLineWithLog(start_command, &exit_code, "pktmon_start",
                             request_id, &log_path)) {
    return static_cast<int>(exit_code == ERROR_GEN_FAILURE ? 6 : exit_code);
  }
  return 0;
}

int RunPktMonStopMode(const std::wstring& log_dir) {
  if (log_dir.empty()) {
    return 2;
  }
  const std::filesystem::path dir(log_dir);
  if (!EnsureDirectoryExists(dir)) {
    return 3;
  }
  const uint64_t request_id = GetTickCount64();
  const std::filesystem::path etl_path = dir / "pktmon_udp_capture.etl";
  const std::filesystem::path txt_path = dir / "pktmon_udp_capture.txt";
  const std::filesystem::path pcap_path = dir / "pktmon_udp_capture.pcapng";
  DWORD exit_code = ERROR_GEN_FAILURE;
  std::string log_path;
  if (!RunCommandLineWithLog(L"pktmon stop", &exit_code, "pktmon_stop",
                             request_id, &log_path)) {
    return static_cast<int>(exit_code == ERROR_GEN_FAILURE ? 4 : exit_code);
  }
  RunCommandLineWithLog(L"pktmon counters --json", &exit_code, "pktmon_counters",
                        request_id, &log_path);
  if (std::filesystem::exists(etl_path)) {
    RunCommandLineWithLog(L"pktmon etl2txt " + QuoteForCommand(etl_path.wstring()) +
                              L" --out " + QuoteForCommand(txt_path.wstring()) +
                              L" --timestamp --verbose",
                          &exit_code, "pktmon_etl2txt", request_id, &log_path);
    RunCommandLineWithLog(L"pktmon etl2pcap " + QuoteForCommand(etl_path.wstring()) +
                              L" --out " + QuoteForCommand(pcap_path.wstring()),
                          &exit_code, "pktmon_etl2pcap", request_id, &log_path);
  }
  return 0;
}

Result EnsureIpViaPowerShell(uint32_t if_index, const std::string& ip_text,
                             uint8_t prefix_length, DWORD* ps_exit_code,
                             uint64_t request_id,
                             std::string* diagnostics_log_path) {
  const AdapterVisibilityProbe adapter_probe =
      ProbeAdapterViaGetAdaptersAddresses(if_index);
  const std::string script =
      "$ErrorActionPreference='Stop'\n"
      "try {\n"
      "  Write-Output 'TRACE=ensure_ip_start'\n" +
      BuildAdapterVisibilityProbeScript(if_index, adapter_probe) +
      "  if (-not $bindAdapter) { throw 'adapter binding target not visible via InterfaceGuid/InterfaceAlias' }\n"
      "  $bindAlias = $bindAdapter.Name\n"
      "  $bindGuid = $bindAdapter.InterfaceGuid\n"
      "  $existing = Get-NetIPAddress -InterfaceAlias $bindAlias" +
      " -AddressFamily IPv4 -IPAddress '" + ip_text +
      "' -ErrorAction SilentlyContinue\n"
      "  if (-not $existing) {\n"
      "    New-NetIPAddress -InterfaceAlias $bindAlias" +
      " -IPAddress '" + ip_text + "' -PrefixLength " +
      std::to_string(static_cast<int>(prefix_length)) +
      " -AddressFamily IPv4 -Type Unicast -PolicyStore ActiveStore -ErrorAction Stop | Out-Null\n"
      "    $verified = Get-NetIPAddress -InterfaceAlias $bindAlias" +
      " -AddressFamily IPv4 -IPAddress '" + ip_text +
      "' -ErrorAction SilentlyContinue\n"
      "    if (-not $verified) { throw 'New-NetIPAddress completed but verification by InterfaceAlias failed' }\n"
      "    Write-Output ('VERIFY_ALIAS=' + $verified.InterfaceAlias)\n"
      "    Write-Output ('VERIFY_IFINDEX=' + $verified.InterfaceIndex)\n"
      "    Write-Output 'RESULT=created'\n"
      "    exit 2\n"
      "  }\n"
      "  Write-Output ('VERIFY_ALIAS=' + $existing.InterfaceAlias)\n"
      "  Write-Output ('VERIFY_IFINDEX=' + $existing.InterfaceIndex)\n"
      "  Write-Output 'RESULT=exists'\n"
      "  exit 0\n"
      "} catch {\n"
      "  Write-Output ('ERR_MSG=' + $_.Exception.Message)\n"
      "  Write-Output ('ERR_FQID=' + $_.FullyQualifiedErrorId)\n"
      "  Write-Output ('ERR_CAT=' + $_.CategoryInfo)\n"
      "  if ($_.InvocationInfo) { Write-Output ('ERR_AT=' + $_.InvocationInfo.PositionMessage) }\n"
      "  if ($_.ScriptStackTrace) { Write-Output ('ERR_STACK=' + $_.ScriptStackTrace) }\n"
      "  $_ | Format-List * -Force | Out-String | Write-Output\n"
      "  exit 1\n"
      "}\n";
  DWORD code = ERROR_GEN_FAILURE;
  const bool ok = RunPowerShellScript(script, &code, "ensure_ip", request_id,
                                      diagnostics_log_path);
  if (ps_exit_code != nullptr) {
    *ps_exit_code = code;
  }
  if (ok) {
    return Result::kAlreadyExists;
  }
  if (code == 2) {
    return Result::kSuccess;
  }
  return Result::kFailed;
}

Result EnsureRouteViaPowerShell(uint32_t if_index, const std::string& cidr,
                                DWORD* ps_exit_code, uint64_t request_id,
                                std::string* diagnostics_log_path) {
  const std::string script =
      "$ErrorActionPreference='Stop'\n"
      "try {\n"
      "  Write-Output 'TRACE=ensure_route_start'\n"
      "  $existing = Get-NetRoute -InterfaceIndex " + std::to_string(if_index) +
      " -AddressFamily IPv4 -DestinationPrefix '" + cidr +
      "' -ErrorAction SilentlyContinue\n"
      "  if (-not $existing) {\n"
      "    New-NetRoute -InterfaceIndex " + std::to_string(if_index) +
      " -AddressFamily IPv4 -DestinationPrefix '" + cidr +
      "' -NextHop '0.0.0.0' -RouteMetric 5 -PolicyStore ActiveStore -ErrorAction Stop | Out-Null\n"
      "    Write-Output 'RESULT=created'\n"
      "    exit 2\n"
      "  }\n"
      "  Write-Output 'RESULT=exists'\n"
      "  exit 0\n"
      "} catch {\n"
      "  Write-Output ('ERR_MSG=' + $_.Exception.Message)\n"
      "  Write-Output ('ERR_FQID=' + $_.FullyQualifiedErrorId)\n"
      "  Write-Output ('ERR_CAT=' + $_.CategoryInfo)\n"
      "  if ($_.InvocationInfo) { Write-Output ('ERR_AT=' + $_.InvocationInfo.PositionMessage) }\n"
      "  if ($_.ScriptStackTrace) { Write-Output ('ERR_STACK=' + $_.ScriptStackTrace) }\n"
      "  $_ | Format-List * -Force | Out-String | Write-Output\n"
      "  exit 1\n"
      "}\n";
  DWORD code = ERROR_GEN_FAILURE;
  const bool ok = RunPowerShellScript(script, &code, "ensure_route", request_id,
                                      diagnostics_log_path);
  if (ps_exit_code != nullptr) {
    *ps_exit_code = code;
  }
  if (ok) {
    return Result::kAlreadyExists;
  }
  if (code == 2) {
    return Result::kSuccess;
  }
  return Result::kFailed;
}

Result EnsureIpv4AddressViaNetio(uint32_t if_index, uint32_t address_network_order,
                                 uint8_t prefix_length, DWORD* native_error_code,
                                 std::string* diagnostics_summary) {
  if (native_error_code != nullptr) {
    *native_error_code = NO_ERROR;
  }
  if (diagnostics_summary != nullptr) {
    diagnostics_summary->clear();
  }
  const AdapterVisibilityProbe adapter_probe =
      ProbeAdapterViaGetAdaptersAddresses(if_index);
  const bool admin_up = EnsureInterfaceAdminUp(if_index);

  auto append_summary = [&](int attempt_count, Result luid_result,
                            DWORD luid_error, Result index_result,
                            DWORD index_error, DWORD final_error,
                            const char* terminal_path) {
    if (diagnostics_summary == nullptr) {
      return;
    }
    std::ostringstream summary;
    summary << "probe=" << (adapter_probe.found ? 1 : 0)
            << " admin_up=" << (admin_up ? 1 : 0)
            << " oper=" << (adapter_probe.oper_status.empty() ? "-" : adapter_probe.oper_status)
            << " alias="
            << (adapter_probe.alias.empty() ? "-" : adapter_probe.alias)
            << " luid=" << adapter_probe.luid
            << " tries=" << attempt_count
            << " luid=" << ResultToShortText(luid_result) << "/" << luid_error
            << " idx=" << ResultToShortText(index_result) << "/" << index_error
            << " final=" << (terminal_path == nullptr ? "-" : terminal_path)
            << "/" << final_error;
    *diagnostics_summary = summary.str();
  };

  auto try_create = [&](bool use_luid, DWORD* result_code) -> Result {
    if (result_code != nullptr) {
      *result_code = NO_ERROR;
    }
    MIB_UNICASTIPADDRESS_ROW row = {};
    InitializeUnicastIpAddressEntry(&row);
    if (use_luid && adapter_probe.found && adapter_probe.luid != 0) {
      row.InterfaceLuid.Value = adapter_probe.luid;
    } else {
      row.InterfaceIndex = if_index;
    }
    row.Address.si_family = AF_INET;
    row.Address.Ipv4.sin_family = AF_INET;
    row.Address.Ipv4.sin_addr.S_un.S_addr = address_network_order;
    row.OnLinkPrefixLength = prefix_length > 32 ? 32 : prefix_length;
    row.DadState = IpDadStatePreferred;
    row.ValidLifetime = 0xffffffff;
    row.PreferredLifetime = 0xffffffff;
    const DWORD result = CreateUnicastIpAddressEntry(&row);
    if (result_code != nullptr) {
      *result_code = result;
    }
    if (result == NO_ERROR) {
      return Result::kSuccess;
    }
    if (result == ERROR_OBJECT_ALREADY_EXISTS) {
      return Result::kAlreadyExists;
    }
    if (result == ERROR_ACCESS_DENIED) {
      return Result::kPermissionDenied;
    }
    return Result::kFailed;
  };

  DWORD last_error = NO_ERROR;
  Result last_luid_result = Result::kFailed;
  DWORD last_luid_error = NO_ERROR;
  Result last_index_result = Result::kFailed;
  DWORD last_index_error = NO_ERROR;
  for (int attempt = 0; attempt < 8; ++attempt) {
    if (HasIpv4Address(if_index, address_network_order)) {
      if (native_error_code != nullptr) {
        *native_error_code = NO_ERROR;
      }
      append_summary(attempt, Result::kAlreadyExists, NO_ERROR,
                     Result::kAlreadyExists, NO_ERROR, NO_ERROR, "precheck");
      return Result::kAlreadyExists;
    }

    DWORD luid_error = NO_ERROR;
    const Result luid_result = try_create(true, &luid_error);
    last_luid_result = luid_result;
    last_luid_error = luid_error;
    if (luid_result == Result::kSuccess || luid_result == Result::kAlreadyExists ||
        luid_result == Result::kPermissionDenied) {
      if (native_error_code != nullptr) {
        *native_error_code = luid_error;
      }
      append_summary(attempt + 1, luid_result, luid_error, Result::kFailed,
                     NO_ERROR, luid_error, "luid");
      return luid_result;
    }

    DWORD index_error = NO_ERROR;
    const Result index_result = try_create(false, &index_error);
    last_index_result = index_result;
    last_index_error = index_error;
    if (index_result == Result::kSuccess || index_result == Result::kAlreadyExists ||
        index_result == Result::kPermissionDenied) {
      if (native_error_code != nullptr) {
        *native_error_code = index_error;
      }
      append_summary(attempt + 1, luid_result, luid_error, index_result,
                     index_error, index_error, "index");
      return index_result;
    }

    last_error = index_error != NO_ERROR ? index_error : luid_error;
    if (HasIpv4Address(if_index, address_network_order)) {
      if (native_error_code != nullptr) {
        *native_error_code = NO_ERROR;
      }
      append_summary(attempt + 1, luid_result, luid_error, index_result,
                     index_error, NO_ERROR, "postcheck");
      return Result::kAlreadyExists;
    }
    Sleep(250);
  }

  if (native_error_code != nullptr) {
    *native_error_code = last_error;
  }
  append_summary(8, last_luid_result, last_luid_error, last_index_result,
                 last_index_error, last_error, "retry_exhausted");
  return Result::kFailed;
}

bool RunPowerShellRemoveIp(uint32_t if_index, const std::string& ip_text,
                           uint64_t request_id, DWORD* exit_code,
                           std::string* diagnostics_log_path) {
  const std::string script =
      "$ErrorActionPreference='Stop'\n"
      "try {\n"
      "  Write-Output 'TRACE=remove_ip_start'\n"
      "  $x=Get-NetIPAddress -InterfaceIndex " + std::to_string(if_index) +
      " -AddressFamily IPv4 -IPAddress '" + ip_text +
      "' -ErrorAction SilentlyContinue\n"
      "  if ($x) { $x | Remove-NetIPAddress -Confirm:$false -ErrorAction Stop | Out-Null }\n"
      "  Write-Output 'RESULT=removed_or_absent'\n"
      "  exit 0\n"
      "} catch {\n"
      "  Write-Output ('ERR_MSG=' + $_.Exception.Message)\n"
      "  Write-Output ('ERR_FQID=' + $_.FullyQualifiedErrorId)\n"
      "  Write-Output ('ERR_CAT=' + $_.CategoryInfo)\n"
      "  if ($_.InvocationInfo) { Write-Output ('ERR_AT=' + $_.InvocationInfo.PositionMessage) }\n"
      "  if ($_.ScriptStackTrace) { Write-Output ('ERR_STACK=' + $_.ScriptStackTrace) }\n"
      "  $_ | Format-List * -Force | Out-String | Write-Output\n"
      "  exit 1\n"
      "}\n";
  return RunPowerShellScript(script, exit_code, "remove_ip", request_id,
                             diagnostics_log_path);
}

Result EnsureFirewallRulesForProgram(const std::string& program_path,
                                     uint64_t request_id, DWORD* exit_code,
                                     std::string* diagnostics_log_path) {
  if (program_path.empty()) {
    if (exit_code != nullptr) {
      *exit_code = ERROR_INVALID_PARAMETER;
    }
    return Result::kInvalidRequest;
  }
  std::filesystem::path path(Utf8ToWide(program_path));
  if (!std::filesystem::exists(path)) {
    if (exit_code != nullptr) {
      *exit_code = ERROR_FILE_NOT_FOUND;
    }
    return Result::kNotFound;
  }
  const std::string file_name = path.filename().u8string();
  const std::string in_rule = "ZeroTier LibZT Host " + file_name + " Inbound";
  const std::string out_rule = "ZeroTier LibZT Host " + file_name + " Outbound";
  const std::string escaped_program = EscapePowerShellSingleQuotedLiteral(program_path);
  const std::string escaped_in = EscapePowerShellSingleQuotedLiteral(in_rule);
  const std::string escaped_out = EscapePowerShellSingleQuotedLiteral(out_rule);
  const std::string script =
      "$exe='" + escaped_program + "'\n"
      "$inName='" + escaped_in + "'\n"
      "$outName='" + escaped_out + "'\n"
      "$ErrorActionPreference='Stop'\n"
      "function Get-ExactRule([string]$name){\n"
      "  return Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Select-Object -First 1\n"
      "}\n"
      "function Test-ExactAllowRule([string]$name,[string]$program,[string]$direction){\n"
      "  $rule = Get-ExactRule $name\n"
      "  if (-not $rule) { return $false }\n"
      "  $app = ($rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Select-Object -First 1).Program\n"
      "  $port = ($rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue | Select-Object -First 1).Protocol\n"
      "  return $rule.Direction -eq $direction -and $rule.Action -eq 'Allow' -and $app -ieq $program -and ($port -eq 'UDP' -or $port -eq 17)\n"
      "}\n"
      "function Ensure-UdpRule([string]$name,[string]$direction,[string]$program){\n"
      "  $exact = Test-ExactAllowRule $name $program $direction\n"
      "  Write-Output ('CHECK_' + $direction + '=' + $exact)\n"
      "  if ($exact) { return 'present' }\n"
      "  $existing = Get-ExactRule $name\n"
      "  if ($existing) {\n"
      "    Write-Output ('REMOVE_' + $direction + '=1')\n"
      "    $existing | Remove-NetFirewallRule -ErrorAction Stop | Out-Null\n"
      "  } else {\n"
      "    Write-Output ('REMOVE_' + $direction + '=0')\n"
      "  }\n"
      "  New-NetFirewallRule -DisplayName $name -Direction $direction -Program $program -Protocol UDP -Action Allow -Profile Any -ErrorAction Stop | Out-Null\n"
      "  return 'created'\n"
      "}\n"
      "Write-Output ('HOST_EXE=' + $exe)\n"
      "$inResult = Ensure-UdpRule $inName 'Inbound' $exe\n"
      "$outResult = Ensure-UdpRule $outName 'Outbound' $exe\n"
      "Write-Output ('IN_RESULT=' + $inResult)\n"
      "Write-Output ('OUT_RESULT=' + $outResult)\n"
      "$nowIn = Test-ExactAllowRule $inName $exe 'Inbound'\n"
      "$nowOut = Test-ExactAllowRule $outName $exe 'Outbound'\n"
      "Write-Output ('NOW_IN=' + $nowIn)\n"
      "Write-Output ('NOW_OUT=' + $nowOut)\n"
      "if ($nowIn -and $nowOut) { exit 0 } else { exit 23 }\n";
  DWORD ps_exit_code = ERROR_GEN_FAILURE;
  std::string log_path;
  const bool ok = RunPowerShellScript(script, &ps_exit_code, "ensure_firewall",
                                      request_id, &log_path);
  if (exit_code != nullptr) {
    *exit_code = ps_exit_code;
  }
  if (diagnostics_log_path != nullptr) {
    *diagnostics_log_path = log_path;
  }
  return ok ? Result::kSuccess : Result::kFailed;
}

Response HandleEnsureWintunAdapterRequest(const Request& request) {
  Response response = {};
  response.protocol_version = ztwin::privileged_mount::kProtocolVersion;
  response.request_id = request.request_id;

  constexpr const wchar_t* kAdapterName = L"FileTransferFlutter";
  constexpr const wchar_t* kTunnelType = L"FileTransferFlutter";
  const GUID kAdapterGuid = {0x9f0f6f21, 0x2a6b, 0x4bbf,
                             {0xb9, 0x30, 0x7a, 0xe2, 0x63, 0x85, 0x5d, 0x11}};

  std::string load_message;
  WintunApi* api = GetSharedWintunApi(&load_message);
  if (api == nullptr) {
    response.result = static_cast<uint32_t>(Result::kUnavailable);
    response.service_error = ERROR_MOD_NOT_FOUND;
    SafeCopyMessage(load_message, response.message, sizeof(response.message));
    return response;
  }

  WintunAdapterHandle handle = g_pinned_wintun_handle;
  bool created = false;
  DWORD open_error = NO_ERROR;
  DWORD create_error = NO_ERROR;
  if (handle == nullptr) {
    handle = api->open_adapter(kAdapterName);
    open_error = handle == nullptr ? GetLastError() : NO_ERROR;
    if (handle == nullptr) {
      handle = api->create_adapter(kAdapterName, kTunnelType, &kAdapterGuid);
      created = handle != nullptr;
      create_error = handle == nullptr ? GetLastError() : NO_ERROR;
    }
    if (handle != nullptr) {
      g_pinned_wintun_handle = handle;
      g_pinned_wintun_created = created;
    }
  }

  if (handle == nullptr) {
    response.result = static_cast<uint32_t>(
        (open_error == ERROR_ACCESS_DENIED || create_error == ERROR_ACCESS_DENIED)
            ? Result::kPermissionDenied
            : Result::kFailed);
    response.native_error = create_error != NO_ERROR ? create_error : open_error;
    std::ostringstream message;
    message << "wintun_open_create_failed open_error=" << open_error
            << " create_error=" << create_error
            << " load=" << load_message;
    SafeCopyMessage(message.str(), response.message, sizeof(response.message));
    return response;
  }

  NET_LUID luid = {};
  api->get_adapter_luid(handle, &luid);
  NET_IFINDEX if_index = 0;
  const DWORD convert_error = ConvertInterfaceLuidToIndex(&luid, &if_index);
  if (convert_error == NO_ERROR && if_index != 0) {
    TryBringInterfaceUp(if_index);
  }

  WintunAdapterResolution resolved;
  std::string resolve_detail;
  const bool stable = WaitForStableWintunAdapterByName(
      "FileTransferFlutter", 24, 250, &resolved, &resolve_detail);

  if (stable) {
    response.result = static_cast<uint32_t>(created ? Result::kSuccess
                                                    : Result::kAlreadyExists);
    response.adapter_if_index = resolved.if_index;
    response.adapter_luid = resolved.luid.Value;
    response.native_error = NO_ERROR;
    std::ostringstream message;
    message << (created ? "wintun_created" : "wintun_opened")
            << " if_index=" << resolved.if_index
            << " luid=" << resolved.luid.Value
            << " oper=" << resolved.oper_status
            << " load=" << WideToUtf8(api->loaded_from.c_str())
            << " resolve=" << resolve_detail
            << " pinned_created=" << (g_pinned_wintun_created ? "true" : "false");
    SafeCopyMessage(TruncateForMessage(message.str(), 191), response.message,
                    sizeof(response.message));
    return response;
  }

  response.result = static_cast<uint32_t>(Result::kFailed);
  response.native_error = convert_error;
  response.adapter_if_index = if_index;
  response.adapter_luid = luid.Value;
  std::ostringstream message;
  message << "wintun_not_stable if_index=" << if_index
          << " luid=" << luid.Value
          << " convert_error=" << convert_error
          << " resolve=" << resolve_detail
          << " pinned_created=" << (g_pinned_wintun_created ? "true" : "false");
  SafeCopyMessage(TruncateForMessage(message.str(), 191), response.message,
                  sizeof(response.message));
  return response;
}

Response HandleRequest(const Request& request) {
  Response response = {};
  response.protocol_version = ztwin::privileged_mount::kProtocolVersion;
  response.request_id = request.request_id;

  if (request.protocol_version != ztwin::privileged_mount::kProtocolVersion) {
    response.result = static_cast<uint32_t>(Result::kInvalidRequest);
    response.service_error = ERROR_REVISION_MISMATCH;
    SafeCopyMessage("protocol_mismatch", response.message,
                    sizeof(response.message));
    return response;
  }

  const std::string value(request.value,
                          strnlen_s(request.value, sizeof(request.value)));
  switch (static_cast<Command>(request.command)) {
    case Command::kPing: {
      response.result = static_cast<uint32_t>(Result::kSuccess);
      SafeCopyMessage("pong", response.message, sizeof(response.message));
      return response;
    }
    case Command::kEnsureWintunAdapter: {
      return HandleEnsureWintunAdapterRequest(request);
    }
    case Command::kEnsureFirewallHostExe: {
      if (value.empty()) {
        response.result = static_cast<uint32_t>(Result::kInvalidRequest);
        response.service_error = ERROR_INVALID_PARAMETER;
        SafeCopyMessage("invalid_firewall_request", response.message,
                        sizeof(response.message));
        return response;
      }
      DWORD ps_exit_code = ERROR_GEN_FAILURE;
      std::string diagnostics_log_path;
      const Result firewall_result = EnsureFirewallRulesForProgram(
          value, request.request_id, &ps_exit_code, &diagnostics_log_path);
      response.result = static_cast<uint32_t>(firewall_result);
      response.service_error = ps_exit_code;
      SafeCopyMessage(
          ComposeMessageWithLogPath(
              firewall_result == Result::kSuccess ? "firewall_ready"
                                                  : "firewall_failed",
              diagnostics_log_path),
          response.message, sizeof(response.message));
      return response;
    }
    case Command::kEnsureIpV4: {
      in_addr ip = {};
      if (request.if_index == 0 || !ParseIpv4(value, &ip)) {
        response.result = static_cast<uint32_t>(Result::kInvalidRequest);
        response.service_error = ERROR_INVALID_PARAMETER;
        SafeCopyMessage("invalid_ip_request", response.message,
                        sizeof(response.message));
        return response;
      }
      if (HasIpv4Address(request.if_index, ip.S_un.S_addr)) {
        response.result = static_cast<uint32_t>(Result::kAlreadyExists);
        SafeCopyMessage("ip_already_exists", response.message,
                        sizeof(response.message));
        return response;
      }
      DWORD netio_error = NO_ERROR;
      std::string netio_diagnostics;
      const Result netio_result = EnsureIpv4AddressViaNetio(
          request.if_index, ip.S_un.S_addr, request.prefix_length, &netio_error,
          &netio_diagnostics);
      if (netio_result == Result::kSuccess ||
          netio_result == Result::kAlreadyExists) {
        response.result = static_cast<uint32_t>(netio_result);
        response.native_error = NO_ERROR;
        std::ostringstream message;
        message << (netio_result == Result::kSuccess ? "ip_created_netio"
                                                     : "ip_already_exists_netio")
                << " if_index=" << request.if_index
                << " netio_error=" << netio_error
                << " diag=" << TruncateForMessage(netio_diagnostics, 96);
        SafeCopyMessage(message.str(), response.message, sizeof(response.message));
      } else if (netio_result == Result::kPermissionDenied) {
        response.result = static_cast<uint32_t>(Result::kPermissionDenied);
        response.native_error = netio_error;
        std::ostringstream message;
        message << "ip_permission_denied_netio"
                << " if_index=" << request.if_index
                << " netio_error=" << netio_error
                << " diag=" << TruncateForMessage(netio_diagnostics, 96);
        SafeCopyMessage(message.str(), response.message, sizeof(response.message));
      } else {
        DWORD ps_exit_code = ERROR_GEN_FAILURE;
        std::string diagnostics_log_path;
        const Result ps_result =
            EnsureIpViaPowerShell(request.if_index, value, request.prefix_length,
                                  &ps_exit_code, request.request_id,
                                  &diagnostics_log_path);
        if (ps_result == Result::kSuccess || ps_result == Result::kAlreadyExists) {
          response.result = static_cast<uint32_t>(ps_result);
          response.native_error = netio_error;
          response.service_error = ps_exit_code;
          SafeCopyMessage(
              ComposeMessageWithLogPath(
                  (ps_result == Result::kSuccess ? "ip_created_ps"
                                                 : "ip_already_exists_ps") +
                      (" if_index=" + std::to_string(request.if_index) +
                       " netio_error=" + std::to_string(netio_error) +
                       " diag=" + TruncateForMessage(netio_diagnostics, 48) +
                       " ps_exit=" + std::to_string(ps_exit_code)),
                  diagnostics_log_path),
              response.message, sizeof(response.message));
        } else {
          response.result = static_cast<uint32_t>(Result::kFailed);
          response.native_error = netio_error;
          response.service_error = ps_exit_code;
          SafeCopyMessage(
              ComposeMessageWithLogPath(
                  "ip_create_failed if_index=" + std::to_string(request.if_index) +
                      " netio_error=" + std::to_string(netio_error) +
                      " diag=" + TruncateForMessage(netio_diagnostics, 48) +
                      " ps_exit=" + std::to_string(ps_exit_code),
                  diagnostics_log_path),
              response.message, sizeof(response.message));
        }
      }
      return response;
    }
    case Command::kEnsureRouteV4: {
      in_addr network = {};
      uint8_t prefix_length = 0;
      if (request.if_index == 0 || !ParseIpv4Cidr(value, &network, &prefix_length)) {
        response.result = static_cast<uint32_t>(Result::kInvalidRequest);
        response.service_error = ERROR_INVALID_PARAMETER;
        SafeCopyMessage("invalid_route_request", response.message,
                        sizeof(response.message));
        return response;
      }
      if (HasRoute(request.if_index, network.S_un.S_addr, prefix_length)) {
        response.result = static_cast<uint32_t>(Result::kAlreadyExists);
        SafeCopyMessage("route_already_exists", response.message,
                        sizeof(response.message));
        return response;
      }
      MIB_IPFORWARDROW row = {};
      row.dwForwardDest = network.S_un.S_addr;
      row.dwForwardMask = PrefixMaskNetworkOrder(prefix_length);
      row.dwForwardPolicy = 0;
      row.dwForwardNextHop = htonl(INADDR_ANY);
      row.dwForwardIfIndex = request.if_index;
      row.dwForwardType = MIB_IPROUTE_TYPE_DIRECT;
      row.dwForwardProto = MIB_IPPROTO_NETMGMT;
      row.dwForwardAge = INFINITE;
      row.dwForwardNextHopAS = 0;
      row.dwForwardMetric1 = 5;
      row.dwForwardMetric2 = static_cast<DWORD>(-1);
      row.dwForwardMetric3 = static_cast<DWORD>(-1);
      row.dwForwardMetric4 = static_cast<DWORD>(-1);
      row.dwForwardMetric5 = static_cast<DWORD>(-1);
      const DWORD result = CreateIpForwardEntry(&row);
      if (result == NO_ERROR || result == ERROR_OBJECT_ALREADY_EXISTS) {
        response.result = static_cast<uint32_t>(
            result == NO_ERROR ? Result::kSuccess : Result::kAlreadyExists);
        response.native_error = result;
        SafeCopyMessage(result == NO_ERROR ? "route_created" : "route_already_exists",
                        response.message, sizeof(response.message));
      } else if (result == ERROR_ACCESS_DENIED) {
        response.result = static_cast<uint32_t>(Result::kPermissionDenied);
        response.native_error = result;
        SafeCopyMessage("route_permission_denied", response.message,
                        sizeof(response.message));
      } else {
        DWORD ps_exit_code = ERROR_GEN_FAILURE;
        std::string diagnostics_log_path;
        const Result ps_result = EnsureRouteViaPowerShell(
            request.if_index, value, &ps_exit_code, request.request_id,
            &diagnostics_log_path);
        if (ps_result == Result::kSuccess || ps_result == Result::kAlreadyExists) {
          response.result = static_cast<uint32_t>(ps_result);
          response.native_error = result;
          response.service_error = ps_exit_code;
          SafeCopyMessage(
              ComposeMessageWithLogPath(
                  ps_result == Result::kSuccess ? "route_created_ps"
                                                : "route_already_exists_ps",
                  diagnostics_log_path),
              response.message, sizeof(response.message));
        } else {
          response.result = static_cast<uint32_t>(Result::kFailed);
          response.native_error = result;
          response.service_error = ps_exit_code;
          SafeCopyMessage(
              ComposeMessageWithLogPath("route_create_failed",
                                        diagnostics_log_path),
              response.message, sizeof(response.message));
        }
      }
      return response;
    }
    case Command::kRemoveRouteV4: {
      in_addr network = {};
      uint8_t prefix_length = 0;
      if (request.if_index == 0 || !ParseIpv4Cidr(value, &network, &prefix_length)) {
        response.result = static_cast<uint32_t>(Result::kInvalidRequest);
        response.service_error = ERROR_INVALID_PARAMETER;
        SafeCopyMessage("invalid_remove_route_request", response.message,
                        sizeof(response.message));
        return response;
      }
      if (!HasRoute(request.if_index, network.S_un.S_addr, prefix_length)) {
        response.result = static_cast<uint32_t>(Result::kNotFound);
        SafeCopyMessage("route_not_found", response.message,
                        sizeof(response.message));
        return response;
      }
      if (RemoveRoute(request.if_index, network.S_un.S_addr, prefix_length)) {
        response.result = static_cast<uint32_t>(Result::kSuccess);
        SafeCopyMessage("route_removed", response.message, sizeof(response.message));
      } else {
        response.result = static_cast<uint32_t>(Result::kFailed);
        response.service_error = ERROR_GEN_FAILURE;
        SafeCopyMessage("route_remove_failed", response.message,
                        sizeof(response.message));
      }
      return response;
    }
    case Command::kRemoveIpV4: {
      if (request.if_index == 0 || value.empty()) {
        response.result = static_cast<uint32_t>(Result::kInvalidRequest);
        response.service_error = ERROR_INVALID_PARAMETER;
        SafeCopyMessage("invalid_remove_ip_request", response.message,
                        sizeof(response.message));
        return response;
      }
      DWORD ps_exit_code = ERROR_GEN_FAILURE;
      std::string diagnostics_log_path;
      if (RunPowerShellRemoveIp(request.if_index, value, request.request_id,
                                &ps_exit_code, &diagnostics_log_path)) {
        response.result = static_cast<uint32_t>(Result::kSuccess);
        response.service_error = 0;
        SafeCopyMessage(
            ComposeMessageWithLogPath("ip_removed", diagnostics_log_path),
            response.message, sizeof(response.message));
      } else {
        response.result = static_cast<uint32_t>(Result::kFailed);
        response.service_error = ps_exit_code;
        SafeCopyMessage(
            ComposeMessageWithLogPath("ip_remove_failed", diagnostics_log_path),
            response.message, sizeof(response.message));
      }
      return response;
    }
    case Command::kInvalid:
    default:
      response.result = static_cast<uint32_t>(Result::kInvalidRequest);
      response.service_error = ERROR_INVALID_PARAMETER;
      SafeCopyMessage("unknown_command", response.message, sizeof(response.message));
      return response;
  }
}

void ProcessPipeSession(HANDLE pipe) {
  Request request = {};
  DWORD bytes_read = 0;
  if (!ReadFile(pipe, &request, sizeof(request), &bytes_read, nullptr) ||
      bytes_read != sizeof(request)) {
    return;
  }
  const Response response = HandleRequest(request);
  DWORD bytes_written = 0;
  WriteFile(pipe, &response, sizeof(response), &bytes_written, nullptr);
}

void ServiceLoop() {
  PSECURITY_DESCRIPTOR security_descriptor = nullptr;
  const wchar_t* pipe_sddl =
      L"D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)";
  SECURITY_ATTRIBUTES pipe_security = {};
  if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
          pipe_sddl, SDDL_REVISION_1, &security_descriptor, nullptr)) {
    pipe_security.nLength = sizeof(pipe_security);
    pipe_security.lpSecurityDescriptor = security_descriptor;
    pipe_security.bInheritHandle = FALSE;
  }

  while (WaitForSingleObject(g_stop_event, 0) != WAIT_OBJECT_0) {
    HANDLE pipe = CreateNamedPipeW(
        ztwin::privileged_mount::kPipeName,
        PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_NOWAIT,
        4,
        sizeof(Response),
        sizeof(Request),
        1000,
        security_descriptor == nullptr ? nullptr : &pipe_security);
    if (pipe == INVALID_HANDLE_VALUE) {
      Sleep(250);
      continue;
    }

    BOOL connected = FALSE;
    while (WaitForSingleObject(g_stop_event, 0) != WAIT_OBJECT_0) {
      if (ConnectNamedPipe(pipe, nullptr)) {
        connected = TRUE;
        break;
      }
      const DWORD connect_error = GetLastError();
      if (connect_error == ERROR_PIPE_CONNECTED) {
        connected = TRUE;
        break;
      }
      if (connect_error == ERROR_PIPE_LISTENING ||
          connect_error == ERROR_NO_DATA) {
        Sleep(100);
        continue;
      }
      break;
    }
    if (connected) {
      ProcessPipeSession(pipe);
    }
    FlushFileBuffers(pipe);
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
  }

  if (security_descriptor != nullptr) {
    LocalFree(security_descriptor);
  }
}

void WINAPI ServiceControlHandler(DWORD control_code) {
  if (control_code == SERVICE_CONTROL_STOP ||
      control_code == SERVICE_CONTROL_SHUTDOWN) {
    SetServiceState(SERVICE_STOP_PENDING, NO_ERROR, 2000);
    if (g_stop_event != nullptr) {
      SetEvent(g_stop_event);
    }
  }
}

void WINAPI ServiceMain(DWORD, LPWSTR*) {
  g_status_handle =
      RegisterServiceCtrlHandlerW(L"ZeroTierMountService", ServiceControlHandler);
  if (g_status_handle == nullptr) {
    return;
  }

  g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (g_stop_event == nullptr) {
    SetServiceState(SERVICE_STOPPED, GetLastError(), 0);
    return;
  }

  SetServiceState(SERVICE_RUNNING, NO_ERROR, 0);
  ServiceLoop();
  SetServiceState(SERVICE_STOPPED, NO_ERROR, 0);

  CloseHandle(g_stop_event);
  g_stop_event = nullptr;
}

int RunConsoleMode() {
  g_stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (g_stop_event == nullptr) {
    return 2;
  }
  ServiceLoop();
  CloseHandle(g_stop_event);
  g_stop_event = nullptr;
  return 0;
}

bool ReadRequestFile(const std::wstring& path, Request* request) {
  if (request == nullptr || path.empty()) {
    return false;
  }
  std::ifstream input(std::filesystem::path(path), std::ios::binary);
  if (!input.is_open()) {
    return false;
  }
  Request loaded = {};
  input.read(reinterpret_cast<char*>(&loaded), sizeof(loaded));
  if (!input.good() && !input.eof()) {
    return false;
  }
  if (input.gcount() != static_cast<std::streamsize>(sizeof(loaded))) {
    return false;
  }
  *request = loaded;
  return true;
}

bool WriteResponseFile(const std::wstring& path, const Response& response) {
  if (path.empty()) {
    return false;
  }
  std::ofstream output(std::filesystem::path(path),
                       std::ios::binary | std::ios::trunc);
  if (!output.is_open()) {
    return false;
  }
  output.write(reinterpret_cast<const char*>(&response), sizeof(response));
  output.close();
  return output.good();
}

int RunSingleRequestMode(const std::wstring& request_path,
                         const std::wstring& response_path) {
  Request request = {};
  if (!ReadRequestFile(request_path, &request)) {
    return 3;
  }
  const Response response = HandleRequest(request);
  if (!WriteResponseFile(response_path, response)) {
    return 4;
  }
  return 0;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc >= 3 && _wcsicmp(argv[1], L"--pktmon-start") == 0) {
    std::wstring log_dir;
    int file_size_mb = 128;
    for (int i = 2; i < argc; ++i) {
      if (_wcsicmp(argv[i], L"--log-dir") == 0 && i + 1 < argc) {
        log_dir = argv[++i];
      } else if (_wcsicmp(argv[i], L"--file-size-mb") == 0 && i + 1 < argc) {
        file_size_mb = ParsePositiveInt(argv[++i], 128);
      }
    }
    return RunPktMonStartMode(log_dir, file_size_mb);
  }

  if (argc >= 3 && _wcsicmp(argv[1], L"--pktmon-stop") == 0) {
    std::wstring log_dir;
    for (int i = 2; i < argc; ++i) {
      if (_wcsicmp(argv[i], L"--log-dir") == 0 && i + 1 < argc) {
        log_dir = argv[++i];
      }
    }
    return RunPktMonStopMode(log_dir);
  }

  if (argc >= 5 && _wcsicmp(argv[1], L"--single-request") == 0) {
    std::wstring request_path;
    std::wstring response_path;
    for (int i = 2; i + 1 < argc; i += 2) {
      if (_wcsicmp(argv[i], L"--request-file") == 0) {
        request_path = argv[i + 1];
      } else if (_wcsicmp(argv[i], L"--response-file") == 0) {
        response_path = argv[i + 1];
      }
    }
    if (request_path.empty() || response_path.empty()) {
      return 2;
    }
    return RunSingleRequestMode(request_path, response_path);
  }

  if (argc >= 2 && _wcsicmp(argv[1], L"--console") == 0) {
    return RunConsoleMode();
  }

  SERVICE_TABLE_ENTRYW table[] = {
      {const_cast<LPWSTR>(L"ZeroTierMountService"), ServiceMain},
      {nullptr, nullptr},
  };
  if (!StartServiceCtrlDispatcherW(table)) {
    return static_cast<int>(GetLastError());
  }
  return 0;
}
