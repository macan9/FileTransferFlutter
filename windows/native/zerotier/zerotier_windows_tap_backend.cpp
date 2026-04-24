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

#include "native/zerotier/zerotier_windows_tap_backend.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <vector>

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "Shell32.lib")

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
  std::transform(
      normalized.begin(), normalized.end(), normalized.begin(),
      [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return normalized == "1" || normalized == "true" || normalized == "yes" ||
         normalized == "on";
}

bool IsPrivilegedWintunBootstrapEnabled() {
  char* raw = nullptr;
  size_t raw_size = 0;
  if (_dupenv_s(&raw, &raw_size, "ZT_WIN_ENABLE_PRIVILEGED_WINTUN_BOOTSTRAP") !=
          0 ||
      raw == nullptr) {
    return true;
  }
  const bool enabled = ParseTruthyEnvValue(raw);
  free(raw);
  return enabled;
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

std::wstring GuidToWideString(const GUID& guid) {
  wchar_t buffer[64] = {0};
  if (StringFromGUID2(guid, buffer, 64) == 0) {
    return L"";
  }
  std::wstring text(buffer);
  if (!text.empty() && text.front() == L'{') {
    text.erase(text.begin());
  }
  if (!text.empty() && text.back() == L'}') {
    text.pop_back();
  }
  return text;
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

  std::wstring script_path;
  DWORD temp_path_error = NO_ERROR;
  if (!CreateTempPowerShellScriptPath(L"ztw", &script_path, &temp_path_error)) {
    if (exit_code != nullptr) {
      *exit_code = temp_path_error;
    }
    return false;
  }
  std::ofstream stream(std::filesystem::path(script_path),
                       std::ios::binary | std::ios::trunc);
  if (!stream.is_open()) {
    if (exit_code != nullptr) {
      *exit_code = ERROR_OPEN_FAILED;
    }
    DeleteFileW(script_path.c_str());
    return false;
  }
  const std::string script_utf8 = "\xEF\xBB\xBF& { " + WideToUtf8(script) + " }\r\n";
  stream.write(script_utf8.data(),
               static_cast<std::streamsize>(script_utf8.size()));
  stream.close();

  std::wstring parameters =
      L"-NoProfile -ExecutionPolicy Bypass -File \"" + script_path +
      L"\"";

  SHELLEXECUTEINFOW info = {};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOCLOSEPROCESS;
  info.lpVerb = L"runas";
  info.lpFile = L"powershell.exe";
  info.lpParameters = parameters.c_str();
  info.nShow = SW_HIDE;

  if (!ShellExecuteExW(&info)) {
    if (exit_code != nullptr) {
      *exit_code = GetLastError();
    }
    DeleteFileW(script_path.c_str());
    return false;
  }

  DWORD process_exit_code = ERROR_GEN_FAILURE;
  const DWORD wait_result = WaitForSingleObject(info.hProcess, 45000);
  if (wait_result == WAIT_OBJECT_0) {
    GetExitCodeProcess(info.hProcess, &process_exit_code);
  } else if (wait_result == WAIT_TIMEOUT) {
    process_exit_code = WAIT_TIMEOUT;
    TerminateProcess(info.hProcess, WAIT_TIMEOUT);
  } else {
    process_exit_code = GetLastError();
  }
  CloseHandle(info.hProcess);
  DeleteFileW(script_path.c_str());

  if (exit_code != nullptr) {
    *exit_code = process_exit_code;
  }
  return wait_result == WAIT_OBJECT_0 && process_exit_code == 0;
}

bool RunPowerShellScriptHidden(const std::wstring& script, DWORD* exit_code) {
  if (exit_code != nullptr) {
    *exit_code = ERROR_GEN_FAILURE;
  }
  if (script.empty()) {
    if (exit_code != nullptr) {
      *exit_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }

  std::wstring script_path;
  DWORD temp_path_error = NO_ERROR;
  if (!CreateTempPowerShellScriptPath(L"ztw", &script_path, &temp_path_error)) {
    if (exit_code != nullptr) {
      *exit_code = temp_path_error;
    }
    return false;
  }
  std::ofstream stream(std::filesystem::path(script_path),
                       std::ios::binary | std::ios::trunc);
  if (!stream.is_open()) {
    DeleteFileW(script_path.c_str());
    if (exit_code != nullptr) {
      *exit_code = ERROR_OPEN_FAILED;
    }
    return false;
  }
  const std::string script_utf8 = "\xEF\xBB\xBF& { " + WideToUtf8(script) + " }\r\n";
  stream.write(script_utf8.data(),
               static_cast<std::streamsize>(script_utf8.size()));
  stream.close();

  std::wstring command_line =
      L"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" +
      script_path + L"\"";
  std::vector<wchar_t> command_line_buffer(command_line.begin(),
                                           command_line.end());
  command_line_buffer.push_back(L'\0');

  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {};
  if (!CreateProcessW(nullptr, command_line_buffer.data(), nullptr, nullptr,
                      FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup,
                      &process)) {
    const DWORD create_error = GetLastError();
    DeleteFileW(script_path.c_str());
    if (exit_code != nullptr) {
      *exit_code = create_error;
    }
    return false;
  }

  DWORD process_exit_code = ERROR_GEN_FAILURE;
  const DWORD wait_result = WaitForSingleObject(process.hProcess, 15000);
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
  DeleteFileW(script_path.c_str());

  if (exit_code != nullptr) {
    *exit_code = process_exit_code;
  }
  return wait_result == WAIT_OBJECT_0 && process_exit_code == 0;
}

bool TryBootstrapWintunAdapterViaElevatedPowerShell(
    const std::wstring& wintun_dll_path, const std::wstring& adapter_name,
    const std::wstring& tunnel_type, const GUID& adapter_guid,
    DWORD* exit_code) {
  if (exit_code != nullptr) {
    *exit_code = ERROR_GEN_FAILURE;
  }
  if (wintun_dll_path.empty() || adapter_name.empty() || tunnel_type.empty()) {
    if (exit_code != nullptr) {
      *exit_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }

  const std::wstring guid_text = GuidToWideString(adapter_guid);
  if (guid_text.empty()) {
    if (exit_code != nullptr) {
      *exit_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }

  const std::filesystem::path dll_path(wintun_dll_path);
  const std::wstring dll_dir =
      dll_path.has_parent_path() ? dll_path.parent_path().wstring() : L"";
  if (dll_dir.empty()) {
    if (exit_code != nullptr) {
      *exit_code = ERROR_INVALID_PARAMETER;
    }
    return false;
  }

  const std::wstring ps_dll_dir = EscapePowerShellSingleQuotedLiteral(dll_dir);
  const std::wstring ps_adapter = EscapePowerShellSingleQuotedLiteral(adapter_name);
  const std::wstring ps_tunnel = EscapePowerShellSingleQuotedLiteral(tunnel_type);
  const std::wstring ps_guid = EscapePowerShellSingleQuotedLiteral(guid_text);

  std::wostringstream script;
  script << LR"(
$ErrorActionPreference = 'Stop';
$env:Path = ')" << ps_dll_dir << LR"(' + ';' + $env:Path;
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ZTWintunNative {
  [DllImport("wintun.dll", EntryPoint="WintunOpenAdapter", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr OpenAdapter(string name);
  [DllImport("wintun.dll", EntryPoint="WintunCreateAdapter", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr CreateAdapter(string name, string tunnelType, ref Guid requestedGuid);
  [DllImport("wintun.dll", EntryPoint="WintunCloseAdapter", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern void CloseAdapter(IntPtr adapter);
}
"@;
$name = ')" << ps_adapter << LR"(';
$type = ')" << ps_tunnel << LR"(';
$guid = [Guid]::Parse(')" << ps_guid << LR"(');
$handle = [ZTWintunNative]::OpenAdapter($name);
if ($handle -ne [IntPtr]::Zero) {
  [ZTWintunNative]::CloseAdapter($handle);
  exit 0
}
$handle = [ZTWintunNative]::CreateAdapter($name, $type, [ref]$guid);
if ($handle -eq [IntPtr]::Zero) {
  exit 101
}
[ZTWintunNative]::CloseAdapter($handle);
exit 0
)";

  return RunPowerShellScriptElevated(script.str(), exit_code);
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

WintunApi* GetSharedWintunApi(std::string* load_message) {
  static WintunApi api;
  static bool loaded = false;
  if (!loaded) {
    if (!api.Load(load_message)) {
      return nullptr;
    }
    loaded = true;
  }
  return &api;
}

WintunAdapterHandle& SharedPinnedWintunHandle() {
  static WintunAdapterHandle handle = nullptr;
  return handle;
}

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

bool IsIpv4InterfaceConfigurable(const NET_LUID& luid, NET_IFINDEX if_index,
                                 DWORD* native_error) {
  if (native_error != nullptr) {
    *native_error = NO_ERROR;
  }
  NET_IFINDEX resolved_if_index = if_index;
  if (resolved_if_index == 0 && luid.Value != 0) {
    const DWORD convert_result = ConvertInterfaceLuidToIndex(&luid, &resolved_if_index);
    if (convert_result != NO_ERROR) {
      if (native_error != nullptr) {
        *native_error = convert_result;
      }
      return false;
    }
  }
  if (resolved_if_index == 0) {
    if (native_error != nullptr) {
      *native_error = ERROR_INVALID_PARAMETER;
    }
    return false;
  }
  std::wostringstream script;
  script << L"$ErrorActionPreference='Stop'; "
         << L"$ipIf = Get-NetIPInterface -InterfaceIndex " << resolved_if_index
         << L" -AddressFamily IPv4 -ErrorAction SilentlyContinue; "
         << L"if (-not $ipIf) { exit 2 }; "
         << L"$adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.ifIndex -eq "
         << resolved_if_index << L" } | Select-Object -First 1; "
         << L"if (-not $adapter) { exit 3 }; "
         << L"exit 0";
  DWORD result = ERROR_GEN_FAILURE;
  const bool ok = RunPowerShellScriptHidden(script.str(), &result);
  if (native_error != nullptr) {
    *native_error = result;
  }
  return ok;
}

bool IsAdapterRecordConfigurable(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter,
    DWORD* native_error) {
  NET_LUID luid = {};
  luid.Value = adapter.luid;
  return IsIpv4InterfaceConfigurable(luid, adapter.if_index, native_error);
}

bool HasConfigurableWintunAdapter(
    const ZeroTierWindowsAdapterBridge::ProbeResult& probe_result,
    std::string* detail) {
  DWORD last_error = ERROR_NOT_FOUND;
  for (const auto& adapter : probe_result.adapters) {
    if (adapter.driver_kind != "wintun" && adapter.driver_kind != "wireguard") {
      continue;
    }
    DWORD native_error = NO_ERROR;
    if (IsAdapterRecordConfigurable(adapter, &native_error)) {
      if (detail != nullptr) {
        std::ostringstream stream;
        stream << "if_index=" << adapter.if_index << " luid=" << adapter.luid
               << " alias=" << adapter.friendly_name;
        *detail = stream.str();
      }
      return true;
    }
    last_error = native_error;
  }
  if (detail != nullptr) {
    *detail = "last_error=" + std::to_string(last_error);
  }
  return false;
}

bool WaitForIpv4InterfaceConfigurable(const NET_LUID& luid, NET_IFINDEX if_index,
                                      int attempts, DWORD sleep_ms,
                                      DWORD* native_error) {
  DWORD last_error = ERROR_NOT_FOUND;
  for (int attempt = 0; attempt < attempts; ++attempt) {
    if (IsIpv4InterfaceConfigurable(luid, if_index, &last_error)) {
      if (native_error != nullptr) {
        *native_error = NO_ERROR;
      }
      return true;
    }
    Sleep(sleep_ms);
  }
  if (native_error != nullptr) {
    *native_error = last_error;
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
    case InstallState::kPermissionDenied:
      return "permission_denied";
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
  std::string configurable_detail;
  if (HasConfigurableWintunAdapter(probe_result, &configurable_detail)) {
    install_state_ = InstallState::kInstalled;
    consecutive_failures_ = 0;
    next_bootstrap_tick_ms_ = 0;
    if (action_summary != nullptr) {
      *action_summary = "wintun adapter configurable " + configurable_detail;
    }
    return false;
  }
  if (HasLikelyWintunAdapter(probe_result) && action_summary != nullptr) {
    *action_summary =
        "wintun adapter visible via GetAdaptersAddresses but not configurable " +
        configurable_detail;
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

  WintunApi* api = nullptr;
  std::string load_message;
  api = GetSharedWintunApi(&load_message);
  if (api == nullptr) {
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

  WintunAdapterHandle handle = api->open_adapter(kAdapterName);
  DWORD open_error = handle == nullptr ? GetLastError() : NO_ERROR;
  bool created = false;
  if (handle == nullptr) {
    handle = api->create_adapter(kAdapterName, kTunnelType, &kAdapterGuid);
    created = handle != nullptr;
  }
  DWORD create_error = created || handle != nullptr ? NO_ERROR : GetLastError();
  DWORD helper_exit_code = NO_ERROR;
  bool helper_attempted = false;
  bool helper_succeeded = false;

  if (handle == nullptr &&
      (open_error == ERROR_ACCESS_DENIED || create_error == ERROR_ACCESS_DENIED) &&
      !IsProcessElevated() && IsPrivilegedWintunBootstrapEnabled()) {
    helper_attempted = true;
    helper_succeeded = TryBootstrapWintunAdapterViaElevatedPowerShell(
        api->loaded_from.empty() ? L"wintun.dll" : api->loaded_from, kAdapterName,
        kTunnelType, kAdapterGuid, &helper_exit_code);
    if (helper_succeeded) {
      handle = api->open_adapter(kAdapterName);
      open_error = handle == nullptr ? GetLastError() : NO_ERROR;
      if (handle == nullptr) {
        handle = api->create_adapter(kAdapterName, kTunnelType, &kAdapterGuid);
        created = handle != nullptr;
        create_error = created || handle != nullptr ? NO_ERROR : GetLastError();
      }
    }
  }

  if (handle == nullptr) {
    ++consecutive_failures_;
    if ((open_error == ERROR_ACCESS_DENIED ||
         create_error == ERROR_ACCESS_DENIED) &&
        !IsProcessElevated()) {
      install_state_ = InstallState::kPermissionDenied;
    } else {
      install_state_ = consecutive_failures_ >= 3 ? InstallState::kRepairNeeded
                                                   : InstallState::kNotInstalled;
    }
    next_bootstrap_tick_ms_ = now + BootstrapRetryDelayMs(bootstrap_attempts_);
    if (action_summary != nullptr) {
      std::ostringstream stream;
      stream << "wintun bootstrap failed: open/create adapter returned null"
             << " open_error=" << open_error
             << " create_error=" << create_error
             << " process_elevated=" << (IsProcessElevated() ? "true" : "false")
             << " helper_attempted=" << (helper_attempted ? "true" : "false")
             << " helper_succeeded=" << (helper_succeeded ? "true" : "false");
      if (helper_attempted) {
        stream << " helper_exit_code=" << helper_exit_code;
      }
      stream << " last_error=" << GetLastError()
             << " state=" << InstallStateLabel();
      *action_summary = stream.str();
    }
    return false;
  }

  WintunAdapterHandle& pinned_handle = SharedPinnedWintunHandle();
  if (pinned_handle == nullptr) {
    pinned_handle = handle;
  } else if (handle != pinned_handle) {
    api->close_adapter(handle);
  }

  NET_LUID luid = {};
  api->get_adapter_luid(pinned_handle, &luid);
  NET_IFINDEX if_index = 0;
  if (ConvertInterfaceLuidToIndex(&luid, &if_index) == NO_ERROR && if_index != 0) {
    TryBringInterfaceUp(api->get_adapter_luid, pinned_handle);
  }

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
  DWORD configurable_error = ERROR_NOT_FOUND;
  const bool configurable = WaitForIpv4InterfaceConfigurable(
      luid, if_index, 30, 250, &configurable_error);
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
  if (!configurable) {
    ++consecutive_failures_;
    install_state_ = InstallState::kRepairNeeded;
    next_bootstrap_tick_ms_ = now + BootstrapRetryDelayMs(bootstrap_attempts_);
    if (action_summary != nullptr) {
      std::ostringstream stream;
      stream << "wintun adapter created but IPv4 interface not configurable"
             << " if_index=" << if_index
             << " luid=" << luid.Value
             << " native_error=" << configurable_error
             << " state=" << InstallStateLabel();
      *action_summary = stream.str();
    }
    return false;
  }

  install_state_ = InstallState::kInstalled;
  consecutive_failures_ = 0;
  next_bootstrap_tick_ms_ = 0;

  if (action_summary != nullptr) {
    std::string loaded_from = WideToUtf8(api->loaded_from);
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
