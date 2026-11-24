#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  video_host_ = std::make_unique<VideoHost>(
      GetHandle(), flutter_controller_->view()->GetNativeWindow(),
      flutter_controller_->engine()->messenger());
  native_window_ = std::make_unique<NativeWindow>(
      GetHandle(), flutter_controller_->engine()->messenger());
  native_window_->SetFullScreenHandler(
      [this](bool fullscreen) { return SetFullScreen(fullscreen); });
  trailer_textures_ = std::make_unique<TrailerTextures>(
      flutter_controller_->engine()->messenger(),
      FlutterDesktopRegistrarGetTextureRegistrar(
          flutter_controller_->engine()->GetRegistrarForPlugin("ZerkTrailerTextures")));

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  video_host_ = nullptr;
  native_window_ = nullptr;
  trailer_textures_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Answer before the plugin delegates: window_manager's hidden-title-bar hook
  // always keeps 8 px of non-client area on the right, bottom and left so the
  // window stays draggable from its edges. That border is what left the last
  // full-screen attempt with a strip of desktop along the bottom, and the
  // plugin only drops it for the full screen *it* set. Ours is SetFullScreen
  // below, so the client area is pinned to the window rect here instead.
  if (fullscreen_ && message == WM_NCCALCSIZE && wparam) {
    return 0;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_SIZE:
      if (video_host_) video_host_->OnParentResized();
      break;
    case WM_ACTIVATE:
      if (video_host_ && video_host_->visible()) {
        video_host_->Focus();
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

bool FlutterWindow::SetFullScreen(bool fullscreen) {
  if (fullscreen == fullscreen_) return true;

  HWND hwnd = GetHandle();
  if (!hwnd) return false;

  if (fullscreen) {
    saved_placement_ = WINDOWPLACEMENT{};
    saved_placement_.length = sizeof(WINDOWPLACEMENT);
    if (!GetWindowPlacement(hwnd, &saved_placement_)) return false;
    saved_style_ = static_cast<LONG>(GetWindowLongPtr(hwnd, GWL_STYLE));

    MONITORINFO monitor = {};
    monitor.cbSize = sizeof(MONITORINFO);
    if (!GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                        &monitor)) {
      return false;
    }

    // A maximized window ignores SetWindowPos, so drop it first. The placement
    // captured above still says SW_SHOWMAXIMIZED, so the way out puts it back.
    if (saved_placement_.showCmd == SW_SHOWMAXIMIZED) {
      ShowWindow(hwnd, SW_RESTORE);
    }

    // Flagged before the resize: SetWindowPos runs WM_NCCALCSIZE, and that has
    // to already know it is covering the monitor.
    fullscreen_ = true;
    SetWindowLongPtr(hwnd, GWL_STYLE,
                     saved_style_ & ~(WS_THICKFRAME | WS_MAXIMIZEBOX));
    SetWindowPos(hwnd, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
                 monitor.rcMonitor.right - monitor.rcMonitor.left,
                 monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  } else {
    fullscreen_ = false;
    SetWindowLongPtr(hwnd, GWL_STYLE, saved_style_);
    SetWindowPlacement(hwnd, &saved_placement_);
    // FRAMECHANGED re-runs WM_NCCALCSIZE, so the hidden title bar gets its
    // resize border back together with the windowed rect, and HWND_TOP plus the
    // activation below stop the window from reappearing under the desktop.
    SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE);
  }

  ::BringWindowToTop(hwnd);
  SetForegroundWindow(hwnd);
  return true;
}
