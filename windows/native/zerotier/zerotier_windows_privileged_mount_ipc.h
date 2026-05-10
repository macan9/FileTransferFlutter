#pragma once

#include <Windows.h>

#include <cstdint>
#include <string>

namespace ztwin::privileged_mount {

constexpr uint32_t kProtocolVersion = 6;
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\ZeroTierMountServicePipeV6";

enum class Command : uint32_t {
  kInvalid = 0,
  kPing = 1,
  kEnsureIpV4 = 2,
  kEnsureRouteV4 = 3,
  kRemoveIpV4 = 4,
  kRemoveRouteV4 = 5,
  kEnsureWintunAdapter = 6,
  kEnsureFirewallHostExe = 7,
  kStartWintunProxySession = 8,
  kStopWintunProxySession = 9,
  kWintunProxySendPacket = 10,
  kWintunProxyReceivePacket = 11,
};

enum class Result : uint32_t {
  kFailed = 0,
  kSuccess = 1,
  kAlreadyExists = 2,
  kNotFound = 3,
  kUnavailable = 4,
  kInvalidRequest = 5,
  kPermissionDenied = 6,
};

#pragma pack(push, 1)
struct Request {
  uint32_t protocol_version = kProtocolVersion;
  uint32_t command = 0;
  uint64_t request_id = 0;
  uint64_t network_id = 0;
  uint64_t session_id = 0;
  uint32_t if_index = 0;
  uint8_t prefix_length = 0;
  uint8_t reserved[3] = {0, 0, 0};
  char value[260] = {0};  // IPv4, CIDR, or host exe path
};

struct Response {
  uint32_t protocol_version = kProtocolVersion;
  uint32_t result = 0;
  uint32_t native_error = 0;
  uint32_t service_error = 0;
  uint32_t adapter_if_index = 0;
  uint32_t reserved = 0;
  uint64_t adapter_luid = 0;
  uint64_t request_id = 0;
  uint64_t session_id = 0;
  char message[192] = {0};
};
#pragma pack(pop)

static_assert(sizeof(Request) == 300, "Unexpected privileged mount request size");
static_assert(sizeof(Response) == 240, "Unexpected privileged mount response size");

bool SendRequest(const Request& request, Response* response, DWORD timeout_ms,
                 DWORD* transport_error);

std::string ResultToString(Result result);

}  // namespace ztwin::privileged_mount
