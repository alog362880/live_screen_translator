import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

import '../models/capture_frame.dart';
import '../models/text_block.dart';
import 'ai_vision_ocr_client.dart';
import 'ai_settings.dart';
import 'screen_translation_service.dart';

/// Web has no floating-overlay-over-other-apps concept (browsers are
/// sandboxed), so this implementation captures a tab/window/screen the
/// USER explicitly picks via the browser's native `getDisplayMedia`
/// picker, and renders the translation overlay as a Stack on top of the
/// captured frame shown inside the app itself.
class WebScreenTranslationService extends ScreenTranslationService {
  WebScreenTranslationService({
    required AiSettings aiSettings,
    required this.targetLanguage,
  }) : _ai = AiVisionOcrClient(settings: aiSettings);

  final AiVisionOcrClient _ai;
  String targetLanguage;

  web.MediaStream? _stream;

  static const PlatformCapabilities capabilities = PlatformCapabilities(
    supportsGlobalHotkey: false, // browsers can't register OS-wide hotkeys
    supportsSystemTray: false,
    supportsFullScreenCapture: false, // user always picks tab/window/screen
    requiresUserGestureForCapture: true, // getDisplayMedia requires a click
  );

  @override
  Future<void> initialize() async {
    // Nothing to pre-register on web — getDisplayMedia must be called
    // directly from a user-gesture handler (the floating trigger's
    // onTap), so the actual permission prompt happens in captureOnce().
  }

  @override
  Future<CaptureFrame> captureOnce() async {
    // navigator.mediaDevices.getDisplayMedia({video: true}) — JS interop
    // via package:web's typed bindings (the modern replacement for
    // hand-written `@JS()` externs / manual JS glue files).
    final constraints = web.DisplayMediaStreamOptions(video: true.toJS);
    final stream =
        await web.window.navigator.mediaDevices.getDisplayMedia(constraints).toDart;
    _stream = stream;

    final video = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = true
      ..srcObject = stream;

    // Wait for the first frame so videoWidth/Height are populated.
    // package:web exposes DOM events via addEventListener, not Dart
    // Streams, so bridge the one-shot 'loadedmetadata' event to a Future.
    final metadataLoaded = Completer<void>();
    video.addEventListener(
      'loadedmetadata',
      ((web.Event _) => metadataLoaded.complete()).toJS,
    );
    await metadataLoaded.future;
    await video.play().toDart;

    final width = video.videoWidth;
    final height = video.videoHeight;

    final canvas = web.HTMLCanvasElement()
      ..width = width
      ..height = height;
    final ctx = canvas.getContext('2d') as web.CanvasRenderingContext2D;
    ctx.drawImage(video, 0, 0);

    final blob = await _canvasToPngBlob(canvas);
    final buffer = await blob.arrayBuffer().toDart;
    final bytes = buffer.toDart.asUint8List();

    // Stop sharing immediately after grabbing one frame — this is a
    // single "translate what I see now" capture, not continuous mirroring.
    for (final track in stream.getTracks().toDart) {
      track.stop();
    }

    return CaptureFrame(
      pngBytes: bytes,
      pixelWidth: width,
      pixelHeight: height,
      logicalWidth: width.toDouble(),
      logicalHeight: height.toDouble(),
    );
  }

  Future<web.Blob> _canvasToPngBlob(web.HTMLCanvasElement canvas) {
    final completer = Completer<web.Blob>();
    canvas.toBlob((web.Blob? blob) {
      if (blob != null) completer.complete(blob);
    }.toJS, 'image/png');
    return completer.future;
  }

  @override
  Future<List<TextBlock>> recognizeText(CaptureFrame frame) {
    // No WASM/JS OCR engine bundled by default (Tesseract.js is a valid
    // drop-in — see NOTES in README). This starter reuses the same
    // AI-vision combined OCR+translate call as Windows for consistency.
    return _ai.extractAndTranslate(
      pngBytes: frame.pngBytes,
      targetLanguage: targetLanguage,
      pixelWidth: frame.pixelWidth,
      pixelHeight: frame.pixelHeight,
    );
  }

  @override
  Future<void> showOverlay(List<TextBlock> blocks, CaptureFrame frame) async {
    // Web has no OS-level overlay window — the UI layer
    // (translation_overlay_stack.dart) reads these blocks from
    // TranslationController and renders a Stack directly in-page. This
    // method is a no-op placeholder to satisfy the shared interface.
  }

  @override
  Future<void> hideOverlay() async {}

  @override
  void updateTargetLanguage(String language) => targetLanguage = language;

  @override
  Future<void> dispose() async {
    _stream?.getTracks().toDart.forEach((t) => t.stop());
  }
}

ScreenTranslationService createScreenTranslationService({
  required AiSettings aiSettings,
  required String targetLanguage,
}) =>
    WebScreenTranslationService(aiSettings: aiSettings, targetLanguage: targetLanguage);
