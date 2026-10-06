/// The AI backends the app can talk to. Each has its own request/response
/// format, handled in [AiConfig].
enum AiProvider { claude, gemini, openai }

extension AiProviderInfo on AiProvider {
  String get id => name;

  String get label => switch (this) {
        AiProvider.claude => 'Claude (Anthropic)',
        AiProvider.gemini => 'Gemini (Google)',
        AiProvider.openai => 'ChatGPT (OpenAI)',
      };

  String get defaultModel => switch (this) {
        AiProvider.claude => 'claude-sonnet-5',
        AiProvider.gemini => 'gemini-2.5-flash',
        AiProvider.openai => 'gpt-4o-mini',
      };

  String get keyHint => switch (this) {
        AiProvider.claude => 'sk-ant-...',
        AiProvider.gemini => 'AIza...',
        AiProvider.openai => 'sk-...',
      };

  String get keyConsole => switch (this) {
        AiProvider.claude => 'console.anthropic.com',
        AiProvider.gemini => 'aistudio.google.com',
        AiProvider.openai => 'platform.openai.com',
      };
}

class AiRequestException implements Exception {
  AiRequestException(this.message);
  final String message;
  @override
  String toString() => 'AiRequestException: $message';
}

/// Where one AI request goes and how it is shaped. Immutable snapshot built
/// by [AiSettings]. Two modes:
///  - proxy: our own proxy (see /proxy) holds the real key; the client only
///    carries a revocable bearer token.
///  - direct: the user's own personal API key, sent straight to the provider
///    (no rate limiting/revocability; visible to a network inspector on this
///    device). Chosen explicitly in Settings.
class AiConfig {
  const AiConfig.proxy({
    required this.provider,
    required String proxyUrl,
    required String proxyToken,
    required this.model,
  })  : _proxyUrl = proxyUrl,
        _secret = proxyToken,
        isDirect = false;

  const AiConfig.direct({
    required this.provider,
    required String apiKey,
    required this.model,
  })  : _proxyUrl = null,
        _secret = apiKey,
        isDirect = true;

  final AiProvider provider;
  final String model;
  final bool isDirect;
  final String? _proxyUrl;
  final String _secret; // proxy token or personal API key

  bool get isConfigured =>
      _secret.isNotEmpty && (isDirect || (_proxyUrl?.isNotEmpty ?? false));

  Uri get uri {
    if (isDirect) {
      return Uri.parse(switch (provider) {
        AiProvider.claude => 'https://api.anthropic.com/v1/messages',
        AiProvider.gemini =>
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent',
        AiProvider.openai => 'https://api.openai.com/v1/chat/completions',
      });
    }
    final base = _proxyUrl!.replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse(base +
        switch (provider) {
          AiProvider.claude => '/v1/messages',
          AiProvider.gemini => '/gemini/v1beta/models/$model:generateContent',
          AiProvider.openai => '/openai/v1/chat/completions',
        });
  }

  Map<String, String> get headers {
    const json = {'content-type': 'application/json'};
    if (!isDirect) return {...json, 'authorization': 'Bearer $_secret'};
    return switch (provider) {
      AiProvider.claude => {
          ...json,
          'x-api-key': _secret,
          'anthropic-version': '2023-06-01',
          // Required for browser (Flutter Web) calls; harmless elsewhere.
          'anthropic-dangerous-direct-browser-access': 'true',
        },
      AiProvider.gemini => {...json, 'x-goog-api-key': _secret},
      AiProvider.openai => {...json, 'authorization': 'Bearer $_secret'},
    };
  }

  /// Request body in the provider's native format. [imageBase64] is a PNG.
  Map<String, dynamic> body({
    required String prompt,
    String? imageBase64,
    int maxTokens = 4096,
  }) {
    switch (provider) {
      case AiProvider.claude:
        return {
          'model': model,
          'max_tokens': maxTokens,
          'messages': [
            {
              'role': 'user',
              'content': imageBase64 == null
                  ? prompt
                  : [
                      {
                        'type': 'image',
                        'source': {'type': 'base64', 'media_type': 'image/png', 'data': imageBase64},
                      },
                      {'type': 'text', 'text': prompt},
                    ],
            }
          ],
        };
      case AiProvider.gemini:
        // The model is in the URL, not the body. Gemini 2.5 "thinking"
        // tokens count against maxOutputTokens, so leave generous headroom.
        return {
          'contents': [
            {
              'role': 'user',
              'parts': [
                if (imageBase64 != null)
                  {
                    'inlineData': {'mimeType': 'image/png', 'data': imageBase64},
                  },
                {'text': prompt},
              ],
            }
          ],
          'generationConfig': {
            'maxOutputTokens': 8192,
            'temperature': 0,
            'responseMimeType': 'application/json',
          },
        };
      case AiProvider.openai:
        return {
          'model': model,
          'max_completion_tokens': maxTokens,
          'messages': [
            {
              'role': 'user',
              'content': imageBase64 == null
                  ? prompt
                  : [
                      {
                        'type': 'image_url',
                        'image_url': {'url': 'data:image/png;base64,$imageBase64', 'detail': 'high'},
                      },
                      {'type': 'text', 'text': prompt},
                    ],
            }
          ],
        };
    }
  }

  /// Pulls the model's text answer out of the provider's response JSON.
  String extractText(Map<String, dynamic> json) {
    switch (provider) {
      case AiProvider.claude:
        final parts = (json['content'] as List? ?? const [])
            .whereType<Map>()
            .where((p) => p['type'] == 'text')
            .map((p) => p['text'] as String);
        if (parts.isEmpty) throw AiRequestException('Empty response from Claude.');
        return parts.join();
      case AiProvider.gemini:
        final candidates = json['candidates'] as List? ?? const [];
        if (candidates.isEmpty) {
          final reason = (json['promptFeedback'] as Map?)?['blockReason'];
          throw AiRequestException(
              'Gemini returned no answer${reason != null ? ' (blocked: $reason)' : ''}.');
        }
        final parts = ((candidates.first as Map)['content'] as Map?)?['parts'] as List? ?? const [];
        final text = parts
            .whereType<Map>()
            .where((p) => p['thought'] != true && p['text'] is String)
            .map((p) => p['text'] as String)
            .join();
        if (text.isEmpty) throw AiRequestException('Empty response from Gemini.');
        return text;
      case AiProvider.openai:
        final choices = json['choices'] as List? ?? const [];
        final content = choices.isEmpty
            ? null
            : ((choices.first as Map)['message'] as Map?)?['content'];
        if (content is! String || content.isEmpty) {
          throw AiRequestException('Empty response from ChatGPT.');
        }
        return content;
    }
  }
}
