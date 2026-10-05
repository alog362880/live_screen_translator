import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/capture_frame.dart';
import '../models/text_block.dart';
import 'ai_translation_client.dart';
import 'ocr_service_mlkit.dart';
import 'ai_settings.dart';
import 'screen_translation_service.dart';

/// iOS has no MediaProjection equivalent an app can drive itself — screen
/// mirroring is only available through ReplayKit, and only a Broadcast
/// Upload Extension (a separate process) can read live frames. That
/// extension writes the latest frame as a PNG into the shared App Group
/// container (see ios/BroadcastExtension/SampleHandler.swift); this
/// service just watches that container for a fresh frame written after
/// the user starts a broadcast from Control Center / our in-app picker.
const _liveActivityChannel = MethodChannel('screen_translate/live_activity');
const _deeplinkChannel = MethodChannel('screen_translate/deeplink');
const _broadcastPickerChannel = MethodChannel('screen_translate/broadcast_picker');
const _latestFrameFileName = 'latest_frame.png';

class IosScreenTranslationService extends ScreenTranslationService {
  IosScreenTranslationService({
    required AiSettings aiSettings,
    required this.targetLanguage,
  }) : _translator = AiTranslationClient(settings: aiSettings);

  final AiTranslationClient _translator;
  final OcrServiceMlkit _ocr = OcrServiceMlkit();
  String targetLanguage;

  static const PlatformCapabilities capabilities = PlatformCapabilities(
    supportsGlobalHotkey: false,
    supportsSystemTray: false,
    supportsFullScreenCapture: false, // broadcast picker is user-initiated
    requiresUserGestureForCapture: true,
  );

  @override
  Future<void> initialize() async {
    // Two capture entry points on iOS:
    //  1. RPSystemBroadcastPickerView (native, see ios/NOTES_XCODE_SETUP.md)
    //     — user starts/stops a live broadcast; SampleHandler.swift writes
    //     frames continuously to the App Group container.
    //  2. The Share/Action Extension — a one-off screenshot handed to us
    //     directly. It deep-links back via `screentranslate://capture`;
    //     AppDelegate forwards that over this channel.
    _deeplinkChannel.setMethodCallHandler((call) async {
      if (call.method == 'onShareExtensionCapture') {
        onExternalCaptureRequest?.call();
      }
    });
  }

  @override
  Future<void> prepareCaptureSession() async {
    // Shows the system RPSystemBroadcastPickerView so the user can start
    // a ReplayKit broadcast — required once (or again after they stop a
    // broadcast) before SampleHandler.swift has any frame for
    // captureOnce() to read. Must be called from a user-tap handler (the
    // floating trigger's onTap, or a dedicated "start capture" button),
    // same as any other ReplayKit/screen-capture entry point on iOS.
    await _broadcastPickerChannel.invokeMethod('showPicker');
  }

  @override
  Future<CaptureFrame> captureOnce() async {
    final containerDir = await _appGroupContainerDir();
    final frameFile = File('${containerDir.path}/$_latestFrameFileName');
    if (!await frameFile.exists()) {
      throw StateError(
        'No broadcast frame available yet. Start a broadcast via the '
        'system picker, or use the Share Extension for a one-off capture.',
      );
    }
    final bytes = await frameFile.readAsBytes();

    // SampleHandler.swift writes frame dimensions alongside the PNG as a
    // sibling .json (see that file) so we don't need to decode the PNG
    // header just to get pixel size here.
    final metaFile = File('${containerDir.path}/latest_frame.json');
    final meta = await metaFile.exists()
        ? (await metaFile.readAsString())
        : '{"width":0,"height":0}';
    final dims = RegExp(r'"width":(\d+),"height":(\d+)').firstMatch(meta);
    final w = int.parse(dims?.group(1) ?? '0');
    final h = int.parse(dims?.group(2) ?? '0');

    return CaptureFrame(
      pngBytes: bytes,
      pixelWidth: w,
      pixelHeight: h,
      logicalWidth: w.toDouble(),
      logicalHeight: h.toDouble(),
    );
  }

  /// Entry point used by the Share Extension flow: it hands the screenshot
  /// straight to the app (via the extension's own App Group write) rather
  /// than going through a live broadcast.
  Future<CaptureFrame> captureFromShareExtension() => captureOnce();

  Future<Directory> _appGroupContainerDir() async {
    // path_provider doesn't know about App Groups directly; the native
    // side resolves FileManager.default.containerURL(forSecurityApplication
    // GroupIdentifier:) using its own appGroupId constant (see
    // ScreenTranslateChannels.swift — the single source of truth for that
    // string, kept in sync with the Xcode App Group capability) and hands
    // the resulting path back so Dart never hardcodes a sandbox path.
    final path = await _liveActivityChannel.invokeMethod<String>('getAppGroupContainerPath');
    return Directory(path!);
  }

  @override
  Future<List<TextBlock>> recognizeText(CaptureFrame frame) async {
    final tmpDir = await getTemporaryDirectory();
    final tmpFile = File('${tmpDir.path}/ocr_input.png');
    await tmpFile.writeAsBytes(frame.pngBytes);

    final blocks = await _ocr.recognize(frame, tmpFile.path);
    return _translator.translateBlocks(blocks: blocks, targetLanguage: targetLanguage);
  }

  @override
  Future<void> showOverlay(List<TextBlock> blocks, CaptureFrame frame) async {
    // Two presentation modes, matching the spec:
    //  - In-app modal: handled entirely in Flutter, see
    //    lib/ui/translation_overlay_stack.dart driven by
    //    TranslationController — no native call needed.
    //  - Lock Screen / Dynamic Island Live Activity: requires ActivityKit,
    //    which Flutter cannot call directly, hence this method channel
    //    into Swift. Keep the payload small (Live Activities have a
    //    strict content-state size budget) — summarize instead of
    //    sending every block.
    final summary = blocks.take(3).map((b) => b.translatedText ?? '').join(' · ');
    await _liveActivityChannel.invokeMethod('startOrUpdateLiveActivity', {
      'summaryText': summary,
      'blockCount': blocks.length,
    });
  }

  @override
  Future<void> hideOverlay() async {
    await _liveActivityChannel.invokeMethod('endLiveActivity');
  }

  @override
  void updateTargetLanguage(String language) => targetLanguage = language;

  @override
  Future<void> dispose() async {
    await _ocr.dispose();
  }
}

ScreenTranslationService createScreenTranslationService({
  required AiSettings aiSettings,
  required String targetLanguage,
}) =>
    IosScreenTranslationService(aiSettings: aiSettings, targetLanguage: targetLanguage);
