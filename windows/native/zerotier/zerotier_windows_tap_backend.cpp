#include "native/zerotier/zerotier_windows_tap_backend.h"

#include <Windows.h>
#include <iphlpapi.h>
#include <netioapi.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <vector>

#pragma comment(lib, "iphlpapi.lib")

namespace {

int ApplyBasePriority(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter, int score) {
  if (adapter.is_up) {
    score += 20;
  }
  if (adapter.matches_expected_ip) {
    score += 100;
  }
  return score;
}

std::string Normalize(std::string value) {
  std::transform(
      value.begin(), value.end(), value.begin(),
      [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return value;
}

using WintunAdapterHandle = void*;
using WintunCreateAdapterFn =
    WintunAdapterHandle(WINAPI*)(const wchar_t*, const wchar_t*, const GUID*);
using WintunOpenAdapterFn = WintunAdapterHandle(WINAPI*)(const wchar_t*);
using WintunCloseAdapterFn = void(WINAPI*)(WintunAdapterHandle);
using WintunGetAdapterLuidFn = void(WINAPI*)(WintunAdapterHandle, NET_LUID*);

struct WintunApi {
  HMODULE module = nullptr;
  WintunCreateAdapterFn create_adapter = nullptr;
  WintunOpenAdapterFn open_adapter = nullptr;
  WintunCloseAdapterFn close_adapter = nullptr;
  WintunGetAdapterLuidFn get_adapter_luid = nullptr;

  ~WintunApi() {
    if (module != nullptr) {
      FreeLibrary(module);
    }
  }

  bool Load(std::string* load_message) {
    char* env_value = nullptr;
    size_t env_size = 0;
    if (_dupenv_s(&env_value, &env_size, "ZT_WINTUN_DLL") == 0 &&
        env_value != nullptr && env_value[0] != '\0') {
      module = LoadLibraryA(env_value);
      free(env_value);
    }
    if (module == nullptr) {
      module = LoadLibraryW(L"wintun.dll");
    }
    if (module == nullptr) {
      if (load_message != nullptr) {
        *load_message = "wintun.dll not found";
      }
      return false;
    }

    create_adapter = reinterpret_cast<WintunCreateAdapterFn>(
        GetProcAddress(module, "WintunCreateAdapter"));
    open_adapter = reinterpret_cast<WintunOpenAdapterFn>(
        GetProcAddress(module, "WintunOpenAdapter"));
    close_adapter = reinterpret_cast<WintunCloseAdapterFn>(
        GetProcAddress(module, "WintunCloseAdapter"));
    get_adapter_luid = reinterpret_cast<WintunGetAdapterLuidFn>(
        GetProcAddress(module, "WintunGetAdapterLUID"));
    if (open_adapter == nullptr || close_adapter == nullptr ||
        create_adapter == nullptr) {
      if (load_message != nullptr) {
        *load_message = "wintun.dll missing required exports";
      }
      return false;
    }
    return true;
  }
};

void TryBringInterfaceUp(WintunGetAdapterLuidFn get_adapter_luid,
                         WintunAdapterHandle adapter) {
  if (get_adapter_luid == nullptr || adapter == nullptr) {
    return;
  }
  NET_LUID luid = {};
  get_adapter_luid(adapter, &luid);

  NET_IFINDEX if_index = 0;
  if (ConvertInterfaceLuidToIndex(&luid, &if_index) != NO_ERROR || if_index == 0) {
    return;
  }

  MIB_IFROW row = {};
  row.dwIndex = if_index;
  if (GetIfEntry(&row) != NO_ERROR) {
    return;
  }
  if (row.dwAdminStatus == MIB_IF_ADMIN_STATUS_UP) {
    return;
  }
  row.dwAdminStatus = MIB_IF_ADMIN_STATUS_UP;
  SetIfEntry(&row);
}

bool HasLikelyWintunAdapter(const ZeroTierWindowsAdapterBridge::ProbeResult& probe_result) {
  for (const auto& adapter : probe_result.adapters) {
    if (adapter.driver_kind == "wintun" || adapter.driver_kind == "wireguard") {
      return true;
    }
  }
  return false;
}

bool HasExpectedAddress(
    const ZeroTierWindowsAdapterBridge::ProbeResult& probe_result,
    const std::vector<std::string>& expected_ipv4_addresses) {
  if (expected_ipv4_addresses.empty()) {
    return false;
  }
  for (const auto& adapter : probe_result.adapters) {
    if (!adapter.matches_expected_ip) {
      continue;
    }
    if (adapter.driver_kind == "wintun" || adapter.driver_kind == "wireguard" ||
        adapter.driver_kind == "unknown") {
      return true;
    }
  }
  return false;
}

}  // namespace

std::string ZeroTierWindowsWintunTapBackend::BackendId() const {
  return "wintun";
}

bool ZeroTierWindowsWintunTapBackend::IsUsableMountCandidate(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const {
  if (!adapter.is_mount_candidate) {
    return false;
  }
  return adapter.driver_kind == "wintun" || adapter.driver_kind == "wireguard" ||
         adapter.driver_kind == "unknown";
}

int ZeroTierWindowsWintunTapBackend::FallbackScore(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const {
  int score = 0;
  if (adapter.driver_kind == "wintun") {
    score += 300;
  } else if (adapter.driver_kind == "wireguard") {
    score += 250;
  } else if (adapter.driver_kind == "unknown") {
    score += 100;
  }
  return ApplyBasePriority(adapter, score);
}

bool ZeroTierWindowsWintunTapBackend::EnsureAdapterPresent(
    const ZeroTierWindowsAdapterBridge::ProbeResult& probe_result,
    const std::vector<std::string>& expected_ipv4_addresses,
    std::string* action_summary) {
  if (action_summary != nullptr) {
    action_summary->clear();
  }
  if (HasExpectedAddress(probe_result, expected_ipv4_addresses)) {
    return false;
  }
  if (HasLikelyWintunAdapter(probe_result)) {
    return false;
  }
  if (attempted_bootstrap_) {
    return false;
  }
  attempted_bootstrap_ = true;

  WintunApi api;
  std::string load_message;
  if (!api.Load(&load_message)) {
    if (action_summary != nullptr) {
      *action_summary = "wintun bootstrap skipped: " + load_message;
    }
    return false;
  }

  constexpr const wchar_t* kAdapterName = L"FileTransferFlutter";
  constexpr const wchar_t* kTunnelType = L"FileTransferFlutter";

  WintunAdapterHandle handle = api.open_adapter(kAdapterName);
  bool created = false;
  if (handle == nullptr) {
    handle = api.create_adapter(kAdapterName, kTunnelType, nullptr);
    created = handle != nullptr;
  }
  if (handle == nullptr) {
    if (action_summary != nullptr) {
      *action_summary = "wintun bootstrap failed: open/create adapter returned null";
    }
    return false;
  }

  TryBringInterfaceUp(api.get_adapter_luid, handle);
  api.close_adapter(handle);

  if (action_summary != nullptr) {
    *action_summary = created ? "wintun adapter created" : "wintun adapter opened";
  }
  return true;
}

std::string ZeroTierWindowsZtTapBackend::BackendId() const {
  return "zttap";
}

bool ZeroTierWindowsZtTapBackend::IsUsableMountCandidate(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const {
  if (!adapter.is_mount_candidate) {
    return false;
  }
  return adapter.driver_kind == "zerotier" ||
         adapter.driver_kind == "tap-windows" || adapter.driver_kind == "unknown";
}

int ZeroTierWindowsZtTapBackend::FallbackScore(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const {
  int score = 0;
  if (adapter.driver_kind == "zerotier") {
    score += 300;
  } else if (adapter.driver_kind == "tap-windows") {
    score += 250;
  } else if (adapter.driver_kind == "unknown") {
    score += 100;
  }
  return ApplyBasePriority(adapter, score);
}

bool ZeroTierWindowsZtTapBackend::EnsureAdapterPresent(
    const ZeroTierWindowsAdapterBridge::ProbeResult& probe_result,
    const std::vector<std::string>& expected_ipv4_addresses,
    std::string* action_summary) {
  (void)probe_result;
  (void)expected_ipv4_addresses;
  if (action_summary != nullptr) {
    action_summary->clear();
  }
  return false;
}

std::string ZeroTierWindowsAutoTapBackend::BackendId() const {
  return "auto";
}

bool ZeroTierWindowsAutoTapBackend::IsUsableMountCandidate(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const {
  return adapter.is_mount_candidate;
}

int ZeroTierWindowsAutoTapBackend::FallbackScore(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const {
  int score = 0;
  if (adapter.driver_kind == "wintun") {
    score += 300;
  } else if (adapter.driver_kind == "wireguard") {
    score += 260;
  } else if (adapter.driver_kind == "zerotier") {
    score += 220;
  } else if (adapter.driver_kind == "tap-windows") {
    score += 200;
  } else if (adapter.driver_kind == "unknown") {
    score += 100;
  }
  return ApplyBasePriority(adapter, score);
}

bool ZeroTierWindowsAutoTapBackend::EnsureAdapterPresent(
    const ZeroTierWindowsAdapterBridge::ProbeResult& probe_result,
    const std::vector<std::string>& expected_ipv4_addresses,
    std::string* action_summary) {
  (void)probe_result;
  (void)expected_ipv4_addresses;
  if (action_summary != nullptr) {
    action_summary->clear();
  }
  return false;
}

std::unique_ptr<ZeroTierWindowsTapBackend> CreateWindowsTapBackendFromEnv() {
  char* raw = nullptr;
  size_t raw_size = 0;
  std::string value;
  if (_dupenv_s(&raw, &raw_size, "ZT_WIN_TAP_BACKEND") == 0 &&
      raw != nullptr) {
    value = raw;
    free(raw);
  }
  value = Normalize(value);
  if (value == "zttap" || value == "tap-windows" || value == "zerotier") {
    return std::make_unique<ZeroTierWindowsZtTapBackend>();
  }
  if (value == "auto") {
    return std::make_unique<ZeroTierWindowsAutoTapBackend>();
  }
  // Default to wintun-oriented orchestration if not explicitly specified.
  return std::make_unique<ZeroTierWindowsWintunTapBackend>();
}
