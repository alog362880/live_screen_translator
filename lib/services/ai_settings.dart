import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_config.dart';

enum AiMode { proxy, direct }

const _prefMode = 'ai_mode';
const _prefPersonalApiKey = 'ai_personal_api_key';

/// The single source of truth AiTranslationClient/AiVisionOcrClient read
/// per-request (via [config]), so toggling the mode in Settings takes
/// effect on the very next capture — no need to recreate the capture
/// pipeline or restart the app.
///
/// The proxy URL/token stay build-time-only (lib/secrets.dart or
/// --dart-define, see main.dart); only [mode] and the personal API key are
/// user-editable at runtime, and only those two are persisted locally.
class AiSettings extends ChangeNotifier {
  AiSettings({
    required this.defaultProxyUrl,
    required this.defaultProxyToken,
    this.model = 'claude-sonnet-5',
  });

  final String defaultProxyUrl;
  final String defaultProxyToken;
  final String model;

  AiMode mode = AiMode.proxy;
  String personalApiKey = '';

  /// Call once at startup (fire-and-forget is fine — [notifyListeners]
  /// fires when it resolves, so the UI picks up a persisted choice even if
  /// it rendered once already with the defaults).
  Future<void> loadPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    final storedMode = prefs.getString(_prefMode);
    mode = storedMode == 'direct' ? AiMode.direct : AiMode.proxy;
    personalApiKey = prefs.getString(_prefPersonalApiKey) ?? '';
    notifyListeners();
  }

  Future<void> setMode(AiMode value) async {
    mode = value;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(
      _prefMode,
      value == AiMode.direct ? 'direct' : 'proxy',
    );
  }

  Future<void> setPersonalApiKey(String value) async {
    personalApiKey = value;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_prefPersonalApiKey, value);
  }

  /// Built fresh from current fields on every access — never cached, so
  /// there's no stale-config window between a Settings change and the
  /// next capture.
  AiConfig get config => mode == AiMode.direct
      ? AiConfig.direct(apiKey: personalApiKey, model: model)
      : AiConfig.proxy(proxyUrl: defaultProxyUrl, proxyToken: defaultProxyToken, model: model);
}
