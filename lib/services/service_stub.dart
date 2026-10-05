import 'ai_settings.dart';
import 'screen_translation_service.dart';

/// Selected only when neither `dart.library.io` nor
/// `dart.library.js_interop` is available (i.e. never, in practice, for
/// Flutter's supported targets) — kept so `service_factory.dart`'s
/// conditional import always has a valid fallback branch and the analyzer
/// never flags a missing case.
ScreenTranslationService createScreenTranslationService({
  required AiSettings aiSettings,
  required String targetLanguage,
}) {
  throw UnsupportedError('No ScreenTranslationService implementation for this platform.');
}
