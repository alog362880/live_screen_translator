import 'ai_settings.dart';
import 'screen_translation_service.dart';

// Conditional import picks the right implementation at COMPILE time based
// on which core library is available — `dart.library.js_interop` is only
// present when compiling for web, `dart.library.io` covers every native
// target (Windows here; Android/iOS if you extend this later). Within the
// io branch, service_io.dart does a runtime Platform.isX check because
// dart:io alone can't tell Windows from iOS at compile time.
//
// Each of service_stub/web/io.dart must expose the same top-level:
//   ScreenTranslationService createScreenTranslationService({
//     required AiSettings aiSettings,
//     required String targetLanguage,
//   })
import 'service_stub.dart'
    if (dart.library.js_interop) 'service_web.dart'
    if (dart.library.io) 'service_io.dart' as platform;

/// Call this from `main.dart` / the state layer — never construct a
/// platform service class directly.
ScreenTranslationService createScreenTranslationService({
  required AiSettings aiSettings,
  required String targetLanguage,
}) =>
    platform.createScreenTranslationService(
      aiSettings: aiSettings,
      targetLanguage: targetLanguage,
    );
