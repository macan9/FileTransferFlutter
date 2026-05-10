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
#include "native/zerotier/zerotier_windows_privileged_mount_ipc.h"

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

std::string WideToUtf8(const wchar_t* text) {
  if (text == nullptr || *text == L'\0') {
    return "";
  }
  return WideToUtf8(std::wstring(text));
}

std::string Trim(std::string text) {
  while (!text.empty() &&
         std::isspace(static_cast<unsigned char>(text.front())) != 0) {
    text.erase(text.begin());
  }
  while (!text.empty() &&
         std::isspace(static_cast<unsigned char>(text.back())) != 0) {
    text.pop_back();
  }
  return text;
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

std::string FormatNetworkIdHex(uint64_t network_id) {
  std::ostringstream stream;
  stream << std::hex << std::nouppercase << network_id;
  return stream.str();
}

std::string BuildWintunAdapterNameForNetwork(uint64_t network_id) {
  return "FileTransferFlutter-" + FormatNetworkIdHex(network_id);
}

std::wstring BuildWintunAdapterNameForNetworkWide(uint64_t network_id) {
  return Utf8ToWide(BuildWintunAdapterNameForNetwork(network_id));
}

std::wstring BuildWintunTunnelTypeWide() {
  return L"FileTransferFlutter";
}

GUID BuildWintunAdapterGuidForNetwork(uint64_t network_id) {
  GUID guid = {0x9f0f6f21, 0x2a6b, 0x4bbf, {0xb9, 0x30, 0x7a, 0xe2, 0x63, 0x85, 0x5d, 0x11}};
  guid.Data1 ^= static_cast<unsigned long>(network_id & 0xffffffffULL);
  guid.Data2 ^= static_cast<unsigned short>((network_id >> 32) & 0xffffULL);
  guid.Data3 ^= static_cast<unsigned short>((network_id >> 48) & 0xffffULL);
  for (int index = 0; index < 8; ++index) {
    guid.Data4[index] ^= static_cast<unsigned char>((network_id >> ((index % 8) * 8)) & 0xffULL);
  }
  return guid;
}

struct WintunRegistryProbe {
  bool found = false;
  std::string class_key;
  std::string connection_name;
  std::string pnp_instance_id;
  std::string service_name;
  std::string component_id;
};

bool ContainsToken(const std::string& haystack, const std::string& needle) {
  return Normalize(haystack).find(Normalize(needle)) != std::string::npos;
}

bool ProbeWintunRegistryState(const std::string& desired_name,
                              WintunRegistryProbe* probe) {
  if (probe == nullptr) {
    return false;
  }
  *probe = WintunRegistryProbe{};
  HKEY network_root = nullptr;
  const std::string root_path =
      "SYSTEM\\CurrentControlSet\\Control\\Network\\"
      "{4D36E972-E325-11CE-BFC1-08002BE10318}";
  if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, root_path.c_str(), 0, KEY_READ,
                    &network_root) != ERROR_SUCCESS) {
    return false;
  }

  DWORD index = 0;
  char subkey_name[256] = {0};
  DWORD subkey_name_len = 0;
  while (true) {
    subkey_name_len = static_cast<DWORD>(std::size(subkey_name));
    const LONG enum_result =
        RegEnumKeyExA(network_root, index++, subkey_name, &subkey_name_len,
                      nullptr, nullptr, nullptr, nullptr);
    if (enum_result == ERROR_NO_MORE_ITEMS) {
      break;
    }
    if (enum_result != ERROR_SUCCESS) {
      continue;
    }
    const std::string class_key = root_path + "\\" + subkey_name + "\\Connection";
    const std::string connection_name =
        ReadRegistryStringValue(HKEY_LOCAL_MACHINE, class_key, "Name");
    const std::string pnp_instance_id =
        ReadRegistryStringValue(HKEY_LOCAL_MACHINE, class_key, "PnpInstanceID");
    if (!ContainsToken(connection_name, desired_name) &&
        !ContainsToken(pnp_instance_id, desired_name) &&
        !ContainsToken(pnp_instance_id, "wintun")) {
      continue;
    }
    probe->found = true;
    probe->class_key = class_key;
    probe->connection_name = connection_name;
    probe->pnp_instance_id = pnp_instance_id;
    if (!pnp_instance_id.empty()) {
      const std::string enum_key =
          "SYSTEM\\CurrentControlSet\\Enum\\" + pnp_instance_id;
      probe->service_name =
          ReadRegistryStringValue(HKEY_LOCAL_MACHINE, enum_key, "Service");
      probe->component_id =
          ReadRegistryStringValue(HKEY_LOCAL_MACHINE, enum_key, "ComponentId");
    }
    break;
  }
  RegCloseKey(network_root);
  return probe->found;
}

std::string DescribeWintunRegistryProbe(const WintunRegistryProbe& probe) {
  if (!probe.found) {
    return "registry=not_found";
  }
  std::ostringstream stream;
  stream << "registry=found"
         << " name=" << (probe.connection_name.empty() ? "-" : probe.connection_name)
         << " pnp=" << (probe.pnp_instance_id.empty() ? "-" : probe.pnp_instance_id)
         << " service=" << (probe.service_name.empty() ? "-" : probe.service_name)
         << " component=" << (probe.component_id.empty() ? "-" : probe.component_id);
  return stream.str();
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
    DWORD* exit_code, std::string* debug_output) {
  constexpr DWORD kTransientCreateExitCode = 102;
  if (exit_code != nullptr) {
    *exit_code = ERROR_GEN_FAILURE;
  }
  if (debug_output != nullptr) {
    debug_output->clear();
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
  std::wstring helper_log_path;
  DWORD helper_log_error = NO_ERROR;
  if (!CreateTempPowerShellScriptPath(L"ztwl", &helper_log_path,
                                      &helper_log_error)) {
    helper_log_path.clear();
  }
  const std::wstring ps_log_path =
      EscapePowerShellSingleQuotedLiteral(helper_log_path);

  std::wostringstream script;
  script << LR"(
$ErrorActionPreference = 'Stop';
$env:Path = ')" << ps_dll_dir << LR"(' + ';' + $env:Path;
$logPath = ')" << ps_log_path << LR"(';
function Write-DebugLine {
  param([string]$Message)
  if ($logPath) {
    Add-Content -LiteralPath $logPath -Value $Message -Encoding UTF8
  }
}
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
Write-DebugLine ("open_handle=" + $handle + " open_error=" +
  [Runtime.InteropServices.Marshal]::GetLastWin32Error());
if ($handle -ne [IntPtr]::Zero) {
  [ZTWintunNative]::CloseAdapter($handle);
  Write-DebugLine "open_result=success";
  exit 0
}
$handle = [ZTWintunNative]::CreateAdapter($name, $type, [ref]$guid);
Write-DebugLine ("create_handle=" + $handle + " create_error=" +
  [Runtime.InteropServices.Marshal]::GetLastWin32Error());
if ($handle -eq [IntPtr]::Zero) {
  Write-DebugLine "create_result=failed";
  exit 101
}
Write-DebugLine "create_result=created_but_transient";
Write-DebugLine "create_note=helper_process_created_adapter;closing_created_handle_removes_adapter";
[ZTWintunNative]::CloseAdapter($handle);
Write-DebugLine "create_cleanup=closed_created_handle";
exit )" << kTransientCreateExitCode << LR"(
)";

  const bool ok = RunPowerShellScriptElevated(script.str(), exit_code);
  if (!helper_log_path.empty()) {
    std::ifstream stream(std::filesystem::path(helper_log_path),
                         std::ios::binary);
    if (stream.is_open()) {
      std::ostringstream buffer;
      buffer << stream.rdbuf();
      if (debug_output != nullptr) {
        *debug_output = buffer.str();
        while (!debug_output->empty() &&
               (debug_output->back() == '\r' || debug_output->back() == '\n')) {
          debug_output->pop_back();
        }
      }
    } else if (debug_output != nullptr) {
      *debug_output = "helper_log_unavailable";
    }
    DeleteFileW(helper_log_path.c_str());
  }
  if (ok || (exit_code != nullptr && *exit_code == kTransientCreateExitCode)) {
    return ok;
  }
  return false;
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

std::filesystem::path StandaloneMountHelperPath() {
  const std::filesystem::path current(CurrentModuleDirectory());
  if (current.empty()) {
    return {};
  }
  const std::filesystem::path preferred = current / L"zt_mount_helper_v4.exe";
  if (std::filesystem::exists(preferred)) {
    return preferred;
  }
  const std::filesystem::path prior = current / L"zt_mount_helper_v2.exe";
  if (std::filesystem::exists(prior)) {
    return prior;
  }
  const std::filesystem::path legacy = current / L"zt_mount_helper.exe";
  if (std::filesystem::exists(legacy)) {
    return legacy;
  }
  return current / L"zt_mount_service.exe";
}

bool WaitForPrivilegedMountPipeReady(DWORD timeout_ms, DWORD* error_code) {
  if (error_code != nullptr) {
    *error_code = ERROR_GEN_FAILURE;
  }
  const DWORD start = GetTickCount();
  while (GetTickCount() - start < timeout_ms) {
    if (WaitNamedPipeW(ztwin::privileged_mount::kPipeName, 250)) {
      if (error_code != nullptr) {
        *error_code = NO_ERROR;
      }
      return true;
    }
    const DWORD wait_error = GetLastError();
    if (wait_error != ERROR_FILE_NOT_FOUND && wait_error != ERROR_SEM_TIMEOUT &&
        wait_error != ERROR_PIPE_BUSY) {
      if (error_code != nullptr) {
        *error_code = wait_error;
      }
      return false;
    }
    Sleep(100);
  }
  if (error_code != nullptr) {
    *error_code = ERROR_SEM_TIMEOUT;
  }
  return false;
}

bool EnsurePrivilegedMountConsoleRunning(DWORD* launch_error,
                                         std::string* launch_detail) {
  if (launch_error != nullptr) {
    *launch_error = ERROR_GEN_FAILURE;
  }
  if (launch_detail != nullptr) {
    launch_detail->clear();
  }
  const std::filesystem::path helper_path = StandaloneMountHelperPath();
  if (helper_path.empty() || !std::filesystem::exists(helper_path)) {
    if (launch_error != nullptr) {
      *launch_error = ERROR_FILE_NOT_FOUND;
    }
    if (launch_detail != nullptr) {
      *launch_detail = "mount_console_helper_missing";
    }
    return false;
  }

  SHELLEXECUTEINFOW info = {};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOCLOSEPROCESS;
  info.lpVerb = L"runas";
  info.lpFile = helper_path.c_str();
  info.lpParameters = L"--console";
  const std::wstring helper_dir = helper_path.parent_path().wstring();
  info.lpDirectory = helper_dir.c_str();
  info.nShow = SW_HIDE;

  if (!ShellExecuteExW(&info)) {
    const DWORD error = GetLastError();
    if (launch_error != nullptr) {
      *launch_error = error;
    }
    if (launch_detail != nullptr) {
      std::ostringstream stream;
      stream << "mount_console_launch_failed error=" << error;
      *launch_detail = stream.str();
    }
    return false;
  }

  CloseHandle(info.hProcess);
  DWORD ready_error = NO_ERROR;
  const bool ready = WaitForPrivilegedMountPipeReady(5000, &ready_error);
  if (launch_error != nullptr) {
    *launch_error = ready ? NO_ERROR : ready_error;
  }
  if (launch_detail != nullptr) {
    std::ostringstream stream;
    stream << "mount_console_started helper=" << helper_path.u8string()
           << " pipe_ready=" << (ready ? "true" : "false")
           << " pipe_error=" << ready_error;
    *launch_detail = stream.str();
  }
  return ready;
}

bool EnsureWintunAdapterViaPrivilegedService(uint64_t network_id,
                                             uint32_t* if_index,
                                             uint64_t* luid,
                                             DWORD* service_error,
                                             DWORD* native_error,
                                             std::string* detail) {
  if (if_index != nullptr) {
    *if_index = 0;
  }
  if (luid != nullptr) {
    *luid = 0;
  }
  if (service_error != nullptr) {
    *service_error = ERROR_GEN_FAILURE;
  }
  if (native_error != nullptr) {
    *native_error = NO_ERROR;
  }
  if (detail != nullptr) {
    detail->clear();
  }

  ztwin::privileged_mount::Request request = {};
  request.command =
      static_cast<uint32_t>(ztwin::privileged_mount::Command::kEnsureWintunAdapter);
  request.request_id =
      (static_cast<uint64_t>(GetTickCount64()) << 16) ^ 0x57544EULL;
  request.network_id = network_id;

  ztwin::privileged_mount::Response response = {};
  DWORD transport_error = NO_ERROR;
  if (!ztwin::privileged_mount::SendRequest(request, &response, 2000,
                                            &transport_error)) {
    std::string launch_detail;
    DWORD launch_error = NO_ERROR;
    if (!EnsurePrivilegedMountConsoleRunning(&launch_error, &launch_detail) ||
        !ztwin::privileged_mount::SendRequest(request, &response, 5000,
                                              &transport_error)) {
      if (service_error != nullptr) {
        *service_error = transport_error != NO_ERROR ? transport_error : launch_error;
      }
      if (detail != nullptr) {
        std::ostringstream stream;
        stream << "service_pipe_unavailable transport_error=" << transport_error;
        if (!launch_detail.empty()) {
          stream << " " << launch_detail;
        }
        *detail = stream.str();
      }
      return false;
    }
    if (detail != nullptr && !launch_detail.empty()) {
      *detail = launch_detail;
    }
  }

  if (service_error != nullptr) {
    *service_error = response.service_error;
  }
  if (native_error != nullptr) {
    *native_error = response.native_error;
  }
  if (if_index != nullptr) {
    *if_index = response.adapter_if_index;
  }
  if (luid != nullptr) {
    *luid = response.adapter_luid;
  }
  if (detail != nullptr) {
    const std::string message(
        response.message, strnlen_s(response.message, sizeof(response.message)));
    if (!detail->empty() && !message.empty()) {
      detail->append(" ");
    }
    detail->append(message);
  }

  const auto result =
      static_cast<ztwin::privileged_mount::Result>(response.result);
  return result == ztwin::privileged_mount::Result::kSuccess ||
         result == ztwin::privileged_mount::Result::kAlreadyExists;
}

bool IsIpv4InterfaceConfigurable(const NET_LUID& luid, NET_IFINDEX if_index,
                                 DWORD* native_error);

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

struct WintunAdapterResolution {
  bool found = false;
  std::string adapter_name;
  std::string friendly_name;
  std::string description;
  NET_IFINDEX if_index = 0;
  NET_LUID luid = {};
  std::string oper_status = "unknown";
  bool is_up = false;
  bool ipv4_configurable = false;
  DWORD configurable_error = NO_ERROR;
};

std::string NormalizeAdapterLabel(std::string value) {
  value = Normalize(value);
  value.erase(std::remove_if(value.begin(), value.end(),
                             [](unsigned char ch) { return std::isspace(ch) != 0; }),
              value.end());
  return value;
}

bool LooksLikeNamedWintunAdapter(const std::string& desired_name,
                                 const std::string& friendly_name,
                                 const std::string& description,
                                 const std::string& adapter_name) {
  const std::string desired = NormalizeAdapterLabel(desired_name);
  if (desired.empty()) {
    return false;
  }
  const std::string friendly = NormalizeAdapterLabel(friendly_name);
  const std::string desc = NormalizeAdapterLabel(description);
  const std::string adapter = NormalizeAdapterLabel(adapter_name);
  return friendly == desired || desc == desired || adapter == desired;
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
  IP_ADAPTER_ADDRESSES* adapters =
      reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  if (GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_ALL_INTERFACES, nullptr,
                           adapters, &size) != NO_ERROR) {
    return false;
  }

  for (const IP_ADAPTER_ADDRESSES* adapter = adapters; adapter != nullptr;
       adapter = adapter->Next) {
    const std::string friendly_name = WideToUtf8(adapter->FriendlyName);
    const std::string description = WideToUtf8(adapter->Description);
    const std::string adapter_name =
        adapter->AdapterName == nullptr ? "" : adapter->AdapterName;
    if (!LooksLikeNamedWintunAdapter(desired_name, friendly_name, description,
                                     adapter_name)) {
      continue;
    }
    resolution->found = true;
    resolution->adapter_name = adapter_name;
    resolution->friendly_name = friendly_name;
    resolution->description = description;
    resolution->if_index = adapter->IfIndex;
    resolution->luid = adapter->Luid;
    resolution->oper_status = OperStatusToString(adapter->OperStatus);
    resolution->is_up = adapter->OperStatus == IfOperStatusUp;
    return true;
  }
  return false;
}

bool WaitForStableWintunAdapterByName(const std::string& desired_name,
                                      int attempts, DWORD sleep_ms,
                                      WintunAdapterResolution* resolution,
                                      std::string* detail) {
  WintunAdapterResolution current;
  DWORD last_error = ERROR_NOT_FOUND;
  for (int attempt = 0; attempt < attempts; ++attempt) {
    if (ResolveWintunAdapterByName(desired_name, &current) && current.if_index != 0) {
      current.ipv4_configurable =
          IsIpv4InterfaceConfigurable(current.luid, current.if_index, &last_error);
      current.configurable_error = last_error;
      if (current.ipv4_configurable && IsInterfaceEnumerableByIfIndex(current.if_index)) {
        if (resolution != nullptr) {
          *resolution = current;
        }
        if (detail != nullptr) {
          std::ostringstream stream;
          stream << "attempt=" << (attempt + 1)
                 << " if_index=" << current.if_index
                 << " luid=" << current.luid.Value
                 << " oper=" << current.oper_status
                 << " up=" << (current.is_up ? "true" : "false")
                 << " alias="
                 << (current.friendly_name.empty() ? "-" : current.friendly_name);
          *detail = stream.str();
        }
        return true;
      }
      if (detail != nullptr) {
        std::ostringstream stream;
        stream << "attempt=" << (attempt + 1)
               << " found=true"
               << " if_index=" << current.if_index
               << " luid=" << current.luid.Value
               << " oper=" << current.oper_status
               << " up=" << (current.is_up ? "true" : "false")
               << " configurable=" << (current.ipv4_configurable ? "true" : "false")
               << " cfg_error=" << last_error;
        *detail = stream.str();
      }
    } else if (detail != nullptr) {
      std::ostringstream stream;
      stream << "attempt=" << (attempt + 1) << " found=false";
      *detail = stream.str();
    }
    Sleep(sleep_ms);
  }
  if (resolution != nullptr) {
    *resolution = current;
  }
  return false;
}

std::string ZeroTierWindowsWintunTapBackend::DescribeMountCandidateDecision(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const {
  if (!adapter.is_mount_candidate) {
    return "reject:not_mount_candidate";
  }
  if (adapter.driver_kind == "wintun" || adapter.driver_kind == "wireguard" ||
      adapter.driver_kind == "unknown") {
    return "accept:driver_kind=" + adapter.driver_kind;
  }
  return "reject:driver_kind=" + adapter.driver_kind +
         ";expected=wintun|wireguard|unknown";
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
    const std::vector<uint64_t>& network_ids,
    const std::vector<std::string>& expected_ipv4_addresses,
    std::string* action_summary) {
  if (action_summary != nullptr) {
    action_summary->clear();
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
  std::vector<uint64_t> target_network_ids = network_ids;
  if (target_network_ids.empty()) {
    if (action_summary != nullptr) {
      *action_summary = "wintun bootstrap skipped: no active network ids";
    }
    return false;
  }
  std::sort(target_network_ids.begin(), target_network_ids.end());
  target_network_ids.erase(
      std::unique(target_network_ids.begin(), target_network_ids.end()),
      target_network_ids.end());

  const bool process_elevated = IsProcessElevated();
  bool any_changed = false;
  bool any_failed = false;
  std::vector<std::string> summaries;

  for (const uint64_t network_id : target_network_ids) {
    const std::wstring adapter_name_wide =
        BuildWintunAdapterNameForNetworkWide(network_id);
    const std::string adapter_name = BuildWintunAdapterNameForNetwork(network_id);
    const GUID adapter_guid = BuildWintunAdapterGuidForNetwork(network_id);
    const std::wstring tunnel_type_wide = BuildWintunTunnelTypeWide();

    WintunAdapterHandle handle = api->open_adapter(adapter_name_wide.c_str());
    const DWORD open_error = handle == nullptr ? GetLastError() : NO_ERROR;
    bool created = false;
    if (handle == nullptr) {
      handle =
          api->create_adapter(adapter_name_wide.c_str(), tunnel_type_wide.c_str(),
                              &adapter_guid);
      created = handle != nullptr;
    }
    const DWORD create_error =
        created || handle != nullptr ? NO_ERROR : GetLastError();

    DWORD helper_exit_code = NO_ERROR;
    bool helper_attempted = false;
    bool helper_succeeded = false;
    std::string helper_debug_output;
    uint32_t helper_if_index = 0;
    uint64_t helper_luid = 0;
    DWORD helper_native_error = NO_ERROR;

    if (handle == nullptr &&
        (open_error == ERROR_ACCESS_DENIED ||
         create_error == ERROR_ACCESS_DENIED) &&
        !process_elevated && IsPrivilegedWintunBootstrapEnabled()) {
      helper_attempted = true;
      helper_succeeded = EnsureWintunAdapterViaPrivilegedService(
          network_id, &helper_if_index, &helper_luid, &helper_exit_code,
          &helper_native_error, &helper_debug_output);
    }

    WintunAdapterResolution resolved;
    std::string resolve_detail;
    NET_LUID luid = {};
    NET_IFINDEX if_index = 0;
    bool enumerated = false;
    DWORD configurable_error = ERROR_NOT_FOUND;
    bool configurable = false;
    WintunRegistryProbe registry_probe;

    if (handle != nullptr) {
      api->get_adapter_luid(handle, &luid);
      if (ConvertInterfaceLuidToIndex(&luid, &if_index) == NO_ERROR &&
          if_index != 0) {
        TryBringInterfaceUp(api->get_adapter_luid, handle);
        for (int attempt = 0; attempt < 10; ++attempt) {
          if (IsInterfaceEnumerableByIfIndex(if_index)) {
            enumerated = true;
            break;
          }
          Sleep(200);
        }
      }
      configurable = WaitForIpv4InterfaceConfigurable(luid, if_index, 30, 250,
                                                      &configurable_error);
      api->close_adapter(handle);
      handle = nullptr;
    } else if (helper_succeeded && helper_if_index != 0 && helper_luid != 0) {
      if_index = helper_if_index;
      luid.Value = helper_luid;
      enumerated = IsInterfaceEnumerableByIfIndex(if_index);
      configurable = WaitForIpv4InterfaceConfigurable(luid, if_index, 30, 250,
                                                      &configurable_error);
      std::ostringstream helper_detail;
      helper_detail << "service_if_index=" << helper_if_index
                    << " service_luid=" << helper_luid
                    << " enumerable=" << (enumerated ? "true" : "false");
      resolve_detail = helper_detail.str();
    }

    const bool resolved_stable = WaitForStableWintunAdapterByName(
        adapter_name, 12, 250, &resolved, &resolve_detail);
    ProbeWintunRegistryState(adapter_name, &registry_probe);
    if (resolved_stable) {
      if_index = resolved.if_index;
      luid = resolved.luid;
      enumerated = true;
      configurable = true;
      configurable_error = NO_ERROR;
    }

    std::ostringstream stream;
    stream << "network_id=" << FormatNetworkIdHex(network_id)
           << " adapter=" << adapter_name;

    if (!enumerated || !configurable) {
      any_failed = true;
      ++consecutive_failures_;
      install_state_ = (open_error == ERROR_ACCESS_DENIED ||
                        create_error == ERROR_ACCESS_DENIED) &&
                               !process_elevated
                           ? InstallState::kPermissionDenied
                           : InstallState::kRepairNeeded;
      next_bootstrap_tick_ms_ = now + BootstrapRetryDelayMs(bootstrap_attempts_);
      stream << " result=failed"
             << " open_error=" << open_error
             << " create_error=" << create_error
             << " helper_attempted=" << (helper_attempted ? "true" : "false")
             << " helper_succeeded=" << (helper_succeeded ? "true" : "false")
             << " helper_exit_code=" << helper_exit_code
             << " helper_native_error=" << helper_native_error
             << " if_index=" << if_index
             << " luid=" << luid.Value
             << " enumerated=" << (enumerated ? "true" : "false")
             << " configurable=" << (configurable ? "true" : "false")
             << " configurable_error=" << configurable_error;
      if (!resolve_detail.empty()) {
        stream << " resolve_detail=" << resolve_detail;
      }
      stream << " " << DescribeWintunRegistryProbe(registry_probe);
      if (!helper_debug_output.empty()) {
        stream << " helper_debug=" << helper_debug_output;
      }
      summaries.push_back(stream.str());
      continue;
    }

    any_changed = any_changed || created || helper_succeeded;
    stream << " result=" << (created ? "created" : "opened")
           << " if_index=" << if_index
           << " luid=" << luid.Value;
    if (!resolve_detail.empty()) {
      stream << " resolve_detail=" << resolve_detail;
    }
    stream << " " << DescribeWintunRegistryProbe(registry_probe);
    summaries.push_back(stream.str());
  }

  if (any_failed) {
    if (action_summary != nullptr) {
      std::ostringstream stream;
      stream << "wintun bootstrap partial_failure ";
      for (size_t index = 0; index < summaries.size(); ++index) {
        if (index > 0) {
          stream << " | ";
        }
        stream << summaries[index];
      }
      *action_summary = stream.str();
    }
    return false;
  }

  install_state_ = InstallState::kInstalled;
  consecutive_failures_ = 0;
  next_bootstrap_tick_ms_ = 0;
  if (action_summary != nullptr) {
    std::ostringstream stream;
    stream << "wintun bootstrap ready ";
    for (size_t index = 0; index < summaries.size(); ++index) {
      if (index > 0) {
        stream << " | ";
      }
      stream << summaries[index];
    }
    *action_summary = stream.str();
  }
  return any_changed;
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

std::string ZeroTierWindowsZtTapBackend::DescribeMountCandidateDecision(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const {
  if (!adapter.is_mount_candidate) {
    return "reject:not_mount_candidate";
  }
  if (adapter.driver_kind == "zerotier" ||
      adapter.driver_kind == "tap-windows" ||
      adapter.driver_kind == "wintun" ||
      adapter.driver_kind == "wireguard" ||
      adapter.driver_kind == "unknown") {
    return "accept:driver_kind=" + adapter.driver_kind;
  }
  return "reject:driver_kind=" + adapter.driver_kind +
         ";expected=zerotier|tap-windows|wintun|wireguard|unknown";
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
    const std::vector<uint64_t>& network_ids,
    const std::vector<std::string>& expected_ipv4_addresses,
    std::string* action_summary) {
  std::string fallback_action;
  const bool changed = wintun_fallback_.EnsureAdapterPresent(
      probe_result, network_ids, expected_ipv4_addresses, &fallback_action);
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

std::string ZeroTierWindowsAutoTapBackend::DescribeMountCandidateDecision(
    const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const {
  if (!adapter.is_mount_candidate) {
    return "reject:not_mount_candidate";
  }
  return "accept:auto_backend_mount_candidate";
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
    const std::vector<uint64_t>& network_ids,
    const std::vector<std::string>& expected_ipv4_addresses,
    std::string* action_summary) {
  const bool changed = wintun_backend_.EnsureAdapterPresent(
      probe_result, network_ids, expected_ipv4_addresses, action_summary);
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
