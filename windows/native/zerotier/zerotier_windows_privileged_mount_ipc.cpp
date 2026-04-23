#include "native/zerotier/zerotier_windows_privileged_mount_ipc.h"

#include <array>

namespace ztwin::privileged_mount {

bool SendRequest(const Request& request, Response* response, DWORD timeout_ms,
                 DWORD* transport_error) {
  if (response == nullptr) {
    if (transport_error != nullptr) {
      *transport_error = ERROR_INVALID_PARAMETER;
    }
    return false;
  }
  *response = Response{};
  if (transport_error != nullptr) {
    *transport_error = ERROR_GEN_FAILURE;
  }

  if (!WaitNamedPipeW(kPipeName, timeout_ms)) {
    if (transport_error != nullptr) {
      *transport_error = GetLastError();
    }
    return false;
  }

  HANDLE pipe = CreateFileW(kPipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) {
    if (transport_error != nullptr) {
      *transport_error = GetLastError();
    }
    return false;
  }

  DWORD mode = PIPE_READMODE_MESSAGE;
  SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);

  DWORD bytes_written = 0;
  if (!WriteFile(pipe, &request, sizeof(request), &bytes_written, nullptr) ||
      bytes_written != sizeof(request)) {
    if (transport_error != nullptr) {
      *transport_error = GetLastError();
    }
    CloseHandle(pipe);
    return false;
  }

  DWORD bytes_read = 0;
  if (!ReadFile(pipe, response, sizeof(*response), &bytes_read, nullptr) ||
      bytes_read != sizeof(*response)) {
    if (transport_error != nullptr) {
      *transport_error = GetLastError();
    }
    CloseHandle(pipe);
    return false;
  }

  CloseHandle(pipe);
  if (transport_error != nullptr) {
    *transport_error = NO_ERROR;
  }
  return true;
}

std::string ResultToString(Result result) {
  switch (result) {
    case Result::kSuccess:
      return "success";
    case Result::kAlreadyExists:
      return "already_exists";
    case Result::kNotFound:
      return "not_found";
    case Result::kUnavailable:
      return "unavailable";
    case Result::kInvalidRequest:
      return "invalid_request";
    case Result::kPermissionDenied:
      return "permission_denied";
    case Result::kFailed:
    default:
      return "failed";
  }
}

}  // namespace ztwin::privileged_mount

