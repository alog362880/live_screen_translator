import 'package:flutter/foundation.dart';

import '../models/capture_frame.dart';
import '../models/text_block.dart';

/// Unified surface the UI/state layer talks to, regardless of platform.
/// Each platform implements capture + OCR its own way (native screen
/// projection, browser Screen Capture API, ReplayKit, …) but returns the
/// same [CaptureFrame] / [TextBlock] shapes so the rest of the app never
/// branches on platform.
abstract class ScreenTranslationService {
  /// One-time setup: request permissions, register hotkeys/tray icons,
  /// spin up the overlay window, etc. Must be called before [captureOnce].
  Future<void> initialize();

  /// Fired when the platform layer has a capture ready to process outside
  /// the normal "tap the floating button" flow — currently only iOS's
  /// Share Extension deep-link (screentranslate://capture, see
  /// IosScreenTranslationService and ios/Runner/AppDelegate.swift). Other
  /// platforms never call this; TranslationController wires it to
  /// [runCaptureAndTranslate]-equivalent behavior once, in its own
  /// initialize(), so neither main.dart nor the UI layer needs a
  /// platform-specific type check to set it up.
  VoidCallback? onExternalCaptureRequest;

  /// Platform-specific gesture required before [captureOnce] can succeed,
  /// distinct from [initialize] because it must run from a *user-tap*
  /// context — most platforms need nothing here (default no-op), but iOS
  /// must show the ReplayKit broadcast picker (a system UI the user has
  /// to tap themselves) before SampleHandler.swift starts writing frames
  /// to the shared App Group container. Safe to call repeatedly; a no-op
  /// where it isn't needed.
  Future<void> prepareCaptureSession() async {}

  /// Captures the current screen (or the platform's equivalent — a
  /// dragged region on Windows, the shared browser tab on Web, the last
  /// ReplayKit frame on iOS) and returns it undecoded-but-ready for OCR.
  Future<CaptureFrame> captureOnce();

  /// Runs on-device OCR over [frame] and returns text blocks with
  /// coordinates in the frame's pixel space.
  Future<List<TextBlock>> recognizeText(CaptureFrame frame);

  /// Shows [blocks] as an overlay positioned over the original screen
  /// content. Implementations decide *how* (separate transparent window
  /// on Windows, a Stack over the captured image on Web, a Live
  /// Activity / in-app modal on iOS).
  Future<void> showOverlay(List<TextBlock> blocks, CaptureFrame frame);

  Future<void> hideOverlay();

  /// Changes the language used by subsequent [recognizeText] calls.
  /// Already-shown overlays are not retranslated retroactively.
  void updateTargetLanguage(String language);

  Future<void> dispose();
}

/// Platform capability flags the UI uses to decide what controls to show
/// (e.g. hide the hotkey settings row on iOS).
class PlatformCapabilities {
  final bool supportsGlobalHotkey;
  final bool supportsSystemTray;
  final bool supportsFullScreenCapture;
  final bool requiresUserGestureForCapture;

  const PlatformCapabilities({
    required this.supportsGlobalHotkey,
    required this.supportsSystemTray,
    required this.supportsFullScreenCapture,
    required this.requiresUserGestureForCapture,
  });
}
