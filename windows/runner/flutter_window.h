#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "native_window.h"
#include "trailer_texture.h"
#include "video_host.h"
#include "win32_window.h"

class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  /// Covers the monitor with the client area, or hands the saved geometry back.
  ///
  /// This used to be window_manager's setFullScreen, which cannot do the job
  /// here: the window has a hidden title bar rather than being frameless, so
  /// the plugin's entry path calls SetAsFrameless() first, and from then on its
  /// WM_NCCALCSIZE hook shrinks the client area by the monitor work-area
  /// offset (a strip of desktop along the bottom on a taskbar-shrunk screen).
  /// Its exit path is worse: it restores the pre-full-screen frame without
  /// activating the window, resets is_frameless_, and re-extends the DWM frame,
  /// which left the app behind the desktop and ignoring the mouse. Owning the
  /// geometry here keeps the client area equal to the monitor rect exactly.
  bool SetFullScreen(bool fullscreen);

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  flutter::DartProject project_;

  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<VideoHost> video_host_;

  std::unique_ptr<NativeWindow> native_window_;

  std::unique_ptr<TrailerTextures> trailer_textures_;

  /// True while the window covers a whole monitor. WM_NCCALCSIZE reads it to
  /// skip the 8 px resize border a hidden title bar asks for.
  bool fullscreen_ = false;

  /// Windowed state captured on the way into full screen.
  LONG saved_style_ = 0;
  WINDOWPLACEMENT saved_placement_ = {};
};

#endif
