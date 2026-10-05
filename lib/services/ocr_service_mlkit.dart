import 'dart:io';
// ML Kit's own `TextBlock` (a paragraph-level OCR result) collides with
// our app's `TextBlock` (an overlay-ready text+bbox+translation model) —
// hide theirs since this file only needs the finer-grained `.lines`.
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart' hide TextBlock;

import '../models/capture_frame.dart';
import '../models/text_block.dart';

/// On-device OCR via Google ML Kit. Only usable on iOS/Android — Windows
/// and Web have no ML Kit binding, so [OcrServiceMlkit.isSupported] gates
/// this at the call site (see service_windows.dart / service_web.dart for
/// their own OCR strategies).
class OcrServiceMlkit {
  OcrServiceMlkit() : _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  final TextRecognizer _recognizer;

  static bool get isSupported => Platform.isIOS || Platform.isAndroid;

  Future<List<TextBlock>> recognize(CaptureFrame frame, String tempImagePath) async {
    final input = InputImage.fromFilePath(tempImagePath);
    final result = await _recognizer.processImage(input);

    final blocks = <TextBlock>[];
    var i = 0;
    for (final block in result.blocks) {
      for (final line in block.lines) {
        final rect = line.boundingBox;
        blocks.add(TextBlock(
          id: 'blk_${i++}',
          originalText: line.text,
          left: rect.left,
          top: rect.top,
          width: rect.width,
          height: rect.height,
        ));
      }
    }
    return blocks;
  }

  Future<void> dispose() => _recognizer.close();
}
