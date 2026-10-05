import 'dart:io';

import 'ai_settings.dart';
import 'screen_translation_service.dart';
import 'service_windows.dart';
import 'service_ios.dart';

/// dart:io covers both Windows and iOS builds, so pick the concrete
/// implementation at runtime.
ScreenTranslationService createScreenTranslationService({
  required AiSettings aiSettings,
  required String targetLanguage,
}) {
  if (Platform.isWindows) {
    return WindowsScreenTranslationService(
      aiSettings: aiSettings,
      targetLanguage: targetLanguage,
    );
  }
  if (Platform.isIOS) {
    return IosScreenTranslationService(
      aiSettings: aiSettings,
      targetLanguage: targetLanguage,
    );
  }
  throw UnsupportedError(
    'ScreenTranslationService: unsupported native platform "${Platform.operatingSystem}". '
    'This starter only wires up Windows and iOS.',
  );
}
