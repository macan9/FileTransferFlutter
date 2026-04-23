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
  enum class InstallState {
    kNotInstalled = 0,
    kInstalling = 1,
    kInstalled = 2,
    kRepairNeeded = 3,
  };

  std::string InstallStateLabel() const;

  InstallState install_state_ = InstallState::kNotInstalled;
  int bootstrap_attempts_ = 0;
  int consecutive_failures_ = 0;
  unsigned long long next_bootstrap_tick_ms_ = 0;
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

 private:
  ZeroTierWindowsWintunTapBackend wintun_fallback_;
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

 private:
  ZeroTierWindowsWintunTapBackend wintun_backend_;
};

std::unique_ptr<ZeroTierWindowsTapBackend> CreateWindowsTapBackendFromEnv();

#endif  // FLUTTER_RUNNER_ZEROTIER_WINDOWS_TAP_BACKEND_H_
