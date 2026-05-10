#include "include/tray_manager/tray_manager_plugin.h"

// This must be included before many other Windows headers.
#include <stdio.h>
#include <windows.h>
#include <windowsx.h>

#include <gdiplus.h>
#include <shellapi.h>
#include <strsafe.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <codecvt>
#include <map>
#include <memory>
#include <sstream>
#include <string>
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

void FillRoundedRectangle(Gdiplus::Graphics* graphics,
                          Gdiplus::Brush* brush,
                          Gdiplus::REAL x,
                          Gdiplus::REAL y,
                          Gdiplus::REAL width,
                          Gdiplus::REAL height,
                          Gdiplus::REAL radius) {
  Gdiplus::GraphicsPath path;
  const Gdiplus::REAL diameter = radius * 2.0f;
  path.AddArc(x, y, diameter, diameter, 180.0f, 90.0f);
  path.AddArc(x + width - diameter, y, diameter, diameter, 270.0f, 90.0f);
  path.AddArc(x + width - diameter, y + height - diameter, diameter, diameter,
              0.0f, 90.0f);
  path.AddArc(x, y + height - diameter, diameter, diameter, 90.0f, 90.0f);
  path.CloseFigure();
  graphics->FillPath(brush, &path);
}

std::unique_ptr<
    flutter::MethodChannel<flutter::EncodableValue>,
    std::default_delete<flutter::MethodChannel<flutter::EncodableValue>>>
    channel = nullptr;

struct OwnerDrawMenuItem {
  int id = 0;
  std::wstring label;
  std::wstring icon_path;
  bool disabled = false;
  bool checked = false;
  bool separator = false;
};

float GetWindowScaleFactor(HWND hwnd) {
  UINT dpi = 96;
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (user32 != nullptr) {
    using GetDpiForWindowProc = UINT(WINAPI*)(HWND);
    auto get_dpi_for_window = reinterpret_cast<GetDpiForWindowProc>(
        GetProcAddress(user32, "GetDpiForWindow"));
    if (get_dpi_for_window != nullptr && hwnd != nullptr) {
      dpi = get_dpi_for_window(hwnd);
    }
  }
  if (dpi == 0) {
    dpi = 96;
  }
  return static_cast<float>(dpi) / 96.0f;
}

int ScaleForWindow(HWND hwnd, int value) {
  return std::max(1, static_cast<int>(std::lround(value * GetWindowScaleFactor(hwnd))));
}

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
  ULONG_PTR gdiplus_token = 0;
  // do create pop-up menu only once.
  HMENU hMenu = CreatePopupMenu();
  HWND menu_owner_window = nullptr;
  HWND custom_menu_window = nullptr;
  std::vector<HBITMAP> menu_bitmaps;
  std::vector<std::unique_ptr<OwnerDrawMenuItem>> owner_draw_menu_items;
  int custom_menu_hover_index = -1;
  bool tray_icon_setted = false;
  UINT windows_taskbar_created_message_id = 0;

  // The ID of the WindowProc delegate registration.
  int window_proc_id = -1;

  void TrayManagerPlugin::_CreateMenu(HMENU menu, flutter::EncodableMap args);
  void TrayManagerPlugin::_ApplyIcon();
  void TrayManagerPlugin::_ClearMenuBitmaps();
  void TrayManagerPlugin::_ClearOwnerDrawMenuItems();
  std::wstring TrayManagerPlugin::_ResolveAssetPath(const std::string& asset);
  HBITMAP TrayManagerPlugin::_LoadMenuBitmap(const std::string& icon);
  bool TrayManagerPlugin::_MeasureOwnerDrawMenuItem(MEASUREITEMSTRUCT* measure);
  bool TrayManagerPlugin::_DrawOwnerDrawMenuItem(DRAWITEMSTRUCT* draw);
  HWND TrayManagerPlugin::_GetMenuOwnerWindow();
  HWND TrayManagerPlugin::_GetCustomMenuWindow();
  float TrayManagerPlugin::_GetMenuScale();
  int TrayManagerPlugin::_ScaleMenuValue(int value);
  SIZE TrayManagerPlugin::_MeasureCustomMenu();
  int TrayManagerPlugin::_HitTestCustomMenu(int y);
  void TrayManagerPlugin::_PaintCustomMenu(HWND hwnd);
  void TrayManagerPlugin::_ShowCustomMenu(int x, int y);
  void TrayManagerPlugin::_HideCustomMenu();
  void TrayManagerPlugin::_InvokeCustomMenuItem(int index);
  static LRESULT CALLBACK TrayManagerPlugin::_MenuOwnerWndProc(
      HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  static LRESULT CALLBACK TrayManagerPlugin::_CustomMenuWndProc(
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
  Gdiplus::GdiplusStartupInput startup_input;
  Gdiplus::GdiplusStartup(&gdiplus_token, &startup_input, nullptr);
  window_proc_id = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
  windows_taskbar_created_message_id = RegisterWindowMessage(L"TaskbarCreated");
}

TrayManagerPlugin::~TrayManagerPlugin() {
  if (custom_menu_window != nullptr) {
    DestroyWindow(custom_menu_window);
    custom_menu_window = nullptr;
  }
  if (menu_owner_window != nullptr) {
    DestroyWindow(menu_owner_window);
    menu_owner_window = nullptr;
  }
  _ClearMenuBitmaps();
  _ClearOwnerDrawMenuItems();
  if (gdiplus_token != 0) {
    Gdiplus::GdiplusShutdown(gdiplus_token);
    gdiplus_token = 0;
  }
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
  if (plugin != nullptr && message == WM_MEASUREITEM) {
    if (plugin->_MeasureOwnerDrawMenuItem(
            reinterpret_cast<MEASUREITEMSTRUCT*>(lparam))) {
      return TRUE;
    }
  }
  if (plugin != nullptr && message == WM_DRAWITEM) {
    if (plugin->_DrawOwnerDrawMenuItem(
            reinterpret_cast<DRAWITEMSTRUCT*>(lparam))) {
      return TRUE;
    }
  }
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

HWND TrayManagerPlugin::_GetCustomMenuWindow() {
  if (custom_menu_window != nullptr) {
    return custom_menu_window;
  }

  constexpr const wchar_t kCustomMenuWindowClassName[] =
      L"TRAY_MANAGER_CUSTOM_MENU_WINDOW";
  static bool class_registered = false;
  if (!class_registered) {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = TrayManagerPlugin::_CustomMenuWndProc;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kCustomMenuWindowClassName;
    RegisterClassW(&window_class);
    class_registered = true;
  }

  custom_menu_window = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED,
      kCustomMenuWindowClassName, L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
      GetModuleHandle(nullptr), this);
  SetLayeredWindowAttributes(custom_menu_window, 0, 245, LWA_ALPHA);
  return custom_menu_window;
}

float TrayManagerPlugin::_GetMenuScale() {
  HWND reference_window = custom_menu_window != nullptr ? custom_menu_window
                                                        : GetMainWindow();
  return GetWindowScaleFactor(reference_window);
}

int TrayManagerPlugin::_ScaleMenuValue(int value) {
  HWND reference_window = custom_menu_window != nullptr ? custom_menu_window
                                                        : GetMainWindow();
  return ScaleForWindow(reference_window, value);
}

LRESULT CALLBACK TrayManagerPlugin::_CustomMenuWndProc(HWND hwnd, UINT message,
                                                       WPARAM wparam,
                                                       LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto create_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create_struct->lpCreateParams));
  }

  auto plugin = reinterpret_cast<TrayManagerPlugin*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));

  switch (message) {
    case WM_PAINT:
      if (plugin != nullptr) {
        plugin->_PaintCustomMenu(hwnd);
        return 0;
      }
      break;
    case WM_ERASEBKGND:
      return 1;
    case WM_MOUSEMOVE:
      if (plugin != nullptr) {
        int hover_index =
            plugin->_HitTestCustomMenu(GET_Y_LPARAM(lparam));
        if (hover_index != plugin->custom_menu_hover_index) {
          plugin->custom_menu_hover_index = hover_index;
          InvalidateRect(hwnd, nullptr, FALSE);
        }
        TRACKMOUSEEVENT event{};
        event.cbSize = sizeof(TRACKMOUSEEVENT);
        event.dwFlags = TME_LEAVE;
        event.hwndTrack = hwnd;
        TrackMouseEvent(&event);
        return 0;
      }
      break;
    case WM_MOUSELEAVE:
      if (plugin != nullptr) {
        plugin->custom_menu_hover_index = -1;
        InvalidateRect(hwnd, nullptr, FALSE);
        return 0;
      }
      break;
    case WM_LBUTTONUP:
      if (plugin != nullptr) {
        plugin->_InvokeCustomMenuItem(
            plugin->_HitTestCustomMenu(GET_Y_LPARAM(lparam)));
        return 0;
      }
      break;
    case WM_ACTIVATE:
      if (plugin != nullptr && LOWORD(wparam) == WA_INACTIVE) {
        plugin->_HideCustomMenu();
        return 0;
      }
      break;
    case WM_KILLFOCUS:
      if (plugin != nullptr) {
        plugin->_HideCustomMenu();
        return 0;
      }
      break;
    case WM_KEYDOWN:
      if (plugin != nullptr && wparam == VK_ESCAPE) {
        plugin->_HideCustomMenu();
        return 0;
      }
      break;
  }

  return DefWindowProc(hwnd, message, wparam, lparam);
}

void TrayManagerPlugin::_ClearMenuBitmaps() {
  for (HBITMAP bitmap : menu_bitmaps) {
    DeleteObject(bitmap);
  }
  menu_bitmaps.clear();
}

void TrayManagerPlugin::_ClearOwnerDrawMenuItems() {
  owner_draw_menu_items.clear();
}

std::wstring TrayManagerPlugin::_ResolveAssetPath(const std::string& asset) {
  wchar_t module_path[MAX_PATH];
  DWORD path_length = GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  if (path_length == 0 || path_length >= MAX_PATH) {
    return L"";
  }

  std::wstring asset_path(module_path, path_length);
  size_t slash_index = asset_path.find_last_of(L"\\/");
  if (slash_index != std::wstring::npos) {
    asset_path = asset_path.substr(0, slash_index);
  }
  asset_path += L"\\data\\flutter_assets\\";
  asset_path += g_converter.from_bytes(asset);
  return asset_path;
}

HBITMAP TrayManagerPlugin::_LoadMenuBitmap(const std::string& icon) {
  if (icon.empty()) {
    return nullptr;
  }

  std::wstring icon_path = _ResolveAssetPath(icon);
  if (icon_path.empty()) {
    return nullptr;
  }

  int bitmap_size = GetSystemMetrics(SM_CYMENU);
  if (bitmap_size < 24) {
    bitmap_size = 24;
  } else if (bitmap_size > 36) {
    bitmap_size = 36;
  }

  if (gdiplus_token != 0) {
    Gdiplus::Bitmap source(icon_path.c_str());
    if (source.GetLastStatus() == Gdiplus::Ok) {
      Gdiplus::Bitmap resized(bitmap_size, bitmap_size,
                              PixelFormat32bppPARGB);
      Gdiplus::Graphics graphics(&resized);
      graphics.SetCompositingMode(Gdiplus::CompositingModeSourceCopy);
      graphics.SetCompositingQuality(Gdiplus::CompositingQualityHighQuality);
      graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
      graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
      graphics.SetSmoothingMode(Gdiplus::SmoothingModeHighQuality);
      graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
      const int draw_size = static_cast<int>(bitmap_size * 1.16);
      const int draw_offset_x = bitmap_size - draw_size;
      const int draw_offset_y = (bitmap_size - draw_size) / 2;
      graphics.DrawImage(
          &source,
          Gdiplus::Rect(draw_offset_x, draw_offset_y, draw_size, draw_size));

      HBITMAP bitmap = nullptr;
      if (resized.GetHBITMAP(Gdiplus::Color(0, 0, 0, 0), &bitmap) ==
              Gdiplus::Ok &&
          bitmap != nullptr) {
        menu_bitmaps.push_back(bitmap);
        return bitmap;
      }
    }
  }

  HBITMAP bitmap = static_cast<HBITMAP>(
      LoadImageW(nullptr, icon_path.c_str(), IMAGE_BITMAP, bitmap_size,
                 bitmap_size, LR_LOADFROMFILE | LR_CREATEDIBSECTION));
  if (bitmap != nullptr) {
    menu_bitmaps.push_back(bitmap);
  }
  return bitmap;
}

bool TrayManagerPlugin::_MeasureOwnerDrawMenuItem(
    MEASUREITEMSTRUCT* measure) {
  if (measure == nullptr || measure->CtlType != ODT_MENU) {
    return false;
  }

  auto* item = reinterpret_cast<OwnerDrawMenuItem*>(measure->itemData);
  if (item == nullptr) {
    return false;
  }

  if (item->separator) {
    measure->itemWidth = 1;
    measure->itemHeight = _ScaleMenuValue(9);
    return true;
  }

  HDC hdc = GetDC(nullptr);
  HFONT font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
  HFONT old_font = static_cast<HFONT>(SelectObject(hdc, font));
  SIZE text_size = {0, 0};
  GetTextExtentPoint32W(hdc, item->label.c_str(),
                        static_cast<int>(item->label.length()), &text_size);
  SelectObject(hdc, old_font);
  ReleaseDC(nullptr, hdc);

  const UINT icon_left = _ScaleMenuValue(10);
  const UINT icon_size = _ScaleMenuValue(20);
  const UINT text_gap = _ScaleMenuValue(7);
  const UINT text_right_padding = _ScaleMenuValue(18);
  measure->itemWidth =
      icon_left + icon_size + text_gap + text_size.cx + text_right_padding;
  measure->itemHeight = _ScaleMenuValue(30);
  return true;
}

bool TrayManagerPlugin::_DrawOwnerDrawMenuItem(DRAWITEMSTRUCT* draw) {
  if (draw == nullptr || draw->CtlType != ODT_MENU) {
    return false;
  }

  auto* item = reinterpret_cast<OwnerDrawMenuItem*>(draw->itemData);
  if (item == nullptr) {
    return false;
  }

  HDC hdc = draw->hDC;
  RECT rect = draw->rcItem;

  HBRUSH menu_brush = CreateSolidBrush(GetSysColor(COLOR_MENU));
  FillRect(hdc, &rect, menu_brush);
  DeleteObject(menu_brush);

  if (item->separator) {
    RECT line_rect = rect;
    line_rect.left += _ScaleMenuValue(10);
    line_rect.right -= _ScaleMenuValue(8);
    line_rect.top += (rect.bottom - rect.top) / 2;
    line_rect.bottom = line_rect.top + std::max(1, _ScaleMenuValue(1));
    HBRUSH line_brush = CreateSolidBrush(RGB(225, 225, 225));
    FillRect(hdc, &line_rect, line_brush);
    DeleteObject(line_brush);
    return true;
  }

  const bool selected = (draw->itemState & ODS_SELECTED) != 0;
  if (selected && !item->disabled) {
    RECT selected_rect = rect;
    selected_rect.left += _ScaleMenuValue(3);
    selected_rect.right -= _ScaleMenuValue(3);
    HBRUSH selected_brush = CreateSolidBrush(RGB(238, 238, 238));
    FillRect(hdc, &selected_rect, selected_brush);
    DeleteObject(selected_brush);
  }

  const int item_height = rect.bottom - rect.top;
  const int icon_size = _ScaleMenuValue(20);
  const int icon_left = rect.left + _ScaleMenuValue(10);
  const int icon_top = rect.top + (item_height - icon_size) / 2;

  if (!item->icon_path.empty() && gdiplus_token != 0) {
    Gdiplus::Bitmap icon(item->icon_path.c_str());
    if (icon.GetLastStatus() == Gdiplus::Ok) {
      Gdiplus::Graphics graphics(hdc);
      graphics.SetCompositingQuality(Gdiplus::CompositingQualityHighQuality);
      graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
      graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
      graphics.SetSmoothingMode(Gdiplus::SmoothingModeHighQuality);
      graphics.DrawImage(&icon, Gdiplus::Rect(icon_left, icon_top, icon_size,
                                              icon_size));
    }
  }

  RECT text_rect = rect;
  text_rect.left = rect.left + _ScaleMenuValue(37);
  text_rect.right -= _ScaleMenuValue(14);
  text_rect.top += _ScaleMenuValue(1);

  HFONT font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
  HFONT old_font = static_cast<HFONT>(SelectObject(hdc, font));
  int old_bk_mode = SetBkMode(hdc, TRANSPARENT);
  COLORREF old_text_color = SetTextColor(
      hdc, item->disabled ? GetSysColor(COLOR_GRAYTEXT)
                          : GetSysColor(COLOR_MENUTEXT));
  DrawTextW(hdc, item->label.c_str(), -1, &text_rect,
            DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_NOPREFIX);
  SetTextColor(hdc, old_text_color);
  SetBkMode(hdc, old_bk_mode);
  SelectObject(hdc, old_font);

  return true;
}

SIZE TrayManagerPlugin::_MeasureCustomMenu() {
  const int icon_left = _ScaleMenuValue(12);
  const int icon_size = _ScaleMenuValue(28);
  const int text_gap = _ScaleMenuValue(4);
  const int right_padding = _ScaleMenuValue(20);
  const int min_width = _ScaleMenuValue(150);
  SIZE size = {min_width, _ScaleMenuValue(12)};

  HDC hdc = GetDC(nullptr);
  HFONT font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
  HFONT old_font = static_cast<HFONT>(SelectObject(hdc, font));
  for (const auto& item : owner_draw_menu_items) {
    if (item->separator) {
      size.cy += _ScaleMenuValue(9);
      continue;
    }

    SIZE text_size = {0, 0};
    GetTextExtentPoint32W(hdc, item->label.c_str(),
                          static_cast<int>(item->label.length()), &text_size);
    size.cx = std::max(size.cx,
                       icon_left + icon_size + text_gap + text_size.cx +
                           right_padding);
    size.cy += _ScaleMenuValue(34);
  }
  SelectObject(hdc, old_font);
  ReleaseDC(nullptr, hdc);
  size.cx += 2;
  return size;
}

int TrayManagerPlugin::_HitTestCustomMenu(int y) {
  int top = _ScaleMenuValue(6);
  for (size_t index = 0; index < owner_draw_menu_items.size(); index++) {
    const auto& item = owner_draw_menu_items[index];
    int height = item->separator ? _ScaleMenuValue(9) : _ScaleMenuValue(34);
    if (y >= top && y < top + height) {
      if (item->separator || item->disabled) {
        return -1;
      }
      return static_cast<int>(index);
    }
    top += height;
  }
  return -1;
}

void TrayManagerPlugin::_PaintCustomMenu(HWND hwnd) {
  PAINTSTRUCT paint;
  HDC hdc = BeginPaint(hwnd, &paint);

  RECT client_rect;
  GetClientRect(hwnd, &client_rect);
  const int width = client_rect.right - client_rect.left;
  const int height = client_rect.bottom - client_rect.top;

  HDC buffer_hdc = CreateCompatibleDC(hdc);
  HBITMAP buffer_bitmap = CreateCompatibleBitmap(hdc, width, height);
  HBITMAP old_buffer_bitmap =
      static_cast<HBITMAP>(SelectObject(buffer_hdc, buffer_bitmap));

  Gdiplus::Graphics graphics(buffer_hdc);
  graphics.SetSmoothingMode(Gdiplus::SmoothingModeHighQuality);
  graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
  graphics.Clear(Gdiplus::Color(248, 250, 252));

  Gdiplus::SolidBrush background(Gdiplus::Color(248, 250, 252));
  const float scale = _GetMenuScale();
  FillRoundedRectangle(&graphics, &background, 0.0f, 0.0f,
                       static_cast<Gdiplus::REAL>(width),
                       static_cast<Gdiplus::REAL>(height), 10.0f * scale);

  int top = _ScaleMenuValue(6);
  const int icon_left = _ScaleMenuValue(12);
  const int icon_size = _ScaleMenuValue(28);
  const int text_left = icon_left + icon_size + _ScaleMenuValue(4);

  for (size_t index = 0; index < owner_draw_menu_items.size(); index++) {
    const auto& item = owner_draw_menu_items[index];
    if (item->separator) {
      Gdiplus::SolidBrush line_brush(Gdiplus::Color(226, 232, 240));
      graphics.FillRectangle(&line_brush, _ScaleMenuValue(10),
                             top + _ScaleMenuValue(4), width - _ScaleMenuValue(20),
                             std::max(1, _ScaleMenuValue(1)));
      top += _ScaleMenuValue(9);
      continue;
    }

    const int item_height = _ScaleMenuValue(34);
    const bool selected = static_cast<int>(index) == custom_menu_hover_index;
    if (selected) {
      Gdiplus::SolidBrush selected_brush(Gdiplus::Color(235, 239, 244));
      FillRoundedRectangle(&graphics, &selected_brush,
                           static_cast<Gdiplus::REAL>(_ScaleMenuValue(5)),
                           static_cast<float>(top),
                           static_cast<float>(width - _ScaleMenuValue(10)),
                           static_cast<Gdiplus::REAL>(_ScaleMenuValue(30)),
                           7.0f * scale);
    }

    if (!item->icon_path.empty() && gdiplus_token != 0) {
      Gdiplus::Bitmap icon(item->icon_path.c_str());
      if (icon.GetLastStatus() == Gdiplus::Ok) {
        graphics.SetCompositingQuality(Gdiplus::CompositingQualityHighQuality);
        graphics.SetInterpolationMode(
            Gdiplus::InterpolationModeHighQualityBicubic);
        graphics.DrawImage(&icon,
                           Gdiplus::Rect(icon_left,
                                         top + (item_height - icon_size) / 2,
                                         icon_size, icon_size));
      }
    }

    RECT text_rect = {text_left, top, width - _ScaleMenuValue(16),
                      top + item_height};
    HFONT font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
    HFONT old_font = static_cast<HFONT>(SelectObject(buffer_hdc, font));
    int old_bk_mode = SetBkMode(buffer_hdc, TRANSPARENT);
    COLORREF old_text_color = SetTextColor(
        buffer_hdc,
        item->disabled ? GetSysColor(COLOR_GRAYTEXT) : RGB(31, 41, 55));
    DrawTextW(buffer_hdc, item->label.c_str(), -1, &text_rect,
              DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_NOPREFIX);
    SetTextColor(buffer_hdc, old_text_color);
    SetBkMode(buffer_hdc, old_bk_mode);
    SelectObject(buffer_hdc, old_font);

    top += item_height;
  }

  BitBlt(hdc, 0, 0, width, height, buffer_hdc, 0, 0, SRCCOPY);
  SelectObject(buffer_hdc, old_buffer_bitmap);
  DeleteObject(buffer_bitmap);
  DeleteDC(buffer_hdc);

  EndPaint(hwnd, &paint);
}

void TrayManagerPlugin::_ShowCustomMenu(int x, int y) {
  HWND hwnd = _GetCustomMenuWindow();
  if (hwnd == nullptr) {
    return;
  }

  SIZE size = _MeasureCustomMenu();
  HMONITOR monitor = MonitorFromPoint({x, y}, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  GetMonitorInfoW(monitor, &monitor_info);

  int left = x;
  int top = y - size.cy;
  if (left + size.cx > monitor_info.rcWork.right) {
    left = monitor_info.rcWork.right - size.cx;
  }
  if (top < monitor_info.rcWork.top) {
    top = y;
  }
  left = std::max(left, static_cast<int>(monitor_info.rcWork.left));
  top = std::max(top, static_cast<int>(monitor_info.rcWork.top));

  const int corner_radius = _ScaleMenuValue(12);
  HRGN region = CreateRoundRectRgn(0, 0, size.cx + 1, size.cy + 1,
                                   corner_radius, corner_radius);
  SetWindowRgn(hwnd, region, TRUE);
  custom_menu_hover_index = -1;
  SetWindowPos(hwnd, HWND_TOPMOST, left, top, size.cx, size.cy,
               SWP_SHOWWINDOW);
  SetForegroundWindow(hwnd);
  SetFocus(hwnd);
  InvalidateRect(hwnd, nullptr, TRUE);
}

void TrayManagerPlugin::_HideCustomMenu() {
  if (custom_menu_window != nullptr && IsWindowVisible(custom_menu_window)) {
    ShowWindow(custom_menu_window, SW_HIDE);
  }
  custom_menu_hover_index = -1;
}

void TrayManagerPlugin::_InvokeCustomMenuItem(int index) {
  if (index < 0 ||
      index >= static_cast<int>(owner_draw_menu_items.size()) ||
      owner_draw_menu_items[index]->separator ||
      owner_draw_menu_items[index]->disabled) {
    return;
  }

  int id = owner_draw_menu_items[index]->id;
  _HideCustomMenu();
  flutter::EncodableMap eventData = flutter::EncodableMap();
  eventData[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
  channel->InvokeMethod("onTrayMenuItemClick",
                        std::make_unique<flutter::EncodableValue>(eventData));
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
    UINT uFlags = MF_OWNERDRAW;

    if (disabled) {
      uFlags |= MF_GRAYED;
    }

    auto owner_draw_item = std::make_unique<OwnerDrawMenuItem>();
    owner_draw_item->id = id;
    owner_draw_item->label = g_converter.from_bytes(label);
    owner_draw_item->disabled = disabled;
    owner_draw_item->checked = checked != nullptr && *checked == true;
    if (icon != nullptr) {
      owner_draw_item->icon_path = _ResolveAssetPath(*icon);
    }
    OwnerDrawMenuItem* owner_draw_item_ptr = owner_draw_item.get();
    owner_draw_menu_items.push_back(std::move(owner_draw_item));

    if (type.compare("separator") == 0) {
      owner_draw_item_ptr->separator = true;
      AppendMenuW(menu, MF_SEPARATOR | MF_OWNERDRAW, item_id,
                  reinterpret_cast<LPCWSTR>(owner_draw_item_ptr));
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
      AppendMenuW(menu, uFlags, item_id,
                  reinterpret_cast<LPCWSTR>(owner_draw_item_ptr));
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
  } else if (message == WM_MEASUREITEM) {
    if (_MeasureOwnerDrawMenuItem(
            reinterpret_cast<MEASUREITEMSTRUCT*>(lParam))) {
      return TRUE;
    }
  } else if (message == WM_DRAWITEM) {
    if (_DrawOwnerDrawMenuItem(reinterpret_cast<DRAWITEMSTRUCT*>(lParam))) {
      return TRUE;
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
  _ClearOwnerDrawMenuItems();
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
  _ShowCustomMenu(static_cast<int>(x), static_cast<int>(y));
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
