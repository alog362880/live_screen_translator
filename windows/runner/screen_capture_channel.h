#ifndef RUNNER_SCREEN_CAPTURE_CHANNEL_H_
#define RUNNER_SCREEN_CAPTURE_CHANNEL_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/plugin_registrar_windows.h>

// Registers the "screen_translate/capture" method channel used by
// lib/services/service_windows.dart. Call this once from
// flutter_window.cpp after the FlutterViewController is created, e.g.:
//
//   ScreenCaptureChannel::RegisterWithRegistrar(
//       flutter_controller_->engine()->GetRegistrarForPlugin("ScreenCaptureChannel"));
class ScreenCaptureChannel {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  ScreenCaptureChannel();
  ~ScreenCaptureChannel();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Grabs the full virtual screen via BitBlt and encodes it as PNG.
  flutter::EncodableMap CaptureFullScreen();

  // Shows a full-screen click-drag overlay window so the user can select
  // a rectangular region, then crops the full-screen capture to it.
  // Returns an empty map if the user cancels (Esc).
  flutter::EncodableMap CaptureRegion();
};

#endif  // RUNNER_SCREEN_CAPTURE_CHANNEL_H_
