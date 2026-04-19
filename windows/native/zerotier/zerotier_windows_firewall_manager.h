#ifndef FLUTTER_RUNNER_ZEROTIER_WINDOWS_FIREWALL_MANAGER_H_
#define FLUTTER_RUNNER_ZEROTIER_WINDOWS_FIREWALL_MANAGER_H_

#include <string>
#include <vector>

struct ZeroTierWindowsFirewallPortRule {
  std::string protocol;
  long port = 0;
};

class ZeroTierWindowsFirewallManager {
 public:
  ZeroTierWindowsFirewallManager() = default;

  bool ApplyRules(const std::string& rule_scope_id,
                  const std::string& peer_zerotier_ip,
                  const std::vector<ZeroTierWindowsFirewallPortRule>& ports,
                  std::string* error_message);
  bool RemoveRules(const std::string& rule_scope_id, std::string* error_message);
};

#endif  // FLUTTER_RUNNER_ZEROTIER_WINDOWS_FIREWALL_MANAGER_H_
