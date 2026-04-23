#ifndef FLUTTER_RUNNER_ZEROTIER_WINDOWS_TAP_BACKEND_H_
#define FLUTTER_RUNNER_ZEROTIER_WINDOWS_TAP_BACKEND_H_

#include <memory>
#include <string>

#include "native/zerotier/zerotier_windows_adapter_bridge.h"

class ZeroTierWindowsTapBackend {
 public:
  virtual ~ZeroTierWindowsTapBackend() = default;

  virtual std::string BackendId() const = 0;
  virtual bool IsUsableMountCandidate(
      const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const = 0;
  virtual int FallbackScore(
      const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const = 0;

  virtual bool EnsureAdapterPresent(
      const ZeroTierWindowsAdapterBridge::ProbeResult& probe_result,
      const std::vector<std::string>& expected_ipv4_addresses,
      std::string* action_summary) = 0;
};

class ZeroTierWindowsWintunTapBackend : public ZeroTierWindowsTapBackend {
 public:
  std::string BackendId() const override;
  bool IsUsableMountCandidate(
      const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const override;
  int FallbackScore(
      const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const override;
  bool EnsureAdapterPresent(
      const ZeroTierWindowsAdapterBridge::ProbeResult& probe_result,
      const std::vector<std::string>& expected_ipv4_addresses,
      std::string* action_summary) override;

 private:
  bool attempted_bootstrap_ = false;
};

class ZeroTierWindowsZtTapBackend : public ZeroTierWindowsTapBackend {
 public:
  std::string BackendId() const override;
  bool IsUsableMountCandidate(
      const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const override;
  int FallbackScore(
      const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const override;
  bool EnsureAdapterPresent(
      const ZeroTierWindowsAdapterBridge::ProbeResult& probe_result,
      const std::vector<std::string>& expected_ipv4_addresses,
      std::string* action_summary) override;
};

class ZeroTierWindowsAutoTapBackend : public ZeroTierWindowsTapBackend {
 public:
  std::string BackendId() const override;
  bool IsUsableMountCandidate(
      const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const override;
  int FallbackScore(
      const ZeroTierWindowsAdapterBridge::AdapterRecord& adapter) const override;
  bool EnsureAdapterPresent(
      const ZeroTierWindowsAdapterBridge::ProbeResult& probe_result,
      const std::vector<std::string>& expected_ipv4_addresses,
      std::string* action_summary) override;
};

std::unique_ptr<ZeroTierWindowsTapBackend> CreateWindowsTapBackendFromEnv();

#endif  // FLUTTER_RUNNER_ZEROTIER_WINDOWS_TAP_BACKEND_H_
