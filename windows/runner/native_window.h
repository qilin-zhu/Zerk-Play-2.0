#ifndef RUNNER_NATIVE_WINDOW_H_
#define RUNNER_NATIVE_WINDOW_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

class NativeWindow {
 public:
  NativeWindow(HWND window, flutter::BinaryMessenger* messenger);

  ~NativeWindow();

 private:
  struct HdrStatus {
    bool supported = false;
    bool enabled = false;
  };
  HdrStatus GetHdrStatus() const;
  bool SetHdr(bool enabled);

  // Full screen is not implemented here: window_manager owns it on the Dart
  // side (see NativeWindow.setFullScreen), because the frameless hidden title
  // bar it installs needs its own full-screen flag to drop the 8 px resize
  // border. This class only carries the HDR switch.
  HWND window_;
  bool hdr_enabled_by_app_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
