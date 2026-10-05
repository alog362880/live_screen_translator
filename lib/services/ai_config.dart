/// Where one AI request actually goes. Immutable snapshot built by
/// [AiSettings] — see that class for the user-facing toggle between modes.
class AiConfig {
  /// Default mode: calls our own proxy (see /proxy), which holds the real
  /// Anthropic key. Clients only ever carry a revocable bearer token.
  const AiConfig.proxy({
    required String proxyUrl,
    required String proxyToken,
    this.model = 'claude-sonnet-5',
  })  : _proxyUrl = proxyUrl,
        _proxyToken = proxyToken,
        _apiKey = null;

  /// Opt-in "bring your own key" mode: calls Anthropic directly with the
  /// user's own personal API key, entered in Settings. Skips the proxy
  /// entirely — no rate limiting, no revocability, and (on Web/the Chrome
  /// extension) the key leaves the browser in a request header a network
  /// inspector can read. The user chooses this explicitly; see the warning
  /// text next to the toggle in settings_page.dart / popup.html.
  const AiConfig.direct({
    required String apiKey,
    this.model = 'claude-sonnet-5',
  })  : _apiKey = apiKey,
        _proxyUrl = null,
        _proxyToken = null;

  final String? _proxyUrl;
  final String? _proxyToken;
  final String? _apiKey;
  final String model;

  bool get isDirect => _apiKey != null;

  Uri get messagesUri => isDirect
      ? Uri.parse('https://api.anthropic.com/v1/messages')
      : Uri.parse('${_proxyUrl!.replaceFirst(RegExp(r'/+$'), '')}/v1/messages');

  Map<String, String> get headers => isDirect
      ? {
          'content-type': 'application/json',
          'x-api-key': _apiKey!,
          'anthropic-version': '2023-06-01',
        }
      : {
          'content-type': 'application/json',
          'authorization': 'Bearer $_proxyToken',
        };

  bool get isConfigured => isDirect
      ? _apiKey!.isNotEmpty
      : (_proxyUrl?.isNotEmpty ?? false) && (_proxyToken?.isNotEmpty ?? false);
}
