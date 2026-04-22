#include "native/zerotier/zerotier_windows_adapter_bridge.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdio>
#include <regex>
#include <sstream>

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

bool LooksLikeVirtualAdapter(const std::string& name) {
  const std::string lowered = ToLower(name);
  return lowered.find("zerotier") != std::string::npos ||
         lowered.find("wintun") != std::string::npos ||
         lowered.find("tap") != std::string::npos ||
         lowered.find("vpn") != std::string::npos ||
         lowered.find("virtual") != std::string::npos;
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

std::string ReadCommandOutput(const char* command) {
  std::string output;
#ifdef _WIN32
  FILE* pipe = _popen(command, "r");
#else
  FILE* pipe = popen(command, "r");
#endif
  if (pipe == nullptr) {
    return output;
  }

  std::array<char, 4096> buffer{};
  while (fgets(buffer.data(), static_cast<int>(buffer.size()), pipe) != nullptr) {
    output += buffer.data();
  }

#ifdef _WIN32
  _pclose(pipe);
#else
  pclose(pipe);
#endif
  return output;
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

  const std::string ipconfig = ReadCommandOutput("ipconfig");
  if (ipconfig.empty()) {
    result.summary = "ipconfig returned no output.";
    return result;
  }

  const std::regex ip_pattern(R"((\d{1,3}\.){3}\d{1,3})");
  std::istringstream stream(ipconfig);
  std::string line;
  std::string current_adapter;

  while (std::getline(stream, line)) {
    const std::string trimmed = Trim(line);
    if (trimmed.empty()) {
      continue;
    }

    if (trimmed.back() == ':') {
      current_adapter = trimmed.substr(0, trimmed.size() - 1);
      if (LooksLikeVirtualAdapter(current_adapter)) {
        result.has_virtual_adapter = true;
        result.virtual_adapter_names.push_back(current_adapter);
      }
      continue;
    }

    std::smatch match;
    if (!std::regex_search(trimmed, match, ip_pattern)) {
      continue;
    }
    const std::string ip = match.str(0);
    if (ip == "0.0.0.0") {
      continue;
    }
    result.detected_ipv4_addresses.push_back(ip);
  }

  for (const auto& expected : result.expected_ipv4_addresses) {
    if (std::find(result.detected_ipv4_addresses.begin(),
                  result.detected_ipv4_addresses.end(),
                  expected) != result.detected_ipv4_addresses.end()) {
      result.has_expected_network_ip = true;
      break;
    }
  }

  std::ostringstream summary;
  summary << "virtual_adapter=" << (result.has_virtual_adapter ? "true" : "false")
          << " expected_ip_bound=" << (result.has_expected_network_ip ? "true" : "false")
          << " expected_ips=" << Join(result.expected_ipv4_addresses)
          << " adapters=" << Join(result.virtual_adapter_names)
          << " detected_ips=" << Join(result.detected_ipv4_addresses);
  result.summary = summary.str();
  return result;
}
