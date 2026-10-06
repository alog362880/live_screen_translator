import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_config.dart';

enum AiMode { proxy, direct }

const _prefMode = 'ai_mode';
const _prefProvider = 'ai_provider';
const _legacyPrefKey = 'ai_personal_api_key'; // pre-multi-provider: Claude only

String _keyPref(AiProvider p) => 'ai_key_${p.id}';
String _modelPref(AiProvider p) => 'ai_model_${p.id}';

/// The single source of truth AiTranslationClient/AiVisionOcrClient read
/// per-request (via [config]), so changing provider/mode/key in Settings
/// takes effect on the very next capture — no rebuild or restart.
///
/// The proxy URL/token stay build-time-only (lib/secrets.dart or
/// --dart-define, see main.dart). Everything else here is user-editable at
/// runtime and persisted locally: which [provider] to use, whether to go via
/// the proxy or a personal key ([mode]), one personal key per provider, and
/// an optional model override per provider.
class AiSettings extends ChangeNotifier {
  AiSettings({
    required this.defaultProxyUrl,
    required this.defaultProxyToken,
  });

  final String defaultProxyUrl;
  final String defaultProxyToken;

  AiProvider provider = AiProvider.claude;
  AiMode mode = AiMode.proxy;
  final Map<AiProvider, String> _keys = {};
  final Map<AiProvider, String> _models = {};

  String keyFor(AiProvider p) => _keys[p] ?? '';

  /// The user's override, or '' when the provider default is in effect.
  String modelOverrideFor(AiProvider p) => _models[p] ?? '';

  String modelFor(AiProvider p) {
    final m = modelOverrideFor(p).trim();
    return m.isEmpty ? p.defaultModel : m;
  }

  /// Call once at startup (fire-and-forget is fine — [notifyListeners]
  /// fires when it resolves, so the UI picks up persisted choices even if
  /// it rendered once already with the defaults).
  Future<void> loadPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    mode = prefs.getString(_prefMode) == 'direct' ? AiMode.direct : AiMode.proxy;
    final storedProvider = prefs.getString(_prefProvider);
    provider = AiProvider.values.firstWhere(
      (p) => p.id == storedProvider,
      orElse: () => AiProvider.claude,
    );
    for (final p in AiProvider.values) {
      _keys[p] = prefs.getString(_keyPref(p)) ?? '';
      _models[p] = prefs.getString(_modelPref(p)) ?? '';
    }
    // Migrate the single Claude-only key saved by earlier versions.
    if (keyFor(AiProvider.claude).isEmpty) {
      _keys[AiProvider.claude] = prefs.getString(_legacyPrefKey) ?? '';
    }
    notifyListeners();
  }

  Future<void> setMode(AiMode value) async {
    mode = value;
    notifyListeners();
    (await SharedPreferences.getInstance())
        .setString(_prefMode, value == AiMode.direct ? 'direct' : 'proxy');
  }

  Future<void> setProvider(AiProvider value) async {
    provider = value;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_prefProvider, value.id);
  }

  Future<void> setKey(AiProvider p, String value) async {
    _keys[p] = value;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_keyPref(p), value);
  }

  Future<void> setModelOverride(AiProvider p, String value) async {
    _models[p] = value;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_modelPref(p), value);
  }

  /// Built fresh from current fields on every access — never cached, so
  /// there's no stale-config window between a Settings change and the
  /// next capture.
  AiConfig get config => mode == AiMode.direct
      ? AiConfig.direct(provider: provider, apiKey: keyFor(provider), model: modelFor(provider))
      : AiConfig.proxy(
          provider: provider,
          proxyUrl: defaultProxyUrl,
          proxyToken: defaultProxyToken,
          model: modelFor(provider),
        );
}
