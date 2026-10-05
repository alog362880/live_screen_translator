import 'dart:convert';
import 'package:http/http.dart' as http;

import '../models/text_block.dart';
import 'ai_settings.dart';

/// Windows and Web have no bundled on-device OCR engine (ML Kit is
/// mobile-only). Rather than bundling Tesseract, this client does OCR
/// *and* translation in one multimodal call: send the captured screen
/// image straight to the AI model and ask for
/// `[{text, translated, bbox}]` back. One round-trip, no local OCR
/// dependency, works identically on Windows and Web.
///
/// Trade-off: bounding boxes come back as the model's best estimate
/// (0-1000 normalized per Claude's vision convention) rather than pixel-
/// exact ML Kit boxes — good enough for overlay placement, not pixel
/// perfect. Swap in `google_mlkit_text_recognition` (mobile) or a native
/// OCR pass if you need exact boxes on desktop/web too.
///
/// Reads [AiSettings.config] fresh on every call, so a user flipping the
/// proxy/personal-API-key toggle in Settings takes effect on the very next
/// capture — see ai_settings.dart.
class AiVisionOcrClient {
  AiVisionOcrClient({required this.settings});

  final AiSettings settings;

  Future<List<TextBlock>> extractAndTranslate({
    required List<int> pngBytes,
    required String targetLanguage,
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    final b64 = base64Encode(pngBytes);
    final prompt = '''
Find every piece of legible on-screen text in this image. For each, return
its bounding box in pixel coordinates of the ORIGINAL image (width=$pixelWidth,
height=$pixelHeight) and its translation into $targetLanguage.

Return ONLY a JSON array, no commentary, each item shaped exactly as:
{"text": "...", "translated": "...", "bbox": [left, top, width, height]}
''';

    final config = settings.config;
    final response = await http.post(
      config.messagesUri,
      headers: config.headers,
      body: jsonEncode({
        'model': config.model,
        'max_tokens': 4096,
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {'type': 'base64', 'media_type': 'image/png', 'data': b64},
              },
              {'type': 'text', 'text': prompt},
            ],
          }
        ],
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Vision OCR/translate failed (${response.statusCode}): ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final text = (decoded['content'] as List).first['text'] as String;
    final cleaned = text.trim().replaceAll(RegExp(r'^```json|^```|```$'), '').trim();
    final items = (jsonDecode(cleaned) as List).cast<Map<String, dynamic>>();

    var i = 0;
    return items.map((item) {
      final bbox = (item['bbox'] as List).cast<num>();
      return TextBlock(
        id: 'blk_${i++}',
        originalText: item['text'] as String,
        translatedText: item['translated'] as String,
        left: bbox[0].toDouble(),
        top: bbox[1].toDouble(),
        width: bbox[2].toDouble(),
        height: bbox[3].toDouble(),
      );
    }).toList();
  }
}
