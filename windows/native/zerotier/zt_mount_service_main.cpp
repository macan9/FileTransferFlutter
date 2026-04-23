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
  WaitForSingleObject(process.hProcess, 30000);
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

Result EnsureIpViaPowerShell(uint32_t if_index, const std::string& ip_text,
                             uint8_t prefix_length, DWORD* ps_exit_code,
                             uint64_t request_id,
                             std::string* diagnostics_log_path) {
  const std::string script =
      "$ErrorActionPreference='Stop'\n"
      "try {\n"
      "  Write-Output 'TRACE=ensure_ip_start'\n"
      "  $existing = Get-NetIPAddress -InterfaceIndex " + std::to_string(if_index) +
      " -AddressFamily IPv4 -IPAddress '" + ip_text +
      "' -ErrorAction SilentlyContinue\n"
      "  if (-not $existing) {\n"
      "    New-NetIPAddress -InterfaceIndex " + std::to_string(if_index) +
      " -IPAddress '" + ip_text + "' -PrefixLength " +
      std::to_string(static_cast<int>(prefix_length)) +
      " -AddressFamily IPv4 -Type Unicast -PolicyStore ActiveStore -ErrorAction Stop | Out-Null\n"
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
                                 uint8_t prefix_length, DWORD* native_error_code) {
  if (native_error_code != nullptr) {
    *native_error_code = NO_ERROR;
  }
  MIB_UNICASTIPADDRESS_ROW row = {};
  InitializeUnicastIpAddressEntry(&row);
  row.InterfaceIndex = if_index;
  row.Address.si_family = AF_INET;
  row.Address.Ipv4.sin_family = AF_INET;
  row.Address.Ipv4.sin_addr.S_un.S_addr = address_network_order;
  row.OnLinkPrefixLength = prefix_length > 32 ? 32 : prefix_length;
  row.DadState = IpDadStatePreferred;
  const DWORD result = CreateUnicastIpAddressEntry(&row);
  if (result == NO_ERROR) {
    return Result::kSuccess;
  }
  if (result == ERROR_OBJECT_ALREADY_EXISTS) {
    return Result::kAlreadyExists;
  }
  if (result == ERROR_ACCESS_DENIED) {
    if (native_error_code != nullptr) {
      *native_error_code = result;
    }
    return Result::kPermissionDenied;
  }
  if (native_error_code != nullptr) {
    *native_error_code = result;
  }
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
      const Result netio_result = EnsureIpv4AddressViaNetio(
          request.if_index, ip.S_un.S_addr, request.prefix_length, &netio_error);
      if (netio_result == Result::kSuccess ||
          netio_result == Result::kAlreadyExists) {
        response.result = static_cast<uint32_t>(netio_result);
        response.native_error = NO_ERROR;
        SafeCopyMessage(netio_result == Result::kSuccess ? "ip_created_netio"
                                                         : "ip_already_exists_netio",
                        response.message, sizeof(response.message));
      } else if (netio_result == Result::kPermissionDenied) {
        response.result = static_cast<uint32_t>(Result::kPermissionDenied);
        response.native_error = netio_error;
        SafeCopyMessage("ip_permission_denied_netio", response.message,
                        sizeof(response.message));
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
                  ps_result == Result::kSuccess ? "ip_created_ps"
                                                : "ip_already_exists_ps",
                  diagnostics_log_path),
              response.message, sizeof(response.message));
        } else {
          response.result = static_cast<uint32_t>(Result::kFailed);
          response.native_error = netio_error;
          response.service_error = ps_exit_code;
          SafeCopyMessage(
              ComposeMessageWithLogPath("ip_create_failed", diagnostics_log_path),
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
  std::puts("[ZT/WIN] zt_mount_service console mode started");
  ServiceLoop();
  CloseHandle(g_stop_event);
  g_stop_event = nullptr;
  return 0;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
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
