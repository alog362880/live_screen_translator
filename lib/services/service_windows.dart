import 'dart:convert';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../models/capture_frame.dart';
import '../models/text_block.dart';
import 'ai_vision_ocr_client.dart';
import 'ai_settings.dart';
import 'screen_translation_service.dart';

/// The method channel bridging to the native capture code in
/// windows/runner/screen_capture_channel.cpp (GDI BitBlt full-screen /
/// region grab — see that file for the native side).
const _captureChannel = MethodChannel('screen_translate/capture');

class WindowsScreenTranslationService extends ScreenTranslationService {
  WindowsScreenTranslationService({
    required AiSettings aiSettings,
    required this.targetLanguage,
  }) : _ai = AiVisionOcrClient(settings: aiSettings);

  final AiVisionOcrClient _ai;
  String targetLanguage;

  WindowController? _overlayWindow;

  static const PlatformCapabilities capabilities = PlatformCapabilities(
    supportsGlobalHotkey: true,
    supportsSystemTray: true,
    supportsFullScreenCapture: true,
    requiresUserGestureForCapture: false,
  );

  @override
  Future<void> initialize() async {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true); // closing hides to tray instead
    await windowManager.hide();

    await trayManager.setIcon('assets/tray_icon.ico');
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'capture', label: 'Capture & Translate'),
      MenuItem(key: 'settings', label: 'Settings'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]));

    await HotKeyManager.instance.unregisterAll();
    await HotKeyManager.instance.register(
      HotKey(
        key: PhysicalKeyboardKey.keyT,
        modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
        scope: HotKeyScope.system, // fires even while another app is focused
      ),
      keyDownHandler: (_) => captureOnce().then((frame) async {
        final blocks = await recognizeText(frame);
        await showOverlay(blocks, frame);
      }),
    );
  }

  @override
  Future<CaptureFrame> captureOnce() async {
    // Native side returns raw PNG bytes for the full virtual screen plus
    // the logical (DPI-scaled) desktop size, so we can map OCR boxes back
    // to window_manager's logical coordinate space.
    final result = await _captureChannel.invokeMethod<Map>('captureFullScreen');
    final bytes = result!['pngBytes'] as Uint8List;
    final display = await screenRetriever.getPrimaryDisplay();

    return CaptureFrame(
      pngBytes: bytes,
      pixelWidth: result['pixelWidth'] as int,
      pixelHeight: result['pixelHeight'] as int,
      logicalWidth: display.size.width,
      logicalHeight: display.size.height,
    );
  }

  /// Lets the user drag a bounding box instead of grabbing the whole
  /// screen; native side handles the drag UI and crops before returning.
  Future<CaptureFrame> captureRegion() async {
    final result = await _captureChannel.invokeMethod<Map>('captureRegion');
    final bytes = result!['pngBytes'] as Uint8List;
    return CaptureFrame(
      pngBytes: bytes,
      pixelWidth: result['pixelWidth'] as int,
      pixelHeight: result['pixelHeight'] as int,
      logicalWidth: (result['logicalWidth'] as num).toDouble(),
      logicalHeight: (result['logicalHeight'] as num).toDouble(),
      originX: (result['originX'] as num).toDouble(),
      originY: (result['originY'] as num).toDouble(),
    );
  }

  @override
  Future<List<TextBlock>> recognizeText(CaptureFrame frame) {
    // Windows has no bundled OCR engine wired up here — this combines OCR
    // + translation in one AI vision call. See ai_vision_ocr_client.dart.
    return _ai.extractAndTranslate(
      pngBytes: frame.pngBytes,
      targetLanguage: targetLanguage,
      pixelWidth: frame.pixelWidth,
      pixelHeight: frame.pixelHeight,
    );
  }

  @override
  Future<void> showOverlay(List<TextBlock> blocks, CaptureFrame frame) async {
    await hideOverlay();

    final window = await DesktopMultiWindow.createWindow(jsonEncode({
      'route': 'overlay',
      'blocks': blocks.map((b) => b.toJson()..['translated'] = b.translatedText).toList(),
      'scaleX': frame.scaleX,
      'scaleY': frame.scaleY,
    }));
    _overlayWindow = window;

    final screenSize = await _virtualScreenSize();
    await window.setFrame(Offset.zero & screenSize);
    await window.center();
    await window.setTitle('Translation Overlay');
    await window.show();

    // Overlay window itself is configured borderless/transparent/click-
    // through-except-on-text-chips inside main.dart's `overlay` route
    // (see lib/ui/translation_overlay_stack.dart) using window_manager's
    // setBackgroundColor(Colors.transparent) + setAsFrameless() called
    // from that secondary isolate's own WidgetsBinding.
  }

  Future<Size> _virtualScreenSize() async {
    final display = await screenRetriever.getPrimaryDisplay();
    return display.size;
  }

  @override
  Future<void> hideOverlay() async {
    if (_overlayWindow != null) {
      await _overlayWindow!.close();
      _overlayWindow = null;
    }
  }

  @override
  void updateTargetLanguage(String language) => targetLanguage = language;

  @override
  Future<void> dispose() async {
    await HotKeyManager.instance.unregisterAll();
    await trayManager.destroy();
    await hideOverlay();
  }
}

ScreenTranslationService createScreenTranslationService({
  required AiSettings aiSettings,
  required String targetLanguage,
}) =>
    WindowsScreenTranslationService(aiSettings: aiSettings, targetLanguage: targetLanguage);
