import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/text_block.dart';
import 'ai_settings.dart';

/// Sends OCR'd text blocks to an AI model and asks for a structured JSON
/// translation payload, in one batched call per screen capture (cheaper
/// and avoids re-establishing layout context per line).
///
/// Reads [AiSettings.config] fresh on every call, so a user flipping the
/// proxy/personal-API-key toggle in Settings takes effect on the very next
/// request — see ai_settings.dart.
class AiTranslationClient {
  AiTranslationClient({required this.settings});

  final AiSettings settings;

  /// Translates every block's [TextBlock.originalText] into
  /// [targetLanguage] and returns new blocks with [TextBlock.translatedText]
  /// populated. Bounding boxes are passed straight through untouched —
  /// only the model-facing prompt needs them, to keep translations
  /// context-aware (e.g. a button label vs. a paragraph).
  Future<List<TextBlock>> translateBlocks({
    required List<TextBlock> blocks,
    required String targetLanguage,
  }) async {
    if (blocks.isEmpty) return blocks;

    final payload = blocks.map((b) => b.toJson()).toList();
    final prompt = '''
You are a screen-OCR translation engine. Translate the "text" field of each
item below into $targetLanguage. Preserve tone and brevity appropriate for
UI text. Return ONLY a JSON array, same order, same "id"s, where each item
is {"id": "...", "translated": "..."}. Do not add commentary.

Input:
${jsonEncode(payload)}
''';

    final config = settings.config;
    final response = await http.post(
      config.messagesUri,
      headers: config.headers,
      body: jsonEncode({
        'model': config.model,
        'max_tokens': 2048,
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
      }),
    );

    if (response.statusCode != 200) {
      throw AiTranslationException(
        'Translation request failed (${response.statusCode}): ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final text = (decoded['content'] as List).first['text'] as String;
    final translated = _parseJsonArray(text);

    final byId = {for (final t in translated) t['id'] as String: t['translated'] as String};
    return blocks
        .map((b) => b.copyWith(translatedText: byId[b.id] ?? b.originalText))
        .toList();
  }

  List<Map<String, dynamic>> _parseJsonArray(String raw) {
    // Models occasionally wrap JSON in a ```json fence despite instructions;
    // strip it defensively rather than failing the whole batch.
    final cleaned = raw.trim().replaceAll(RegExp(r'^```json|^```|```$'), '').trim();
    final list = jsonDecode(cleaned) as List;
    return list.cast<Map<String, dynamic>>();
  }
}

class AiTranslationException implements Exception {
  AiTranslationException(this.message);
  final String message;
  @override
  String toString() => 'AiTranslationException: $message';
}
