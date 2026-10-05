import 'package:flutter/foundation.dart';

import '../models/capture_frame.dart';
import '../models/text_block.dart';
import '../services/screen_translation_service.dart';

enum CaptureStatus { idle, capturing, recognizing, translating, showing, error }

/// Single source of truth for the capture -> OCR -> translate -> overlay
/// pipeline. UI widgets (floating trigger, overlay stack, settings)
/// listen to this instead of talking to ScreenTranslationService directly.
class TranslationController extends ChangeNotifier {
  TranslationController({required ScreenTranslationService service}) : _service = service;

  final ScreenTranslationService _service;

  CaptureStatus status = CaptureStatus.idle;
  String targetLanguage = 'English';
  List<TextBlock> lastBlocks = [];
  CaptureFrame? lastFrame;
  String? errorMessage;

  Future<void> initialize() {
    // Wired here (not main.dart) so no call site needs a platform-specific
    // type check — see ScreenTranslationService.onExternalCaptureRequest.
    _service.onExternalCaptureRequest = runCaptureAndTranslate;
    return _service.initialize();
  }

  /// Platform-specific pre-capture gesture (currently: showing iOS's
  /// ReplayKit broadcast picker). No-op on Windows/Web. Must be called
  /// from a direct user-tap handler — see
  /// ScreenTranslationService.prepareCaptureSession for why.
  Future<void> prepareCaptureSession() => _service.prepareCaptureSession();

  /// Drives the whole pipeline for one "tap the floating button" event.
  Future<void> runCaptureAndTranslate() async {
    try {
      status = CaptureStatus.capturing;
      errorMessage = null;
      notifyListeners();

      final frame = await _service.captureOnce();
      lastFrame = frame;

      status = CaptureStatus.recognizing;
      notifyListeners();

      final blocks = await _service.recognizeText(frame);
      lastBlocks = blocks;

      status = CaptureStatus.showing;
      notifyListeners();

      await _service.showOverlay(blocks, frame);
    } catch (e) {
      status = CaptureStatus.error;
      errorMessage = e.toString();
    } finally {
      if (status != CaptureStatus.error) status = CaptureStatus.idle;
      notifyListeners();
    }
  }

  Future<void> dismissOverlay() async {
    await _service.hideOverlay();
    lastBlocks = [];
    lastFrame = null;
    notifyListeners();
  }

  void setTargetLanguage(String language) {
    targetLanguage = language;
    _service.updateTargetLanguage(language);
    notifyListeners();
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }
}
