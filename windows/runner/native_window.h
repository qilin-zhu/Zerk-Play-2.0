#ifndef RUNNER_NATIVE_WINDOW_H_
#define RUNNER_NATIVE_WINDOW_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <functional>
#include <memory>
#include <utility>

class NativeWindow {
 public:
  NativeWindow(HWND window, flutter::BinaryMessenger* messenger);

  ~NativeWindow();

  /// Full screen lives in FlutterWindow (it needs the window procedure to drop
  /// the resize border), so the channel forwards there.
  void SetFullScreenHandler(std::function<bool(bool)> handler) {
    fullscreen_handler_ = std::move(handler);
  }

 private:
  struct HdrStatus {
    bool supported = false;
    bool enabled = false;
  };
  HdrStatus GetHdrStatus() const;
  bool SetHdr(bool enabled);

  HWND window_;
  bool hdr_enabled_by_app_ = false;
  std::function<bool(bool)> fullscreen_handler_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
