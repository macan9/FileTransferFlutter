#include "native/zerotier/zerotier_windows_firewall_manager.h"

#include <Windows.h>
#include <netfw.h>

#include <iomanip>
#include <sstream>
#include <string>

namespace {

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return L"";
  }
  const int size =
      MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  if (size <= 0) {
    return L"";
  }
  std::wstring result(static_cast<size_t>(size - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), size);
  return result;
}

BSTR ToBstr(const std::wstring& value) {
  return SysAllocStringLen(value.data(), static_cast<UINT>(value.size()));
}

int ProtocolToWindowsValue(const std::string& protocol) {
  if (_stricmp(protocol.c_str(), "TCP") == 0) {
    return NET_FW_IP_PROTOCOL_TCP;
  }
  if (_stricmp(protocol.c_str(), "UDP") == 0) {
    return NET_FW_IP_PROTOCOL_UDP;
  }
  return NET_FW_IP_PROTOCOL_ANY;
}

std::string FormatHResult(HRESULT hr) {
  std::ostringstream stream;
  stream << "0x" << std::hex << std::uppercase
         << static_cast<unsigned long>(hr);
  return stream.str();
}

std::string ComposeFirewallError(const std::string& context, HRESULT hr) {
  return context + " HRESULT=" + FormatHResult(hr) +
         ". Windows may require administrator approval for firewall updates.";
}

}  // namespace

bool ZeroTierWindowsFirewallManager::ApplyRules(
    const std::string& rule_scope_id, const std::string& peer_zerotier_ip,
    const std::vector<ZeroTierWindowsFirewallPortRule>& ports,
    std::string* error_message) {
  if (ports.empty()) {
    return true;
  }
  if (rule_scope_id.empty()) {
    if (error_message != nullptr) {
      *error_message = "Firewall rule scope id is required.";
    }
    return false;
  }
  if (peer_zerotier_ip.empty()) {
    if (error_message != nullptr) {
      *error_message = "Peer ZeroTier IP is required for inbound firewall rules.";
    }
    return false;
  }

  INetFwPolicy2* policy = nullptr;
  HRESULT hr = CoCreateInstance(__uuidof(NetFwPolicy2), nullptr, CLSCTX_INPROC_SERVER,
                                __uuidof(INetFwPolicy2),
                                reinterpret_cast<void**>(&policy));
  if (FAILED(hr) || policy == nullptr) {
    if (error_message != nullptr) {
      *error_message = ComposeFirewallError("Failed to create INetFwPolicy2.", hr);
    }
    return false;
  }

  INetFwRules* rules = nullptr;
  hr = policy->get_Rules(&rules);
  if (FAILED(hr) || rules == nullptr) {
    policy->Release();
    if (error_message != nullptr) {
      *error_message =
          ComposeFirewallError("Failed to access Windows firewall rules.", hr);
    }
    return false;
  }

  std::string remove_error;
  if (!RemoveRules(rule_scope_id, &remove_error)) {
    rules->Release();
    policy->Release();
    if (error_message != nullptr) {
      *error_message = remove_error;
    }
    return false;
  }

  std::vector<std::wstring> added_rule_names;
  for (const auto& port_rule : ports) {
    INetFwRule* rule = nullptr;
    hr = CoCreateInstance(__uuidof(NetFwRule), nullptr, CLSCTX_INPROC_SERVER,
                          __uuidof(INetFwRule),
                          reinterpret_cast<void**>(&rule));
    if (FAILED(hr) || rule == nullptr) {
      if (error_message != nullptr) {
        *error_message =
            ComposeFirewallError("Failed to create Windows firewall rule.", hr);
      }
      rules->Release();
      policy->Release();
      return false;
    }

    const std::wstring display_name =
        Utf8ToWide("FileTransferFlutter-" + rule_scope_id + "-" +
                   port_rule.protocol + "-" + std::to_string(port_rule.port));
    const std::wstring remote_ip = Utf8ToWide(peer_zerotier_ip);
    const std::wstring local_port = Utf8ToWide(std::to_string(port_rule.port));
    const std::wstring grouping = Utf8ToWide("FileTransferFlutter ZeroTier");
    const std::wstring interface_types = Utf8ToWide("All");
    BSTR name_bstr = ToBstr(display_name);
    BSTR remote_bstr = ToBstr(remote_ip);
    BSTR local_port_bstr = ToBstr(local_port);
    BSTR grouping_bstr = ToBstr(grouping);
    BSTR interface_types_bstr = ToBstr(interface_types);

    rule->put_Name(name_bstr);
    rule->put_Description(name_bstr);
    rule->put_Protocol(ProtocolToWindowsValue(port_rule.protocol));
    rule->put_LocalPorts(local_port_bstr);
    rule->put_RemoteAddresses(remote_bstr);
    rule->put_Grouping(grouping_bstr);
    rule->put_InterfaceTypes(interface_types_bstr);
    rule->put_Direction(NET_FW_RULE_DIR_IN);
    rule->put_Action(NET_FW_ACTION_ALLOW);
    rule->put_Enabled(VARIANT_TRUE);
    rule->put_Profiles(NET_FW_PROFILE2_ALL);

    hr = rules->Add(rule);
    SysFreeString(name_bstr);
    SysFreeString(remote_bstr);
    SysFreeString(local_port_bstr);
    SysFreeString(grouping_bstr);
    SysFreeString(interface_types_bstr);
    rule->Release();

    if (FAILED(hr)) {
      if (error_message != nullptr) {
        *error_message =
            ComposeFirewallError("Failed to add Windows firewall rule.", hr);
      }
      std::string rollback_error;
      RemoveRuleNames(added_rule_names, &rollback_error);
      rules->Release();
      policy->Release();
      return false;
    }

    added_rule_names.push_back(display_name);
  }

  rules->Release();
  policy->Release();
  return true;
}

bool ZeroTierWindowsFirewallManager::RemoveRules(
    const std::string& rule_scope_id, std::string* error_message) {
  if (rule_scope_id.empty()) {
    if (error_message != nullptr) {
      *error_message = "Firewall rule scope id is required.";
    }
    return false;
  }

  INetFwPolicy2* policy = nullptr;
  HRESULT hr = CoCreateInstance(__uuidof(NetFwPolicy2), nullptr, CLSCTX_INPROC_SERVER,
                                __uuidof(INetFwPolicy2),
                                reinterpret_cast<void**>(&policy));
  if (FAILED(hr) || policy == nullptr) {
    if (error_message != nullptr) {
      *error_message = ComposeFirewallError("Failed to create INetFwPolicy2.", hr);
    }
    return false;
  }

  INetFwRules* rules = nullptr;
  hr = policy->get_Rules(&rules);
  if (FAILED(hr) || rules == nullptr) {
    policy->Release();
    if (error_message != nullptr) {
      *error_message =
          ComposeFirewallError("Failed to access Windows firewall rules.", hr);
    }
    return false;
  }

  IUnknown* unknown = nullptr;
  hr = rules->get__NewEnum(&unknown);
  if (FAILED(hr) || unknown == nullptr) {
    rules->Release();
    policy->Release();
    if (error_message != nullptr) {
      *error_message =
          ComposeFirewallError("Failed to enumerate firewall rules.", hr);
    }
    return false;
  }

  IEnumVARIANT* enumerator = nullptr;
  hr = unknown->QueryInterface(IID_IEnumVARIANT,
                               reinterpret_cast<void**>(&enumerator));
  unknown->Release();
  if (FAILED(hr) || enumerator == nullptr) {
    rules->Release();
    policy->Release();
    if (error_message != nullptr) {
      *error_message =
          ComposeFirewallError("Failed to enumerate firewall rules.", hr);
    }
    return false;
  }

  const std::wstring prefix = Utf8ToWide("FileTransferFlutter-" + rule_scope_id + "-");
  std::vector<std::wstring> names_to_remove;
  VARIANT variant;
  VariantInit(&variant);
  ULONG fetched = 0;
  while (enumerator->Next(1, &variant, &fetched) == S_OK) {
    if (variant.vt == VT_DISPATCH && variant.pdispVal != nullptr) {
      INetFwRule* rule = nullptr;
      hr = variant.pdispVal->QueryInterface(__uuidof(INetFwRule),
                                            reinterpret_cast<void**>(&rule));
      if (SUCCEEDED(hr) && rule != nullptr) {
        BSTR name = nullptr;
        if (SUCCEEDED(rule->get_Name(&name)) && name != nullptr) {
          const std::wstring rule_name(name, SysStringLen(name));
          if (rule_name.rfind(prefix, 0) == 0) {
            names_to_remove.push_back(rule_name);
          }
          SysFreeString(name);
        }
        rule->Release();
      }
    }
    VariantClear(&variant);
  }

  for (const auto& name : names_to_remove) {
    BSTR name_bstr = ToBstr(name);
    rules->Remove(name_bstr);
    SysFreeString(name_bstr);
  }

  enumerator->Release();
  rules->Release();
  policy->Release();
  return true;
}

bool ZeroTierWindowsFirewallManager::RemoveRuleNames(
    const std::vector<std::wstring>& rule_names, std::string* error_message) {
  if (rule_names.empty()) {
    return true;
  }

  INetFwPolicy2* policy = nullptr;
  HRESULT hr = CoCreateInstance(__uuidof(NetFwPolicy2), nullptr,
                                CLSCTX_INPROC_SERVER, __uuidof(INetFwPolicy2),
                                reinterpret_cast<void**>(&policy));
  if (FAILED(hr) || policy == nullptr) {
    if (error_message != nullptr) {
      *error_message = ComposeFirewallError("Failed to create INetFwPolicy2.", hr);
    }
    return false;
  }

  INetFwRules* rules = nullptr;
  hr = policy->get_Rules(&rules);
  if (FAILED(hr) || rules == nullptr) {
    policy->Release();
    if (error_message != nullptr) {
      *error_message =
          ComposeFirewallError("Failed to access Windows firewall rules.", hr);
    }
    return false;
  }

  for (const auto& rule_name : rule_names) {
    BSTR name_bstr = ToBstr(rule_name);
    rules->Remove(name_bstr);
    SysFreeString(name_bstr);
  }

  rules->Release();
  policy->Release();
  return true;
}
