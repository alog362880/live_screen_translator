import 'dart:convert';

import '../models/text_block.dart';
import 'ai_client.dart';
import 'ai_settings.dart';

/// Windows and Web have no bundled on-device OCR engine (ML Kit is
/// mobile-only). Rather than bundling Tesseract, this client does OCR
/// *and* translation in one multimodal call: send the captured screen
/// image straight to the AI model and ask for
/// `[{text, translated, box}]` back. One round-trip, no local OCR
/// dependency, works identically on Windows and Web, with Claude, Gemini
/// or ChatGPT (see [AiConfig]).
///
/// Boxes are requested as normalized 0-1000 `[ymin, xmin, ymax, xmax]`
/// (Gemini's native convention, and resolution-independent for the other
/// providers, which resize images internally) and converted to pixels here.
/// They're the model's best estimate rather than pixel-exact ML Kit boxes —
/// good enough for overlay placement. Swap in a native OCR pass if you need
/// exact boxes on desktop/web.
///
/// Reads [AiSettings.config] fresh on every call, so changing provider or
/// key in Settings takes effect on the very next capture.
class AiVisionOcrClient {
  AiVisionOcrClient({required this.settings});

  final AiSettings settings;

  Future<List<TextBlock>> extractAndTranslate({
    required List<int> pngBytes,
    required String targetLanguage,
    required int pixelWidth,
    required int pixelHeight,
  }) async {
    final prompt = '''
Find every piece of legible on-screen text in this image. For each, return the
original text, its translation into $targetLanguage, and its bounding box as
"box_2d": [ymin, xmin, ymax, xmax] with each value normalized to the range
0-1000 relative to the image (0,0 is top-left; 1000,1000 is bottom-right).
Skip text already in $targetLanguage.

Return ONLY a JSON array, no commentary, each item shaped exactly as:
{"text": "...", "translated": "...", "box_2d": [ymin, xmin, ymax, xmax]}
''';

    final answer = await aiComplete(
      settings.config,
      prompt: prompt,
      imageBase64: base64Encode(pngBytes),
      maxTokens: 4096,
    );
    return parseBlocks(answer, pixelWidth: pixelWidth, pixelHeight: pixelHeight);
  }

  /// Converts the model's JSON answer into pixel-space [TextBlock]s.
  static List<TextBlock> parseBlocks(
    String answer, {
    required int pixelWidth,
    required int pixelHeight,
  }) {
    var i = 0;
    final blocks = <TextBlock>[];
    for (final item in parseJsonArray(answer)) {
      final box = (item['box_2d'] as List?)?.cast<num>();
      if (box == null || box.length != 4) continue;
      final ymin = box[0].toDouble(), xmin = box[1].toDouble();
      final ymax = box[2].toDouble(), xmax = box[3].toDouble();
      blocks.add(TextBlock(
        id: 'blk_${i++}',
        originalText: '${item['text'] ?? ''}',
        translatedText: '${item['translated'] ?? item['text'] ?? ''}',
        left: xmin / 1000 * pixelWidth,
        top: ymin / 1000 * pixelHeight,
        width: (xmax - xmin) / 1000 * pixelWidth,
        height: (ymax - ymin) / 1000 * pixelHeight,
      ));
    }
    return blocks;
  }
}
