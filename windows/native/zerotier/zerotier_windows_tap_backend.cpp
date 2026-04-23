#include "native/zerotier/zerotier_windows_tap_backend.h"

#include <Windows.h>
#include <iphlpapi.h>
#include <netioapi.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <sstream>
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

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) {
    return L"";
  }
  const int required =
      MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, nullptr, 0);
  if (required <= 1) {
    return L"";
  }
  std::wstring wide(static_cast<size_t>(required), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.c_str(), -1, wide.data(), required);
  wide.pop_back();
  return wide;
}

std::string WideToUtf8(const std::wstring& text) {
  if (text.empty()) {
    return "";
  }
  const int required = WideCharToMultiByte(
      CP_UTF8, 0, text.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (required <= 1) {
    return "";
  }
  std::string utf8(static_cast<size_t>(required), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, utf8.data(), required,
                      nullptr, nullptr);
  utf8.pop_back();
  return utf8;
}

std::wstring CurrentModuleDirectory() {
  std::vector<wchar_t> buffer(MAX_PATH);
  for (;;) {
    DWORD length =
        GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
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
      AddLoadCandidate(
          &candidates,
          probe / L"third_party" / L"wintun" / L"0.14.1" / L"extract" /
              L"wintun" / L"bin" / kWintunArchDir / L"wintun.dll");
      probe = probe.parent_path();
    }
  }

  candidates.push_back(L"wintun.dll");
  return candidates;
}

unsigned long long BootstrapRetryDelayMs(int attempt) {
  if (attempt <= 0) {
    return 1000;
  }
  const unsigned long long scaled =
      static_cast<unsigned long long>(attempt) * 1500ull;
  return std::min<unsigned long long>(15000ull, scaled);
}

bool IsInterfaceEnumerableByIfIndex(NET_IFINDEX if_index) {
  if (if_index == 0) {
    return false;
  }
  MIB_IFROW row = {};
  row.dwIndex = if_index;
  return GetIfEntry(&row) == NO_ERROR;
}

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
    }
  }

  bool Load(std::string* load_message) {
    for (const auto& candidate : BuildWintunDllLoadCandidates()) {
      module = LoadLibraryW(candidate.c_str());
      if (module != nullptr) {
        loaded_from = candidate;
        break;
      }
    }
    if (module == nullptr) {
      if (load_message != nullptr) {
        *load_message = "wintun.dll not found from configured and bundled paths";
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
        create_adapter == nullptr || get_adapter_luid == nullptr) {
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

std::string ZeroTierWindowsWintunTapBackend::InstallStateLabel() const {
  switch (install_state_) {
    case InstallState::kNotInstalled:
      return "not_installed";
    case InstallState::kInstalling:
      return "installing";
    case InstallState::kInstalled:
      return "installed";
    case InstallState::kRepairNeeded:
      return "repair_needed";
    default:
      return "unknown";
  }
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
    install_state_ = InstallState::kInstalled;
    consecutive_failures_ = 0;
    return false;
  }
  if (HasLikelyWintunAdapter(probe_result)) {
    install_state_ = InstallState::kInstalled;
    consecutive_failures_ = 0;
    return false;
  }
  const unsigned long long now = GetTickCount64();
  if (install_state_ == InstallState::kInstalled &&
      !probe_result.has_virtual_adapter &&
      !probe_result.has_mount_candidate &&
      next_bootstrap_tick_ms_ == 0) {
    next_bootstrap_tick_ms_ = now + 5000;
  }
  if (next_bootstrap_tick_ms_ != 0 && now < next_bootstrap_tick_ms_) {
    if (action_summary != nullptr) {
      *action_summary = "wintun bootstrap throttled state=" + InstallStateLabel();
    }
    return false;
  }
  install_state_ = InstallState::kInstalling;
  ++bootstrap_attempts_;

  WintunApi api;
  std::string load_message;
  if (!api.Load(&load_message)) {
    ++consecutive_failures_;
    install_state_ = consecutive_failures_ >= 3 ? InstallState::kRepairNeeded
                                                 : InstallState::kNotInstalled;
    next_bootstrap_tick_ms_ = now + BootstrapRetryDelayMs(bootstrap_attempts_);
    if (action_summary != nullptr) {
      *action_summary = "wintun bootstrap skipped: " + load_message +
                        " state=" + InstallStateLabel();
    }
    return false;
  }

  constexpr const wchar_t* kAdapterName = L"FileTransferFlutter";
  constexpr const wchar_t* kTunnelType = L"FileTransferFlutter";
  const GUID kAdapterGuid = {0x9f0f6f21, 0x2a6b, 0x4bbf,
                              {0xb9, 0x30, 0x7a, 0xe2, 0x63, 0x85, 0x5d, 0x11}};

  WintunAdapterHandle handle = api.open_adapter(kAdapterName);
  bool created = false;
  if (handle == nullptr) {
    handle = api.create_adapter(kAdapterName, kTunnelType, &kAdapterGuid);
    created = handle != nullptr;
  }
  if (handle == nullptr) {
    ++consecutive_failures_;
    install_state_ = consecutive_failures_ >= 3 ? InstallState::kRepairNeeded
                                                 : InstallState::kNotInstalled;
    next_bootstrap_tick_ms_ = now + BootstrapRetryDelayMs(bootstrap_attempts_);
    if (action_summary != nullptr) {
      std::ostringstream stream;
      stream << "wintun bootstrap failed: open/create adapter returned null"
             << " last_error=" << GetLastError()
             << " state=" << InstallStateLabel();
      *action_summary = stream.str();
    }
    return false;
  }

  NET_LUID luid = {};
  api.get_adapter_luid(handle, &luid);
  NET_IFINDEX if_index = 0;
  if (ConvertInterfaceLuidToIndex(&luid, &if_index) == NO_ERROR && if_index != 0) {
    TryBringInterfaceUp(api.get_adapter_luid, handle);
  }
  api.close_adapter(handle);

  bool enumerated = false;
  if (if_index != 0) {
    for (int attempt = 0; attempt < 10; ++attempt) {
      if (IsInterfaceEnumerableByIfIndex(if_index)) {
        enumerated = true;
        break;
      }
      Sleep(200);
    }
  }
  if (!enumerated) {
    ++consecutive_failures_;
    install_state_ = InstallState::kRepairNeeded;
    next_bootstrap_tick_ms_ = now + BootstrapRetryDelayMs(bootstrap_attempts_);
    if (action_summary != nullptr) {
      std::ostringstream stream;
      stream << "wintun adapter created but not enumerable"
             << " if_index=" << if_index
             << " state=" << InstallStateLabel();
      *action_summary = stream.str();
    }
    return false;
  }

  install_state_ = InstallState::kInstalled;
  consecutive_failures_ = 0;
  next_bootstrap_tick_ms_ = 0;

  if (action_summary != nullptr) {
    std::string loaded_from = WideToUtf8(api.loaded_from);
    if (loaded_from.empty()) {
      loaded_from = "wintun.dll";
    }
    *action_summary = (created ? "wintun adapter created" : "wintun adapter opened");
    action_summary->append(" if_index=");
    action_summary->append(std::to_string(if_index));
    action_summary->append(" via ");
    action_summary->append(loaded_from);
    action_summary->append(" state=");
    action_summary->append(InstallStateLabel());
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
         adapter.driver_kind == "tap-windows" ||
         adapter.driver_kind == "wintun" ||
         adapter.driver_kind == "wireguard" ||
         adapter.driver_kind == "unknown";
}

int ZeroTierWindowsZtTapBackend::FallbackScore(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const {
  int score = 0;
  if (adapter.driver_kind == "zerotier") {
    score += 300;
  } else if (adapter.driver_kind == "tap-windows") {
    score += 250;
  } else if (adapter.driver_kind == "wintun") {
    score += 220;
  } else if (adapter.driver_kind == "wireguard") {
    score += 200;
  } else if (adapter.driver_kind == "unknown") {
    score += 100;
  }
  return ApplyBasePriority(adapter, score);
}

bool ZeroTierWindowsZtTapBackend::EnsureAdapterPresent(
    const ZeroTierWindowsAdapterBridge::ProbeResult& probe_result,
    const std::vector<std::string>& expected_ipv4_addresses,
    std::string* action_summary) {
  std::string fallback_action;
  const bool changed = wintun_fallback_.EnsureAdapterPresent(
      probe_result, expected_ipv4_addresses, &fallback_action);
  if (action_summary != nullptr) {
    if (fallback_action.empty()) {
      action_summary->clear();
    } else {
      *action_summary = "zttap backend fallback: " + fallback_action;
    }
  }
  return changed;
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
  const bool changed = wintun_backend_.EnsureAdapterPresent(
      probe_result, expected_ipv4_addresses, action_summary);
  if (action_summary != nullptr) {
    if (!action_summary->empty()) {
      *action_summary = "auto backend: " + *action_summary;
    }
  }
  return changed;
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
