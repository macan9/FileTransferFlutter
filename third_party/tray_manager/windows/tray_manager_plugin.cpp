#include "include/tray_manager/tray_manager_plugin.h"

// This must be included before many other Windows headers.
#include <stdio.h>
#include <windows.h>

#include <shellapi.h>
#include <strsafe.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <codecvt>
#include <map>
#include <memory>
#include <sstream>
#include <vector>

#define WM_MYMESSAGE (WM_USER + 1)

namespace {

const flutter::EncodableValue* ValueOrNull(const flutter::EncodableMap& map,
                                           const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return &(it->second);
}
std::unique_ptr<
    flutter::MethodChannel<flutter::EncodableValue>,
    std::default_delete<flutter::MethodChannel<flutter::EncodableValue>>>
    channel = nullptr;

class TrayManagerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  TrayManagerPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~TrayManagerPlugin();

 private:
  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> g_converter;

  flutter::PluginRegistrarWindows* registrar;
  NOTIFYICONDATA nid;
  NOTIFYICONIDENTIFIER niif;
  // do create pop-up menu only once.
  HMENU hMenu = CreatePopupMenu();
  HWND menu_owner_window = nullptr;
  std::vector<HBITMAP> menu_bitmaps;
  bool tray_icon_setted = false;
  UINT windows_taskbar_created_message_id = 0;

  // The ID of the WindowProc delegate registration.
  int window_proc_id = -1;

  void TrayManagerPlugin::_CreateMenu(HMENU menu, flutter::EncodableMap args);
  void TrayManagerPlugin::_ApplyIcon();
  void TrayManagerPlugin::_ClearMenuBitmaps();
  HBITMAP TrayManagerPlugin::_LoadMenuBitmap(const std::string& icon);
  HWND TrayManagerPlugin::_GetMenuOwnerWindow();
  static LRESULT CALLBACK TrayManagerPlugin::_MenuOwnerWndProc(
      HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  // Called for top-level WindowProc delegation.
  std::optional<LRESULT> TrayManagerPlugin::HandleWindowProc(HWND hwnd,
                                                             UINT message,
                                                             WPARAM wparam,
                                                             LPARAM lparam);
  HWND TrayManagerPlugin::GetMainWindow();
  void TrayManagerPlugin::Destroy(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetIcon(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetToolTip(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetContextMenu(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::PopUpContextMenu(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::GetBounds(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

static bool plugin_already_registered = false;

// static
void TrayManagerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  if (plugin_already_registered) {
    // Skip registration in subwindow
    return;
  }
  
  plugin_already_registered = true;
  
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "tray_manager",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<TrayManagerPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

TrayManagerPlugin::TrayManagerPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar(registrar) {
  window_proc_id = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
  windows_taskbar_created_message_id = RegisterWindowMessage(L"TaskbarCreated");
}

TrayManagerPlugin::~TrayManagerPlugin() {
  if (menu_owner_window != nullptr) {
    DestroyWindow(menu_owner_window);
    menu_owner_window = nullptr;
  }
  _ClearMenuBitmaps();
  registrar->UnregisterTopLevelWindowProcDelegate(window_proc_id);
}

LRESULT CALLBACK TrayManagerPlugin::_MenuOwnerWndProc(HWND hwnd, UINT message,
                                                      WPARAM wparam,
                                                      LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto create_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create_struct->lpCreateParams));
  }

  auto plugin = reinterpret_cast<TrayManagerPlugin*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (plugin != nullptr && message == WM_COMMAND) {
    flutter::EncodableMap eventData = flutter::EncodableMap();
    eventData[flutter::EncodableValue("id")] =
        flutter::EncodableValue((int)wparam);

    channel->InvokeMethod("onTrayMenuItemClick",
                          std::make_unique<flutter::EncodableValue>(eventData));
    return 0;
  }

  return DefWindowProc(hwnd, message, wparam, lparam);
}

HWND TrayManagerPlugin::_GetMenuOwnerWindow() {
  if (menu_owner_window != nullptr) {
    return menu_owner_window;
  }

  constexpr const wchar_t kMenuOwnerWindowClassName[] =
      L"TRAY_MANAGER_MENU_OWNER_WINDOW";
  static bool class_registered = false;
  if (!class_registered) {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = TrayManagerPlugin::_MenuOwnerWndProc;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.lpszClassName = kMenuOwnerWindowClassName;
    RegisterClassW(&window_class);
    class_registered = true;
  }

  menu_owner_window = CreateWindowExW(
      WS_EX_TOOLWINDOW, kMenuOwnerWindowClassName, L"", WS_POPUP, 0, 0, 0, 0,
      nullptr, nullptr, GetModuleHandle(nullptr), this);
  return menu_owner_window;
}

void TrayManagerPlugin::_ClearMenuBitmaps() {
  for (HBITMAP bitmap : menu_bitmaps) {
    DeleteObject(bitmap);
  }
  menu_bitmaps.clear();
}

HBITMAP TrayManagerPlugin::_LoadMenuBitmap(const std::string& icon) {
  if (icon.empty()) {
    return nullptr;
  }

  wchar_t module_path[MAX_PATH];
  DWORD path_length = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  if (path_length == 0 || path_length >= MAX_PATH) {
    return nullptr;
  }

  std::wstring icon_path(module_path, path_length);
  size_t slash_index = icon_path.find_last_of(L"\\/");
  if (slash_index != std::wstring::npos) {
    icon_path = icon_path.substr(0, slash_index);
  }
  icon_path += L"\\data\\flutter_assets\\";
  icon_path += g_converter.from_bytes(icon);

  int bitmap_size = GetSystemMetrics(SM_CYMENU);
  if (bitmap_size < 24) {
    bitmap_size = 24;
  } else if (bitmap_size > 32) {
    bitmap_size = 32;
  }

  HBITMAP bitmap = static_cast<HBITMAP>(
      LoadImageW(nullptr, icon_path.c_str(), IMAGE_BITMAP, bitmap_size,
                 bitmap_size, LR_LOADFROMFILE | LR_CREATEDIBSECTION));
  if (bitmap != nullptr) {
    menu_bitmaps.push_back(bitmap);
  }
  return bitmap;
}

void TrayManagerPlugin::_CreateMenu(HMENU menu, flutter::EncodableMap args) {
  flutter::EncodableList items = std::get<flutter::EncodableList>(
      args.at(flutter::EncodableValue("items")));

  int count = GetMenuItemCount(menu);
  for (int i = 0; i < count; i++) {
    // always remove at 0 because they shift every time
    RemoveMenu(menu, 0, MF_BYPOSITION);
  }

  for (flutter::EncodableValue item_value : items) {
    flutter::EncodableMap item_map =
        std::get<flutter::EncodableMap>(item_value);
    int id = std::get<int>(item_map.at(flutter::EncodableValue("id")));
    std::string type =
        std::get<std::string>(item_map.at(flutter::EncodableValue("type")));
    std::string label =
        std::get<std::string>(item_map.at(flutter::EncodableValue("label")));
    auto* checked = std::get_if<bool>(ValueOrNull(item_map, "checked"));
    auto* icon = std::get_if<std::string>(ValueOrNull(item_map, "icon"));
    bool disabled =
        std::get<bool>(item_map.at(flutter::EncodableValue("disabled")));

    UINT_PTR item_id = id;
    UINT uFlags = MF_STRING;

    if (disabled) {
      uFlags |= MF_GRAYED;
    }

    if (type.compare("separator") == 0) {
      AppendMenuW(menu, MF_SEPARATOR, item_id, NULL);
    } else {
      if (type.compare("checkbox") == 0) {
        if (checked == nullptr) {
          // skip
        } else {
          uFlags |= (*checked == true ? MF_CHECKED : MF_UNCHECKED);
        }
      } else if (type.compare("submenu") == 0) {
        uFlags |= MF_POPUP;
        HMENU sub_menu = ::CreatePopupMenu();
        _CreateMenu(sub_menu, std::get<flutter::EncodableMap>(item_map.at(
                                  flutter::EncodableValue("submenu"))));
        item_id = reinterpret_cast<UINT_PTR>(sub_menu);
      }
      AppendMenuW(menu, uFlags, item_id, g_converter.from_bytes(label).c_str());
      if (icon != nullptr) {
        HBITMAP bitmap = _LoadMenuBitmap(*icon);
        if (bitmap != nullptr) {
          MENUITEMINFOW menu_item_info;
          ZeroMemory(&menu_item_info, sizeof(MENUITEMINFOW));
          menu_item_info.cbSize = sizeof(MENUITEMINFOW);
          menu_item_info.fMask = MIIM_BITMAP;
          menu_item_info.hbmpItem = bitmap;
          SetMenuItemInfoW(menu, GetMenuItemCount(menu) - 1, TRUE,
                           &menu_item_info);
        }
      }
    }
  }
}

std::optional<LRESULT> TrayManagerPlugin::HandleWindowProc(HWND hWnd,
                                                           UINT message,
                                                           WPARAM wParam,
                                                           LPARAM lParam) {
  std::optional<LRESULT> result;
  if (message == WM_DESTROY) {
    if (tray_icon_setted) {
      Shell_NotifyIcon(NIM_DELETE, &nid);
      DestroyIcon(nid.hIcon);
    }
  } else if (message == WM_COMMAND) {
    flutter::EncodableMap eventData = flutter::EncodableMap();
    eventData[flutter::EncodableValue("id")] =
        flutter::EncodableValue((int)wParam);

    channel->InvokeMethod("onTrayMenuItemClick",
                          std::make_unique<flutter::EncodableValue>(eventData));
  } else if (message == WM_MYMESSAGE) {
    switch (lParam) {
      case WM_LBUTTONUP:
        channel->InvokeMethod("onTrayIconMouseDown",
                              std::make_unique<flutter::EncodableValue>());
        break;
      case WM_RBUTTONUP:
        channel->InvokeMethod("onTrayIconRightMouseDown",
                              std::make_unique<flutter::EncodableValue>());
        break;
      default:
        return DefWindowProc(hWnd, message, wParam, lParam);
    };
  } else if (message == windows_taskbar_created_message_id) {
    if (windows_taskbar_created_message_id != 0 && tray_icon_setted) {
      // restore the icon with the existing resource.
      tray_icon_setted = false;
      _ApplyIcon();
    }
  } else if (message == WM_POWERBROADCAST) {
    // Handle power management events (sleep/wake)
    switch (wParam) {
      case PBT_APMRESUMEAUTOMATIC:
      case PBT_APMRESUMESUSPEND:
        // System is resuming from sleep/hibernation
        if (tray_icon_setted) {
          // Restore the tray icon after system wakes up
          tray_icon_setted = false;
          _ApplyIcon();
        }
        break;
      default:
        break;
    }
  }
  return result;
}

HWND TrayManagerPlugin::GetMainWindow() {
  return ::GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT);
}

void TrayManagerPlugin::Destroy(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  Shell_NotifyIcon(NIM_DELETE, &nid);
  DestroyIcon(nid.hIcon);
  tray_icon_setted = false;

  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::SetIcon(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  std::string iconPath =
      std::get<std::string>(args.at(flutter::EncodableValue("iconPath")));

  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> converter;

  if (nid.hIcon != nullptr) {
    DestroyIcon(nid.hIcon);
  }

  nid.hIcon = static_cast<HICON>(
      LoadImage(nullptr, (LPCWSTR)(converter.from_bytes(iconPath).c_str()),
                IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE));

  _ApplyIcon();

  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::_ApplyIcon() {
  if (tray_icon_setted) {
    Shell_NotifyIcon(NIM_MODIFY, &nid);
  } else {
    HICON hIconBackup = nid.hIcon;
    WCHAR szTipBackup[128];
    StringCchCopy(szTipBackup, _countof(szTipBackup), nid.szTip);
    
    ZeroMemory(&nid, sizeof(NOTIFYICONDATA));
    nid.cbSize = sizeof(NOTIFYICONDATA);
    nid.hWnd = GetMainWindow();
    nid.uID = 1;
    nid.hIcon = hIconBackup;
    StringCchCopy(nid.szTip, _countof(nid.szTip), szTipBackup);
    nid.uCallbackMessage = WM_MYMESSAGE;
    nid.uFlags = NIF_MESSAGE | NIF_ICON;
    if (nid.szTip[0] != '\0') {
      nid.uFlags |= NIF_TIP;
    }
    Shell_NotifyIcon(NIM_ADD, &nid);
  }

  niif.cbSize = sizeof(NOTIFYICONIDENTIFIER);
  niif.hWnd = nid.hWnd;
  niif.uID = nid.uID;
  niif.guidItem = GUID_NULL;

  tray_icon_setted = true;
}

void TrayManagerPlugin::SetToolTip(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  std::string toolTip =
      std::get<std::string>(args.at(flutter::EncodableValue("toolTip")));

  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> converter;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  StringCchCopy(nid.szTip, _countof(nid.szTip),
                converter.from_bytes(toolTip).c_str());
  Shell_NotifyIcon(NIM_MODIFY, &nid);

  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::SetContextMenu(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  _ClearMenuBitmaps();
  _CreateMenu(hMenu, std::get<flutter::EncodableMap>(
                         args.at(flutter::EncodableValue("menu"))));

  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::PopUpContextMenu(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  bool bringAppToFront =
      std::get<bool>(args.at(flutter::EncodableValue("bringAppToFront")));

  HWND main_window = GetMainWindow();
  HWND menu_owner = bringAppToFront ? main_window : _GetMenuOwnerWindow();
  if (menu_owner == nullptr) {
    menu_owner = main_window;
  }

  double x, y;

  // RECT rect;
  // Shell_NotifyIconGetRect(&niif, &rect);

  // x = rect.left + ((rect.right - rect.left) / 2);
  // y = rect.top + ((rect.bottom - rect.top) / 2);

  POINT cursorPos;
  GetCursorPos(&cursorPos);
  x = cursorPos.x;
  y = cursorPos.y;

  if (bringAppToFront) {
    SetForegroundWindow(main_window);
  } else {
    SetForegroundWindow(menu_owner);
  }
  TrackPopupMenu(hMenu, TPM_BOTTOMALIGN | TPM_LEFTALIGN, static_cast<int>(x),
                 static_cast<int>(y), 0, menu_owner, NULL);
  PostMessage(menu_owner, WM_NULL, 0, 0);
  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::GetBounds(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  if (!tray_icon_setted) {
    result->Success();
    return;
  }

  double devicePixelRatio =
      std::get<double>(args.at(flutter::EncodableValue("devicePixelRatio")));

  RECT rect;
  Shell_NotifyIconGetRect(&niif, &rect);
  flutter::EncodableMap resultMap = flutter::EncodableMap();

  double x = rect.left / devicePixelRatio * 1.0f;
  double y = rect.top / devicePixelRatio * 1.0f;
  double width = (rect.right - rect.left) / devicePixelRatio * 1.0f;
  double height = (rect.bottom - rect.top) / devicePixelRatio * 1.0f;

  resultMap[flutter::EncodableValue("x")] = flutter::EncodableValue(x);
  resultMap[flutter::EncodableValue("y")] = flutter::EncodableValue(y);
  resultMap[flutter::EncodableValue("width")] = flutter::EncodableValue(width);
  resultMap[flutter::EncodableValue("height")] =
      flutter::EncodableValue(height);

  result->Success(flutter::EncodableValue(resultMap));
}

void TrayManagerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("destroy") == 0) {
    Destroy(method_call, std::move(result));
  } else if (method_call.method_name().compare("setIcon") == 0) {
    SetIcon(method_call, std::move(result));
  } else if (method_call.method_name().compare("setToolTip") == 0) {
    SetToolTip(method_call, std::move(result));
  } else if (method_call.method_name().compare("setContextMenu") == 0) {
    SetContextMenu(method_call, std::move(result));
  } else if (method_call.method_name().compare("popUpContextMenu") == 0) {
    PopUpContextMenu(method_call, std::move(result));
  } else if (method_call.method_name().compare("getBounds") == 0) {
    GetBounds(method_call, std::move(result));
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void TrayManagerPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  TrayManagerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
